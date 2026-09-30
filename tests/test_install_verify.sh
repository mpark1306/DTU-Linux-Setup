#!/usr/bin/env bash
###############################################################################
# Tests for the checksum verification in bin/dtu-install.sh and
# scripts/update-latest.sh
#
# Both scripts download code from GitHub and run "make install" as root. Until
# v1.8.0 nothing checked what arrived. Now fetch_verified_release refuses to
# extract anything that does not match the release's sha256sums.txt, and, if
# the caller pinned one, a SHA256 obtained some other way.
#
# A fake release is served from localhost: a real "git archive" of this repo
# plus a sha256sums.txt, then each case tampers with one of them. Every case
# runs against BOTH scripts, because they carry separate copies of the
# function.
#
# Run with: bash tests/test_install_verify.sh
###############################################################################
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null; fi
  rm -rf "$TMP"
}
trap cleanup EXIT

PASS=0; FAIL=0
ok_()   { printf '  \033[0;32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad_()  { printf '  \033[0;31m✗\033[0m %s\n' "$1"; printf '      %s\n' "${2:-}"; FAIL=$((FAIL+1)); }

TAG="v9.9.9"
VER="9.9.9"
ASSET="dtu-sustain-setup-${VER}.tar.gz"
WWW="$TMP/www"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
BASE="http://127.0.0.1:${PORT}"

# ── A realistic release: the same command CI uses ─────────────────────────
mkdir -p "$TMP/pristine"
git -C "$REPO_ROOT" archive --format=tar.gz --prefix="dtu-sustain-setup-${VER}/" \
  -o "$TMP/pristine/${ASSET}" HEAD
GOOD_SUM="$(sha256sum "$TMP/pristine/${ASSET}" | awk '{print $1}')"
# Same tree under another prefix: extracts cleanly, different bytes, different hash.
git -C "$REPO_ROOT" archive --format=tar.gz --prefix="evil/" -o "$TMP/evil.tar.gz" HEAD

# publish KIND — lay out $WWW/$TAG/ for one scenario
publish() {
  rm -rf "$WWW"; mkdir -p "$WWW/$TAG"
  local d="$WWW/$TAG"
  cp "$TMP/pristine/${ASSET}" "$d/"
  printf '%s  %s\n' "$GOOD_SUM" "$ASSET" > "$d/sha256sums.txt"
  printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" \
    "dtu-sustain-setup_${VER}_all.deb" >> "$d/sha256sums.txt"
  case "$1" in
    good) ;;
    tampered-archive)
      # One extra byte is enough; the archive still extracts fine without the check.
      printf 'x' >> "$d/${ASSET}" ;;
    replaced-both)
      # An attacker who controls the release: a different but perfectly valid
      # archive, AND a sums file that matches it.
      cp "$TMP/evil.tar.gz" "$d/${ASSET}"
      printf '%s  %s\n' "$(sha256sum "$d/${ASSET}" | awk '{print $1}')" "$ASSET" > "$d/sha256sums.txt" ;;
    not-listed)
      grep -v "$ASSET" "$d/sha256sums.txt" > "$d/s" && mv "$d/s" "$d/sha256sums.txt" ;;
    listed-twice)
      printf '%s  %s\n' "$GOOD_SUM" "$ASSET" >> "$d/sha256sums.txt" ;;
    malformed-sum)
      printf 'nothex  %s\n' "$ASSET" > "$d/sha256sums.txt" ;;
    old-dist-prefix)
      # How v1.7.1 and earlier wrote the file.
      printf '%s  dist/%s\n' "$GOOD_SUM" "$ASSET" > "$d/sha256sums.txt" ;;
    binary-marker)
      # "sha256sum -b" writes " *name". Legitimate, must be accepted.
      printf '%s *%s\n' "$GOOD_SUM" "$ASSET" > "$d/sha256sums.txt" ;;
    uppercase-sum)
      printf '%s  %s\n' "${GOOD_SUM^^}" "$ASSET" > "$d/sha256sums.txt" ;;
    no-sums)
      rm -f "$d/sha256sums.txt" ;;
    no-archive)
      # A release from before source archives existed.
      rm -f "$d/${ASSET}" ;;
    truncated)
      head -c 2000 "$TMP/pristine/${ASSET}" > "$d/${ASSET}" ;;
    *) echo "unknown scenario $1" >&2; exit 2 ;;
  esac
}

