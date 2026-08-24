"""Collecting the input a module needs before it can run.

Each module declares an `input_type`; this maps that declaration to the dialog
that satisfies it, and lets a pre-loaded env file stand in for the dialog when
it already carries every value the module wants.

Kept out of the window because the rule "an env file suppresses the prompt" is
the part most likely to be wrong, and it is far easier to reason about — and to
change — when it is not interleaved with the code that starts the process.
"""

from __future__ import annotations

from PyQt6.QtWidgets import QInputDialog, QLineEdit, QMessageBox, QWidget

from .input_dialog import (
    CredentialDialog,
    DomainJoinDialog,
    SoftwareDialog,
    UsernameDialog,
)
from .modules import ModuleDef
from .tpm2_dialog import Tpm2ReadinessDialog

# Returned instead of a dict when the user dismissed a dialog. `None` is the
# signal to abort the run without an error — cancelling is not a failure.
Cancelled = None


def collect_module_env(
    parent: QWidget,
    mod: ModuleDef,
    overrides: dict[str, str],
    script_path=None,
) -> dict[str, str] | None:
    """Return the env vars for `mod`, or None if the user cancelled.

    `overrides` is whatever a previously loaded env file supplied. A dialog is
    shown only for values it does not already cover; where it covers some but
    not all, the dialog opens pre-filled with what is known.
    """
    env: dict[str, str] = {}

    if mod.input_type == "credentials":
        user = overrides.get("DTU_USERNAME", "")
        pw = overrides.get("DTU_PASSWORD", "")
        if user and pw:
            env["DTU_USERNAME"] = user
            env["DTU_PASSWORD"] = pw
        else:
            dlg = CredentialDialog(
                parent,
                title=f"{mod.title} – Credentials",
                message=f"Enter your WIN domain credentials for {mod.title}:",
            )
            if user:
                dlg.username_edit.setText(user)
            result = dlg.get_credentials()
            if result is None:
                return Cancelled
            env["DTU_USERNAME"], env["DTU_PASSWORD"] = result

    elif mod.input_type == "domain_join":
        host = overrides.get("DTU_HOSTNAME", "")
        admin = overrides.get("DTU_ADMIN_USERNAME", "")
        if host and admin:
            env["DTU_HOSTNAME"] = host
            env["DTU_ADMIN_USERNAME"] = admin
        else:
            dlg = DomainJoinDialog(parent)
            if host:
                dlg.hostname_edit.setText(host)
            if admin:
                dlg.username_edit.setText(admin)
            result = dlg.get_domain_join_info()
            if result is None:
                return Cancelled
            env["DTU_HOSTNAME"], env["DTU_ADMIN_USERNAME"] = result

    elif mod.input_type == "username":
        user = overrides.get("DTU_USERNAME", "")
        if user:
            env["DTU_USERNAME"] = user
        else:
            dlg = UsernameDialog(
                parent,
                title=f"{mod.title} – Username",
                message=f"Enter the target username for {mod.title}:",
            )
            username = dlg.get_username()
            if username is None:
                return Cancelled
            env["DTU_USERNAME"] = username

    elif mod.input_type == "software":
        dlg = SoftwareDialog(parent)
        cisco_pre = overrides.get("DTU_CISCO_TARBALL", "")
        if cisco_pre:
            dlg._cisco_path_edit.setText(cisco_pre)
        result = dlg.get_software_config()
        if result is None:
            return Cancelled
        conf_path, cisco_tarball = result
        env["DTU_SOFTWARE_CONF"] = overrides.get("DTU_SOFTWARE_CONF", str(conf_path))
        if cisco_tarball:
            env["DTU_CISCO_TARBALL"] = cisco_tarball

    # TPM2 asks for the existing LUKS passphrase on top of its declared
    # input_type: the value is never stored, only handed to systemd-cryptenroll
    # for this one run.
    if mod.id == "tpm2-enroll":
        # Preconditions first. They are things the user cannot fix from inside
        # this application — firmware settings, and whether the disk was
        # encrypted at install time — so finding out afterwards from a failed
        # run costs a reboot into BIOS either way. Better to say so up front.
        if script_path is not None:
            dlg = Tpm2ReadinessDialog(
                parent, script_path, overrides.get("DTU_LUKS_DEVICE", "")
            )
            dlg.exec()
            if not dlg.should_proceed():
                return Cancelled

        passphrase = overrides.get("DTU_LUKS_PASSPHRASE", "")
        if not passphrase:
            passphrase, ok = QInputDialog.getText(
                parent,
                "TPM2 Auto-Unlock",
                "Enter your existing LUKS passphrase:",
                QLineEdit.EchoMode.Password,
            )
            if not ok:
                return Cancelled
        if not passphrase:
            QMessageBox.warning(
                parent,
                "Missing passphrase",
                "A LUKS passphrase is required to continue TPM2 enrollment.",
            )
            return Cancelled
        env["DTU_LUKS_PASSPHRASE"] = passphrase

        # Modulets øvrige valg har ingen dialog: der er ingen terminal bag
        # pkexec, så det bruger sine defaults medmindre en env-fil siger andet.
        # Uden dem videresendt kan brugeren ikke styre dem overhovedet.
        for key in ("DTU_LUKS_DEVICE", "DTU_TPM2_REBIND", "DTU_TPM2_RECOVERY_KEY"):
            if overrides.get(key):
                env[key] = overrides[key]

    return env


def collect_batch_credentials(
    parent: QWidget, needed: str, overrides: dict[str, str], *, message: str
) -> dict[str, str] | None:
    """Collect the one set of credentials a whole batch shares.

    Asking once per batch rather than once per module is the entire point of
    Run All; `needed` comes from `batch.batch_input_type`.
    """
    if needed == "credentials":
        user = overrides.get("DTU_USERNAME", "")
        pw = overrides.get("DTU_PASSWORD", "")
        if not (user and pw):
            dlg = CredentialDialog(
                parent, title="User Scripts – Credentials", message=message
            )
            if user:
                dlg.username_edit.setText(user)
            result = dlg.get_credentials()
            if result is None:
                return Cancelled
            user, pw = result
        return {"DTU_USERNAME": user, "DTU_PASSWORD": pw}

    if needed == "username":
        user = overrides.get("DTU_USERNAME", "")
        if not user:
            dlg = UsernameDialog(
                parent, title="User Scripts – Username", message=message
            )
            username = dlg.get_username()
            if username is None:
                return Cancelled
            user = username
        return {"DTU_USERNAME": user}

    return {}
