#!/usr/bin/env bash
###############################################################################
# DTU AIT – netværksdrev, frittstående
#
# Samme resultat som netværksdrev-modulet i DTU Linux Setup for AIT-profilen,
# men uden noget af det: ingen common.sh, ingen site_require, ingen GUI.
# Beregnet til at blive kørt i hånden fra en terminal på en maskine hvor DTU
# Linux Setup ikke er installeret — eller hvor man bare vil have drevene op.
#
#   O-drev   Afdelingens fælles drev            → /mnt/Odrev
#   M-drev   Brugerens personlige drev          → /mnt/Mdrev
#
# ── Brug ─────────────────────────────────────────────────────────────────────
#
#   sudo ./ait-drives.sh                     # spørger om bruger og kodeord
#   sudo ./ait-drives.sh --user mpark        # spørger kun om kodeord
#   sudo DTU_USERNAME=mpark DTU_PASSWORD=… ./ait-drives.sh   # uden prompt
#
# Samme variabelnavne som modulet i DTU Linux Setup, så en eksisterende
# env-fil kan genbruges direkte.
#
# Der er med vilje intet --password-flag. Alt på kommandolinjen kan læses af
# enhver bruger på maskinen med `ps`, og det er et domænekodeord.
#
# ── Tilvalg ──────────────────────────────────────────────────────────────────
#
#   --user NAVN        WIN-brugernavn drevene monteres for
#   --domain NAVN      NetBIOS-domæne (default: WIN)
#   --server VÆRT      filserveren begge drev ligger på
#   --o-share STI      afdelingens fælles share, fx Department/Institut
#   --no-o-drive       spring O-drevet over
#   --no-m-drive       spring M-drevet over
#   --unmount          fjern begge drev igen (fstab-linjer og automounts)
#   --no-site-conf     ignorér /etc/dtu-setup/ helt, også hvis den findes
#   --show-values      vis værtsnavne i klartekst (ellers maskeres de)
#   -h, --help
#
# ── Kan køres igen ───────────────────────────────────────────────────────────
#
# Scriptet konvergerer mod en kendt tilstand. Egne fstab-linjer for de to
# monteringspunkter fjernes først, så en genkørsel ikke lægger dubletter ind,
# og resten af fstab røres ikke. Fejl afbryder ikke undervejs: de samles op og
# rapporteres til sidst, så et fejlende O-drev ikke koster dig M-drevet.
# Exitkoden er 1 hvis noget står tilbage.
#
# ── Hvor M-drevet ligger ─────────────────────────────────────────────────────
#
# Det personlige drev ligger under en af flere nummererede undermapper på
# users-sharet, og hvilken en er ikke til at regne ud på forhånd. Scriptet
# prøver at montere hver enkelt indtil en virker, og husker svaret, så en
# genkørsel er hurtig. Er svaret forældet, prøves resten igen.
#
# ── Værdier vises ikke på skærmen ────────────────────────────────────────────
#
# Værtsnavne og kodeord skrives aldrig ud. Indtastning af kodeord sker uden
# ekko. Scriptet køres typisk på en andens maskine med nogen kigge med, og et
# terminaludklip ender let i en supportsag. --show-values slår maskeringen fra
# når man fejlsøger alene.
#
# ── Serveradresser ───────────────────────────────────────────────────────────
#
# Slås op i denne rækkefølge, første fund vinder:
#
#   1. drives.conf ved siden af scriptet
#   2. /etc/dtu-setup/site.conf
#   3. /etc/dtu-setup/dtu-ait.env          (den forældede profil)
#   4. spørger
#
# Værdierne står IKKE i scriptet. De peger på intern DTU-infrastruktur, og
# scriptet her ligger i et offentligt repo. Se drives.conf.example.
#
# ── Vedligehold ──────────────────────────────────────────────────────────────
#
# Dette er bevidst en kopi af AIT-grenen i scripts/ubuntu/qdrive.sh. Ændres
# monteringsopsætningen dér, skal den ændres her. Alternativet — et script der
# kun findes i en ZIP på nogens skrivebord — er værre.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
banner() { printf '\n%s%s=== %s ===%s\n\n' "$CYAN" "$BOLD" "$1" "$NC"; }
ok()     { printf '%s✅ %s%s\n' "$GREEN" "$1" "$NC"; }
warn()   { printf '%s⚠️  %s%s\n' "$YELLOW" "$1" "$NC"; }
fail()   { printf '%s❌ %s%s\n' "$RED" "$1" "$NC"; }

