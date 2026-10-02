"""Error dialog shown when a module fails.

Shows the captured error output, a heuristic-based suggested fix, and
a "Copy Error Message and Fix" button that places everything on the
system clipboard so the user can paste it into a support ticket.
"""

from __future__ import annotations

import platform
import re
import shlex
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from PyQt6.QtCore import Qt
from PyQt6.QtGui import QFont, QGuiApplication
from PyQt6.QtWidgets import (
    QDialog,
    QDialogButtonBox,
    QHBoxLayout,
    QLabel,
    QPlainTextEdit,
    QPushButton,
    QVBoxLayout,
)

from .theme import palette


# ─── Helpdesk contact info (read from /etc/dtu-setup/site.conf) ────────────

def _read_helpdesk_info() -> tuple[str, str]:
    """Return (url, email) from site.conf, falling back to DTU defaults."""
    url = "https://serviceportal.dtu.dk"
    email = "ait@dtu.dk"
    try:
        conf = Path("/etc/dtu-setup/site.conf")
        if conf.exists():
            for raw in conf.read_text(encoding="utf-8").splitlines():
                line = raw.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                key = key.strip()
                tokens = shlex.split(val, posix=True)
                parsed = tokens[0] if tokens else ""
                if key == "SITE_HELPDESK_URL" and parsed:
                    url = parsed
                elif key == "SITE_HELPDESK_EMAIL" and parsed:
                    email = parsed
    except Exception:
        pass
    return url, email


_HELPDESK_URL, _HELPDESK_EMAIL = _read_helpdesk_info()


# ─── Error pattern → suggested fix mapping ─────────────────────────────
# Each entry: (regex pattern, short title, suggested fix text).
# First match wins; ordering matters (most specific first).

@dataclass(frozen=True)
class ErrorPattern:
    pattern: str
    title: str
    fix: str


