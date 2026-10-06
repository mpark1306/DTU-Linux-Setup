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
echo "── standalone fix for machines that already have the web apps ───"
FIX="$REPO_ROOT/scripts/standalone/fix-pwa-pin-wayland.sh"
F="$TMP/fixroot"; mkdir -p "$F/usr/share/applications" "$F/home/alice/.local/share/applications" "$TMP/fixbin"
old_exec='Exec=flatpak run io.github.ungoogled_software.ungoogled_chromium --app=https://word.cloud.microsoft/'
printf '[Desktop Entry]\nName=Word\n%s\nStartupWMClass=word.cloud.microsoft\n' "$old_exec" \
    > "$F/usr/share/applications/ms-word.desktop"
printf '[Desktop Entry]\nName=Outlook\nExec=chromium --app=https://outlook.office.com/mail/\n' \
    > "$F/home/alice/.local/share/applications/ms-outlook.desktop"
chmod 600 "$F/home/alice/.local/share/applications/ms-outlook.desktop"
printf '[Desktop Entry]\nName=Not ours\nExec=ms-tool --app=x\n' > "$F/usr/share/applications/other.desktop"
printf '[Desktop Entry]\nName=Also not ours\nExec=ms-thing\n' > "$F/usr/share/applications/ms-thing.desktop"
# flatpak: the app is installed, and overrides are kept in a file
cat > "$TMP/fixbin/flatpak" <<STUB
#!/bin/sh
st="$TMP/override.state"
case "\$1" in
  info) exit 0 ;;
  override)
    case "\$*" in
      *--show*) cat "\$st" 2>/dev/null ;;
      *--nosocket=wayland*) echo 'sockets=!wayland;' > "\$st" ;;
      *--socket=wayland*) echo 'sockets=wayland;' > "\$st" ;;
    esac ;;
esac
exit 0
STUB
chmod +x "$TMP/fixbin/flatpak"
fix() { FIX_ROOT="$F" PATH="$TMP/fixbin:/usr/bin:/bin" bash "$FIX" "$@" 2>&1; }

out="$(fix --check)"; rc=$?
check "--check on an unfixed machine fails" "1" "$rc"
has "and names the shortcut that lacks the flag" "ms-word.desktop lacks --ozone-platform=x11" "$out"
fix >/dev/null
has "the flatpak loses its Wayland socket" '!wayland' "$(cat "$TMP/override.state" 2>/dev/null)"
check "the system shortcut gets the flag" \
    "Exec=flatpak run io.github.ungoogled_software.ungoogled_chromium --ozone-platform=x11 --app=https://word.cloud.microsoft/" \
    "$(grep '^Exec=' "$F/usr/share/applications/ms-word.desktop")"
check "a user's own shortcut gets it too" "Exec=chromium --ozone-platform=x11 --app=https://outlook.office.com/mail/" \
    "$(grep '^Exec=' "$F/home/alice/.local/share/applications/ms-outlook.desktop")"
check "and keeps its permissions" "600" "$(stat -c %a "$F/home/alice/.local/share/applications/ms-outlook.desktop")"
has "StartupWMClass is left alone" "StartupWMClass=word.cloud.microsoft" "$(cat "$F/usr/share/applications/ms-word.desktop")"
check "other shortcuts are not touched" "Exec=ms-tool --app=x" "$(grep '^Exec=' "$F/usr/share/applications/other.desktop")"
check "an ms-*.desktop without --app is not touched" "Exec=ms-thing" "$(grep '^Exec=' "$F/usr/share/applications/ms-thing.desktop")"
out="$(fix)"
check "running it again adds the flag only once" "1" "$(grep -o -- '--ozone-platform=x11' "$F/usr/share/applications/ms-word.desktop" | wc -l)"
has "and says so" "already done" "$out"
fix --check >/dev/null; check "--check on a fixed machine passes" "0" "$?"
fix --undo >/dev/null
check "--undo restores the shortcut" "$old_exec" "$(grep '^Exec=' "$F/usr/share/applications/ms-word.desktop")"
has "and gives the flatpak its Wayland socket back" 'sockets=wayland' "$(cat "$TMP/override.state")"
out="$(PATH="$TMP/fixbin:/usr/bin:/bin" bash "$FIX" 2>&1)"; rc=$?
if [[ $EUID -ne 0 ]]; then
    check "without sudo it refuses" "1" "$rc"
    has "and says why" "Run it with sudo" "$out"
fi

echo
echo "─────────────────────────────────────────────────────────────────"
printf "%d passed, %d failed\n" "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
