#!/usr/bin/env bash
###############################################################################
# DTU Sustain – printeropsætning, frittstående
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
#   -h, --help
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
    sed -n '3,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

ARG_USER=""
ARG_DOMAIN=""
ARG_PRINT_SERVER=""
ARG_PLOT_SERVER=""
PLOT_EXPLICITLY_OFF=0

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
            fail "Der er ikke noget --password-flag."
            echo "   Alt på kommandolinjen kan læses med 'ps' af enhver bruger"
            echo "   på maskinen. Brug DTU_PASSWORD=… eller lad scriptet spørge."
            exit 1 ;;
        -h|--help)      usage 0 ;;
        *)              fail "Ukendt tilvalg: $1"; usage 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    fail "Dette script skal køres som root."
    echo "   sudo $0"
    exit 1
fi

banner "DTU Sustain – printeropsætning"

# ── Serveradresser ───────────────────────────────────────────────────────────

read_var() {   # read_var FIL VARIABEL
    [[ -r "$1" ]] || return 1
    local v
    v="$(sed -n "s/^[[:space:]]*$2=//p" "$1" | head -1 | tr -d '"'"'" | tr -d '\r')"
    [[ -n "$v" && "$v" != *"<"*">"* ]] || return 1
    printf '%s' "$v"
}

find_var() {   # find_var VARIABEL
    local f
    for f in "$SCRIPT_DIR/print.conf" /etc/dtu-setup/site.conf \
             /etc/dtu-setup/dtu-sustain.env; do
        if v="$(read_var "$f" "$1")"; then
            printf '%s' "$v"
            return 0
        fi
    done
    return 1
}

if [[ -n "$ARG_PRINT_SERVER" ]]; then
    PRINT_SERVER="$ARG_PRINT_SERVER"
    echo "  FollowMe-server: $PRINT_SERVER  (--print-server)"
elif PRINT_SERVER="$(find_var SITE_PRINT_SERVER)"; then
    echo "  FollowMe-server: $PRINT_SERVER"
else
    read -rp "  FollowMe-printserverens værtsnavn: " PRINT_SERVER
    [[ -n "$PRINT_SERVER" ]] || { fail "Uden printserver kan FollowMe-køen ikke oprettes."; exit 1; }
fi

if [[ "$PLOT_EXPLICITLY_OFF" -eq 1 ]]; then
    PLOT_SERVER="$ARG_PLOT_SERVER"
    [[ -n "$PLOT_SERVER" ]] && echo "  Plotter:         $PLOT_SERVER  (--plot-server)"
elif PLOT_SERVER="$(find_var SITE_SUSTAIN_PLOT_SERVER)"; then
    echo "  Plotter:         $PLOT_SERVER"
else
    read -rp "  Plotterens værtsnavn (blank = spring plotteren over): " PLOT_SERVER
fi

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
    fail "KOC751iUX.ppd blev ikke fundet ved siden af scriptet."
    echo "   Den skal ligge i samme mappe som dette script."
    exit 1
fi
PLOT_PPD_FILE="$(find_ppd hp-designjet-Z9dr-44in-ps.ppd || true)"

# ── Domænebruger ─────────────────────────────────────────────────────────────
#
# FollowMe-køen spooler som brugeren, så kodeordet skal med. Her er der en
# TTY — modulet i GUI'en kan ikke spørge, og får værdierne som miljøvariabler.
# Rækkefølge: flag, så miljø, så prompt. Samme variabelnavne som modulet i
# DTU Linux Setup, så en env-fil derfra virker uændret.
U="${ARG_USER:-${DTU_USERNAME:-}}"
P="${DTU_PASSWORD:-}"
DOMAIN="${ARG_DOMAIN:-${DTU_AD_NETBIOS:-WIN}}"

if [[ -z "$U" ]]; then
    read -rp "  WIN-brugernavn (fx mpark): " U
fi
[[ -n "$U" ]] || { fail "Brugernavn er påkrævet."; exit 1; }

if [[ -z "$P" ]]; then
    if [[ ! -t 0 ]]; then
        fail "Intet kodeord, og der er ingen terminal at spørge på."
        echo "   Sæt DTU_PASSWORD, eller kør scriptet fra en terminal."
        exit 1
    fi
    read -rsp "  Kodeord for ${DOMAIN}\\${U}: " P
    echo ""
