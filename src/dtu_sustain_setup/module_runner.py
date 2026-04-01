"""Module runner – executes bash scripts via QProcess with live output."""

from __future__ import annotations

import os
import shutil
import tempfile
from pathlib import Path
from shlex import quote as shlex_quote

from PyQt6.QtCore import QProcess, QProcessEnvironment, pyqtSignal, QObject


class ModuleRunner(QObject):
    """Runs a bash script as a QProcess, optionally via pkexec for root."""

    output_received = pyqtSignal(str)
    finished = pyqtSignal(bool, str)  # (success, module_id)

    def __init__(self, parent=None):
        super().__init__(parent)
        self._process: QProcess | None = None
        self._wrapper_file: str | None = None

    def run(
        self,
        script_path: Path,
        module_id: str,
        *,
        needs_root: bool = False,
        env_vars: dict[str, str] | None = None,
    ) -> None:
        """Start the script. If needs_root, wraps with pkexec."""
        if self._process is not None and self._process.state() != QProcess.ProcessState.NotRunning:
            self.output_received.emit("ERROR: A module is already running.\n")
            return

        self._module_id = module_id

        self._process = QProcess(self)
        self._process.setProcessChannelMode(QProcess.ProcessChannelMode.MergedChannels)
        self._process.readyReadStandardOutput.connect(self._on_stdout)
        self._process.finished.connect(self._on_finished)

        script = str(script_path.resolve())

        if needs_root:
            pkexec = shutil.which("pkexec")
            if not pkexec:
                self.output_received.emit("ERROR: pkexec not found. Cannot escalate privileges.\n")
                self.finished.emit(False, module_id)
                return

            # pkexec strips environment variables. Write a small wrapper
            # script that re-exports DTU_* vars, then exec's the real script.
            # Explicitly isolate root's HOME and XDG dirs to prevent tools
            # (flatpak, Qt, KDE libs) from writing config files into the
            # calling user's home directory as root.
            wrapper_lines = ["#!/usr/bin/env bash"]
            wrapper_lines.append("export HOME=/root")
            wrapper_lines.append("unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR XDG_STATE_HOME")
            wrapper_lines.append("unset DBUS_SESSION_BUS_ADDRESS")
            # Pass display vars so scripts can open GUI windows (e.g. Konsole)
            for display_var in ("DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY"):
                val = os.environ.get(display_var)
                if val:
                    wrapper_lines.append(f"export {display_var}={shlex_quote(val)}")
            if env_vars:
                for key, value in env_vars.items():
                    # Only pass DTU_* variables
                    if key.startswith("DTU_"):
                        wrapper_lines.append(f"export {key}={shlex_quote(value)}")
            wrapper_lines.append(f'exec bash {shlex_quote(script)}')

            fd, wrapper_path = tempfile.mkstemp(prefix="dtu-run-", suffix=".sh")
            with os.fdopen(fd, "w") as f:
                f.write("\n".join(wrapper_lines) + "\n")
            os.chmod(wrapper_path, 0o700)
            self._wrapper_file = wrapper_path

            self.output_received.emit(f"▶ Running with elevated privileges: {script_path.name}\n")
            self._process.start(pkexec, ["bash", wrapper_path])
        else:
            # Non-root: pass env vars directly via QProcessEnvironment
            proc_env = QProcessEnvironment.systemEnvironment()
            if env_vars:
                for key, value in env_vars.items():
                    proc_env.insert(key, value)
            proc_env.insert("LANG", "en_US.UTF-8")
            self._process.setProcessEnvironment(proc_env)

            self.output_received.emit(f"▶ Running: {script_path.name}\n")
            self._process.start("bash", [script])

    def is_running(self) -> bool:
        return (
            self._process is not None
            and self._process.state() != QProcess.ProcessState.NotRunning
        )

    def cancel(self) -> None:
        if self._process and self._process.state() != QProcess.ProcessState.NotRunning:
            self._process.kill()

    def _on_stdout(self) -> None:
        if self._process is None:
            return
        data = self._process.readAllStandardOutput()
        if data:
            text = bytes(data).decode("utf-8", errors="replace")
            self.output_received.emit(text)

    def _on_finished(self, exit_code: int, exit_status: QProcess.ExitStatus) -> None:
        # Clean up wrapper script
        if self._wrapper_file and os.path.exists(self._wrapper_file):
            os.unlink(self._wrapper_file)
            self._wrapper_file = None

        success = exit_code == 0 and exit_status == QProcess.ExitStatus.NormalExit
        status_text = "✅ Completed successfully" if success else f"❌ Failed (exit code {exit_code})"
        self.output_received.emit(f"\n{status_text}\n{'─' * 60}\n")
        self.finished.emit(success, self._module_id)
