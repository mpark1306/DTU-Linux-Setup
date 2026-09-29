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

# Egen markør for skiftet af den lokale administratorkode.
#
# Den er adskilt fra MARKER, fordi de to ting kan gå galt hver for sig:
# afbryder brugeren resten af opsætningen, skal koden stadig skiftes, og
# færdiggør brugeren opsætningen uden at skifte koden, skal vi spørge igen
# ved næste login.
#
# Og den ligger systemvidt, ikke i $HOME. Der er én lokal administratorkonto
# på maskinen, ikke én per bruger. Lå markøren i hjemmemappen, ville bruger
# nummer to på en delt maskine blive bedt om at sætte en ny kode oven i den
# bruger nummer et lige har valgt, uden at nogen af dem vidste det.
ADMIN_PW_MARKER="/var/lib/dtu-setup/admin-password-changed"

# Rester fra dengang autostart-posten blev lagt i /etc/skel og kopieret ind i
# hver ny hjemmemappe. Den ligger nu i /etc/xdg/autostart og gælder alle
# sessioner; en per-bruger-kopi ville køre dialogen to gange.
STALE_USER_ENTRY="$HOME/.config/autostart/dtu-first-login.desktop"
rm -f "$STALE_USER_ENTRY" 2>/dev/null || true

# ── Read department config (written by qdrive.sh during admin setup) ─────────
DEPARTMENT="sustain"
if [[ -f /etc/dtu-setup/department ]]; then
  DEPARTMENT=$(cat /etc/dtu-setup/department)
fi
export DTU_DEPARTMENT="$DEPARTMENT"

# ── Already completed? ───────────────────────────────────────────────────────
#
# Bemaerk at der IKKE afsluttes her naar MARKER findes. Adgangskodetrinnet
# laengere nede har sin egen markoer og skal kunne koere paa en maskine hvor
# resten af opsaetningen for laengst er gjort. Den rigtige exit ligger lige
# foer velkomstdialogen.
if [[ -f "$MARKER" && -f "$ADMIN_PW_MARKER" ]]; then
    exit 0
fi

# ── Only for domain users ────────────────────────────────────────────────────
#
# Autostart-posten ligger systemvidt, så den udløses også for den lokale
# admin-konto der satte maskinen op. Opsætningen her henter netværksdrev og
# printere for en WIN-konto og giver ingen mening for en lokal bruger — og
# skrev den en markør, ville den rigtige bruger aldrig få dialogen.
#
# En domænebruger findes i getent, men ikke i /etc/passwd: den kommer fra
# SSSD. Det er den skelnen der tæller her, ikke UID-intervallet.
if grep -q "^${USER}:" /etc/passwd 2>/dev/null; then
    exit 0
fi
if ! getent passwd "$USER" >/dev/null 2>&1; then
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

# ── Keyboard layout ─────────────────────────────────────────────────────────
#
# WHY THIS IS ASKED BEFORE THE PASSWORD
#
# The image ships with one layout. A user with a different physical keyboard
# types their domain password through the wrong map, the server rejects it,
# and nothing on screen explains why: the password field shows dots either
# way. So the layout is chosen first, applied to the running session
# immediately, and only then is the password asked for.
#
# WHAT "DEFAULT" MEANS HERE
#
# The layout is written to the system, not to this user's profile, because
# the login screen has to have it too. SDDM runs on X, and the X server reads
# /etc/X11/xorg.conf.d/00-keyboard.conf, which is exactly what
# "localectl set-x11-keymap" writes, along with /etc/default/keyboard for the
# console. Setting it per user in KDE would fix the session and leave the
# login screen on the old layout, which is the half that matters when you are
# typing a password you cannot see.

# Display name and xkb code in one list, so the two cannot drift apart.
KEYBOARD_CHOICES=(
    "Danish|dk"
    "English (US)|us"
    "English (UK)|gb"
    "German|de"
    "Norwegian|no"
    "Swedish|se"
    "Finnish|fi"
    "Icelandic|is"
    "French|fr"
    "Spanish|es"
    "Italian|it"
    "Dutch|nl"
    "Polish|pl"
    "Portuguese|pt"
    "Greek|gr"
    "Turkish|tr"
)

