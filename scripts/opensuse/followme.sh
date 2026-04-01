#!/usr/bin/env bash
###############################################################################
# DTU Sustain – openSUSE Tumbleweed – Module: FollowMe Printers
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

CUPS_BACKEND_DIR="/usr/lib/cups/backend"

echo "[1/8] Installing packages..."
zypper --non-interactive install cups samba-client
zypper --non-interactive install OpenPrintingPPDs-postscript 2>/dev/null \
  || zypper --non-interactive install OpenPrintingPPDs 2>/dev/null \
  || warn "Could not install OpenPrintingPPDs — using generic PostScript PPD."

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
SMBSPOOL_BIN="/usr/bin/smbspool"
[[ -x "${CUPS_BACKEND_DIR}/smb" ]] && SMBSPOOL_BIN="${CUPS_BACKEND_DIR}/smb"
[[ -x "/usr/bin/smbspool" ]] && SMBSPOOL_BIN="/usr/bin/smbspool"

cat > "${CUPS_BACKEND_DIR}/smbspool-auth" <<BACKEND
#!/usr/bin/env bash
set -euo pipefail
CREDS="/etc/cups/print-sustain.creds"
if [ \$# -eq 0 ]; then exit 0; fi
USER_LINE=\$(grep -E "^username=" "\$CREDS" | head -n1 | cut -d= -f2-)
PASS_LINE=\$(grep -E "^password=" "\$CREDS" | head -n1 | cut -d= -f2-)
DOMAIN="\${USER_LINE%%\\\\\\\\*}"
UNAME="\${USER_LINE##*\\\\\\\\}"
URI="\${DEVICE_URI#smbspool-auth://}"
export DEVICE_URI="smb://\${DOMAIN}/\${UNAME}:\${PASS_LINE}@\${URI}"
exec ${SMBSPOOL_BIN} "\$@"
BACKEND
chmod 755 "${CUPS_BACKEND_DIR}/smbspool-auth"
rm -f "${CUPS_BACKEND_DIR}/smb-auth" 2>/dev/null || true

echo "[6/8] Removing old queues..."
lpadmin -x FollowMe-MFP-PCL 2>/dev/null || true
lpadmin -x FollowMe-Plot-PS  2>/dev/null || true

PPD_MODEL="drv:///sample.drv/generic.ppd"

echo "[7/8] Adding FollowMe printers..."
lpadmin -p FollowMe-MFP-PCL -E \
  -v "smbspool-auth://konfigureret via site.conf/FollowMe-MFP-PCL" \
  -m "$PPD_MODEL" \
  -o job-sheets=none,none

lpadmin -p FollowMe-Plot-PS -E \
  -v "smbspool-auth://konfigureret via site.conf/FollowMe-Plot-PS" \
  -m "$PPD_MODEL" \
  -o job-sheets=none,none

systemctl restart cups

echo "[8/8] Verifying..."
lpstat -p FollowMe-MFP-PCL || true
lpstat -p FollowMe-Plot-PS  || true

ok "FollowMe printers configured."
echo "    Check with: lpstat -W completed | head"