ERROR_PATTERNS: list[ErrorPattern] = [
    # Først, fordi den er grundårsagen til alt andet i outputtet: en pakke
    # står halvt installeret, og HVERT efterfølgende apt-kald prøver at gøre
    # den færdig og fejler på samme sted. Set 2. oktober 2026, hvor tre
    # moduler i træk fejlede på én Microsoft-pakke fra et fjerde.
    ErrorPattern(
        r"(end of file on stdin at conffile prompt|dpkg was interrupted|"
        r"you must manually run 'sudo dpkg --configure -a')",
        "A package installation was left unfinished",
        "An earlier installation stopped halfway, so every module that\n"
        "uses apt now fails at the same place.\n"
        "• Finish it, taking the packages' own configuration files:\n"
        "  sudo DEBIAN_FRONTEND=noninteractive dpkg --force-confnew --force-confmiss --configure -a\n"
        "• Then run this module again.",
    ),
    # Næsten lige så tidligt: flere moduler skjuler apt's output (-qq,
    # >/dev/null), og så er dette den eneste linje der når frem. Den er altid
    # grundårsagen når den står der, også når resten af outputtet ligner noget
    # andet.
    ErrorPattern(
        r"Sub-process /usr/bin/dpkg returned an error code",
        "A package could not be installed (dpkg failed)",
        "apt asked dpkg to install or configure a package, and dpkg failed.\n"
        "• Most often an earlier installation stopped halfway. Finish it:\n"
        "  sudo DEBIAN_FRONTEND=noninteractive dpkg --force-confnew --force-confmiss --configure -a\n"
        "• Then: sudo apt-get -f install\n"
        "• Run the module again. If it still fails, run its script in a terminal\n"
        "  to see dpkg's own message.",
    ),
    ErrorPattern(
        r"pkexec.*(dismissed|cancelled|not authorized|Authorization failed)",
        "Authentication cancelled or denied",
        "The PolicyKit authorisation was denied or cancelled.\n"
        "• Click 'Authenticate' in the password prompt.\n"
        "• Check that you are an IT admin (a member of the 'sus-itadm' group), "
        "or that the polkit rules are installed (run the 'PolicyKit' module first).",
    ),
    ErrorPattern(
        r"(NT_STATUS_LOGON_FAILURE|LOGON_FAILURE|mount error\(13\)|Permission denied.*cifs|"
        r"NT_STATUS_ACCESS_DENIED)",
        "Wrong username or password for the network drive",
        "The server rejected the WIN domain login.\n"
        "• Check that the username is your WIN username, not your email address.\n"
        "• Try signing in at https://portal.office.com with the same credentials.\n"
        "• If the password has expired, change it first in the DTU password portal.",
    ),
    ErrorPattern(
        r"(NT_STATUS_HOST_UNREACHABLE|NT_STATUS_IO_TIMEOUT|Host is down|"
        r"Connection timed out|Network is unreachable|No route to host)",
        "Cannot reach the server",
        "The machine cannot reach the file server.\n"
        "• Check that you are on the DTU network, or that the DTU VPN is connected.\n"
        "• Test the connection: ping <file server>\n"
        "  (the file server is named in SITE_FILE_SERVER in /etc/dtu-setup/site.conf)\n"
        "• If you are working from home, start GlobalProtect / VPN first.",
    ),
    ErrorPattern(
        r"(NT_STATUS_BAD_NETWORK_NAME|mount error\(2\):|No such file or directory.*\\\\)",
        "The network share does not exist",
        "The share could not be found on the server.\n"
        "• Check that the right department, AIT or Sustain, is selected in the dropdown.\n"
        "• For the AIT M drive, your user folder must exist in the Users0-9 structure.\n"
        "• Contact IT support if your network drive is missing.",
    ),
    ErrorPattern(
        r"(realm.*not enrolled|sssd.*could not authenticate|kinit.*Preauthentication failed|"
        r"kinit.*Client not found)",
        "Domain join or Kerberos failure",
        "The domain join or the Kerberos authentication failed.\n"
        "• Run the 'Domain Join' module first; it has to happen before network drives.\n"
        "• Check the system clock: timedatectl status. It must be synchronised.\n"
        "• Check that DNS points at DTU's name servers.",
    ),
    ErrorPattern(
        r"(Could not resolve host|Temporary failure in name resolution|Name or service not known)",
        "DNS lookup failed",
        "The machine cannot resolve host names.\n"
        "• Check the network connection: ip addr / nmcli device status\n"
        "• Test DNS: nslookup <file server>\n"
        "  (the file server is named in SITE_FILE_SERVER in /etc/dtu-setup/site.conf)\n"
        "• On DTUSecure, give the Wi-Fi a moment to connect.",
    ),
    ErrorPattern(
        r"(E: Could not get lock|dpkg was interrupted|apt.*Unable to lock)",
        "APT is locked by another process",
        "Another package operation is running or was interrupted.\n"
        "• Wait for the automatic updates to finish, up to 5 minutes.\n"
        "• If it persists:\n"
        "    sudo dpkg --configure -a\n"
        "    sudo apt-get -f install",
    ),
    ErrorPattern(
        r"(E: Unable to locate package|Unable to fetch some archives|"
        r"404\s+Not Found.*archive\.ubuntu)",
        "The package could not be downloaded",
        "APT could not find or fetch the package.\n"
        "• Refresh the package cache: sudo apt-get update\n"
        "• Check the connection to archive.ubuntu.com.\n"
        "• Check that /etc/apt/sources.list points at the right repositories.",
    ),
    ErrorPattern(
        r"(nmcli.*Error.*Connection activation failed|Secrets were required|"
        r"802-1x.*EAP authentication failed)",
        "Wi-Fi connection failed",
        "DTUSecure could not connect.\n"
        "• Check the WIN username and password.\n"
        "• Check that you are physically in range of DTUSecure.\n"
        "• Show the NetworkManager log: journalctl -u NetworkManager -n 50",
    ),
    ErrorPattern(
        r"(cups.*Forbidden|lpadmin.*Not authorized|cupsd.*permission denied)",
        "CUPS refused the operation",
        "CUPS did not allow the printer to be configured.\n"
        "• Check that the user is in the 'lpadmin' group: groups\n"
        "• Check that CUPS is running: systemctl status cups\n"
        "• Restart CUPS: sudo systemctl restart cups",
    ),
    ErrorPattern(
        r"(command not found|No such file or directory.*\.sh)",
        "Missing command or script",
        "A required command or script file is missing from the system.\n"
        "• Check that all DTU setup packages are installed.\n"
        "• If it is an external tool, install it with apt.\n"
        "• Run the module's script directly in a terminal for the full output.",
    ),
    ErrorPattern(
        r"(No space left on device|disk full|ENOSPC)",
        "The disk is full",
        "There is no space left on the file system.\n"
        "• Check the free space: df -h\n"
        "• Clear the package cache: sudo apt-get clean\n"
        "• Trim old journals: sudo journalctl --vacuum-time=7d",
    ),

    # ─── Authentication / credentials ────────────────────────────────
    ErrorPattern(
        r"(Password has expired|password expired|CHANGE_PASSWORD_REQUIRED|"
        r"NT_STATUS_PASSWORD_EXPIRED|NT_STATUS_PASSWORD_MUST_CHANGE)",
        "The WIN password has expired",
        "Your WIN domain password has expired and must be changed.\n"
        "• Change it in the DTU password portal: https://password.dtu.dk\n"
        "• Or change it on a Windows machine with Ctrl+Alt+Del → 'Change a password'.\n"
        "• Run the module again once the password has been changed.",
    ),
    ErrorPattern(
        r"(NT_STATUS_ACCOUNT_LOCKED_OUT|account.*locked)",
        "The account is locked",
        "Your WIN account is temporarily locked after too many failed attempts.\n"
        "• Wait 15 to 30 minutes and try again.\n"
        "• Contact DTU IT to have it unlocked manually.",
    ),
    ErrorPattern(
        r"(NT_STATUS_ACCOUNT_DISABLED|NT_STATUS_ACCOUNT_EXPIRED)",
        "The account is disabled or expired",
        "Your WIN domain account is disabled or has expired.\n"
        "• Contact DTU IT support to have the account reactivated.\n"
        "• If you are a new employee, check that the AD account is fully provisioned.",
    ),
    ErrorPattern(
        r"(NT_STATUS_NOLOGON_WORKSTATION_TRUST_ACCOUNT|trust relationship.*failed|"
        r"machine account password)",
        "The machine has lost its domain trust",
        "The machine's computer account no longer has a trust relationship with AD.\n"
        "• Rejoin the domain: run the 'Domain Join' module again.\n"
        "• Or by hand: sudo realm leave && sudo realm join win.dtu.dk",
    ),
    ErrorPattern(
        r"(authentication token manipulation error|pam_unix.*authentication failure)",
        "PAM authentication failed",
        "The system's PAM stack rejected the login.\n"
        "• Check /etc/pam.d/common-auth and /etc/nsswitch.conf.\n"
        "• Restart SSSD: sudo systemctl restart sssd\n"
        "• Check the log: journalctl -u sssd -n 100",
    ),

    # ─── Kerberos / clock skew ───────────────────────────────────────
    ErrorPattern(
        r"(Clock skew too great|KRB_AP_ERR_SKEW|krb5.*time.*offset)",
        "The system clock is out of sync (Kerberos)",
        "The machine's clock differs too much from the domain controller.\n"
        "• Enable NTP: sudo timedatectl set-ntp true\n"
        "• Check the status: timedatectl status\n"
        "• Force a sync: sudo systemctl restart systemd-timesyncd",
    ),
    ErrorPattern(
        r"(KDC_ERR_S_PRINCIPAL_UNKNOWN|Server not found in Kerberos database)",
        "The Kerberos service principal is missing",
        "AD does not know the service you are requesting a ticket for.\n"
        "• Check the SPN in AD; contact IT support.\n"
        "• Check /etc/krb5.conf. default_realm must be WIN.DTU.DK",
    ),

    # ─── DNS & network specifics ─────────────────────────────────────
    ErrorPattern(
        r"(NetworkManager.*not running|nmcli.*Error.*NetworkManager is not running)",
        "NetworkManager is not running",
        "NetworkManager is not active, so Wi-Fi and networking cannot be configured.\n"
        "• Start the service: sudo systemctl start NetworkManager\n"
        "• Enable it at boot: sudo systemctl enable NetworkManager\n"
        "• Check the status: systemctl status NetworkManager",
    ),
    ErrorPattern(
        r"(SSL certificate problem|certificate verify failed|self signed certificate|"
        r"unable to get local issuer certificate)",
        "TLS/SSL certificate error",
        "A TLS connection was rejected because of the certificate.\n"
        "• Update the root certificates: sudo update-ca-certificates\n"
        "• Check the system clock. A wrong time makes valid certificates look invalid.\n"
        "• Behind a corporate proxy, import the internal CA into "
        "/usr/local/share/ca-certificates/",
    ),

    # ─── SMB / CIFS specifics ────────────────────────────────────────
    ErrorPattern(
        r"(mount error\(112\):|Host is down.*cifs|cifs_mount failed.*-112)",
        "The SMB host is not responding",
        "The file server is not answering on the SMB protocol.\n"
        "• Wait a moment. The server may be restarting.\n"
        "• Test from a terminal: smbclient -L //<file server>/ -U <user>\n"
        "  (the file server is named in SITE_FILE_SERVER in /etc/dtu-setup/site.conf)\n"
        "• On VPN, check that the SMB port, 445, is not blocked.",
    ),
    ErrorPattern(
        r"(mount error\(95\):|Operation not supported.*cifs|"
        r"CIFS VFS:.*SMB.*unsupported)",
        "Unsupported SMB protocol version",
        "The client and the server cannot agree on an SMB version.\n"
        "• Add 'vers=3.0' to the mount options in /etc/fstab.\n"
        "• Or try 'vers=2.1' for older file servers.\n"
        "• Check: sudo mount -t cifs ... -o vers=3.0,...",
    ),
    ErrorPattern(
        r"(mount\.cifs.*not found|mount: unknown filesystem type 'cifs')",
        "cifs-utils is missing",
        "The CIFS package is not installed.\n"
        "• Ubuntu: sudo apt-get install -y cifs-utils\n"
    ),
    ErrorPattern(
        r"(smbclient.*command not found|samba-client.*not installed)",
        "The Samba client is missing",
        "smbclient is not installed. It is required to look up the AIT M drive.\n"
        "• Ubuntu: sudo apt-get install -y smbclient\n"
    ),
    ErrorPattern(
        r"(target is busy|umount.*device is busy)",
        "The file system is busy and cannot be unmounted",
        "An open file handle is preventing the unmount.\n"
        "• Find the process using it: sudo lsof +D /mnt/Qdrev\n"
        "• Or: sudo fuser -m /mnt/Qdrev\n"
        "• Close the program and try again, or use: sudo umount -l /mnt/Qdrev",
    ),

    # ─── Domain join specifics ───────────────────────────────────────
    ErrorPattern(
        r"(realm.*Already joined|Realm.*is already configured)",
        "Already joined to the domain",
        "The machine is already a member of WIN.DTU.DK.\n"
        "• Skip the 'Domain Join' module.\n"
        "• To rejoin, run sudo realm leave win.dtu.dk first.",
    ),
    ErrorPattern(
        r"(realm.*Cannot find a matching realm|No such realm found)",
        "The domain cannot be found",
        "realmd cannot discover WIN.DTU.DK.\n"
        "• Check that DNS points at DTU's name servers: resolvectl status\n"
        "• Test by hand: realm discover win.dtu.dk\n"
        "• Off campus, connect the VPN first.",
    ),
    ErrorPattern(
        r"(adcli.*Couldn't authenticate|adcli.*Insufficient permissions)",
        "AD refused the domain join",
        "The account does not have the right to join machines to AD.\n"
        "• Use an account with 'Domain Admin' or delegated join rights.\n"
        "• Contact DTU IT for join credentials for the pilot OU.",
    ),

    # ─── PolicyKit / sudo ────────────────────────────────────────────
    ErrorPattern(
        r"(polkit.*not authorized|org\.freedesktop\.PolicyKit.*Error|"
        r"Operation.*not permitted by polkit)",
        "A PolicyKit rule is missing or is blocking",
        "PolicyKit refused the operation for this user.\n"
        "• Run the 'PolicyKit' module to install the domain rules.\n"
        "• Check the rules: ls /etc/polkit-1/rules.d/\n"
        "• Check the polkit log: journalctl -u polkit -n 50",
    ),
    ErrorPattern(
        r"(sudo: a password is required|sudo:.*incorrect password|"
        r"is not in the sudoers file)",
        "Missing sudo rights",
        "The user is not in sudoers, or typed the wrong password.\n"
        "• IT admin: add the user to the 'sudo' group.\n"
        "• Run: sudo usermod -aG sudo <user>",
    ),

    # ─── PackageKit / Flatpak / fwupd ────────────────────────────────
    ErrorPattern(
        r"(PackageKit.*org\.freedesktop\.PackageKit\.Failed|"
        r"pkcon.*Fatal error|PK_ERROR_)",
        "PackageKit error",
        "The PackageKit daemon returned an error.\n"
        "• Restart it: sudo systemctl restart packagekit\n"
        "• Check the log: journalctl -u packagekit -n 50\n"
        "• As a fallback, use apt directly in a terminal.",
    ),
    ErrorPattern(
        r"(flatpak.*error|Could not find ref.*flatpak|No remote refs found)",
        "Flatpak error",
        "Flatpak could not install or find the app.\n"
        "• Refresh the remotes: flatpak update --appstream\n"
        "• Add Flathub: flatpak remote-add --if-not-exists flathub "
        "https://flathub.org/repo/flathub.flatpakrepo\n"
        "• Check the network. Flathub needs internet access.",
    ),
    ErrorPattern(
        r"(fwupdmgr.*failed|fwupd.*Authentication required|"
        r"fwupd.*UEFI capsule)",
        "Firmware update failed",
        "fwupd could not update the firmware.\n"
        "• Check what is supported: fwupdmgr get-devices\n"
        "• On some systems a UEFI capsule requires Secure Boot to be disabled.\n"
        "• Log: journalctl -u fwupd -n 100",
    ),
    ErrorPattern(
        r"(snap.*error|cannot install.*snap|snapd is not running)",
        "Snap error",
        "The snap package system failed.\n"
        "• Start snapd: sudo systemctl start snapd\n"
        "• Check the connection to api.snapcraft.io.\n"
        "• As a workaround, use apt or flatpak.",
    ),
    ErrorPattern(
        r"(GPG error|NO_PUBKEY|public key is not available|"
        r"signatures couldn't be verified)",
        "The repository's GPG key is missing",
        "The package repository is not trusted, because its GPG key is missing.\n"
        "• Ubuntu: sudo apt-key adv --recv-keys <KEY_ID>  (older systems)\n"
        "  or import the key into /etc/apt/keyrings/.\n"
    ),
    ErrorPattern(
        r"(Conflicting requests|file conflicts|nothing provides|"
        r"have unmet dependencies)",
        "Package dependency conflict",
        "The package resolver could not find a valid combination.\n"
        "• Ubuntu: sudo apt-get -f install   (fix broken)\n"
        "• As a last resort: sudo apt-get dist-upgrade --fix-broken",
    ),

    # ─── Microsoft Defender ──────────────────────────────────────────
    ErrorPattern(
        r"(mdatp.*not licensed|mdatp.*not onboarded|onboarding.*failed)",
        "Defender onboarding failed",
        "Microsoft Defender for Endpoint could not onboard.\n"
        "• Check that the onboarding script (.py) is valid and signed.\n"
        "• Check the mdatp status: mdatp health\n"
        "• Log: /var/log/microsoft/mdatp/",
    ),
    ErrorPattern(
        r"(mdatp.*conflicts with|conflicting AV product|another antivirus)",
        "Defender conflicts with another antivirus",
        "Another antivirus product is preventing Defender from running.\n"
        "• Uninstall ClamAV or any other AV packages first.\n"
        "• Contact IT support if it persists.",
    ),

    # ─── Filesystem / permissions ────────────────────────────────────
    ErrorPattern(
        r"(Read-only file system|\bEROFS\b)",
        "The file system is read-only",
        "The file system is mounted read-only, which usually follows an error at boot.\n"
        "• Remount it read-write: sudo mount -o remount,rw /\n"
        "• Check dmesg for disk errors: dmesg | tail -50\n"
        "• If the disk has errors, run sudo fsck after a restart.",
    ),
    ErrorPattern(
        r"(Permission denied(?!.*cifs)|EACCES|Operation not permitted)",
        "Permission denied",
        "A file or system operation was refused because of permissions.\n"
        "• Check whether the script needs sudo or pkexec.\n"
        "• Check the ownership: ls -la <path>\n"
        "• With SELinux or AppArmor active, check the audit log: sudo ausearch -m avc",
    ),
    ErrorPattern(
        r"(Input/output error|\bEIO\b|Buffer I/O error)",
        "I/O error, possibly a failing disk",
        "The kernel reported an I/O error, which can mean a hardware problem.\n"
        "• Check the SMART status: sudo smartctl -a /dev/sda\n"
        "• Read the kernel messages: dmesg | grep -i error\n"
        "• Back up important data and contact IT support.",
    ),

    # ─── Build / git / curl ──────────────────────────────────────────
    ErrorPattern(
        r"(curl.*\(6\) Could not resolve host|wget.*unable to resolve)",
        "Download failed (DNS)",
        "curl or wget could not resolve the target host.\n"
        "• Check the network connection: ping 1.1.1.1\n"
        "• Check DNS: cat /etc/resolv.conf\n"
        "• Behind a proxy, set $http_proxy / $https_proxy.",
    ),
    ErrorPattern(
        r"(curl.*\(7\) Failed to connect|curl.*Connection refused)",
        "HTTP connection refused",
        "The server refused the connection.\n"
        "• Check that the service is running on the other end.\n"
        "• Behind a firewall, check which outbound ports are allowed.\n"
        "• Test with: curl -v <url>",
    ),
    ErrorPattern(
        r"(curl.*\(60\) SSL certificate|curl.*\(35\) SSL connect error)",
        "curl SSL/TLS error",
        "curl could not establish a TLS connection.\n"
        "• Update the ca-certificates package.\n"
        "• Check the system clock. A wrong time invalidates certificates.\n"
        "• With an internal CA, import it into the system trust store.",
    ),
    ErrorPattern(
        r"(git.*fatal:.*could not read Username|Authentication failed for.*github)",
        "Git authentication failed",
        "Git could not authenticate against the remote.\n"
        "• Use HTTPS with a personal access token, not a password.\n"
        "• Or switch to SSH: git remote set-url origin git@github.com:...\n"
        "• Check the credential helper: git config --global credential.helper",
    ),

    # ─── systemd ─────────────────────────────────────────────────────
    ErrorPattern(
        r"(Failed to (start|enable|reload).*\.service|Job for .* failed because)",
        "A systemd service failed",
        "A systemd unit could not be started or enabled.\n"
        "• Show the status: systemctl status <service>\n"
        "• Show the log: journalctl -u <service> -n 100 --no-pager\n"
        "• Reload the definitions: sudo systemctl daemon-reload",
    ),
    ErrorPattern(
        r"(Unit .* not found|Unit file .* does not exist)",
        "The systemd unit does not exist",
        "The service file is not installed.\n"
        "• Check that the module's package is installed.\n"
        "• Check: systemctl list-unit-files | grep <name>\n"
        "• Reinstall the module if needed.",
    ),

    # ─── User / shell ────────────────────────────────────────────────
    ErrorPattern(
        r"(useradd.*already exists|usermod.*does not exist|"
        r"groupadd.*already exists)",
        "User or group conflict",
        "The user or group already exists, or is missing.\n"
        "• Check what exists: getent passwd <user> / getent group <group>\n"
        "• Remove a stale entry if needed: sudo userdel / groupdel\n"
        "• Or skip the creation if it is already there.",
    ),

    # ─── Generic process errors ──────────────────────────────────────
    ErrorPattern(
        r"\b(Killed|received signal 9|out of memory|OOM)\b",
        "The process was killed (out of memory, or a signal)",
        "The script was stopped by the kernel or by hand.\n"
        "• Check the memory: free -h\n"
        "• Read the OOM killer log: dmesg | grep -i 'killed process'\n"
        "• Close heavy programs and try again.",
    ),
    ErrorPattern(
        r"(syntax error|unexpected end of file|unexpected token)",
        "Syntax error in a bash script",
        "The script has a syntax error, which may mean a corrupt installation.\n"
        "• Check it: bash -n <script>.sh\n"
        "• Reinstall the dtu-setup package.\n"
        "• Send a bug report to the maintainers.",
    ),
    ErrorPattern(
        r"(set -e|errexit).*line \d+",
        "The script stopped at the first error (set -e)",
        "The script exits on the first failure. The line number points at the problem.\n"
        "• Read the full output for the command just before the exit.\n"
        "• Send the output to IT support.",
    ),

    # ─── Onboarding / first-login ────────────────────────────────────
    ErrorPattern(
        r"(kdialog.*not found|zenity.*not found|No GUI dialog tool)",
        "No dialog tool installed",
        "Neither kdialog nor zenity is installed, and the first login needs one.\n"
        "• Ubuntu: sudo apt-get install -y zenity   (GNOME) or kdialog (KDE)\n"
    ),

    # ─── Generic catch-alls (lowest priority – ordered last) ─────────
    ErrorPattern(
        r"(connection reset by peer|broken pipe|\bEPIPE\b)",
        "The connection dropped mid-transfer",
        "The other end closed the connection unexpectedly.\n"
        "• Try again in a moment.\n"
        "• If it keeps happening, check the network, proxy and firewall.\n"
        "• Check that the server is not overloaded.",
    ),
    ErrorPattern(
        r"(timeout|timed out)",
        "Operation timed out",
        "A network or system operation took too long.\n"
        "• Check the network speed and latency.\n"
        "• On VPN, try a different gateway.\n"
        "• Run the module again. It may be temporary load.",
    ),
]


