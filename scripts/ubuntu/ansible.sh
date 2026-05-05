#!/usr/bin/env bash
###############################################################################
# DTU Sustain – Ubuntu 24.04 – Module: Ansible Onboarding
# Creates the sus-root service account, deploys the SSH public key,
# configures passwordless sudo, and hides the account from the login screen.
# Run AFTER domain-join.
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
need_root

banner "Ansible Onboarding"

USERNAME="${SITE_ANSIBLE_USER:-sus-root}"
TARGET_UID=0
TARGET_GID=0
HOSTNAME_SHORT="$(hostname -s)"
HOSTNAME_FQDN="$(echo "$HOSTNAME_SHORT" | tr '[:upper:]' '[:lower:]').sus.clients.local"

# ── Step 1: Install required packages ────────────────────────────────────────
echo "[1/6] Installing required packages..."
export DEBIAN_FRONTEND=noninteractive
apt_wait
apt-get update -qq || warn "apt-get update reported errors (likely a broken third-party repository); continuing."
apt-get install -y openssh-server python3
systemctl enable --now ssh
ok "openssh-server + python3 installed."

# ── Step 2: Create / verify user ────────────────────────────────────────────
echo "[2/6] Creating / verifying user '$USERNAME' (UID=0, GID=0)..."
if ! id "$USERNAME" &>/dev/null; then
    useradd -o -u $TARGET_UID -g $TARGET_GID -d /root -s /bin/bash "$USERNAME"
    ok "Created user $USERNAME (uid=0, gid=0, home=/root)"
else
    # Ensure existing user has uid/gid 0 and home /root
    CURRENT_UID=$(id -u "$USERNAME")
    if [[ "$CURRENT_UID" -ne 0 ]]; then
        echo "  Migrating $USERNAME to UID=0, GID=0, home=/root..."
        usermod -o -u $TARGET_UID -g $TARGET_GID -d /root -s /bin/bash "$USERNAME"
        # Remove old home if it was separate
        [[ -d /home/$USERNAME ]] && rm -rf /home/$USERNAME
        ok "Migrated $USERNAME to root (uid=0, gid=0)"
    else
        ok "User $USERNAME already exists (uid=0)"
    fi
fi

# ── Step 3: Hide from login screen ──────────────────────────────────────────
echo "[3/6] Hiding '$USERNAME' from display manager..."
mkdir -p /var/lib/AccountsService/users
cat > "/var/lib/AccountsService/users/$USERNAME" <<EOF
[User]
SystemAccount=true
EOF
ok "AccountsService: SystemAccount=true"

# ── Step 4: Set password ────────────────────────────────────────────────────
echo "[4/6] Setting password for '$USERNAME'..."

ANSIBLE_PASS="${DTU_ANSIBLE_PASSWORD:-}"
if [[ -z "$ANSIBLE_PASS" ]]; then
    # Interactive fallback
    read -rsp "  Enter password for $USERNAME: " ANSIBLE_PASS
    echo
fi

echo "$USERNAME:$ANSIBLE_PASS" | chpasswd
ok "Password set."

# Add to sudo group
usermod -aG sudo "$USERNAME"
ok "Added $USERNAME to sudo group."

# ── Step 5: Deploy SSH public key ───────────────────────────────────────────
echo "[5/6] Deploying SSH public key..."
ANSIBLE_HOME="/root"
mkdir -p "$ANSIBLE_HOME/.ssh"
chmod 700 "$ANSIBLE_HOME/.ssh"

PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFR8JkuYI5FyEXdgXvOdHN1BStpg+gf4WqiDPgHj3tDr ansible@dtu-sustain"
AUTH_KEYS="$ANSIBLE_HOME/.ssh/authorized_keys"
if ! grep -qF "$PUBKEY" "$AUTH_KEYS" 2>/dev/null; then
    echo "$PUBKEY" >> "$AUTH_KEYS"
    ok "Key added to $AUTH_KEYS"
else
    ok "Key already present"
fi
chmod 600 "$AUTH_KEYS"
chown -R root:root "$ANSIBLE_HOME/.ssh"

# ── Step 6: Passwordless sudo ───────────────────────────────────────────────
echo "[6/6] Configuring passwordless sudo..."
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/ansible-$USERNAME"
chmod 440 "/etc/sudoers.d/ansible-$USERNAME"
ok "Passwordless sudo configured."

echo ""
ok "Ansible onboarding complete for $HOSTNAME_SHORT ($HOSTNAME_FQDN)."
echo "    User '$USERNAME' is a root alias (UID=0, GID=0, home=/root)."
echo "    Full unrestricted root access — no sudo restrictions."
echo "    You can now run playbooks against this host."
