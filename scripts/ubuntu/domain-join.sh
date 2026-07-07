#!/usr/bin/env bash
###############################################################################
# DTU Sustain – Ubuntu 24.04 – Module: Domain Join (WIN.DTU.DK)
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
DOMAIN_DN=$(echo "$DOMAIN" | sed 's/\./,DC=/g; s/^/DC=/')
DOMAIN_UPPER=$(echo "$DOMAIN" | tr '[:lower:]' '[:upper:]')

echo "[1/8] Setting hostname..."
DEPT_LOWER="$(printf '%s' "${DTU_DEPARTMENT:-}" | tr '[:upper:]' '[:lower:]')"
if [ "$DEPT_LOWER" = "sustain" ] && [ -n "${DTU_HOSTNAME:-}" ]; then
  warn "Sustain profile selected — ignoring DTU_HOSTNAME and keeping current hostname."
  unset DTU_HOSTNAME
fi
if [ -z "${DTU_HOSTNAME:-}" ] && [ "$DEPT_LOWER" = "ait" ]; then
  SERIALNO="$(dmidecode -s system-serial-number 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$SERIALNO" ] && [ "$SERIALNO" != "NotSpecified" ] && [ "$SERIALNO" != "ToBeFilledByO.E.M." ]; then
    DTU_HOSTNAME="DTU-${SERIALNO}"
    warn "DTU_HOSTNAME not set (AIT) — using serial number: $DTU_HOSTNAME"
  else
    warn "DTU_HOSTNAME not set (AIT) and no usable serial number found — keeping current hostname: $(hostname)"
  fi
fi
if [ -n "${DTU_HOSTNAME:-}" ]; then
  hostnamectl set-hostname "$DTU_HOSTNAME"
  # Keep /etc/hosts in sync so sudo doesn't warn about unresolvable hostname
  if grep -q "^127\.0\.1\.1" /etc/hosts; then
    sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t$DTU_HOSTNAME/" /etc/hosts
  else
    printf "127.0.1.1\t%s\n" "$DTU_HOSTNAME" >> /etc/hosts
  fi
  ok "Hostname set to $DTU_HOSTNAME"
else
  warn "DTU_HOSTNAME not set — keeping current hostname: $(hostname)"
fi

echo "[2/8] Installing required packages..."
export DEBIAN_FRONTEND=noninteractive
apt_wait
apt-get update -qq || warn "apt-get update reported errors (likely a broken third-party repository); continuing."
apt-get install -y \
  realmd \
  sssd \
  sssd-tools \
  sssd-ad \
  adcli \
  krb5-user \
  packagekit \
  samba-common-bin \
  oddjob \
  oddjob-mkhomedir \
  libnss-sss \
  libpam-sss

echo "[3/8] Discovering domain..."
if ! realm discover "$DOMAIN"; then
  fail "Could not discover domain $DOMAIN. Check DNS and network."
  exit 1
fi
ok "Domain $DOMAIN discovered."

echo "[4/8] Joining domain..."
if realm list 2>/dev/null | grep -qi "$DOMAIN"; then
  # Already joined — verify SSSD is working before skipping
  if id "${ADMIN_USER}@${DOMAIN}" >/dev/null 2>&1 || id "${ADMIN_USER}" >/dev/null 2>&1; then
    ok "Already joined to $DOMAIN and SSSD is resolving users — skipping rejoin."
    SKIP_JOIN=1
  else
    warn "Already joined to $DOMAIN but SSSD cannot resolve users — re-joining..."
    realm leave "$DOMAIN" 2>/dev/null || true
    SKIP_JOIN=0
  fi
else
  SKIP_JOIN=0
fi

if [ "$SKIP_JOIN" -eq 0 ]; then
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

# Prompt for password once — used for AD check and domain join
read -rsp "Password for ${ADMIN_USER}@${DOMAIN_UPPER}: " ADMIN_PASS
echo ""
echo ""

