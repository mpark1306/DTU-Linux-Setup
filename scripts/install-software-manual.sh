#!/usr/bin/env bash
###############################################################################
# DTU Sustain – Manual Software Installation (no GUI)
# Run with: sudo bash install-software-manual.sh
###############################################################################
set -euo pipefail

# ─── Colours / helpers ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

banner()  { echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}\n"; }
ok()      { echo -e "${GREEN}✅ $1${NC}"; }
warn()    { echo -e "${YELLOW}⚠️  $1${NC}"; }
fail()    { echo -e "${RED}❌ $1${NC}"; }

if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as root (use sudo)."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Detect distro ──────────────────────────────────────────────────────────
DISTRO="unknown"
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    case "${ID,,}" in
        ubuntu)                DISTRO="ubuntu" ;;
        opensuse-tumbleweed)   DISTRO="opensuse" ;;
        *)
            case "${ID_LIKE,,}" in
                *ubuntu*) DISTRO="ubuntu" ;;
                *suse*)   DISTRO="opensuse" ;;
            esac
            ;;
    esac
fi

banner "DTU Manual Software Installation (${DISTRO})"

if [[ "$DISTRO" == "unknown" ]]; then
    fail "Unsupported distribution. Only Ubuntu and openSUSE Tumbleweed are supported."
    exit 1
fi

# ─── Package manager helpers ────────────────────────────────────────────────
apt_wait() {
    local max_wait=120 waited=0
    while fuser /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock &>/dev/null 2>&1; do
        if (( waited == 0 )); then warn "Waiting for apt/dpkg lock..."; fi
        sleep 2; waited=$((waited + 2))
        if (( waited >= max_wait )); then fail "Timed out waiting for apt lock"; return 1; fi
    done
}

pkg_install() {
    if [[ "$DISTRO" == "ubuntu" ]]; then
        apt_wait
        DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
    else
        zypper --non-interactive install -y "$@" 2>/dev/null || true
    fi
}

# ─── Software list (embedded) ────────────────────────────────────────────────
FLATPAK_APPS=(
    com.microsoft.Edge
    com.github.tchx84.Flatseal
    org.flameshot.Flameshot
    org.onlyoffice.desktopeditors
    com.github.IsmaelMartinez.teams_for_linux
    org.remmina.Remmina
    us.zoom.Zoom
    com.usebottles.bottles
    io.github.alescdb.mailviewer
)
SNAP_APPS=(
    office365webdesktop
)
CISCO_ENABLED=true

echo "  Flatpak apps: ${FLATPAK_APPS[*]:-none}"
echo "  Snap apps:    ${SNAP_APPS[*]:-none}"
echo "  Cisco VPN:    ${CISCO_ENABLED}"
echo ""

