#!/usr/bin/env bash
set -euo pipefail

# Simple DTU Sustain FollowMe printer setup (Ubuntu/openSUSE)

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run as root: sudo $0"
  exit 1
fi

install_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y cups smbclient samba-common-bin >/dev/null
    return
  fi

  if command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install cups samba-client >/dev/null
    return
  fi

  echo "Unsupported distro: could not find apt-get or zypper."
  exit 1
}

install_deps

if ! command -v lpadmin >/dev/null 2>&1; then
  echo "CUPS tools not found (lpadmin) after dependency install."
  exit 1
fi

read -rp "DTU username (without WIN\\): " DTU_USERNAME
read -rsp "DTU password: " DTU_PASSWORD
echo

if [[ -z "$DTU_USERNAME" || -z "$DTU_PASSWORD" ]]; then
  echo "Username/password cannot be empty."
  exit 1
fi

if [[ -d "/usr/lib/cups/backend" ]]; then
  BACKEND_DIR="/usr/lib/cups/backend"
elif [[ -d "/usr/libexec/cups/backend" ]]; then
  BACKEND_DIR="/usr/libexec/cups/backend"
else
  echo "Could not locate CUPS backend directory."
  exit 1
fi

CREDS_FILE="/etc/cups/print-sustain.creds"
PPD_FILE="/usr/share/cups/model/KOC751iUX.ppd"

mkdir -p "$(dirname "$PPD_FILE")"

# Try to find PPD either from installed path or repo root.
if [[ -f "/opt/dtu-sustain-setup/KOC751iUX.ppd" ]]; then
  cp -f "/opt/dtu-sustain-setup/KOC751iUX.ppd" "$PPD_FILE"
elif [[ -f "$(pwd)/KOC751iUX.ppd" ]]; then
  cp -f "$(pwd)/KOC751iUX.ppd" "$PPD_FILE"
elif [[ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/KOC751iUX.ppd" ]]; then
  cp -f "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/KOC751iUX.ppd" "$PPD_FILE"
else
  echo "Could not find KOC751iUX.ppd."
  echo "Expected one of:"
  echo "  - /opt/dtu-sustain-setup/KOC751iUX.ppd"
  echo "  - ./KOC751iUX.ppd"
  echo "  - <repo>/KOC751iUX.ppd"
  exit 1
fi
chmod 644 "$PPD_FILE"

cat > "$CREDS_FILE" <<EOF
username=WIN\\${DTU_USERNAME}
password=${DTU_PASSWORD}
EOF
chown root:lp "$CREDS_FILE"
chmod 640 "$CREDS_FILE"

cat > "${BACKEND_DIR}/smbspool-auth" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
CREDS="/etc/cups/print-sustain.creds"
if [ $# -eq 0 ]; then
  exit 0
fi
USER_LINE=$(grep -E "^username=" "$CREDS" | head -n1 | cut -d= -f2-)
PASS_LINE=$(grep -E "^password=" "$CREDS" | head -n1 | cut -d= -f2-)
DOMAIN="${USER_LINE%%\\*}"
UNAME="${USER_LINE##*\\}"
URI="${DEVICE_URI#smbspool-auth://}"
export DEVICE_URI="smb://${DOMAIN}/${UNAME}:${PASS_LINE}@${URI}"

if command -v smbspool >/dev/null 2>&1; then
  exec smbspool "$@"
elif [[ -x /usr/lib/cups/backend/smb ]]; then
  exec /usr/lib/cups/backend/smb "$@"
elif [[ -x /usr/libexec/cups/backend/smb ]]; then
  exec /usr/libexec/cups/backend/smb "$@"
else
  echo "smbspool backend not found"
  exit 1
fi
EOF
chmod 755 "${BACKEND_DIR}/smbspool-auth"

if command -v systemctl >/dev/null 2>&1; then
  systemctl enable --now cups >/dev/null 2>&1 || true
  systemctl disable --now cups-browsed >/dev/null 2>&1 || true
fi

lpadmin -x FollowMe-MFP-PCL >/dev/null 2>&1 || true
lpadmin -x FollowMe-Plot-PS >/dev/null 2>&1 || true

lpadmin -p FollowMe-MFP-PCL -E \
  -v "smbspool-auth://print.sustain.dtu.dk/FollowMe-MFP-PCL" \
  -P "$PPD_FILE" \
  -o job-sheets=none,none

lpadmin -p FollowMe-Plot-PS -E \
  -v "smbspool-auth://print.sustain.dtu.dk/FollowMe-Plot-PS" \
  -P "$PPD_FILE" \
  -o job-sheets=none,none

if command -v systemctl >/dev/null 2>&1; then
  systemctl restart cups >/dev/null 2>&1 || true
fi

echo
echo "Done. Printers added:"
lpstat -p FollowMe-MFP-PCL || true
lpstat -p FollowMe-Plot-PS || true
echo
echo "Default printer status:"
lpstat -d || true
