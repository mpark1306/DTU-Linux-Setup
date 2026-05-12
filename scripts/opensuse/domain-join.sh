#!/usr/bin/env bash
###############################################################################
# DTU Sustain – openSUSE Tumbleweed – Module: Domain Join (WIN.DTU.DK)
# Joins the machine to the WIN.DTU.DK Active Directory domain using
# realmd + SSSD. Configures mkhomedir so domain users get a home
# directory on first login.
#
# Env: DTU_HOSTNAME       – hostname to set before joining (e.g. DTU-SUS-PC01)
#      DTU_ADMIN_USERNAME – domain admin username (e.g. adm-<username>)
#      DTU_USERNAME       – fallback if DTU_ADMIN_USERNAME is unset
#      DTU_ADMIN_PASSWORD – domain admin password
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
need_root

banner "Domain Join – ${SITE_AD_DOMAIN} (realmd + SSSD)"

DOMAIN="${SITE_AD_DOMAIN}"
ADMIN_USER="${DTU_ADMIN_USERNAME:-$(get_username)}"

echo "[1/8] Setting hostname..."
if [ -n "${DTU_HOSTNAME:-}" ]; then
  hostnamectl set-hostname "$DTU_HOSTNAME"
  ok "Hostname set to $DTU_HOSTNAME"
else
  warn "DTU_HOSTNAME not set — keeping current hostname: $(hostname)"
fi

echo "[2/8] Installing required packages..."
zypper --non-interactive install \
  realmd \
  sssd \
  sssd-tools \
  sssd-ad \
  adcli \
  krb5-client \
  samba-client \
  oddjob \
  oddjob-mkhomedir

echo "[3/8] Discovering domain..."
if ! realm discover "$DOMAIN"; then
  fail "Could not discover domain $DOMAIN. Check DNS and network."
  exit 1
fi
ok "Domain $DOMAIN discovered."

echo "[4/8] Joining domain..."
if realm list 2>/dev/null | grep -qi "$DOMAIN"; then
  warn "Already joined to $DOMAIN — re-joining..."
  realm leave "$DOMAIN" 2>/dev/null || true
fi

# Open an interactive terminal for realm join — password entry requires a TTY.
echo "Opening Konsole for interactive domain join..."
echo "Please enter the password for ${ADMIN_USER} when prompted."

JOIN_SCRIPT=$(mktemp /tmp/dtu-join-XXXXXX.sh)
cat > "$JOIN_SCRIPT" <<JOINEOF
#!/usr/bin/env bash
echo "══════════════════════════════════════════════════════════"
echo "  Domain Join — ${DOMAIN}"
echo "  Admin user: ${ADMIN_USER}"
echo "══════════════════════════════════════════════════════════"
echo ""
realm join -U "${ADMIN_USER}" "${DOMAIN}"
JOIN_RC=\$?
if [ \$JOIN_RC -eq 0 ]; then
  echo ""
  echo "✅ Domain join succeeded! This window will close in 3 seconds..."
  sleep 3
else
  echo ""
  echo "❌ Domain join failed (exit code \$JOIN_RC)."
  echo "Press Enter to close this window..."
  read -r
fi
exit \$JOIN_RC
JOINEOF
chmod 700 "$JOIN_SCRIPT"

# Try konsole first (KDE), fall back to xterm
if command -v konsole >/dev/null 2>&1; then
  konsole --separate -e bash "$JOIN_SCRIPT"
  JOIN_EXIT=$?
elif command -v xterm >/dev/null 2>&1; then
  xterm -title "DTU Domain Join" -e bash "$JOIN_SCRIPT"
  JOIN_EXIT=$?
else
  # Last resort: run inline (may hang if no TTY)
  bash "$JOIN_SCRIPT"
  JOIN_EXIT=$?
fi

rm -f "$JOIN_SCRIPT"

if [ $JOIN_EXIT -ne 0 ]; then
  fail "Domain join failed."
  exit 1
fi
ok "Successfully joined $DOMAIN."

echo "[5/8] Configuring SSSD..."
if [ -f /etc/sssd/sssd.conf ]; then
  sed -i 's/^use_fully_qualified_names\s*=.*/use_fully_qualified_names = False/' /etc/sssd/sssd.conf
  sed -i 's|^fallback_homedir\s*=.*|fallback_homedir = /home/%u|' /etc/sssd/sssd.conf

  if ! grep -q "^use_fully_qualified_names" /etc/sssd/sssd.conf; then
    sed -i "/^\[domain\/${DOMAIN}\]/a use_fully_qualified_names = False" /etc/sssd/sssd.conf
  fi
  if ! grep -q "^fallback_homedir" /etc/sssd/sssd.conf; then
    sed -i "/^\[domain\/${DOMAIN}\]/a fallback_homedir = /home/%u" /etc/sssd/sssd.conf
  fi

  chmod 600 /etc/sssd/sssd.conf
fi
ok "SSSD configured (short usernames, /home/%u)."

echo "[6/8] Enabling mkhomedir + setting default KDE X11 session for new users..."
pam-config --add --mkhomedir

# GDM reads ~/.dmrc to pick the default session for a user who hasn't logged
# in before. Writing it to /etc/skel ensures every new domain user starts in
# KDE Plasma on X11 rather than Wayland.
if [[ -f /usr/share/xsessions/plasmaX11.desktop ]]; then
    KDE_X11_SESSION="plasmaX11"
else
    KDE_X11_SESSION="plasma"  # fallback
fi
cat > /etc/skel/.dmrc <<DMRC
[Desktop]
Session=${KDE_X11_SESSION}
DMRC
chmod 0644 /etc/skel/.dmrc
ok "Default session set to '${KDE_X11_SESSION}' (X11) for all new users via /etc/skel/.dmrc."

echo "[7/8] Restarting services..."
systemctl restart sssd
systemctl enable sssd

echo "[8/8] Verifying domain membership..."
realm list
echo ""

if id "${ADMIN_USER}@${DOMAIN}" >/dev/null 2>&1 || id "${ADMIN_USER}" >/dev/null 2>&1; then
  ok "Domain user '${ADMIN_USER}' resolved successfully."
else
  warn "Could not resolve domain user '${ADMIN_USER}' yet. SSSD may need a moment to sync."
fi

ok "Domain join complete: $DOMAIN"
echo "    SSSD: use_fully_qualified_names = False"
echo "    Home: /home/<username> (auto-created on login)"
echo "    Test: id <username>  or  su - <username>"