fi
[[ -n "$P" ]] || { fail "Kodeord er påkrævet."; exit 1; }

echo "  Køen spooler som:  ${DOMAIN}\\${U}"

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
echo "[1/7] Installerer pakker..."
export DEBIAN_FRONTEND=noninteractive
for _ in $(seq 1 30); do
    fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || break
    echo "      venter på at en anden apt-kørsel bliver færdig..."
    sleep 5
done
apt-get update -qq || warn "apt-get update meldte fejl (ofte et tredjeparts-repo); fortsætter."
apt-get install -y cups smbclient openprinting-ppds samba-common-bin

echo "[2/7] Slår CUPS til..."
systemctl enable --now cups

echo "[3/7] Slår cups-browsed fra (hvis den findes)..."
systemctl disable --now cups-browsed 2>/dev/null || true

echo "[4/7] Skriver credentials..."
umask 077
cat > "${CREDS_FILE}" <<CREDS
username=${DOMAIN}\\${U}
password=${P}
CREDS
chown root:lp "${CREDS_FILE}"
chmod 640 "${CREDS_FILE}"

echo "[5/7] Installerer smbspool-auth-backend..."
cat > /usr/lib/cups/backend/smbspool-auth <<'BACKEND'
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
sed -i "3i CREDS=\"${CREDS_FILE}\"" /usr/lib/cups/backend/smbspool-auth
chmod 755 /usr/lib/cups/backend/smbspool-auth
rm -f /usr/lib/cups/backend/smb-auth 2>/dev/null || true

echo "[6/7] Fjerner gamle køer..."
lpadmin -x FollowMe-MFP-PCL 2>/dev/null || true
# FollowMe-Plot-PS er afløst af BYG-PHP03-PCL. Den fjernes stadig, så maskiner
# der har været sat op tidligere ikke står med en kø mod en share der ikke
# længere bruges.
lpadmin -x FollowMe-Plot-PS 2>/dev/null || true
lpadmin -x BYG-PHP03-PCL    2>/dev/null || true

echo "[7/7] Opretter køer..."
lpadmin -p FollowMe-MFP-PCL -E \
  -v "smbspool-auth://${PRINT_SERVER}/FollowMe-MFP-PCL" \
  -P "$PPD_FILE" \
  "${COMMON_DEFAULTS[@]}" \
  -o job-sheets=none,none
ok "FollowMe-MFP-PCL oprettet."

# Plotteren er ikke en FollowMe-kø. Den har ingen SMB-tjeneste, men lytter på
# JetDirect (9100) — derfor socket:// og ingen credentials.
#
# COMMON_DEFAULTS bruges bevidst IKKE her. De er Konica-specifikke (KMDuplex,
# TextPureBlack, GlossyMode …) og findes ikke i HP'ens PPD; lpadmin ville
# afvise dem.
if [[ -z "$PLOT_SERVER" ]]; then
    warn "Ingen plotteradresse angivet — BYG-PHP03-PCL springes over."
elif [[ -z "$PLOT_PPD_FILE" ]]; then
    fail "hp-designjet-Z9dr-44in-ps.ppd blev ikke fundet — BYG-PHP03-PCL springes over."
else
    lpadmin -p BYG-PHP03-PCL -E \
      -v "socket://${PLOT_SERVER}:9100" \
      -P "$PLOT_PPD_FILE" \
      -D "BYG-PHP03-PCL (HP DesignJet Z9dr 44in)" \
      -L "BYG" \
      -o PageSize=A4 \
      -o job-sheets=none,none
    ok "BYG-PHP03-PCL oprettet (${PLOT_SERVER}:9100)."
fi

systemctl restart cups

apt-get install -y print-manager 2>/dev/null || true

banner "Færdig"
lpstat -p 2>/dev/null || true
echo ""
echo "Testside:  lp -d FollowMe-MFP-PCL /usr/share/cups/data/testprint"
echo "Status:    lpstat -p"
echo "Jobkø:     lpstat -o"
