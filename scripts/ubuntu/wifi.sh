#!/usr/bin/env bash
###############################################################################
# DTU – Ubuntu 24.04 – Module: DTUSecure WiFi auto-connect
#
# Creates a NetworkManager WPA2-Enterprise (PEAP/MSCHAPv2) profile for
# DTUSecure with stored domain credentials so the machine connects
# automatically when DTUSecure is in range and no Ethernet is available.
#
# Env: DTU_USERNAME, DTU_PASSWORD
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
need_root

banner "DTUSecure WiFi – WPA2-Enterprise auto-connect"

if [[ -z "${DTU_USERNAME:-}" || -z "${DTU_PASSWORD:-}" ]]; then
  fail "DTU_USERNAME and DTU_PASSWORD must be set."
  exit 1
fi

SSID="${SITE_WIFI_SSID}"
CON_NAME="${SITE_WIFI_SSID}"
IDENTITY="${DTU_USERNAME}${SITE_WIFI_IDENTITY_SUFFIX}"
PASSWORD="$DTU_PASSWORD"

echo "[1/4] Installing NetworkManager WPA-supplicant support..."
apt_wait
apt-get install -y network-manager wpasupplicant >/dev/null

echo "[2/4] Removing old DTUSecure profile (if any)..."
nmcli connection delete "$CON_NAME" 2>/dev/null || true

echo "[3/4] Creating DTUSecure profile..."
nmcli connection add \
  type wifi \
  con-name "$CON_NAME" \
  ssid "$SSID" \
  wifi-sec.key-mgmt wpa-eap \
  802-1x.eap peap \
  802-1x.phase2-auth mschapv2 \
  802-1x.identity "$IDENTITY" \
  802-1x.password "$PASSWORD" \
  802-1x.anonymous-identity "${SITE_WIFI_ANON_IDENTITY}" \
  connection.autoconnect yes \
  connection.autoconnect-priority 10

# Wired connections have default priority 0 (higher = more preferred in NM,
# but wired is always preferred when the cable is present because NM
# deactivates lower-priority connections when a higher-priority one activates).
# Priority 10 ensures DTUSecure connects automatically among WiFi networks,
# but a connected Ethernet will always win.

echo "[4/4] Verifying profile..."
nmcli connection show "$CON_NAME" | grep -E "connection\.(id|autoconnect|type)|802-1x\.(eap|identity|phase2)|wifi\.ssid" || true

ok "DTUSecure WiFi configured."
echo "    SSID     : $SSID"
echo "    Identity : $IDENTITY"
echo "    Auth     : PEAP / MSCHAPv2"
echo "    Auto-connect: yes (priority 10 — Ethernet always wins)"
echo "    NM will connect automatically when DTUSecure is in range."
