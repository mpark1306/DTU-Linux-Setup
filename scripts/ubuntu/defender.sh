#!/usr/bin/env bash
###############################################################################
# DTU Sustain – Ubuntu 24.04 – Module: Microsoft Defender for Endpoint
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
need_root

banner "Microsoft Defender for Endpoint"

# Onboarding downloads from a site-specific URL — refuse to run without it.
site_require SITE_DEFENDER_ONBOARDING_URL

export DEBIAN_FRONTEND=noninteractive
# Network Protection is only supported on the Insiders Slow/Fast channels —
# this script installs from Production, where it always fails to start
# ("unsupported release ring") and makes mdatp report unhealthy forever.
NP_MODE="${NP_MODE:-disabled}"

# Ikke '. /etc/os-release': den laegger ~20 variabler i dette scripts
# navnerum, og scriptet koerer under 'set -u'. Hjaelperne i common.sh laeser
# kun den noegle der spoerges om.
UBUNTU_VER="$(ubuntu_version || true)"
UBUNTU_CODE="$(os_release_value VERSION_CODENAME || true)"
if [[ -z "$UBUNTU_VER" ]]; then
    die "Defender is only packaged for Ubuntu. /etc/os-release says ID=$(os_release_value ID || true)."
fi
echo "[i] Detected: Ubuntu ${UBUNTU_VER} (${UBUNTU_CODE})"

# Cleanup old artifacts
rm -f /etc/apt/sources.list.d/microsoft-prod.list || true
rm -f /etc/apt/keyrings/microsoft.gpg || true
rm -f /etc/apt/trusted.gpg.d/microsoft.gpg || true
rm -f /usr/local/bin/mdatp || true

echo "[1/6] Installing prerequisites..."
apt_wait
apt-get update -y || warn "apt-get update reported errors (likely a broken third-party repository); continuing."
apt-get install -y curl ca-certificates gnupg apt-transport-https

echo "[2/6] Installing Microsoft keyring..."
# Microsoft udgiver ikke en config-mappe for en ny Ubuntu-udgivelse med det
# samme, saa en 26.04-maskine kan moede en 404 i maaneder. .deb'en goer kun to
# ting: laegger en apt-kilde og en noegle. Findes vores udgivelse ikke endnu,
# er det rigtige at bruge den nyeste der ER udgivet og SIGE det, frem for at
# doe paa en curl-fejl der ikke naevner aarsagen.
MS_CONFIG_VER=""
for cand in "$UBUNTU_VER" 26.04 24.04 22.04; do
    if [[ -z "$cand" ]]; then continue; fi
    if curl -fsSL "https://packages.microsoft.com/config/ubuntu/${cand}/packages-microsoft-prod.deb" \
         -o /tmp/packages-microsoft-prod.deb; then
        MS_CONFIG_VER="$cand"; break
    fi
done
if [[ -z "$MS_CONFIG_VER" ]]; then
    die "No packages.microsoft.com config for Ubuntu ${UBUNTU_VER} or any older release. Check the network and https://packages.microsoft.com/config/ubuntu/"
fi
if [[ "$MS_CONFIG_VER" != "$UBUNTU_VER" ]]; then
    warn "Microsoft has no repo for Ubuntu ${UBUNTU_VER} yet; using the ${MS_CONFIG_VER} one."
    warn "mdatp will install from the ${MS_CONFIG_VER} suite. Re-run this module once ${UBUNTU_VER} is published."
fi
dpkg -i /tmp/packages-microsoft-prod.deb
apt-get update -y || warn "apt-get update reported errors (likely a broken third-party repository); continuing."

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
  "${SITE_DEFENDER_ONBOARDING_URL}"
python3 /tmp/MicrosoftDefenderATPOnboardingLinuxServer.py || true

mdatp config passive-mode --value disabled || true
mdatp config real-time-protection --value enabled || true
case "$NP_MODE" in
  audit|block) mdatp config network-protection enforcement-level --value "$NP_MODE" || true ;;
esac

if [[ -n "${SUDO_USER:-}" ]]; then
  usermod -aG mdatp "$SUDO_USER" || true
fi

echo "[6/7] Scheduling automatic quick scans (systemd timer)..."
cat > /etc/systemd/system/mdatp-quick-scan.service <<'UNIT'
[Unit]
Description=Microsoft Defender for Endpoint – Scheduled Quick Scan
Documentation=https://learn.microsoft.com/en-us/defender-endpoint/linux-schedule-scan-mde
After=mdatp.service
Requires=mdatp.service

[Service]
Type=oneshot
ExecStart=/usr/bin/mdatp scan quick
StandardOutput=journal
StandardError=journal
SyslogIdentifier=mdatp-quick-scan
UNIT

cat > /etc/systemd/system/mdatp-quick-scan.timer <<'UNIT'
[Unit]
Description=Microsoft Defender for Endpoint – Daily Quick Scan
Documentation=https://learn.microsoft.com/en-us/defender-endpoint/linux-schedule-scan-mde

[Timer]
OnCalendar=*-*-* 02:00:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
systemctl enable --now mdatp-quick-scan.timer
ok "Quick scan scheduled daily at 02:00 (±30 min random delay)."
echo "    Check:  systemctl status mdatp-quick-scan.timer"
echo "    Logs:   journalctl -u mdatp-quick-scan.service"
echo "    Manual: mdatp scan quick"

echo "[7/7] Final checks..."
mdatp definitions update || true
sleep 5
mdatp health || true
mdatp version || true
ok "Microsoft Defender installed on Ubuntu ${UBUNTU_VER}"