current_keyboard_layout() {
    local layout=""
    if command -v localectl >/dev/null 2>&1; then
        layout="$(localectl status 2>/dev/null \
                  | awk -F: '/X11 Layout/{gsub(/[[:space:]]/,"",$2); print $2; exit}')"
    fi
    if [[ -z "$layout" && -r /etc/default/keyboard ]]; then
        layout="$(awk -F'"' '/^XKBLAYOUT=/{print $2; exit}' /etc/default/keyboard)"
    fi
    # A machine can carry several layouts, "dk,us". The first one is the
    # active default, and that is what the dialog should preselect.
    layout="${layout%%,*}"
    printf '%s\n' "${layout:-dk}"
}

keyboard_name_for_code() {
    local code="$1" entry
    for entry in "${KEYBOARD_CHOICES[@]}"; do
        if [[ "${entry##*|}" == "$code" ]]; then
            printf '%s\n' "${entry%%|*}"
            return 0
        fi
    done
    return 1
}

keyboard_code_for_name() {
    local name="$1" entry
    for entry in "${KEYBOARD_CHOICES[@]}"; do
        if [[ "${entry%%|*}" == "$name" ]]; then
            printf '%s\n' "${entry##*|}"
            return 0
        fi
    done
    return 1
}

ask_keyboard_layout() {
    local current="$1" default_name names=() entry valgt
    for entry in "${KEYBOARD_CHOICES[@]}"; do
        names+=("${entry%%|*}")
    done
    if ! default_name="$(keyboard_name_for_code "$current")"; then
        default_name="${names[0]}"
    fi

    if [[ "$DIALOG" == "kdialog" ]]; then
        valgt="$(kdialog --title "${DEPT_LABEL} – Keyboard layout" \
                         --combobox "Which keyboard layout does this machine use?" \
                         "${names[@]}" --default "$default_name")" || return 1
    else
        valgt="$(zenity --list --title="${DEPT_LABEL} – Keyboard layout" \
                        --text="Which keyboard layout does this machine use?" \
                        --column="Layout" "${names[@]}" --height=420)" || return 1
    fi
    [[ -n "$valgt" ]] || return 1
    keyboard_code_for_name "$valgt"
}

apply_keyboard_layout() {
    local code="$1" model=""

    if [[ -r /etc/default/keyboard ]]; then
        model="$(awk -F'"' '/^XKBMODEL=/{print $2; exit}' /etc/default/keyboard)"
    fi
    if [[ -z "$model" ]]; then
        model="pc105"
    fi

    # First try localectl as the user. The PolicyKit module already grants
    # domain users org.freedesktop.locale1.set-keyboard, so on a fully set up
    # machine this succeeds with no prompt at all.
    if command -v localectl >/dev/null 2>&1 \
       && localectl set-x11-keymap "$code" "$model" "" "" 2>/dev/null; then
        return 0
    fi

    # Otherwise do it with rights. The two files written here are the same
    # two that systemd-localed would have written; this is the fallback for a
    # machine where the polkit rules are not in place yet, which is exactly
    # the machine a first login happens on.
    pkexec bash -s <<WRAPEOF || return 1
#!/usr/bin/env bash
set -euo pipefail
code=$(printf '%q' "$code")
model=$(printf '%q' "$model")

if command -v localectl >/dev/null 2>&1 \
   && localectl set-x11-keymap "\$code" "\$model" "" ""; then
    exit 0
fi

printf 'XKBMODEL="%s"\nXKBLAYOUT="%s"\nXKBVARIANT=""\nXKBOPTIONS=""\nBACKSPACE="guess"\n' \
    "\$model" "\$code" > /etc/default/keyboard

install -d -m 0755 /etc/X11/xorg.conf.d
printf 'Section "InputClass"\n        Identifier "system-keyboard"\n        MatchIsKeyboard "on"\n        Option "XkbLayout" "%s"\n        Option "XkbModel" "%s"\nEndSection\n' \
    "\$code" "\$model" > /etc/X11/xorg.conf.d/00-keyboard.conf
chmod 0644 /etc/X11/xorg.conf.d/00-keyboard.conf
WRAPEOF
}

