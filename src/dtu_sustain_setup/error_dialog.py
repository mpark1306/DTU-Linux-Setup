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
    ErrorPattern(
        r"pkexec.*(dismissed|cancelled|not authorized|Authorization failed)",
        "Authentication cancelled or denied",
        "PolicyKit-godkendelsen blev afvist eller annulleret.\n"
        "• Tryk 'Authenticate' i password-prompten.\n"
        "• Tjek at du er IT-admin (medlem af gruppen 'sus-itadm') eller at "
        "polkit-reglerne er installeret (kør 'PolicyKit'-modulet først).",
    ),
    ErrorPattern(
        r"(NT_STATUS_LOGON_FAILURE|LOGON_FAILURE|mount error\(13\)|Permission denied.*cifs|"
        r"NT_STATUS_ACCESS_DENIED)",
        "Forkert brugernavn/kodeord til netværksdrev",
        "WIN-domæne loginet blev afvist af serveren.\n"
        "• Verificér brugernavn er dit WIN-username (ikke email).\n"
        "• Prøv at logge ind på https://portal.office.com med samme creds.\n"
        "• Hvis kodeordet er udløbet: skift det først via DTU password-portal.",
    ),
    ErrorPattern(
        r"(NT_STATUS_HOST_UNREACHABLE|NT_STATUS_IO_TIMEOUT|Host is down|"
        r"Connection timed out|Network is unreachable|No route to host)",
        "Kan ikke nå serveren",
        "Maskinen kan ikke nå netværksserveren.\n"
        "• Tjek at du er på DTU-netværket eller har DTU VPN aktiveret.\n"
        "• Test forbindelse: ping <fileserver>.win.dtu.dk\n"
        "• Hvis du er hjemmefra: start GlobalProtect / VPN først.",
    ),
    ErrorPattern(
        r"(NT_STATUS_BAD_NETWORK_NAME|mount error\(2\):|No such file or directory.*\\\\)",
        "Netværksshare findes ikke",
        "Den angivne share kunne ikke findes på serveren.\n"
        "• Verificér at dit AIT/Sustain-departement er valgt korrekt i dropdown.\n"
        "• For AIT M-drev: brugermappen skal eksistere i Users0-9 strukturen.\n"
        "• Kontakt IT-support hvis dit netværksdrev mangler.",
    ),
    ErrorPattern(
        r"(realm.*not enrolled|sssd.*could not authenticate|kinit.*Preauthentication failed|"
        r"kinit.*Client not found)",
        "Domæne-join eller Kerberos fejl",
        "Domæne-join eller Kerberos-godkendelse fejlede.\n"
        "• Kør 'Domain Join'-modulet først (skal ske før netværksdrev).\n"
        "• Tjek systemtid: timedatectl status — skal være synkroniseret.\n"
        "• Verificér DNS peger på DTU's nameservere.",
    ),
    ErrorPattern(
        r"(Could not resolve host|Temporary failure in name resolution|Name or service not known)",
        "DNS-opslag fejlede",
        "Maskinen kan ikke slå hostnames op via DNS.\n"
        "• Tjek netværksforbindelse: ip addr / nmcli device status\n"
        "• Test DNS: nslookup <fileserver>.win.dtu.dk\n"
        "• Hvis du er på DTUSecure: vent et øjeblik på at WiFi forbinder.",
    ),
    ErrorPattern(
        r"(E: Could not get lock|dpkg was interrupted|apt.*Unable to lock)",
        "APT er låst af en anden proces",
        "En anden pakke-handling kører eller er afbrudt.\n"
        "• Vent på at automatiske opdateringer afslutter (op til 5 min).\n"
        "• Hvis problemet fortsætter:\n"
        "    sudo dpkg --configure -a\n"
        "    sudo apt-get -f install",
    ),
    ErrorPattern(
        r"(E: Unable to locate package|Unable to fetch some archives|"
        r"404\s+Not Found.*archive\.ubuntu)",
        "Pakke kunne ikke hentes",
        "APT kunne ikke finde eller downloade pakken.\n"
        "• Opdater pakke-cache: sudo apt-get update\n"
        "• Tjek netværksforbindelse til archive.ubuntu.com.\n"
        "• Verificér at /etc/apt/sources.list peger på korrekte repos.",
    ),
    ErrorPattern(
        r"(zypper.*System management is locked|zypp.*PackageKit is running|"
        r"another instance of zypper)",
        "Zypper er låst af en anden proces",
        "Pakkesystemet er optaget.\n"
        "• Vent på at PackageKit/automatiske opdateringer afslutter.\n"
        "• Tjek: ps aux | grep -E 'zypper|packagekit'\n"
        "• Hvis nødvendigt: sudo killall packagekitd && sudo zypper refresh",
    ),
    ErrorPattern(
        r"(nmcli.*Error.*Connection activation failed|Secrets were required|"
        r"802-1x.*EAP authentication failed)",
        "WiFi-forbindelse fejlede",
        "DTUSecure WiFi kunne ikke forbinde.\n"
        "• Verificér WIN-brugernavn og kodeord.\n"
        "• Tjek at du er fysisk i nærheden af DTUSecure-netværket.\n"
        "• Vis NM logs: journalctl -u NetworkManager -n 50",
    ),
    ErrorPattern(
        r"(cups.*Forbidden|lpadmin.*Not authorized|cupsd.*permission denied)",
        "CUPS afviste handlingen",
        "CUPS tillod ikke printer-konfigurationen.\n"
        "• Tjek at brugeren er i 'lpadmin'-gruppen: groups\n"
        "• Verificér at CUPS kører: systemctl status cups\n"
        "• Restart CUPS: sudo systemctl restart cups",
    ),
    ErrorPattern(
        r"(command not found|No such file or directory.*\.sh)",
        "Manglende kommando eller script",
        "En påkrævet kommando eller script-fil mangler på systemet.\n"
        "• Kontrollér at alle DTU-setup pakker er installeret.\n"
        "• Hvis det er et eksternt værktøj: installer det med apt/zypper.\n"
        "• Kør modulets script direkte i terminalen for fuld output.",
    ),
    ErrorPattern(
        r"(No space left on device|disk full|ENOSPC)",
        "Disken er fuld",
        "Der er ikke plads tilbage på filsystemet.\n"
        "• Tjek diskplads: df -h\n"
        "• Ryd cache: sudo apt-get clean / sudo zypper clean -a\n"
        "• Tøm gamle journaler: sudo journalctl --vacuum-time=7d",
    ),

    # ─── Authentication / credentials ────────────────────────────────
    ErrorPattern(
        r"(Password has expired|password expired|CHANGE_PASSWORD_REQUIRED|"
        r"NT_STATUS_PASSWORD_EXPIRED|NT_STATUS_PASSWORD_MUST_CHANGE)",
        "WIN-kodeord er udløbet",
        "Dit WIN-domæne kodeord er udløbet og skal skiftes.\n"
        "• Skift det via DTU password-portal: https://password.dtu.dk\n"
        "• Eller skift via en Windows-maskine med Ctrl+Alt+Del → 'Change a password'.\n"
        "• Kør modulet igen efter password-skift.",
    ),
    ErrorPattern(
        r"(NT_STATUS_ACCOUNT_LOCKED_OUT|account.*locked)",
        "Konto er låst",
        "Din WIN-konto er midlertidigt låst pga. for mange forkerte forsøg.\n"
        "• Vent 15-30 minutter og prøv igen.\n"
        "• Kontakt DTU IT for at få den låst op manuelt.",
    ),
    ErrorPattern(
        r"(NT_STATUS_ACCOUNT_DISABLED|NT_STATUS_ACCOUNT_EXPIRED)",
        "Konto er deaktiveret eller udløbet",
        "Din WIN-domæne konto er deaktiveret eller udløbet.\n"
        "• Kontakt DTU IT-support for at få kontoen reaktiveret.\n"
        "• Hvis du er ny ansat: bekræft at AD-kontoen er fuldt provisioneret.",
    ),
    ErrorPattern(
        r"(NT_STATUS_NOLOGON_WORKSTATION_TRUST_ACCOUNT|trust relationship.*failed|"
        r"machine account password)",
        "Maskinens domænetillid er brudt",
        "Maskinens computer-konto har mistet tillid til AD.\n"
        "• Re-join domænet: kør 'Domain Join'-modulet igen.\n"
        "• Eller manuelt: sudo realm leave && sudo realm join win.dtu.dk",
    ),
    ErrorPattern(
        r"(authentication token manipulation error|pam_unix.*authentication failure)",
        "PAM-godkendelse fejlede",
        "Systemets PAM-stack afviste login.\n"
        "• Kontrollér /etc/pam.d/common-auth og /etc/nsswitch.conf.\n"
        "• Restart SSSD: sudo systemctl restart sssd\n"
        "• Tjek logs: journalctl -u sssd -n 100",
    ),

    # ─── Kerberos / clock skew ───────────────────────────────────────
    ErrorPattern(
        r"(Clock skew too great|KRB_AP_ERR_SKEW|krb5.*time.*offset)",
        "Systemtid er ude af synk (Kerberos)",
        "Maskinens ur afviger for meget fra domæne-controlleren.\n"
        "• Aktivér NTP: sudo timedatectl set-ntp true\n"
        "• Tjek status: timedatectl status\n"
        "• Tving sync: sudo systemctl restart systemd-timesyncd",
    ),
    ErrorPattern(
        r"(KDC_ERR_S_PRINCIPAL_UNKNOWN|Server not found in Kerberos database)",
        "Kerberos service principal mangler",
        "AD kender ikke den service du prøver at få ticket til.\n"
        "• Verificér SPN i AD (kontakt IT-support).\n"
        "• Tjek /etc/krb5.conf — default_realm skal være WIN.DTU.DK",
    ),

    # ─── DNS & network specifics ─────────────────────────────────────
    ErrorPattern(
        r"(NetworkManager.*not running|nmcli.*Error.*NetworkManager is not running)",
        "NetworkManager kører ikke",
        "NetworkManager er ikke aktiv – WiFi/netværk kan ikke konfigureres.\n"
        "• Start service: sudo systemctl start NetworkManager\n"
        "• Aktivér ved boot: sudo systemctl enable NetworkManager\n"
        "• Tjek status: systemctl status NetworkManager",
    ),
    ErrorPattern(
        r"(SSL certificate problem|certificate verify failed|self signed certificate|"
        r"unable to get local issuer certificate)",
        "TLS/SSL certifikat-fejl",
        "En TLS-forbindelse blev afvist pga. certifikat.\n"
        "• Opdater root-certifikater: sudo update-ca-certificates  (Ubuntu)\n"
        "  eller: sudo update-ca-certificates -f  (openSUSE)\n"
        "• Tjek systemtid (forkert tid → ugyldigt certifikat).\n"
        "• Hvis bag corporate proxy: importér intern CA i /usr/local/share/ca-certificates/",
    ),

    # ─── SMB / CIFS specifics ────────────────────────────────────────
    ErrorPattern(
        r"(mount error\(112\):|Host is down.*cifs|cifs_mount failed.*-112)",
        "SMB-host svarer ikke",
        "Filserveren svarer ikke på SMB-protokollen.\n"
        "• Vent et øjeblik – serveren kan være under genstart.\n"
        "• Test fra terminalen: smbclient -L //<fileserver>/ -U <bruger>\n"
        "• Hvis du er på VPN: tjek at SMB-port (445) ikke blokeres.",
    ),
    ErrorPattern(
        r"(mount error\(95\):|Operation not supported.*cifs|"
        r"CIFS VFS:.*SMB.*unsupported)",
        "SMB-protokol-version ikke understøttet",
        "Klient og server kan ikke blive enige om SMB-version.\n"
        "• Føj 'vers=3.0' til mount-options i /etc/fstab.\n"
        "• Eller prøv 'vers=2.1' for ældre filservere.\n"
        "• Tjek: sudo mount -t cifs ... -o vers=3.0,...",
    ),
    ErrorPattern(
        r"(mount\.cifs.*not found|mount: unknown filesystem type 'cifs')",
        "cifs-utils mangler",
        "CIFS-pakken er ikke installeret.\n"
        "• Ubuntu: sudo apt-get install -y cifs-utils\n"
        "• openSUSE: sudo zypper install -y cifs-utils",
    ),
    ErrorPattern(
        r"(smbclient.*command not found|samba-client.*not installed)",
        "Samba-client mangler",
        "smbclient er ikke installeret – kræves til AIT M-drev opslag.\n"
        "• Ubuntu: sudo apt-get install -y smbclient\n"
        "• openSUSE: sudo zypper install -y samba-client",
    ),
    ErrorPattern(
        r"(target is busy|umount.*device is busy)",
        "Filsystem er optaget (kan ikke afmonteres)",
        "Et åbent filhåndtag forhindrer afmontering.\n"
        "• Find proces der bruger det: sudo lsof +D /mnt/Qdrev\n"
        "• Eller: sudo fuser -m /mnt/Qdrev\n"
        "• Luk programmet og prøv igen, eller brug: sudo umount -l /mnt/Qdrev",
    ),

    # ─── Domain join specifics ───────────────────────────────────────
    ErrorPattern(
        r"(realm.*Already joined|Realm.*is already configured)",
        "Allerede joinet til domænet",
        "Maskinen er allerede medlem af WIN.DTU.DK.\n"
        "• Spring 'Domain Join'-modulet over.\n"
        "• Hvis du vil re-joine: sudo realm leave win.dtu.dk først.",
    ),
    ErrorPattern(
        r"(realm.*Cannot find a matching realm|No such realm found)",
        "Domænet kan ikke findes",
        "realmd kan ikke discover WIN.DTU.DK.\n"
        "• Tjek DNS peger på DTU's nameservere (resolvectl status).\n"
        "• Test manuelt: realm discover win.dtu.dk\n"
        "• Hvis du er off-campus: tilkobl VPN først.",
    ),
    ErrorPattern(
        r"(adcli.*Couldn't authenticate|adcli.*Insufficient permissions)",
        "Domain join nægtet af AD",
        "Brugeren har ikke ret til at joine maskiner til AD.\n"
        "• Brug en konto med 'Domain Admin' eller delegeret join-ret.\n"
        "• Kontakt DTU IT for join-credentials til pilot-OU.",
    ),

    # ─── PolicyKit / sudo ────────────────────────────────────────────
    ErrorPattern(
        r"(polkit.*not authorized|org\.freedesktop\.PolicyKit.*Error|"
        r"Operation.*not permitted by polkit)",
        "PolicyKit-regel mangler eller blokerer",
        "PolicyKit nægtede handlingen for denne bruger.\n"
        "• Kør 'PolicyKit'-modulet for at installere domæne-regler.\n"
        "• Verificér regler: ls /etc/polkit-1/rules.d/\n"
        "• Tjek polkit logs: journalctl -u polkit -n 50",
    ),
    ErrorPattern(
        r"(sudo: a password is required|sudo:.*incorrect password|"
        r"is not in the sudoers file)",
        "Sudo-rettigheder mangler",
        "Brugeren er ikke i sudoers eller indtastede forkert kodeord.\n"
        "• IT-admin: tilføj brugeren til 'sudo' (Ubuntu) eller 'wheel' (openSUSE).\n"
        "• Kør: sudo usermod -aG sudo <bruger>",
    ),

    # ─── PackageKit / Flatpak / fwupd ────────────────────────────────
    ErrorPattern(
        r"(PackageKit.*org\.freedesktop\.PackageKit\.Failed|"
        r"pkcon.*Fatal error|PK_ERROR_)",
        "PackageKit-fejl",
        "PackageKit-daemonen returnerede en fejl.\n"
        "• Restart: sudo systemctl restart packagekit\n"
        "• Tjek log: journalctl -u packagekit -n 50\n"
        "• Som fallback: brug apt/zypper direkte i terminalen.",
    ),
    ErrorPattern(
        r"(flatpak.*error|Could not find ref.*flatpak|No remote refs found)",
        "Flatpak-fejl",
        "Flatpak kunne ikke installere eller finde appen.\n"
        "• Opdater remotes: flatpak update --appstream\n"
        "• Tilføj Flathub: flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo\n"
        "• Tjek netværk – Flathub kræver internet.",
    ),
    ErrorPattern(
        r"(fwupdmgr.*failed|fwupd.*Authentication required|"
        r"fwupd.*UEFI capsule)",
        "Firmware-opdatering fejlede",
        "fwupd kunne ikke opdatere firmware.\n"
        "• Tjek understøttelse: fwupdmgr get-devices\n"
        "• UEFI capsule kræver Secure Boot deaktiveret på nogle systemer.\n"
        "• Logs: journalctl -u fwupd -n 100",
    ),
    ErrorPattern(
        r"(snap.*error|cannot install.*snap|snapd is not running)",
        "Snap-fejl",
        "Snap-pakkesystemet svigtede.\n"
        "• Start snapd: sudo systemctl start snapd\n"
        "• Tjek netværksforbindelse til api.snapcraft.io.\n"
        "• Som workaround: brug apt eller flatpak.",
    ),
    ErrorPattern(
        r"(GPG error|NO_PUBKEY|public key is not available|"
        r"signatures couldn't be verified)",
        "GPG-nøgle mangler for repository",
        "Pakke-repository er ikke betroet pga. manglende GPG-nøgle.\n"
        "• Ubuntu: sudo apt-key adv --recv-keys <KEY_ID>  (ældre)\n"
        "  eller importer nøglen til /etc/apt/keyrings/.\n"
        "• openSUSE: sudo rpm --import <key-url>",
    ),
    ErrorPattern(
        r"(Conflicting requests|file conflicts|nothing provides|"
        r"have unmet dependencies)",
        "Pakke-afhængighedskonflikt",
        "Pakke-løseren kunne ikke finde en gyldig kombination.\n"
        "• Ubuntu: sudo apt-get -f install   (fix broken)\n"
        "• openSUSE: sudo zypper verify   (find/fix konflikter)\n"
        "• Som sidste udvej: sudo zypper dup --force-resolution",
    ),

    # ─── Microsoft Defender ──────────────────────────────────────────
    ErrorPattern(
        r"(mdatp.*not licensed|mdatp.*not onboarded|onboarding.*failed)",
        "Defender onboarding fejlede",
        "Microsoft Defender for Endpoint kunne ikke onboarde.\n"
        "• Verificér onboarding-script (.py) er gyldigt og signeret.\n"
        "• Tjek mdatp-status: mdatp health\n"
        "• Logs: /var/log/microsoft/mdatp/",
    ),
    ErrorPattern(
        r"(mdatp.*conflicts with|conflicting AV product|another antivirus)",
        "Defender konflikt med anden AV",
        "Et andet antivirus-produkt forhindrer Defender i at køre.\n"
        "• Afinstaller ClamAV / andre AV-pakker først.\n"
        "• Kontakt IT-support hvis problemet fortsætter.",
    ),

    # ─── Filesystem / permissions ────────────────────────────────────
    ErrorPattern(
        r"(Read-only file system|EROFS)",
        "Filsystem er read-only",
        "Filsystemet er monteret read-only – kan være pga. fejl ved boot.\n"
        "• Genmonter rw: sudo mount -o remount,rw /\n"
        "• Tjek dmesg for diskfejl: dmesg | tail -50\n"
        "• Hvis disken har fejl: kør sudo fsck efter genstart.",
    ),
    ErrorPattern(
        r"(Permission denied(?!.*cifs)|EACCES|Operation not permitted)",
        "Adgang nægtet (rettighedsfejl)",
        "En fil- eller systemoperation blev nægtet pga. rettigheder.\n"
        "• Tjek om scriptet kræver sudo/pkexec.\n"
        "• Kontrollér ejerskab: ls -la <sti>\n"
        "• Hvis SELinux/AppArmor er aktiv: tjek audit-log: sudo ausearch -m avc",
    ),
    ErrorPattern(
        r"(Input/output error|EIO|Buffer I/O error)",
        "I/O-fejl (muligvis disk-fejl)",
        "Kernen rapporterede en I/O-fejl – kan indikere hardwareproblem.\n"
        "• Tjek SMART-status: sudo smartctl -a /dev/sda\n"
        "• Se kernel-beskeder: dmesg | grep -i error\n"
        "• Backup vigtige data og kontakt IT-support.",
    ),

    # ─── Build / git / curl ──────────────────────────────────────────
    ErrorPattern(
        r"(curl.*\(6\) Could not resolve host|wget.*unable to resolve)",
        "Download fejlede (DNS)",
        "curl/wget kunne ikke slå target-host op.\n"
        "• Verificér netværksforbindelse: ping 1.1.1.1\n"
        "• Tjek DNS: cat /etc/resolv.conf\n"
        "• Hvis bag proxy: sæt $http_proxy / $https_proxy.",
    ),
    ErrorPattern(
        r"(curl.*\(7\) Failed to connect|curl.*Connection refused)",
        "HTTP-forbindelse afvist",
        "Serveren afviste forbindelsen.\n"
        "• Tjek at servicen kører på destinationen.\n"
        "• Hvis bag firewall: tjek tilladte udgående porte.\n"
        "• Test med: curl -v <url>",
    ),
    ErrorPattern(
        r"(curl.*\(60\) SSL certificate|curl.*\(35\) SSL connect error)",
        "curl SSL/TLS fejl",
        "curl kunne ikke etablere TLS-forbindelse.\n"
        "• Opdater ca-certificates pakken.\n"
        "• Tjek systemtid – forkert tid → ugyldigt cert.\n"
        "• Hvis intern CA: importér til system trust store.",
    ),
    ErrorPattern(
        r"(git.*fatal:.*could not read Username|Authentication failed for.*github)",
        "Git authentication fejlede",
        "Git kunne ikke autentificere mod remote.\n"
        "• Brug HTTPS med Personal Access Token (ikke kodeord).\n"
        "• Eller skift til SSH: git remote set-url origin git@github.com:...\n"
        "• Tjek credentials helper: git config --global credential.helper",
    ),

    # ─── systemd ─────────────────────────────────────────────────────
    ErrorPattern(
        r"(Failed to (start|enable|reload).*\.service|Job for .* failed because)",
        "systemd-service fejlede",
        "En systemd-unit kunne ikke startes/aktiveres.\n"
        "• Vis status: systemctl status <service>\n"
        "• Vis logs: journalctl -u <service> -n 100 --no-pager\n"
        "• Reload definitioner: sudo systemctl daemon-reload",
    ),
    ErrorPattern(
        r"(Unit .* not found|Unit file .* does not exist)",
        "systemd-unit findes ikke",
        "Den ønskede service-fil er ikke installeret.\n"
        "• Verificér at modulets pakke er installeret.\n"
        "• Tjek: systemctl list-unit-files | grep <name>\n"
        "• Genindstaller modulet om nødvendigt.",
    ),

    # ─── User / shell ────────────────────────────────────────────────
    ErrorPattern(
        r"(useradd.*already exists|usermod.*does not exist|"
        r"groupadd.*already exists)",
        "Bruger/gruppe-konflikt",
        "Brugeren eller gruppen findes allerede / mangler.\n"
        "• Tjek eksisterende: getent passwd <bruger> / getent group <gruppe>\n"
        "• Slet evt. gammel post: sudo userdel/groupdel\n"
        "• Eller spring oprettelse over hvis allerede til stede.",
    ),

    # ─── Generic process errors ──────────────────────────────────────
    ErrorPattern(
        r"(Killed|received signal 9|out of memory|OOM)",
        "Processen blev dræbt (OOM eller signal)",
        "Scriptet blev afbrudt af kernen eller manuelt.\n"
        "• Tjek hukommelse: free -h\n"
        "• Se OOM-killer log: dmesg | grep -i 'killed process'\n"
        "• Luk tunge programmer og prøv igen.",
    ),
    ErrorPattern(
        r"(syntax error|unexpected end of file|unexpected token)",
        "Syntaksfejl i bash-script",
        "Scriptet har en syntaks-fejl – muligvis korrupt installation.\n"
        "• Verificér: bash -n <script>.sh\n"
        "• Geninstallér dtu-setup pakken.\n"
        "• Send fejlrapport til vedligeholderne.",
    ),
    ErrorPattern(
        r"(set -e|errexit).*line \d+",
        "Script stoppet pga. fejl (set -e)",
        "Scriptet exit'er ved første fejl. Linjenummeret peger på problem-stedet.\n"
        "• Læs den fulde output for kommandoen lige før exit.\n"
        "• Send fejlrapport til IT-support med output.",
    ),

    # ─── Onboarding / first-login ────────────────────────────────────
    ErrorPattern(
        r"(kdialog.*not found|zenity.*not found|No GUI dialog tool)",
        "Mangler dialog-værktøj",
        "Hverken kdialog eller zenity er installeret – nødvendigt for første login.\n"
        "• Ubuntu: sudo apt-get install -y zenity   (GNOME) eller kdialog (KDE)\n"
        "• openSUSE: sudo zypper install -y zenity",
    ),

    # ─── Generic catch-alls (lowest priority – ordered last) ─────────
    ErrorPattern(
        r"(connection reset by peer|broken pipe|EPIPE)",
        "Forbindelse afbrudt midt i overførsel",
        "Den anden ende lukkede forbindelsen uventet.\n"
        "• Prøv igen om et øjeblik.\n"
        "• Hvis det sker gentagne gange: tjek netværk/proxy/firewall.\n"
        "• Verificér at server-tjenesten ikke er overbelastet.",
    ),
    ErrorPattern(
        r"(timeout|timed out)",
        "Operation timeout",
        "En netværks- eller systemoperation tog for lang tid.\n"
        "• Tjek netværkshastighed og latency.\n"
        "• Hvis du er på VPN: prøv en anden gateway.\n"
        "• Kør modulet igen – kan være midlertidig overbelastning.",
    ),
]


