#!/usr/bin/env bash
###############################################################################
# DTU – First-Login User Setup
# Deployed to /usr/local/bin/dtu-first-login.sh
#
# Runs on the user's first login via an autostart .desktop entry.
# Shows a welcome dialog, collects domain credentials, then
# runs Q/O-Drive, FollowMe and WiFi setup via pkexec.
###############################################################################
set -euo pipefail

MARKER="$HOME/.config/dtu-sustain-setup-done"
AUTOSTART_ENTRY="$HOME/.config/autostart/dtu-first-login.desktop"

# ── Read department config (written by qdrive.sh during admin setup) ─────────
DEPARTMENT="sustain"
if [[ -f /etc/dtu-setup/department ]]; then
  DEPARTMENT=$(cat /etc/dtu-setup/department)
fi
export DTU_DEPARTMENT="$DEPARTMENT"

# ── Already completed? ───────────────────────────────────────────────────────
if [[ -f "$MARKER" ]]; then
    exit 0
fi

# ── Detect dialog tool ───────────────────────────────────────────────────────
if command -v kdialog &>/dev/null; then
    DIALOG="kdialog"
elif command -v zenity &>/dev/null; then
    DIALOG="zenity"
else
    echo "ERROR: Neither kdialog nor zenity found." >&2
    exit 1
fi

# ── Helper functions ─────────────────────────────────────────────────────────
show_message() {
    local title="$1" msg="$2"
    if [[ "$DIALOG" == "kdialog" ]]; then
        kdialog --title "$title" --msgbox "$msg"
    else
        zenity --info --title="$title" --text="$msg" --width=450
    fi
}

show_error() {
    local title="$1" msg="$2"
    if [[ "$DIALOG" == "kdialog" ]]; then
        kdialog --title "$title" --error "$msg"
    else
        zenity --error --title="$title" --text="$msg" --width=450
    fi
}

get_text() {
    local title="$1" label="$2"
    if [[ "$DIALOG" == "kdialog" ]]; then
        kdialog --title "$title" --inputbox "$label" ""
    else
        zenity --entry --title="$title" --text="$label" --width=400
    fi
}

get_password() {
    local title="$1" label="$2"
    if [[ "$DIALOG" == "kdialog" ]]; then
        kdialog --title "$title" --password "$label"
    else
        zenity --password --title="$title" --width=400
    fi
}

ask_yesno() {
    local title="$1" msg="$2"
    if [[ "$DIALOG" == "kdialog" ]]; then
        kdialog --title "$title" --yesno "$msg"
    else
        zenity --question --title="$title" --text="$msg" --width=450
    fi
}

show_progress() {
    local title="$1" msg="$2" pid="$3"
    if [[ "$DIALOG" == "kdialog" ]]; then
        local dbusref
        dbusref=$(kdialog --title "$title" --progressbar "$msg" 0)
        qdbus $dbusref showCancelButton false 2>/dev/null || true
        wait "$pid" 2>/dev/null
        local rc=$?
        qdbus $dbusref close 2>/dev/null || true
        return $rc
    else
        (
            while kill -0 "$pid" 2>/dev/null; do
                echo "# $msg"
                sleep 1
            done
        ) | zenity --progress --title="$title" --text="$msg" \
                   --pulsate --auto-close --no-cancel --width=400 2>/dev/null || true
        wait "$pid" 2>/dev/null
        return $?
    fi
}

# ── Department labels ────────────────────────────────────────────────────────
if [[ "$DEPARTMENT" == "ait" ]]; then
  DEPT_LABEL="DTU AIT"
  DRIVE_TEXT="O-Drive & M-Drive (netværksdrev)"
else
  DEPT_LABEL="DTU Sustain"
  DRIVE_TEXT="Q-Drive & P-Drive (netværksdrev)"
fi

