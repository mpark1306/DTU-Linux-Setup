#!/usr/bin/env bash
###############################################################################
# DTU Linux Setup – Update to latest release from GitHub
#
# Downloads the latest main-branch tarball from GitHub, removes the current
# installation, and reinstalls the new version.
###############################################################################
set -euo pipefail

REPO="mpark1306/DTU-Linux-Setup"
BRANCH="${BRANCH:-main}"
ARCHIVE_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"
TMP_DIR="$(mktemp -d /tmp/dtu-update-XXXXXXXX)"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (use sudo/pkexec)." >&2
  exit 1
fi

echo "▶ DTU Linux Setup – Update"
echo "▶ Repository : https://github.com/${REPO}"
echo "▶ Branch     : ${BRANCH}"
echo "▶ Archive    : ${ARCHIVE_URL}"
echo ""

for cmd in tar make; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "▶ Installing missing tool: ${cmd}..."
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -qq
      apt-get install -y "$cmd"
    elif command -v zypper >/dev/null 2>&1; then
      zypper --non-interactive install "$cmd"
    else
      echo "ERROR: '${cmd}' not found and cannot be auto-installed." >&2
      exit 1
    fi
  fi
done

echo "▶ Downloading latest release source..."
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$ARCHIVE_URL" | tar -xz -C "$TMP_DIR" --strip-components=1
elif command -v wget >/dev/null 2>&1; then
  wget -qO- "$ARCHIVE_URL" | tar -xz -C "$TMP_DIR" --strip-components=1
else
  echo "ERROR: Neither curl nor wget found." >&2
  exit 1
fi

echo "▶ Removing previous installation (if any)..."
make -C "$TMP_DIR" uninstall 2>/dev/null || true

echo "▶ Installing latest version..."
make -C "$TMP_DIR" install

echo ""
echo "✅ DTU Linux Setup updated from branch '${BRANCH}'."
echo "   Restart the app if it is still open."