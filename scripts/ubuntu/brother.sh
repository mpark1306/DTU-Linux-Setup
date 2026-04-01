#!/usr/bin/env bash
###############################################################################
# DTU Sustain – Ubuntu 24.04 – Module: Brother P950NW Label Printer
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
need_root

banner "Brother P950NW Label Printer"

PRINTER_NAME="Brother_P950NW"
PRINTER_IP="10.61.1.9"
PPD_MODEL="ptouch:0/ppd/ptouch-driver/Brother-PT-P950NW-ptouch-pt.ppd"

echo "[1/5] Installing packages..."
apt-get update -qq
apt-get install -y cups printer-driver-ptouch

echo "[2/5] Enabling CUPS..."
systemctl enable --now cups
systemctl restart cups

echo "[3/5] Verifying PPD model..."
if ! lpinfo -m | grep -qF "$PPD_MODEL"; then
  fail "PPD model not found."
  lpinfo -m | grep -i ptouch || true
  exit 1
fi

echo "[4/5] Adding printer..."
lpadmin -x "$PRINTER_NAME" 2>/dev/null || true
lpadmin -p "$PRINTER_NAME" -E \
  -v "socket://$PRINTER_IP:9100" \
  -m "$PPD_MODEL"
lpadmin -p "$PRINTER_NAME" \
  -o PageSize=12mm \
  -o Resolution=360dpi \
  -o MirrorPrint=Normal \
  -o RequireMatchingLabelSize=noRequireMatchingLabelSize
cupsenable "$PRINTER_NAME"
cupsaccept "$PRINTER_NAME"

echo "[5/5] Final config:"
lpoptions -p "$PRINTER_NAME" -l | grep -E "PageSize|Resolution|MirrorPrint|RequireMatchingLabelSize"
lpoptions -p "$PRINTER_NAME"
ok "Brother P950NW added."
