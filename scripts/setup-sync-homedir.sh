#!/bin/bash
###############################################################################
# setup-sync-homedir.sh — Lokal installation af sync-homedir
#
# Kør som din egen bruger. Installerer sync-script, systemd units og
# aktiverer timeren. Kræver IKKE root.
###############################################################################
set -e

SCRIPT_SRC="$(cd "$(dirname "$0")" && pwd)/sync-homedir.sh"
SCRIPT_DST="$HOME/.local/bin/sync-homedir.sh"
SERVICE_DIR="$HOME/.config/systemd/user"

echo "=== Opretter mapper ==="
mkdir -p "$HOME/.local/bin"
mkdir -p "$SERVICE_DIR"
mkdir -p "$HOME/Desktop" "$HOME/Documents" "$HOME/Pictures"

echo "=== Kopierer sync-script ==="
cp "$SCRIPT_SRC" "$SCRIPT_DST"
chmod +x "$SCRIPT_DST"

echo "=== Skriver systemd service ==="
cat > "$SERVICE_DIR/sync-homedir.service" <<EOF
[Unit]
Description=Sync home directories to network drive
After=network-online.target

[Service]
Type=oneshot
ExecStart=${SCRIPT_DST}

[Install]
WantedBy=default.target
EOF

echo "=== Skriver systemd timer ==="
cat > "$SERVICE_DIR/sync-homedir.timer" <<EOF
[Unit]
Description=Periodisk sync af home-mapper til netværksdrev

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s

[Install]
WantedBy=timers.target
EOF

echo "=== Aktiverer timer ==="
systemctl --user daemon-reload
systemctl --user enable --now sync-homedir.timer
systemctl --user enable sync-homedir.service

echo ""
echo "=== Status ==="
systemctl --user status sync-homedir.timer --no-pager

echo ""
echo "=== Kør manuelt for at teste ==="
echo "  $SCRIPT_DST"
echo "  Eller: systemctl --user start sync-homedir.service"
echo ""
echo "=== Log findes her ==="
echo "  ~/.local/share/sync-homedir.log"