def _classify(output: str) -> tuple[str, str]:
    """Return (title, fix) for the first matching pattern, or generic fallback."""
    for entry in ERROR_PATTERNS:
        if re.search(entry.pattern, output, re.IGNORECASE | re.MULTILINE):
            return entry.title, entry.fix
    return (
        "Ukendt fejl",
        "Modulet fejlede uden et genkendt fejlmønster.\n"
        "• Læs den fulde output nedenfor for detaljer.\n"
        "• Prøv at køre scriptet direkte i en terminal for mere kontekst.\n"
        "• Send fejl-rapporten til IT-support via knappen nedenfor.",
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
    ):
        super().__init__(parent)
        self.setWindowTitle(f"Fejl: {module_title}")
        self.setMinimumSize(720, 540)

        self._module_title = module_title
        self._module_id = module_id
        self._script_name = script_name
        self._exit_code = exit_code
        self._output = output
        self._diagnosis_title, self._fix_text = _classify(output)

        layout = QVBoxLayout(self)

        # Header
        header = QLabel(f"❌  <b>{module_title}</b> fejlede (exit code {exit_code})")
        header_font = QFont()
        header_font.setPointSize(13)
        header.setFont(header_font)
        layout.addWidget(header)

        # Diagnosis
        diag_label = QLabel(f"<b>Diagnose:</b> {self._diagnosis_title}")
        diag_label.setWordWrap(True)
        layout.addWidget(diag_label)

        # Fix suggestion
        fix_label = QLabel("<b>Foreslået løsning:</b>")
        layout.addWidget(fix_label)

        fix_view = QPlainTextEdit()
        fix_view.setReadOnly(True)
        fix_view.setPlainText(self._fix_text)
        fix_view.setMaximumHeight(140)
        fix_view.setStyleSheet(
            "QPlainTextEdit { background: #fff8dc; border: 1px solid #d4a017; "
            "padding: 6px; }"
        )
        layout.addWidget(fix_view)

        # Error output
        out_label = QLabel("<b>Fejl-output (sidste linjer):</b>")
        layout.addWidget(out_label)

        out_view = QPlainTextEdit()
        out_view.setReadOnly(True)
        out_view.setPlainText(_tail(output))
        mono = QFont("Monospace")
        mono.setStyleHint(QFont.StyleHint.TypeWriter)
        out_view.setFont(mono)
        out_view.setStyleSheet(
            "QPlainTextEdit { background: #1e1e1e; color: #f0f0f0; "
            "border: 1px solid #555; padding: 6px; }"
        )
        layout.addWidget(out_view, stretch=1)

        # Helpdesk contact
        helpdesk_label = QLabel(
            f"IT-support: <a href='{_HELPDESK_URL}'>{_HELPDESK_URL}</a>"
            f" &nbsp;·&nbsp; <a href='mailto:{_HELPDESK_EMAIL}'>{_HELPDESK_EMAIL}</a>"
        )
        helpdesk_label.setOpenExternalLinks(True)
        helpdesk_label.setStyleSheet("font-size: 11px; color: #555; margin-top: 4px;")
        layout.addWidget(helpdesk_label)

        # Buttons
        btn_row = QHBoxLayout()
        copy_btn = QPushButton("📋  Copy Error Message and Fix")
        copy_btn.setStyleSheet(
            "QPushButton { padding: 8px 16px; font-weight: bold; "
            "background: #0d6efd; color: white; border-radius: 4px; }"
            "QPushButton:hover { background: #0b5ed7; }"
        )
        copy_btn.clicked.connect(self._copy_to_clipboard)
        self._copy_btn = copy_btn
        btn_row.addWidget(copy_btn)

        btn_row.addStretch()

        bb = QDialogButtonBox(QDialogButtonBox.StandardButton.Close)
        bb.rejected.connect(self.reject)
        bb.accepted.connect(self.accept)
        btn_row.addWidget(bb)

        layout.addLayout(btn_row)

    def _build_report(self) -> str:
        """Build the full text that gets copied to the clipboard."""
        try:
            distro = platform.freedesktop_os_release().get("PRETTY_NAME", platform.platform())
        except Exception:
            distro = platform.platform()

        return (
            f"DTU Setup – Fejlrapport\n"
            f"========================\n"
            f"Tidspunkt   : {datetime.now().isoformat(timespec='seconds')}\n"
            f"Modul       : {self._module_title} ({self._module_id})\n"
            f"Script      : {self._script_name}\n"
            f"Exit code   : {self._exit_code}\n"
            f"OS          : {distro}\n"
            f"Hostname    : {platform.node()}\n"
            f"\n"
            f"Diagnose\n"
            f"--------\n"
            f"{self._diagnosis_title}\n"
            f"\n"
            f"Foreslået løsning\n"
            f"-----------------\n"
            f"{self._fix_text}\n"
            f"\n"
            f"Fejl-output\n"
            f"-----------\n"
            f"{_tail(self._output, max_lines=80)}\n"
            f"\n"
            f"IT-support\n"
            f"----------\n"
            f"URL   : {_HELPDESK_URL}\n"
            f"Email : {_HELPDESK_EMAIL}\n"
        )

    def _copy_to_clipboard(self) -> None:
        clipboard = QGuiApplication.clipboard()
        if clipboard is None:
            return
        clipboard.setText(self._build_report())
        self._copy_btn.setText("✓  Kopieret til udklipsholder")
        # Reset label after a short delay
        from PyQt6.QtCore import QTimer
        QTimer.singleShot(
            2500,
            lambda: self._copy_btn.setText("📋  Copy Error Message and Fix"),
        )
