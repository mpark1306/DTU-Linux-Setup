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
#   VERSION=v1.8.0       Pin to one release, e.g. to reproduce an image
#   SHA256=<64 hex>      Expected checksum of the source archive, obtained
#                        some other way than from GitHub. See "What the
#                        checksum protects against" below.
#   BRANCH=main          Install a branch head instead — for testing unreleased
#                        work. Takes precedence over VERSION. UNVERIFIED.
#   DTU_ALLOW_UNVERIFIED=1
#                        Install a release that predates verifiable source
#                        archives, from GitHub's generated tarball. UNVERIFIED.
#
#   Example:
#     curl -fsSL ... | sudo VERSION=v1.4.0 bash
#     curl -fsSL ... | sudo BRANCH=main bash
#
# The default is a release, not a branch: a branch head is whatever was pushed
# last, has not necessarily passed CI, and cannot be named afterwards. An image
# built from "main" can never be traced back to the code it contains.
#
# ── What the checksum protects against ──────────────────────────────────────
#
# Every release carries a source archive built by CI and a sha256sums.txt that
# covers it. Nothing is extracted, let alone run as root, until the archive
# matches. That catches a truncated or corrupted download, and a tampered copy
# served from a cache or mirror.
#
# It does NOT help against someone who can replace BOTH files: a compromised
# GitHub account, or an interception with a CA the machine trusts. The
# checksum arrives over the same channel as the archive. For that, pass
# SHA256= with a value that reached you some other way (the image build pins
# one), or verify a signature. A checksum is integrity, not authenticity.
#
###############################################################################
set -euo pipefail

REPO="mpark1306/DTU-Linux-Setup"
BRANCH="${BRANCH:-}"
VERSION="${VERSION:-latest}"
SHA256="${SHA256:-}"
DTU_ALLOW_UNVERIFIED="${DTU_ALLOW_UNVERIFIED:-}"
# Overridable only so the tests can serve a fake release from localhost. The
# caller is root already, so this grants nothing it did not have.
DTU_RELEASE_BASE_URL="${DTU_RELEASE_BASE_URL:-https://github.com/${REPO}/releases/download}"
DTU_API_URL="${DTU_API_URL:-https://api.github.com/repos/${REPO}/releases/latest}"

# ── fetch_verified_release ───────────────────────────────────────────────────
# fetch_verified_release TAG DEST
#
# Downloads the source archive of release TAG together with the release's
# sha256sums.txt, checks one against the other (and against $SHA256 if given),
# and only then extracts into DEST. On any failure DEST is left untouched and
# the function returns 1 with the reason on stderr.
#
# The same function lives in scripts/update-latest.sh. Both files must be
# runnable on their own (this one is piped into bash straight from GitHub),
# so they cannot source a shared library. tests/test_scripts.py fails if the
# two copies drift apart.
fetch_verified_release() {
    local tag="$1" dest="$2"
    local ver="${tag#v}"
    local asset="dtu-sustain-setup-${ver}.tar.gz"
    local base="${DTU_RELEASE_BASE_URL%/}/${tag}"
    local work expected actual matches

    work="$(mktemp -d)"
    # A RETURN trap outlives the function that set it, so it removes itself.
    # shellcheck disable=SC2064  # expand $work now, while it is still in scope
    trap "rm -rf '$work'; trap - RETURN" RETURN

    if ! _dtu_download "${base}/sha256sums.txt" "${work}/sha256sums.txt"; then
        echo "ERROR: Could not download sha256sums.txt for ${tag}." >&2
        echo "       ${base}/sha256sums.txt" >&2
        return 1
    fi
    if ! _dtu_download "${base}/${asset}" "${work}/${asset}"; then
        echo "ERROR: Release ${tag} has no source archive named ${asset}." >&2
        echo "       Releases made before verifiable source archives existed" >&2
        echo "       do not have one. Install a newer release, or accept an" >&2
        echo "       unverified install explicitly with DTU_ALLOW_UNVERIFIED=1." >&2
        return 1
    fi

    # Exactly one line must name the archive, by its bare file name. Zero means
    # the release does not vouch for it; two means we cannot tell which to trust.
    matches="$(awk -v f="$asset" '{ n = $2; sub(/^\*/, "", n) } n == f' "${work}/sha256sums.txt")"
    if [[ -z "$matches" || "$(printf '%s\n' "$matches" | wc -l)" -ne 1 ]]; then
        echo "ERROR: sha256sums.txt for ${tag} does not list ${asset} exactly once." >&2
        return 1
    fi
    expected="$(printf '%s' "$matches" | awk '{ print tolower($1) }')"
    if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]]; then
        echo "ERROR: sha256sums.txt for ${tag} has a malformed checksum." >&2
        return 1
    fi

    actual="$(sha256sum "${work}/${asset}" | awk '{ print $1 }')"
    if [[ "$actual" != "$expected" ]]; then
        echo "ERROR: CHECKSUM MISMATCH for ${asset}. Nothing was installed." >&2
        echo "       expected ${expected}" >&2
        echo "       got      ${actual}" >&2
        return 1
    fi
    if [[ -n "$SHA256" && "$actual" != "${SHA256,,}" ]]; then
        echo "ERROR: ${asset} does not match the SHA256 you pinned. Nothing was installed." >&2
        echo "       It does match the release's own sha256sums.txt, so the release" >&2
        echo "       itself differs from what you expected." >&2
        echo "       pinned ${SHA256,,}" >&2
        echo "       got    ${actual}" >&2
        return 1
    fi

    echo "▶ Verified ${asset}"
    echo "  sha256 ${actual}"
    if [[ -n "$SHA256" ]]; then
        echo "  matches both the release's sha256sums.txt and your pinned SHA256"
    fi

    tar -xzf "${work}/${asset}" -C "$dest" --strip-components=1 --no-same-owner
}

