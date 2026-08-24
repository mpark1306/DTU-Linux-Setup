"""Readiness dialog for the TPM2 auto-unlock module.

TPM2 unlocking has preconditions the user cannot do anything about from inside
this application — the TPM has to be enabled in firmware, the disk has to have
been encrypted at install time, and Secure Boot has to be in its final state
*before* enrollment rather than after. Getting any of them wrong shows up as a
failed module run, or worse, as a machine that stops unlocking after the next
firmware update.

So the checks are shown before the run, not explained afterwards in a log.

The list of what matters lives in tpm2-enroll.sh --check, not here. One place
has to know what TPM2 unlocking requires, and if that place were duplicated in
Python the copy in the GUI would be the one that goes stale.
"""

from __future__ import annotations

import shutil
from pathlib import Path

from PyQt6.QtCore import QProcess, Qt
from PyQt6.QtWidgets import (
    QDialog,
    QDialogButtonBox,
    QFrame,
    QHBoxLayout,
    QLabel,
    QPushButton,
    QScrollArea,
    QVBoxLayout,
    QWidget,
)

from .theme import palette

# Prefix written by tpm2-enroll.sh --check.
_MARKER = "TPM2CHECK|"


class CheckItem:
    """One line of output from --check."""

    __slots__ = ("id", "status", "title", "detail", "fix")

    def __init__(self, id: str, status: str, title: str, detail: str, fix: str):
        self.id = id
        self.status = status
        self.title = title
        self.detail = detail
        self.fix = fix

    @classmethod
    def parse(cls, line: str) -> "CheckItem | None":
        if not line.startswith(_MARKER):
            return None
        # Split into exactly 5 fields; the script replaces any | inside the
        # text fields, so a longer split means the format changed.
        parts = line[len(_MARKER):].rstrip("\n").split("|")
        if len(parts) < 5:
            return None
        return cls(parts[0], parts[1], parts[2], parts[3], "|".join(parts[4:]))

    @property
    def blocks(self) -> bool:
        """Whether this stops enrollment from being worth attempting."""
        return self.status == "fail"


_ICONS = {"ok": "✓", "warn": "!", "fail": "✕", "info": "·", "unknown": "?"}


def _colour_for(status: str) -> tuple[str, str]:
    """(foreground, border) for a status, from the active palette."""
    pal = palette()
    return {
        "ok": (pal.ok_border, pal.ok_border),
        "warn": (pal.warn_fg, pal.warn_border),
        "fail": (pal.err_border, pal.err_border),
        "info": (pal.text_muted, pal.card_border),
        "unknown": (pal.text_muted, pal.card_border),
    }.get(status, (pal.text_muted, pal.card_border))


