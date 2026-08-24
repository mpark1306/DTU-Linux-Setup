"""Module catalogue for DTU Linux Setup.

The list of modules the GUI offers, kept apart from the window that renders it
so that adding or disabling a module is a data edit and not a UI edit.
"""

from __future__ import annotations

from dataclasses import dataclass


# ─── Module definitions ─────────────────────────────────────────────────────

@dataclass
class ModuleDef:
    id: str
    title: str
    description: str
    script_name: str
    needs_root: bool
    input_type: str  # "none", "credentials", "username", "domain_join"
    icon_name: str
    script_type: str = "admin"  # "admin" or "user"
    enabled: bool = True
    common_script: bool = False


MODULES: list[ModuleDef] = [
    ModuleDef(
        id="domain-join",
        title="Domain Join",
        description="Join WIN.DTU.DK domain\n(realmd + SSSD + mkhomedir)",
        script_name="domain-join.sh",
        needs_root=True,
        input_type="domain_join",
        icon_name="network-server",
    ),
    ModuleDef(
        id="qdrive",
        title="Network Drives",
        description="Map department network drives\n(Q+P or O+M via CIFS)",
        script_name="qdrive.sh",
        needs_root=True,
        input_type="credentials",
        icon_name="folder-remote",
        script_type="user",
    ),
    ModuleDef(
        id="defender",
        title="Microsoft Defender",
        description="Defender for Endpoint\n(install + onboard)",
        script_name="defender.sh",
        needs_root=True,
        input_type="none",
        icon_name="security-high",
    ),
    ModuleDef(
        id="polkit",
        title="PolicyKit",
        description="Domain-user rights\n(USB, WiFi, packages)",
        script_name="polkit.sh",
        needs_root=True,
        input_type="none",
        icon_name="preferences-system",
    ),
    ModuleDef(
        id="followme",
        title="Printers",
        description="FollowMe (Sustain) /\nWebPrint app (AIT)",
        script_name="followme.sh",
        needs_root=True,
        input_type="credentials",
        icon_name="printer",
        script_type="user",
    ),
    ModuleDef(
        id="wifi",
        title="DTUSecure WiFi",
        description="WPA2-Enterprise\n(PEAP/MSCHAPv2 auto-connect)",
        script_name="wifi.sh",
        needs_root=True,
        input_type="credentials",
        icon_name="network-wireless",
    ),
    ModuleDef(
        id="software",
        title="Software",
        description="Flatpaks, Snaps\n& Cisco VPN",
        script_name="software.sh",
        needs_root=True,
        input_type="software",
        icon_name="application-x-addon",
    ),
    ModuleDef(
        id="automount",
        title="Auto-mount",
        description="USB automount + udev rules\n(no symlinks)",
        script_name="automount.sh",
        needs_root=True,
        input_type="none",
        icon_name="drive-removable-media",
    ),
    ModuleDef(
        id="sync-homedir",
        title="Sync Home Dirs",
        description="Backup Desktop, Documents\n& Pictures to network drive",
        script_name="setup-sync-homedir.sh",
        needs_root=True,
        input_type="none",
        icon_name="folder-download",
        script_type="user",
        common_script=True,
    ),
    ModuleDef(
        id="auto-update-setup",
        title="Auto Update Setup",
        description="Install daily automatic updates\n(for DTU Sustain + AIT)",
        script_name="setup-dtu-auto-update_Version4.sh",
        needs_root=True,
        input_type="none",
        icon_name="system-software-update",
        common_script=True,
    ),
    ModuleDef(
        id="rdp",
        title="RDP (xrdp)",
        description="Remote Desktop\n(KDE Plasma via xrdp)",
        script_name="rdp.sh",
        needs_root=True,
        input_type="none",
        icon_name="preferences-desktop-remote-desktop",
    ),
    ModuleDef(
        id="tpm2-enroll",
        title="TPM2 Auto-Unlock",
        description="LUKS disk auto-unlock\n(TPM2, no passphrase at boot)",
        script_name="tpm2-enroll.sh",
        needs_root=True,
        input_type="none",
        icon_name="security-high",
    ),
    ModuleDef(
        id="first-login-deploy",
        title="First-Login Setup",
        description="Deploy welcome dialog\nfor new domain users",
        script_name="first-login-deploy.sh",
        needs_root=True,
        input_type="none",
        icon_name="user-new",
    ),
    ModuleDef(
        id="reset-test-user",
        title="Reset Test User",
        description="Remove domain user state\n& home dir for re-testing",
        script_name="reset-test-user.sh",
        needs_root=True,
        input_type="username",
        icon_name="edit-delete",
        enabled=False,
        common_script=True,
    ),
    ModuleDef(
        id="repair-folders",
        title="Repair Home Folders",
        description="Fix broken Desktop/Documents/Pictures\nfrom earlier installs + dedupe fstab",
        script_name="repair-user-folders.sh",
        needs_root=True,
        input_type="username",
        icon_name="view-refresh",
        script_type="user",
        common_script=True,
    ),
]
