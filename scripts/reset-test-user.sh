#!/usr/bin/env bash
###############################################################################
# DTU Sustain – Reset Test User
#
# Removes a domain user's per-user state and home directory so the machine
# is ready for the real domain user's first login.
#
# Run as root:  sudo bash reset-test-user.sh <username>
#
# What it does:
#   1. Stops user systemd services (sync-homedir, onedrive)
#   2. Unmounts CIFS shares and removes fstab entries
#   3. Removes CUPS credentials for the user
#   4. Disables linger
#   5. Deletes the home directory
#   6. Resets mountpoint ownership
#
# What it does NOT touch:
#   - System-wide installs (scripts in /usr/local/bin, /etc/skel, printers etc.)
#   - Domain membership (the machine stays joined)
#   - Other users
###############################################################################
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

banner()  { echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}\n"; }
ok()      { echo -e "${GREEN}✅ $1${NC}"; }
warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
fail()    { echo -e "${RED}❌ $1${NC}"; }

if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as root (use sudo)."
    exit 1
fi

if [[ -z "${1:-}" && -z "${DTU_USERNAME:-}" ]]; then
    echo "Usage: sudo bash $0 <username>"
    echo "  or:  DTU_USERNAME=<username> sudo bash $0"
    echo ""
    echo "Removes all per-user DTU setup state for <username> so the"
    echo "machine is clean for the next domain user's first login."
    exit 1
fi

USERNAME="${1:-$DTU_USERNAME}"
HOME_DIR="/home/${USERNAME}"

banner "Reset test user: ${USERNAME}"

# ── Safety check ─────────────────────────────────────────────
echo "This will PERMANENTLY delete:"
echo "  • Home directory: ${HOME_DIR}"
echo "  • CIFS fstab entries referencing ${USERNAME}"
echo "  • CUPS credentials in /etc/cups/print-sustain.creds"
echo "  • Systemd linger for ${USERNAME}"
echo ""
if [[ -t 0 ]]; then
    # Interactive terminal — require typed confirmation
    read -rp "Type the username to confirm: " CONFIRM
    if [[ "$CONFIRM" != "$USERNAME" ]]; then
        fail "Confirmation failed. Aborting."
        exit 1
    fi
else
    # Non-interactive (GUI) — DTU_USERNAME was already confirmed in dialog
    echo "(Non-interactive mode — proceeding with ${USERNAME})"
fi

# ── Step 1: Stop user services ───────────────────────────────
echo "[1/7] Stopping user services..."
if id "$USERNAME" &>/dev/null; then
    UID_NUM=$(id -u "$USERNAME")

    # Stop user systemd services if the user session is running
    if [[ -d "/run/user/${UID_NUM}" ]]; then
        sudo -u "$USERNAME" XDG_RUNTIME_DIR="/run/user/${UID_NUM}" \
            systemctl --user stop sync-homedir.timer 2>/dev/null || true
        sudo -u "$USERNAME" XDG_RUNTIME_DIR="/run/user/${UID_NUM}" \
            systemctl --user stop sync-homedir.service 2>/dev/null || true
        sudo -u "$USERNAME" XDG_RUNTIME_DIR="/run/user/${UID_NUM}" \
            systemctl --user stop onedrive.service 2>/dev/null || true
        ok "User services stopped."
    else
        echo "  No active user session found — skipping."
    fi
else
    warn "User '${USERNAME}' not found in passwd/SSSD. Continuing with cleanup..."
fi

# ── Step 2: Unmount CIFS shares ──────────────────────────────
echo "[2/7] Unmounting CIFS shares..."
systemctl stop mnt-Qdrev.automount 2>/dev/null || true
systemctl stop mnt-Personal.automount 2>/dev/null || true
umount /mnt/Qdrev 2>/dev/null || true
umount /mnt/Personal 2>/dev/null || true
ok "Shares unmounted."

# ── Step 3: Clean fstab ─────────────────────────────────────
echo "[3/7] Removing fstab entries referencing ${USERNAME}..."
if grep -q "${USERNAME}" /etc/fstab 2>/dev/null; then
    # Back up fstab first
    cp /etc/fstab /etc/fstab.bak-reset-$(date +%Y%m%d%H%M%S)
    sed -i "/${USERNAME}/d" /etc/fstab
    # Also remove entries with the credential file path
    sed -i "\|smbcred-<fileserver>|d" /etc/fstab
    systemctl daemon-reload
    ok "fstab entries removed. Backup at /etc/fstab.bak-reset-*"
elif grep -q "smbcred-<fileserver>" /etc/fstab 2>/dev/null; then
    cp /etc/fstab /etc/fstab.bak-reset-$(date +%Y%m%d%H%M%S)
    sed -i "\|smbcred-<fileserver>|d" /etc/fstab
    systemctl daemon-reload
    ok "fstab CIFS entries removed."
else
    echo "  No matching fstab entries found."
fi

# ── Step 4: Remove CUPS credentials ─────────────────────────
echo "[4/7] Removing CUPS credentials..."
if [[ -f /etc/cups/print-sustain.creds ]]; then
    rm -f /etc/cups/print-sustain.creds
    ok "CUPS credentials removed."
else
    echo "  No CUPS credentials found."
fi

# ── Step 5: Disable linger ──────────────────────────────────
echo "[5/7] Disabling linger..."
loginctl disable-linger "$USERNAME" 2>/dev/null || true
rm -f "/var/lib/systemd/linger/${USERNAME}" 2>/dev/null || true
ok "Linger disabled."

# ── Step 6: Delete home directory ────────────────────────────
echo "[6/7] Deleting home directory ${HOME_DIR}..."
if [[ -d "$HOME_DIR" ]]; then
    rm -rf "$HOME_DIR"
    ok "Home directory deleted."
else
    echo "  Home directory not found — already clean."
fi

# ── Step 7: Reset mountpoints ───────────────────────────────
echo "[7/7] Resetting mountpoint ownership..."
for mp in /mnt/Qdrev /mnt/Personal; do
    if [[ -d "$mp" ]]; then
        chown root:root "$mp"
        chmod 0755 "$mp"
        echo "  → Reset $mp"
    fi
done
# Clean Pdrev symlink if it exists
rm -f /mnt/Pdrev 2>/dev/null || true
ok "Mountpoints reset."

echo ""
banner "Reset complete"
echo "The machine is ready for the next domain user to log in."
echo ""
echo "What's preserved:"
echo "  • Domain membership (WIN.DTU.DK)"
echo "  • Installed software (Flatpaks, Snaps, Cisco)"
echo "  • System-wide scripts (/usr/local/bin/*, /etc/skel/*)"
echo "  • Printers (FollowMe queues — creds will be re-created)"
echo "  • First-login autostart (will trigger for new user)"
echo ""
echo "Next domain user login → welcome dialog → credentials → fully configured."
