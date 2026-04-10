#!/usr/bin/env bash
###############################################################################
# DTU Sustain – First-Login User Setup
# Deployed to /usr/local/bin/dtu-first-login.sh
#
# Runs on the user's first login via an autostart .desktop entry.
# Shows a KDE welcome dialog, collects domain credentials, then
# runs Q-Drive and FollowMe setup via pkexec.
###############################################################################
set -euo pipefail

MARKER="$HOME/.config/dtu-sustain-setup-done"
AUTOSTART_ENTRY="$HOME/.config/autostart/dtu-first-login.desktop"

# ── Already completed? ───────────────────────────────────────
if [[ -f "$MARKER" ]]; then
    exit 0
fi

# ── Detect dialog tool ───────────────────────────────────────
if command -v kdialog &>/dev/null; then
    DIALOG="kdialog"
elif command -v zenity &>/dev/null; then
    DIALOG="zenity"
else
    echo "ERROR: Neither kdialog nor zenity found." >&2
    exit 1
fi

# ── Helper functions ─────────────────────────────────────────
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
        # Set as busy (pulsating)
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
              --pulsate --auto-close --no-cancel --width=400 2>/dev/null
        wait "$pid" 2>/dev/null
        return $?
    fi
}

# ── Welcome dialog ───────────────────────────────────────────
show_message "Velkommen til DTU Sustain" \
    "Velkommen til din nye Ubuntu-arbejdsstation!\n\nFor at fuldføre opsætningen har vi brug for dine WIN-domæne-oplysninger.\n\nDette opsætter:\n  • Q-Drive & P-Drive (netværksdrev)\n  • FollowMe printere\n\nTryk OK for at fortsætte."

# ── Collect credentials ──────────────────────────────────────
DTU_USERNAME=$(get_text "DTU Sustain – Login" "Indtast dit WIN-domæne brugernavn (f.eks. mpark):")
if [[ -z "$DTU_USERNAME" ]]; then
    show_error "Fejl" "Brugernavn er påkrævet. Kør opsætningen igen ved næste login."
    exit 1
fi

DTU_PASSWORD=$(get_password "DTU Sustain – Login" "Indtast dit WIN-domæne kodeord:")
if [[ -z "$DTU_PASSWORD" ]]; then
    show_error "Fejl" "Kodeord er påkrævet. Kør opsætningen igen ved næste login."
    exit 1
fi

export DTU_USERNAME DTU_PASSWORD

# ── Find scripts directory ───────────────────────────────────
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

# ── Run Q-Drive setup ────────────────────────────────────────
QDRIVE_LOG=$(mktemp /tmp/dtu-qdrive-XXXXXX.log)
QDRIVE_SCRIPT="${SCRIPTS_DIR}/qdrive.sh"

if [[ -f "$QDRIVE_SCRIPT" ]]; then
    # Write a wrapper that passes creds via env (pkexec strips env)
    WRAPPER=$(mktemp /tmp/dtu-first-login-XXXXXX.sh)
    cat > "$WRAPPER" <<WRAPEOF
#!/usr/bin/env bash
export HOME=/root
export DTU_USERNAME=$(printf '%q' "$DTU_USERNAME")
export DTU_PASSWORD=$(printf '%q' "$DTU_PASSWORD")
bash $(printf '%q' "$QDRIVE_SCRIPT") > $(printf '%q' "$QDRIVE_LOG") 2>&1
WRAPEOF
    chmod 700 "$WRAPPER"

    pkexec bash "$WRAPPER" &
    QDRIVE_PID=$!
    show_progress "DTU Sustain" "Opsætter Q-Drive & P-Drive..." "$QDRIVE_PID" || true
    wait "$QDRIVE_PID" 2>/dev/null
    QDRIVE_RC=$?
    rm -f "$WRAPPER"

    if [[ $QDRIVE_RC -eq 0 ]]; then
        show_message "Q-Drive" "Q-Drive & P-Drive er sat op!\n\nDine mapper (Desktop, Documents, Pictures) peger nu på dit personlige netværksdrev."
    else
        show_error "Q-Drive fejl" "Q-Drive opsætning fejlede.\n\nSe log: $QDRIVE_LOG\n\nKontakt IT-support."
    fi
else
    show_error "Fejl" "Q-Drive script ikke fundet: $QDRIVE_SCRIPT"
fi

# ── Run FollowMe setup ───────────────────────────────────────
FOLLOWME_LOG=$(mktemp /tmp/dtu-followme-XXXXXX.log)
FOLLOWME_SCRIPT="${SCRIPTS_DIR}/followme.sh"

if [[ -f "$FOLLOWME_SCRIPT" ]]; then
    WRAPPER=$(mktemp /tmp/dtu-first-login-XXXXXX.sh)
    cat > "$WRAPPER" <<WRAPEOF
#!/usr/bin/env bash
export HOME=/root
export DTU_USERNAME=$(printf '%q' "$DTU_USERNAME")
export DTU_PASSWORD=$(printf '%q' "$DTU_PASSWORD")
bash $(printf '%q' "$FOLLOWME_SCRIPT") > $(printf '%q' "$FOLLOWME_LOG") 2>&1
WRAPEOF
    chmod 700 "$WRAPPER"

    pkexec bash "$WRAPPER" &
    FOLLOWME_PID=$!
    show_progress "DTU Sustain" "Opsætter FollowMe printere..." "$FOLLOWME_PID" || true
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

# ── Mark as done ─────────────────────────────────────────────
mkdir -p "$(dirname "$MARKER")"
date '+%F %T' > "$MARKER"

# Remove autostart so it won't run again
rm -f "$AUTOSTART_ENTRY"

show_message "DTU Sustain – Færdig" \
    "Opsætningen er fuldført!\n\nDine netværksdrev og printere er nu klar til brug.\n\nGod arbejdslyst!"

exit 0
