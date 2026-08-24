"""Main window for DTU Linux Setup."""

from __future__ import annotations

from pathlib import Path

from PyQt6.QtCore import QProcess, Qt, pyqtSignal
from PyQt6.QtGui import QFont, QIcon, QPixmap
from PyQt6.QtWidgets import (
    QComboBox,
    QFileDialog,
    QFrame,
    QGridLayout,
    QHBoxLayout,
    QLabel,
    QMainWindow,
    QMessageBox,
    QPushButton,
    QScrollArea,
    QSizePolicy,
    QTabWidget,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

from . import __version__
from .batch import (
    DEFERRED_INFO_MESSAGE,
    BatchQueue,
    admin_batch_modules,
    batch_input_type,
    user_batch_modules,
)
from .distro import Distro, detect_distro, distro_display_name, get_scripts_dir
from .env_loader import KNOWN_VARS, SECRET_VARS, EnvLoadResult, parse_env_file
from .error_dialog import ErrorDialog
from .input_dialog import DomainJoinDialog
from .module_runner import ModuleRunner
from .modules import MODULES, ModuleDef
from .prompts import collect_batch_credentials, collect_module_env
from .theme import palette


# ─── Main Window ────────────────────────────────────────────────────────────

class ModuleCard(QFrame):
    """Clickable module card with title, role badge, and description."""

    clicked = pyqtSignal()

    def __init__(self, mod: ModuleDef):
        super().__init__()
        self._last_result: bool | None = None
        pal = palette()

        self.setObjectName("moduleCard")
        self.setFixedHeight(104)
        self.setMinimumWidth(210)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self._apply_default_style()

        layout = QVBoxLayout(self)
        layout.setContentsMargins(12, 9, 12, 9)
        layout.setSpacing(4)

        title_row = QHBoxLayout()
        title_row.setContentsMargins(0, 0, 0, 0)
        title_row.setSpacing(6)

        title_label = QLabel(mod.title)
        title_label.setStyleSheet(
            f"color: {pal.text}; font-size: 13px; font-weight: 600;"
        )
        title_row.addWidget(title_label)

        badge = QLabel("ADMIN" if mod.script_type == "admin" else "USER")
        if mod.script_type == "admin":
            badge.setStyleSheet(
                f"QLabel {{ color: {pal.badge_admin}; font-size: 10px; font-weight: 700; }}"
            )
        else:
            badge.setStyleSheet(
                f"QLabel {{ color: {pal.badge_user}; font-size: 10px; font-weight: 700; }}"
            )
        title_row.addWidget(badge)
        title_row.addStretch()
        layout.addLayout(title_row)

        desc_label = QLabel(mod.description)
        desc_label.setWordWrap(True)
        desc_label.setStyleSheet(f"color: {pal.text_muted}; font-size: 11px;")
        layout.addWidget(desc_label)

    def _apply_default_style(self) -> None:
        pal = palette()
        self.setStyleSheet(
            f"QFrame {{ background: {pal.card_bg}; border: 1px solid {pal.card_border}; "
            "border-radius: 8px; }"
            "QFrame QLabel { border: none; }"
            f"QFrame:hover {{ border-color: {pal.card_hover_border}; "
            f"background: {pal.card_hover_bg}; }}"
        )

    def set_result(self, success: bool) -> None:
        """Highlight card based on latest run result."""
        self._last_result = success
        self._apply_result_style()

    def _apply_result_style(self) -> None:
        pal = palette()
        success = self._last_result
        border = pal.ok_border if success else pal.err_border
        bg = pal.ok_bg if success else pal.err_bg
        self.setStyleSheet(
            f"QFrame {{ background: {bg}; border: 2px solid {border}; border-radius: 8px; }}"
            "QFrame QLabel { border: none; }"
        )

    def setEnabled(self, enabled: bool) -> None:
        """Keep visual style aligned with enabled state, preserving the last run result."""
        super().setEnabled(enabled)
        if enabled:
            if self._last_result is not None:
                self._apply_result_style()
            else:
                self._apply_default_style()
        else:
            pal = palette()
            self.setStyleSheet(
                f"QFrame {{ background: {pal.card_disabled_bg}; "
                f"border: 1px solid {pal.card_disabled_border}; border-radius: 8px; }}"
                "QFrame QLabel { border: none; }"
            )

    def mousePressEvent(self, event) -> None:
        if self.isEnabled() and event.button() == Qt.MouseButton.LeftButton:
            self.clicked.emit()
        super().mousePressEvent(event)

class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()

        pal = palette()
        self._pal = pal

        self._distro = detect_distro()
        self._scripts_dir = get_scripts_dir(self._distro)
        self._runner = ModuleRunner(self)
        self._runner.output_received.connect(self._append_log)
        self._runner.finished.connect(self._on_module_finished)
        self._runner.failed.connect(self._on_module_failed)
        self._module_buttons: dict[str, QWidget] = {}
        self._module_tab_for_mod: dict[str, str] = {}
        # Pre-loaded answers from an env file (see _load_env_file).
        self._env_overrides: dict[str, str] = {}
        self._env_source: Path | None = None
        self._batch = BatchQueue()

        self.setWindowTitle("DTU Linux Setup")
        self.setMinimumSize(800, 700)

        # Try to set window icon
        icon_path = self._find_icon()
        if icon_path:
            self.setWindowIcon(QIcon(str(icon_path)))

        central = QWidget()
        self.setCentralWidget(central)
        main_layout = QVBoxLayout(central)
        main_layout.setSpacing(14)
        main_layout.setContentsMargins(22, 22, 22, 22)
        central.setStyleSheet(f"background: {pal.window_bg};")

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
        title_label.setStyleSheet(f"color: {pal.accent_text};")
        title_block.addWidget(title_label)

        distro_label = QLabel(f"Detected: {distro_display_name()}")
        distro_label.setStyleSheet(f"color: {pal.text_dim}; font-size: 12px;")
        title_block.addWidget(distro_label)

        version_label = QLabel(f"Version: {__version__}")
        version_label.setStyleSheet(f"color: {pal.text_dim}; font-size: 12px;")
        title_block.addWidget(version_label)
        header.addLayout(title_block)

        header.addStretch()

        right_block = QVBoxLayout()
        right_block.setSpacing(6)

        self._update_btn = QPushButton("Update to latest version")
        self._update_btn.setToolTip(
            "Download the newest release from GitHub, remove the old installation, and reinstall."
        )
        self._update_btn.setStyleSheet(
            f"QPushButton {{ background: {pal.accent}; color: {pal.accent_fg}; "
            "font-weight: bold; padding: 8px 14px; border-radius: 6px; font-size: 12px; }"
            f"QPushButton:hover {{ background: {pal.accent_hover}; }}"
            f"QPushButton:disabled {{ background: {pal.btn_disabled_bg}; "
            f"color: {pal.btn_disabled_fg}; }}"
        )
        self._update_btn.clicked.connect(self._update_latest_version)
        right_block.addWidget(self._update_btn)

        # Department selector
        self._dept_combo = QComboBox()
        self._dept_combo.addItem("DTU Sustain", "sustain")
        self._dept_combo.addItem("DTU AIT", "ait")
        self._dept_combo.setMinimumWidth(160)
        self._dept_combo.setStyleSheet(
            f"QComboBox {{ font-size: 13px; padding: 5px 10px; "
            f"border: 2px solid {pal.input_border}; border-radius: 6px; "
            f"background: {pal.input_bg}; color: {pal.input_text}; }} "
            f"QComboBox QAbstractItemView {{ background: {pal.input_bg}; "
            f"color: {pal.input_text}; selection-background-color: {pal.selection_bg}; "
            f"selection-color: {pal.selection_text}; }} "
            f"QComboBox:focus {{ border-color: {pal.accent_text}; }}"
        )
        right_block.addWidget(self._dept_combo, alignment=Qt.AlignmentFlag.AlignRight)
        header.addLayout(right_block)

        main_layout.addLayout(header)

        # ── Distro warning ──────────────────────────────────────────────
        if self._distro == Distro.UNKNOWN:
            warn_label = QLabel(
                "⚠️ Unsupported distribution detected! "
                "This tool supports Ubuntu 24.04 and openSUSE Tumbleweed."
            )
            warn_label.setStyleSheet(
                f"background: {pal.warn_bg}; color: {pal.warn_fg}; padding: 8px; "
                f"border: 1px solid {pal.warn_border}; border-radius: 4px;"
            )
            warn_label.setWordWrap(True)
            main_layout.addWidget(warn_label)

        section_label = QLabel("Modules")
        section_label.setStyleSheet(
            f"color: {pal.accent_text}; font-size: 15px; font-weight: 700; margin-top: 4px;"
        )
        main_layout.addWidget(section_label)

        # ── Module grid tabs ────────────────────────────────────────────
        self._module_tabs = QTabWidget()
        self._module_tabs.setStyleSheet(
            f"QTabWidget::pane {{ border: 1px solid {pal.tab_border}; border-radius: 8px; "
            f"background: {pal.panel_bg}; }}"
            f"QTabBar::tab {{ background: {pal.tab_bg}; color: {pal.tab_text}; "
            f"padding: 7px 14px; border: 1px solid {pal.tab_border}; border-bottom: none; "
            "border-top-left-radius: 8px; border-top-right-radius: 8px; font-weight: 500; }"
            f"QTabBar::tab:selected {{ background: {pal.tab_selected_bg}; "
            f"color: {pal.accent_text}; font-weight: 600; }}"
            f"QTabBar::tab:!selected:hover {{ background: {pal.tab_hover_bg}; }}"
        )

        self._module_containers: dict[str, QWidget] = {}
        self._module_grids: dict[str, QGridLayout] = {}

        for key, title in (("admin", "Admin Scripts"), ("user", "User Scripts")):
            tab = QWidget()
            tab_layout = QVBoxLayout(tab)
            tab_layout.setContentsMargins(8, 8, 8, 8)

            container = QWidget()
            grid = QGridLayout(container)
            grid.setHorizontalSpacing(12)
            grid.setVerticalSpacing(12)
            self._module_containers[key] = container
            self._module_grids[key] = grid

            scroll = QScrollArea()
            scroll.setWidgetResizable(True)
            scroll.setFrameShape(scroll.Shape.NoFrame)
            scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
            scroll.setWidget(container)
            tab_layout.addWidget(scroll)
            self._module_tabs.addTab(tab, title)

        for mod in MODULES:
            btn = self._create_module_button(mod)
            if not mod.enabled:
                btn.setEnabled(False)
                btn.setToolTip("This module has been disabled.")
            self._module_buttons[mod.id] = btn
            self._module_tab_for_mod[mod.id] = mod.script_type

        main_layout.addWidget(self._module_tabs, 1)
        self._rebuild_module_grid()
        self._module_tabs.currentChanged.connect(self._update_run_all_button_label)

        # ── Action bar ──────────────────────────────────────────────────
        action_bar = QHBoxLayout()

        run_all_btn = QPushButton("▶  Run All Admin Modules")
        run_all_btn.setStyleSheet(
            f"QPushButton {{ background: {pal.accent}; color: {pal.accent_fg}; "
            "font-weight: 700; padding: 9px 18px; border-radius: 8px; font-size: 13px; "
            f"border: 1px solid {pal.accent_hover}; }}"
            f"QPushButton:hover {{ background: {pal.accent_hover}; }}"
            "QPushButton:pressed { padding-top: 11px; padding-bottom: 9px; }"
            f"QPushButton:disabled {{ background: {pal.btn_disabled_bg}; "
            f"color: {pal.btn_disabled_fg}; border-color: {pal.btn_disabled_border}; }}"
        )
        run_all_btn.clicked.connect(self._run_all_for_active_tab)
        self._run_all_btn = run_all_btn
        self._update_run_all_button_label()
        action_bar.addWidget(run_all_btn)

        load_env_btn = QPushButton("☰  Load env file…")
        load_env_btn.setToolTip(
            "Pre-fill prompts from a KEY=VALUE file (DTU_HOSTNAME, DTU_USERNAME, …).\n"
            "Modules with all required variables already set will not show input dialogs."
        )
        load_env_btn.setStyleSheet(
            "QPushButton { padding: 9px 14px; border-radius: 8px; font-size: 13px; "
            f"background: {pal.btn_bg}; color: {pal.btn_text}; "
            f"border: 1px solid {pal.btn_border}; font-weight: 600; }}"
            f"QPushButton:hover {{ background: {pal.btn_hover_bg}; }}"
            "QPushButton:pressed { padding-top: 11px; padding-bottom: 9px; }"
        )
        load_env_btn.clicked.connect(self._load_env_file)
        action_bar.addWidget(load_env_btn)

        action_bar.addStretch()

        cancel_btn = QPushButton("Cancel")
        cancel_btn.setEnabled(False)
        cancel_btn.setStyleSheet(
            "QPushButton { padding: 9px 18px; border-radius: 8px; font-size: 13px; "
            f"background: {pal.btn_bg}; color: {pal.btn_text}; "
            f"border: 1px solid {pal.btn_border}; font-weight: 600; }}"
            f"QPushButton:hover {{ background: {pal.btn_hover_bg}; }}"
            "QPushButton:pressed { padding-top: 11px; padding-bottom: 9px; }"
            f"QPushButton:disabled {{ background: {pal.btn_disabled_bg}; "
            f"color: {pal.btn_disabled_fg}; border-color: {pal.btn_disabled_border}; }}"
        )
        cancel_btn.clicked.connect(self._cancel_running)
        self._cancel_btn = cancel_btn
        action_bar.addWidget(cancel_btn)

        main_layout.addLayout(action_bar)

        # ── Log output ──────────────────────────────────────────────────
        log_label = QLabel("Output Log:")
        log_label.setStyleSheet(
            f"color: {pal.text}; font-weight: bold; font-size: 13px; margin-top: 8px;"
        )
        main_layout.addWidget(log_label)

        self._log = QTextEdit()
        self._log.setReadOnly(True)
        self._log.setFont(QFont("Monospace", 10))
        self._log.setStyleSheet(
            f"background: {pal.console_bg}; color: {pal.console_fg}; "
            f"border: 1px solid {pal.console_border}; border-radius: 6px; padding: 8px;"
        )
        self._log.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        main_layout.addWidget(self._log)

        # ── Status bar ──────────────────────────────────────────────────
        self.statusBar().showMessage("Ready")

        # Auto-detect department from installed site config.
        self._auto_detect_department()

    def _auto_detect_department(self) -> None:
        """Read DTU_DEPARTMENT from /etc/dtu-setup/site.conf and sync the dropdown."""
        site_conf = Path("/etc/dtu-setup/site.conf")
        if not site_conf.exists():
            return
        result = parse_env_file(site_conf)
        dept = result.values.get("DTU_DEPARTMENT", "").lower()
        if dept in {"sustain", "ait"}:
            idx = self._dept_combo.findData(dept)
            if idx >= 0:
                self._dept_combo.setCurrentIndex(idx)

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

    def _create_module_button(self, mod: ModuleDef) -> QWidget:
        """Create a styled card for a module."""
        card = ModuleCard(mod)
        card.clicked.connect(lambda m=mod: self._run_module(m))
        return card

    def _rebuild_module_grid(self) -> None:
        """Rebuild tabbed module grids with responsive column count."""
        if not hasattr(self, "_module_grids"):
            return

        for tab_key, grid in self._module_grids.items():
            for btn in self._module_buttons.values():
                grid.removeWidget(btn)

            available_width = max(320, self._module_containers[tab_key].width() - 12)
            preferred_card_width = 300
            max_columns = 3
            columns = max(1, min(max_columns, available_width // preferred_card_width))

            tab_modules = [
                m for m in MODULES if self._module_tab_for_mod.get(m.id) == tab_key
            ]
            for i, mod in enumerate(tab_modules):
                btn = self._module_buttons[mod.id]
                row, col = divmod(i, columns)
                grid.addWidget(btn, row, col)

            for col in range(columns):
                grid.setColumnStretch(col, 1)

    def resizeEvent(self, event) -> None:
        """Keep module layout tidy when window size changes."""
        super().resizeEvent(event)
        self._rebuild_module_grid()

    def _active_script_tab(self) -> str:
        """Return active module tab key."""
        return "user" if self._module_tabs.currentIndex() == 1 else "admin"

    def _update_run_all_button_label(self) -> None:
        """Sync the run-all button text with the active scripts tab."""
        if not hasattr(self, "_run_all_btn"):
            return
        if self._active_script_tab() == "user":
            self._run_all_btn.setText("▶  Run All User Scripts")
        else:
            self._run_all_btn.setText("▶  Run All Admin Modules")

    def _run_all_for_active_tab(self) -> None:
        """Run all modules from the currently selected scripts tab."""
        if self._active_script_tab() == "user":
            self._run_all_user()
        else:
            self._run_all_admin()

    def _run_module(self, mod: ModuleDef) -> None:
        """Collect input and start a module."""
        if self._runner.is_running():
            QMessageBox.warning(
                self, "Busy", "A module is already running. Wait for it to finish or cancel it."
            )
            return

        script = self._resolve_script_path(mod)
        if not script.exists():
            QMessageBox.critical(
                self, "Script Missing",
                f"Script not found:\n{script}\n\nIs the correct distro detected?",
            )
            return

        env_vars = collect_module_env(self, mod, self._env_overrides, script)
        if env_vars is None:
            return

        env_vars["DTU_DEPARTMENT"] = self._dept_combo.currentData()
        self._set_running(True)
        self.statusBar().showMessage(f"Running: {mod.title}...")
        self._runner.run(
            script, mod.id, needs_root=mod.needs_root, env_vars=env_vars
        )

    def _update_latest_version(self) -> None:
        """Download and install the latest GitHub release."""
        if self._runner.is_running():
            QMessageBox.warning(
                self, "Busy", "A module is already running. Wait for it to finish or cancel it."
            )
            return

        update_script = self._scripts_dir.parent / "update-latest.sh"
        if not update_script.exists():
            QMessageBox.critical(
                self,
                "Update Script Missing",
                f"Update script not found:\n{update_script}\n\nIs the installation complete?",
            )
            return

        confirm = QMessageBox.question(
            self,
            "Update to latest version",
            "This will download the latest release from GitHub, remove the current installation, and reinstall the app.\n\nContinue?",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,
        )
        if confirm != QMessageBox.StandardButton.Yes:
            return

        self._set_running(True)
        self.statusBar().showMessage("Running: Update to latest version...")
        self._runner.run(
            update_script,
            "update-latest",
            needs_root=True,
            env_vars={"DTU_DEPARTMENT": self._dept_combo.currentData()},
        )

    def _run_all_admin(self) -> None:
        """Queue all admin modules (runs them sequentially).

        Which modules are deferred, and why, lives in batch.py.
        """
        if self._runner.is_running():
            QMessageBox.warning(self, "Busy", "A module is already running.")
            return

        # Collect admin info for Domain Join
        host = self._env_overrides.get("DTU_HOSTNAME", "")
        admin_user = self._env_overrides.get("DTU_ADMIN_USERNAME", "")
        if host and admin_user:
            admin_result = (host, admin_user)
        else:
            admin_dlg = DomainJoinDialog(self)
            if host:
                admin_dlg.hostname_edit.setText(host)
            if admin_user:
                admin_dlg.username_edit.setText(admin_user)
            admin_result = admin_dlg.get_domain_join_info()
            if admin_result is None:
                return

        self._batch.start(
            admin_batch_modules(MODULES),
            {
                "DTU_HOSTNAME": admin_result[0],
                "DTU_ADMIN_USERNAME": admin_result[1],
                "DTU_DEPARTMENT": self._dept_combo.currentData(),
            },
            is_admin_run=True,
        )

        QMessageBox.information(
            self, "Admin Run – Deferred Modules", DEFERRED_INFO_MESSAGE
        )

        self._run_next_queued()

    def _run_all_user(self) -> None:
        """Queue all user scripts (runs them sequentially)."""
        if self._runner.is_running():
            QMessageBox.warning(self, "Busy", "A module is already running.")
            return

        user_modules = user_batch_modules(MODULES)
        if not user_modules:
            QMessageBox.information(self, "No user scripts", "No enabled user scripts found.")
            return

        shared_env: dict[str, str] = {"DTU_DEPARTMENT": self._dept_combo.currentData()}

        needed = batch_input_type(user_modules)
        collected = collect_batch_credentials(
            self,
            needed,
            self._env_overrides,
            message=(
                "Enter your WIN domain credentials for User Scripts "
                "(Network Drives / Printers)."
                if needed == "credentials"
                else "Enter the target username for User Scripts "
                "(e.g. Repair Home Folders):"
            ),
        )
        if collected is None:
            return
        shared_env.update(collected)

        self._batch.start(user_modules, shared_env, is_admin_run=False)
        self._run_next_queued()

    def _run_next_queued(self) -> None:
        """Run the next module in the queue."""
        mod = self._batch.pop_next()
        if mod is None:
            self._set_running(False)
            self.statusBar().showMessage("All modules completed.")
            self._append_log("\n═══ All modules completed ═══\n")
            prompt_reboot = self._batch.should_prompt_reboot()
            self._batch.reset()
            if prompt_reboot:
                self._prompt_reboot_after_admin_run()
            return

        script = self._resolve_script_path(mod)
        if not script.exists():
            self._append_log(f"⚠ Skipping {mod.title}: script not found\n")
            self._run_next_queued()
            return

        self._set_running(True)
        self.statusBar().showMessage(f"Running: {mod.title}...")
        self._runner.run(
            script, mod.id, needs_root=mod.needs_root, env_vars=self._batch.shared_env
        )

    def _on_module_finished(self, success: bool, module_id: str) -> None:
        """Handle module completion."""
        btn = self._module_buttons.get(module_id)
        if isinstance(btn, ModuleCard):
            btn.set_result(success)

        # If we have queued modules, run the next one
        if self._batch.has_pending():
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
        self._batch.cancel()
        self._runner.cancel()
        self._set_running(False)
        self.statusBar().showMessage("Cancelled.")

    def _prompt_reboot_after_admin_run(self) -> None:
        """Offer reboot after completing the admin batch run."""
        answer = QMessageBox.question(
            self,
            "Run All Completed",
            "Run All Admin Modules is finished.\n\nDo you want to reboot the computer now?",
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
            QMessageBox.StandardButton.No,
        )
        if answer != QMessageBox.StandardButton.Yes:
            return

        started = QProcess.startDetached("pkexec", ["systemctl", "reboot"])
        if not started:
            QMessageBox.warning(
                self,
                "Reboot failed",
                "Could not start reboot automatically. Please reboot manually.",
            )

    def _set_running(self, running: bool) -> None:
        """Enable/disable UI during module execution."""
        self._cancel_btn.setEnabled(running)
        self._run_all_btn.setEnabled(not running)
        self._update_btn.setEnabled(not running)
        for mod_id, btn in self._module_buttons.items():
            mod = next((m for m in MODULES if m.id == mod_id), None)
            if mod and not mod.enabled:
                btn.setEnabled(False)
            else:
                btn.setEnabled(not running)

    def _resolve_script_path(self, mod: ModuleDef) -> Path:
        """Resolve script location based on module type."""
        if mod.common_script:
            return self._scripts_dir.parent / mod.script_name
        return self._scripts_dir / mod.script_name

    def _load_env_file(self) -> None:
        """Open a file picker, parse a KEY=VALUE env file and pre-fill prompts."""
        if self._runner.is_running():
            QMessageBox.warning(
                self, "Busy", "A module is running. Wait for it to finish first."
            )
            return

        # Build a guided 'what is this' message before the file picker.
        known_list = "\n".join(
            f"  • {k}" + ("  (sensitive)" if k in SECRET_VARS else "")
            for k in KNOWN_VARS
        )
        proceed = QMessageBox.question(
            self,
            "Load env file",
            "Pick a plain-text env file with KEY=VALUE lines (shell-style).\n"
            "Lines starting with # are ignored. The 'export ' prefix is allowed.\n\n"
            "Recognised variables:\n"
            f"{known_list}\n\n"
            "Modules with all required variables already set will run without prompts.\n"
            "Continue?",
            QMessageBox.StandardButton.Ok | QMessageBox.StandardButton.Cancel,
        )
        if proceed != QMessageBox.StandardButton.Ok:
            return

        path_str, _ = QFileDialog.getOpenFileName(
            self,
            "Select env file",
            "",
            "Env files (*.env *.conf *.cfg);;All files (*)",
        )
        if not path_str:
            return

        result: EnvLoadResult = parse_env_file(Path(path_str))
        if result.errors and not result.values:
            QMessageBox.critical(self, "Env file – parse failed", result.summary())
            return

        # Build summary before modifying result.values so DTU_DEPARTMENT is visible.
        summary = result.summary()

        # Sync the department dropdown if the file specifies one.
        dept = result.values.get("DTU_DEPARTMENT", "").lower()
        if dept in {"sustain", "ait"}:
            idx = self._dept_combo.findData(dept)
            if idx >= 0:
                self._dept_combo.setCurrentIndex(idx)

        # Strip DTU_DEPARTMENT from overrides because it comes from the dropdown.
        result.values.pop("DTU_DEPARTMENT", None)
        self._env_overrides = result.values
        self._env_source = result.path

        QMessageBox.information(
            self,
            "Env file loaded",
            summary
            + "\n\nNote: SITE_* variables (site configuration) are read directly "
            "by scripts from /etc/dtu-setup/site.conf and are not shown here.\n\n"
            "These values will be used to skip input dialogs.\n"
            "Click 'Load env file…' again to load a different file.",
        )
        self.statusBar().showMessage(
            f"Env loaded: {result.path.name} ({len(result.values)} vars)"
        )
        self._append_log(
            f"\n[env] Loaded {len(result.values)} variable(s) from {result.path}\n"
        )

    def _append_log(self, text: str) -> None:
        """Append text to the log widget."""
        self._log.moveCursor(self._log.textCursor().MoveOperation.End)
        self._log.insertPlainText(text)
        self._log.moveCursor(self._log.textCursor().MoveOperation.End)
