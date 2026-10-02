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

# Bruges baade til at skrive konfigurationen og til at efterproeve udfaldet i
# trin 5. Staar de to steder hver for sig, driver de fra hinanden.
# /bin/false og /usr/bin/false er forskellige straenge for SDDM, selvom /bin er
# et symlink. Snap-konti bruger den sidste og overlever ellers MinimumUid,
# fordi de ligger over 500000.
HIDE_SHELLS="/usr/sbin/nologin,/sbin/nologin,/usr/bin/nologin,/bin/false,/usr/bin/false,/bin/sync"

# sddm_conf_value SECTION KEY
# Laes en noegle som SDDM selv ville. Rakkefoelgen er distro-defaults foerst,
# derefter /etc/sddm.conf.d/ sorteret, og til sidst /etc/sddm.conf; den sidste
# traeffer vinder. Noedvendigt fordi 'Current' IKKE staar ét sted: paa en
# provisioneret maskine siger default.conf "kubuntu" og kde_settings.conf
# "ubuntu-theme", og den sidste sorterer efter og vinder.
sddm_conf_value() {
    local section="$1" key="$2" f found=""
    for f in /usr/lib/sddm/sddm.conf.d/*.conf /etc/sddm.conf.d/*.conf /etc/sddm.conf; do
        if [[ -r "$f" ]]; then
            local v
            v="$(awk -F= -v s="[$section]" -v k="$key" '
                /^[[:space:]]*\[/ { h = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", h); insec = (h == s); next }
                insec && $1 ~ "^[[:space:]]*" k "[[:space:]]*$" {
                    sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2); val = $2
                }
                END { if (val != "") print val }' "$f" 2>/dev/null)"
            if [[ -n "$v" ]]; then found="$v"; fi
        fi
    done
    printf '%s' "$found"
}

echo "[1/6] Checking that SDDM is the display manager..."
if ! command -v sddm >/dev/null 2>&1; then
    echo "[!] SDDM is not installed. This module only applies to the KDE image."
    exit 0
fi
CURRENT_DM="$(basename "$(readlink -f /etc/systemd/system/display-manager.service 2>/dev/null || echo unknown)")"
echo "    display manager: ${CURRENT_DM}"

echo "[2/6] Resolving which greeter theme actually wins..."
THEME="$(sddm_conf_value Theme Current)"
if [[ -z "$THEME" ]]; then THEME="breeze"; fi
THEME_DIR="/usr/share/sddm/themes/${THEME}"
echo "    theme: ${THEME}  (${THEME_DIR})"
if [[ -d "$THEME_DIR" ]] && ! dpkg -S "${THEME_DIR}/Main.qml" >/dev/null 2>&1; then
    warn "${THEME_DIR} belongs to no package."
    warn "It is a copy made by Systemindstillinger -> Loginskaerm, so apt will"
    warn "never update it. It keeps whatever behaviour it was copied with, which"
    warn "is why a distribution upgrade can leave this working by accident."
fi

echo "[3/6] Checking that the theme still falls back to a username field..."
# Hele strategien hviler paa at temaet SELV skifter til et navnefelt naar
# brugerlisten er tom. Det staar i temaets QML, ikke i en indstilling vi kan
# saette, saa det skal efterproeves mod den QML der faktisk ligger paa
# maskinen, ikke mod hvad kommentaren ovenfor husker fra 24.04:
#
#   Main.qml:  if (userListModel.count === 0 ) { return false }   // showUserList
#   Login.qml: property bool showUsernamePrompt: !showUserList
#              TextField { visible: showUsernamePrompt }
#
# Mangler en af dem, er antagelsen ikke sand laengere, og en tom brugerliste
# kan betyde en loginskaerm UDEN navnefelt. Da skrives der intet: maskinen
# beholder standard-SDDM med MaximumUid=60000, den lokale konto staar paa
# listen, og nogen kan komme ind og rette det.
MAIN_QML="${THEME_DIR}/Main.qml"
LOGIN_QML="${THEME_DIR}/Login.qml"
MISSING=()
if [[ ! -f "$MAIN_QML"  ]]; then MISSING+=("${MAIN_QML} (findes ikke)"); fi
if [[ ! -f "$LOGIN_QML" ]]; then MISSING+=("${LOGIN_QML} (findes ikke)"); fi
if (( ${#MISSING[@]} == 0 )); then
    if ! grep -qE 'userListModel\.count[[:space:]]*===?[[:space:]]*0' "$MAIN_QML"; then
        MISSING+=("the 'count === 0' fallback in Main.qml")
    fi
    if ! grep -qE 'showUsernamePrompt[[:space:]]*:[[:space:]]*!showUserList' "$LOGIN_QML"; then
        MISSING+=("showUsernamePrompt in Login.qml")
    fi
    if ! grep -qE 'visible:[[:space:]]*showUsernamePrompt' "$LOGIN_QML"; then
        MISSING+=("the username field itself in Login.qml")
    fi
fi
if (( ${#MISSING[@]} > 0 )); then
    fail "The '${THEME}' greeter theme no longer has the fallback this module needs:"
    for m in "${MISSING[@]}"; do fail "    missing: ${m}"; done
    fail "Refusing to empty the user list. That could leave a login screen with no"
    fail "username field, and then nobody could log in graphically."
    fail "NOTHING WAS CHANGED. The machine keeps its current login screen."
    fail "A machine without a greeter is still reachable on Ctrl+Alt+F3 and over SSH."
    exit 1
fi
ok "the '${THEME}' theme still shows a username field when the list is empty"

echo "[4/6] Checking that nothing else sets a UID range..."
# Samme orden SDDM bruger: sorteret efter navn, den sidste vinder. Sorterer
# noget efter os og saetter MaximumUid, er rettelsen tavst doed.
# /usr/lib/sddm/sddm.conf.d/ er distro-defaults og kan ikke overskrive /etc,
# saa den er ikke med her.
WINNER=""
for f in "$CONF_DIR"/*.conf; do
    if grep -qE '^\s*(MinimumUid|MaximumUid)' "$f" 2>/dev/null; then WINNER="$f"; fi
done
# /etc/sddm.conf er en selvstaendig placering, og den gamle haandlavede
# rettelse skrev netop UID-indstillinger derind. Saetter den et interval, kan
# vi ikke vide at vi vinder, og saa skrives der ikke.
if [[ -r /etc/sddm.conf ]] && grep -qE '^\s*(MinimumUid|MaximumUid)' /etc/sddm.conf; then
    fail "/etc/sddm.conf sets a UID range of its own."
    fail "Remove those lines from /etc/sddm.conf first; ${CONF_DIR}/ is the place for this."
    fail "NOTHING WAS CHANGED."
    exit 1
fi
if [[ -n "$WINNER" && "$WINNER" > "$CONF" ]]; then
    fail "'${WINNER}' sorts after our file and also sets a UID range."
    fail "It would override us. Rename our file so it sorts last."
    fail "NOTHING WAS CHANGED."
    exit 1
fi
ok "no competing UID range"

echo "[5/6] Writing ${CONF} and verifying the user list really ends up empty..."
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
MinimumUid=${MIN_UID}
MaximumUid=2147483647
HideShells=${HIDE_SHELLS}
RememberLastUser=true
RememberLastSession=true
CONFEOF
chmod 0644 "$CONF"

# Konfigurationen virker kun hvis listen FAKTISK bliver tom. Her efterlignes
# SDDM's UserModel: alle konti fra getent, filtreret paa UID-interval og paa
# HideShells. Er der én tilbage, viser temaet en brugerliste og der er intet
# navnefelt. En ny systemkonto i intervallet er nok til at gaa galt.
REMAINING="$(getent passwd | awk -F: -v min="$MIN_UID" -v hide="$HIDE_SHELLS" '
    BEGIN { n = split(hide, h, ","); for (i = 1; i <= n; i++) hidden[h[i]] = 1 }
    $3 >= min && $3 <= 2147483647 && !($7 in hidden) { print $1 " (uid " $3 ", shell " $7 ")" }
')"
if [[ -n "$REMAINING" ]]; then
    fail "SDDM would still list these accounts, so no username field would appear:"
    while IFS= read -r line; do fail "    ${line}"; done <<< "$REMAINING"
    fail "Fix one of: raise MinimumUid, add that shell to HideShells, or hide the account."
    fail "Reverting ${CONF} so the machine keeps a login screen that works."
    rm -f "$CONF"
    exit 1
fi
ok "SDDM's user list will be empty, so a username field will be shown"

echo "[6/6] Cleaning up the older workaround, if present..."
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