# ─── Calculate steps ────────────────────────────────────────────────────────
TOTAL_STEPS=2
(( ${#SNAP_APPS[@]} > 0 )) && TOTAL_STEPS=$((TOTAL_STEPS + 1))
$CISCO_ENABLED && TOTAL_STEPS=$((TOTAL_STEPS + 1))
STEP=0

# ─── Step: Flatpak setup ────────────────────────────────────────────────────
STEP=$((STEP + 1))
echo "[${STEP}/${TOTAL_STEPS}] Setting up Flatpak + Flathub..."

if [[ "$DISTRO" == "ubuntu" ]]; then
    apt_wait
    apt-get update -y
    apt-get install -y flatpak xdg-desktop-portal xdg-desktop-portal-gtk
else
    zypper --non-interactive install -y flatpak 2>/dev/null || true
fi

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

    if [[ "$DISTRO" == "opensuse" ]] && ! command -v snap &>/dev/null; then
        echo "    Installing snapd..."
        zypper --non-interactive install -y snapd || true
        systemctl enable --now snapd 2>/dev/null || true
        systemctl enable --now snapd.apparmor 2>/dev/null || true
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

    CISCO_TAR="${DTU_CISCO_TARBALL:-}"
    if [[ -z "$CISCO_TAR" ]]; then
        for f in "${SCRIPT_DIR}"/cisco-secure-client-linux64-*.tar.gz \
                 "${SCRIPT_DIR}"/../cisco-secure-client-linux64-*.tar.gz \
                 /tmp/cisco-secure-client-linux64-*.tar.gz; do
            [[ -f "$f" ]] && CISCO_TAR="$f" && break
        done
    fi

    if [[ -z "$CISCO_TAR" || ! -f "$CISCO_TAR" ]]; then
        warn "Cisco tarball not found. Place cisco-secure-client-linux64-*.tar.gz next to this script, in /tmp, or set DTU_CISCO_TARBALL."
    else
        echo "    Using tarball: ${CISCO_TAR}"

        echo "    Installing dependencies..."
        if [[ "$DISTRO" == "ubuntu" ]]; then
            export LD_LIBRARY_PATH="/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
            pkg_install libxml2 "linux-headers-$(uname -r)" gcc make 2>/dev/null || true
        else
            pkg_install libxml2-2 kernel-devel gcc make 2>/dev/null || true
        fi

        CISCO_EXTRACT="$(mktemp -d)"
        echo "    Extracting tarball..."
        tar -xzf "$CISCO_TAR" -C "$CISCO_EXTRACT" --strip-components=1

        mapfile -t ALL_SCRIPTS < <(find "$CISCO_EXTRACT" -name "*_install.sh" ! -name "*uninstall*" | sort)

        if (( ${#ALL_SCRIPTS[@]} == 0 )); then
            warn "No install scripts found in tarball."
        else
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
                SCRIPT_OUTPUT=$( cd "$(dirname "$script")" && yes | bash "$(basename "$script")" 2>&1 ) || true
                EXIT_CODE=$?
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
            echo "    Note: NVM (Network Visibility Module) may fail on newer kernels ($(uname -r))."
        fi

        rm -rf "$CISCO_EXTRACT"
    fi
fi

echo ""
ok "Software installation complete."
echo "    Flatpaks: ${FLATPAK_APPS[*]:-none}"
echo "    Snaps: ${SNAP_APPS[*]:-none}"
echo "    Cisco Secure Client: ${CISCO_ENABLED}"

# ─── Step: Deploy sync-homedir ──────────────────────────────────────────────
STEP=$((STEP + 1))
echo ""
echo "[${STEP}/${TOTAL_STEPS}] Deploying sync-homedir..."

SYNC_SCRIPT="/usr/local/bin/sync-homedir.sh"
SKEL_DIR="/etc/skel/.config/systemd/user"
SKEL_SERVICE="${SKEL_DIR}/sync-homedir.service"
SKEL_TIMER="${SKEL_DIR}/sync-homedir.timer"
PROFILE_SCRIPT="/etc/profile.d/sync-homedir-login.sh"

# Back up existing files
SYNC_BACKUP_DIR=$(mktemp -d /tmp/sync-homedir-backup-XXXXXXXX)
echo "    Backup directory: $SYNC_BACKUP_DIR"
for f in "$SYNC_SCRIPT" "$SKEL_SERVICE" "$SKEL_TIMER" "$PROFILE_SCRIPT"; do
    if [[ -f "$f" ]]; then
        rel="${f#/}"
        mkdir -p "$SYNC_BACKUP_DIR/$(dirname "$rel")"
        cp -p "$f" "$SYNC_BACKUP_DIR/$rel"
        echo "    ↳ backed up $f"
    fi
done

# Dependencies
echo "    Ensuring rsync is installed..."
pkg_install rsync > /dev/null 2>&1

# Sync script
echo "    Deploying $SYNC_SCRIPT..."
cat > "$SYNC_SCRIPT" << 'SYNCEOF'
#!/usr/bin/env bash
# sync-homedir.sh — rsync selected home dirs → Q-drev
set -euo pipefail

MOUNT_POINT="/mnt/Qdrev"
REMOTE_BASE="$MOUNT_POINT/Personal/$USER"
LOG="$HOME/.local/share/sync-homedir.log"
DIRS=("Desktop" "Documents" "Pictures")

mkdir -p "$(dirname "$LOG")"

if ! mountpoint -q "$MOUNT_POINT"; then
  echo "$(date '+%F %T') Drev ikke tilgængeligt, springer over." >> "$LOG"
  exit 0
fi

for DIR in "${DIRS[@]}"; do
  mkdir -p "$REMOTE_BASE/$DIR"
done

for DIR in "${DIRS[@]}"; do
  rsync -av --update \
    "$HOME/$DIR/" \
    "$REMOTE_BASE/$DIR/" \
    >> "$LOG" 2>&1
done

echo "$(date '+%F %T') Sync gennemført for $USER." >> "$LOG"
SYNCEOF
chmod 0755 "$SYNC_SCRIPT"

# Skeleton for new users
echo "    Creating skel systemd user directory..."
mkdir -p "$SKEL_DIR"
chmod 0755 "$SKEL_DIR"

echo "    Deploying service to skel..."
cat > "$SKEL_SERVICE" << 'SVCEOF'
[Unit]
Description=Sync home directory
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/sync-homedir.sh

[Install]
WantedBy=default.target
SVCEOF
chmod 0644 "$SKEL_SERVICE"

echo "    Deploying timer to skel..."
cat > "$SKEL_TIMER" << 'TMREOF'
[Unit]
Description=Periodic home directory sync

[Timer]
OnBootSec=2min
OnUnitActiveSec=30s
Persistent=true

[Install]
WantedBy=timers.target
TMREOF
chmod 0644 "$SKEL_TIMER"

# Login trigger
echo "    Deploying profile.d login script..."
cat > "$PROFILE_SCRIPT" << 'PROFEOF'
#!/usr/bin/env bash
# sync-homedir-login.sh — trigger sync + enable timer on first login
if [ -n "$USER" ] && [ "$USER" != "root" ]; then
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable --now sync-homedir.timer 2>/dev/null || true
  systemctl --user start sync-homedir.service 2>/dev/null || true
fi
PROFEOF
chmod 0755 "$PROFILE_SCRIPT"

ok "sync-homedir deployed. Backup at: $SYNC_BACKUP_DIR"
echo "    To undo sync-homedir only:"
echo "      sudo bash -c 'for f in $SYNC_SCRIPT $SKEL_SERVICE $SKEL_TIMER $PROFILE_SCRIPT; do rm -f \"\$f\"; done'"

echo ""
echo "    A reboot may be required for Flatpak apps to appear in the menu."
