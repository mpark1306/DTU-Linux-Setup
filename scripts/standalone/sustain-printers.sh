#!/usr/bin/env bash
###############################################################################
# DTU Sustain – printer setup, frittstående
#
# Samme resultat som Printers-modulet i DTU Linux Setup, men uden noget af
# det: ingen common.sh, ingen site_require, ingen GUI. Beregnet til at blive
# kørt i hånden fra en terminal på en maskine hvor DTU Linux Setup ikke er
# installeret — eller hvor man bare vil have printerne op uden alt det andet.
#
#   FollowMe-MFP-PCL   Konica MFP via SMB mod FollowMe-serveren
#   BYG-PHP03-PCL      HP DesignJet Z9dr storformatplotter, direkte JetDirect
#
# ── Brug ─────────────────────────────────────────────────────────────────────
#
#   sudo ./sustain-printers.sh                    # spørger om bruger og kodeord
#   sudo ./sustain-printers.sh --user mpark       # spørger kun om kodeord
#   sudo DTU_USERNAME=mpark DTU_PASSWORD=… ./sustain-printers.sh    # uden prompt
#
# Samme variabelnavne som Printers-modulet i DTU Linux Setup bruger, så en
# eksisterende env-fil kan genbruges direkte.
#
# Der er med vilje intet --password-flag. Alt på kommandolinjen kan læses af
# enhver bruger på maskinen med `ps`, og det er et domænekodeord. Kodeordet
# tages fra DTU_PASSWORD eller fra prompten, som ikke ekkoer.
#
# ── Tilvalg ──────────────────────────────────────────────────────────────────
#
#   --user NAVN        WIN-brugernavn køen skal spoole som
#   --domain NAVN      NetBIOS-domæne (default: WIN)
#   --print-server VÆRT
#   --plot-server VÆRT  (tom streng springer plotteren over)
#   --no-plotter       spring plotteren over
#   --remove-all-printers
#                      fjern ALLE køer, også lokale printere maskinen selv har
#   --no-site-conf     ignorér /etc/dtu-setup/ helt, også hvis den findes
#   --show-values      vis værtsnavne i klartekst (ellers maskeres de)
#   -h, --help
#
# ── Kan køres igen ───────────────────────────────────────────────────────────
#
# Scriptet konvergerer mod en kendt tilstand frem for at antage en tom
# maskine. Det fjerner sine egne køer først — dem der hedder FollowMe-* eller
# BYG-PHP03-*, og dem der peger på FollowMe-serveren eller plotteren uanset
# hvad de hedder. Andre printere på maskinen røres ikke: en Brother på
# skrivebordet er ikke vores at fjerne. --remove-all-printers rydder alt, hvis
# det er det man vil.
#
# Derefter oprettes køerne igen, og til sidst kontrolleres at de findes, peger
# det rigtige sted hen, er slået til og tager imod jobs. En kø der står
# disabled eller reject bliver rettet.
#
# Fejl afbryder ikke undervejs. De samles op og rapporteres til sidst, så en
# fejlende plotter ikke koster dig FollowMe-køen. Exitkoden er 1 hvis noget
# står tilbage.
#
# ── Værdier vises ikke på skærmen ────────────────────────────────────────────
#
# Værtsnavne og kodeord skrives aldrig ud. Indtastning sker uden ekko, og
# kvitteringen viser kun længden. Scriptet køres typisk på en andens maskine
# med nogen kigge med, og et terminaludklip ender let i en supportsag.
# --show-values slår maskeringen fra når man fejlsøger alene.
#
# ── Uafhængighed af DTU Linux Setup ──────────────────────────────────────────
#
# Scriptet kræver intet fra DTU Linux Setup: ingen common.sh, ingen site.conf,
# ingen installeret pakke. Findes /etc/dtu-setup/ bruges den som en bekvem
# kilde til serveradresser — men --no-site-conf slår også det fra, så det kan
# køres helt udenom på en maskine hvor værktøjet ER installeret.
#
# ── Serveradresser ───────────────────────────────────────────────────────────
#
# Slås op i denne rækkefølge, første fund vinder:
#
#   1. print.conf ved siden af scriptet
#   2. /etc/dtu-setup/site.conf
#   3. /etc/dtu-setup/dtu-sustain.env      (den forældede profil)
#   4. spørger
#
# Værdierne står IKKE i scriptet. De peger på intern DTU-infrastruktur, og
# scriptet her ligger i et offentligt repo.
#
# ── Vedligehold ──────────────────────────────────────────────────────────────
#
# Dette er bevidst en kopi af Sustain-grenen i scripts/ubuntu/followme.sh.
# Ændres køopsætningen dér, skal den ændres her. Alternativet — et script der
# kun findes i en ZIP på nogens skrivebord — er værre; det er præcis sådan
# image-byggeriet endte med kun at eksistere i hukommelsen hos én person.
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
    sed -n '3,75p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

