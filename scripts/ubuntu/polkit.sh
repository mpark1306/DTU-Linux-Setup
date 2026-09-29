#!/usr/bin/env bash
###############################################################################
# DTU Sustain – Ubuntu 24.04 – Module: PolicyKit / KDE IT-Backdoor
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
need_root

banner "PolicyKit / KDE IT Admin Backdoor + Domain User Rights"

# Admin group from site.conf. No default: granting sudo + polkit admin rights
# to a guessed group name is worse than refusing to run.
site_require SITE_AD_ADMIN_GROUP

ADMIN_GROUP="${SITE_AD_ADMIN_GROUP}"
ADMIN_GROUP_LC="$(echo "$ADMIN_GROUP" | tr '[:upper:]' '[:lower:]')"
ADMIN_GROUP_LC_NODASH="$(echo "$ADMIN_GROUP_LC" | tr -d -)"
REALM_LC="${SITE_AD_REALM}"
REALM_UC="${SITE_AD_DOMAIN}"

echo "[1/5] Configuring admin identities..."
tee /etc/polkit-1/localauthority.conf.d/50-localauthority.conf > /dev/null <<EOF
[Configuration]
AdminIdentities=unix-user:0;unix-group:sudo;unix-group:wheel;unix-group:${ADMIN_GROUP};unix-group:${ADMIN_GROUP_LC_NODASH}
EOF

echo "[2/5] Adding ${ADMIN_GROUP} to sudoers..."
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
# 'rm -f' returnerer 0, saa hele ||-gruppen returnerede 0 og 'set -e' udloeste
# ikke: scriptet fortsatte. Konsekvensen var den vaerst taenkelige. Den
# KODEORDSBESKYTTEDE sudo-fil blev slettet, mens polkit-reglen nedenfor blev
# skrevet alligevel, saa gruppen mistede den sikre vej til root og beholdt den
# usikre. Derfor et eksplicit exit.
if ! visudo -cf /etc/sudoers.d/dtu-it-admins; then
    rm -f /etc/sudoers.d/dtu-it-admins
    die "sudoers syntax error. The file was removed and no polkit rules were written."
fi

echo "[3/5] Creating PolKit admin rules..."
mkdir -p /etc/polkit-1/rules.d/

# Foer var denne regel et ubetinget "YES" paa ALLE polkit-actions, uden
# subject.local/active. Det gav prompt-fri root via 'pkexec <hvad som helst>',
# ogsaa over RDP og SSH, fordi .policy-filen annoterer action'en paa
# /usr/bin/bash og derfor daekker enhver 'pkexec bash ...'.
#
# Nu er den snaevret ind til to ting:
#   1. Kun lokale, aktive sessioner. Samme betingelse som 48-domain-users har
#      haft hele tiden. En RDP- eller SSH-session faar et kodeordsprompt.
#   2. Kun vaerktoejets egen action. Alt andet falder igennem til polkit's
#      normale auth_admin, og vejen dertil er 'sudo', som kraever kodeord og
#      allerede er givet i trin 2 ovenfor.
#
# De daglige rettigheder (USB, WiFi, pakker, strøm) mister admins ikke:
# 48-domain-users.rules nedenfor daekker nu ogsaa admingruppen, saa listen
# staar ét sted i stedet for to.
tee /etc/polkit-1/rules.d/49-domain-admins.rules > /dev/null <<EOF
// DTU IT admins - password-free access to this tool's own modules.
// Everything else goes through sudo, which asks for a password.

polkit.addRule(function(action, subject) {

    // Only active, local sessions. Not RDP, not SSH.
    if (!subject.local || !subject.active)
        return polkit.Result.NOT_HANDLED;

    if (!subject.isInGroup("${ADMIN_GROUP}") &&
        !subject.isInGroup("${ADMIN_GROUP_LC_NODASH}"))
        return polkit.Result.NOT_HANDLED;

    // This tool's own modules only.
    if (action.id.indexOf("dk.dtu.sustain.setup.") === 0)
        return polkit.Result.YES;

    return polkit.Result.NOT_HANDLED;
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
tee /etc/polkit-1/rules.d/48-domain-users.rules > /dev/null <<EOF
// Domain Users and IT admins - daily-use rights without an admin password.
//
// The admin group is included here so the list of actions lives in one place.
// 49-domain-admins.rules only adds this tool's own modules on top; it no
// longer returns YES for everything.

polkit.addRule(function(action, subject) {

    // Only apply to active, local sessions
    if (!subject.local || !subject.active)
        return polkit.Result.NOT_HANDLED;

    // Domain Users, or the IT admin group. SSSD may resolve either casing.
    if (!subject.isInGroup("Domain Users") &&
        !subject.isInGroup("domain users") &&
        !subject.isInGroup("${ADMIN_GROUP}") &&
        !subject.isInGroup("${ADMIN_GROUP_LC_NODASH}"))
        return polkit.Result.NOT_HANDLED;

    var id = action.id;
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

ok "PolicyKit configured for ${ADMIN_GROUP} + Domain Users."
echo "    Domain users can install packages, mount USB, manage WiFi, etc. without password prompts."
echo "    Log out and back in for full effect."
