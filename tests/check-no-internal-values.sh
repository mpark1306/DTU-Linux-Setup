#!/usr/bin/env bash
###############################################################################
# Guard: no concrete DTU infrastructure in tracked files
#
# This repo is public. Internal file servers, share names and AD group names
# belong in /etc/dtu-setup/site.conf on the machine — never in a commit.
#
# IMPORTANT: this script deliberately contains NO list of the internal values
# it guards against. A blocklist in a public repo would publish exactly what it
# is meant to keep out. It works on structure instead:
#
#   1. SITE_* may only be assigned an approved site-independent default, a
#      <placeholder>, an empty value, or another shell variable.
#   2. Only approved, publicly-advertised *.dtu.dk hostnames may appear.
#   3. The mount target chosen at runtime must come from configuration, never
#      from a literal.
#
# Adding a genuinely public value? Extend the approved lists below and say in
# the commit message why it is safe to publish.
#
# Run: bash tests/check-no-internal-values.sh
###############################################################################
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2

SELF="tests/check-no-internal-values.sh"
FAILURES=0

note() { printf '  \033[0;31m✗\033[0m %s\n' "$1"; FAILURES=$((FAILURES+1)); }
good() { printf '  \033[0;32m✓\033[0m %s\n' "$1"; }

# Values that are the same at every DTU site and already public.
APPROVED_VALUES=(
  "WIN.DTU.DK" "win.dtu.dk" "@win.dtu.dk"
  "DTUSecure"
  "https://webprint.dtu.dk"
  "https://serviceportal.dtu.dk"
  "ait@dtu.dk"
  "Users" 'Users$'
  "Qdrev/SUS" "Qdrev/SUS/Personal"
  '2adm$/AIT'
)

# Hostnames DTU advertises publicly.
APPROVED_HOSTS=(
  win.dtu.dk webprint.dtu.dk serviceportal.dtu.dk
  password.dtu.dk net.ait.dtu.dk sustain.dtu.dk
)

in_list() { # in_list NEEDLE LIST...
  local needle="$1"; shift
  local item
  for item in "$@"; do [[ "$needle" == "$item" ]] && return 0; done
  return 1
}

tracked() { git ls-files | grep -v "^${SELF}$"; }

# ── Rule 1: SITE_* assignments ───────────────────────────────────────────────
echo "── Regel 1: SITE_* må kun tildeles godkendte defaults eller placeholders ──"
r1=$FAILURES
while IFS= read -r file; do
  [[ -f "$file" ]] || continue
  while IFS= read -r line; do
    # ": ${SITE_X:=value}"  and  SITE_X="value"
    val="$(printf '%s' "$line" | sed -nE 's/.*SITE_[A-Z0-9_]+:=([^}]*)\}.*/\1/p')"
    [[ -z "$val" ]] && val="$(printf '%s' "$line" | sed -nE 's/.*SITE_[A-Z0-9_]+="([^"]*)".*/\1/p')"
    [[ -z "$val" ]] && continue
    [[ "$val" == *'$'* && "$val" != 'Users$' && "$val" != '2adm$/AIT' ]] && continue  # variable reference
    [[ "$val" == *"<"*">"* ]] && continue                                             # placeholder
    in_list "$val" "${APPROVED_VALUES[@]}" && continue
    note "$file: SITE_*-værdi der hverken er godkendt default eller placeholder: [$val]"
  done < <(grep -E 'SITE_[A-Z0-9_]+(:=|=")' "$file" 2>/dev/null)
done < <(tracked)
[[ $FAILURES -eq $r1 ]] && good "ingen ikke-godkendte SITE_*-værdier"

# ── Rule 2: dtu.dk hostnames ─────────────────────────────────────────────────
echo "── Regel 2: kun offentligt annoncerede *.dtu.dk-værtsnavne ──"
r2=$FAILURES
while IFS= read -r file; do
  [[ -f "$file" ]] || continue
  while IFS= read -r host; do
    host="${host#@}"
    in_list "$host" "${APPROVED_HOSTS[@]}" && continue
    note "$file: ikke-godkendt DTU-værtsnavn: [$host]"
  done < <(grep -ohE '[a-zA-Z0-9][a-zA-Z0-9.-]*\.dtu\.dk' "$file" 2>/dev/null | sort -u)
done < <(tracked)
[[ $FAILURES -eq $r2 ]] && good "ingen ikke-godkendte DTU-værtsnavne"

# ── Rule 3: runtime mount target must be config-driven ───────────────────────
echo "── Regel 3: mount-mål sættes fra konfiguration, ikke fra literaler ──"
r3=$FAILURES
while IFS= read -r file; do
  [[ "$file" == scripts/* ]] || continue
  [[ -f "$file" ]] || continue
  while IFS= read -r line; do
    printf '%s' "$line" | grep -qE '^[0-9]+:\s*#' && continue
    rhs="$(printf '%s' "$line" | sed -E 's/^[0-9]+:\s*(SERVER|Q_SHARE_PATH|P_SHARE_PATH)=//')"
    # A single-quoted value never expands, so a '$' inside it is literal text —
    # this is exactly how the hardcoded Qumulo share slipped through before.
    if [[ "$rhs" == \'*\' ]]; then
      note "$file: mount-mål tildelt en literal: $(printf '%s' "$line" | sed 's/^ *//')"
      continue
    fi
    [[ "$rhs" == *'${'* || "$rhs" == '$'* || "$rhs" == '"$'* ]] && continue  # variable reference
    note "$file: mount-mål tildelt en literal: $(printf '%s' "$line" | sed 's/^ *//')"
  done < <(grep -nE '^\s*(SERVER|Q_SHARE_PATH|P_SHARE_PATH)=' "$file" 2>/dev/null)
done < <(tracked)
[[ $FAILURES -eq $r3 ]] && good "alle mount-mål er konfigurationsdrevne"

echo "─────────────────────────────────────────────────────────────────"
if [[ $FAILURES -eq 0 ]]; then
  echo "✅ Ingen interne værdier i trackede filer."
  exit 0
fi
cat <<MSG
❌ $FAILURES fund.

Værdier der identificerer DTU-infrastruktur hører hjemme i
/etc/dtu-setup/site.conf på maskinen — ikke i repoet. Brug en <placeholder> i
skabelonerne, og lad koden læse værdien via load_site_conf() / site_require.
MSG
exit 1