# ── Welcome dialog ───────────────────────────────────────────────────────────
show_message "Velkommen til ${DEPT_LABEL}" \
    "Velkommen til din nye Ubuntu-arbejdsstation!

For at fuldføre opsætningen har vi brug for dine WIN-domæne-oplysninger.

Dette opsætter:
  • ${DRIVE_TEXT}
  • FollowMe printere
  • DTUSecure WiFi (automatisk forbindelse)

Tryk OK for at fortsætte."

# ── Collect credentials ──────────────────────────────────────────────────────
DTU_USERNAME=$(get_text "${DEPT_LABEL} – Login" "Indtast dit WIN-domæne brugernavn (f.eks. mpark):")
if [[ -z "$DTU_USERNAME" ]]; then
    show_error "Fejl" "Brugernavn er påkrævet. Kør opsætningen igen ved næste login."
    exit 1
fi

DTU_PASSWORD=$(get_password "${DEPT_LABEL} – Login" "Indtast dit WIN-domæne kodeord:")
if [[ -z "$DTU_PASSWORD" ]]; then
    show_error "Fejl" "Kodeord er påkrævet. Kør opsætningen igen ved næste login."
    exit 1
fi

export DTU_USERNAME DTU_PASSWORD

# ── Find scripts directory ───────────────────────────────────────────────────
SCRIPTS_DIR=""
for candidate in \
    /opt/dtu-sustain-setup/scripts/ubuntu \
    /usr/share/dtu-sustain-setup/scripts/ubuntu \
    /usr/local/share/dtu-sustain-setup/scripts/ubuntu; do
    if [[ -d "$candidate" ]]; then
        SCRIPTS_DIR="$candidate"
        break
    fi
done

if [[ -z "$SCRIPTS_DIR" ]]; then
    show_error "Fejl" "Kan ikke finde DTU setup-scripts.\nKontakt IT-support."
    exit 1
fi

# ── Run drive setup ──────────────────────────────────────────────────────────
QDRIVE_LOG=$(mktemp /tmp/dtu-qdrive-XXXXXX.log)
QDRIVE_SCRIPT="${SCRIPTS_DIR}/qdrive.sh"

if [[ -f "$QDRIVE_SCRIPT" ]]; then
    WRAPPER=$(mktemp /tmp/dtu-first-login-XXXXXX.sh)
    cat > "$WRAPPER" <<WRAPEOF
#!/usr/bin/env bash
export HOME=/root
export DTU_USERNAME=$(printf '%q' "$DTU_USERNAME")
export DTU_PASSWORD=$(printf '%q' "$DTU_PASSWORD")
export DTU_DEPARTMENT=$(printf '%q' "$DEPARTMENT")
bash $(printf '%q' "$QDRIVE_SCRIPT") > $(printf '%q' "$QDRIVE_LOG") 2>&1
WRAPEOF
    chmod 700 "$WRAPPER"

    pkexec bash "$WRAPPER" &
    QDRIVE_PID=$!
    show_progress "${DEPT_LABEL}" "Opsætter ${DRIVE_TEXT}..." "$QDRIVE_PID" || true
    wait "$QDRIVE_PID" 2>/dev/null
    QDRIVE_RC=$?
    rm -f "$WRAPPER"

    if [[ $QDRIVE_RC -eq 0 ]]; then
        show_message "Netværksdrev" "${DRIVE_TEXT} er sat op!

Drev er tilgængelige når du er på netværket.
Filer i Desktop, Documents og Pictures synces automatisk op når drevet kan nås."
    else
        show_error "Drev fejl" "Drev-opsætning fejlede.\n\nSe log: $QDRIVE_LOG\n\nKontakt IT-support."
    fi
else
    show_error "Fejl" "Drev-script ikke fundet: $QDRIVE_SCRIPT"
fi

# ── Run FollowMe setup ───────────────────────────────────────────────────────
FOLLOWME_LOG=$(mktemp /tmp/dtu-followme-XXXXXX.log)
FOLLOWME_SCRIPT="${SCRIPTS_DIR}/followme.sh"

