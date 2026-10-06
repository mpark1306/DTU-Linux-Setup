#!/usr/bin/env bash
###############################################################################
# DTU – Microsoft 365-webapps kan ikke fastgøres til proceslinjen, frittstående
#
# Retter maskiner der allerede har webapps fra install-ms-pwa.sh (Word, Outlook
# osv. i Ungoogled Chromium). Under Wayland, som er standard på Kubuntu 26.04,
# er "Fastgør til opgavelinjen" gråt, og vinduet får Chromiums ikon.
#
# ── Hvorfor ──────────────────────────────────────────────────────────────────
#
# Plasma kobler et Wayland-vindue til sin genvej via vinduets app_id, og kun
# ved at genvejens FILNAVN er app_id'et. Genvejene bygger på StartupWMClass,
# som kun virker under X11 og XWayland. Kører Chromium som rent Wayland-
# program, får PWA-vinduet fx app_id'et chrome-word.cloud.microsoft__-Default,
# ingen genvej hedder det, og Plasma ved ikke hvad det skal fastgøre.
#
# Rettelsen holder Chromium på XWayland, så den eksisterende kobling virker:
#   1) Flatpak-Chromium mister Wayland-socket'en (flatpak override
#      --nosocket=wayland). Også når den åbnes som almindelig browser, for
#      Chromium samler alle vinduer i den proces der allerede kører.
#   2) Genvejene får --ozone-platform=x11, for en Chromium uden Flatpak.
# Genvejene beholder deres navne, så eksisterende fastgørelser virker videre.
# Samme rettelse som install-ms-pwa.sh fra DTU Linux Setup efter v1.9.0.
#
# ── Brug ─────────────────────────────────────────────────────────────────────
#
#   sudo ./fix-pwa-pin-wayland.sh            # ret maskinen
#   sudo ./fix-pwa-pin-wayland.sh --check    # vis tilstanden, ændr intet
#   sudo ./fix-pwa-pin-wayland.sh --undo     # fjern rettelsen igen
#
# Bagefter skal Chromium lukkes helt én gang (alle vinduer, også webapps).
# Scriptet viser hvem der har den åben. Det lukker den ikke selv: en bruger
# kan have arbejde i et vindue.
#
# Kan køres igen: en genvej der allerede har flaget, røres ikke.
###############################################################################
set -euo pipefail

FLATPAK_ID="io.github.ungoogled_software.ungoogled_chromium"
FLAG="--ozone-platform=x11"
# Kun til testene: et falsk rodtræ.
R="${FIX_ROOT:-}"

MODE=fix
case "${1:-}" in
    "")        ;;
    --check)   MODE=check ;;
    --undo)    MODE=undo ;;
    -h|--help) sed -n '3,37p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "Unknown option: $1 (see --help)" >&2; exit 2 ;;
esac

if [[ -t 1 ]]; then GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; NC=$'\033[0m'
else GREEN=""; YELLOW=""; RED=""; NC=""; fi
ok()   { echo "  ${GREEN}[OK]${NC} $*"; }
info() { echo "  [i] $*"; }
warn() { echo "  ${YELLOW}[WARN]${NC} $*"; }
die()  { echo "  ${RED}[FAIL]${NC} $*" >&2; exit 1; }

if [[ -z "$R" && $EUID -ne 0 ]]; then
    die "Run it with sudo: it changes files in /usr/share/applications and every user's home."
fi

