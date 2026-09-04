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
# The old version slept 3 seconds and then ran the full reselect on every
# event, silently. That was both too slow to feel responsive and too quiet:
# while it worked, every access to /mnt blocked, and nobody knew why.
#
# Now: settle briefly, ask the cheap question (can the mounted target still
# be reached), and only then do anything. If a change is needed the user is
# told, with a button, rather than having the desktop stall on them.
ACTION="\$2"
case "\$ACTION" in
  up|down|vpn-up|vpn-down) ;;
  *) exit 0 ;;
esac

(
  sleep 1                      # lige nok til at ruten er sat

  # Er det nuværende mål stadig i live, er der intet at lave. Det er den
  # hurtige vej, og den vej der tages næsten hver gang.
  if [ -r /etc/dtu-setup/drives.conf ]; then
    . /etc/dtu-setup/drives.conf 2>/dev/null || true
  fi
  CURRENT="\$(awk '/[[:space:]]cifs[[:space:]]/{print \$1}' /etc/fstab 2>/dev/null \
              | head -1 | sed 's|^//||; s|/.*||')"
  if [ -n "\$CURRENT" ] && timeout 2 bash -c "exec 3<>/dev/tcp/\$CURRENT/445" 2>/dev/null; then
    exit 0
  fi

  # Målet kan ikke nås. Sig det til dem der er logget ind på en grafisk
  # session — én notifikation per bruger, med en knap.
  for u in \$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print \$3}' | sort -u); do
    [ -n "\$u" ] || continue
    "${NOTIFY_SCRIPT}" "\$u" &
  done
) >> /var/log/dtu-drives-reselect.log 2>&1 &
HOOK
chmod 755 "$DISPATCHER_HOOK"
chown root:root "$DISPATCHER_HOOK"

ok "Drive auto-switch hook installed: ${DISPATCHER_HOOK}"
echo "    Runs ${RESELECT_SCRIPT} on network up/down/vpn-up/vpn-down."