usage() {
    sed -n '3,72p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

# Monteringsvalgene er skrevet af fra common.sh. De to konstanter hører
# sammen og skal ændres begge steder.
#
# vers=3.0/ntlmssp/nodfs undgår kernens DFS-referral-fejl. mount-timeout er
# det der afgør hvor længe skrivebordet står stille når serveren ikke kan
# nås: en automount afbryder ENHVER adgang til stien, og kalderen sover
# uafbrydeligt indtil monteringen lykkes eller timer ud.
CIFS_MOUNT_OPTS="vers=3.0,sec=ntlmssp,nosharesock,nodfs,iocharset=utf8,serverino"
CIFS_SYSTEMD_OPTS="_netdev,nofail,x-systemd.automount,x-systemd.idle-timeout=600,x-systemd.mount-timeout=10"

O_MOUNTPOINT="/mnt/Odrev"
M_MOUNTPOINT="/mnt/Mdrev"
FSTAB_FILE="/etc/fstab"

ARG_USER=""
ARG_DOMAIN=""
ARG_SERVER=""
ARG_O_SHARE=""
WANT_O=1
WANT_M=1
UNMOUNT_ONLY=0
USE_SITE_CONF=1
SHOW_VALUES=0
PROBLEMS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)        ARG_USER="${2:-}";      shift 2 ;;
        --domain)      ARG_DOMAIN="${2:-}";    shift 2 ;;
        --server)      ARG_SERVER="${2:-}";    shift 2 ;;
        --o-share)     ARG_O_SHARE="${2:-}";   shift 2 ;;
        --no-o-drive)  WANT_O=0;               shift ;;
        --no-m-drive)  WANT_M=0;               shift ;;
        --unmount)     UNMOUNT_ONLY=1;         shift ;;
        --no-site-conf) USE_SITE_CONF=0;       shift ;;
        --show-values) SHOW_VALUES=1;          shift ;;
        --password|--password=*)
            fail "Der er ikke noget --password-flag, og det er med vilje."
            echo "   Alt på kommandolinjen kan læses af enhver bruger på maskinen"
            echo "   med \`ps\`, og det her er et domænekodeord. Brug DTU_PASSWORD"
            echo "   eller lad scriptet spørge."
            exit 2 ;;
        -h|--help)     usage 0 ;;
        *)             fail "Ukendt tilvalg: $1"; usage 2 ;;
    esac
done

mask() {
    local v="$1"
    if [[ "$SHOW_VALUES" -eq 1 ]]; then printf '%s' "$v"
    else printf '(sat, %d tegn)' "${#v}"; fi
}

problem() { PROBLEMS+=("$1"); fail "$1"; }

read_var() {   # read_var FIL VARIABEL
    [[ -r "$1" ]] || return 1
    local v
    v="$(sed -n "s/^[[:space:]]*$2=//p" "$1" | head -1 | tr -d '"'"'" | tr -d '\r')"
    [[ -n "$v" && "$v" != *"<"*">"* ]] || return 1
    printf '%s' "$v"
}

# Sætter FOUND_VALUE og FOUND_IN i den kaldende shell frem for at skrive
# værdien ud: kaldes den i en kommandosubstitution, sker tildelingen i en
# subshell og kilden er tom igen bagefter.
FOUND_VALUE=""
FOUND_IN=""
find_var() {
    FOUND_VALUE=""
    FOUND_IN=""
    local f v sources=("$SCRIPT_DIR/drives.conf")
    if [[ "$USE_SITE_CONF" -eq 1 ]]; then
        sources+=(/etc/dtu-setup/site.conf /etc/dtu-setup/dtu-ait.env)
    fi
    for f in "${sources[@]}"; do
        if v="$(read_var "$f" "$1")"; then
            FOUND_VALUE="$v"
            FOUND_IN="$(basename "$f")"
            return 0
        fi
    done
    return 1
}

if [[ $EUID -ne 0 ]]; then
    fail "Skal køres som root — den skriver i /etc/fstab og monterer."
    echo "   sudo $0 $*"
    exit 1
fi

fstab_drop() {   # fstab_drop MOUNTPOINT
    sed -i "\|[[:space:]]${1}[[:space:]].*cifs|d" "$FSTAB_FILE" 2>/dev/null || true
    return 0
}

