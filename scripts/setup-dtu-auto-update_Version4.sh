#!/usr/bin/env bash
###############################################################################
# setup-dtu-auto-update.sh (v3)
#
# Opsætter daglig automatisk opdatering af:
#   - Systempakker (zypper dup på openSUSE, apt dist-upgrade på Debian/Ubuntu)
#   - Firmware (fwupd)
#   - Flatpak (system + pr. bruger)
#   - Snap (hvis installeret)
#
# Egenskaber:
#   - Kører som root via systemd timer
#   - Locking (flock) mod overlappende kørsler
#   - Persistent timer + NetworkManager dispatcher fallback
#   - Reboot-prompt kun når nødvendig (udskydelse mulig)
#   - Konfigurerbar via /etc/default/dtu-auto-update
#   - Rapporter i /var/log/dtu-auto-update (kun root)
###############################################################################
set -euo pipefail

TOTAL=11
BLUE='\033[1;34m'; GREEN='\033[1;32m'; RED='\033[1;31m'; NC='\033[0m'
step() { echo -e "\n${BLUE}[TRIN $1/${TOTAL}]${NC} $2"; }
ok()   { echo -e "  ${GREEN}[OK]${NC} $1"; }
fail() { echo -e "  ${RED}[FEJL]${NC} $1"; exit 1; }

###############################################################################
step 1 "Tjekker forudsætninger og distribution"
###############################################################################
[ "$(id -u)" -eq 0 ] || fail "Scriptet skal køres som root (sudo)."

. /etc/os-release
FAMILY=""
case "${ID:-}" in
  ubuntu|debian) FAMILY="debian" ;;
  opensuse-tumbleweed|opensuse*|sles|sled) FAMILY="suse" ;;
  *)
    case "${ID_LIKE:-}" in
      *debian*|*ubuntu*) FAMILY="debian" ;;
      *suse*) FAMILY="suse" ;;
      *) fail "Ukendt distribution: ${ID:-?}" ;;
    esac
    ;;
esac
ok "Distribution: ${PRETTY_NAME:-$ID} (familie: $FAMILY)"

command -v systemctl >/dev/null || fail "systemd er påkrævet."
ok "systemd fundet"

