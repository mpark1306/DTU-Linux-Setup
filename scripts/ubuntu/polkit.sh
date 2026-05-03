#!/usr/bin/env bash
###############################################################################
# DTU Sustain – Ubuntu 24.04 – Module: PolicyKit / KDE IT-Backdoor
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
need_root

banner "PolicyKit / KDE IT Admin Backdoor + Domain User Rights"

echo "[1/6] Configuring admin identities..."
tee /etc/polkit-1/localauthority.conf.d/50-localauthority.conf > /dev/null <<'EOF'
[Configuration]
AdminIdentities=unix-user:0;unix-group:sudo;unix-group:wheel;unix-group:SUS-ITAdm-Client-Admins;unix-group:sus-itadm-clientadmins
EOF

echo "[2/6] Adding SUS-ITAdm-Client-Admins to sudoers..."
cat > /etc/sudoers.d/dtu-it-admins <<'SUDOERS'
# DTU Sustain IT admins – covers SSSD group name variants
%SUS-ITAdm-Client-Admins ALL=(ALL) ALL
%sus-itadm-client-admins ALL=(ALL) ALL
%sus-itadm-clientadmins ALL=(ALL) ALL
%SUS-ITAdm-Client-Admins@WIN.DTU.DK ALL=(ALL) ALL
%sus-itadm-client-admins@win.dtu.dk ALL=(ALL) ALL
%sus-itadm-clientadmins@win.dtu.dk ALL=(ALL) ALL
SUDOERS
chmod 440 /etc/sudoers.d/dtu-it-admins
visudo -cf /etc/sudoers.d/dtu-it-admins || { fail "sudoers syntax error"; rm -f /etc/sudoers.d/dtu-it-admins; }

echo "[3/6] Creating PolKit admin rules..."
mkdir -p /etc/polkit-1/rules.d/

tee /etc/polkit-1/rules.d/49-domain-admins.rules > /dev/null <<'EOF'
polkit.addRule(function(action, subject) {
    if (subject.isInGroup("SUS-ITAdm-Client-Admins") ||
        subject.isInGroup("sus-itadm-clientadmins")) {
        return polkit.Result.YES;
    }
});
EOF

# NOTE: 49-allow-username-input.rules is intentionally NOT written here.
# That file was a catch-all (AUTH_ADMIN_KEEP for all org.freedesktop.* / org.kde.*)
# which caused domain users to be asked for admin passwords constantly.
# Remove it if it exists from a previous deployment.
rm -f /etc/polkit-1/rules.d/49-allow-username-input.rules

# ── Step 3: Domain user daily-use rights ──────────────────────────────────
echo "[4/5] Creating domain-user rights (48-domain-users.rules)..."
rm -f /etc/polkit-1/rules.d/50-domain-users.rules   # clean up old name
tee /etc/polkit-1/rules.d/48-domain-users.rules > /dev/null <<'EOF'
// Domain Users – daily-use rights without admin password prompt.
// IT admins (SUS-ITAdm-Client-Admins) are already handled by
// 49-domain-admins.rules and get YES for everything.

polkit.addRule(function(action, subject) {

    // Only apply to active, local sessions
    if (!subject.local || !subject.active)
        return polkit.Result.NOT_HANDLED;

    // Only apply to Domain Users
    if (!subject.isInGroup("Domain Users"))
        return polkit.Result.NOT_HANDLED;

    var id = action.id;

    // ── USB / removable storage ──────────────────────────────────────────
    if (id.indexOf("org.freedesktop.udisks2.filesystem-mount")  === 0 ||
        id.indexOf("org.freedesktop.udisks2.power-off-drive")   === 0 ||
        id.indexOf("org.freedesktop.udisks2.eject-media")       === 0 ||
        id.indexOf("org.freedesktop.udisks2.encrypted-unlock")  === 0 ||
        id.indexOf("org.freedesktop.udisks2.loop-setup")        === 0 ||
        id.indexOf("org.freedesktop.udisks2.ata-smart")         === 0) {
        return polkit.Result.YES;
    }

    // ── NetworkManager (WiFi, VPN, wired) ───────────────────────────────
    if (id.indexOf("org.freedesktop.NetworkManager.") === 0) {
        return polkit.Result.YES;
    }

    // ── Power / session ──────────────────────────────────────────────────
    if (id.indexOf("org.freedesktop.login1.power-off")  === 0 ||
        id.indexOf("org.freedesktop.login1.reboot")     === 0 ||
        id.indexOf("org.freedesktop.login1.suspend")    === 0 ||
        id.indexOf("org.freedesktop.login1.hibernate")  === 0) {
        return polkit.Result.YES;
    }

    // ── PackageKit: refresh, update, install, remove ─────────────────────
    // Domain users can install/remove software without an admin prompt.
    if (id.indexOf("org.freedesktop.packagekit.") === 0) {
        return polkit.Result.YES;
    }

    // ── Flatpak ──────────────────────────────────────────────────────────
    if (id.indexOf("org.freedesktop.Flatpak.") === 0) {
        return polkit.Result.YES;
    }

    // ── Firmware updates (fwupd) ─────────────────────────────────────────
    if (id.indexOf("org.freedesktop.fwupd.") === 0) {
        return polkit.Result.YES;
    }

    // ── Bluetooth ────────────────────────────────────────────────────────
    if (id.indexOf("org.bluez.") === 0) {
        return polkit.Result.YES;
    }

    // ── Date / time / locale ─────────────────────────────────────────────
    if (id.indexOf("org.freedesktop.timedate1.") === 0 ||
        id.indexOf("org.freedesktop.locale1.")   === 0) {
        return polkit.Result.YES;
    }

    // ── Colour management ────────────────────────────────────────────────
    if (id.indexOf("org.freedesktop.color-manager.") === 0) {
        return polkit.Result.YES;
    }

    // ── CUPS: own print jobs ─────────────────────────────────────────────
    if (id === "org.opensuse.cupspkhelper.mechanism.job-cancel" ||
        id === "org.opensuse.cupspkhelper.mechanism.job-edit") {
        return polkit.Result.YES;
    }

    // ── KDE / Plasma actions ─────────────────────────────────────────────
    if (id.indexOf("org.kde.kcontrol.") === 0 ||
        id.indexOf("org.kde.plasma.")   === 0 ||
        id.indexOf("org.kde.kinfocenter") === 0) {
        return polkit.Result.YES;
    }

    return polkit.Result.NOT_HANDLED;
});
EOF

echo "[5/5] Restarting polkit..."
# Also remove the legacy PackageKit noauth rule – now merged into 48 above.
rm -f /etc/polkit-1/rules.d/49-packagekit-noauth.rules
systemctl restart polkit
sleep 1

ok "PolicyKit configured for SUS-ITAdm-Client-Admins + Domain Users."
echo "    Domain users can install packages, mount USB, manage WiFi, etc. without password prompts."
echo "    Log out and back in for full effect."