class Tpm2ReadinessDialog(QDialog):
    """Runs tpm2-enroll.sh --check and shows what is and is not in place."""

    def __init__(self, parent, script_path: Path, luks_device: str = ""):
        super().__init__(parent)
        self._script = script_path
        self._luks_device = luks_device
        self._items: list[CheckItem] = []
        self._buffer = ""
        self._proc: QProcess | None = None
        self._ran_privileged = False
        self._proceed = False

        pal = palette()
        self.setWindowTitle("TPM2 Auto-Unlock – forudsætninger")
        self.setMinimumSize(680, 520)
        self.setStyleSheet(f"background: {pal.window_bg};")

        layout = QVBoxLayout(self)
        layout.setSpacing(12)
        layout.setContentsMargins(20, 20, 20, 20)

        heading = QLabel("Kan denne maskine bruge TPM2 auto-unlock?")
        heading.setStyleSheet(
            f"color: {pal.accent_text}; font-size: 16px; font-weight: 700;"
        )
        layout.addWidget(heading)

        self._subtitle = QLabel("Kontrollerer…")
        self._subtitle.setWordWrap(True)
        self._subtitle.setStyleSheet(f"color: {pal.text_muted}; font-size: 12px;")
        layout.addWidget(self._subtitle)

        self._list_host = QWidget()
        self._list_layout = QVBoxLayout(self._list_host)
        self._list_layout.setContentsMargins(0, 0, 0, 0)
        self._list_layout.setSpacing(8)
        self._list_layout.addStretch()

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        scroll.setWidget(self._list_host)
        layout.addWidget(scroll, 1)

        # ── Buttons ────────────────────────────────────────────────────────
        bar = QHBoxLayout()

        self._elevate_btn = QPushButton("Kontrollér resten med rettigheder")
        self._elevate_btn.setToolTip(
            "Nogle punkter kan kun aflæses som administrator: om disken allerede\n"
            "er bundet til TPM'en, og om clevis er i initramfs."
        )
        self._elevate_btn.setStyleSheet(
            "QPushButton { padding: 8px 14px; border-radius: 6px; font-size: 12px; "
            f"background: {pal.btn_bg}; color: {pal.btn_text}; "
            f"border: 1px solid {pal.btn_border}; font-weight: 600; }}"
            f"QPushButton:hover {{ background: {pal.btn_hover_bg}; }}"
            f"QPushButton:disabled {{ background: {pal.btn_disabled_bg}; "
            f"color: {pal.btn_disabled_fg}; border-color: {pal.btn_disabled_border}; }}"
        )
        self._elevate_btn.setEnabled(False)
        self._elevate_btn.clicked.connect(lambda: self._run(privileged=True))
        bar.addWidget(self._elevate_btn)

        bar.addStretch()

        self._proceed_btn = QPushButton("Fortsæt")
        self._proceed_btn.setStyleSheet(
            f"QPushButton {{ background: {pal.accent}; color: {pal.accent_fg}; "
            "font-weight: 700; padding: 8px 18px; border-radius: 6px; font-size: 12px; }"
            f"QPushButton:hover {{ background: {pal.accent_hover}; }}"
            f"QPushButton:disabled {{ background: {pal.btn_disabled_bg}; "
            f"color: {pal.btn_disabled_fg}; }}"
        )
        self._proceed_btn.setEnabled(False)
        self._proceed_btn.clicked.connect(self._accept_proceed)
        bar.addWidget(self._proceed_btn)

        close_box = QDialogButtonBox(QDialogButtonBox.StandardButton.Close)
        close_box.rejected.connect(self.reject)
        bar.addWidget(close_box)

        layout.addLayout(bar)

        self._run(privileged=False)

    # ── Running the check ──────────────────────────────────────────────────

    def _run(self, *, privileged: bool) -> None:
        if self._proc is not None and self._proc.state() != QProcess.ProcessState.NotRunning:
            return

        self._items = []
        self._buffer = ""
        self._clear_list()
        self._subtitle.setText(
            "Kontrollerer med administratorrettigheder…" if privileged
            else "Kontrollerer…"
        )
        self._elevate_btn.setEnabled(False)
        self._proceed_btn.setEnabled(False)

        args = [str(self._script), "--check"]
        if self._luks_device:
            args.append(self._luks_device)

        program, argv = "bash", args
        if privileged:
            pkexec = shutil.which("pkexec")
            if not pkexec:
                self._subtitle.setText("pkexec blev ikke fundet — kan ikke hæve rettigheder.")
                return
            program, argv = pkexec, ["bash", *args]
            self._ran_privileged = True

        self._proc = QProcess(self)
        self._proc.setProcessChannelMode(QProcess.ProcessChannelMode.MergedChannels)
        self._proc.readyReadStandardOutput.connect(self._on_output)
        self._proc.finished.connect(self._on_finished)
        self._proc.start(program, argv)

    def _on_output(self) -> None:
        if self._proc is None:
            return
        self._buffer += bytes(self._proc.readAllStandardOutput()).decode(
            "utf-8", errors="replace"
        )
        while "\n" in self._buffer:
            line, self._buffer = self._buffer.split("\n", 1)
            item = CheckItem.parse(line)
            if item is not None:
                self._items.append(item)

    def _on_finished(self, exit_code: int, _status) -> None:
        item = CheckItem.parse(self._buffer)
        if item is not None:
            self._items.append(item)

        if not self._items:
            # pkexec returns 126/127 when the prompt is dismissed or the
            # action is not authorised. Anything else with no output means the
            # script did not get far enough to report.
            if exit_code in (126, 127):
                self._subtitle.setText("Rettighedsprompten blev afvist. Punkterne nedenfor er uændrede.")
            else:
                self._subtitle.setText(
                    f"Kontrollen gav ingen resultater (exit {exit_code}). "
                    "Er scriptet installeret korrekt?"
                )
            return

        self._render()

    # ── Rendering ──────────────────────────────────────────────────────────

    def _clear_list(self) -> None:
        while self._list_layout.count() > 1:
            w = self._list_layout.takeAt(0).widget()
            if w is not None:
                w.deleteLater()

    def _render(self) -> None:
        self._clear_list()
        pal = palette()

        for item in self._items:
            self._list_layout.insertWidget(
                self._list_layout.count() - 1, self._make_row(item, pal)
            )

        blockers = [i for i in self._items if i.blocks]
        unknowns = [i for i in self._items if i.status == "unknown"]
        warnings = [i for i in self._items if i.status == "warn"]

        if blockers:
            self._subtitle.setText(
                f"{len(blockers)} forudsætning(er) er ikke opfyldt. "
                "TPM2 auto-unlock kan ikke sættes op før de er løst."
            )
            self._proceed_btn.setEnabled(False)
        elif warnings:
            self._subtitle.setText(
                f"Ingen blokerende problemer, men {len(warnings)} punkt(er) "
                "bør du læse først."
            )
            self._proceed_btn.setEnabled(True)
        else:
            self._subtitle.setText("Alt ser ud til at være på plads.")
            self._proceed_btn.setEnabled(True)

        # Only offer elevation while something is still genuinely unknown.
        needs_root = any(
            i.status == "unknown" and "rettigheder" in i.detail for i in unknowns
        )
        self._elevate_btn.setEnabled(needs_root and not self._ran_privileged)

    def _make_row(self, item: CheckItem, pal) -> QWidget:
        fg, border = _colour_for(item.status)

        frame = QFrame()
        frame.setStyleSheet(
            f"QFrame {{ background: {pal.card_bg}; border: 1px solid {border}; "
            "border-radius: 6px; }"
            "QFrame QLabel { border: none; }"
        )
        row = QHBoxLayout(frame)
        row.setContentsMargins(12, 10, 12, 10)
        row.setSpacing(10)

        icon = QLabel(_ICONS.get(item.status, "·"))
        icon.setStyleSheet(f"color: {fg}; font-size: 15px; font-weight: 700;")
        icon.setFixedWidth(18)
        icon.setAlignment(Qt.AlignmentFlag.AlignTop)
        row.addWidget(icon)

        text = QVBoxLayout()
        text.setSpacing(3)

        title = QLabel(item.title)
        title.setWordWrap(True)
        title.setStyleSheet(f"color: {pal.text}; font-size: 13px; font-weight: 600;")
        text.addWidget(title)

        if item.detail:
            detail = QLabel(item.detail)
            detail.setWordWrap(True)
            detail.setStyleSheet(f"color: {pal.text_muted}; font-size: 11px;")
            text.addWidget(detail)

        # The fix is the reason the dialog exists, so it is only shown where it
        # is actionable — repeating it under a green tick trains people to skip
        # the text.
        if item.fix and item.status in ("warn", "fail"):
            fix = QLabel(f"→ {item.fix}")
            fix.setWordWrap(True)
            fix.setStyleSheet(f"color: {fg}; font-size: 11px; font-weight: 600;")
            text.addWidget(fix)

        row.addLayout(text, 1)
        return frame

    def closeEvent(self, event) -> None:
        """Stop a check that is still running.

        Without this the QProcess outlives the dialog and Qt complains at
        destruction. It also matters in practice: closing the dialog while a
        pkexec prompt is open should take the prompt with it, not leave an
        orphaned authentication dialog on the user's screen.
        """
        if self._proc is not None and self._proc.state() != QProcess.ProcessState.NotRunning:
            self._proc.terminate()
            if not self._proc.waitForFinished(2000):
                self._proc.kill()
                self._proc.waitForFinished(1000)
        super().closeEvent(event)

    # ── Result ─────────────────────────────────────────────────────────────

    def _accept_proceed(self) -> None:
        self._proceed = True
        self.accept()

    def should_proceed(self) -> bool:
        """True only if the user reviewed the checks and chose to continue."""
        return self._proceed
