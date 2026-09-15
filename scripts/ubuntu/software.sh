#!/usr/bin/env bash
###############################################################################
# DTU Sustain – Ubuntu 24.04 – Module: Software Installation
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
need_root

banner "Software Installation"

export DEBIAN_FRONTEND=noninteractive
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ─── Read software config ────────────────────────────────────────────────────
SOFTWARE_CONF="${DTU_SOFTWARE_CONF:-${REPO_ROOT}/data/software.conf}"
if [[ ! -f "$SOFTWARE_CONF" ]]; then
    fail "Software config not found: ${SOFTWARE_CONF}"
    exit 1
fi

echo "Reading software list from: ${SOFTWARE_CONF}"

# Parse config file into arrays
FLATPAK_APPS=()
SNAP_APPS=()
PWA_APPS=()
CISCO_MODULES=()
CISCO_ENABLED=false
_section=""
while IFS= read -r line; do
    line="${line%%#*}"        # strip comments
    line="${line#"${line%%[![:space:]]*}"}"  # ltrim
    line="${line%"${line##*[![:space:]]}"}"  # rtrim
    [[ -z "$line" ]] && continue
    if [[ "$line" == "["*"]" ]]; then
        _section="${line:1:${#line}-2}"
        _section="${_section,,}"
        continue
    fi
    case "$_section" in
        flatpak) FLATPAK_APPS+=("$line") ;;
        snap)    SNAP_APPS+=("$line") ;;
        pwa)     PWA_APPS+=("$line") ;;
        cisco)
            CISCO_ENABLED=true
            # Linjer under [cisco] navngiver de moduler der skal installeres.
            # Den gamle vaerdi "cisco-secure-client" betoed "installér alt" og
            # betyder nu "installér standarden", som er vpn alene.
            [[ "$line" == "cisco-secure-client" ]] || CISCO_MODULES+=("${line,,}")
            ;;
    esac
done < "$SOFTWARE_CONF"

