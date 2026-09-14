#!/usr/bin/env bash
###############################################################################
# DTU Sustain – Ubuntu 24.04 – Module: Login screen (SDDM shows the domain user)
#
# Problem: SDDM listed only local accounts, so the login screen defaulted to the
# local admin instead of the domain user.
#
# Two independent blockers caused it:
#
#   1. UID range. SDDM's default MaximumUid is 60000. A DTU domain account gets
#      its UID from SSSD's SID mapping and lands around 1.5 billion, so it was
#      filtered out before it could be shown.
#
#   2. Enumeration. SSSD does not enumerate domain users (correctly so on an AD
#      this size), so they never appear in getpwent and therefore never in
#      SDDM's user list, no matter what the UID range says.
#
# Fix: raise the ceiling, and lift MinimumUid above every local account so the
# list ends up empty. The Breeze/Ubuntu themes then switch to a username field
# on their own:
#
#     Main.qml:   if (userListModel.count === 0) { return false }   // showUserList
#     Login.qml:  property bool showUsernamePrompt: !showUserList
#                 text: lastUserName                               // = userModel.lastUser
#
# With RememberLastUser=true SDDM writes the last successful login to its own
# state file and pre-fills that field, and focus starts in the password box.
# The domain user therefore just types a password. A local account is reached by
# typing its name instead.
#
# Filename matters: files in /etc/sddm.conf.d/ are read in sorted order and the
# last one wins. "kde_settings.conf" is written by System Settings -> Login
# Screen the moment anyone opens and applies it, and it pins MaximumUid=60000.
# Our file has to sort after that, hence the zz- prefix.
###############################################################################
set -euo pipefail
# NB: under 'set -e' afslutter '[[ ... ]] && kommando' hele scriptet naar
# betingelsen er falsk. Brug 'if', ikke '&&', til valgfri output.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
need_root

banner "Login screen – show the domain user by default"

CONF_DIR=/etc/sddm.conf.d
CONF="$CONF_DIR/zz-dtu-domain-login.conf"

# Above every local account, far below the SSSD mapping range. Verified against
# a real domain account: uid 1590871524, and local accounts at 1000-65534.
MIN_UID=100000

echo "[1/4] Checking that SDDM is the display manager..."
if ! command -v sddm >/dev/null 2>&1; then
    echo "[!] SDDM is not installed. This module only applies to the KDE image."
    exit 0
fi
CURRENT_DM="$(basename "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || echo unknown)")"
echo "    display manager: ${CURRENT_DM}"

echo "[2/4] Writing ${CONF}..."
mkdir -p "$CONF_DIR"
cat > "$CONF" <<CONFEOF
# GENERERET AF DTU LINUX SETUP - login-screen.sh
#
# Domaenebrugeren er standard paa loginskaermen.
#
# MinimumUid over alle lokale konti goer brugerlisten tom. Temaet skifter da
# selv til et navnefelt, som udfyldes med sidste bruger. Lokale konti logges
# ind ved at skrive navnet.
#
# Filnavnet skal sortere EFTER kde_settings.conf, som skrives af
# Systemindstillinger -> Loginskaerm og ellers ville saette MaximumUid=60000.
[Users]
# /bin/false og /usr/bin/false er forskellige straenge for SDDM, selvom
# /bin er et symlink. Snap-konti bruger den sidste og overlever ellers
# MinimumUid, fordi de ligger over 500000.
MinimumUid=${MIN_UID}
MaximumUid=2147483647
HideShells=/usr/sbin/nologin,/sbin/nologin,/usr/bin/nologin,/bin/false,/usr/bin/false,/bin/sync
RememberLastUser=true
RememberLastSession=true
CONFEOF
chmod 0644 "$CONF"

echo "[3/4] Verifying that our file is the one that wins..."
# Same order SDDM uses: sorted by name, last one wins. If something sorts after
# us and sets MaximumUid, the fix is silently dead - so say so loudly.
WINNER=""
for f in "$CONF_DIR"/*.conf; do
    if grep -qE '^\s*(MinimumUid|MaximumUid)' "$f" 2>/dev/null; then WINNER="$f"; fi
done
if [[ "$WINNER" != "$CONF" ]]; then
    echo "[!] '${WINNER}' sorts after our file and also sets a UID range."
    echo "[!] It will override us. Rename our file so it sorts last."
    exit 1
fi
echo "    ok: ${WINNER}"

echo "[4/4] Cleaning up the older workaround, if present..."
# An earlier hand-rolled fix wrote a save-last-user hook and put UID settings in
# /etc/sddm.conf. The hook was never called: SDDM's DisplayStopCommand defaults
# to /usr/share/sddm/scripts/Xstop, not /etc/sddm/Xstop, and it is X11-only.
# SDDM already records the last user natively via RememberLastUser.
REMOVED=0
for stale in /etc/sddm/Xstop /usr/local/bin/save-last-user.sh /usr/local/bin/setup-login.sh; do
    if [[ -e "$stale" ]]; then
        rm -f "$stale"
        echo "    removed ${stale}"
        REMOVED=1
    fi
done
if [[ -f /etc/systemd/system/sddm.service.d/override.conf ]] \
   && grep -q 'ExecStartPre=/bin/sleep' /etc/systemd/system/sddm.service.d/override.conf; then
    # A fixed sleep is a race dressed up as a fix. If SDDM must wait for SSSD,
    # that is an ordering dependency, not a delay.
    rm -f /etc/systemd/system/sddm.service.d/override.conf
    rmdir --ignore-fail-on-non-empty /etc/systemd/system/sddm.service.d
    systemctl daemon-reload
    echo "    removed the sleep-based sddm override"
    REMOVED=1
fi
if [[ "$REMOVED" -eq 0 ]]; then echo "    nothing to clean up"; fi

echo
echo "Done. The change takes effect at the next login screen."
echo
echo "  What you will see: a username field, pre-filled with the last user."
echo "  Log in once as a domain user, then restart to confirm."
echo "  A local account is reached by clearing the field and typing its name."
echo
echo "  Apply now without rebooting:  sudo systemctl restart sddm"
echo "  (this closes every graphical session on the machine)"
