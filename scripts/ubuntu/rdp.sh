#!/usr/bin/env bash
###############################################################################
# DTU Sustain – Ubuntu 24.04 – Module: RDP (xrdp + KDE Plasma session)
#
# Installs xrdp so users can RDP into the machine from Windows/Mac/Linux.
# Uses KDE Plasma (Wayland) as the session — not bare Xorg.
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
need_root

banner "RDP – Remote Desktop (xrdp + KDE Plasma)"

echo "[1/7] Installing xrdp and xorgxrdp..."
apt_wait
apt-get update -qq 2>/dev/null || true
apt-get install -y xrdp xorgxrdp >/dev/null

echo "[2/7] Adding xrdp user to ssl-cert group..."
usermod -aG ssl-cert xrdp

echo "[3/7] Configuring KDE Plasma session for xrdp..."
# xrdp runs startwm.sh on login — override to launch KDE Plasma (Wayland first, X11 fallback)
cat > /etc/xrdp/startwm.sh <<'STARTWM'
#!/bin/sh
# xrdp session starter – DTU Sustain
# Launches KDE Plasma for RDP sessions.

# Source user profile
if [ -r /etc/profile ]; then
    . /etc/profile
fi
if [ -r "$HOME/.profile" ]; then
    . "$HOME/.profile"
fi

# Prevent KDE from reusing the console session
unset DBUS_SESSION_BUS_ADDRESS
unset XDG_RUNTIME_DIR

# Prefer Plasma X11 for xrdp (Wayland over RDP is not yet stable)
if command -v startplasma-x11 >/dev/null 2>&1; then
    exec startplasma-x11
elif command -v startplasma-wayland >/dev/null 2>&1; then
    exec startplasma-wayland
else
    # Fallback
    exec xterm
fi
STARTWM
chmod 755 /etc/xrdp/startwm.sh

echo "[4/7] Tuning xrdp.ini (performance + security)..."
XRDP_INI="/etc/xrdp/xrdp.ini"
cp -n "$XRDP_INI" "${XRDP_INI}.orig" 2>/dev/null || true

# Force single-stack IPv4 bind. Default `port=3389` makes xrdp try IPv6
# *and* IPv4 separately; the IPv6 bind succeeds as dual-stack on Ubuntu
# 24.04 and the IPv4 bind then fails with EINVAL ("g_tcp_bind ... errno=22"),
# crashing the daemon. tcp://0.0.0.0:3389 forces a single IPv4 socket.
sed -i 's|^port=.*|port=tcp://0.0.0.0:3389|' "$XRDP_INI"
# Disable vsock listener (not used; can also clash on some systems)
sed -i 's/^use_vsock=.*/use_vsock=false/' "$XRDP_INI"

# Max colour depth 24-bit (good balance of quality and bandwidth)
sed -i 's/^max_bpp=.*/max_bpp=24/' "$XRDP_INI"
# Default colour depth
sed -i 's/^#\?xserverbpp=.*/xserverbpp=24/' "$XRDP_INI"

# Allow only TLS (disable plain RDP encryption)
sed -i 's/^security_layer=.*/security_layer=tls/' "$XRDP_INI"
sed -i 's/^crypt_level=.*/crypt_level=high/' "$XRDP_INI"

# Enable clipboard and drive redirection
sed -i 's/^#\?FuseMountName=.*/FuseMountName=thinclient_drives/' "$XRDP_INI"

echo "[5/7] Configuring polkit for RDP sessions..."
# RDP sessions need colord and login1 permissions
tee /etc/polkit-1/rules.d/45-xrdp.rules > /dev/null <<'POLKIT'
// Allow xrdp sessions to create colour profiles and manage sessions.
// Without this, KDE Plasma shows auth dialogs on every RDP login.
// Installed by DTU Linux Setup – rdp.sh

polkit.addRule(function(action, subject) {
    if ((action.id === "org.freedesktop.color-manager.create-device" ||
         action.id === "org.freedesktop.color-manager.create-profile" ||
         action.id === "org.freedesktop.color-manager.modify-device"  ||
         action.id === "org.freedesktop.color-manager.modify-profile" ||
         action.id === "org.freedesktop.color-manager.delete-device"  ||
         action.id === "org.freedesktop.color-manager.delete-profile") &&
        subject.isInGroup("Domain Users")) {
        return polkit.Result.YES;
    }
});
POLKIT

echo "[6/7] Enabling and starting xrdp..."
# Stop any prior instance and kill stragglers that might still hold port 3389.
systemctl stop xrdp xrdp-sesman 2>/dev/null || true
pkill -x xrdp 2>/dev/null || true
pkill -x xrdp-sesman 2>/dev/null || true
sleep 1
if ss -ltn 'sport = :3389' 2>/dev/null | grep -q ':3389'; then
  warn "Something else is listening on :3389 — xrdp may still fail to bind."
  ss -ltnp 'sport = :3389' || true
fi
systemctl enable xrdp
systemctl restart xrdp-sesman 2>/dev/null || systemctl start xrdp-sesman 2>/dev/null || true
systemctl restart xrdp

# Open firewall port if ufw is active
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  echo "  Opening port 3389/tcp in ufw..."
  ufw allow 3389/tcp comment "xrdp (RDP)" >/dev/null
fi

echo "[7/7] Verifying..."
if systemctl is-active --quiet xrdp; then
  ok "xrdp is running on port 3389."
else
  fail "xrdp failed to start."
  journalctl -u xrdp --no-pager -n 20
  exit 1
fi

ok "RDP configured – KDE Plasma session via xrdp."
echo "    Connect with any RDP client (Windows Remote Desktop, Remmina, etc.)"
echo "    Address: $(hostname -I | awk '{print $1}'):3389"
echo "    Login with your DTU domain credentials (WIN\\username)"
echo "    Session type: KDE Plasma"