echo "  Flatpak apps: ${FLATPAK_APPS[*]:-none}"
echo "  Snap apps:    ${SNAP_APPS[*]:-none}"
echo "  M365 PWAs:    ${PWA_APPS[*]:-none}"
# Kun VPN som standard.
#
# Tarballen indeholder ogsaa posture, nvm, dart og umbrella. Ingen af dem
# bruges paa DTU, og de installeres hver isaer af et interaktivt script vi ikke
# ejer og ikke kan forudsige. posture er det konkrete eksempel: den spoerger om
# en STI, ikke om ja eller nej, saa "y" bliver afvist og spoergsmaalet gentaget.
# Med uendeligt input og en log uden loft skrev den 438 GB paa en kvarter og
# fyldte rodfilsystemet paa en ny maskine.
#
# At installere noget vi ikke bruger er ikke gratis. Det er en risiko uden
# modydelse.
if $CISCO_ENABLED && (( ${#CISCO_MODULES[@]} == 0 )); then
    CISCO_MODULES=(vpn)
fi
echo "  Cisco:        ${CISCO_ENABLED} (moduler: ${CISCO_MODULES[*]:-ingen})"

# Calculate total steps
TOTAL_STEPS=2  # Flatpak setup + Flatpak install
(( ${#SNAP_APPS[@]} > 0 )) && TOTAL_STEPS=$((TOTAL_STEPS + 1))
# The PWA step also removes the snap it replaced, so it runs even when the
# section is empty — otherwise a machine imaged before the change would keep
# office365webdesktop forever.
TOTAL_STEPS=$((TOTAL_STEPS + 1))
$CISCO_ENABLED && TOTAL_STEPS=$((TOTAL_STEPS + 1))
STEP=0

# ─── Step: Flatpak setup ────────────────────────────────────────────────────
STEP=$((STEP + 1))
echo "[${STEP}/${TOTAL_STEPS}] Setting up Flatpak + Flathub..."
apt_wait
apt-get update -y || warn "apt-get update reported errors (likely a broken third-party repository); continuing."
apt-get install -y flatpak xdg-desktop-portal xdg-desktop-portal-gtk

# Add Flathub if not already present
if ! flatpak remote-list --columns=name 2>/dev/null | grep -qw flathub; then
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    echo "    Flathub remote added."
else
    echo "    Flathub remote already configured."
fi

# ─── Step: Install Flatpak apps ─────────────────────────────────────────────
STEP=$((STEP + 1))
echo "[${STEP}/${TOTAL_STEPS}] Installing Flatpak applications..."
if (( ${#FLATPAK_APPS[@]} > 0 )); then
    for app in "${FLATPAK_APPS[@]}"; do
        echo "  → ${app}..."
        if flatpak info "$app" &>/dev/null; then
            echo "    Already installed, skipping."
        else
            flatpak install -y --noninteractive flathub "$app" || warn "Failed to install ${app}"
        fi
    done
else
    echo "    No Flatpak apps configured."
fi

# ─── Step: Snap packages ────────────────────────────────────────────────────
if (( ${#SNAP_APPS[@]} > 0 )); then
    STEP=$((STEP + 1))
    echo "[${STEP}/${TOTAL_STEPS}] Installing Snap packages..."
    if ! command -v snap &>/dev/null; then
        echo "    snapd not present – installing..."
        apt_wait
        apt-get install -y snapd || warn "Failed to install snapd"
        systemctl enable --now snapd.socket 2>/dev/null || true
        systemctl enable --now snapd 2>/dev/null || true
        # snapd needs a moment after first start before `snap` works
        sleep 5
    fi
    if command -v snap &>/dev/null; then
        for app in "${SNAP_APPS[@]}"; do
            snap_name="${app%% *}"           # first word = package name
            snap_args="${app#"$snap_name"}"  # remainder = optional flags
            snap_args="${snap_args# }"        # strip leading space
            echo "  → ${snap_name}..."
            if snap list "$snap_name" &>/dev/null 2>&1; then
                echo "    Already installed, skipping."
            else
                # shellcheck disable=SC2086
                snap install "$snap_name" $snap_args || warn "Failed to install ${snap_name} snap"
            fi
        done
    else
        warn "snapd not available – skipping Snap packages."
    fi
fi

# ─── Step: Microsoft 365 PWA shortcuts ──────────────────────────────────────
#
# Replaces the office365webdesktop snap. That snap was a packaged browser
# shipped from a beta channel, running alongside the browser the machine
# already has. install-ms-pwa.sh writes ordinary .desktop files that open the
# same Microsoft 365 apps in Ungoogled Chromium — the flatpak installed above.
STEP=$((STEP + 1))
echo "[${STEP}/${TOTAL_STEPS}] Microsoft 365 web apps..."

# The snap this replaces. Removed by name, and only if it is actually there:
# an upgraded machine must not keep both.
OBSOLETE_SNAPS=(office365webdesktop)
if command -v snap &>/dev/null; then
    for obsolete in "${OBSOLETE_SNAPS[@]}"; do
        if snap list "$obsolete" &>/dev/null 2>&1; then
            echo "  → removing obsolete snap: ${obsolete}"
            snap remove --purge "$obsolete" || warn "Could not remove ${obsolete} snap"
        fi
    done
fi

if (( ${#PWA_APPS[@]} > 0 )); then
    PWA_SCRIPT="${REPO_ROOT}/scripts/install-ms-pwa.sh"
    if [[ ! -f "$PWA_SCRIPT" ]]; then
        warn "install-ms-pwa.sh not found at ${PWA_SCRIPT} — skipping M365 shortcuts."
    else
        # --system: the shortcuts go in /usr/share/applications for every user.
        # Without it the script installs into $HOME, and this module runs as
        # root, so they would land in root's home and nobody would see them.
        if [[ -n "${DTU_MS_TENANT:-}" ]]; then
            export MS_TENANT="$DTU_MS_TENANT"
        fi
        echo "  → ${PWA_APPS[*]}"
        if bash "$PWA_SCRIPT" --system "${PWA_APPS[@]}"; then
            ok "Microsoft 365 shortcuts installed for all users."
        else
            warn "install-ms-pwa.sh failed — the M365 shortcuts may be missing."
        fi
    fi
else
    echo "    No M365 web apps configured."
fi

_cisco_wanted() {
    local modul="${1,,}" oensket
    for oensket in "${CISCO_MODULES[@]}"; do
        [[ "$modul" == "$oensket" ]] && return 0
    done
    return 1
}

# Vagthund paa logfilen. Den skal vaere her, selvom input nu er bundet: en
# installatoer kan ogsaa loope uden at laese fra stdin, og saa er der intet
# der stopper den foer tidsgraensen. 900 sekunder med fri skriveadgang paa en
# NVMe er hundredvis af gigabyte.
_cisco_log_watchdog() {
    local fil="$1" maks="$2" pid="$3"
    while kill -0 "$pid" 2>/dev/null; do
        if [[ -f "$fil" ]] && (( $(stat -c %s "$fil" 2>/dev/null || echo 0) > maks )); then
            kill -TERM "$pid" 2>/dev/null
            sleep 2
            kill -KILL "$pid" 2>/dev/null
            return 0
        fi
        # Overskridelsen er skrivehastighed gange interval. Ét sekund paa en
        # NVMe er i vaerste fald nogle hundrede megabyte, og filen ryddes
        # bagefter. Det er forskellen paa en bule og en fuld disk.
        sleep 1
    done
    return 1
}

# ─── Step: Cisco Secure Client ──────────────────────────────────────────────
if $CISCO_ENABLED; then
    STEP=$((STEP + 1))
    echo "[${STEP}/${TOTAL_STEPS}] Installing Cisco Secure Client..."

    # Tarball path: prefer env var, then look in repo root
    CISCO_TAR="${DTU_CISCO_TARBALL:-}"
    if [[ -z "$CISCO_TAR" ]]; then
        # Search the places the tarball can legitimately live, in order.
        #
        # /etc/dtu-setup is first because that is where the DTU image ships it:
        # baked into the ISO so the Software module needs no file picker on a
        # freshly imaged machine. The repo root comes next for developers
        # running from a checkout.
        for d in /etc/dtu-setup /opt/dtu-sustain-setup "${REPO_ROOT}"; do
            for f in "$d"/cisco-secure-client-linux64-*.tar.gz; do
                [[ -f "$f" ]] && CISCO_TAR="$f" && break 2
            done
        done
    fi

    if [[ -z "$CISCO_TAR" || ! -f "$CISCO_TAR" ]]; then
        warn "Cisco tarball not found. Set DTU_CISCO_TARBALL, or place the .tar.gz in /etc/dtu-setup/ (where the DTU image ships it) or the repo root."
    else
        echo "    Using tarball: ${CISCO_TAR}"

        # Install dependencies
        echo "    Installing dependencies..."
        export LD_LIBRARY_PATH="/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
        apt-get install -y libxml2 "linux-headers-$(uname -r)" gcc make 2>/dev/null || true

        if [[ -f /usr/lib/x86_64-linux-gnu/libxml2.so.2 || -L /usr/lib/x86_64-linux-gnu/libxml2.so.2 ]]; then
            echo "    [OK] libxml2.so.2 found"
        else
            warn "libxml2.so.2 not found – VPN may fail"
        fi

        # Extract tarball
        CISCO_EXTRACT="$(mktemp -d)"
        echo "    Extracting tarball..."
        tar -xzf "$CISCO_TAR" -C "$CISCO_EXTRACT" --strip-components=1

        # Find all install scripts (excluding uninstall)
        mapfile -t ALL_SCRIPTS < <(find "$CISCO_EXTRACT" -name "*_install.sh" ! -name "*uninstall*" | sort)

        if (( ${#ALL_SCRIPTS[@]} == 0 )); then
            warn "No install scripts found in tarball."
        else
            # Run VPN module first, then the rest
            VPN_SCRIPT=""
            OTHER_SCRIPTS=()
            for s in "${ALL_SCRIPTS[@]}"; do
                if [[ "$s" == */vpn/vpn_install.sh ]]; then
                    VPN_SCRIPT="$s"
                else
                    OTHER_SCRIPTS+=("$s")
                fi
            done

            ORDERED_SCRIPTS=()
            SKIPPED_MODULES=()
            if [[ -n "$VPN_SCRIPT" ]] && _cisco_wanted vpn; then
                ORDERED_SCRIPTS+=("$VPN_SCRIPT")
            fi
            for s in "${OTHER_SCRIPTS[@]}"; do
                _m="$(basename "$(dirname "$s")")"
                if _cisco_wanted "$_m"; then
                    ORDERED_SCRIPTS+=("$s")
                else
                    SKIPPED_MODULES+=("$_m")
                fi
            done

            if (( ${#SKIPPED_MODULES[@]} > 0 )); then
                echo "    Skipping (not requested): ${SKIPPED_MODULES[*]}"
            fi
            if (( ${#ORDERED_SCRIPTS[@]} == 0 )); then
                warn "None of the requested modules (${CISCO_MODULES[*]}) are in this tarball."
            fi

            echo "    Modules to install:"
            for s in "${ORDERED_SCRIPTS[@]}"; do echo "      $(basename "$(dirname "$s")")"; done

            CISCO_INSTALLED=0
            CISCO_FAILED=0
            CISCO_TIMED_OUT=0

            # Each module gets its own log file, and the installer writes
            # into that file rather than into a pipe we read.
            #
            # This is not a style preference. The old code ran the installer
            # inside $( ), which waits for end-of-file on the installer's
            # stdout — NOT for the installer to exit. Cisco's installers
            # leave processes behind that inherited that stdout, so the pipe
            # never reached EOF and the module hung forever *after* a
            # successful install. The GUI showed nothing, because all output
            # was being captured for a variable that never got assigned.
            #
            # A file has no such property: the write end being held open by
            # some leftover process costs nothing, and the redirect returns
            # as soon as the installer itself exits.
            CISCO_TIMEOUT="${DTU_CISCO_MODULE_TIMEOUT:-900}"

            # Loft paa den enkelte logfil. Rigelig plads til en normal
            # installation, og langt under hvad der kan goere skade.
            CISCO_MAX_LOG="${DTU_CISCO_MAX_LOG:-52428800}"   # 50 MB

            # Somewhere that outlives the extraction directory, which is
            # deleted below. A log the failure message points at has to still
            # be there when someone goes looking for it.
            CISCO_LOG_DIR=/var/log/dtu-setup
            mkdir -p "$CISCO_LOG_DIR"
            chmod 750 "$CISCO_LOG_DIR"
            # Logge fra tidligere koersler har ingen vaerdi naar vi er i gang
            # med en ny, og de er det eneste i mappen der kan vokse.
            find "$CISCO_LOG_DIR" -maxdepth 1 -name 'cisco-*.log' -mtime +30 -delete 2>/dev/null || true

            for script in "${ORDERED_SCRIPTS[@]}"; do
                MODULE=$(basename "$(dirname "$script")")
                MODULE_LOG="${CISCO_LOG_DIR}/cisco-${MODULE}.log"
                echo "    --- Installing: ${MODULE} ---"
                echo "        (no output until this module finishes; up to ${CISCO_TIMEOUT}s)"

                # Input er bundet. "yes" alene svarer i det uendelige, og en
                # installatoer der ikke kan bruge svaret spoerger bare igen.
                # 50 linjer raekker rigeligt til en EULA-prompt; derefter faar
                # den EOF og maa give op i stedet for at loope.
                #
                # Stadig en FIL og ikke et roer: $( ) venter paa end-of-file
                # paa installatoerens stdout, ikke paa at den afslutter, og
                # Cisco efterlader processer der arver den stdout. Det hang
                # modulet for evigt efter en ellers vellykket installation.
                # En omdirigering til fil har ikke den egenskab.
                rm -f "$MODULE_LOG"
                set +e
                ( cd "$(dirname "$script")" \
                  && exec timeout "$CISCO_TIMEOUT" bash "$(basename "$script")" ) \
                    < <(yes | head -n 50) > "$MODULE_LOG" 2>&1 &
                INSTALLER_PID=$!
                _cisco_log_watchdog "$MODULE_LOG" "$CISCO_MAX_LOG" "$INSTALLER_PID" &
                WATCHDOG_PID=$!
                wait "$INSTALLER_PID"
                EXIT_CODE=$?
                kill "$WATCHDOG_PID" 2>/dev/null
                wait "$WATCHDOG_PID" 2>/dev/null
                set -e

                LOG_SIZE=$(stat -c %s "$MODULE_LOG" 2>/dev/null || echo 0)
                CISCO_LOG_CAPPED=0
                if (( LOG_SIZE > CISCO_MAX_LOG )); then
                    CISCO_LOG_CAPPED=1
                    warn "${MODULE} skrev over $((CISCO_MAX_LOG / 1024 / 1024)) MB log og blev stoppet."
                    echo "        Den spurgte formentlig om noget den ikke fik brugbart svar paa."
                    : > "$MODULE_LOG"
                    echo "        (loggen er ryddet; den ville ellers fylde disken)" >> "$MODULE_LOG"
                fi

                # Kun halen laeses. Hele filen i en variabel var den anden
                # ubundne laesning i den her loekke.
                SCRIPT_OUTPUT="$(tail -c 20000 "$MODULE_LOG" 2>/dev/null || true)"
                echo "$SCRIPT_OUTPUT"

                if (( CISCO_LOG_CAPPED )); then
                    ((CISCO_FAILED++)) || true
                elif [[ $EXIT_CODE -eq 124 ]]; then
                    # timeout(1) reports 124 when it had to kill the child.
                    warn "${MODULE} timed out after ${CISCO_TIMEOUT}s and was killed."
                    echo "        The installer did not exit on its own. Its log:"
                    echo "          ${MODULE_LOG}"
                    echo "        Raise the limit with DTU_CISCO_MODULE_TIMEOUT=<seconds> if"
                    echo "        this machine is simply slow."
                    ((CISCO_TIMED_OUT++)) || true
                    ((CISCO_FAILED++)) || true
                elif [[ $EXIT_CODE -eq 0 ]]; then
                    echo "    [OK] ${MODULE}"
                    ((CISCO_INSTALLED++)) || true
                elif echo "$SCRIPT_OUTPUT" | grep -qiE "already installed|installed successfully|is installed"; then
                    # Non-zero exit, but the installer says it did the work.
                    # Checked after the exit code, not before it: the other
                    # order let a timed-out module whose log happened to
                    # contain "is installed" be reported as a success.
                    echo "    [OK] ${MODULE} (exit ${EXIT_CODE}, but reports success)"
                    ((CISCO_INSTALLED++)) || true
                else
                    warn "${MODULE} failed (exit ${EXIT_CODE})"
                    ((CISCO_FAILED++)) || true
                fi
            done

            ok "Cisco Secure Client: ${CISCO_INSTALLED} module(s) installed, ${CISCO_FAILED} failed."
            echo "    Per-module logs: ${CISCO_LOG_DIR}/cisco-*.log"
            if (( CISCO_TIMED_OUT > 0 )); then
                warn "${CISCO_TIMED_OUT} module(s) had to be killed on timeout."
            fi
            echo "    Note: NVM (Network Visibility Module) may fail on newer kernels ($(uname -r)). This is a Cisco limitation."
        fi

        rm -rf "$CISCO_EXTRACT"
    fi
fi

ok "Software installation complete."
echo "    Flatpaks: ${FLATPAK_APPS[*]:-none}"
echo "    Snaps: ${SNAP_APPS[*]:-none}"
echo "    M365 PWAs: ${PWA_APPS[*]:-none}"
echo "    Cisco Secure Client: ${CISCO_ENABLED}"
echo "    A reboot may be required for Flatpak apps to appear in the menu."