choose_keyboard_layout() {
    local current code navn
    current="$(current_keyboard_layout)"

    if ! code="$(ask_keyboard_layout "$current")"; then
        # Cancelled. Keeping the current layout is a valid answer, and the
        # user has to be able to get past this dialog to reach the rest of
        # the setup.
        return 0
    fi
    if [[ "$code" == "$current" ]]; then
        return 0
    fi

    if ! apply_keyboard_layout "$code"; then
        show_error "Keyboard layout" \
          "The keyboard layout could not be changed.

The machine keeps the layout it had. You can change it later in
System Settings under Keyboard."
        return 0
    fi

    # Apply it to the session that is running right now, so the password the
    # user types in the next dialog goes through the layout they just picked.
    if command -v setxkbmap >/dev/null 2>&1; then
        setxkbmap "$code" 2>/dev/null || true
    fi

    if ! navn="$(keyboard_name_for_code "$code")"; then
        navn="$code"
    fi
    show_message "Keyboard layout" \
      "The keyboard layout is now ${navn}.

This applies to the login screen as well, so the next time you sign in, your
password is typed with this layout."
}

# ── Den lokale administratorkonto ────────────────────────────────────────────
#
# HVORFOR
#
# Billedet udrulles med den samme lokale administratorkode på hver eneste
# maskine. Én kode der slipper ud, er dermed en kode til hele flåden. Det
# eneste sted den med sikkerhed kan skiftes til noget maskinen selv ejer, er
# her: ved første login, hvor der sidder et menneske foran skærmen.
#
# Koden forlader aldrig maskinen og skrives ingen steder. Den der vælger den,
# er også den der skal huske den.
ADMIN_PW_MINLEN=12
ADMIN_PW_MAXLEN=128
ADMIN_PW_MINCLASSES=3     # ud af små, store, cifre, tegn