_dtu_download() { # _dtu_download URL FILE
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$2" "$1"
    else
        echo "ERROR: Neither curl nor wget found." >&2
        return 1
    fi
}

# Tests source this file for the functions above and stop here.
if [[ -n "${DTU_INSTALL_SOURCE_ONLY:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi

TMP_DIR="$(mktemp -d /tmp/dtu-install-XXXXXXXX)"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# ── Check the inputs first ───────────────────────────────────────────────────
# Before the root check and before any download: a bad pin should fail at
# once, with a reason, whoever runs it.
if [[ -n "$SHA256" ]]; then
    if [[ -n "$BRANCH" || -n "$DTU_ALLOW_UNVERIFIED" ]]; then
        echo "ERROR: SHA256 was given, but this install is unverified (BRANCH or" >&2
        echo "       DTU_ALLOW_UNVERIFIED). A pin that is never checked is worse than" >&2
        echo "       none, so refusing." >&2
        exit 1
    fi
    if [[ ! "${SHA256,,}" =~ ^[0-9a-f]{64}$ ]]; then
        echo "ERROR: SHA256 must be 64 hexadecimal characters." >&2
        exit 1
    fi
fi

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
        json="$(curl -fsSL "$DTU_API_URL" 2>/dev/null || true)"
    else
        json="$(wget -qO- "$DTU_API_URL" 2>/dev/null || true)"
    fi
    tag="$(printf '%s' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
    printf '%s' "$tag"
}

VERIFIED=yes
if [[ -n "$BRANCH" ]]; then
    SOURCE_DESC="branch '${BRANCH}'"
    INSTALLED_REF="$BRANCH"
    ARCHIVE_URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"
    VERIFIED=no
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
    if [[ -n "$DTU_ALLOW_UNVERIFIED" ]]; then
        ARCHIVE_URL="https://github.com/${REPO}/archive/refs/tags/${RESOLVED_TAG}.tar.gz"
        VERIFIED=no
    else
        ARCHIVE_URL="${DTU_RELEASE_BASE_URL%/}/${RESOLVED_TAG}/dtu-sustain-setup-${RESOLVED_TAG#v}.tar.gz"
    fi
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
if [[ "$VERIFIED" == yes ]]; then
    fetch_verified_release "$RESOLVED_TAG" "$TMP_DIR" || exit 1
else
    echo "" >&2
    echo "⚠  UNVERIFIED INSTALL: nothing checks that this code is what was published." >&2
    echo "⚠  Use it for testing only, never to build an image." >&2
    echo "" >&2
    ARCHIVE_FILE="${TMP_DIR}.tar.gz"
    _dtu_download "$ARCHIVE_URL" "$ARCHIVE_FILE" || exit 1
    tar -xzf "$ARCHIVE_FILE" -C "$TMP_DIR" --strip-components=1 --no-same-owner
    rm -f "$ARCHIVE_FILE"
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
if [[ "$VERIFIED" == yes ]]; then
    echo "✅ DTU Linux Setup installed from ${SOURCE_DESC} (checksum verified)."
else
    echo "✅ DTU Linux Setup installed from ${SOURCE_DESC} (UNVERIFIED)."
fi
echo ""
echo "   Launch:  dtu-sustain-setup"
echo "   Menu:    'DTU Linux Setup' under Settings / Indstillinger"
echo ""
echo "   Next step: place /etc/dtu-setup/site.conf and set department:"
echo "     sudo install -m 0644 data/site.conf.example /etc/dtu-setup/site.conf"
echo "     sudo \$EDITOR /etc/dtu-setup/site.conf   # fill in the <placeholders>"
echo "     echo sustain | sudo tee /etc/dtu-setup/department"
echo "     # or: echo ait | sudo tee /etc/dtu-setup/department"