automount_stop() {   # automount_stop MOUNTPOINT
    local unit; unit="$(systemd-escape -p --suffix=automount "$1")"
    local munit; munit="$(systemd-escape -p --suffix=mount "$1")"
    systemctl stop "$unit" 2>/dev/null || true
    systemctl stop "$munit" 2>/dev/null || true
    if mountpoint -q "$1" 2>/dev/null; then
        # umount uden -l blokerer selv mod en server der ikke svarer.
        umount -l "$1" 2>/dev/null || true
    fi
    return 0
}

if [[ "$UNMOUNT_ONLY" -eq 1 ]]; then
    banner "AIT netværksdrev – fjern"
    [[ -f "$FSTAB_FILE" ]] && cp -a "$FSTAB_FILE" "${FSTAB_FILE}.dtu.bak.$(date +%s)"
    for mp in "$O_MOUNTPOINT" "$M_MOUNTPOINT"; do
        automount_stop "$mp"
        fstab_drop "$mp"
        ok "Fjernet: $mp"
    done
    systemctl daemon-reload
    ok "Færdig. Selve mapperne er ikke slettet."
    exit 0
fi

banner "AIT netværksdrev – O-drev og M-drev"

# ── Domænebruger ─────────────────────────────────────────────────────────────
U="${ARG_USER:-${DTU_USERNAME:-}}"
P="${DTU_PASSWORD:-}"
DOMAIN="${ARG_DOMAIN:-${DTU_AD_NETBIOS:-WIN}}"

if [[ -z "$U" ]]; then
    echo "Drevene monteres for en navngiven domænebruger — M-drevet er"
    echo "personligt, så det er DEN brugers login der skal ind."
    echo ""
    read -rp "  WIN-brugernavn, kun kortnavnet (fx mpark): " U
fi
[[ -n "$U" ]] || { fail "Brugernavn er påkrævet."; exit 1; }

# Folk skriver domænet med, og alle tre former er "rigtige" andre steder.
# Credentials-filen skal have brugernavnet alene, så WIN\WIN\mpark fejler
# godkendelsen uden at sige hvorfor.
U_RAW="$U"
U="${U##*\\}"
U="${U%%@*}"
if [[ "$U" != "$U_RAW" ]]; then
    echo "      (bruger '$U' — domænet sættes på automatisk)"
fi

if [[ -z "$P" ]]; then
    if [[ ! -t 0 ]]; then
        fail "Intet kodeord, og der er ingen terminal at spørge på."
        echo "   Sæt DTU_PASSWORD, eller kør scriptet fra en terminal."
        exit 1
    fi
    read -rsp "  Kodeord for ${DOMAIN}\\${U} (vises ikke): " P
    echo ""
fi
[[ -n "$P" ]] || { fail "Kodeord er påkrævet."; exit 1; }

if ! id "$U" >/dev/null 2>&1; then
    fail "Brugeren '$U' findes ikke på denne maskine."
    echo "   Domænebrugeren skal kunne slås op lokalt, før drevene kan ejes"
    echo "   af den. Er maskinen domæne-joinet? Prøv: getent passwd $U"
    exit 1
fi
UID_NUM="$(id -u "$U")"
GID_NUM="$(id -g "$U")"
HOME_DIR="$(getent passwd "$U" | cut -d: -f6)"
HOME_DIR="${HOME_DIR:-/home/$U}"

echo "  Bruger:   ${DOMAIN}\\${U}  (uid=${UID_NUM} gid=${GID_NUM})"

# ── Serveradresser ───────────────────────────────────────────────────────────
if [[ -n "$ARG_SERVER" ]]; then
    SERVER="$ARG_SERVER"
    echo "  Filserver: $(mask "$SERVER")  fra --server"
elif find_var SITE_MDRIVE_SERVER; then
    SERVER="$FOUND_VALUE"; echo "  Filserver: $(mask "$SERVER")  fra ${FOUND_IN}"
elif find_var SITE_FILE_SERVER; then
    SERVER="$FOUND_VALUE"; echo "  Filserver: $(mask "$SERVER")  fra ${FOUND_IN}"
else
    echo ""
    echo "Filserverens værtsnavn — den både O-drevet og M-drevet ligger på."
    echo "  Et navn i stil med <navn>.win.dtu.dk, ikke en IP-adresse."
    echo "  Står den i site.conf på en maskine der virker, findes den med:"
    echo "      grep -E 'SITE_(MDRIVE|FILE)_SERVER' /etc/dtu-setup/*.conf"
    echo ""
    read -rp "  Værtsnavn: " SERVER
    [[ -n "$SERVER" ]] || { fail "Uden filserver kan drevene ikke monteres."; exit 1; }
fi

