#!/usr/bin/env bash
###############################################################################
# Tests for the release helpers in scripts/common.sh
#
# The fleet runs 24.04 and 26.04 from one branch, so os_release_value,
# ubuntu_version and version_at_least decide which branch a module takes. A
# wrong answer here does not fail loudly — it installs the wrong package or
# skips a step — so every case is pinned against a synthetic root.
#
# Run with: bash tests/test_os_helpers.sh
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

# Run a snippet with common.sh sourced. Nothing here touches the real
# /etc/os-release: every call passes an explicit ROOT.
run_() { # run_ SNIPPET
  bash -c "
    source '$COMMON' >/dev/null 2>&1
    $1" 2>&1
}

# mkroot NAME ID VERSION_ID  — lays down ROOT/etc/os-release
mkroot() {
  mkdir -p "$TMP/$1/etc"
  printf 'ID=%s\nVERSION_ID="%s"\nNAME="Ubuntu"\nPRETTY_NAME="Ubuntu %s"\n' \
    "$2" "$3" "$3" > "$TMP/$1/etc/os-release"
}

mkroot noble    ubuntu 24.04
mkroot oracular ubuntu 24.10
mkroot resolute ubuntu 26.04
mkroot octal    ubuntu 24.09
mkroot fedora   fedora 41

echo "── os_release_value ─────────────────────────────────────────────"
check "laeser VERSION_ID" "24.04" "$(run_ "os_release_value VERSION_ID '$TMP/noble'")"
check "fjerner anfoerselstegn" "Ubuntu" "$(run_ "os_release_value NAME '$TMP/noble'")"
check "laeser ID uden anfoerselstegn" "ubuntu" "$(run_ "os_release_value ID '$TMP/noble'")"

# VERSION_ID må ikke kunne rammes af et præfiks-match på VERSION.
check "noeglen matches praecist, ikke som praefiks" "Ubuntu 24.04" \
  "$(run_ "os_release_value PRETTY_NAME '$TMP/noble'")"

mkdir -p "$TMP/empty"
check "manglende fil fejler" "1" "$(run_ "os_release_value ID '$TMP/empty' >/dev/null; echo \$?")"
check "manglende noegle fejler" "1" \
  "$(run_ "os_release_value NOSUCHKEY '$TMP/noble' >/dev/null; echo \$?")"

# Nogle images har kun /usr/lib/os-release. Faldbacken er ikke kosmetisk:
# uden den ser en chroot-forespoergsel ud som en ikke-Ubuntu maskine.
mkdir -p "$TMP/usrlib/usr/lib"
printf 'ID=ubuntu\nVERSION_ID="26.04"\n' > "$TMP/usrlib/usr/lib/os-release"
check "falder tilbage til /usr/lib/os-release" "26.04" \
  "$(run_ "os_release_value VERSION_ID '$TMP/usrlib'")"

echo
echo "── ubuntu_version ───────────────────────────────────────────────"
check "24.04" "24.04" "$(run_ "ubuntu_version '$TMP/noble'")"
check "26.04" "26.04" "$(run_ "ubuntu_version '$TMP/resolute'")"
check "afviser en ikke-Ubuntu ID" "1" \
  "$(run_ "ubuntu_version '$TMP/fedora' >/dev/null; echo \$?")"
check "afviser en tom rod" "1" \
  "$(run_ "ubuntu_version '$TMP/empty' >/dev/null; echo \$?")"

echo
echo "── version_at_least ─────────────────────────────────────────────"
# 24.04 mod alt
check "24.04 >= 24.04" "0" "$(run_ "version_at_least 24.04 '$TMP/noble'; echo \$?")"
check "24.04 >= 24.10 er falsk" "1" "$(run_ "version_at_least 24.10 '$TMP/noble'; echo \$?")"
check "24.04 >= 26.04 er falsk" "1" "$(run_ "version_at_least 26.04 '$TMP/noble'; echo \$?")"
# 26.04 mod alt
check "26.04 >= 24.04" "0" "$(run_ "version_at_least 24.04 '$TMP/resolute'; echo \$?")"
check "26.04 >= 26.04" "0" "$(run_ "version_at_least 26.04 '$TMP/resolute'; echo \$?")"
# Mellemudgaven skal sortere rigtigt i begge retninger. En ren
# strengsammenligning rammer dette ved held.
check "24.10 >= 24.04" "0" "$(run_ "version_at_least 24.04 '$TMP/oracular'; echo \$?")"
check "24.10 >= 26.04 er falsk" "1" "$(run_ "version_at_least 26.04 '$TMP/oracular'; echo \$?")"
# Oktal-faelden: 09 som andet felt maa ikke give en aritmetikfejl.
check "24.09 >= 24.04 (ingen oktalfejl)" "0" \
  "$(run_ "version_at_least 24.04 '$TMP/octal'; echo \$?")"
check "24.09 >= 24.10 er falsk" "1" "$(run_ "version_at_least 24.10 '$TMP/octal'; echo \$?")"
check "en anden distro er aldrig 'mindst'" "1" \
  "$(run_ "version_at_least 24.04 '$TMP/fedora'; echo \$?")"

echo
echo "── under 'set -e' ───────────────────────────────────────────────"
# Hele grunden til at praedikatet bruger 'if' og ikke '&&': et falsk svar maa
# ikke afslutte det kaldende modul. Dette er fejlen login-screen.sh advarer om
# i sin egen hovedkommentar.
out="$(bash -c "
  set -euo pipefail
  source '$COMMON' >/dev/null 2>&1
  if version_at_least 26.04 '$TMP/noble'; then echo NYERE; else echo AELDRE; fi
  echo NAAEDE_HERTIL" 2>&1)"
check "et falsk svar afslutter ikke kalderen" "AELDRE
NAAEDE_HERTIL" "$out"

echo
echo "─────────────────────────────────────────────────────────────────"
printf "%d bestået, %d fejlet\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
