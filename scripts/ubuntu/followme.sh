#!/usr/bin/env bash
###############################################################################
# DTU Sustain – Ubuntu 24.04 – Module: FollowMe Printers
# Env: DTU_USERNAME, DTU_PASSWORD (optional – falls back to interactive)
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
need_root

banner "DTU Sustain FollowMe Printers"

# Require credentials via environment (interactive prompts hang in GUI)
if [[ -z "${DTU_USERNAME:-}" || -z "${DTU_PASSWORD:-}" ]]; then
  fail "DTU_USERNAME and DTU_PASSWORD must be set. Run via the GUI or export them."
  exit 1
fi

U="$DTU_USERNAME"
P="$DTU_PASSWORD"

echo "[1/8] Installing packages..."
apt-get update -qq
apt-get install -y cups smbclient openprinting-ppds samba-common-bin

echo "[2/8] Enabling CUPS..."
systemctl enable --now cups

echo "[3/8] Disabling cups-browsed (if present)..."
systemctl disable --now cups-browsed 2>/dev/null || true

echo "[4/8] Writing credentials..."
cat > /etc/cups/print-sustain.creds <<CREDS
username=WIN\\\\${U}
password=${P}
CREDS
chown root:lp /etc/cups/print-sustain.creds
chmod 640 /etc/cups/print-sustain.creds

echo "[5/8] Installing smbspool-auth backend..."
cat > /usr/lib/cups/backend/smbspool-auth << "BACKEND"
#!/usr/bin/env bash
set -euo pipefail
CREDS="/etc/cups/print-sustain.creds"
if [ $# -eq 0 ]; then exit 0; fi
USER_LINE=$(grep -E "^username=" "$CREDS" | head -n1 | cut -d= -f2-)
PASS_LINE=$(grep -E "^password=" "$CREDS" | head -n1 | cut -d= -f2-)
DOMAIN="${USER_LINE%%\\\\*}"
UNAME="${USER_LINE##*\\\\}"
URI="${DEVICE_URI#smbspool-auth://}"
export DEVICE_URI="smb://${DOMAIN}/${UNAME}:${PASS_LINE}@${URI}"
exec /usr/bin/smbspool "$@"
BACKEND
chmod 755 /usr/lib/cups/backend/smbspool-auth
rm -f /usr/lib/cups/backend/smb-auth 2>/dev/null || true

echo "[6/8] Removing old queues..."
lpadmin -x FollowMe-MFP-PCL 2>/dev/null || true
lpadmin -x FollowMe-Plot-PS  2>/dev/null || true

echo "[7/8] Adding FollowMe printers..."
lpadmin -p FollowMe-MFP-PCL -E \
  -v "smbspool-auth://konfigureret via site.conf/FollowMe-MFP-PCL" \
  -m "openprinting-ppds:0/ppd/openprinting/KONICA_MINOLTA/KOC550UX.ppd" \
  -o job-sheets=none,none

lpadmin -p FollowMe-Plot-PS -E \
  -v "smbspool-auth://konfigureret via site.conf/FollowMe-Plot-PS" \
  -m "openprinting-ppds:0/ppd/openprinting/KONICA_MINOLTA/KOC550UX.ppd" \
  -o job-sheets=none,none

systemctl restart cups

echo "[8/8] Installing print-manager + test page..."
apt-get install -y print-manager 2>/dev/null || true
lp -d FollowMe-MFP-PCL /usr/share/cups/data/testprint >/dev/null || true

ok "FollowMe printers configured."
echo "    Check with: lpstat -W completed | head"