USERS_SHARE="$(find_var SITE_MDRIVE_BASE >/dev/null 2>&1 && printf '%s' "$FOUND_VALUE" || printf 'Users')"
USERS_PREFIX="$(find_var SITE_AIT_USERS_PREFIX >/dev/null 2>&1 && printf '%s' "$FOUND_VALUE" || printf 'users')"
USERS_FROM="$(find_var SITE_AIT_USERS_FIRST >/dev/null 2>&1 && printf '%s' "$FOUND_VALUE" || printf '1')"
USERS_TO="$(find_var SITE_AIT_USERS_LAST >/dev/null 2>&1 && printf '%s' "$FOUND_VALUE" || printf '9')"

if [[ "$WANT_O" -eq 1 ]]; then
    if [[ -n "$ARG_O_SHARE" ]]; then
        O_SHARE="$ARG_O_SHARE"; echo "  O-drev:    $(mask "$O_SHARE")  fra --o-share"
    elif find_var SITE_AIT_O_SHARE; then
        O_SHARE="$FOUND_VALUE"; echo "  O-drev:    $(mask "$O_SHARE")  fra ${FOUND_IN}"
    else
        echo ""
        echo "Afdelingens fælles share, uden servernavn foran —"
        echo "  formen er <share>/<afdeling>, fx Department/Institut."
        echo ""
        read -rp "  O-drev share: " O_SHARE
        if [[ -z "$O_SHARE" ]]; then
            warn "Intet O-drev angivet — springer det over."
            WANT_O=0
        fi
    fi
fi
echo ""

# ── Forudsætninger ───────────────────────────────────────────────────────────
if ! command -v mount.cifs >/dev/null 2>&1; then
    echo "[1/6] Installerer cifs-utils..."
    if ! (apt-get update -qq >/dev/null 2>&1; apt-get install -y cifs-utils >/dev/null 2>&1); then
        fail "Kunne ikke installere cifs-utils. Er der netværk?"
        exit 1
    fi
    ok "cifs-utils installeret"
else
    echo "[1/6] cifs-utils er der allerede — springer over"
fi

if [[ ! -d "$HOME_DIR" ]]; then
    mkdir -p "$HOME_DIR"
    chown "$UID_NUM":"$GID_NUM" "$HOME_DIR"
    chmod 0700 "$HOME_DIR"
fi

# ── Credentials ──────────────────────────────────────────────────────────────
#
# Skrives under umask 077 i en subshell frem for chmod bagefter: filen må
# ikke findes læsbar for andre i vinduet imellem.
echo "[2/6] Skriver credentials-fil..."
CREDS_FILE="${HOME_DIR}/.smbcred-$(printf '%s' "$SERVER" | cut -d. -f1)"
(
    umask 077
    cat > "$CREDS_FILE" <<CREDS
username=${U}
password=${P}
domain=${DOMAIN}
CREDS
)
chown "$UID_NUM":"$GID_NUM" "$CREDS_FILE"
chmod 600 "$CREDS_FILE"
ok "$(basename "$CREDS_FILE") (mode 600, ejet af $U)"

[[ -f "$FSTAB_FILE" ]] && cp -a "$FSTAB_FILE" "${FSTAB_FILE}.dtu.bak.$(date +%s)"

test_mount() {   # test_mount SHARE_PATH
    local tmp; tmp="$(mktemp -d /tmp/dtu-probe.XXXXXX)"
    if mount -t cifs "//${SERVER}/${1}" "$tmp" \
         -o "credentials=${CREDS_FILE},uid=${UID_NUM},gid=${GID_NUM},${CIFS_MOUNT_OPTS}" \
         >/dev/null 2>&1; then
        umount "$tmp" 2>/dev/null || umount -l "$tmp" 2>/dev/null || true
        rmdir "$tmp" 2>/dev/null || true
        return 0
    fi
    rmdir "$tmp" 2>/dev/null || true
    return 1
}

write_share() {   # write_share SHARE_PATH MOUNTPOINT
    local path="$1" mp="$2"
    mkdir -p "$mp"
    chown "$UID_NUM":"$GID_NUM" "$mp"
    chmod 0770 "$mp"
    fstab_drop "$mp"
    printf '%s\n' \
      "//${SERVER}/${path}  ${mp}  cifs  credentials=${CREDS_FILE},uid=${UID_NUM},gid=${GID_NUM},dir_mode=0770,file_mode=0660,${CIFS_MOUNT_OPTS},${CIFS_SYSTEMD_OPTS}  0  0" \
      >> "$FSTAB_FILE"
    if mountpoint -q "$mp" 2>/dev/null; then
        umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
    fi
    return 0
}

