#!/usr/bin/env bash
###############################################################################
# Installerer overvågningen af TPM2-bindingen.
#
# To dele, og de er med vilje adskilt:
#
#   dtu-tpm2-watch.sh    kører som root efter opstart, prøver om bindingen
#                        stadig låser op, og skriver en tilstandsfil
#   dtu-tpm2-notify.sh   kører i brugerens session, læser tilstandsfilen og
#                        siger det på almindeligt dansk
#
# Adskillelsen er ikke pænhed. Prøven kræver root og adgang til LUKS-headeren;
# beskeden kræver en grafisk session. Ingen proces har begge dele.
#
# Kaldes af tpm2-enroll.sh og tpm2-rebind.sh. Kan også køres alene.
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ $EUID -eq 0 ]] || { echo "Kør med sudo." >&2; exit 1; }

BIN_DIR=/usr/local/bin
UNIT_DIR=/etc/systemd/system
AUTOSTART_DIR=/etc/xdg/autostart      # gælder alle brugere, også dem der ikke
                                      # findes endnu. Se dtu-first-login.sh for
                                      # hvorfor /etc/skel var den forkerte vej.

install -m 0755 "${SCRIPT_DIR}/dtu-tpm2-watch.sh"  "${BIN_DIR}/dtu-tpm2-watch.sh"
install -m 0755 "${SCRIPT_DIR}/dtu-tpm2-notify.sh" "${BIN_DIR}/dtu-tpm2-notify.sh"
install -m 0644 "${SCRIPT_DIR}/systemd/dtu-tpm2-watch.service" \
                "${UNIT_DIR}/dtu-tpm2-watch.service"
install -m 0644 "${SCRIPT_DIR}/systemd/dtu-tpm2-notify.desktop" \
                "${AUTOSTART_DIR}/dtu-tpm2-notify.desktop"

install -d -m 0755 /var/lib/dtu-setup

systemctl daemon-reload
systemctl enable dtu-tpm2-watch.service >/dev/null 2>&1 || true

# Kør den med det samme, så tilstanden er kendt nu og ikke først efter en
# genstart. Den retter ingenting; den kigger.
systemctl start dtu-tpm2-watch.service >/dev/null 2>&1 || true

echo "    Overvågning af TPM2-bindingen er installeret."
echo "      kontrol ved opstart : dtu-tpm2-watch.service"
echo "      besked ved login    : ${AUTOSTART_DIR}/dtu-tpm2-notify.desktop"
