#!/usr/bin/env bash
###############################################################################
# DTU Sustain – Ubuntu 24.04 – Module: KDE Wallet auto-unlock
#
# Fixes the endless login/auth prompts domain users see after logging in.
# Root cause: pam_kwallet5 is not wired into PAM, so the default KDE Wallet
# ("kdewallet") is never unlocked automatically at login.
#
# What this script does:
#   1. Installs pam_kwallet5 (kwalletmanager package)
#   2. Adds pam_kwallet5 to PAM auth + session stacks
#   3. Creates /etc/skel kwalletrc  → new users auto-unlock on login
#   4. Patches existing user profiles so current users also benefit
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
need_root

banner "KDE Wallet – Auto-Unlock for Domain Users"

# ── 1/4: Install libpam-kwallet5 (ships pam_kwallet5.so) ─────────────────
echo "[1/4] Installing libpam-kwallet5..."
apt_wait
if ! apt-get install -y libpam-kwallet5 2>&1 | tail -1; then
    fail "Could not install libpam-kwallet5. Cannot continue."
    exit 1
fi

PAM_MODULE=""
for candidate in \
    /usr/lib/x86_64-linux-gnu/security/pam_kwallet5.so \
    /usr/lib/security/pam_kwallet5.so \
    /usr/lib64/security/pam_kwallet5.so; do
    if [[ -f "$candidate" ]]; then
        PAM_MODULE="$candidate"
        break
    fi
done

if [[ -z "$PAM_MODULE" ]]; then
    fail "pam_kwallet5.so not found after install. Cannot continue."
    exit 1
fi
ok "pam_kwallet5.so found at ${PAM_MODULE}"

# ── 2/4: Wire pam_kwallet5 into PAM ─────────────────────────────────────
echo "[2/4] Configuring PAM for KDE Wallet auto-unlock..."

# --- /etc/pam.d/common-auth ---
AUTH_FILE="/etc/pam.d/common-auth"
AUTH_LINE="auth    optional    pam_kwallet5.so"
if grep -qF "pam_kwallet5" "$AUTH_FILE" 2>/dev/null; then
    echo "  pam_kwallet5 already in ${AUTH_FILE} — skipping."
else
    # Insert BEFORE the final pam_deny / pam_permit line
    if grep -q "^auth.*pam_deny" "$AUTH_FILE"; then
        sed -i "/^auth.*pam_deny/i ${AUTH_LINE}" "$AUTH_FILE"
    else
        echo "$AUTH_LINE" >> "$AUTH_FILE"
    fi
    ok "Added pam_kwallet5 to ${AUTH_FILE}"
fi

# --- /etc/pam.d/common-session ---
SESSION_FILE="/etc/pam.d/common-session"
SESSION_LINE="session optional    pam_kwallet5.so auto_start"
if grep -qF "pam_kwallet5" "$SESSION_FILE" 2>/dev/null; then
    echo "  pam_kwallet5 already in ${SESSION_FILE} — skipping."
else
    echo "$SESSION_LINE" >> "$SESSION_FILE"
    ok "Added pam_kwallet5 to ${SESSION_FILE}"
fi

# ── 3/4: Skel kwalletrc – new users get auto-unlock ─────────────────────
echo "[3/4] Creating /etc/skel KDE Wallet config..."
SKEL_CFG="/etc/skel/.config"
mkdir -p "$SKEL_CFG"

cat > "${SKEL_CFG}/kwalletrc" <<'KWALLETRC'
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

ok "Skel kwalletrc created."

# ── 4/4: Patch existing home directories ────────────────────────────────
echo "[4/4] Patching existing user profiles..."
patched=0
for homedir in /home/*/; do
    user="$(basename "$homedir")"
    # Skip system-like users
    uid=$(id -u "$user" 2>/dev/null) || continue
    (( uid < 1000 )) && continue

    cfg_dir="${homedir}.config"
    rc_file="${cfg_dir}/kwalletrc"
    mkdir -p "$cfg_dir"
    # Only write if file doesn't exist or doesn't have our config
    if [[ ! -f "$rc_file" ]] || ! grep -q "Prompt on Open=false" "$rc_file" 2>/dev/null; then
        cp "${SKEL_CFG}/kwalletrc" "$rc_file"
        chown "$user":"$user" "$rc_file" 2>/dev/null || true
        chown "$user":"$user" "$cfg_dir" 2>/dev/null || true
        ((patched++))
    fi
done
ok "Patched ${patched} existing user profile(s)."

echo ""
ok "KDE Wallet auto-unlock configured."
echo "    pam_kwallet5 will unlock the wallet at login using the user's password."
echo "    Users must log out and back in for the fix to take effect."
echo "    On first login after the fix, the wallet may prompt once to set the"
echo "    wallet password — they should use their domain login password."
