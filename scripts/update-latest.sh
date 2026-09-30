#!/usr/bin/env bash
###############################################################################
# DTU Linux Setup – Update to the latest release from GitHub
#
# Called by the GUI's "Update to latest version" button. Downloads the newest
# published RELEASE, verifies it against the release's sha256sums.txt, removes
# the current installation and installs the new one.
#
# Until v1.8.0 this fetched the head of the main branch, while the button
# promised "the latest release". A branch head has not necessarily passed CI
# and has no checksum, so a click in the GUI ran unverified code as root.
#
# BRANCH=<name> still installs a branch head, for testing only, UNVERIFIED.
# See bin/dtu-install.sh for what the checksum does and does not protect
# against.
###############################################################################
set -euo pipefail

REPO="mpark1306/DTU-Linux-Setup"
BRANCH="${BRANCH:-}"
SHA256="${SHA256:-}"
# Overridable only so the tests can serve a fake release from localhost.
DTU_RELEASE_BASE_URL="${DTU_RELEASE_BASE_URL:-https://github.com/${REPO}/releases/download}"
DTU_API_URL="${DTU_API_URL:-https://api.github.com/repos/${REPO}/releases/latest}"

# ── fetch_verified_release ───────────────────────────────────────────────────
# Identical copy of the function in bin/dtu-install.sh; see the comment there.
# tests/test_scripts.py fails if the two copies drift apart.
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

resolve_latest_release() {
    local json
    json="$(curl -fsSL "$DTU_API_URL" 2>/dev/null || wget -qO- "$DTU_API_URL" 2>/dev/null || true)"
    printf '%s' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# Tests source this file for the functions above and stop here.
if [[ -n "${DTU_INSTALL_SOURCE_ONLY:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: This script must be run as root (use sudo/pkexec)." >&2
  exit 1
fi

TMP_DIR="$(mktemp -d /tmp/dtu-update-XXXXXXXX)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

echo "▶ DTU Linux Setup – Update"
echo "▶ Repository : https://github.com/${REPO}"

for cmd in tar make sha256sum; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: '${cmd}' not found." >&2
    exit 1
  fi
done

if [[ -n "$BRANCH" ]]; then
  echo "▶ Source     : branch '${BRANCH}'"
  echo "" >&2
  echo "⚠  UNVERIFIED UPDATE: a branch head has no checksum. Testing only." >&2
  echo "" >&2
  ARCHIVE_FILE="${TMP_DIR}.tar.gz"
  _dtu_download "https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz" "$ARCHIVE_FILE"
  tar -xzf "$ARCHIVE_FILE" -C "$TMP_DIR" --strip-components=1 --no-same-owner
  rm -f "$ARCHIVE_FILE"
  SOURCE_DESC="branch '${BRANCH}' (UNVERIFIED)"
else
  echo "▶ Looking up latest release..."
  TAG="$(resolve_latest_release)"
  if [[ -z "$TAG" ]]; then
    echo "ERROR: Could not determine the latest release (GitHub API unreachable?)." >&2
    exit 1
  fi
  echo "▶ Source     : release ${TAG}"
  fetch_verified_release "$TAG" "$TMP_DIR" || exit 1
  SOURCE_DESC="release ${TAG} (checksum verified)"
fi

echo "▶ Removing previous installation (if any)..."
make -C "$TMP_DIR" uninstall 2>/dev/null || true

echo "▶ Installing..."
make -C "$TMP_DIR" install

echo ""
echo "✅ DTU Linux Setup updated from ${SOURCE_DESC}."
echo "   Restart the app if it is still open."