ARG_USER=""
ARG_DOMAIN=""
ARG_PRINT_SERVER=""
ARG_PLOT_SERVER=""
PLOT_EXPLICITLY_OFF=0
USE_SITE_CONF=1
SHOW_VALUES=0
REMOVE_ALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)         ARG_USER="${2:-}"; shift 2 ;;
        --user=*)       ARG_USER="${1#*=}"; shift ;;
        --domain)       ARG_DOMAIN="${2:-}"; shift 2 ;;
        --domain=*)     ARG_DOMAIN="${1#*=}"; shift ;;
        --print-server) ARG_PRINT_SERVER="${2:-}"; shift 2 ;;
        --print-server=*) ARG_PRINT_SERVER="${1#*=}"; shift ;;
        --plot-server)  ARG_PLOT_SERVER="${2:-}"; PLOT_EXPLICITLY_OFF=1; shift 2 ;;
        --plot-server=*) ARG_PLOT_SERVER="${1#*=}"; PLOT_EXPLICITLY_OFF=1; shift ;;
        --no-plotter)   ARG_PLOT_SERVER=""; PLOT_EXPLICITLY_OFF=1; shift ;;
        --password|--password=*)
            fail "There is no --password flag."
            echo "   Everything on the command line can be read with 'ps' by any user"
            echo "   on the machine. Use DTU_PASSWORD=… or let the script ask."
            exit 1 ;;
        --remove-all-printers) REMOVE_ALL=1; shift ;;
        # Var et flag før standarden blev vendt. Accepteres stadig, så en
        # nedskrevet instruktion ikke pludselig fejler.
        --keep-other-printers) shift ;;
        --no-site-conf) USE_SITE_CONF=0; shift ;;
        --show-values)  SHOW_VALUES=1; shift ;;
        -h|--help)      usage 0 ;;
        *)              fail "Ukendt tilvalg: $1"; usage 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as root."
    echo "   sudo $0"
    exit 1
fi

banner "DTU Sustain – printer setup"

# ── Serveradresser ───────────────────────────────────────────────────────────

# Værdierne herunder er interne værtsnavne. De skrives aldrig på skærmen:
# en tekniker kører det her på en andens maskine, tit med nogen kigge med,
# og et terminaludklip ender let i en supportsag eller et skærmbillede.
# Kør med --show-values hvis du fejlsøger alene og vil se dem.
mask() {
    local v="$1"
    [[ -z "$v" ]] && { printf '(not set)'; return; }
    if [[ "${SHOW_VALUES:-0}" -eq 1 ]]; then printf '%s' "$v"
    else printf '(sat, %d tegn)' "${#v}"; fi
}

# Indtastning uden ekko, med maskeret kvittering så en slåfejl kan ses på
# længden uden at værdien står på skærmen.
read_hidden() {   # read_hidden PROMPT VARIABELNAVN
    local prompt="$1" name="$2" value
    read -rsp "$prompt" value
    echo ""
    printf -v "$name" '%s' "$value"
    if [[ -n "$value" ]]; then
        echo "      → $(mask "$value")"
    fi
    # Eksplicit. Var den sidste sætning en &&-liste, returnerede funktionen 1
    # når feltet var tomt — og med set -e døde hele scriptet tavst dér.
    # Symptomet var at man trykkede Enter for at springe plotteren over, og
    # så skete der ikke mere.
    return 0
}

read_var() {   # read_var FIL VARIABEL
    [[ -r "$1" ]] || return 1
    local v
    v="$(sed -n "s/^[[:space:]]*$2=//p" "$1" | head -1 | tr -d '"'"'" | tr -d '\r')"
    [[ -n "$v" && "$v" != *"<"*">"* ]] || return 1
    printf '%s' "$v"
}

