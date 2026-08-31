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

echo "[1/9] Setting hostname..."
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

echo "[2/9] Installing required packages..."
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

echo "[3/9] Discovering domain..."
if ! realm discover "$DOMAIN"; then
  fail "Could not discover domain $DOMAIN. Check DNS and network."
  exit 1
fi
ok "Domain $DOMAIN discovered."

echo "[4/9] Joining domain..."
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

echo "[5/9] Optimising the Kerberos client..."
# Uden en KDC-liste slår klienten realmet op via DNS SRV ved hver billet. Det
# opslag er den største enkeltpost i et koldt login.
#
# De to ting hænger uløseligt sammen: dns_lookup_kdc=false MÅ kun sættes når
# der faktisk står kdc-linjer i filen. Gør man det ene uden det andet, har
# klienten ingen måde at finde en KDC på, og hvert eneste login fejler. Derfor
# skrives blokken kun når SITE_AD_KDCS er sat, og ellers røres filen ikke.
if [ -n "${SITE_AD_KDCS:-}" ]; then
  if [ -f /etc/krb5.conf ] && [ ! -f /etc/krb5.conf.dtu-backup ]; then
    cp -a /etc/krb5.conf /etc/krb5.conf.dtu-backup
    ok "Backed up the existing krb5.conf to /etc/krb5.conf.dtu-backup"
  fi

  KDC_LINES=""
  FIRST_KDC=""
  for kdc in $SITE_AD_KDCS; do
    [ -n "$FIRST_KDC" ] || FIRST_KDC="$kdc"
    KDC_LINES="${KDC_LINES}  kdc = ${kdc}"$'\n'
  done

  {
    printf '%s\n' "[libdefaults]"
    printf ' %s\n' "default_realm = ${DOMAIN_UPPER}"
    printf '\n'
    printf ' # KDCs are named below, so the DNS SRV lookup on every ticket request\n'
    printf ' # is dead weight. Never set these to false without kdc= lines.\n'
    printf ' %s\n' "dns_lookup_kdc = false"
    printf ' %s\n' "dns_lookup_realm = false"
    printf ' # Reverse lookups add a DNS round trip per service ticket and are not\n'
    printf ' # needed when the service principal is already known.\n'
    printf ' %s\n' "rdns = false"
    printf ' # 0 means: try TCP first. AD PAC data routinely exceeds the UDP limit,\n'
    printf ' # so the UDP attempt only ever costs a timeout before the TCP retry.\n'
    printf ' %s\n' "udp_preference_limit = 0"
    printf '\n'
    printf ' %s\n' "forwardable = true"
    printf ' %s\n' "proxiable = true"
    printf '\n'
    printf '%s\n' "[realms]"
    printf ' %s = {\n' "${DOMAIN_UPPER}"
    printf '%s' "$KDC_LINES"
    printf '  %s\n' "admin_server = ${FIRST_KDC}"
    printf '  %s\n' "default_domain = ${SITE_AD_REALM}"
    printf ' }\n'
    printf '\n'
    printf '%s\n' "[domain_realm]"
    printf ' .%s = %s\n' "${SITE_AD_REALM}" "${DOMAIN_UPPER}"
    printf ' %s = %s\n' "${SITE_AD_REALM}" "${DOMAIN_UPPER}"
  } > /etc/krb5.conf
  chmod 0644 /etc/krb5.conf
  chown root:root /etc/krb5.conf
  ok "krb5.conf written with $(printf '%s\n' $SITE_AD_KDCS | wc -l) KDC(s); DNS discovery disabled."
else
  warn "SITE_AD_KDCS is not set — leaving /etc/krb5.conf alone."
  warn "  Kerberos keeps discovering KDCs over DNS. That works, but it is the"
  warn "  slowest part of a cold login. Set SITE_AD_KDCS in site.conf to fix it."
fi

echo "[6/9] Configuring SSSD..."
# Rewrite sssd.conf with Python for reliable multi-setting updates
if [ -f /etc/sssd/sssd.conf ]; then
  if SITE_AD_ACCESS_PROVIDER="${SITE_AD_ACCESS_PROVIDER:-}" python3 - <<'PYEOF'
import os
import re

PATH = '/etc/sssd/sssd.conf'
with open(PATH) as f:
    content = f.read()

# Ubuntu 24.04's sssd-common socket-activates the nss/pam responders
# (sssd-nss.socket, sssd-pam.socket). realm join's default sssd.conf still
# lists them on the services= line too, which makes SSSD's monitor race
# systemd for the same socket and crash-loop (start-limit-hit). Drop the
# line so responders are purely socket-activated, as intended on 24.04.
#
# This is also why the standalone Speedup_Login.sh must not be run after this
# module: it writes `services = nss, pam` straight back in and the crash-loop
# returns. Everything that script does for speed is done here instead.
content = re.sub(r'^services\s*=.*\n?', '', content, flags=re.MULTILINE)