if [[ -f "$FOLLOWME_SCRIPT" ]]; then
    WRAPPER=$(mktemp /tmp/dtu-first-login-XXXXXX.sh)
    cat > "$WRAPPER" <<WRAPEOF
#!/usr/bin/env bash
export HOME=/root
export DTU_USERNAME=$(printf '%q' "$DTU_USERNAME")
export DTU_PASSWORD=$(printf '%q' "$DTU_PASSWORD")
export DTU_DEPARTMENT=$(printf '%q' "$DEPARTMENT")
bash $(printf '%q' "$FOLLOWME_SCRIPT") > $(printf '%q' "$FOLLOWME_LOG") 2>&1
WRAPEOF
    chmod 700 "$WRAPPER"

    pkexec bash "$WRAPPER" &
    FOLLOWME_PID=$!
    show_progress "${DEPT_LABEL}" "Opsætter FollowMe printere..." "$FOLLOWME_PID" || true
    wait "$FOLLOWME_PID" 2>/dev/null
    FOLLOWME_RC=$?
    rm -f "$WRAPPER"

    if [[ $FOLLOWME_RC -eq 0 ]]; then
        show_message "FollowMe" "FollowMe printere er konfigureret!\n\n  • FollowMe-MFP-PCL\n  • FollowMe-Plot-PS"
    else
        show_error "FollowMe fejl" "FollowMe opsætning fejlede.\n\nSe log: $FOLLOWME_LOG\n\nKontakt IT-support."
    fi
else
    show_error "Fejl" "FollowMe script ikke fundet: $FOLLOWME_SCRIPT"
fi

# ── Run WiFi setup ───────────────────────────────────────────────────────────
WIFI_LOG=$(mktemp /tmp/dtu-wifi-XXXXXX.log)
WIFI_SCRIPT="${SCRIPTS_DIR}/wifi.sh"

if [[ -f "$WIFI_SCRIPT" ]]; then
    WRAPPER=$(mktemp /tmp/dtu-first-login-XXXXXX.sh)
    cat > "$WRAPPER" <<WRAPEOF
#!/usr/bin/env bash
export HOME=/root
export DTU_USERNAME=$(printf '%q' "$DTU_USERNAME")
export DTU_PASSWORD=$(printf '%q' "$DTU_PASSWORD")
bash $(printf '%q' "$WIFI_SCRIPT") > $(printf '%q' "$WIFI_LOG") 2>&1
WRAPEOF
    chmod 700 "$WRAPPER"

    pkexec bash "$WRAPPER" &
    WIFI_PID=$!
    show_progress "${DEPT_LABEL}" "Opsætter DTUSecure WiFi..." "$WIFI_PID" || true
    wait "$WIFI_PID" 2>/dev/null
    WIFI_RC=$?
    rm -f "$WRAPPER"

    if [[ $WIFI_RC -eq 0 ]]; then
        show_message "DTUSecure WiFi" "DTUSecure WiFi er konfigureret!\n\nMaskinen forbinder automatisk til DTUSecure når du er i nærheden og ikke har kabel."
    else
        show_error "WiFi fejl" "DTUSecure WiFi opsætning fejlede.\n\nSe log: $WIFI_LOG\n\nDu kan stadig bruge maskinen – kontakt IT-support for WiFi."
    fi
else
    echo "WiFi script ikke fundet: $WIFI_SCRIPT – springer over." >&2
fi

# ── Mark as done ─────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$MARKER")"
date '+%F %T' > "$MARKER"

# Remove autostart so it won't run again
rm -f "$AUTOSTART_ENTRY"

show_message "${DEPT_LABEL} – Færdig" \
    "Opsætningen er fuldført!

Dine netværksdrev, printere og WiFi er nu klar til brug.

God arbejdslyst!"

exit 0