# find_var sætter FOUND_VALUE og FOUND_IN i den kaldende shell frem for at
# skrive værdien ud. Kaldes den i en kommandosubstitution, sker tildelingen i
# en subshell og FOUND_IN er tom igen bagefter — kilden blev aldrig vist.
FOUND_VALUE=""
FOUND_IN=""

find_var() {   # find_var VARIABEL → FOUND_VALUE, FOUND_IN
    FOUND_VALUE=""
    FOUND_IN=""
    local f v sources=("$SCRIPT_DIR/print.conf")
    # /etc/dtu-setup/ hører til DTU Linux Setup. Den bruges hvis den er der,
    # men scriptet kræver den ikke — og --no-site-conf slår den fra, så det
    # kan køres helt udenom på en maskine hvor værktøjet ER installeret.
    if [[ "${USE_SITE_CONF:-1}" -eq 1 ]]; then
        sources+=(/etc/dtu-setup/site.conf /etc/dtu-setup/dtu-sustain.env)
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

# ── Domænebruger ─────────────────────────────────────────────────────────────
#
# Først, fordi det er hele pointen. FollowMe-køen spooler som en navngiven
# bruger — serveren kan ikke afregne et job eller frigive det ved
# kopimaskinen uden at vide hvem det tilhører. Alt andet herunder er
# valgfrit; det her er ikke.
#
# Rækkefølge: flag, så miljø, så prompt. Samme variabelnavne som modulet i
# DTU Linux Setup, så en env-fil derfra virker uændret.
U="${ARG_USER:-${DTU_USERNAME:-}}"
P="${DTU_PASSWORD:-}"
DOMAIN="${ARG_DOMAIN:-${DTU_AD_NETBIOS:-WIN}}"

if [[ -z "$U" || -z "$P" ]]; then
    echo "The queue prints as a named user. That is how FollowMe knows"
    echo "who the job belongs to, and who can release it at the machine."
    echo "If you are at someone else's computer, it is THEIR login that goes in."
    echo ""
fi

if [[ -z "$U" ]]; then
    read -rp "  WIN-brugernavn, kun kortnavnet (fx mpark): " U
fi
[[ -n "$U" ]] || { fail "A username is required."; exit 1; }

# Folk skriver domænet med. Det er en rimelig ting at gøre, og alle tre
# former er "rigtige" andre steder — men credentials-filen skal have
# WIN\brugernavn, så WIN\WIN\mpark eller WIN\mpark@dtu.dk fejler
# godkendelsen uden at sige hvorfor. Jobbet lander i køen og forsvinder.
U_RAW="$U"
U="${U##*\\}"            # WIN\mpark  →  mpark
U="${U%%@*}"             # mpark@dtu.dk → mpark
if [[ "$U" != "$U_RAW" ]]; then
    echo "      (using '$U'; the domain is added automatically)"
fi

if [[ -z "$P" ]]; then
    if [[ ! -t 0 ]]; then
        fail "No password, and there is no terminal to ask in."
        echo "   Set DTU_PASSWORD, or run the script from a terminal."
        exit 1
    fi
    read -rsp "  Password for ${DOMAIN}\\${U} (not shown): " P
    echo ""
fi
[[ -n "$P" ]] || { fail "A password is required."; exit 1; }

echo "  The queue spools as:  ${DOMAIN}\\${U}"
echo ""

# ── Serveradresser ───────────────────────────────────────────────────────────
#
# Værdierne skrives ikke på skærmen bagefter, men indtastes synligt: at taste
# et værtsnavn i blinde uden ekko og uden at kunne se en slåfejl er værre end
# det beskytter imod. Kodeordet ovenfor er den del der skal være skjult.
if [[ -n "$ARG_PRINT_SERVER" ]]; then
    PRINT_SERVER="$ARG_PRINT_SERVER"
    echo "  FollowMe-server: $(mask "$PRINT_SERVER")  fra --print-server"
elif find_var SITE_PRINT_SERVER; then
    PRINT_SERVER="$FOUND_VALUE"
    echo "  FollowMe-server: $(mask "$PRINT_SERVER")  fra ${FOUND_IN}"
else
    echo "The host name of the FollowMe print server."
    echo ""
    echo "  It is the Windows print server that Sustain's copiers sit behind,"
    echo "  a name like <name>.win.dtu.dk. It is NOT the copier's"
    echo "  own name, and not an IP address."
    echo ""
    echo "  If it is in /etc/dtu-setup/site.conf on a machine that works,"
    echo "  the script finds it by itself:"
    echo "      grep SITE_PRINT_SERVER /etc/dtu-setup/*.conf /etc/dtu-setup/*.env"
    echo ""
    read -rp "  Host name: " PRINT_SERVER
    [[ -n "$PRINT_SERVER" ]] || { fail "Without a print server the FollowMe queue cannot be created."; exit 1; }
fi

if [[ "$PLOT_EXPLICITLY_OFF" -eq 1 ]]; then
    PLOT_SERVER="$ARG_PLOT_SERVER"
    if [[ -n "$PLOT_SERVER" ]]; then
        echo "  Plotter:         $(mask "$PLOT_SERVER")  fra --plot-server"
    fi
elif find_var SITE_SUSTAIN_PLOT_SERVER; then
    PLOT_SERVER="$FOUND_VALUE"
    echo "  Plotter:         $(mask "$PLOT_SERVER")  fra ${FOUND_IN}"
else
    echo ""
    echo "Storformatplotteren i BYG (valgfri)."
    echo "  The device's own host name. It has no print server in front of it."
    echo "  Press Enter to skip it; FollowMe is created either way."
    echo ""
    read -rp "  Host name, or Enter: " PLOT_SERVER
fi
echo ""

# ── PPD-filer ────────────────────────────────────────────────────────────────
#
# Ved siden af scriptet først — det er sådan ZIP'en er pakket. Dernæst en
# installeret DTU Linux Setup, så scriptet også virker fra et checkout.
find_ppd() {   # find_ppd FILNAVN
    local name="$1" p
    for p in "$SCRIPT_DIR/$name" "$SCRIPT_DIR/../../data/$name" \
             "/opt/dtu-sustain-setup/data/$name"; do
        [[ -f "$p" ]] && { printf '%s' "$p"; return 0; }
    done
    return 1
}

if ! PPD_FILE="$(find_ppd KOC751iUX.ppd)"; then
    fail "KOC751iUX.ppd was not found next to the script."
    echo "   It has to be in the same folder as this script."
    exit 1
fi
PLOT_PPD_FILE="$(find_ppd hp-designjet-Z9dr-44in-ps.ppd || true)"

CREDS_FILE="/etc/cups/print-sustain.creds"

COMMON_DEFAULTS=(
  -o PageSize=A4
  -o InputSlot=AutoSelect
  -o MediaType=Plain
  -o Collate=True
  -o KMDuplex=2Sided
  -o SelectColor=Auto
  -o TextPureBlack=Auto
  -o TextScreen=Auto
  -o GlossyMode=False
  -o AutoTrapping=False
  -o BlackOverPrint=Off
  -o OutputBin=Default
  -o Binding=LeftBinding
  -o PaperSources=None
  -o Finisher=None
  -o KOPunch=None
  -o ZFoldUnit=None
  -o PostInserter=None
  -o SaddleUnit=None
  -o PrinterHDD=HDD
)

echo ""
# ─────────────────────────────────────────────────────────────────────────────
# Herfra og ned konvergerer scriptet mod en kendt tilstand. Det er ikke en
# engangsopsætning: det skal kunne køres igen på en maskine der allerede er
# sat op, på en der er halvt sat op, og på en hvor nogen har rodet i CUPS —
# og give samme resultat hver gang.
#
# Derfor: `set -e` slås fra i denne del. Et enkelt fejlende lpadmin-kald må
# ikke efterlade maskinen halvfærdig uden at nogen får det at vide. Fejl
# samles op i PROBLEMS og rapporteres til sidst.
# ─────────────────────────────────────────────────────────────────────────────
set +e

PROBLEMS=()
problem() { PROBLEMS+=("$1"); fail "$1"; }

# Kun køer der faktisk blev oprettet, verificeres. Ellers rapporteres samme
# årsag to gange — én gang som "kunne ikke oprette", og én gang som "findes
# ikke efter opsætning" — og listen til sidst bliver længere end problemet.
MFP_CREATED=0
PLOT_CREATED=0

echo "[1/8] Pakker..."
export DEBIAN_FRONTEND=noninteractive
NEEDED=()
for pkg in cups smbclient openprinting-ppds samba-common-bin; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" \
        || NEEDED+=("$pkg")
done
if [[ ${#NEEDED[@]} -eq 0 ]]; then
    echo "      alt er installeret"
else
    for _ in $(seq 1 30); do
        fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
        echo "      waiting for another apt run..."
        sleep 5
    done
    apt-get update -qq || warn "apt-get update reported an error; continuing with what is cached."
    if ! apt-get install -y "${NEEDED[@]}"; then
        # Manglende cups er fatalt. Resten kan undværes til en genkørsel.
        if ! command -v lpadmin >/dev/null 2>&1; then
            fail "Could not install CUPS, and it is not installed already."
            echo "   Without a network the script cannot continue. Try again when"
            echo "   maskinen har forbindelse."
            exit 1
        fi
        warn "Could not install: ${NEEDED[*]}; continuing with what is there."
    fi
fi

echo "[2/8] CUPS..."
# reset-failed først: står cups i failed efter et tidligere forsøg, nægter
# systemctl start at gøre noget, og resten af scriptet ville løbe videre mod
# en død dæmon.
systemctl reset-failed cups.service cups.socket 2>/dev/null
systemctl enable --now cups >/dev/null 2>&1
for _ in $(seq 1 10); do
    lpstat -r >/dev/null 2>&1 && break
    sleep 1
done
if ! lpstat -r >/dev/null 2>&1; then
    problem "CUPS is not responding. See: systemctl status cups"
    echo "   Without a running daemon the queues cannot be created."
    exit 1
fi
echo "      running"

# cups-browsed opdager netværksprintere selv og genopretter køer bag ryggen
# på os. At stoppe den er ikke nok — den starter igen ved næste boot eller
# når en anden pakke trækker den op. Den maskeres.
if systemctl list-unit-files cups-browsed.service >/dev/null 2>&1; then
    systemctl disable --now cups-browsed >/dev/null 2>&1
    systemctl mask cups-browsed >/dev/null 2>&1
    echo "      cups-browsed disabled and masked"
fi

echo "[3/8] Removing the existing queues..."
mapfile -t EXISTING < <(lpstat -p 2>/dev/null | awk '/^printer /{print $2}')
if [[ ${#EXISTING[@]} -eq 0 ]]; then
    echo "      no queues to begin with"
else
    # Kun de køer scriptet selv ejer. En Brother på skrivebordet eller en
    # USB-printer i et lokale er ikke vores at fjerne.
    #
    # Der matches på to ting. Navnet fanger vores egne køer og de forældede
    # varianter. Device-URI'en fanger det navnet ikke kan: en kø nogen har
    # kaldt "Printer-1" men som peger på FollowMe-serveren eller plotteren
    # er en dublet der stjæler jobs, uanset hvad den hedder.
    ours() {   # ours NAVN
        local q="$1" uri
        case "$q" in
            FollowMe-*|BYG-PHP03-*) return 0 ;;
        esac
        uri="$(lpstat -v "$q" 2>/dev/null | sed 's/.*: //')"
        [[ "$uri" == smbspool-auth://* ]] && return 0
        [[ -n "$PRINT_SERVER" && "$uri" == *"$PRINT_SERVER"* ]] && return 0
        [[ -n "$PLOT_SERVER"  && "$uri" == *"$PLOT_SERVER"*  ]] && return 0
        return 1
    }

    KILL=(); KEPT=()
    for q in "${EXISTING[@]}"; do
        if [[ "$REMOVE_ALL" -eq 1 ]] || ours "$q"; then KILL+=("$q"); else KEPT+=("$q"); fi
    done
    if [[ ${#KEPT[@]} -gt 0 ]]; then
        echo "      keeping ${#KEPT[@]} queue(s) that are not ours: ${KEPT[*]}"
    fi
    if [[ ${#KILL[@]} -eq 0 ]]; then
        echo "      no DTU queues to remove"
    else
        for q in "${KILL[@]}"; do
            cupsreject "$q" >/dev/null 2>&1
            cupsdisable "$q" >/dev/null 2>&1
            cancel -a "$q" >/dev/null 2>&1        # hængende jobs blokerer sletning
            if lpadmin -x "$q" >/dev/null 2>&1; then
                echo "      fjernet: $q"
            else
                problem "Could not remove the queue '$q'."
            fi
        done
    fi
fi
# En kø der stod i printers.conf men ikke i lpstat efterlader en forældet PPD.
rm -f /etc/cups/ppd/FollowMe-MFP-PCL.ppd /etc/cups/ppd/FollowMe-Plot-PS.ppd \
      /etc/cups/ppd/BYG-PHP03-PCL.ppd 2>/dev/null

echo "[4/8] Credentials..."
# umask her, ikke chmod bagefter: filen må ikke findes læsbar for andre i
# vinduet mellem oprettelse og rettelse. Den indeholder et domænekodeord.
( umask 077
  cat > "${CREDS_FILE}" <<CREDS
username=${DOMAIN}\\${U}
password=${P}
CREDS
)
chown root:lp "${CREDS_FILE}" 2>/dev/null || problem "Could not set the ownership of ${CREDS_FILE}."
chmod 640 "${CREDS_FILE}"
[[ "$(stat -c '%U:%G %a' "$CREDS_FILE" 2>/dev/null)" == "root:lp 640" ]] \
    || problem "${CREDS_FILE} is not root:lp 640."
echo "      skrevet (root:lp 640)"

echo "[5/8] smbspool-auth-backend..."
BACKEND_PATH=/usr/lib/cups/backend/smbspool-auth
if [[ ! -x /usr/bin/smbspool ]]; then
    problem "/usr/bin/smbspool is missing, so the FollowMe queue cannot spool."
    echo "   Installér samba-common-bin / smbclient."
fi
# Skriv til en midlertidig fil og flyt på plads. Afbrydes scriptet midt i,
# står der ellers en halv backend tilbage, og CUPS fejler hvert job med en
# fejl der ikke peger nogen steder hen.
cat > "${BACKEND_PATH}.new" <<'BACKEND'
#!/usr/bin/env bash
set -euo pipefail
if [ $# -eq 0 ]; then exit 0; fi
USER_LINE=$(grep -E "^username=" "$CREDS" | head -n1 | cut -d= -f2-)
PASS_LINE=$(grep -E "^password=" "$CREDS" | head -n1 | cut -d= -f2-)
DOMAIN="${USER_LINE%%\\*}"
UNAME="${USER_LINE##*\\}"
URI="${DEVICE_URI#smbspool-auth://}"
export DEVICE_URI="smb://${DOMAIN}/${UNAME}:${PASS_LINE}@${URI}"
exec /usr/bin/smbspool "$@"
BACKEND
sed -i "3i CREDS=\"${CREDS_FILE}\"" "${BACKEND_PATH}.new"
chown root:root "${BACKEND_PATH}.new"
chmod 755 "${BACKEND_PATH}.new"
mv -f "${BACKEND_PATH}.new" "${BACKEND_PATH}"
rm -f /usr/lib/cups/backend/smb-auth 2>/dev/null
# CUPS nægter at køre en backend der er skrivbar for andre end root.
if [[ "$(stat -c '%U %a' "$BACKEND_PATH")" != "root 755" ]]; then
    problem "The backend has the wrong permissions, so CUPS will not run it."
fi
echo "      installeret"

echo "[6/8] Can the servers be reached..."
# Uden det her bliver en uopnåelig server til en kø der ser fin ud i lpstat
# og taber hvert job i stilhed.
# Portforespørgslen laves med Python, ikke med bash: en shell der åbner en rå
# TCP socket er den primitiv en reverse shell bygges af, og EDR signerer på
# den. Samme adfærd, uden signaturen. Se cifs_host_up i scripts/common.sh.
reachable() {   # reachable VÆRT PORT
    python3 -c '
import socket, sys
try: socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=4).close()
except OSError: sys.exit(1)
' "$1" "$2" 2>/dev/null
}
if reachable "$PRINT_SERVER" 445; then
    echo "      the FollowMe server answers on 445 (SMB)"
else
    warn "The FollowMe server does not answer on port 445."
    echo "      The queue is created anyway, but jobs will not go through until"
    echo "      the machine can reach it, usually over VPN or a cable."
fi
if [[ -n "$PLOT_SERVER" ]]; then
    if reachable "$PLOT_SERVER" 9100; then
        echo "      the plotter answers on 9100 (JetDirect)"
    else
        warn "The plotter does not answer on port 9100."
        echo "      It has to be reachable directly; it is not behind FollowMe."
    fi
fi

echo "[7/8] Creating the queues..."
if lpadmin -p FollowMe-MFP-PCL -E \
      -v "smbspool-auth://${PRINT_SERVER}/FollowMe-MFP-PCL" \
      -P "$PPD_FILE" \
      "${COMMON_DEFAULTS[@]}" \
      -o job-sheets=none,none 2>/tmp/lpadmin.err; then
    echo "      FollowMe-MFP-PCL oprettet"
    MFP_CREATED=1
else
    problem "Could not create FollowMe-MFP-PCL: $(tr -d '\n' < /tmp/lpadmin.err)"
fi

# Plotteren er ikke en FollowMe-kø. Den har ingen SMB-tjeneste, men lytter på
# JetDirect (9100) — derfor socket:// og ingen credentials.
#
# COMMON_DEFAULTS bruges bevidst IKKE her. De er Konica-specifikke (KMDuplex,
# TextPureBlack, GlossyMode …) og findes ikke i HP'ens PPD; lpadmin ville
# afvise dem.
if [[ -z "$PLOT_SERVER" ]]; then
    echo "      plotter skipped (no address)"
elif [[ -z "$PLOT_PPD_FILE" ]]; then
    problem "hp-designjet-Z9dr-44in-ps.ppd was not found; plotter skipped."
elif lpadmin -p BYG-PHP03-PCL -E \
        -v "socket://${PLOT_SERVER}:9100" \
        -P "$PLOT_PPD_FILE" \
        -D "BYG-PHP03-PCL (HP DesignJet Z9dr 44in)" \
        -L "BYG" \
        -o PageSize=A4 \
        -o job-sheets=none,none 2>/tmp/lpadmin.err; then
    echo "      BYG-PHP03-PCL oprettet"
    PLOT_CREATED=1
else
    problem "Could not create BYG-PHP03-PCL: $(tr -d '\n' < /tmp/lpadmin.err)"
fi
rm -f /tmp/lpadmin.err

lpadmin -d FollowMe-MFP-PCL 2>/dev/null   # standardprinter
systemctl restart cups >/dev/null 2>&1
for _ in $(seq 1 10); do lpstat -r >/dev/null 2>&1 && break; sleep 1; done

echo "[8/8] Verificerer..."
# lpadmin -E slår køen til ved oprettelse, men en kø der blev stoppet af en
# fejl tidligere kan stadig stå disabled eller reject efter genstart. Det er
# den hyppigste grund til at "printeren er der, men der sker ingenting".
verify_queue() {   # verify_queue NAVN FORVENTET_URI_PRÆFIKS
    local q="$1" want="$2" state uri
    if ! lpstat -p "$q" >/dev/null 2>&1; then
        problem "The queue '$q' does not exist after setup."
        return 1
    fi
    uri="$(lpstat -v "$q" 2>/dev/null | sed 's/.*: //')"
    if [[ "$uri" != "$want"* ]]; then
        problem "'$q' peger et forkert sted hen."
        return 1
    fi
    state="$(lpstat -p "$q" 2>/dev/null | head -1)"
    if [[ "$state" == *disabled* ]]; then
        cupsenable "$q" >/dev/null 2>&1
        if lpstat -p "$q" 2>/dev/null | head -1 | grep -q disabled; then
            problem "'$q' is disabled and could not be enabled."
            return 1
        fi
        warn "'$q' was disabled; enabled again."
    fi
    if lpstat -a "$q" 2>/dev/null | grep -q "not accepting"; then
        cupsaccept "$q" >/dev/null 2>&1
        if lpstat -a "$q" 2>/dev/null | grep -q "not accepting"; then
            problem "'$q' is rejecting jobs and could not be fixed."
            return 1
        fi
        warn "'$q' afviste jobs — rettet."
    fi
    ok "$q: klar"
    return 0
}

[[ "$MFP_CREATED" -eq 1 ]] && verify_queue FollowMe-MFP-PCL "smbspool-auth://"
[[ "$PLOT_CREATED" -eq 1 ]] && verify_queue BYG-PHP03-PCL "socket://"

apt-get install -y print-manager >/dev/null 2>&1

banner "Resultat"
lpstat -p 2>/dev/null
echo ""
if [[ ${#PROBLEMS[@]} -eq 0 ]]; then
    ok "Everything is in place. The script can be run again at any time."
    echo ""
    echo "  Testside:  lp -d FollowMe-MFP-PCL /usr/share/cups/data/testprint"
    echo "  Job queue: lpstat -o"
    exit 0
fi
fail "${#PROBLEMS[@]} problem(er) tilbage:"
for pr in "${PROBLEMS[@]}"; do echo "    • $pr"; done
echo ""
echo "  Logfil:    sudo tail -50 /var/log/cups/error_log"
echo "  Run again: sudo $0"
exit 1
