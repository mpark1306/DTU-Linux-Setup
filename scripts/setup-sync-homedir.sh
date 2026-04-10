#!/usr/bin/env bash
# deploy-sync-homedir.sh — Deploy sync-homedir to Ubuntu 24.04 workstations
# Run as root: sudo bash deploy-sync-homedir.sh
#
# Features:
#   • Backs up every file it touches before overwriting
#   • Automatically rolls back ALL changes on any error
#   • Pass --rollback to manually undo a previous deploy
set -euo pipefail

# ── Paths managed by this script ─────────────────────────────
SYNC_SCRIPT="/usr/local/bin/sync-homedir.sh"
SKEL_DIR="/etc/skel/.config/systemd/user"
SKEL_SERVICE="${SKEL_DIR}/sync-homedir.service"
SKEL_TIMER="${SKEL_DIR}/sync-homedir.timer"
PROFILE_SCRIPT="/etc/profile.d/sync-homedir-login.sh"

MANAGED_FILES=("$SYNC_SCRIPT" "$SKEL_SERVICE" "$SKEL_TIMER" "$PROFILE_SCRIPT")

# ── Backup / rollback helpers ────────────────────────────────
BACKUP_DIR=""
DEPLOYED_FILES=()
CREATED_DIRS=()

backup_file() {
  local file="$1"
  if [[ -f "$file" ]]; then
    local rel="${file#/}"
    mkdir -p "$BACKUP_DIR/$(dirname "$rel")"
    cp -p "$file" "$BACKUP_DIR/$rel"
    echo "  ↳ backed up $file"
  fi
}

ensure_dir() {
  local dir="$1"
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir"
    CREATED_DIRS+=("$dir")
    echo "  ↳ created $dir"
  fi
}

