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

tee /etc/polkit-1/rules.d/49-allow-username-input.rules > /dev/null <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.") === 0 ||
        action.id.indexOf("org.kde.") === 0) {
        return polkit.Result.AUTH_ADMIN_KEEP;
    }
});
EOF

# ── Step 3: Domain user daily-use rights ──────────────────────────────────
echo "[4/6] Creating domain-user rights (48-domain-users.rules)..."
# Must be 48- so it is evaluated BEFORE 49-allow-username-input.rules,
# otherwise AUTH_ADMIN_KEEP from that catch-all would override our YES.
rm -f /etc/polkit-1/rules.d/50-domain-users.rules   # clean up old name
tee /etc/polkit-1/rules.d/48-domain-users.rules > /dev/null <<'EOF'
// Domain Users – daily-use rights without admin password prompt.
// IT admins (SUS-ITAdm-Client-Admins) are already handled by
// 49-domain-admins.rules and get YES for everything.
//
// Installed by dtu-setup-ubuntu.sh Module 4.

polkit.addRule(function(action, subject) {

    // Only apply to active, local sessions (not SSH without a seat)
    if (!subject.local || !subject.active)
        return polkit.Result.NOT_HANDLED;

    // Only apply to Domain Users
    if (!subject.isInGroup("Domain Users"))
        return polkit.Result.NOT_HANDLED;

    var dominated = action.id;

    // ── ALLOW without prompt ────────────────────────────────────────

    // PackageKit: refresh repos, install updates, accept EULAs
    if (dominated === "org.freedesktop.packagekit.system-sources-refresh" ||
        dominated === "org.freedesktop.packagekit.system-update"          ||
        dominated === "org.freedesktop.packagekit.trigger-offline-update" ||
        dominated === "org.freedesktop.packagekit.package-eula-accept") {
        return polkit.Result.YES;
    }

    // UDisks2: mount/unmount removable media, power-off drives, eject
    if (dominated.indexOf("org.freedesktop.udisks2.filesystem-mount")  === 0 ||
        dominated.indexOf("org.freedesktop.udisks2.power-off-drive")   === 0 ||
        dominated.indexOf("org.freedesktop.udisks2.eject-media")       === 0) {
        return polkit.Result.YES;
    }

    // UDisks2: read SMART reports (prevents password prompt on login/unlock)
    if (dominated === "org.freedesktop.udisks2.ata-smart-update"   ||
        dominated === "org.freedesktop.udisks2.ata-smart-selftest" ||
        dominated === "org.freedesktop.udisks2.ata-smart-simulate") {
        return polkit.Result.YES;
    }

    // NetworkManager: WiFi, VPN, wired – everything
    if (dominated.indexOf("org.freedesktop.NetworkManager.") === 0) {
        return polkit.Result.YES;
    }

    // Login1: power-off, reboot, suspend, hibernate
    if (dominated.indexOf("org.freedesktop.login1.power-off")  === 0 ||
        dominated.indexOf("org.freedesktop.login1.reboot")     === 0 ||
        dominated.indexOf("org.freedesktop.login1.suspend")    === 0 ||
        dominated.indexOf("org.freedesktop.login1.hibernate")  === 0) {
        return polkit.Result.YES;
    }

    // Bluetooth (bluez)
    if (dominated.indexOf("org.bluez.") === 0) {
        return polkit.Result.YES;
    }

    // CUPS: manage own print jobs (cancel, hold, release)
    if (dominated === "org.opensuse.cupspkhelper.mechanism.job-cancel" ||
        dominated === "org.opensuse.cupspkhelper.mechanism.job-edit") {
        return polkit.Result.YES;
    }

    // ── REQUIRE ADMIN AUTH (explicit) ───────────────────────────────

    // PackageKit: install / remove software, configure repos
    if (dominated === "org.freedesktop.packagekit.package-install"          ||
        dominated === "org.freedesktop.packagekit.package-remove"           ||
        dominated === "org.freedesktop.packagekit.system-sources-configure") {
        return polkit.Result.AUTH_ADMIN;
    }

    // CUPS: add/remove printers (admin action)
    if (dominated.indexOf("org.opensuse.cupspkhelper.mechanism.printer-") === 0 ||
        dominated.indexOf("org.opensuse.cupspkhelper.mechanism.server-")  === 0) {
        return polkit.Result.AUTH_ADMIN;
    }

    // Everything else – fall through to default (AUTH_ADMIN)
    return polkit.Result.NOT_HANDLED;
});
EOF

# ── Step 4: PackageKit no-auth rule ─────────────────────────────────────────
echo "[5/6] Creating PackageKit no-auth rule (49-packagekit-noauth.rules)..."
tee /etc/polkit-1/rules.d/49-packagekit-noauth.rules > /dev/null <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.packagekit.") === 0 &&
        action.id !== "org.freedesktop.packagekit.package-install") {
        return polkit.Result.YES;
    }
});
EOF

echo "[6/6] Restarting polkit..."
systemctl restart polkit
sleep 1  # wait for polkit to be fully ready

ok "PolicyKit configured for SUS-ITAdm-Client-Admins + Domain Users."
echo "    KDE auth dialog will now show a username field."
echo "    Domain users can update packages, mount USB, manage WiFi, etc."
echo "    Log out and back in for full effect."
