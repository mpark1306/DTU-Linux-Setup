#!/usr/bin/env bash
###############################################################################
# DTU Sustain – Ubuntu 24.04 – Module: Microsoft Defender for Endpoint
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
need_root

banner "Microsoft Defender for Endpoint"

export DEBIAN_FRONTEND=noninteractive
NP_MODE="${NP_MODE:-audit}"

. /etc/os-release
echo "[i] Detected: Ubuntu ${VERSION_ID} (${VERSION_CODENAME})"

# Cleanup old artifacts
rm -f /etc/apt/sources.list.d/microsoft-prod.list || true
rm -f /etc/apt/keyrings/microsoft.gpg || true
rm -f /etc/apt/trusted.gpg.d/microsoft.gpg || true
rm -f /usr/local/bin/mdatp || true

echo "[1/6] Installing prerequisites..."
apt_wait
apt-get update -y
apt-get install -y curl ca-certificates gnupg apt-transport-https

echo "[2/6] Installing Microsoft keyring..."
curl -fsSL "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" \
  -o /tmp/packages-microsoft-prod.deb
dpkg -i /tmp/packages-microsoft-prod.deb
apt-get update -y

echo "[3/6] Installing mdatp..."
apt-get install -y mdatp

echo "[4/6] Ensuring daemon paths..."
DAEMON="/opt/microsoft/mdatp/sbin/wdavdaemon"
CLIENT="/opt/microsoft/mdatp/sbin/wdavdaemonclient"
[[ -x "$DAEMON" ]] || { fail "Missing daemon: $DAEMON"; exit 1; }
chmod 0755 "$DAEMON" || true
[[ -x "$CLIENT" ]] && chmod 0755 "$CLIENT" || true
command -v mdatp >/dev/null || ln -sf "$CLIENT" /usr/bin/mdatp

if findmnt -T /opt -o OPTIONS -n | grep -qw noexec; then
  mount -o remount,exec /opt || warn "/opt is noexec"
fi

echo "[5/6] Enabling service + onboarding..."
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable --now mdatp

curl -fsSL -o /tmp/MicrosoftDefenderATPOnboardingLinuxServer.py \
  konfigureret via site.conf/download/MicrosoftDefenderATPOnboardingLinuxServer.py
python3 /tmp/MicrosoftDefenderATPOnboardingLinuxServer.py || true

mdatp config passive-mode --value disabled || true
mdatp config real-time-protection --value enabled || true
case "$NP_MODE" in
  audit|block) mdatp config network-protection --value "$NP_MODE" || true ;;
esac

if [[ -n "${SUDO_USER:-}" ]]; then
  usermod -aG mdatp "$SUDO_USER" || true
fi

echo "[6/6] Final checks..."
mdatp definitions update || true
sleep 5
mdatp health || true
mdatp version || true
ok "Microsoft Defender installed on Ubuntu ${VERSION_ID}"
