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
# Called automatically at the end of scripts/ubuntu/qdrive.sh and
# scripts/opensuse/qdrive.sh. Safe to re-run.
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

DISPATCHER_DIR="/etc/NetworkManager/dispatcher.d"
DISPATCHER_HOOK="${DISPATCHER_DIR}/91-dtu-drives"

if [[ ! -d "$DISPATCHER_DIR" ]]; then
  warn "NetworkManager dispatcher.d not found — skipping drive auto-switch hook."
  exit 0
fi

cat > "$DISPATCHER_HOOK" <<HOOK
#!/usr/bin/env bash
# Installed by deploy-drives-autoswitch.sh — re-picks the Q-Drive/P-Drive
# CIFS target (Qumulo-direct vs DFS-root) whenever the network changes.
ACTION="\$2"
case "\$ACTION" in
  up|down|vpn-up|vpn-down)
    (
      sleep 3
      flock -n /var/lock/dtu-drives-reselect.lock "${RESELECT_SCRIPT}" \
        >> /var/log/dtu-drives-reselect.log 2>&1
    ) &
    ;;
esac
HOOK
chmod 755 "$DISPATCHER_HOOK"
chown root:root "$DISPATCHER_HOOK"

ok "Drive auto-switch hook installed: ${DISPATCHER_HOOK}"
echo "    Runs ${RESELECT_SCRIPT} on network up/down/vpn-up/vpn-down."
