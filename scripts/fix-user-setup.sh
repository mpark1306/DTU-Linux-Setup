#!/usr/bin/env bash
###############################################################################
# Quick-fix for a user whose first-login setup didn't fully complete.
# Fixes:
#   1. Replaces broken symlinks with real LOCAL folders + xdg-user-dirs
#   2. Pulls existing files from P-Drive into local folders
#   3. Deploys sync-homedir (local → P-Drive, periodic + on login)
#   4. Fixes polkit rules (removes catch-all admin prompt)
#   5. Disables KDE Wallet prompts via config (no PAM changes)
#   6. Marks first-login as done so welcome dialog won't reappear
#
# Run as root:  sudo bash fix-user-setup.sh <username>
###############################################################################
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "Run as root: sudo $0 <username>"; exit 1; fi
if [[ -z "${1:-}" ]]; then echo "Usage: sudo $0 <username>"; exit 1; fi

USERNAME="$1"
HOME_DIR="/home/$USERNAME"
P_MOUNT="/mnt/Personal"
Q_MOUNT="/mnt/Qdrev"
REMOTE_BASE="${Q_MOUNT}/Personal/${USERNAME}"

if ! id "$USERNAME" &>/dev/null; then echo "User '$USERNAME' not found."; exit 1; fi
UID_NUM="$(id -u "$USERNAME")"
GID_NUM="$(id -g "$USERNAME")"

echo "=== Fixing setup for $USERNAME ==="

# ── 1/6. Replace symlinks with real local folders ────────────
echo "[1/6] Converting symlinks to local folders..."
for FOLDER in Desktop Documents Pictures Downloads Music Videos Templates Public; do
    DIR="${HOME_DIR}/${FOLDER}"

    if [[ -L "$DIR" ]]; then
        OLD_TARGET="$(readlink "$DIR")"
        rm -f "$DIR"
        mkdir -p "$DIR"
        chown "$UID_NUM":"$GID_NUM" "$DIR"

        if [[ -d "$OLD_TARGET" ]]; then
            echo "  → Copying files from $OLD_TARGET into local $FOLDER/"
            rsync -a --ignore-existing "$OLD_TARGET/" "$DIR/" 2>/dev/null || true
            chown -R "$UID_NUM":"$GID_NUM" "$DIR"
        fi
        echo "  ✅ $FOLDER → local folder (was symlink → $OLD_TARGET)"

    elif [[ -d "$DIR" ]]; then
        echo "  ✓ $FOLDER already a local folder"
    else
        mkdir -p "$DIR"
        chown "$UID_NUM":"$GID_NUM" "$DIR"
        echo "  ✅ $FOLDER → created local folder"
    fi
done

# Fix xdg-user-dirs so KDE/GNOME know where Desktop etc. are
echo "  Setting xdg-user-dirs..."
mkdir -p "${HOME_DIR}/.config"
cat > "${HOME_DIR}/.config/user-dirs.dirs" <<XDGEOF
XDG_DESKTOP_DIR="\$HOME/Desktop"
XDG_DOWNLOAD_DIR="\$HOME/Downloads"
XDG_DOCUMENTS_DIR="\$HOME/Documents"
XDG_MUSIC_DIR="\$HOME/Music"
XDG_PICTURES_DIR="\$HOME/Pictures"
XDG_VIDEOS_DIR="\$HOME/Videos"
XDG_TEMPLATES_DIR="\$HOME/Templates"
XDG_PUBLICSHARE_DIR="\$HOME/Public"
XDGEOF
chown "$UID_NUM":"$GID_NUM" "${HOME_DIR}/.config/user-dirs.dirs"
# Prevent xdg-user-dirs-update from overwriting on next login
echo "enabled=False" > "${HOME_DIR}/.config/user-dirs.conf"
chown "$UID_NUM":"$GID_NUM" "${HOME_DIR}/.config/user-dirs.conf"
echo "  ✅ xdg-user-dirs configured"

# ── 2/5. Seed from P-Drive if mounted ───────────────────────
echo "[2/5] Seeding local folders from P-Drive (if reachable)..."
# Trigger automount
ls "$Q_MOUNT" >/dev/null 2>&1 || true
ls "$P_MOUNT" >/dev/null 2>&1 || true
sleep 2

PDRIVE_OK=false
if mountpoint -q "$Q_MOUNT" 2>/dev/null || mountpoint -q "$P_MOUNT" 2>/dev/null; then
    PDRIVE_OK=true
fi

if $PDRIVE_OK; then
    # Determine source — prefer P_MOUNT, fall back to Q_MOUNT/Personal/user
    SRC_BASE=""
    if mountpoint -q "$P_MOUNT" 2>/dev/null && [[ -d "$P_MOUNT" ]]; then
        SRC_BASE="$P_MOUNT"
    elif [[ -d "$REMOTE_BASE" ]]; then
        SRC_BASE="$REMOTE_BASE"
    fi

    if [[ -n "$SRC_BASE" ]]; then
        for FOLDER in Desktop Documents Pictures Downloads; do
            SRC="${SRC_BASE}/${FOLDER}"
            DST="${HOME_DIR}/${FOLDER}"
            if [[ -d "$SRC" ]]; then
                rsync -a --ignore-existing "$SRC/" "$DST/" 2>/dev/null || true
                chown -R "$UID_NUM":"$GID_NUM" "$DST"
                echo "  ✅ Seeded $FOLDER from P-Drive"
            fi
        done
    else
        echo "  ⚠️  P-Drive mounted but user folder not found — skipping seed."
    fi