def _classify(output: str) -> tuple[str, str]:
    """Return (title, fix) for the first matching pattern, or generic fallback."""
    for entry in ERROR_PATTERNS:
        if re.search(entry.pattern, output, re.IGNORECASE | re.MULTILINE):
            return entry.title, entry.fix
    return (
        "Unknown error",
        "The module failed without matching any known error pattern.\n"
        "• Read the full output below for details.\n"
        "• Try running the script directly in a terminal for more context.\n"
        "• Send the error report to IT support with the button below.",
    )


def _tail(text: str, max_lines: int = 40) -> str:
    lines = text.rstrip().splitlines()
    if len(lines) <= max_lines:
        return "\n".join(lines)
    return "[... {} earlier lines truncated ...]\n".format(len(lines) - max_lines) + \
        "\n".join(lines[-max_lines:])


class ErrorDialog(QDialog):
    """Modal dialog showing error output + suggested fix + copy button."""

    def __init__(
        self,
        parent=None,
        *,
        module_title: str,
        module_id: str,
        script_name: str,
        exit_code: int,
        output: str,
        batch_mode: bool = False,
    ):
        super().__init__(parent)
        # Hvad brugeren valgte. "close" for en enkelt modulkørsel, hvor der
        # ikke er en kø at gøre noget ved.
        self.choice = "close"
        self._batch_mode = batch_mode
        self.setWindowTitle(f"Error: {module_title}")
        self.setMinimumSize(720, 540)

        self._module_title = module_title
        self._module_id = module_id
        self._script_name = script_name
        self._exit_code = exit_code
        self._output = output
        self._diagnosis_title, self._fix_text = _classify(output)

        pal = palette()
        layout = QVBoxLayout(self)

        # Header
        header = QLabel(f"❌  <b>{module_title}</b> failed (exit code {exit_code})")
        header_font = QFont()
        header_font.setPointSize(13)
        header.setFont(header_font)
        layout.addWidget(header)

        # Diagnosis
        diag_label = QLabel(f"<b>Diagnosis:</b> {self._diagnosis_title}")
        diag_label.setWordWrap(True)
        layout.addWidget(diag_label)

        # Fix suggestion
        fix_label = QLabel("<b>Suggested fix:</b>")
        layout.addWidget(fix_label)

        fix_view = QPlainTextEdit()
        fix_view.setReadOnly(True)
        fix_view.setPlainText(self._fix_text)
        fix_view.setMaximumHeight(140)
        fix_view.setStyleSheet(
            f"QPlainTextEdit {{ background: {pal.hint_bg}; color: {pal.hint_fg}; "
            f"border: 1px solid {pal.hint_border}; padding: 6px; }}"
        )
        layout.addWidget(fix_view)

        # Error output
        out_label = QLabel("<b>Error output (last lines):</b>")
        layout.addWidget(out_label)

        out_view = QPlainTextEdit()
        out_view.setReadOnly(True)
        out_view.setPlainText(_tail(output))
        mono = QFont("Monospace")
        mono.setStyleHint(QFont.StyleHint.TypeWriter)
        out_view.setFont(mono)
        out_view.setStyleSheet(
            f"QPlainTextEdit {{ background: {pal.console_bg}; color: {pal.console_fg}; "
            f"border: 1px solid {pal.console_border}; padding: 6px; }}"
        )
        layout.addWidget(out_view, stretch=1)

        # Helpdesk contact
        helpdesk_label = QLabel(
            f"IT support: <a href='{_HELPDESK_URL}'>{_HELPDESK_URL}</a>"
            f" &nbsp;·&nbsp; <a href='mailto:{_HELPDESK_EMAIL}'>{_HELPDESK_EMAIL}</a>"
        )
        helpdesk_label.setOpenExternalLinks(True)
        helpdesk_label.setStyleSheet(
            f"font-size: 11px; color: {pal.text_dim}; margin-top: 4px;"
        )
        layout.addWidget(helpdesk_label)

        # Buttons
        btn_row = QHBoxLayout()
        copy_btn = QPushButton("📋  Copy Error Message and Fix")
        copy_btn.setStyleSheet(
            "QPushButton { padding: 8px 16px; font-weight: bold; "
            f"background: {pal.info_bg}; color: {pal.info_fg}; border-radius: 4px; }}"
            f"QPushButton:hover {{ background: {pal.info_hover_bg}; }}"
        )
        copy_btn.clicked.connect(self._copy_to_clipboard)
        self._copy_btn = copy_btn
        btn_row.addWidget(copy_btn)

        btn_row.addStretch()

        if batch_mode:
            # Midt i en samlet kørsel er "Luk" ikke et svar: køen skal vide
            # om modulet skal forsøges igen, springes over, eller om resten
            # skal droppes. Før kørte den videre af sig selv, så en fejl midt
            # i Run All forsvandt op i loggen.
            retry_btn = QPushButton("↻  Try again")
            retry_btn.setDefault(True)
            retry_btn.clicked.connect(lambda: self._choose("retry"))
            btn_row.addWidget(retry_btn)

            skip_btn = QPushButton("Skip")
            skip_btn.clicked.connect(lambda: self._choose("skip"))
            btn_row.addWidget(skip_btn)

            abort_btn = QPushButton("Stop the rest")
            abort_btn.clicked.connect(lambda: self._choose("abort"))
            btn_row.addWidget(abort_btn)
        else:
            bb = QDialogButtonBox(QDialogButtonBox.StandardButton.Close)
            bb.rejected.connect(self.reject)
            bb.accepted.connect(self.accept)
            btn_row.addWidget(bb)

        layout.addLayout(btn_row)

    def _choose(self, choice: str) -> None:
        self.choice = choice
        self.accept()

    def closeEvent(self, event):  # noqa: N802 - Qt-navn
        """Luk på X'et er ikke "fortsæt som om intet var hændt".

        I en samlet kørsel betyder et lukket vindue uden valg, at brugeren
        ikke tog stilling. Det sikreste er at springe modulet over frem for
        at gentage det eller droppe resten uden at være blevet spurgt.
        """
        if self._batch_mode and self.choice == "close":
            self.choice = "skip"
        super().closeEvent(event)

    def _build_report(self) -> str:
        """Build the full text that gets copied to the clipboard."""
        try:
            distro = platform.freedesktop_os_release().get("PRETTY_NAME", platform.platform())
        except Exception:
            distro = platform.platform()

        return (
            f"DTU Setup – error report\n"
            f"========================\n"
            f"Time        : {datetime.now().isoformat(timespec='seconds')}\n"
            f"Module      : {self._module_title} ({self._module_id})\n"
            f"Script      : {self._script_name}\n"
            f"Exit code   : {self._exit_code}\n"
            f"OS          : {distro}\n"
            f"Hostname    : {platform.node()}\n"
            f"\n"
            f"Diagnosis\n"
            f"---------\n"
            f"{self._diagnosis_title}\n"
            f"\n"
            f"Suggested fix\n"
            f"-------------\n"
            f"{self._fix_text}\n"
            f"\n"
            f"Error output\n"
            f"------------\n"
            f"{_tail(self._output, max_lines=80)}\n"
            f"\n"
            f"IT support\n"
            f"----------\n"
            f"URL   : {_HELPDESK_URL}\n"
            f"Email : {_HELPDESK_EMAIL}\n"
        )

    def _copy_to_clipboard(self) -> None:
        clipboard = QGuiApplication.clipboard()
        if clipboard is None:
            return
        clipboard.setText(self._build_report())
        self._copy_btn.setText("✓  Copied to the clipboard")
        # Reset label after a short delay
        from PyQt6.QtCore import QTimer
        QTimer.singleShot(
            2500,
            lambda: self._copy_btn.setText("📋  Copy Error Message and Fix"),
        )