rollback() {
  echo ""
  echo "!!! Rolling back changes !!!"

  # Restore or remove each deployed file
  for file in "${DEPLOYED_FILES[@]}"; do
    local rel="${file#/}"
    if [[ -n "$BACKUP_DIR" && -f "$BACKUP_DIR/$rel" ]]; then
      cp -p "$BACKUP_DIR/$rel" "$file"
      echo "  ↳ restored $file from backup"
    elif [[ -f "$file" ]]; then
      rm -f "$file"
      echo "  ↳ removed $file (did not exist before)"
    fi
  done

  # Remove directories we created (in reverse order), only if empty
  for (( i=${#CREATED_DIRS[@]}-1 ; i>=0 ; i-- )); do
    local dir="${CREATED_DIRS[$i]}"
    if [[ -d "$dir" ]] && [[ -z "$(ls -A "$dir" 2>/dev/null)" ]]; then
      rmdir "$dir" 2>/dev/null || true
      echo "  ↳ removed empty directory $dir"
    fi
  done

  if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
    rm -rf "$BACKUP_DIR"
  fi

  echo "Rollback complete."
}

manual_rollback() {
  # Find the most recent backup
  local latest
  latest=$(find /tmp -maxdepth 1 -name 'sync-homedir-backup-*' -type d 2>/dev/null \
           | sort -r | head -1)
  if [[ -z "$latest" ]]; then
    echo "No backup found in /tmp — nothing to roll back."
    exit 1
  fi
  echo "=== Manual rollback from $latest ==="
  for file in "${MANAGED_FILES[@]}"; do
    local rel="${file#/}"
    if [[ -f "$latest/$rel" ]]; then
      cp -p "$latest/$rel" "$file"
      echo "  ↳ restored $file"
    elif [[ -f "$file" ]]; then
      rm -f "$file"
      echo "  ↳ removed $file (was not present before deploy)"
    fi
  done
  rm -rf "$latest"
  echo "Rollback complete — backup $latest removed."
  exit 0
}

# ── Handle --rollback flag ───────────────────────────────────
if [[ "${1:-}" == "--rollback" ]]; then
  manual_rollback
fi

# ── Pre-flight checks ───────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (sudo)." >&2
  exit 1
fi

echo "=== Deploy sync-homedir ==="

# ── Create backup directory ──────────────────────────────────
BACKUP_DIR=$(mktemp -d /tmp/sync-homedir-backup-XXXXXXXX)
echo "Backup directory: $BACKUP_DIR"

# ── Trap: rollback on ANY error ──────────────────────────────
trap rollback ERR

# ── Back up existing files ───────────────────────────────────
echo "[prep] Backing up existing files..."
for file in "${MANAGED_FILES[@]}"; do
  backup_file "$file"
done

# ── Dependencies ──────────────────────────────────────────────
echo "[1/6] Ensuring rsync is installed..."
apt-get install -y rsync > /dev/null

# ── Sync script ──────────────────────────────────────────────
echo "[2/6] Deploying $SYNC_SCRIPT..."
cat > "$SYNC_SCRIPT" << 'EOF'
#!/usr/bin/env bash
# sync-homedir.sh — rsync selected home dirs → Q-drev
set -euo pipefail

MOUNT_POINT="/mnt/Qdrev"
REMOTE_BASE="$MOUNT_POINT/Personal/$USER"
LOG="$HOME/.local/share/sync-homedir.log"
DIRS=("Desktop" "Documents" "Pictures")

mkdir -p "$(dirname "$LOG")"

if ! mountpoint -q "$MOUNT_POINT"; then
  echo "$(date '+%F %T') Drev ikke tilgængeligt, springer over." >> "$LOG"
  exit 0
fi

for DIR in "${DIRS[@]}"; do
  mkdir -p "$REMOTE_BASE/$DIR"
done

for DIR in "${DIRS[@]}"; do
  rsync -av --update \
    "$HOME/$DIR/" \
    "$REMOTE_BASE/$DIR/" \
    >> "$LOG" 2>&1
done

echo "$(date '+%F %T') Sync gennemført for $USER." >> "$LOG"
EOF
chmod 0755 "$SYNC_SCRIPT"
DEPLOYED_FILES+=("$SYNC_SCRIPT")

# ── Skeleton for new users ───────────────────────────────────
echo "[3/6] Creating skel systemd user directory..."
ensure_dir "$SKEL_DIR"
chmod 0755 "$SKEL_DIR"

echo "[4/6] Deploying service to skel..."
cat > "$SKEL_SERVICE" << 'EOF'
[Unit]
Description=Sync home directory
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sync-homedir.sh

[Install]
WantedBy=default.target
EOF
chmod 0644 "$SKEL_SERVICE"
DEPLOYED_FILES+=("$SKEL_SERVICE")

echo "[5/6] Deploying timer to skel..."
cat > "$SKEL_TIMER" << 'EOF'
[Unit]
Description=Periodic home directory sync

[Timer]
OnBootSec=2min
OnUnitActiveSec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF
chmod 0644 "$SKEL_TIMER"
DEPLOYED_FILES+=("$SKEL_TIMER")

# ── Login trigger ────────────────────────────────────────────
echo "[6/6] Deploying profile.d login script..."
cat > "$PROFILE_SCRIPT" << 'EOF'
#!/usr/bin/env bash
# sync-homedir-login.sh — trigger sync + enable timer on first login
if [ -n "$USER" ] && [ "$USER" != "root" ]; then
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable --now sync-homedir.timer 2>/dev/null || true
  systemctl --user start sync-homedir.service 2>/dev/null || true
fi
EOF
chmod 0755 "$PROFILE_SCRIPT"
DEPLOYED_FILES+=("$PROFILE_SCRIPT")

# ── Success — remove trap and keep backup for manual rollback
trap - ERR
echo ""
echo "=== Done — sync-homedir deployed ==="
echo "Backup kept at: $BACKUP_DIR"
echo "To undo:  sudo bash $0 --rollback"
