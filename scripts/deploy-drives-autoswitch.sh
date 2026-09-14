#!/usr/bin/env bash
###############################################################################
# DTU Linux Setup – Install the Q-Drive/P-Drive network auto-switch hook
#
# Installs a NetworkManager dispatcher hook that re-runs
# dtu-drives-reselect.sh whenever a network interface or VPN connection
# changes state, so the Sustain Q-Drive/P-Drive mount automatically
# switches between the direct Qumulo target and the DFS root depending on
# which one the current network (wired / DTUSecure WiFi / VPN) can reach.
#
# Called automatically at the end of scripts/ubuntu/qdrive.sh, in both
# department branches. Safe to re-run.
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

if [[ $EUID -ne 0 ]]; then
  fail "Must run as root."
  exit 1
fi

RESELECT_SCRIPT="${SCRIPT_DIR}/dtu-drives-reselect.sh"
chmod 755 "$RESELECT_SCRIPT"

# Begge scripts skal ligge på en fast sti: dispatcheren og menupunktet kører
# dem, og hverken NetworkManager eller pkexec kender repoets mappestruktur.
install -m 755 "$RESELECT_SCRIPT" /usr/local/bin/dtu-drives-reselect.sh
NOTIFY_SCRIPT=/usr/local/bin/dtu-drives-notify.sh
install -m 755 "${SCRIPT_DIR}/dtu-drives-notify.sh" "$NOTIFY_SCRIPT"

# Menupunktet — den knap der altid findes, også når skrivebordets
# notifikationer ikke understøtter knapper.
if [[ -f "${SCRIPT_DIR}/dtu-drives-refresh.desktop" ]]; then
    install -m 644 "${SCRIPT_DIR}/dtu-drives-refresh.desktop" \
        /usr/share/applications/dtu-drives-refresh.desktop
    update-desktop-database /usr/share/applications 2>/dev/null || true
fi

DISPATCHER_DIR="/etc/NetworkManager/dispatcher.d"
DISPATCHER_HOOK="${DISPATCHER_DIR}/91-dtu-drives"

if [[ ! -d "$DISPATCHER_DIR" ]]; then
  warn "NetworkManager dispatcher.d not found — skipping drive auto-switch hook."
  exit 0
fi

cat > "$DISPATCHER_HOOK" <<HOOK
#!/usr/bin/env bash
# Installed by deploy-drives-autoswitch.sh — reacts to network changes for
# the DTU network drives.
#
# To gange er den her hook blevet rettet i hver sin retning, og begge gange
# gik det for vidt:
#
#   1) Først sov den 3 sekunder og kørte den fulde reselect stille ved hvert
#      event. Den virkede, men imens blokerede hver adgang til /mnt, og
#      ingen fik at vide hvorfor.
#   2) Så blev kaldet til reselect fjernet helt og erstattet af et
#      rækkevidde-tjek plus en notifikation. Dermed skiftede maskinen intet
#      af sig selv længere: omvalget skete kun hvis nogen trykkede på
#      knappen. Kom man tilbage på et net der virkede, blev automounten
#      aldrig armet igen, og uden en grafisk session skete der slet ingenting
#      — altså blev automounten ved med at være armet mod en død server,
#      hvilket er præcis den frysning det hele findes for at undgå.
#
# Nu: kør reselect ved hvert skift, men i baggrunden og under flock, så
# dispatcheren ikke venter og events ikke hober sig op. Scriptet laver selv
# sine egne billige tjek og afslutter med det samme når intet skal ændres.
# Notifikationen sendes kun når reselect siger 75 — "jeg prøvede, og der er
# stadig intet mål der svarer" — frem for ved hvert netværksskift.
#
# Det gamle rækkevidde-tjek her er væk med vilje: det læste kun den FØRSTE
# cifs-linje i fstab, så en maskine med drev på to forskellige servere fik
# kun den ene testet.
ACTION="\$2"
case "\$ACTION" in
  up|down|vpn-up|vpn-down) ;;
  *) exit 0 ;;
esac

(
  sleep 1                      # lige nok til at ruten er sat

  flock -n /var/lock/dtu-drives-reselect.lock /usr/local/bin/dtu-drives-reselect.sh
  RC=\$?

  # Kun 75. En optaget lås giver 1 fra flock, og det betyder at en anden
  # kørsel er i gang lige nu — ikke at der mangler et mål at montere fra.
  [ "\$RC" -eq 75 ] || exit 0

  # Der er stadig ingen server der svarer. Sig det til dem der er logget ind
  # på en grafisk session — én notifikation per bruger, med en knap.
  for u in \$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print \$3}' | sort -u); do
    [ -n "\$u" ] || continue
    "${NOTIFY_SCRIPT}" "\$u" &
  done
) >> /var/log/dtu-drives-reselect.log 2>&1 &
HOOK
chmod 755 "$DISPATCHER_HOOK"
chown root:root "$DISPATCHER_HOOK"

ok "Drive auto-switch hook installed: ${DISPATCHER_HOOK}"
echo "    Runs /usr/local/bin/dtu-drives-reselect.sh on network up/down/vpn-up/vpn-down,"
echo "    and notifies logged-in users only when no target answers."