# ── M-drev ───────────────────────────────────────────────────────────────────
M_SHARE=""
if [[ "$WANT_M" -eq 1 ]]; then
    echo "[3/6] Finder dit personlige M-drev under ${USERS_SHARE}/${USERS_PREFIX}${USERS_FROM}-${USERS_TO}..."
    M_CACHE="${HOME_DIR}/.config/dtu-setup/ait-mdrive-subdir"
    CACHED=""
    [[ -r "$M_CACHE" ]] && CACHED="$(cat "$M_CACHE" 2>/dev/null || true)"

    CANDIDATES=()
    [[ -n "$CACHED" ]] && CANDIDATES+=("$CACHED")
    for n in $(seq "$USERS_FROM" "$USERS_TO"); do
        [[ "${USERS_PREFIX}${n}" == "$CACHED" ]] && continue
        CANDIDATES+=("${USERS_PREFIX}${n}")
    done

    for d in "${CANDIDATES[@]}"; do
        if test_mount "${USERS_SHARE}/${d}/${U}"; then
            M_SHARE="${USERS_SHARE}/${d}/${U}"
            mkdir -p "$(dirname "$M_CACHE")"
            printf '%s' "$d" > "$M_CACHE"
            chown -R "$UID_NUM":"$GID_NUM" "$(dirname "$M_CACHE")" 2>/dev/null || true
            ok "M-drev fundet i ${d}"
            break
        fi
    done

    if [[ -z "$M_SHARE" ]]; then
        problem "Kunne ikke finde '${U}' under ${USERS_SHARE}/${USERS_PREFIX}${USERS_FROM}-${USERS_TO}."
        echo "         Forkert kodeord, eller mappen ligger uden for det interval."
    else
        write_share "$M_SHARE" "$M_MOUNTPOINT"
        ok "M-drev → ${M_MOUNTPOINT}"
    fi
else
    echo "[3/6] M-drev fravalgt"
fi

# ── O-drev ───────────────────────────────────────────────────────────────────
if [[ "$WANT_O" -eq 1 ]]; then
    echo "[4/6] Opsætter O-drev..."
    if test_mount "$O_SHARE"; then
        ok "O-drev kan nås"
    else
        # nofail betyder at en utilgængelig share ikke blokerer boot — linjen
        # skrives alligevel, så drevet dukker op når adgangen er på plads.
        warn "O-drev kunne ikke test-monteres (rettigheder? ikke medlem?)."
        warn "Linjen skrives alligevel — nofail gør at den bare ikke monterer endnu."
    fi
    write_share "$O_SHARE" "$O_MOUNTPOINT"
    ok "O-drev → ${O_MOUNTPOINT}"
else
    echo "[4/6] O-drev fravalgt"
fi

# ── Start ────────────────────────────────────────────────────────────────────
echo "[5/6] Genindlæser systemd og starter automounts..."
systemctl daemon-reload
for mp in "$O_MOUNTPOINT" "$M_MOUNTPOINT"; do
    grep -qE "[[:space:]]${mp}[[:space:]]" "$FSTAB_FILE" 2>/dev/null || continue
    unit="$(systemd-escape -p --suffix=automount "$mp")"
    systemctl restart "$unit" 2>/dev/null || systemctl start "$unit" 2>/dev/null || \
        problem "Kunne ikke starte automount for ${mp}"
done

# ── Kontrol ──────────────────────────────────────────────────────────────────
echo "[6/6] Kontrollerer..."
for mp in "$O_MOUNTPOINT" "$M_MOUNTPOINT"; do
    grep -qE "[[:space:]]${mp}[[:space:]]" "$FSTAB_FILE" 2>/dev/null || continue
    if ls "$mp" >/dev/null 2>&1; then
        ok "${mp} svarer"
    else
        problem "${mp} kunne ikke læses. Prøv: ls ${mp}"
    fi
done

echo ""
if [[ ${#PROBLEMS[@]} -gt 0 ]]; then
    fail "Færdig med ${#PROBLEMS[@]} problem(er):"
    for p in "${PROBLEMS[@]}"; do echo "   • $p"; done
    exit 1
fi

banner "Færdig"
echo "  O-drev:  ${O_MOUNTPOINT}"
echo "  M-drev:  ${M_MOUNTPOINT}"
echo ""
echo "  Drevene monteres ved første adgang og afmonteres igen når de har"
echo "  været ubrugte i 10 minutter. Det er meningen."