def set_in_section(text, section, key, value, only_if_absent=False):
    """Set key = value inside [section], creating the section if absent."""
    header = re.compile(r'^\[' + re.escape(section) + r'\][^\n]*\n', re.MULTILINE)
    match = header.search(text)
    if not match:
        return text.rstrip('\n') + '\n\n[{}]\n{} = {}\n'.format(section, key, value)

    start = match.end()
    nxt = re.compile(r'^\[', re.MULTILINE).search(text, start)
    end = nxt.start() if nxt else len(text)
    body = text[start:end]

    existing = re.compile(r'^' + re.escape(key) + r'\s*=.*$', re.MULTILINE)
    if existing.search(body):
        if only_if_absent:
            return text
        body = existing.sub('{} = {}'.format(key, value), body)
    else:
        body = '{} = {}\n'.format(key, value) + body
    return text[:start] + body + text[end:]


match = re.search(r'^\[domain/([^\]]+)\]', content, re.MULTILINE)
if not match:
    raise SystemExit('sssd.conf has no [domain/...] section - not touching it.')
domain_section = 'domain/' + match.group(1)

# Behaviour the DTU desktop depends on.
for key, value in [
    ('use_fully_qualified_names',      'False'),
    ('fallback_homedir',               '/home/%u'),
    ('override_homedir',               '/home/%u'),
    ('cache_credentials',              'True'),
    ('krb5_store_password_if_offline', 'True'),
]:
    content = set_in_section(content, domain_section, key, value)

# Login speed.
#
# entry_cache_* was 300 (5 min). At four hours a login on a warm cache does no
# LDAP round trip at all. The cost is that an AD change - crucially a group
# membership, which is what grants sudo and the polkit rules - can take up to
# four hours to reach the machine. `sudo sss_cache -E` flushes it immediately.
#
# ad_enable_gc off keeps lookups on the domain controller instead of the
# global catalog; ldap_use_tokengroups off and nesting level 0 stop SSSD
# walking the full group tree on every login, which is where the multi-second
# stalls came from. enumerate off means no periodic full user/group dump.
for key, value in [
    ('entry_cache_timeout',       '14400'),
    ('entry_cache_user_timeout',  '14400'),
    ('entry_cache_group_timeout', '14400'),
    ('ldap_network_timeout',      '3'),
    ('offline_timeout',           '10'),
    ('enumerate',                 'False'),
    ('ad_enable_gc',              'False'),
    ('ldap_use_tokengroups',      'False'),
    ('ldap_group_nesting_level',  '0'),
    # SSSD defaults to enforcing, which fetches and evaluates GPOs on every
    # login and denies it outright when they cannot be read. Permissive logs
    # what it would have denied and lets the user in.
    ('ad_gpo_access_control',     'permissive'),
]:
    content = set_in_section(content, domain_section, key, value)

# ldap_id_mapping decides whether UIDs are computed from the AD SID or read
# from POSIX attributes. Changing it on a joined machine renumbers every
# domain user and orphans their home directory, so only write it when the file
# does not already say - realm join sets it for AD, and that value is right.
content = set_in_section(content, domain_section, 'ldap_id_mapping', 'True',
                         only_if_absent=True)

# access_provider is an access decision, not a speed setting: "permit" lets
# every domain user log in. Only applied when site.conf spells it out.
access = os.environ.get('SITE_AD_ACCESS_PROVIDER', '').strip()
if access:
    content = set_in_section(content, domain_section, 'access_provider', access)

# Resolving every member of a group is pointless for login and expensive for
# the large groups AD carries. The members are still resolved individually
# when something actually asks for one.
content = set_in_section(content, 'nss', 'ignore_group_members', 'True')

with open(PATH, 'w') as f:
    f.write(content)
PYEOF
  then
    chmod 600 /etc/sssd/sssd.conf
    chown root:root /etc/sssd/sssd.conf
  else
    fail "Could not update /etc/sssd/sssd.conf — see the message above."
    echo "  The domain join itself succeeded. Fix sssd.conf and re-run this module."
    exit 1
  fi
fi
ok "SSSD configured (short usernames, /home/%u, cached credentials, fast lookups)."
if [ -n "${SITE_AD_ACCESS_PROVIDER:-}" ]; then
  warn "access_provider set to '${SITE_AD_ACCESS_PROVIDER}' from site.conf."
fi

echo "[7/9] Enabling mkhomedir (auto-create home on first login)..."
pam-auth-update --enable mkhomedir

echo "[8/9] Restarting services..."
# sssd-pac responder exits immediately with NOTIMPLEMENTED on Ubuntu's SSSD
# build regardless of config — disable it so it doesn't show as a failed
# unit; PAC validation isn't needed for the plain AD login flow used here.
systemctl disable --now sssd-pac.socket sssd-pac.service 2>/dev/null || true
systemctl reset-failed 2>/dev/null || true

# The cache is keyed on the old settings. Leaving it in place means the new
# timeouts and the group-lookup changes only take effect as old entries
# expire - which, at four hours, is not something anyone will sit and wait
# for while testing whether the login got faster.
systemctl stop sssd 2>/dev/null || true
rm -f /var/lib/sss/db/*.ldb
rm -f /var/lib/sss/mc/*
kdestroy 2>/dev/null || true

systemctl start sssd
systemctl enable sssd

echo "[9/9] Verifying domain membership..."
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
