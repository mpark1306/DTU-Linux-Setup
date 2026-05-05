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
        cisco)   CISCO_ENABLED=true ;;
    esac
done < "$SOFTWARE_CONF"

echo "  Flatpak apps: ${FLATPAK_APPS[*]:-none}"
echo "  Snap apps:    ${SNAP_APPS[*]:-none}"
echo "  Cisco VPN:    ${CISCO_ENABLED}"

# Calculate total steps
TOTAL_STEPS=2  # Flatpak setup + Flatpak install
(( ${#SNAP_APPS[@]} > 0 )) && TOTAL_STEPS=$((TOTAL_STEPS + 1))
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
            echo "  → ${app}..."
            if snap list "$app" &>/dev/null 2>&1; then
                echo "    Already installed, skipping."
            else
                snap install "$app" || warn "Failed to install ${app} snap"
            fi
        done
    else
        warn "snapd not available – skipping Snap packages."
    fi
fi

# ─── Step: Cisco Secure Client ──────────────────────────────────────────────
if $CISCO_ENABLED; then
    STEP=$((STEP + 1))
    echo "[${STEP}/${TOTAL_STEPS}] Installing Cisco Secure Client..."

    # Tarball path: prefer env var, then look in repo root
    CISCO_TAR="${DTU_CISCO_TARBALL:-}"
    if [[ -z "$CISCO_TAR" ]]; then
        # Try to find any cisco tarball in the repo root
        for f in "${REPO_ROOT}"/cisco-secure-client-linux64-*.tar.gz; do
            [[ -f "$f" ]] && CISCO_TAR="$f" && break
        done
    fi

    if [[ -z "$CISCO_TAR" || ! -f "$CISCO_TAR" ]]; then
        warn "Cisco tarball not found. Set DTU_CISCO_TARBALL or place .tar.gz in repo root."
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
            [[ -n "$VPN_SCRIPT" ]] && ORDERED_SCRIPTS+=("$VPN_SCRIPT")
            ORDERED_SCRIPTS+=("${OTHER_SCRIPTS[@]}")

            echo "    Modules to install:"
            for s in "${ORDERED_SCRIPTS[@]}"; do echo "      $(basename "$(dirname "$s")")"; done

            CISCO_INSTALLED=0
            CISCO_FAILED=0
            for script in "${ORDERED_SCRIPTS[@]}"; do
                MODULE=$(basename "$(dirname "$script")")
                echo "    --- Installing: ${MODULE} ---"
                set +e
                SCRIPT_OUTPUT=$( cd "$(dirname "$script")" && yes | bash "$(basename "$script")" 2>&1 )
                EXIT_CODE=$?
                set -e
                echo "$SCRIPT_OUTPUT"
                if echo "$SCRIPT_OUTPUT" | grep -qiE "already installed|installed successfully|is installed"; then
                    echo "    [OK] ${MODULE}"
                    ((CISCO_INSTALLED++)) || true
                elif [[ $EXIT_CODE -eq 0 ]]; then
                    echo "    [OK] ${MODULE}"
                    ((CISCO_INSTALLED++)) || true
                else
                    warn "${MODULE} failed"
                    ((CISCO_FAILED++)) || true
                fi
            done

            ok "Cisco Secure Client: ${CISCO_INSTALLED} module(s) installed, ${CISCO_FAILED} failed."
            echo "    Note: NVM (Network Visibility Module) may fail on newer kernels ($(uname -r)). This is a Cisco limitation."
        fi

        rm -rf "$CISCO_EXTRACT"
    fi
fi

ok "Software installation complete."
echo "    Flatpaks: ${FLATPAK_APPS[*]:-none}"
echo "    Snaps: ${SNAP_APPS[*]:-none}"
echo "    Cisco Secure Client: ${CISCO_ENABLED}"
echo "    A reboot may be required for Flatpak apps to appear in the menu."
