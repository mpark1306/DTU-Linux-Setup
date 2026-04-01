#!/usr/bin/env bash
###############################################################################
# DTU Sustain – openSUSE Tumbleweed – Module: Auto-mount (Qdrev/Pdrev) + Desktop Polkit
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
need_root

banner "Auto-mount (Qdrev/Pdrev) + Desktop Polkit Rules"

# ── 1/3: Polkit rules for normal desktop use ──────────────────────────────
echo "[1/3] Writing desktop polkit rules..."
mkdir -p /etc/polkit-1/rules.d/

tee /etc/polkit-1/rules.d/45-desktop-users.rules > /dev/null <<'EOF'
// Allow active local sessions to perform normal desktop operations
// without authentication prompts.
// IT-admin overrides are handled by 49-domain-admins.rules.
polkit.addRule(function(action, subject) {

    if (!subject.active || !subject.local) return;

    var allow = [
        // USB / removable storage
        "org.freedesktop.udisks2.filesystem-mount",
        "org.freedesktop.udisks2.filesystem-mount-system",
        "org.freedesktop.udisks2.filesystem-unmount-others",
        "org.freedesktop.udisks2.encrypted-unlock",
        "org.freedesktop.udisks2.encrypted-unlock-system",
        "org.freedesktop.udisks2.eject-media",
        "org.freedesktop.udisks2.power-off-drive",
        "org.freedesktop.udisks2.loop-setup",
        // Network (WiFi, VPN, wired)
        "org.freedesktop.NetworkManager.network-control",
        "org.freedesktop.NetworkManager.settings.connection.modify",
        "org.freedesktop.NetworkManager.wifi.scan",
        "org.freedesktop.NetworkManager.checkpoint-rollback",
        // Power / session
        "org.freedesktop.login1.suspend",
        "org.freedesktop.login1.suspend-multiple-sessions",
        "org.freedesktop.login1.hibernate",
        "org.freedesktop.login1.hibernate-multiple-sessions",
        "org.freedesktop.login1.reboot",
        "org.freedesktop.login1.reboot-multiple-sessions",
        "org.freedesktop.login1.power-off",
        "org.freedesktop.login1.power-off-multiple-sessions",
        // Date / time
        "org.freedesktop.timedate1.set-time",
        "org.freedesktop.timedate1.set-timezone",
        "org.freedesktop.timedate1.set-ntp",
        // KDE colour management (display calibration)
        "org.freedesktop.color-manager.create-device",
        "org.freedesktop.color-manager.create-profile",
        "org.freedesktop.color-manager.delete-device",
        "org.freedesktop.color-manager.delete-profile",
        "org.freedesktop.color-manager.modify-device",
        "org.freedesktop.color-manager.modify-profile",
        // Locale / keyboard layout
        "org.freedesktop.locale1.set-locale",
        "org.freedesktop.locale1.set-keyboard",
        // PackageKit — repo refresh only (not install)
        "org.freedesktop.packagekit.system-sources-refresh",
    ];

    if (allow.indexOf(action.id) !== -1) {
        return polkit.Result.YES;
    }
});
EOF

# ── 2/3: pam_exec script — Pdrev symlink at login/logout ─────────────────
echo "[2/3] Installing Pdrev session script..."

tee /usr/local/sbin/pdrev-session.sh > /dev/null <<'SCRIPT'
#!/usr/bin/env bash
# /usr/local/sbin/pdrev-session.sh
# Called by pam_exec at session open/close.
# Creates /mnt/Pdrev → /mnt/Qdrev/Personal/<user> at login,
# removes it at logout.
# PAM_USER and PAM_TYPE are injected by the PAM framework.

QDREV="/mnt/Qdrev"
PDREV="/mnt/Pdrev"
PERSONAL="${QDREV}/Personal/${PAM_USER}"

case "${PAM_TYPE}" in
  open_session)
    # Trigger systemd automount by touching the mountpoint, then wait
    ls "${QDREV}" >/dev/null 2>&1 &
    for i in $(seq 1 20); do
      mountpoint -q "${QDREV}" 2>/dev/null && break
      sleep 1
    done

    # Remove stale symlink from a previous session
    [ -L "${PDREV}" ] && rm -f "${PDREV}"
    # Remove empty mountpoint dir if left over
    [ -d "${PDREV}" ] && rmdir "${PDREV}" 2>/dev/null || true

    # Create symlink if the user's Personal folder exists on the share
    if [ -d "${PERSONAL}" ]; then
      ln -sf "${PERSONAL}" "${PDREV}"
    fi
    ;;

  close_session)
    # Only remove if symlink still points to this user's folder
    if [ -L "${PDREV}" ] && \
       [ "$(readlink "${PDREV}")" = "${PERSONAL}" ]; then
      rm -f "${PDREV}"
    fi
    ;;
esac

exit 0
SCRIPT
chmod 755 /usr/local/sbin/pdrev-session.sh

# ── 3/3: Wire pam_exec into PAM common-session ───────────────────────────
echo "[3/3] Adding PAM session hook..."
PAM_FILE="/etc/pam.d/common-session"
PAM_LINE="session optional pam_exec.so quiet /usr/local/sbin/pdrev-session.sh"

if grep -qF "pdrev-session.sh" "${PAM_FILE}"; then
  echo "PAM hook already present — skipping."
else
  echo "${PAM_LINE}" >> "${PAM_FILE}"
  ok "PAM hook added to ${PAM_FILE}"
fi

# Restart polkit for new rules
nohup bash -c 'sleep 2 && systemctl restart polkit' > /tmp/polkit-restart.log 2>&1 &

ok "Auto-mount + Desktop Polkit configured."
echo "    /mnt/Pdrev → /mnt/Qdrev/Personal/<username>  (created at next login)"
echo "    Polkit rules:  USB, network, power, time — no prompts for local users"
warn "Note: Qdrev (Q-Drive module) must be configured before Pdrev will appear."
echo "    Log ud og ind igen for at teste."
