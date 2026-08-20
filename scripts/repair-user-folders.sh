#!/usr/bin/env bash
###############################################################################
# DTU Linux Setup – Repair Home Folders & Network Drive Setup
#
# Cleans up leftovers from earlier / interrupted installs where Desktop,
# Documents or Pictures ended up as broken symlinks or got renamed to
# <name>.bak by an old mount script, leaving the user without access to
# their own folders. Also removes duplicate CIFS fstab entries left behind
# by repeated Network Drives runs.
#
# Run as root:  sudo bash repair-user-folders.sh <username>
#          or:  DTU_USERNAME=<username> sudo bash repair-user-folders.sh
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
need_root

if [[ -z "${1:-}" && -z "${DTU_USERNAME:-}" ]]; then
  echo "Usage: sudo bash $0 <username>"
  echo "  or:  DTU_USERNAME=<username> sudo bash $0"
  exit 1
fi

USERNAME="${1:-$DTU_USERNAME}"
HOME_DIR="/home/${USERNAME}"

if ! id "$USERNAME" >/dev/null 2>&1; then
  fail "User '${USERNAME}' not found on this machine."
  exit 1
fi
if [[ ! -d "$HOME_DIR" ]]; then
  fail "Home directory '${HOME_DIR}' not found."
  exit 1
fi

UID_NUM="$(id -u "$USERNAME")"
GID_NUM="$(id -g "$USERNAME")"

banner "Repair home folders & network drive setup for ${USERNAME}"

DIRS=(Desktop Documents Pictures)

echo "[1/3] Checking Desktop/Documents/Pictures..."
for DIR in "${DIRS[@]}"; do
  TARGET="${HOME_DIR}/${DIR}"
  BACKUP="${TARGET}.bak"

  # -e follows symlinks, so a dangling/unreachable symlink fails this test
  # even though -L (or a plain ls) would still show the entry.
  if [[ -L "$TARGET" && ! -e "$TARGET" ]]; then
    warn "${DIR}: broken symlink (target unreachable) — removing"
    rm -f "$TARGET"
  fi

  if [[ ! -e "$TARGET" && -d "$BACKUP" ]]; then
    ok "${DIR}: restoring from ${DIR}.bak"
    mv "$BACKUP" "$TARGET"
  elif [[ ! -e "$TARGET" ]]; then
    warn "${DIR}: missing and no ${DIR}.bak found — creating empty folder"
    mkdir -p "$TARGET"
  elif [[ -d "$BACKUP" ]]; then
    # A working folder exists but an old .bak sibling is still lying
    # around — merge its contents in rather than silently losing them.
    warn "${DIR}: found leftover ${DIR}.bak next to a working ${DIR} — merging contents"
    cp -an "${BACKUP}/." "${TARGET}/" 2>/dev/null || true
    rm -rf "$BACKUP"
  fi

  chown -R "${UID_NUM}:${GID_NUM}" "$TARGET"
  chmod 0700 "$TARGET"
done
ok "Home folders checked."

echo "[2/3] Deduplicating CIFS fstab entries..."
FSTAB="/etc/fstab"
if [[ -f "$FSTAB" ]]; then
  cp -a "$FSTAB" "${FSTAB}.dtu.bak.$(date +%s)"
  for MP in /mnt/Qdrev /mnt/Personal /mnt/Mdrev /mnt/Odrev; do
    COUNT="$(grep -cE "[[:space:]]${MP}[[:space:]].*cifs" "$FSTAB" || true)"
    if (( COUNT > 1 )); then
      warn "${MP}: ${COUNT} duplicate fstab entries found — keeping the last one"
      LAST_LINE="$(grep -E "[[:space:]]${MP}[[:space:]].*cifs" "$FSTAB" | tail -1)"
      sed -i "\|[[:space:]]${MP}[[:space:]].*cifs|d" "$FSTAB"
      echo "$LAST_LINE" >> "$FSTAB"
    fi
  done
  systemctl daemon-reload
  ok "fstab deduplicated. Backup: ${FSTAB}.dtu.bak.*"
else
  warn "No /etc/fstab found — skipping."
fi

echo "[3/3] Verifying access as ${USERNAME}..."
FAILS=0
for DIR in "${DIRS[@]}"; do
  TARGET="${HOME_DIR}/${DIR}"
  if sudo -u "$USERNAME" test -r "$TARGET" -a -w "$TARGET" -a -x "$TARGET"; then
    ok "${DIR}: read/write/access OK"
  else
    fail "${DIR}: ${USERNAME} does NOT have full access"
    FAILS=$((FAILS + 1))
  fi
done

if (( FAILS > 0 )); then
  fail "Repair completed with ${FAILS} folder(s) still inaccessible. Check ownership/permissions manually."
  exit 1
fi

ok "Repair complete — ${USERNAME} has full access to Desktop, Documents and Pictures."
echo "    Run 'Network Drives' again if Q/P/M/O-Drive mounts still need to be (re)created."
