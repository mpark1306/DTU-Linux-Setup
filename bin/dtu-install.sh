#!/usr/bin/env bash
###############################################################################
# DTU Linux Setup – Curl installer (no git, no GitHub account required)
#
# Downloads the latest version directly from GitHub as a tarball and
# installs it via make install. Works on any public network.
#
# ── Quick install (latest main branch) ───────────────────────────────────────
#
#   Ubuntu / openSUSE:
#     curl -fsSL https://raw.githubusercontent.com/mpark1306/DTU-Linux-Setup/main/bin/dtu-install.sh | sudo bash
#
# ── Update existing installation ─────────────────────────────────────────────
#
#   Same command — the script removes the old installation before reinstalling.
#
# ── Optional env vars ────────────────────────────────────────────────────────
#
#   BRANCH=main          Which branch to install from (default: main)
#
#   Example:
#     curl -fsSL ... | sudo BRANCH=main bash
#
###############################################################################
set -euo pipefail

REPO="mpark1306/DTU-Linux-Setup"
BRANCH="${BRANCH:-main}"
ARCHIVE_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"
TMP_DIR="$(mktemp -d /tmp/dtu-install-XXXXXXXX)"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root." >&2
    echo "       Prefix with sudo, e.g.:" >&2
    echo "       curl -fsSL <url> | sudo bash" >&2
    exit 1
fi

echo "▶ DTU Linux Setup – Installer"
echo "▶ Repository : https://github.com/${REPO}"
echo "▶ Branch     : ${BRANCH}"
echo "▶ Archive    : ${ARCHIVE_URL}"
echo ""

# ── Ensure required build tools ───────────────────────────────────────────────
for cmd in tar make; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "▶ Installing missing tool: ${cmd}..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get install -y "$cmd"
        elif command -v zypper >/dev/null 2>&1; then
            zypper --non-interactive install "$cmd"
        else
            echo "ERROR: '${cmd}' not found and cannot be auto-installed." >&2
            echo "       Install it manually and re-run." >&2
            exit 1
        fi
    fi
done

# ── Download and extract ──────────────────────────────────────────────────────
echo "▶ Downloading branch '${BRANCH}'..."
if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$ARCHIVE_URL" | tar -xz -C "$TMP_DIR" --strip-components=1
elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$ARCHIVE_URL" | tar -xz -C "$TMP_DIR" --strip-components=1
else
    echo "ERROR: Neither curl nor wget found." >&2
    echo "       Install curl first:" >&2
    echo "         Ubuntu  : sudo apt-get install curl" >&2
    echo "         openSUSE: sudo zypper install curl" >&2
    exit 1
fi

# ── Remove previous installation ──────────────────────────────────────────────
echo "▶ Removing previous installation (if any)..."
make -C "$TMP_DIR" uninstall 2>/dev/null || true

# ── Install ───────────────────────────────────────────────────────────────────
echo "▶ Installing..."
make -C "$TMP_DIR" install

echo ""
echo "✅ DTU Linux Setup installed from branch '${BRANCH}'."
echo ""
echo "   Launch:  dtu-sustain-setup"
echo "   Menu:    'DTU Linux Setup' under Settings / Indstillinger"
echo ""
echo "   Next step: place /etc/dtu-setup/site.conf and set department:"
echo "     sudo install -m 0644 <profile>.env /etc/dtu-setup/site.conf"
echo "     echo sustain | sudo tee /etc/dtu-setup/department"
echo "     # or: echo ait | sudo tee /etc/dtu-setup/department"