###############################################################################
step 2 "Installerer afhængigheder"
###############################################################################
if [ "$FAMILY" = "debian" ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq fwupd util-linux >/dev/null
  if ! command -v kdialog >/dev/null && ! command -v zenity >/dev/null; then
    apt-get install -y -qq zenity >/dev/null
  fi
else
  zypper --non-interactive install --no-recommends fwupd util-linux >/dev/null || true
  if ! command -v kdialog >/dev/null && ! command -v zenity >/dev/null; then
    zypper --non-interactive install --no-recommends zenity >/dev/null || true
  fi
fi
ok "Afhængigheder installeret/verificeret"

###############################################################################
step 3 "Opretter mapper"
###############################################################################
install -d -m 700 -o root -g root /var/log/dtu-auto-update
install -d -m 700 -o root -g root /var/lib/dtu-auto-update
ok "Mapper oprettet"

###############################################################################
step 4 "Opretter konfigurationsfil"
###############################################################################
cat > /etc/default/dtu-auto-update <<'CONF_EOF'
# Runtime config for dtu-auto-update
MAX_DEFER=2
DIALOG_TIMEOUT=300
FORCED_REBOOT_DELAY_MIN=5
REBOOT_PROMPT_INITIAL_DELAY_SEC=60

# Dispatcher thresholds
DISPATCHER_MAX_SUCCESS_AGE_SEC=93600   # 26 timer
DISPATCHER_MIN_ATTEMPT_GAP_SEC=7200    # 2 timer
CONF_EOF

chmod 600 /etc/default/dtu-auto-update
chown root:root /etc/default/dtu-auto-update
ok "/etc/default/dtu-auto-update oprettet"

###############################################################################
step 5 "Installerer /usr/local/sbin/dtu-auto-update.sh"
###############################################################################
cat > /usr/local/sbin/dtu-auto-update.sh <<'UPDATE_EOF'
#!/usr/bin/env bash
set -u
export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive
export ZYPP_LOCK_TIMEOUT=600

LOG_DIR="/var/log/dtu-auto-update"
STATE_DIR="/var/lib/dtu-auto-update"
LOCK_FILE="/run/dtu-auto-update.lock"
CONFIG_FILE="/etc/default/dtu-auto-update"

mkdir -p "$LOG_DIR" "$STATE_DIR"
chmod 700 "$LOG_DIR" "$STATE_DIR"

# shellcheck disable=SC1090
[ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"
: "${REBOOT_PROMPT_INITIAL_DELAY_SEC:=60}"

REPORT="${LOG_DIR}/report-$(date +%F_%H-%M-%S).txt"
ERRORS=0

touch "$REPORT"; chmod 600 "$REPORT"

log()     { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$REPORT"; }
section() { printf '\n========== %s ==========\n' "$*" >> "$REPORT"; }

run() {
  local ok_codes="$1" desc="$2"; shift 2
  section "$desc"
  log "Kommando: $*"
  "$@" >> "$REPORT" 2>&1
  local rc=$?
  if [[ " $ok_codes " == *" $rc "* ]]; then
    log "STATUS: OK (exit $rc)"
    return 0
  else
    log "STATUS: FEJL (exit $rc)"
    ERRORS=$((ERRORS+1))
    return 1
  fi
}

# Locking: undgå overlap
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "Et andet run er allerede i gang. Afslutter."
  exit 0
fi

# Opdater attempt-timestamp tidligt (hver gang)
touch "$STATE_DIR/last-attempt"
chmod 600 "$STATE_DIR/last-attempt"

section "DTU AUTO-UPDATE RAPPORT"
log "Maskine: $(hostname -f 2>/dev/null || hostname)"
log "Kernel:  $(uname -r)"

section "Netvaerkstjek"
NET_OK=0
for i in $(seq 1 10); do
  if ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 || ping -c1 -W3 8.8.8.8 >/dev/null 2>&1; then
    if getent hosts download.opensuse.org >/dev/null 2>&1 || getent hosts archive.ubuntu.com >/dev/null 2>&1; then
      NET_OK=1
      break
    fi
  fi
  log "Ingen forbindelse (forsøg $i/10), venter 30 sek..."
  sleep 30
done

if [ "$NET_OK" -ne 1 ]; then
  log "Ingen internetforbindelse. Afslutter (retry via timer/dispatcher)."
  exit 0
fi

. /etc/os-release
FAMILY="debian"
case "${ID:-}${ID_LIKE:-}" in *suse*) FAMILY="suse" ;; esac
log "Distribution: ${PRETTY_NAME:-$ID}"

if [ "$FAMILY" = "debian" ]; then
  APT_OPTS=(-o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
  run "0" "APT update" apt-get "${APT_OPTS[@]}" update
  run "0" "APT dist-upgrade" apt-get "${APT_OPTS[@]}" -y dist-upgrade
  run "0" "APT autoremove" apt-get "${APT_OPTS[@]}" -y autoremove --purge
  if command -v ubuntu-drivers >/dev/null; then
    run "0" "ubuntu-drivers install" ubuntu-drivers install
  fi
else
  run "0" "Zypper refresh" zypper --non-interactive refresh
  run "0 102" "Zypper dup" zypper --non-interactive dup --auto-agree-with-licenses
fi

if command -v fwupdmgr >/dev/null; then
  run "0 2" "fwupd refresh" fwupdmgr refresh --force
  run "0 2" "fwupd update" fwupdmgr update -y --no-reboot-check
else
  section "Firmware"; log "fwupdmgr ikke installeret - springes over"
fi

if command -v flatpak >/dev/null; then
  run "0" "Flatpak system update" flatpak update -y --system --noninteractive
  run "0" "Flatpak system cleanup" flatpak uninstall -y --system --unused --noninteractive

  for d in /home/*; do
    [ -d "$d/.local/share/flatpak" ] || continue
    u="$(stat -c %U "$d" 2>/dev/null)" || continue
    [ "$u" = "root" ] && continue
    run "0" "Flatpak user update ($u)" runuser -u "$u" -- flatpak update -y --user --noninteractive
  done
else
  section "Flatpak"; log "flatpak ikke installeret - springes over"
fi

if command -v snap >/dev/null; then
  run "0" "Snap refresh" snap refresh
else
  section "Snap"; log "snap ikke installeret - springes over"
fi

REBOOT_NEEDED=0
if [ "$FAMILY" = "debian" ]; then
  if [ -f /run/reboot-required ]; then
    REBOOT_NEEDED=1
    [ -f /run/reboot-required.pkgs ] && { section "Pakker der kræver reboot"; cat /run/reboot-required.pkgs >> "$REPORT"; }
  fi
else
  if command -v zypper >/dev/null; then
    zypper needs-rebooting >/dev/null 2>&1
    zrc=$?
    case "$zrc" in
      0) REBOOT_NEEDED=0; log "zypper needs-rebooting=0 (ingen reboot nødvendig)" ;;
      102) REBOOT_NEEDED=1; log "zypper needs-rebooting=102 (reboot nødvendig)" ;;
      *) REBOOT_NEEDED=0; log "zypper needs-rebooting=$zrc (ukendt), antager ingen tvungen reboot" ;;
    esac
  fi
fi

section "OPSUMMERING"
log "Antal fejl: $ERRORS"
log "Reboot påkrævet: $([ "$REBOOT_NEEDED" -eq 1 ] && echo JA || echo NEJ)"

if [ "$ERRORS" -eq 0 ]; then
  touch "$STATE_DIR/last-success"
  chmod 600 "$STATE_DIR/last-success"
  log "Kørsel gennemført uden fejl."
else
  log "Kørsel gennemført med fejl."
fi

find "$LOG_DIR" -name 'report-*.txt' -mtime +90 -delete 2>/dev/null

if [ "$REBOOT_NEEDED" -eq 1 ]; then
  echo 0 > "$STATE_DIR/defer-count"
  chmod 600 "$STATE_DIR/defer-count"
  systemd-run --on-active="${REBOOT_PROMPT_INITIAL_DELAY_SEC}s" --quiet /usr/local/sbin/dtu-reboot-prompt.sh
  log "Reboot-prompt planlagt om ${REBOOT_PROMPT_INITIAL_DELAY_SEC}s."
fi

exit 0
UPDATE_EOF

chmod 700 /usr/local/sbin/dtu-auto-update.sh
chown root:root /usr/local/sbin/dtu-auto-update.sh
ok "dtu-auto-update.sh installeret"

###############################################################################
step 6 "Installerer /usr/local/sbin/dtu-reboot-prompt.sh"
###############################################################################
cat > /usr/local/sbin/dtu-reboot-prompt.sh <<'PROMPT_EOF'
#!/usr/bin/env bash
set -u

STATE_DIR="/var/lib/dtu-auto-update"
DEFER_FILE="$STATE_DIR/defer-count"
LOG_DIR="/var/log/dtu-auto-update"
CONFIG_FILE="/etc/default/dtu-auto-update"

MAX_DEFER=2
DIALOG_TIMEOUT=300
FORCED_REBOOT_DELAY_MIN=5

# shellcheck disable=SC1090
[ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"

mkdir -p "$STATE_DIR" "$LOG_DIR"
COUNT=$(cat "$DEFER_FILE" 2>/dev/null || echo 0)
case "$COUNT" in ''|*[!0-9]*) COUNT=0 ;; esac

plog() {
  printf '[%s] reboot-prompt: %s\n' "$(date '+%F %T')" "$*" >> "$LOG_DIR/reboot-prompt.log"
  chmod 600 "$LOG_DIR/reboot-prompt.log"
}

NEEDED=0
if [ -f /run/reboot-required ]; then NEEDED=1; fi
if command -v zypper >/dev/null; then
  zypper needs-rebooting >/dev/null 2>&1
  [ $? -eq 102 ] && NEEDED=1
fi
if [ "$NEEDED" -eq 0 ]; then
  plog "Reboot ikke længere nødvendig."
  rm -f "$DEFER_FILE"
  exit 0
fi

RUSER=""; RUID=""; SDISPLAY=""
while read -r sid _; do
  [ -n "$sid" ] || continue
  t=$(loginctl show-session "$sid" -p Type --value 2>/dev/null || true)
  st=$(loginctl show-session "$sid" -p State --value 2>/dev/null || true)
  case "$t" in x11|wayland) ;; *) continue ;; esac
  case "$st" in active|online) ;; *) continue ;; esac

  cand_user=$(loginctl show-session "$sid" -p Name --value 2>/dev/null || true)
  [ -n "$cand_user" ] || continue
  cand_uid=$(id -u "$cand_user" 2>/dev/null || true)
  [ -n "$cand_uid" ] || continue

  RUSER="$cand_user"
  RUID="$cand_uid"
  SDISPLAY=$(loginctl show-session "$sid" -p Display --value 2>/dev/null || true)
  break
done < <(loginctl list-sessions --no-legend 2>/dev/null)

# Hvis ingen aktiv GUI-bruger: reboot med det samme
if [ -z "$RUSER" ]; then
  plog "Ingen aktiv GUI-bruger; genstarter nu."
  systemctl reboot
  exit 0
fi

as_user() {
  runuser -u "$RUSER" -- env \
    XDG_RUNTIME_DIR="/run/user/$RUID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$RUID/bus" \
    DISPLAY="${SDISPLAY:-:0}" \
    "$@"
}

REMAINING=$((MAX_DEFER - COUNT))
TITLE="DTU Systemopdatering"

defer_one_hour() {
  echo $((COUNT + 1)) > "$DEFER_FILE"
  chmod 600 "$DEFER_FILE"
  plog "Udskudt af $RUSER ($((COUNT+1))/$MAX_DEFER). Ny prompt om 1 time."
  systemd-run --on-active=3600 --quiet /usr/local/sbin/dtu-reboot-prompt.sh
  as_user notify-send -u normal "$TITLE" "Genstart udskudt 1 time." 2>/dev/null || true
  exit 0
}

reboot_now() {
  plog "Bruger $RUSER valgte genstart nu."
  rm -f "$DEFER_FILE"
  shutdown -r +1 "Systemopdatering: maskinen genstarter om 1 minut."
  exit 0
}

if [ "$REMAINING" -gt 0 ]; then
  MSG="Systemopdateringer er installeret, og genstart er påkrævet.

Genstart nu?

Du kan udskyde $REMAINING gang(e) endnu (1 time pr. gang).
Uden svar udskydes automatisk om 5 minutter."
  if command -v kdialog >/dev/null; then
    as_user timeout "$DIALOG_TIMEOUT" kdialog \
      --title "$TITLE" \
      --warningyesno "$MSG" \
      --yes-label "Genstart nu" \
      --no-label "Udskyd 1 time"
    rc=$?
  else
    as_user zenity \
      --question \
      --title="$TITLE" \
      --text="$MSG" \
      --ok-label="Genstart nu" \
      --cancel-label="Udskyd 1 time" \
      --timeout="$DIALOG_TIMEOUT" \
      --width=420
    rc=$?
  fi

  case "$rc" in
    0) reboot_now ;;
    *) defer_one_hour ;;
  esac
else
  plog "Maks udskydelser nået. Tvungen genstart om ${FORCED_REBOOT_DELAY_MIN} min."
  shutdown -r +"$FORCED_REBOOT_DELAY_MIN" "Systemopdatering: maskinen genstarter om ${FORCED_REBOOT_DELAY_MIN} minutter. Gem dit arbejde."

  MSG="Systemopdateringer kræver genstart, og alle udskydelser er brugt.

Maskinen genstarter automatisk om ${FORCED_REBOOT_DELAY_MIN} minutter.
Gem dit arbejde nu."
  if command -v kdialog >/dev/null; then
    as_user timeout 290 kdialog --title "$TITLE" --sorry "$MSG" 2>/dev/null || true
  else
    as_user zenity --warning --title="$TITLE" --text="$MSG" --timeout=290 --width=420 2>/dev/null || true
  fi
  rm -f "$DEFER_FILE"
fi

exit 0
PROMPT_EOF

chmod 700 /usr/local/sbin/dtu-reboot-prompt.sh
chown root:root /usr/local/sbin/dtu-reboot-prompt.sh
ok "dtu-reboot-prompt.sh installeret"

###############################################################################
step 7 "Opretter systemd service + timer (hardening)"
###############################################################################

# --- Test om mount namespaces virker på denne maskine ---
HARDENING="full"
cat > /tmp/dtu-ns-test.service <<'NSTEST'
[Unit]
Description=DTU namespace test (midlertidig)
[Service]
Type=oneshot
ExecStart=/bin/true
PrivateTmp=true
ProtectSystem=full
NSTEST
systemctl daemon-reload
if systemctl start dtu-ns-test.service 2>/dev/null; then
  ok "Mount namespaces understøttet - bruger fuld hardening"
else
  echo -e "  ${RED}[!]${NC} Mount namespaces ikke understøttet (Cubic-image / begrænset kernel)"
  echo "  Falder tilbage til hardening uden mount namespaces."
  HARDENING="fallback"
fi
rm -f /tmp/dtu-ns-test.service
systemctl reset-failed dtu-ns-test.service 2>/dev/null || true

if [ "$HARDENING" = "full" ]; then
cat > /etc/systemd/system/dtu-auto-update.service <<'SVC_EOF'
[Unit]
Description=DTU daglig automatisk opdatering (apt/zypper, fwupd, flatpak, snap)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/dtu-auto-update.sh
TimeoutStartSec=3h
Nice=10
IOSchedulingClass=idle
UMask=0077

# hardening (mount namespaces tilgaengelige)
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=read-only
ReadWritePaths=/var/log/dtu-auto-update /var/lib/dtu-auto-update /run \
               /usr /boot /etc \
               /var/cache /var/lib/dpkg /var/lib/apt /var/log/apt /var/log/dpkg.log \
               /var/cache/zypp /var/lib/zypp \
               /var/lib/flatpak \
               /var/lib/fwupd /var/cache/fwupd \
               /var/lib/snapd /var/snap /snap \
               /home
SVC_EOF
else
cat > /etc/systemd/system/dtu-auto-update.service <<'SVC_EOF'
[Unit]
Description=DTU daglig automatisk opdatering (apt/zypper, fwupd, flatpak, snap)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/dtu-auto-update.sh
TimeoutStartSec=3h
Nice=10
IOSchedulingClass=idle
UMask=0077

# hardening (uden mount namespaces - sikkerhed via filrettigheder)
NoNewPrivileges=true
SVC_EOF
fi

cat > /etc/systemd/system/dtu-auto-update.timer <<'TMR_EOF'
[Unit]
Description=Daglig timer for DTU automatisk opdatering

[Timer]
OnCalendar=*-*-* 11:30
RandomizedDelaySec=45min
Persistent=true

[Install]
WantedBy=timers.target
TMR_EOF
ok "systemd service+timer oprettet (hardening: $HARDENING)"

###############################################################################
step 8 "Opretter NetworkManager dispatcher hook"
###############################################################################
if [ -d /etc/NetworkManager/dispatcher.d ]; then
  cat > /etc/NetworkManager/dispatcher.d/90-dtu-auto-update <<'NM_EOF'
#!/usr/bin/env bash
set -u

ACTION="${2:-}"
case "$ACTION" in
  up|connectivity-change) ;;
  *) exit 0 ;;
esac

CONFIG_FILE="/etc/default/dtu-auto-update"
STATE_DIR="/var/lib/dtu-auto-update"

DISPATCHER_MAX_SUCCESS_AGE_SEC=93600
DISPATCHER_MIN_ATTEMPT_GAP_SEC=7200
# shellcheck disable=SC1090
[ -r "$CONFIG_FILE" ] && . "$CONFIG_FILE"

now=$(date +%s)
succ=0
att=0
[ -e "$STATE_DIR/last-success" ] && succ=$(stat -c %Y "$STATE_DIR/last-success" 2>/dev/null || echo 0)
[ -e "$STATE_DIR/last-attempt" ] && att=$(stat -c %Y "$STATE_DIR/last-attempt" 2>/dev/null || echo 0)

if [ $((now - succ)) -gt "$DISPATCHER_MAX_SUCCESS_AGE_SEC" ] && \
   [ $((now - att)) -gt "$DISPATCHER_MIN_ATTEMPT_GAP_SEC" ]; then
  systemctl start --no-block dtu-auto-update.service
fi

exit 0
NM_EOF

  chmod 755 /etc/NetworkManager/dispatcher.d/90-dtu-auto-update
  chown root:root /etc/NetworkManager/dispatcher.d/90-dtu-auto-update
  ok "Dispatcher hook installeret"
else
  echo "  [ADVARSEL] /etc/NetworkManager/dispatcher.d findes ikke - springer hook over."
fi

###############################################################################
step 9 "Aktiverer timer"
###############################################################################
systemctl daemon-reload
systemctl enable --now dtu-auto-update.timer
ok "Timer aktiveret"

###############################################################################
step 10 "Kører første opdatering via servicen"
###############################################################################
echo "  Starter dtu-auto-update.service (dette kan tage lang tid)..."
systemctl start dtu-auto-update.service 2>&1 || true
SVC_RC=$(systemctl show -p ExecMainStatus --value dtu-auto-update.service 2>/dev/null || echo "?")
LATEST_REPORT="$(ls -t /var/log/dtu-auto-update/report-*.txt 2>/dev/null | head -1)"

if [ -z "$LATEST_REPORT" ]; then
  echo -e "  ${RED}[ADVARSEL]${NC} Ingen rapport genereret - servicen kan have fejlet helt."
  echo "  Tjek: sudo journalctl -u dtu-auto-update.service --no-pager -n 50"
else
  REPORT_ERRORS=$(grep -c 'STATUS: FEJL' "$LATEST_REPORT" 2>/dev/null || echo 0)
  ok "Servicen afsluttet (exit $SVC_RC). Rapport: $LATEST_REPORT"
  if [ "$REPORT_ERRORS" -gt 0 ]; then
    echo -e "  ${RED}[!]${NC} $REPORT_ERRORS fejl fundet i rapporten - forsøger auto-fix i næste trin."
  else
    ok "Ingen fejl i rapporten."
  fi
fi

###############################################################################
step 11 "Verificerer system og fikser eventuelle problemer"
###############################################################################
NEEDS_RERUN=0

if [ "$FAMILY" = "debian" ]; then
  # --- Fix 1: dpkg afbrudt tilstand ---
  if dpkg --audit 2>&1 | grep -q .; then
    echo -e "  ${RED}[!]${NC} dpkg har afbrudte pakker - fikser..."
    dpkg --configure -a 2>&1 | tail -5
    ok "dpkg --configure -a kørt"
    NEEDS_RERUN=1
  else
    ok "dpkg: ingen afbrudte pakker"
  fi

  # --- Fix 2: ødelagte afhængigheder ---
  if ! apt-get check 2>&1 | tail -1 | grep -q "^0 "; then
    echo -e "  ${RED}[!]${NC} Ødelagte afhængigheder fundet - fikser..."
    apt-get -o DPkg::Lock::Timeout=300 -y -f install 2>&1 | tail -5
    ok "apt-get -f install kørt"
    NEEDS_RERUN=1
  else
    ok "apt: ingen ødelagte afhængigheder"
  fi

  # --- Fix 3: afventende opdateringer ---
  apt-get -o DPkg::Lock::Timeout=300 update -qq 2>/dev/null
  PENDING=$(apt list --upgradable 2>/dev/null | grep -c 'upgradable' || echo 0)
  if [ "$PENDING" -gt 0 ]; then
    echo -e "  ${RED}[!]${NC} $PENDING pakker afventer stadig opdatering - kører dist-upgrade direkte..."
    APT_FIX_OPTS=(-o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
    apt-get "${APT_FIX_OPTS[@]}" -y dist-upgrade 2>&1 | tail -20
    apt-get "${APT_FIX_OPTS[@]}" -y autoremove --purge 2>/dev/null
    # Tjek igen
    STILL_PENDING=$(apt list --upgradable 2>/dev/null | grep -c 'upgradable' || echo 0)
    if [ "$STILL_PENDING" -gt 0 ]; then
      echo -e "  ${RED}[ADVARSEL]${NC} $STILL_PENDING pakker kunne stadig ikke opdateres."
      echo "  Mulige årsager: held-back pakker, PPA-konflikter, eller phased updates."
      echo "  Tjek manuelt: apt list --upgradable"
    else
      ok "Alle afventende pakker er nu installeret."
    fi
  else
    ok "Ingen afventende systempakker."
  fi

else
  # --- openSUSE: zypper med force-resolution ---
  PENDING_SUSE=$(zypper --non-interactive lu 2>/dev/null | grep -c '^v ' || echo 0)
  if [ "$PENDING_SUSE" -gt 0 ]; then
    echo -e "  ${RED}[!]${NC} $PENDING_SUSE pakker afventer opdatering - kører zypper dup --force-resolution..."
    zypper --non-interactive dup --auto-agree-with-licenses --force-resolution 2>&1 | tail -20
    STILL_PENDING_SUSE=$(zypper --non-interactive lu 2>/dev/null | grep -c '^v ' || echo 0)
    if [ "$STILL_PENDING_SUSE" -gt 0 ]; then
      echo -e "  ${RED}[ADVARSEL]${NC} $STILL_PENDING_SUSE pakker kunne stadig ikke opdateres."
      echo "  Tjek manuelt: zypper lu"
    else
      ok "Alle afventende pakker er nu installeret."
    fi
  else
    ok "Ingen afventende systempakker (zypper)."
  fi
fi

# --- Flatpak ---
if command -v flatpak >/dev/null; then
  FLAT_PENDING=$(flatpak remote-ls --updates --system 2>/dev/null | wc -l || echo 0)
  if [ "$FLAT_PENDING" -gt 0 ]; then
    echo -e "  ${RED}[!]${NC} $FLAT_PENDING flatpak-opdateringer afventer - installerer..."
    flatpak update -y --system --noninteractive 2>&1 | tail -10
    ok "Flatpak system-opdateringer kørt."
  else
    ok "Ingen afventende flatpak-opdateringer."
  fi
fi

# --- Snap ---
if command -v snap >/dev/null; then
  SNAP_PENDING=$(snap refresh --list 2>/dev/null | grep -cv '^Name' || echo 0)
  if [ "$SNAP_PENDING" -gt 0 ]; then
    echo -e "  ${RED}[!]${NC} $SNAP_PENDING snap-opdateringer afventer - installerer..."
    snap refresh 2>&1 | tail -10
    ok "Snap refresh kørt."
  else
    ok "Ingen afventende snap-opdateringer."
  fi
fi

# --- Firmware ---
if command -v fwupdmgr >/dev/null; then
  FW_PENDING=$(fwupdmgr get-updates 2>/dev/null | grep -c 'Update Version' || echo 0)
  if [ "$FW_PENDING" -gt 0 ]; then
    echo -e "  ${RED}[!]${NC} $FW_PENDING firmware-opdateringer tilgængelige - installerer..."
    fwupdmgr update -y --no-reboot-check 2>&1 | tail -10
    ok "Firmware-opdateringer kørt."
  else
    ok "Ingen afventende firmware-opdateringer."
  fi
fi

# --- Re-kør servicen hvis dpkg/apt blev fikset ---
if [ "$NEEDS_RERUN" -eq 1 ]; then
  echo
  echo "  Kører servicen én gang mere efter reparation..."
  systemctl start dtu-auto-update.service 2>&1 || true
  ok "Ekstra kørsel gennemført."
fi

echo
echo -e "${GREEN}=============================================================${NC}"
echo -e "${GREEN} Opsætning og første opdatering fuldført (v3)${NC}"
echo -e "${GREEN}=============================================================${NC}"
echo
echo "Rapporter:           sudo ls -lt /var/log/dtu-auto-update/ | head"
echo "Næste planlagte:     $(systemctl list-timers dtu-auto-update.timer --no-pager | sed -n 2p)"
echo "Manuel trigger:      sudo systemctl start dtu-auto-update.service"
echo "Følg live:           sudo journalctl -fu dtu-auto-update.service"
echo