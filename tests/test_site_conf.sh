#!/usr/bin/env bash
###############################################################################
# Smoke tests for the site-configuration layer in scripts/common.sh
#
# Covers the failure mode that shipped the broken 2026.07.01 image: a missing
# or placeholder-filled site.conf must stop a module, never silently produce
# //<fileserver>/... Run with: bash tests/test_site_conf.sh
###############################################################################
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="${REPO_ROOT}/scripts/common.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok_()   { printf '  \033[0;32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad_()  { printf '  \033[0;31m✗\033[0m %s\n' "$1"; printf '      %s\n' "${2:-}"; FAIL=$((FAIL+1)); }
check() { # check DESCRIPTION EXPECTED ACTUAL
  if [[ "$2" == "$3" ]]; then ok_ "$1"; else bad_ "$1" "forventet [$2], fik [$3]"; fi
}

# Run a snippet with common.sh sourced against a given SITE_CONF.
with_conf() { # with_conf CONF_FILE SNIPPET
  SITE_CONF="$1" DTU_DEPARTMENT="${DTU_DEPARTMENT:-}" bash -c "
    source '$COMMON' >/dev/null 2>&1
    $2" 2>&1
}

echo "── site_is_placeholder ──────────────────────────────────────────"
: > "$TMP/empty.conf"
for v in "<fileserver>" "https://<defender-host>/x.py" "konfigureret via site.conf" ""; do
  out="$(with_conf "$TMP/empty.conf" "site_is_placeholder '$v' && echo YES || echo NO")"
  check "afviser [$v]" "YES" "$out"
done
for v in "fs.example.invalid" "https://def.example.invalid/onboard.py" "SOME-Admin-Group" 'share$/SUB' 'Users$'; do
  out="$(with_conf "$TMP/empty.conf" "site_is_placeholder '$v' && echo YES || echo NO")"
  check "accepterer [$v]" "NO" "$out"
done

echo
echo "── load_site_conf: placeholders tømmes, ægte værdier overlever ──"
cat > "$TMP/mixed.conf" <<'EOF'
SITE_FILE_SERVER="<fileserver>"
SITE_PRINT_SERVER="print.example.invalid"
SITE_DEFENDER_ONBOARDING_URL="https://<defender-host>/onboard.py"
SITE_AD_ADMIN_GROUP="Real-Admins"
EOF
check "placeholder-hostname tømmes"  ""                  "$(with_conf "$TMP/mixed.conf" 'printf "%s" "$SITE_FILE_SERVER"')"
check "ægte printserver bevares"     "print.example.invalid" "$(with_conf "$TMP/mixed.conf" 'printf "%s" "$SITE_PRINT_SERVER"')"
check "placeholder-i-URL tømmes"     ""                  "$(with_conf "$TMP/mixed.conf" 'printf "%s" "$SITE_DEFENDER_ONBOARDING_URL"')"
check "ægte admingruppe bevares"     "Real-Admins"       "$(with_conf "$TMP/mixed.conf" 'printf "%s" "$SITE_AD_ADMIN_GROUP"')"
check "site-uafhængig default sat"   "DTUSecure"         "$(with_conf "$TMP/mixed.conf" 'printf "%s" "$SITE_WIFI_SSID"')"
check "SITE_CONF_LOADED sat"         "$TMP/mixed.conf"   "$(with_conf "$TMP/mixed.conf" 'printf "%s" "$SITE_CONF_LOADED"')"

echo
echo "── site_require ─────────────────────────────────────────────────"
# site_require kalder exit, så kaldet skal isoleres i en subshell for at
# exitkoden kan aflæses — at det er nødvendigt er netop pointen med testen.
rc="$(with_conf "$TMP/mixed.conf" '( site_require SITE_FILE_SERVER ) >/dev/null 2>&1; echo $?')"
check "stopper (exit 1) ved manglende variabel" "1" "$rc"
rc="$(with_conf "$TMP/mixed.conf" 'site_require SITE_PRINT_SERVER >/dev/null 2>&1; echo $?')"
check "tillader (exit 0) ved gyldig variabel"   "0" "$rc"
msg="$(with_conf "$TMP/mixed.conf" 'site_require SITE_FILE_SERVER 2>&1 || true')"
case "$msg" in *SITE_FILE_SERVER*) ok_ "fejlbesked navngiver variablen";;
               *) bad_ "fejlbesked navngiver variablen" "fik: $msg";; esac
case "$msg" in *"$TMP/mixed.conf"*) ok_ "fejlbesked viser hvilken fil der blev læst";;
               *) bad_ "fejlbesked viser hvilken fil der blev læst" "fik: $msg";; esac

nofile="$(SITE_CONF="$TMP/findes-ikke.conf" bash -c "source '$COMMON'; site_require SITE_FILE_SERVER 2>&1 || true")"
case "$nofile" in *"No site configuration was found"*) ok_ "melder tydeligt når ingen config findes";;
                  *) bad_ "melder tydeligt når ingen config findes" "fik: $nofile";; esac

echo
echo "── cifs_creds_file: ingen placeholder i stien ───────────────────"
cat > "$TMP/good.conf" <<'EOF'
SITE_FILE_SERVER="fs.example.invalid"
EOF
p="$(with_conf "$TMP/good.conf" 'printf "%s" "$(cifs_creds_file testuser)"')"
check "afledt af SITE_FILE_SERVER" "/home/testuser/.smbcred-fs" "$p"
case "$p" in *"<"*) bad_ "sti indeholder ingen vinkelparentes" "fik: $p";;
             *) ok_ "sti indeholder ingen vinkelparentes";; esac

echo
echo "── sustain_pick_target: gætter aldrig en share-sti ──────────────"
cat > "$TMP/qumulo.conf" <<'EOF'
SITE_FILE_SERVER="dfs.example.invalid"
SITE_FILE_SERVER_QUMULO="qum.example.invalid"
SITE_SUSTAIN_Q_SHARE_QUMULO="ex-q$"
EOF
out="$(with_conf "$TMP/qumulo.conf" 'cifs_host_up() { true; }; sustain_pick_target u >/dev/null; printf "%s|%s|%s" "$TARGET_LABEL" "$Q_SHARE_PATH" "$P_SHARE_PATH"')"
check "Qumulo-mål når share er konfigureret" 'qumulo-direct|ex-q$|ex-q$/Personal/u' "$out"

cat > "$TMP/noqshare.conf" <<'EOF'
SITE_FILE_SERVER="dfs.example.invalid"
SITE_FILE_SERVER_QUMULO="qum.example.invalid"
EOF
out="$(with_conf "$TMP/noqshare.conf" 'cifs_host_up() { true; }; sustain_pick_target u >/dev/null; printf "%s" "$TARGET_LABEL"')"
check "falder tilbage til DFS uden Qumulo-share" "dfs-root" "$out"

out="$(with_conf "$TMP/qumulo.conf" 'cifs_host_up() { false; }; sustain_pick_target u >/dev/null 2>&1; echo $?')"
check "fejler når ingen server kan nås" "1" "$out"

echo
echo "─────────────────────────────────────────────────────────────────"
printf "%d bestået, %d fejlet\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