# Genvejene fra install-ms-pwa.sh: ms-<id>.desktop med en --app=-linje, både
# de systemdækkende (--system) og dem i brugernes egne mapper.
shortcuts() {
    local f
    for f in "${R}"/usr/share/applications/ms-*.desktop \
             "${R}"/usr/local/share/applications/ms-*.desktop \
             "${R}"/home/*/.local/share/applications/ms-*.desktop \
             "${R}"/root/.local/share/applications/ms-*.desktop; do
        [[ -f "$f" ]] && grep -q '^Exec=.*--app=' "$f" && printf '%s\n' "$f"
    done
    return 0
}

# Skriv filen om via cat, så ejer og rettigheder bevares. sed -i ville lave
# en ny fil ejet af root i brugerens hjemmemappe.
rewrite_exec() {
    local f="$1" expr="$2" tmp
    tmp="$(mktemp)"
    sed -e "/^Exec=/ ${expr}" "$f" > "$tmp"
    if ! cmp -s "$tmp" "$f"; then cat "$tmp" > "$f"; rm -f "$tmp"; return 0; fi
    rm -f "$tmp"; return 1
}

flatpak_installed() {
    command -v flatpak >/dev/null 2>&1 && flatpak info "$FLATPAK_ID" >/dev/null 2>&1
}

wayland_blocked() {
    flatpak override --system --show "$FLATPAK_ID" 2>/dev/null | grep -q '^sockets=.*!wayland'
}

echo "Microsoft 365 web apps: pinning to the task manager under Wayland"
echo

# ── Flatpak ─────────────────────────────────────────────────────────────────
if ! flatpak_installed; then
    info "The Ungoogled Chromium flatpak is not installed; no override needed."
elif [[ $MODE == check ]]; then
    if wayland_blocked; then ok "Chromium (flatpak) is kept off Wayland"
    else warn "Chromium (flatpak) may run natively on Wayland: pinning can be greyed out"; fi
elif [[ $MODE == undo ]]; then
    flatpak override --system --socket=wayland "$FLATPAK_ID"
    ok "Chromium (flatpak) may use Wayland again"
else
    flatpak override --system --nosocket=wayland "$FLATPAK_ID"
    ok "Chromium (flatpak) is kept off Wayland (flatpak override --nosocket=wayland)"
fi

# ── Genveje ─────────────────────────────────────────────────────────────────
mapfile -t files < <(shortcuts)
if (( ${#files[@]} == 0 )); then
    info "No Microsoft 365 shortcuts (ms-*.desktop) found."
fi
changed=0; missing=0
dirs=()
for f in "${files[@]}"; do
    name="${f#"${R}"}"
    case "$MODE" in
        check)
            if grep -q "^Exec=.*${FLAG} " "$f"; then ok "$name"
            else warn "$name lacks ${FLAG}"; missing=$((missing + 1)); fi ;;
        undo)
            if rewrite_exec "$f" "s# ${FLAG}##"; then
                info "Removed ${FLAG} from $name"; changed=$((changed + 1))
                dirs+=("$(dirname "$f")")
            fi ;;
        fix)
            if grep -q "^Exec=.*${FLAG} " "$f"; then
                ok "$name (already done)"
            elif rewrite_exec "$f" "s# --app=# ${FLAG} --app=#"; then
                ok "$name"; changed=$((changed + 1))
                dirs+=("$(dirname "$f")")
            fi ;;
    esac
done
if (( ${#dirs[@]} > 0 )) && command -v update-desktop-database >/dev/null 2>&1; then
    printf '%s\n' "${dirs[@]}" | sort -u | while read -r d; do
        update-desktop-database "$d" 2>/dev/null || true
    done
fi

# ── Kørende Chromium ────────────────────────────────────────────────────────
# Rettelsen gælder først for en Chromium der starter efter den.
running="$(ps -C chrome -o user= 2>/dev/null | sort -u | tr '\n' ' ' || true)"

echo
case "$MODE" in
    check)
        if (( missing > 0 )) || { flatpak_installed && ! wayland_blocked; }; then
            echo "Not fixed. Run: sudo $0"; exit 1
        fi
        echo "Fixed." ;;
    undo)
        echo "Undone (${changed} shortcuts changed)." ;;
    fix)
        echo "Done (${changed} shortcuts changed)."
        if [[ -n "${running// /}" ]]; then
            warn "Chromium is open for: ${running}"
            echo "      Close it completely (every window, the web apps too), then open the"
            echo "      web app again. Until then its open windows still cannot be pinned."
        fi ;;
esac
