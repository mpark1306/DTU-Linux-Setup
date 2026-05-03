#!/usr/bin/env bash
###############################################################################
# DTU Sustain – openSUSE Tumbleweed – Module: PolicyKit / KDE IT-Backdoor
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
need_root

banner "PolicyKit / KDE IT Admin Backdoor + Domain User Rights"

ADMIN_GROUP="${SITE_AD_ADMIN_GROUP}"
ADMIN_GROUP_LC="$(echo "$ADMIN_GROUP" | tr '[:upper:]' '[:lower:]')"
ADMIN_GROUP_LC_NODASH="$(echo "$ADMIN_GROUP_LC" | tr -d -)"
REALM_LC="${SITE_AD_REALM}"
REALM_UC="${SITE_AD_DOMAIN}"

echo "[1/6] Creating PolKit admin rules..."
mkdir -p /etc/polkit-1/rules.d/

echo "[2/6] Adding ${ADMIN_GROUP} to sudoers..."
cat > /etc/sudoers.d/dtu-it-admins <<EOF
# DTU IT admins – covers SSSD group name variants
%${ADMIN_GROUP} ALL=(ALL) ALL
%${ADMIN_GROUP_LC} ALL=(ALL) ALL
%${ADMIN_GROUP_LC_NODASH} ALL=(ALL) ALL
%${ADMIN_GROUP}@${REALM_UC} ALL=(ALL) ALL
%${ADMIN_GROUP_LC}@${REALM_LC} ALL=(ALL) ALL
%${ADMIN_GROUP_LC_NODASH}@${REALM_LC} ALL=(ALL) ALL
EOF
chmod 440 /etc/sudoers.d/dtu-it-admins
visudo -cf /etc/sudoers.d/dtu-it-admins || { fail "sudoers syntax error"; rm -f /etc/sudoers.d/dtu-it-admins; }

tee /etc/polkit-1/rules.d/49-domain-admins.rules > /dev/null <<EOF
// Grant full admin access to ${ADMIN_GROUP}
polkit.addRule(function(action, subject) {
    if (subject.isInGroup("${ADMIN_GROUP}") ||
        subject.isInGroup("${ADMIN_GROUP_LC_NODASH}")) {
        return polkit.Result.YES;
    }
});
EOF

tee /etc/polkit-1/rules.d/40-admin-identities.rules > /dev/null <<EOF
// Define who counts as an administrator
polkit.addAdminRule(function(action, subject) {
    return [
        "unix-user:0",
        "unix-group:wheel",
        "unix-group:sudo",
        "unix-group:${ADMIN_GROUP}",
        "unix-group:${ADMIN_GROUP_LC_NODASH}"
    ];
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

# ── Step 2: Domain user daily-use rights ──────────────────────────────────
echo "[3/6] Creating domain-user rights (50-domain-users.rules)..."
tee /etc/polkit-1/rules.d/50-domain-users.rules > /dev/null <<'EOF'
// Domain Users – daily-use rights without admin password prompt.
// IT admins (SUS-ITAdm-Client-Admins) are already handled by
// 49-domain-admins.rules and get YES for everything.
//
// Installed by dtu-setup-opensuse-tw.sh Module 4.

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

# ── Step 3: PackageKit no-auth rule ─────────────────────────────────────────
echo "[4/6] Creating PackageKit no-auth rule (49-packagekit-noauth.rules)..."
tee /etc/polkit-1/rules.d/49-packagekit-noauth.rules > /dev/null <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.packagekit.") === 0 &&
        action.id !== "org.freedesktop.packagekit.package-install") {
        return polkit.Result.YES;
    }
});
EOF

# ── Step 4: Background zypper refresh timer ─────────────────────────────────
echo "[5/6] Installing zypper-refresh systemd timer (every 4 hours)..."

cat > /etc/systemd/system/zypper-refresh.service <<'UNIT'
[Unit]
Description=Refresh zypper repositories
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/zypper --non-interactive refresh
TimeoutStartSec=300
UNIT

cat > /etc/systemd/system/zypper-refresh.timer <<'TIMER'
[Unit]
Description=Refresh zypper repositories every 4 hours

[Timer]
OnBootSec=5min
OnUnitActiveSec=4h
RandomizedDelaySec=10min
Persistent=true

[Install]
WantedBy=timers.target
TIMER

systemctl daemon-reload
systemctl enable --now zypper-refresh.timer

echo "[6/6] Restarting polkit..."
systemctl restart polkit
sleep 1  # wait for polkit to be fully ready

ok "PolicyKit configured for ${ADMIN_GROUP} + Domain Users."
echo "    KDE auth dialog will now show a username field."
echo "    Admin identities set via 40-admin-identities.rules."
echo "    Domain users can update packages, mount USB, manage WiFi, etc."
echo "    Zypper repos will auto-refresh every 4 hours."
echo "    Log out and back in for full effect."
