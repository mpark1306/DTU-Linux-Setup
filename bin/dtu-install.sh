#!/usr/bin/env bash
###############################################################################
# DTU Linux Setup – Curl installer (no git, no GitHub account required)
#
# Downloads the latest version directly from GitHub as a tarball and
# installs it via make install. Works on any public network.
#
# ── Quick install (latest release) ───────────────────────────────────────────
#
#     curl -fsSL https://raw.githubusercontent.com/mpark1306/DTU-Linux-Setup/main/bin/dtu-install.sh | sudo bash
#
# ── Update existing installation ─────────────────────────────────────────────
#
#   Same command — the script removes the old installation before reinstalling.
#
# ── Optional env vars ────────────────────────────────────────────────────────
#
#   VERSION=latest       Newest published release (default)
#   VERSION=v1.4.0       Pin to one release, e.g. to reproduce an image
#   BRANCH=main          Install a branch head instead — for testing unreleased
#                        work. Takes precedence over VERSION.
#
#   Example:
#     curl -fsSL ... | sudo VERSION=v1.4.0 bash
#     curl -fsSL ... | sudo BRANCH=main bash
#
# The default is a release, not a branch: a branch head is whatever was pushed
# last, has not necessarily passed CI, and cannot be named afterwards. An image
# built from "main" can never be traced back to the code it contains.
#
###############################################################################
set -euo pipefail

REPO="mpark1306/DTU-Linux-Setup"
BRANCH="${BRANCH:-}"
VERSION="${VERSION:-latest}"
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

# ── Resolve what to install ───────────────────────────────────────────────────
#
# Resolution happens before anything is downloaded so the chosen ref can be
# printed, and so a typo in VERSION fails here rather than as a confusing
# tar error.
resolve_latest_release() {
    # The API redirects /releases/latest to the newest published release. Read
    # the tag out of the JSON without requiring jq, which is not installed on a
    # stock Ubuntu image.
    local json tag
    if command -v curl >/dev/null 2>&1; then
        json="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null || true)"
    else
        json="$(wget -qO- "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null || true)"
    fi
    tag="$(printf '%s' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
    printf '%s' "$tag"
}

if [[ -n "$BRANCH" ]]; then
    SOURCE_DESC="branch '${BRANCH}'"
    INSTALLED_REF="$BRANCH"
    ARCHIVE_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"
else
    if [[ "$VERSION" == "latest" ]]; then
        echo "▶ Looking up latest release..."
        RESOLVED_TAG="$(resolve_latest_release)"
        if [[ -z "$RESOLVED_TAG" ]]; then
            echo "ERROR: Could not determine the latest release." >&2
            echo "       The GitHub API was unreachable, or the repository has no" >&2
            echo "       published releases yet." >&2
            echo "" >&2
            echo "       Install a specific version:  VERSION=v1.4.0" >&2
            echo "       Or install the branch head:   BRANCH=main" >&2
            exit 1
        fi
    else
        RESOLVED_TAG="$VERSION"
    fi
    SOURCE_DESC="release ${RESOLVED_TAG}"
    INSTALLED_REF="$RESOLVED_TAG"
    ARCHIVE_URL="https://github.com/${REPO}/archive/refs/tags/${RESOLVED_TAG}.tar.gz"
fi

echo "▶ DTU Linux Setup – Installer"
echo "▶ Repository : https://github.com/${REPO}"
echo "▶ Source     : ${SOURCE_DESC}"
echo "▶ Archive    : ${ARCHIVE_URL}"
echo ""

# ── Ensure required build tools ───────────────────────────────────────────────
for cmd in tar make; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "▶ Installing missing tool: ${cmd}..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get install -y "$cmd"
        else
            echo "ERROR: '${cmd}' not found and cannot be auto-installed." >&2
            echo "       Install it manually and re-run." >&2
            exit 1
        fi
    fi
done

# ── Download and extract ──────────────────────────────────────────────────────
echo "▶ Downloading ${SOURCE_DESC}..."
if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$ARCHIVE_URL" | tar -xz -C "$TMP_DIR" --strip-components=1
elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$ARCHIVE_URL" | tar -xz -C "$TMP_DIR" --strip-components=1
else
    echo "ERROR: Neither curl nor wget found." >&2
    echo "       Install curl first:" >&2
    echo "         Ubuntu  : sudo apt-get install curl" >&2
    exit 1
fi

# ── Remove previous installation ──────────────────────────────────────────────
echo "▶ Removing previous installation (if any)..."
make -C "$TMP_DIR" uninstall 2>/dev/null || true

# ── Install ───────────────────────────────────────────────────────────────────
echo "▶ Installing..."
make -C "$TMP_DIR" install

# Record what was installed. An image builder reads this to stamp the version
# into the ISO; on a normal machine it answers "which version is this?" without
# needing dpkg.
install -d /etc/dtu-setup
printf '%s\n' "$INSTALLED_REF" > /etc/dtu-setup/installed-ref
chmod 0644 /etc/dtu-setup/installed-ref

echo ""
echo "✅ DTU Linux Setup installed from ${SOURCE_DESC}."
echo ""
echo "   Launch:  dtu-sustain-setup"
echo "   Menu:    'DTU Linux Setup' under Settings / Indstillinger"
echo ""
echo "   Next step: place /etc/dtu-setup/site.conf and set department:"
echo "     sudo install -m 0644 data/site.conf.example /etc/dtu-setup/site.conf"
echo "     sudo \$EDITOR /etc/dtu-setup/site.conf   # fill in the <placeholders>"
echo "     echo sustain | sudo tee /etc/dtu-setup/department"
echo "     # or: echo ait | sudo tee /etc/dtu-setup/department"
