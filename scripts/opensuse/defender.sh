#!/usr/bin/env bash
###############################################################################
# DTU Sustain – openSUSE Tumbleweed – Module: Microsoft Defender for Endpoint
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
need_root

banner "Microsoft Defender for Endpoint"

NP_MODE="${NP_MODE:-audit}"

. /etc/os-release
echo "[i] Detected: $NAME $VERSION_ID ($PRETTY_NAME)"

rm -f /etc/zypp/repos.d/microsoft-prod.repo 2>/dev/null || true
rm -f /usr/local/bin/mdatp 2>/dev/null || true

echo "[1/6] Installing prerequisites..."
zypper --non-interactive install curl ca-certificates gpg2

echo "[2/6] Adding Microsoft package repository..."
rpm --import https://packages.microsoft.com/keys/microsoft.asc
zypper --non-interactive addrepo --refresh --check \
  "https://packages.microsoft.com/yumrepos/microsoft-sles15-prod" \
  microsoft-prod 2>/dev/null || true
zypper --non-interactive --gpg-auto-import-keys refresh microsoft-prod || true

echo "[3/6] Installing mdatp..."
zypper --non-interactive install mdatp

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

if [[ -n "${SUDO_USER:-}" ]]; then
  usermod -aG mdatp "$SUDO_USER" || true
fi

echo "[6/6] Final checks..."
mdatp definitions update || true
sleep 5
mdatp health || true
mdatp version || true
ok "Microsoft Defender installed on $PRETTY_NAME"
warn "Note: Tumbleweed is not officially supported by Microsoft."
warn "Using SLES 15 packages. Monitor for compatibility issues."