# Kontoen hedder ikke det samme overalt. admin-mpark, admin-alton og
# administrator er alle set i flåden, så navnet gættes ikke. Den findes ud fra
# hvad den ER: en lokal konto med rigtig skal, UID i brugerintervallet, og
# ret til at hæve rettigheder.
find_local_admin() {
    local grupper navn uid skal fundet=()
    grupper=",$(getent group sudo 2>/dev/null | cut -d: -f4),$(getent group admin 2>/dev/null | cut -d: -f4),"

    while IFS=: read -r navn _ uid _ _ _ skal; do
        [[ "$uid" =~ ^[0-9]+$ ]] || continue
        (( uid >= 1000 && uid < 60000 )) || continue
        case "$skal" in
            */nologin|*/false|*/sync) continue ;;
        esac
        fundet+=("$navn")
        if [[ "$grupper" == *",${navn},"* ]]; then
            printf '%s\n' "$navn"
            return 0
        fi
    done < /etc/passwd

    # Ingen af de lokale konti stod i sudo eller admin. Er der præcis én lokal
    # konto tilbage, er det den. Er der flere, gættes der ikke: så springes
    # trinnet over og nogen kigger på maskinen i stedet for at vi skifter kode
    # på den forkerte konto.
    if (( ${#fundet[@]} == 1 )); then
        printf '%s\n' "${fundet[0]}"
        return 0
    fi
    return 1
}

# Returnerer en forklaring på hvorfor koden ikke dur, eller ingenting hvis den
# er i orden. Teksten er det brugeren får at se, så den skal sige hvad der
# mangler, ikke hvilken regel der blev brudt.
password_problem() {
    local pw="$1" konto="$2" klasser=0

    if (( ${#pw} < ADMIN_PW_MINLEN )); then
        printf 'The password must be at least %s characters long. Yours is %s.' \
               "$ADMIN_PW_MINLEN" "${#pw}"
        return 0
    fi
    if (( ${#pw} > ADMIN_PW_MAXLEN )); then
        printf 'The password can be at most %s characters long.' "$ADMIN_PW_MAXLEN"
        return 0
    fi
    if [[ "$pw" != "${pw#[[:space:]]}" || "$pw" != "${pw%[[:space:]]}" ]]; then
        printf 'The password cannot begin or end with a space. It is far too easy to mistype afterwards.'
        return 0
    fi

    # "if" og ikke "[[ ... ]] && klasser=...". Den korte form returnerer 1 når
    # testen er falsk, og under "set -e" afslutter det scriptet. Det er præcis
    # den fejl der væltede fix-login-screen.sh ude hos en bruger.
    if [[ "$pw" == *[[:lower:]]* ]];  then klasser=$(( klasser + 1 )); fi
    if [[ "$pw" == *[[:upper:]]* ]];  then klasser=$(( klasser + 1 )); fi
    if [[ "$pw" == *[[:digit:]]* ]];  then klasser=$(( klasser + 1 )); fi
    if [[ "$pw" == *[^[:alnum:]]* ]]; then klasser=$(( klasser + 1 )); fi
    if (( klasser < ADMIN_PW_MINCLASSES )); then
        printf 'The password must contain at least %s of these four: lower case, upper case, digits, symbols.' \
               "$ADMIN_PW_MINCLASSES"
        return 0
    fi

    local pw_lower="${pw,,}"
    if [[ "$pw_lower" == *"${konto,,}"* ]]; then
        printf 'The password cannot contain the account name "%s".' "$konto"
        return 0
    fi
    local brugernavn="${DTU_USERNAME:-$USER}"
    if [[ -n "$brugernavn" && "$pw_lower" == *"${brugernavn,,}"* ]]; then
        printf 'The password cannot contain your username.'
        return 0
    fi
    # Den lokale konto og domænekontoen skal kunne kompromitteres hver for sig.
    # Er koden den samme, er der kun én af dem.
    if [[ -n "${DTU_PASSWORD:-}" && "$pw" == "${DTU_PASSWORD}" ]]; then
        printf 'The password cannot be the same as your WIN domain password. The two accounts must stand on their own.'
        return 0
    fi
    return 0
}

change_local_admin_password() {
    if [[ "$DEPARTMENT" != "sustain" ]]; then
        return 0
    fi
    if [[ -f "$ADMIN_PW_MARKER" ]]; then
        return 0
    fi

    local konto
    if ! konto="$(find_local_admin)"; then
        echo "No single local administrator account found. Skipping the password change." >&2
        return 0
    fi

    show_message "${DEPT_LABEL} – Local administrator password" \
      "This machine has a local administrator account called \"${konto}\".

It is used when you install software or change system settings, and right now
it has the same password as every other new DTU machine. Please choose a new
one that applies only to this machine.

Requirements:
  • at least ${ADMIN_PW_MINLEN} characters
  • at least ${ADMIN_PW_MINCLASSES} of these four: lower case, upper case, digits, symbols
  • not your username, and not your domain password

Write it down somewhere safe. It cannot be looked up afterwards."

    local forsoeg ny gentag problem
    for forsoeg in 1 2 3; do
        # "if ! VAR=$(...)" og ikke en almindelig tildeling: trykker brugeren
        # Annullér, fejler kdialog, og under "set -e" ville en tildeling
        # afslutte hele scriptet midt i opsætningen.
        if ! ny="$(get_password "${DEPT_LABEL} – New password for ${konto}" \
                                "Choose a new password for the local account \"${konto}\":")"; then
            ny=""
        fi
        if [[ -z "$ny" ]]; then
            show_message "Skipped" \
              "The password for \"${konto}\" has not been changed.

You will be asked again the next time you log in."
            return 0
        fi

        problem="$(password_problem "$ny" "$konto")"
        if [[ -n "$problem" ]]; then
            show_error "That password cannot be used" "$problem

Please try again (attempt ${forsoeg} of 3)."
            continue
        fi

        if ! gentag="$(get_password "${DEPT_LABEL} – Repeat" \
                                    "Type the same password once more:")"; then
            gentag=""
        fi
        if [[ "$ny" != "$gentag" ]]; then
            show_error "The two entries do not match" \
              "The two entries were not the same.

Please try again (attempt ${forsoeg} of 3)."
            continue
        fi

        # Samme mønster som drev-opsætningen nedenfor: rørlagt til "bash -s",
        # ikke skrevet til en fil i /tmp. Koden når hverken disken eller en
        # proceslinje: printf er en indbygget kommando, og chpasswd læser den
        # på sin standardinddata.
        local rc=0
        pkexec bash -s <<WRAPEOF || rc=$?
#!/usr/bin/env bash
set -euo pipefail
konto=$(printf '%q' "$konto")
kode=$(printf '%q' "$ny")
# Mappen først, koden bagefter. Fejler noget af forarbejdet, skal det fejle
# INDEN koden er skiftet: ellers ville brugeren få at vide at det gik galt,
# på en maskine hvor koden allerede var ny.
install -d -m 0755 /var/lib/dtu-setup
printf '%s:%s\n' "\$konto" "\$kode" | chpasswd
printf '%s %s\n' "\$(date '+%F %T')" "\$konto" > $(printf '%q' "$ADMIN_PW_MARKER")
chmod 0644 $(printf '%q' "$ADMIN_PW_MARKER")
WRAPEOF
        unset ny gentag

        if (( rc == 0 )); then
            show_message "Password changed" \
              "The local administrator account \"${konto}\" now uses your new password.

This is the password to use whenever the machine asks for an administrator
password to install software or change system settings.

Remember to write it down somewhere safe."
            return 0
        fi

        show_error "The password could not be changed" \
          "The password for \"${konto}\" was not changed.

Either the administrator prompt was cancelled, or the system rejected the
password. You will be asked again the next time you log in.

Contact IT support if this keeps happening."
        return 0
    done

    show_error "The password was not changed" \
      "No valid password was chosen after three attempts.

You will be asked again the next time you log in."
    return 0
}

# ── Department labels ────────────────────────────────────────────────────────
if [[ "$DEPARTMENT" == "ait" ]]; then
  DEPT_LABEL="DTU AIT"
  DRIVE_TEXT="the O and M network drives"
else
  DEPT_LABEL="DTU Sustain"
  DRIVE_TEXT="the Q and P network drives"
fi

# ── Er resten af opsætningen allerede kørt? ──────────────────────────────────
#
# Så mangler kun kodeskiftet. Maskiner der blev sat op før dette trin fandtes,
# skal have det ved næste login, uden at få velkomstdialogen og spørgsmålet om
# domæneoplysninger igen.
if [[ -f "$MARKER" ]]; then
    change_local_admin_password
    exit 0
fi

# ── Welcome dialog ───────────────────────────────────────────────────────────
show_message "Welcome to ${DEPT_LABEL}" \
  "Welcome to your new DTU Linux workstation.

To finish the setup we need your WIN domain credentials.

This will set up:
  • ${DRIVE_TEXT}
  • FollowMe printers
  • DTUSecure Wi-Fi (connects automatically)

Press OK to continue."

# ── Keyboard layout, before anything is typed ────────────────────────────────
choose_keyboard_layout

# ── Collect credentials ──────────────────────────────────────────────────────
DTU_USERNAME=$(get_text "${DEPT_LABEL} – Login" "Enter your WIN domain username (for example mpark):")
if [[ -z "$DTU_USERNAME" ]]; then
    show_error "Error" "A username is required. The setup will run again at your next login."
    exit 1
fi

DTU_PASSWORD=$(get_password "${DEPT_LABEL} – Login" "Enter your WIN domain password:")
if [[ -z "$DTU_PASSWORD" ]]; then
    show_error "Error" "A password is required. The setup will run again at your next login."
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
    show_error "Error" "Cannot find the DTU setup scripts.\nPlease contact IT support."
    exit 1
fi

# ── Run drive setup ──────────────────────────────────────────────────────────
QDRIVE_LOG=$(mktemp /tmp/dtu-qdrive-XXXXXX.log)
QDRIVE_SCRIPT="${SCRIPTS_DIR}/qdrive.sh"

if [[ -f "$QDRIVE_SCRIPT" ]]; then
    # Piped to `bash -s` rather than written to a file in /tmp. A wrapper file
    # is owned by this (unprivileged) user but read by root only *after* the
    # PolicyKit prompt is answered, leaving a window in which another process
    # running as the same user could swap its contents and have its own code
    # run as root. It also keeps the domain password off the filesystem.
    pkexec bash -s <<WRAPEOF &
#!/usr/bin/env bash
export HOME=/root
export DTU_USERNAME=$(printf '%q' "$DTU_USERNAME")
export DTU_PASSWORD=$(printf '%q' "$DTU_PASSWORD")
export DTU_DEPARTMENT=$(printf '%q' "$DEPARTMENT")
bash $(printf '%q' "$QDRIVE_SCRIPT") > $(printf '%q' "$QDRIVE_LOG") 2>&1
WRAPEOF
    QDRIVE_PID=$!
    show_progress "${DEPT_LABEL}" "Setting up ${DRIVE_TEXT}..." "$QDRIVE_PID" || true
    wait "$QDRIVE_PID" 2>/dev/null
    QDRIVE_RC=$?

    if [[ $QDRIVE_RC -eq 0 ]]; then
        show_message "Network drives" "Your ${DRIVE_TEXT} are set up.

The drives are available whenever you are on the network.
Files in Desktop, Documents and Pictures are synced up automatically once the
drive can be reached."
    else
        show_error "Drive error" "Setting up the drives failed.\n\nLog: $QDRIVE_LOG\n\nPlease contact IT support."
    fi
else
    show_error "Error" "Drive script not found: $QDRIVE_SCRIPT"
fi

# ── Run FollowMe setup ───────────────────────────────────────────────────────
FOLLOWME_LOG=$(mktemp /tmp/dtu-followme-XXXXXX.log)
FOLLOWME_SCRIPT="${SCRIPTS_DIR}/followme.sh"

if [[ -f "$FOLLOWME_SCRIPT" ]]; then
    # See the note on the Q-Drive block above: piped, not written to /tmp.
    pkexec bash -s <<WRAPEOF &
#!/usr/bin/env bash
export HOME=/root
export DTU_USERNAME=$(printf '%q' "$DTU_USERNAME")
export DTU_PASSWORD=$(printf '%q' "$DTU_PASSWORD")
export DTU_DEPARTMENT=$(printf '%q' "$DEPARTMENT")
bash $(printf '%q' "$FOLLOWME_SCRIPT") > $(printf '%q' "$FOLLOWME_LOG") 2>&1
WRAPEOF
    FOLLOWME_PID=$!
    show_progress "${DEPT_LABEL}" "Setting up FollowMe printers..." "$FOLLOWME_PID" || true
    wait "$FOLLOWME_PID" 2>/dev/null
    FOLLOWME_RC=$?

    if [[ $FOLLOWME_RC -eq 0 ]]; then
        show_message "Printers" "The printers are configured.\n\n  • FollowMe-MFP-PCL\n  • BYG-PHP03-PCL (plotter)"
    else
        show_error "FollowMe error" "Setting up FollowMe failed.\n\nLog: $FOLLOWME_LOG\n\nPlease contact IT support."
    fi
else
    show_error "Error" "FollowMe script not found: $FOLLOWME_SCRIPT"
fi

# ── Run WiFi setup ───────────────────────────────────────────────────────────
WIFI_LOG=$(mktemp /tmp/dtu-wifi-XXXXXX.log)
WIFI_SCRIPT="${SCRIPTS_DIR}/wifi.sh"

if [[ -f "$WIFI_SCRIPT" ]]; then
    # See the note on the Q-Drive block above: piped, not written to /tmp.
    pkexec bash -s <<WRAPEOF &
#!/usr/bin/env bash
export HOME=/root
export DTU_USERNAME=$(printf '%q' "$DTU_USERNAME")
export DTU_PASSWORD=$(printf '%q' "$DTU_PASSWORD")
export DTU_DEPARTMENT=$(printf '%q' "$DEPARTMENT")
bash $(printf '%q' "$WIFI_SCRIPT") > $(printf '%q' "$WIFI_LOG") 2>&1
WRAPEOF
    WIFI_PID=$!
    show_progress "${DEPT_LABEL}" "Setting up DTUSecure Wi-Fi..." "$WIFI_PID" || true
    wait "$WIFI_PID" 2>/dev/null
    WIFI_RC=$?

    if [[ $WIFI_RC -eq 0 ]]; then
        show_message "DTUSecure Wi-Fi" "DTUSecure Wi-Fi is configured.\n\nThe machine connects to DTUSecure automatically when you are in range and not on a cable."
    else
        show_error "Wi-Fi error" "Setting up DTUSecure Wi-Fi failed.\n\nLog: $WIFI_LOG\n\nYou can still use the machine. Contact IT support about the Wi-Fi."
    fi
else
    echo "Wi-Fi script not found: $WIFI_SCRIPT, skipping." >&2
fi

# ── Skift koden på den lokale administratorkonto ─────────────────────────────
#
# Til sidst, og ikke først. Brugeren har på dette tidspunkt set hvad maskinen
# er, og har lige tastet sin domænekode. Bad vi om en ny administratorkode som
# det allerførste, ville den blive valgt i blinde og glemt inden frokost.
change_local_admin_password

# ── Mark as done ─────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$MARKER")"
# Markøren skrives her og kun her — efter at alt ovenfor er gået igennem.
# Er der afbrudt undervejs, findes den ikke, og dialogen kommer igen ved
# næste login. Det er med vilje: en halv opsætning skal ikke se færdig ud.
mkdir -p "$(dirname "$MARKER")"
date '+%F %T' > "$MARKER"

show_message "${DEPT_LABEL} – Finished" \
    "The setup is complete.

Your network drives, printers and Wi-Fi are ready to use.

Enjoy your new machine."

exit 0