# ── Check / pre-stage computer object in AD ───────────────────────────────
COMPUTER_NAME="\$(hostname -s | tr '[:lower:]' '[:upper:]')"
echo "▶  Checking computer object '\${COMPUTER_NAME}' in AD (CN=Computers,${DOMAIN_DN})..."
ADCLI_ERR_FILE="\$(mktemp /tmp/dtu-adcli-XXXXXX.err)"
if echo "\${ADMIN_PASS}" | adcli preset-computer --domain="${DOMAIN}" --domain-ou="CN=Computers,${DOMAIN_DN}" --login-user="${ADMIN_USER}" --stdin-password "\${COMPUTER_NAME}" 2>"\${ADCLI_ERR_FILE}"; then
    echo "✅ Computer object ready in AD (CN=Computers,${DOMAIN_DN})"
else
    ADCLI_ERR="\$(cat "\${ADCLI_ERR_FILE}" 2>/dev/null)"
    if echo "\${ADCLI_ERR}" | grep -qi "already exists\|object already\|Entry Already Exists"; then
        echo "✅ Computer object already exists in AD — no pre-staging needed."
    else
        echo "⚠  Pre-staging note: \${ADCLI_ERR}"
        echo "   Continuing with domain join..."
    fi
fi
rm -f "\${ADCLI_ERR_FILE}"
echo ""

# ── Domain join ───────────────────────────────────────────────────────────
echo "▶  Joining domain ${DOMAIN}..."
echo "\${ADMIN_PASS}" | realm join -U "${ADMIN_USER}" "${DOMAIN}"
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
fi

echo "[5/8] Configuring SSSD..."
# Rewrite sssd.conf with Python for reliable multi-setting updates
if [ -f /etc/sssd/sssd.conf ]; then
  python3 - <<'PYEOF'
import re

with open('/etc/sssd/sssd.conf', 'r') as f:
    content = f.read()

# Settings to enforce — order matters for readability
settings = [
    ('use_fully_qualified_names',      'False'),
    ('fallback_homedir',               '/home/%u'),
    ('override_homedir',               '/home/%u'),
    ('cache_credentials',              'True'),
    ('krb5_store_password_if_offline', 'True'),
    ('entry_cache_timeout',            '300'),
    ('ldap_network_timeout',           '3'),
]

for key, value in settings:
    pattern = re.compile(r'^' + re.escape(key) + r'\s*=.*$', re.MULTILINE)
    replacement = f'{key} = {value}'
    if pattern.search(content):
        content = pattern.sub(replacement, content)
    else:
        # Append after the first [domain/...] header
        content = re.sub(
            r'(\[domain/[^\]]*\])',
            lambda m: m.group(0) + '\n' + replacement,
            content,
            count=1
        )

with open('/etc/sssd/sssd.conf', 'w') as f:
    f.write(content)
PYEOF
  chmod 600 /etc/sssd/sssd.conf
fi
ok "SSSD configured (short usernames, /home/%u, credentials cached)."

echo "[6/8] Enabling mkhomedir (auto-create home on first login)..."
pam-auth-update --enable mkhomedir

echo "[7/8] Restarting services..."
systemctl restart sssd
systemctl enable sssd

echo "[8/8] Verifying domain membership..."
realm list
echo ""

# Quick validation
if id "${ADMIN_USER}@${DOMAIN}" >/dev/null 2>&1 || id "${ADMIN_USER}" >/dev/null 2>&1; then
  ok "Domain user '${ADMIN_USER}' resolved successfully."
else
  warn "Could not resolve domain user '${ADMIN_USER}' yet. SSSD may need a moment to sync."
fi

ok "Domain join complete: $DOMAIN"
echo "    SSSD: use_fully_qualified_names = False"
echo "    Home: /home/<username> (auto-created on login)"
echo "    Test: id <username>  or  su - <username>"
