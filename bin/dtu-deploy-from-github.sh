#!/usr/bin/env bash
###############################################################################
# DTU Linux Setup – Deploy / update directly from GitHub
#
# Clones (or fast-forwards) the chosen branch of mpark1306/DTU-Linux-Setup
# into /opt/dtu-sustain-setup-src and runs `make install`.
#
# Usage (run as root):
#   sudo bash dtu-deploy-from-github.sh                 # uses default BRANCH
#   sudo BRANCH=main bash dtu-deploy-from-github.sh
#   sudo BRANCH=deploy bash dtu-deploy-from-github.sh
#
# One-liner from a fresh machine:
#   curl -fsSL https://raw.githubusercontent.com/mpark1306/DTU-Linux-Setup/deploy/bin/dtu-deploy-from-github.sh \
#     | sudo BRANCH=deploy bash
###############################################################################
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/mpark1306/DTU-Linux-Setup.git}"
BRANCH="${BRANCH:-deploy}"
SRC_DIR="${SRC_DIR:-/opt/dtu-sustain-setup-src}"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must be run as root (use sudo)." >&2
  exit 1
fi

echo "▶ Repo:   $REPO_URL"
echo "▶ Branch: $BRANCH"
echo "▶ Src:    $SRC_DIR"

# Ensure git + make are present
if ! command -v git >/dev/null 2>&1 || ! command -v make >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq || true
    apt-get install -y git make
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install git make
  else
    echo "ERROR: install git + make manually." >&2
    exit 1
  fi
fi

if [[ -d "$SRC_DIR/.git" ]]; then
  echo "▶ Updating existing checkout..."
  git -C "$SRC_DIR" remote set-url origin "$REPO_URL"
  git -C "$SRC_DIR" fetch --depth=1 origin "$BRANCH"
  git -C "$SRC_DIR" checkout -B "$BRANCH" "origin/$BRANCH"
  git -C "$SRC_DIR" reset --hard "origin/$BRANCH"
else
  echo "▶ Cloning fresh..."
  rm -rf "$SRC_DIR"
  git clone --depth=1 --branch "$BRANCH" "$REPO_URL" "$SRC_DIR"
fi

echo "▶ Removing previous installation (if any)..."
make -C "$SRC_DIR" uninstall || true

echo "▶ Installing..."
make -C "$SRC_DIR" install

echo "✅ DTU Linux Setup installed from branch '$BRANCH'."
echo "   Launch from menu, or run:  dtu-sustain-setup"
