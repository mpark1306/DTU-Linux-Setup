#!/usr/bin/env bash
###############################################################################
# DTU – openSUSE Tumbleweed – Module: DTUSecure WiFi auto-connect
#
# Creates a NetworkManager WPA2-Enterprise (PEAP/MSCHAPv2) profile for
# DTUSecure with stored domain credentials.
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

SSID="DTUSecure"
CON_NAME="DTUSecure"
IDENTITY="${DTU_USERNAME}@win.dtu.dk"
PASSWORD="$DTU_PASSWORD"

echo "[1/4] Ensuring NetworkManager + wpa_supplicant are installed..."
zypper --non-interactive install NetworkManager wpa_supplicant >/dev/null 2>&1 || true

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
  802-1x.anonymous-identity "anonymous@win.dtu.dk" \
  connection.autoconnect yes \
  connection.autoconnect-priority 10

echo "[4/4] Verifying profile..."
nmcli connection show "$CON_NAME" | grep -E "connection\.(id|autoconnect|type)|802-1x\.(eap|identity|phase2)|wifi\.ssid" || true

ok "DTUSecure WiFi configured."
echo "    SSID     : $SSID"
echo "    Identity : $IDENTITY"
echo "    Auth     : PEAP / MSCHAPv2"
echo "    Auto-connect: yes (Ethernet always wins)"