else
    echo "  ⚠️  P-Drive not reachable — local folders created empty. Sync will start when drive is available."
fi

# ── 3/5. Deploy sync-homedir for this user ───────────────────
echo "[3/5] Setting up periodic sync (local → P-Drive)..."

# Install sync script system-wide if not present
SYNC_SCRIPT="/usr/local/bin/sync-homedir.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SCRIPT_DIR}/sync-homedir.sh" ]]; then
    cp "${SCRIPT_DIR}/sync-homedir.sh" "$SYNC_SCRIPT"
    chmod 755 "$SYNC_SCRIPT"
fi

# Install systemd user units for this user
USER_SYSTEMD="${HOME_DIR}/.config/systemd/user"
mkdir -p "$USER_SYSTEMD"

cat > "${USER_SYSTEMD}/sync-homedir.service" <<'SVC'
[Unit]
Description=Sync home folders to Q-Drive

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sync-homedir.sh
SVC

cat > "${USER_SYSTEMD}/sync-homedir.timer" <<'TMR'
[Unit]
Description=Periodic home folder sync

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
Persistent=true

[Install]
WantedBy=timers.target
TMR

chown -R "$UID_NUM":"$GID_NUM" "${HOME_DIR}/.config/systemd"

# Enable timer for the user
su - "$USERNAME" -c "systemctl --user daemon-reload && systemctl --user enable --now sync-homedir.timer" 2>/dev/null || \
    echo "  ⚠️  Could not enable timer (user not logged in). It will activate on next login."

# Install login trigger
cat > /etc/profile.d/sync-homedir-login.sh <<'PROFILE'
#!/bin/bash
if command -v systemctl &>/dev/null && systemctl --user is-enabled sync-homedir.timer &>/dev/null 2>&1; then
    systemctl --user start sync-homedir.service &
fi
PROFILE
chmod 644 /etc/profile.d/sync-homedir-login.sh

echo "  ✅ Sync timer + login trigger installed."
echo "     Local Desktop/Documents/Pictures sync → Q-Drive every 15 min + on login."

# ── 4/6. Fix polkit rules (stop admin password prompts) ──────
echo "[4/6] Fixing polkit rules..."

# The catch-all 49-allow-username-input.rules forces AUTH_ADMIN_KEEP
# for every org.freedesktop.* and org.kde.* action — remove it.
if [[ -f /etc/polkit-1/rules.d/49-allow-username-input.rules ]]; then
    rm -f /etc/polkit-1/rules.d/49-allow-username-input.rules
    echo "  ✅ Removed 49-allow-username-input.rules (catch-all admin prompt)"
else
    echo "  ✓ 49-allow-username-input.rules already absent"
fi

# Ensure the desktop-users rules are in place (from automount.sh)
if [[ ! -f /etc/polkit-1/rules.d/45-desktop-users.rules ]]; then
    echo "  ⚠️  45-desktop-users.rules missing — polkit.sh / automount.sh may need to be re-run."
fi

systemctl restart polkit 2>/dev/null || true
echo "  ✅ Polkit restarted."

# ── 5/6. Disable KDE Wallet prompts (config only, no PAM) ───
echo "[5/6] Disabling KDE Wallet prompts..."

# Remove any broken pam_kwallet5 entries (safety net)
sed -i '/pam_kwallet5/d' /etc/pam.d/common-auth /etc/pam.d/common-session 2>/dev/null || true

# Configure wallet to not prompt — purely via config, no PAM needed
WALLET_CFG="${HOME_DIR}/.config/kwalletrc"
cat > "$WALLET_CFG" <<'KWALLETRC'
[Wallet]
Close When Idle=false
Close on Screensaver=false
Default Wallet=kdewallet
Enabled=true
First Use=false
Idle Timeout=10
Launch Manager=false
Leave Manager Open=false
Leave Open=true
Prompt on Open=false
Use One Wallet=true

[org.freedesktop.secrets]
apiEnabled=true
KWALLETRC
chown "$UID_NUM":"$GID_NUM" "$WALLET_CFG"
echo "  ✅ KDE Wallet configured (no prompts)."

# ── 6/6. Mark first-login as done ────────────────────────────
echo "[6/6] Marking first-login setup as complete..."
MARKER="${HOME_DIR}/.config/dtu-sustain-setup-done"
mkdir -p "$(dirname "$MARKER")"
date '+%F %T' > "$MARKER"
chown "$UID_NUM":"$GID_NUM" "$MARKER"

# Remove autostart entries so they don't pop up again
rm -f "${HOME_DIR}/.config/autostart/dtu-first-login.desktop"
rm -f "${HOME_DIR}/.config/autostart/dtu-qdrive-mount.desktop"
echo "  ✅ First-login marker set, autostart entries removed."

echo ""
echo "=== Done! ==="
echo "User $USERNAME should log out and back in."
echo ""
echo "  Desktop, Documents, Pictures, Downloads → LOCAL folders"
echo "  Sync → Q-Drive/Personal/$USERNAME every 15 min + on login"
echo "  KDE Wallet → auto-unlock (no more WiFi/app password prompts)"