mkdir -p "$WWW"
(cd "$WWW" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SERVER_PID=$!
for _ in $(seq 1 50); do
  if curl -fs -o /dev/null "$BASE/" 2>/dev/null; then break; fi
  sleep 0.1
done

# run_fetch SCRIPT [SHA256]  — sources SCRIPT's functions and fetches into a
# fresh dir. Prints "rc=N files=M" then stderr, so a case can assert on both.
run_fetch() {
  local script="$1" pin="${2:-}" dest
  dest="$(mktemp -d "$TMP/dest.XXXX")"
  local err rc
  err="$(DTU_INSTALL_SOURCE_ONLY=1 DTU_RELEASE_BASE_URL="$BASE" SHA256="$pin" bash -c "
    source '$script'
    fetch_verified_release '$TAG' '$dest'
  " 2>&1 >/dev/null)"
  rc=$?
  printf 'rc=%s files=%s\n%s' "$rc" "$(find "$dest" -type f | wc -l)" "$err"
}

# expect NAME SCRIPT SCENARIO WANT_RC [PIN] [STDERR_SUBSTRING]
expect() {
  local name="$1" script="$2" scenario="$3" want="$4" pin="${5:-}" needle="${6:-}"
  publish "$scenario"
  local out head
  out="$(run_fetch "$script" "$pin")"
  head="$(printf '%s' "$out" | head -1)"
  if [[ "$want" == 0 ]]; then
    if [[ "$head" =~ ^rc=0\ files=([0-9]+)$ ]] && (( BASH_REMATCH[1] > 50 )); then
      ok_ "$name"
    else
      bad_ "$name" "$out"
    fi
  else
    # Refused: non-zero AND nothing extracted. A refusal that leaves a half
    # extracted tree behind is not a refusal.
    if [[ "$head" == "rc=1 files=0" ]] && [[ -z "$needle" || "$out" == *"$needle"* ]]; then
      ok_ "$name"
    else
      bad_ "$name" "$out"
    fi
  fi
}

for script in "$REPO_ROOT/bin/dtu-install.sh" "$REPO_ROOT/scripts/update-latest.sh"; do
  echo "── $(basename "$script") ─────────────────────────────────────────"
  expect "a good release installs"                  "$script" good 0
  expect "a sha256sum -b line (\" *name\") is accepted"  "$script" binary-marker 0
  expect "an upper-case checksum is accepted"       "$script" uppercase-sum 0
  expect "a tampered archive is refused"            "$script" tampered-archive 1 "" "CHECKSUM MISMATCH"
  expect "a truncated download is refused"          "$script" truncated 1 "" "CHECKSUM MISMATCH"
  expect "an archive the sums file omits is refused" "$script" not-listed 1 "" "exactly once"
  expect "an archive listed twice is refused"       "$script" listed-twice 1 "" "exactly once"
  expect "a malformed checksum is refused"          "$script" malformed-sum 1 "" "malformed"
  expect "the old dist/ prefix does not count"      "$script" old-dist-prefix 1 "" "exactly once"
  expect "a missing sha256sums.txt is refused"      "$script" no-sums 1 "" "sha256sums.txt"
  expect "a release with no source archive is refused" "$script" no-archive 1 "" "DTU_ALLOW_UNVERIFIED"
  expect "a correct pinned SHA256 installs"         "$script" good 0 "$GOOD_SUM"
  expect "a pinned SHA256 catches a replaced release" "$script" replaced-both 1 "$GOOD_SUM" "pinned"
  # Without a pin, "replaced-both" passes. That is the honest limit of a
  # checksum from the same source, and the reason SHA256= exists.
  expect "without a pin, a fully replaced release is NOT caught (documented limit)" \
    "$script" replaced-both 0
  echo
done

echo "── dtu-install.sh: refusals before any download, the real script ─"
# check_refusal NAME ENV... — runs the whole script as this (non-root) user.
# The input checks come before the root check, so a refusal here proves the
# script itself refuses, not a copy of its condition.
check_refusal() {
  local name="$1"; shift
  local out rc
  out="$(env "$@" DTU_RELEASE_BASE_URL="$BASE" bash "$REPO_ROOT/bin/dtu-install.sh" 2>&1)"
  rc=$?
  if [[ $rc -ne 0 && "$out" != *"must be run as root"* ]]; then ok_ "$name"; else bad_ "$name" "rc=$rc: $out"; fi
}
check_refusal "a malformed SHA256 pin is rejected"                SHA256=abc VERSION="$TAG"
check_refusal "a pin with BRANCH (never checked) is rejected"     SHA256="$GOOD_SUM" BRANCH=main
check_refusal "a pin with DTU_ALLOW_UNVERIFIED is rejected"       SHA256="$GOOD_SUM" DTU_ALLOW_UNVERIFIED=1 VERSION="$TAG"
out="$(env SHA256="$GOOD_SUM" VERSION="$TAG" bash "$REPO_ROOT/bin/dtu-install.sh" 2>&1)"
if [[ "$out" == *"must be run as root"* ]]; then
  ok_ "a valid pin passes the input checks and stops only at the root check"
else
  bad_ "a valid pin passes the input checks and stops only at the root check" "$out"
fi

echo
echo "─────────────────────────────────────────────────────────────────"
printf "%d bestået, %d fejlet\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
