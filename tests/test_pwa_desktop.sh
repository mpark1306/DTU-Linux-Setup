#!/usr/bin/env bash
###############################################################################
# Tests for the .desktop files scripts/install-ms-pwa.sh writes.
#
# On Kubuntu 26.04 the session is Wayland, and a PWA window could not be
# pinned to the task manager: the option was greyed out. Under Wayland Plasma
# finds a window's .desktop file by its app_id, which must be the FILE NAME;
# StartupWMClass is an X11 thing. Measured in KWin on 6 Oct 2026:
#   Chromium via XWayland: WM_CLASS instance word.cloud.microsoft -> ms-word
#   Chromium native:       app_id chrome-word.cloud.microsoft__-Default -> none
#
# The fix keeps Chromium on XWayland, where StartupWMClass works in both
# sessions: the Chromium flatpak loses its Wayland socket (flatpak override),
# and the shortcut passes --ozone-platform=x11 for a non-flatpak Chromium.
#
# Run with: bash tests/test_pwa_desktop.sh
###############################################################################
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/install-ms-pwa.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok_()  { printf '  \033[0;32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad_() { printf '  \033[0;31m✗\033[0m %s\n' "$1"; printf '      %s\n' "${2:-}"; FAIL=$((FAIL+1)); }
check() { if [[ "$2" == "$3" ]]; then ok_ "$1"; else bad_ "$1" "expected [$2], got [$3]"; fi; }
has()   { if [[ "$3" == *"$2"* ]]; then ok_ "$1"; else bad_ "$1" "missing [$2] in: $3"; fi; }
lacks() { if [[ "$3" != *"$2"* ]]; then ok_ "$1"; else bad_ "$1" "found [$2] in: $3"; fi; }

echo "── Wayland app_id, against what KWin reported ───────────────────"
# Measured on Kubuntu 26.04.1 with the Ungoogled Chromium flatpak, one window
# per app, Chromium running natively on Wayland.
measured="chrome-outlook.office.com__mail_-Default
chrome-outlook.office.com__calendar_view_workweek-Default
chrome-word.cloud.microsoft__-Default
chrome-excel.cloud.microsoft__-Default
chrome-powerpoint.cloud.microsoft__-Default
chrome-www.onenote.com__notebooks-Default
chrome-to-do.office.com__tasks_-Default
chrome-www.microsoft365.com__-Default"
derived="$(bash "$SCRIPT" --print-wmclass | awk '{print $NF}' | grep -v 'sharepoint')"
check "every derived app_id matches the measured one" "$measured" "$derived"
# OneDrive's host depends on the tenant, so it is checked with a fixed one.
check "the tenant's OneDrive as well" "chrome-example-my.sharepoint.com__-Default" \
    "$(MS_TENANT=example bash "$SCRIPT" --print-wmclass | awk '/sharepoint/ {print $NF}')"

echo
echo "── the shortcut and the flatpak override ────────────────────────"
mkdir -p "$TMP/home" "$TMP/bin" "$TMP/fbin" "$TMP/icons"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/chromium"; chmod +x "$TMP/bin/chromium"
# A flatpak that answers "info" and records every "override"
printf '#!/bin/sh\n[ "$1" = override ] && echo "$*" >> "%s/overrides.log"\nexit 0\n' "$TMP" > "$TMP/fbin/flatpak"
chmod +x "$TMP/fbin/flatpak"
for id in outlook calendar word excel powerpoint onenote onedrive todo m365; do
    printf '<svg xmlns="http://www.w3.org/2000/svg"/>\n' > "$TMP/icons/$id.svg"
done
apps="$TMP/home/.local/share/applications"
run() { HOME="$TMP/home" PATH="$1:/usr/bin:/bin" bash "$SCRIPT" --no-deps --icon-dir "$TMP/icons" "${@:2}" >/dev/null 2>&1; }

run "$TMP/bin" word
main="$(cat "$apps/ms-word.desktop" 2>/dev/null)"
has "the shortcut runs Chromium via XWayland" "--ozone-platform=x11 --app=https://word.cloud.microsoft/" "$main"
has "and keeps StartupWMClass, which only works on X11 and XWayland" "StartupWMClass=word.cloud.microsoft" "$main"
check "one .desktop file per app, so a pin always points at the same one" "ms-word.desktop" \
    "$(find "$apps" -name '*.desktop' -printf '%f\n')"
check "a non-flatpak Chromium gets no flatpak override" "" "$(cat "$TMP/overrides.log" 2>/dev/null)"
run "$TMP/bin" --remove word
check "--remove takes it away" "" "$(find "$apps" -name '*.desktop' 2>/dev/null)"

run "$TMP/fbin" word
has "the flatpak Chromium loses its Wayland socket" \
    "override --user --nosocket=wayland io.github.ungoogled_software.ungoogled_chromium" \
    "$(cat "$TMP/overrides.log" 2>/dev/null)"
has "and its shortcut runs through flatpak" "Exec=flatpak run io.github.ungoogled_software.ungoogled_chromium --ozone-platform=x11" \
    "$(cat "$apps/ms-word.desktop" 2>/dev/null)"

echo
echo "─────────────────────────────────────────────────────────────────"
printf "%d passed, %d failed\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
