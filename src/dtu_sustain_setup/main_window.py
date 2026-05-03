"""Main window for DTU Linux Setup."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Callable

from PyQt6.QtCore import Qt
from PyQt6.QtGui import QFont, QIcon, QPixmap
from PyQt6.QtWidgets import (
    QComboBox,
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QMainWindow,
    QMessageBox,
    QPushButton,
    QSizePolicy,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

from .distro import Distro, detect_distro, distro_display_name, get_scripts_dir
from .error_dialog import ErrorDialog
from .input_dialog import CredentialDialog, DomainJoinDialog, PasswordDialog, SoftwareDialog, UsernameDialog
from .module_runner import ModuleRunner


# ─── Module definitions ─────────────────────────────────────────────────────

@dataclass
class ModuleDef:
    id: str
    title: str
    description: str
    script_name: str
    needs_root: bool
    input_type: str  # "none", "credentials", "username", "domain_join"
    icon_name: str
    enabled: bool = True
    common_script: bool = False


MODULES: list[ModuleDef] = [
    ModuleDef(
        id="domain-join",
        title="Domain Join",
        description="Join WIN.DTU.DK domain\n(realmd + SSSD + mkhomedir)",
        script_name="domain-join.sh",
        needs_root=True,
        input_type="domain_join",
        icon_name="network-server",
    ),
    ModuleDef(
        id="qdrive",
        title="Network Drives",
        description="Map department network drives\n(Q+P or O+M via CIFS)",
        script_name="qdrive.sh",
        needs_root=True,
        input_type="credentials",
        icon_name="folder-remote",
    ),
    ModuleDef(
        id="defender",
        title="Microsoft Defender",
        description="Defender for Endpoint\n(install + onboard)",
        script_name="defender.sh",
        needs_root=True,
        input_type="none",
        icon_name="security-high",
    ),
    ModuleDef(
        id="polkit",
        title="PolicyKit",
        description="Domain-user rights\n(USB, WiFi, packages)",
        script_name="polkit.sh",
        needs_root=True,
        input_type="none",
        icon_name="preferences-system",
    ),
    ModuleDef(
        id="followme",
        title="Printers",
        description="FollowMe (Sustain) /\nWebPrint app (AIT)",
        script_name="followme.sh",
        needs_root=True,
        input_type="credentials",
        icon_name="printer",
    ),
    ModuleDef(
        id="wifi",
        title="DTUSecure WiFi",
        description="WPA2-Enterprise\n(PEAP/MSCHAPv2 auto-connect)",
        script_name="wifi.sh",
        needs_root=True,
        input_type="credentials",
        icon_name="network-wireless",
    ),
    ModuleDef(
        id="software",
        title="Software",
        description="Flatpaks, Snaps\n& Cisco VPN",
        script_name="software.sh",
        needs_root=True,
        input_type="software",
        icon_name="application-x-addon",
    ),
    ModuleDef(
        id="automount",
        title="Auto-mount",
        description="USB automount + udev rules\n(no symlinks)",
        script_name="automount.sh",
        needs_root=True,
        input_type="none",
        icon_name="drive-removable-media",
    ),
    ModuleDef(
        id="sync-homedir",
        title="Sync Home Dirs",
        description="Backup Desktop, Documents\n& Pictures to network drive",
        script_name="setup-sync-homedir.sh",
        needs_root=True,
        input_type="none",
        icon_name="folder-download",
        common_script=True,
    ),
    ModuleDef(
        id="rdp",
        title="RDP (xrdp)",
        description="Remote Desktop\n(KDE Plasma via xrdp)",
        script_name="rdp.sh",
        needs_root=True,
        input_type="none",
        icon_name="preferences-desktop-remote-desktop",
    ),
    ModuleDef(
        id="ansible",
        title="Ansible Onboarding",
        description="sus-root account\n+ SSH key + sudo",
        script_name="ansible.sh",
        needs_root=True,
        input_type="password",
        icon_name="utilities-terminal",
    ),
    ModuleDef(
        id="first-login-deploy",
        title="First-Login Setup",
        description="Deploy welcome dialog\nfor new domain users",
        script_name="first-login-deploy.sh",
        needs_root=True,
        input_type="none",
        icon_name="user-new",
    ),
    ModuleDef(
        id="reset-test-user",
        title="Reset Test User",
        description="Remove domain user state\n& home dir for re-testing",
        script_name="reset-test-user.sh",
        needs_root=True,
        input_type="username",
        icon_name="edit-delete",
        enabled=False,
        common_script=True,
    ),
]


# ─── Colour palette ─────────────────────────────────────────────────────────

DTU_RED = "#990000"
DTU_RED_DARK = "#7a0000"
ADMIN_BADGE = "#cc3333"
USER_BADGE = "#339933"


# ─── Main Window ────────────────────────────────────────────────────────────

class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()

        self._distro = detect_distro()
        self._scripts_dir = get_scripts_dir(self._distro)
        self._runner = ModuleRunner(self)
        self._runner.output_received.connect(self._append_log)
        self._runner.finished.connect(self._on_module_finished)
        self._runner.failed.connect(self._on_module_failed)
        self._module_buttons: dict[str, QPushButton] = {}

        self.setWindowTitle("DTU Linux Setup")
        self.setMinimumSize(800, 700)

        # Try to set window icon
        icon_path = self._find_icon()
        if icon_path:
            self.setWindowIcon(QIcon(str(icon_path)))

        central = QWidget()
        self.setCentralWidget(central)
        main_layout = QVBoxLayout(central)
        main_layout.setSpacing(12)
        main_layout.setContentsMargins(20, 20, 20, 20)

        # ── Header ──────────────────────────────────────────────────────
        header = QHBoxLayout()

        logo_label = QLabel()
        logo_path = self._find_icon()
        if logo_path:
            pixmap = QPixmap(str(logo_path)).scaled(
                64, 64, Qt.AspectRatioMode.KeepAspectRatio,
                Qt.TransformationMode.SmoothTransformation,
            )
            logo_label.setPixmap(pixmap)
        header.addWidget(logo_label)

        title_block = QVBoxLayout()
        title_label = QLabel("DTU Linux Setup")
        title_font = QFont()
        title_font.setPointSize(22)
        title_font.setBold(True)
        title_label.setFont(title_font)
        title_label.setStyleSheet(f"color: {DTU_RED};")
        title_block.addWidget(title_label)

        distro_label = QLabel(f"Detected: {distro_display_name()}")
        distro_label.setStyleSheet("color: #666; font-size: 12px;")
        title_block.addWidget(distro_label)
        header.addLayout(title_block)

        # Department selector
        self._dept_combo = QComboBox()
        self._dept_combo.addItem("DTU Sustain", "sustain")
        self._dept_combo.addItem("DTU AIT", "ait")
        self._dept_combo.setMinimumWidth(160)
        self._dept_combo.setStyleSheet(
            "QComboBox { font-size: 13px; padding: 5px 10px; border: 2px solid #ddd; "
            "border-radius: 6px; background: white; } "
            f"QComboBox:focus {{ border-color: {DTU_RED}; }}"
        )
        header.addSpacing(20)
        header.addWidget(self._dept_combo)
        header.addStretch()

        main_layout.addLayout(header)

        # ── Distro warning ──────────────────────────────────────────────
        if self._distro == Distro.UNKNOWN:
            warn_label = QLabel(
                "⚠️ Unsupported distribution detected! "
                "This tool supports Ubuntu 24.04 and openSUSE Tumbleweed."
            )
            warn_label.setStyleSheet(
                "background: #fff3cd; color: #856404; padding: 8px; "
                "border: 1px solid #ffc107; border-radius: 4px;"
            )
            warn_label.setWordWrap(True)
            main_layout.addWidget(warn_label)

        # ── Module grid ─────────────────────────────────────────────────
        grid = QGridLayout()
        grid.setSpacing(10)

        for i, mod in enumerate(MODULES):
            btn = self._create_module_button(mod)
            if not mod.enabled:
                btn.setEnabled(False)
                btn.setToolTip("This module has been disabled.")
            self._module_buttons[mod.id] = btn
            row, col = divmod(i, 3)
            grid.addWidget(btn, row, col)

        main_layout.addLayout(grid)

        # ── Action bar ──────────────────────────────────────────────────
        action_bar = QHBoxLayout()

        run_all_btn = QPushButton("▶  Run All Admin Modules")
        run_all_btn.setStyleSheet(
            f"QPushButton {{ background: {DTU_RED}; color: white; font-weight: bold; "
            f"padding: 10px 20px; border-radius: 6px; font-size: 14px; }}"
            f"QPushButton:hover {{ background: {DTU_RED_DARK}; }}"
            f"QPushButton:disabled {{ background: #ccc; color: #888; }}"
        )
        run_all_btn.clicked.connect(self._run_all_admin)
        self._run_all_btn = run_all_btn
        action_bar.addWidget(run_all_btn)

        action_bar.addStretch()

        cancel_btn = QPushButton("Cancel")
        cancel_btn.setEnabled(False)
        cancel_btn.setStyleSheet(
            "QPushButton { padding: 10px 20px; border-radius: 6px; font-size: 14px; "
            "background: #e0e0e0; color: #333; border: 1px solid #bbb; }"
            "QPushButton:hover { background: #d0d0d0; }"
            "QPushButton:disabled { background: #555; color: #888; border-color: #666; }"
        )
        cancel_btn.clicked.connect(self._cancel_running)
        self._cancel_btn = cancel_btn
        action_bar.addWidget(cancel_btn)

        main_layout.addLayout(action_bar)

        # ── Log output ──────────────────────────────────────────────────
        log_label = QLabel("Output Log:")
        log_label.setStyleSheet("font-weight: bold; font-size: 13px; margin-top: 8px;")
        main_layout.addWidget(log_label)

        self._log = QTextEdit()
        self._log.setReadOnly(True)
        self._log.setFont(QFont("Monospace", 10))
        self._log.setStyleSheet(
            "background: #1e1e2e; color: #cdd6f4; border: 1px solid #45475a; "
            "border-radius: 6px; padding: 8px;"
        )
        self._log.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        main_layout.addWidget(self._log)

        # ── Status bar ──────────────────────────────────────────────────
        self.statusBar().showMessage("Ready")

    def _find_icon(self) -> Path | None:
        """Find the DTU icon for the window."""
        candidates = [
            Path(__file__).resolve().parent.parent.parent / "data" / "dtu-sustain-setup.svg",
            Path("/opt/dtu-sustain-setup/data/dtu-sustain-setup.svg"),
            Path("/usr/share/icons/hicolor/scalable/apps/dtu-sustain-setup.svg"),
        ]
        for p in candidates:
            if p.exists():
                return p
        return None

    def _create_module_button(self, mod: ModuleDef) -> QPushButton:
        """Create a styled button for a module."""
        badge = "ADMIN" if mod.needs_root else "USER"
        badge_color = ADMIN_BADGE if mod.needs_root else USER_BADGE

        btn = QPushButton()
        btn.setMinimumSize(220, 100)
        btn.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Fixed)

        btn.setText(f"{mod.title}\n{mod.description}")
        btn.setStyleSheet(
            f"QPushButton {{"
            f"  text-align: left; padding: 12px; border: 2px solid #ddd;"
            f"  border-radius: 8px; font-size: 12px; background: white; color: #222;"
            f"}}"
            f"QPushButton:hover {{ border-color: {DTU_RED}; background: #fff5f5; color: #222; }}"
            f"QPushButton:disabled {{ background: #f0f0f0; color: #aaa; border-color: #eee; }}"
        )

        btn.clicked.connect(lambda checked, m=mod: self._run_module(m))
        return btn

    def _run_module(self, mod: ModuleDef) -> None:
        """Collect input and start a module."""
        if self._runner.is_running():
            QMessageBox.warning(
                self, "Busy", "A module is already running. Wait for it to finish or cancel it."
            )
            return

        if mod.common_script:
            script = self._scripts_dir.parent / mod.script_name
        else:
            script = self._scripts_dir / mod.script_name
        if not script.exists():
            QMessageBox.critical(
                self, "Script Missing",
                f"Script not found:\n{script}\n\nIs the correct distro detected?",
            )
            return

        env_vars: dict[str, str] = {}

        if mod.input_type == "credentials":
            dlg = CredentialDialog(
                self,
                title=f"{mod.title} – Credentials",
                message=f"Enter your WIN domain credentials for {mod.title}:",
            )
            result = dlg.get_credentials()
            if result is None:
                return
            env_vars["DTU_USERNAME"] = result[0]
            env_vars["DTU_PASSWORD"] = result[1]

        elif mod.input_type == "domain_join":
            dlg = DomainJoinDialog(self)
            result = dlg.get_domain_join_info()
            if result is None:
                return
            env_vars["DTU_HOSTNAME"] = result[0]
            env_vars["DTU_ADMIN_USERNAME"] = result[1]

        elif mod.input_type == "username":
            dlg = UsernameDialog(
                self,
                title=f"{mod.title} – Username",
                message=f"Enter the target username for {mod.title}:",
            )
            username = dlg.get_username()
            if username is None:
                return
            env_vars["DTU_USERNAME"] = username

        elif mod.input_type == "password":
            dlg = PasswordDialog(
                self,
                title=f"{mod.title} – Password",
                message=f"Enter the password for the sus-root service account:",
                password_label="sus-root password:",
            )
            password = dlg.get_password()
            if password is None:
                return
            env_vars["DTU_ANSIBLE_PASSWORD"] = password

        elif mod.input_type == "software":
            dlg = SoftwareDialog(self)
            result = dlg.get_software_config()
            if result is None:
                return
            conf_path, cisco_tarball = result
            env_vars["DTU_SOFTWARE_CONF"] = str(conf_path)
            if cisco_tarball:
                env_vars["DTU_CISCO_TARBALL"] = cisco_tarball

        env_vars["DTU_DEPARTMENT"] = self._dept_combo.currentData()
        self._set_running(True)
        self.statusBar().showMessage(f"Running: {mod.title}...")
        self._runner.run(
            script, mod.id, needs_root=mod.needs_root, env_vars=env_vars
        )

    def _run_all_admin(self) -> None:
        """Queue all admin modules (runs them sequentially).

        User-credential modules (Q-Drive, FollowMe) are skipped — those
        are handled by the first-login welcome dialog when the domain
        user logs in for the first time.
        """
        if self._runner.is_running():
            QMessageBox.warning(self, "Busy", "A module is already running.")
            return

        # Modules that require the end-user's domain credentials are
        # deferred to first login — skip them in the admin run.
        DEFERRED_MODULES = {"qdrive", "followme", "onedrive", "wifi"}

        # Collect admin info for Domain Join
        admin_dlg = DomainJoinDialog(self)
        admin_result = admin_dlg.get_domain_join_info()
        if admin_result is None:
            return

        # Collect sus-root password (for Ansible onboarding)
        ansible_dlg = PasswordDialog(
            self,
            title="Run All – Ansible Onboarding",
            message="Enter the password for the sus-root service account:",
            password_label="sus-root password:",
        )
        ansible_password = ansible_dlg.get_password()
        if ansible_password is None:
            return

        self._queued_modules = [
            m for m in MODULES if m.enabled and m.id not in DEFERRED_MODULES
        ]
        self._shared_env = {
            "DTU_HOSTNAME": admin_result[0],
            "DTU_ADMIN_USERNAME": admin_result[1],
            "DTU_ANSIBLE_PASSWORD": ansible_password,
            "DTU_DEPARTMENT": self._dept_combo.currentData(),
        }

        info_msg = (
            "The following modules will be skipped and run automatically\n"
            "when the domain user logs in for the first time:\n\n"
            "  \u2022 Q-Drive / O-Drive\n"
            "  \u2022 FollowMe Printers\n"
            "  \u2022 DTUSecure WiFi\n\n"
            "Make sure 'First-Login Setup' is included in the run."
        )
        QMessageBox.information(self, "Admin Run – Deferred Modules", info_msg)

        self._run_next_queued()

    def _run_next_queued(self) -> None:
        """Run the next module in the queue."""
        if not hasattr(self, "_queued_modules") or not self._queued_modules:
            self._set_running(False)
            self.statusBar().showMessage("All modules completed.")
            self._append_log("\n═══ All modules completed ═══\n")
            return

        mod = self._queued_modules.pop(0)
        if mod.common_script:
            script = self._scripts_dir.parent / mod.script_name
        else:
            script = self._scripts_dir / mod.script_name
        if not script.exists():
            self._append_log(f"⚠ Skipping {mod.title}: script not found\n")
            self._run_next_queued()
            return

        self._set_running(True)
        self.statusBar().showMessage(f"Running: {mod.title}...")
        self._runner.run(
            script, mod.id, needs_root=mod.needs_root, env_vars=self._shared_env
        )

    def _on_module_finished(self, success: bool, module_id: str) -> None:
        """Handle module completion."""
        btn = self._module_buttons.get(module_id)
        if btn:
            color = "#d4edda" if success else "#f8d7da"
            border = "#28a745" if success else "#dc3545"
            btn.setStyleSheet(
                f"QPushButton {{ text-align: left; padding: 12px; "
                f"border: 2px solid {border}; border-radius: 8px; "
                f"font-size: 12px; background: {color}; color: #222; }}"
                f"QPushButton:hover {{ border-color: {DTU_RED}; }}"
            )

        # If we have queued modules, run the next one
        if hasattr(self, "_queued_modules") and self._queued_modules:
            self._run_next_queued()
        else:
            self._set_running(False)
            status = "completed" if success else "failed"
            self.statusBar().showMessage(f"Module '{module_id}' {status}.")

    def _on_module_failed(self, module_id: str, exit_code: int, output: str) -> None:
        """Show an ErrorDialog with diagnosis and copy-to-clipboard support."""
        mod = next((m for m in MODULES if m.id == module_id), None)
        title = mod.title if mod else module_id
        script_name = mod.script_name if mod else ""
        dlg = ErrorDialog(
            self,
            module_title=title,
            module_id=module_id,
            script_name=script_name,
            exit_code=exit_code,
            output=output,
        )
        dlg.exec()

    def _cancel_running(self) -> None:
        """Cancel the running module."""
        if hasattr(self, "_queued_modules"):
            self._queued_modules.clear()
        self._runner.cancel()
        self._set_running(False)
        self.statusBar().showMessage("Cancelled.")

    def _set_running(self, running: bool) -> None:
        """Enable/disable UI during module execution."""
        self._cancel_btn.setEnabled(running)
        self._run_all_btn.setEnabled(not running)
        for mod_id, btn in self._module_buttons.items():
            mod = next((m for m in MODULES if m.id == mod_id), None)
            if mod and not mod.enabled:
                btn.setEnabled(False)
            else:
                btn.setEnabled(not running)

    def _append_log(self, text: str) -> None:
        """Append text to the log widget."""
        self._log.moveCursor(self._log.textCursor().MoveOperation.End)
        self._log.insertPlainText(text)
        self._log.moveCursor(self._log.textCursor().MoveOperation.End)
