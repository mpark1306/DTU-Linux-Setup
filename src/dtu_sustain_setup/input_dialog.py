"""Input dialogs for collecting credentials from the user."""

from __future__ import annotations

import socket
from pathlib import Path

from PyQt6.QtCore import Qt
from PyQt6.QtGui import QFont
from PyQt6.QtWidgets import (
    QDialog,
    QDialogButtonBox,
    QFileDialog,
    QFormLayout,
    QHBoxLayout,
    QInputDialog,
    QLabel,
    QLineEdit,
    QListWidget,
    QListWidgetItem,
    QMessageBox,
    QPushButton,
    QTabWidget,
    QVBoxLayout,
    QWidget,
)


class CredentialDialog(QDialog):
    """Dialog that collects username and password."""

    def __init__(
        self,
        parent=None,
        *,
        title: str = "Credentials",
        message: str = "Enter your DTU domain credentials:",
        need_password: bool = True,
        password_label: str = "Password:",
    ):
        super().__init__(parent)
        self.setWindowTitle(title)
        self.setMinimumWidth(400)

        layout = QVBoxLayout(self)

        msg_label = QLabel(message)
        msg_label.setWordWrap(True)
        layout.addWidget(msg_label)

        form = QFormLayout()

        self.username_edit = QLineEdit()
        self.username_edit.setPlaceholderText("e.g. mpark")
        form.addRow("Username:", self.username_edit)

        self.password_edit = QLineEdit()
        self.password_edit.setEchoMode(QLineEdit.EchoMode.Password)
        self.password_edit.setPlaceholderText("Domain password")
        if need_password:
            form.addRow(password_label, self.password_edit)

        self._need_password = need_password
        layout.addLayout(form)

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel
        )
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def get_credentials(self) -> tuple[str, str] | None:
        """Show dialog and return (username, password) or None if cancelled."""
        if self.exec() == QDialog.DialogCode.Accepted:
            username = self.username_edit.text().strip()
            password = self.password_edit.text() if self._need_password else ""
            if not username:
                return None
            return (username, password)
        return None


class UsernameDialog(QDialog):
    """Dialog that collects only a username (no password)."""

    def __init__(
        self,
        parent=None,
        *,
        title: str = "Username",
        message: str = "Enter the target username:",
    ):
        super().__init__(parent)
        self.setWindowTitle(title)
        self.setMinimumWidth(400)

        layout = QVBoxLayout(self)

        msg_label = QLabel(message)
        msg_label.setWordWrap(True)
        layout.addWidget(msg_label)

        form = QFormLayout()
        self.username_edit = QLineEdit()
        self.username_edit.setPlaceholderText("e.g. mpark")
        form.addRow("Username:", self.username_edit)
        layout.addLayout(form)

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel
        )
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def get_username(self) -> str | None:
        """Show dialog and return username or None if cancelled."""
        if self.exec() == QDialog.DialogCode.Accepted:
            username = self.username_edit.text().strip()
            return username if username else None
        return None


class DomainJoinDialog(QDialog):
    """Dialog that collects hostname and admin username for domain join."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Domain Join – WIN.DTU.DK")
        self.setMinimumWidth(450)

        layout = QVBoxLayout(self)

        msg_label = QLabel(
            "Enter the new hostname and domain admin username.\n"
            "A terminal window will open for you to enter the password."
        )
        msg_label.setWordWrap(True)
        layout.addWidget(msg_label)

        form = QFormLayout()

        self.hostname_edit = QLineEdit()
        current = socket.gethostname()
        self.hostname_edit.setText(current)
        self.hostname_edit.setPlaceholderText("e.g. DTU-SUS-PC01")
        form.addRow("Hostname:", self.hostname_edit)

        self.username_edit = QLineEdit()
        self.username_edit.setPlaceholderText("e.g. adm-<username>")
        form.addRow("Admin Username:", self.username_edit)

        layout.addLayout(form)

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel
        )
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def get_domain_join_info(self) -> tuple[str, str] | None:
        """Show dialog and return (hostname, username) or None."""
        if self.exec() == QDialog.DialogCode.Accepted:
            hostname = self.hostname_edit.text().strip()
            username = self.username_edit.text().strip()
            if not hostname or not username:
                return None
            return (hostname, username)
        return None


class PasswordDialog(QDialog):
    """Dialog that collects only a password."""

    def __init__(
        self,
        parent=None,
        *,
        title: str = "Password",
        message: str = "Enter the password:",
        password_label: str = "Password:",
    ):
        super().__init__(parent)
        self.setWindowTitle(title)
        self.setMinimumWidth(400)

        layout = QVBoxLayout(self)

        msg_label = QLabel(message)
        msg_label.setWordWrap(True)
        layout.addWidget(msg_label)

        form = QFormLayout()
        self.password_edit = QLineEdit()
        self.password_edit.setEchoMode(QLineEdit.EchoMode.Password)
        self.password_edit.setPlaceholderText("Password")
        form.addRow(password_label, self.password_edit)
        layout.addLayout(form)

        buttons = QDialogButtonBox(
            QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel
        )
        buttons.accepted.connect(self.accept)
        buttons.rejected.connect(self.reject)
        layout.addWidget(buttons)

    def get_password(self) -> str | None:
        """Show dialog and return password or None if cancelled."""
        if self.exec() == QDialog.DialogCode.Accepted:
            password = self.password_edit.text()
            return password if password else None
        return None


# ─── Software Configuration ─────────────────────────────────────────────────

def _find_software_conf() -> Path:
    """Locate data/software.conf relative to the project."""
    candidates = [
        Path(__file__).resolve().parent.parent.parent / "data" / "software.conf",
        Path("/opt/dtu-sustain-setup/data/software.conf"),
    ]
    for p in candidates:
        if p.exists():
            return p
    # Fallback: create in project tree
    return candidates[0]


def _parse_software_conf(path: Path) -> dict[str, list[str]]:
    """Parse software.conf and return {section: [packages]}."""
    sections: dict[str, list[str]] = {"flatpak": [], "snap": [], "cisco": []}
    current_section = ""
    if not path.exists():
        return sections
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current_section = line[1:-1].lower()
            if current_section not in sections:
                sections[current_section] = []
        elif current_section:
            sections[current_section].append(line)
    return sections


def _write_software_conf(path: Path, sections: dict[str, list[str]]) -> None:
    """Write sections back to software.conf."""
    lines = [
        "# DTU Sustain Setup – Software Configuration",
        "# Lines starting with # are comments. Empty lines are ignored.",
        "#",
        "# Format:",
        "#   [section]",
        "#   package_id",
        "#",
        "# Sections: flatpak, snap, cisco",
        "",
    ]
    for section_name in ("flatpak", "snap", "cisco"):
        pkgs = sections.get(section_name, [])
        lines.append(f"[{section_name}]")
        for pkg in pkgs:
            lines.append(pkg)
        lines.append("")
    path.write_text("\n".join(lines) + "\n")


class SoftwareDialog(QDialog):
    """Dialog to view, add, and edit the software package list."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("Software – Manage Packages")
        self.setMinimumSize(520, 450)

        self._conf_path = _find_software_conf()
        self._sections = _parse_software_conf(self._conf_path)

        layout = QVBoxLayout(self)

        info = QLabel(
            "Manage which software packages will be installed.\n"
            "Add, remove or edit entries, then click Install to run the installation."
        )
        info.setWordWrap(True)
        layout.addWidget(info)

        # Tab widget for each section
        self._tabs = QTabWidget()
        self._lists: dict[str, QListWidget] = {}
        section_labels = {"flatpak": "Flatpak", "snap": "Snap", "cisco": "Cisco"}

        for section_key in ("flatpak", "snap", "cisco"):
            tab = QWidget()
            tab_layout = QVBoxLayout(tab)

            list_widget = QListWidget()
            list_widget.setFont(QFont("Monospace", 10))
            for pkg in self._sections.get(section_key, []):
                list_widget.addItem(QListWidgetItem(pkg))
            tab_layout.addWidget(list_widget)
            self._lists[section_key] = list_widget

            btn_row = QHBoxLayout()

            add_btn = QPushButton("+ Add")
            add_btn.clicked.connect(lambda _, s=section_key: self._add_package(s))
            btn_row.addWidget(add_btn)

            edit_btn = QPushButton("✏ Edit")
            edit_btn.clicked.connect(lambda _, s=section_key: self._edit_package(s))
            btn_row.addWidget(edit_btn)

            remove_btn = QPushButton("− Remove")
            remove_btn.clicked.connect(lambda _, s=section_key: self._remove_package(s))
            btn_row.addWidget(remove_btn)

            tab_layout.addLayout(btn_row)
            self._tabs.addTab(tab, section_labels.get(section_key, section_key))

        layout.addWidget(self._tabs)

        # Cisco tarball path
        cisco_row = QHBoxLayout()
        cisco_label = QLabel("Cisco tarball (.tar.gz):")
        cisco_row.addWidget(cisco_label)

        self._cisco_path_edit = QLineEdit()
        self._cisco_path_edit.setPlaceholderText("Optional – auto-detected from repo root if empty")
        cisco_row.addWidget(self._cisco_path_edit)

        browse_btn = QPushButton("Browse…")
        browse_btn.clicked.connect(self._browse_cisco_tarball)
        cisco_row.addWidget(browse_btn)

        layout.addLayout(cisco_row)

        # Bottom buttons
        bottom = QHBoxLayout()
        save_btn = QPushButton("Save")
        save_btn.setToolTip("Save changes without installing")
        save_btn.clicked.connect(self._save)
        bottom.addWidget(save_btn)

        bottom.addStretch()

        install_btn = QPushButton("Save && Install")
        install_btn.setStyleSheet(
            "QPushButton { background: #990000; color: white; font-weight: bold; "
            "padding: 8px 16px; border-radius: 6px; }"
            "QPushButton:hover { background: #7a0000; }"
        )
        install_btn.clicked.connect(self._save_and_install)
        bottom.addWidget(install_btn)

        cancel_btn = QPushButton("Cancel")
        cancel_btn.clicked.connect(self.reject)
        bottom.addWidget(cancel_btn)

        layout.addLayout(bottom)

    def _add_package(self, section: str) -> None:
        text, ok = QInputDialog.getText(
            self, "Add Package", f"Enter package ID for [{section}]:"
        )
        if ok and text.strip():
            self._lists[section].addItem(QListWidgetItem(text.strip()))

    def _edit_package(self, section: str) -> None:
        lw = self._lists[section]
        item = lw.currentItem()
        if item is None:
            QMessageBox.information(self, "Edit", "Select a package first.")
            return
        text, ok = QInputDialog.getText(
            self, "Edit Package", "Package ID:", text=item.text()
        )
        if ok and text.strip():
            item.setText(text.strip())

    def _remove_package(self, section: str) -> None:
        lw = self._lists[section]
        row = lw.currentRow()
        if row < 0:
            QMessageBox.information(self, "Remove", "Select a package first.")
            return
        lw.takeItem(row)

    def _browse_cisco_tarball(self) -> None:
        path, _ = QFileDialog.getOpenFileName(
            self,
            "Select Cisco Secure Client tarball",
            "",
            "Tarballs (*.tar.gz);;All Files (*)",
        )
        if path:
            self._cisco_path_edit.setText(path)

    def _collect_sections(self) -> dict[str, list[str]]:
        result: dict[str, list[str]] = {}
        for section_key, lw in self._lists.items():
            pkgs = []
            for i in range(lw.count()):
                txt = lw.item(i).text().strip()
                if txt:
                    pkgs.append(txt)
            result[section_key] = pkgs
        return result

    def _save(self) -> None:
        self._sections = self._collect_sections()
        _write_software_conf(self._conf_path, self._sections)
        QMessageBox.information(self, "Saved", f"Configuration saved to:\n{self._conf_path}")

    def _save_and_install(self) -> None:
        self._sections = self._collect_sections()
        _write_software_conf(self._conf_path, self._sections)
        self.accept()

    def get_software_config(self) -> tuple[Path, str] | None:
        """Show dialog. Returns (config_path, cisco_tarball_path) if user clicked Install, None if cancelled."""
        if self.exec() == QDialog.DialogCode.Accepted:
            return (self._conf_path, self._cisco_path_edit.text().strip())
        return None
