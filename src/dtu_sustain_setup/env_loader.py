"""Parse an env-style file (KEY=VALUE) into a dict.

Supports:
    KEY=value
    KEY="value with spaces"
    KEY='value'
    export KEY=value
    # comments and blank lines

Only DTU_* keys are considered; everything else is ignored. The file is
read as plain text — no shell expansion is performed.
"""

from __future__ import annotations

import shlex
from dataclasses import dataclass, field
from pathlib import Path

# Variables the GUI / scripts know how to consume. Keep in sync with
# main_window._run_module() and the scripts under scripts/.
KNOWN_VARS: tuple[str, ...] = (
    "DTU_DEPARTMENT",
    "DTU_HOSTNAME",
    "DTU_ADMIN_USERNAME",
    "DTU_USERNAME",
    "DTU_PASSWORD",
    "DTU_SOFTWARE_CONF",
    "DTU_CISCO_TARBALL",
)

# Variables that should never be displayed in their entirety.
SECRET_VARS: frozenset[str] = frozenset({"DTU_PASSWORD"})


@dataclass
class EnvLoadResult:
    path: Path
    values: dict[str, str] = field(default_factory=dict)
    unknown: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    def summary(self) -> str:
        lines = [f"File: {self.path}"]
        if self.values:
            lines.append("")
            lines.append("Loaded variables:")
            for key in KNOWN_VARS:
                if key in self.values:
                    val = self.values[key]
                    if key in SECRET_VARS:
                        display = "*" * min(len(val), 8) if val else "(empty)"
                    else:
                        display = val if val else "(empty)"
                    lines.append(f"  • {key} = {display}")
        else:
            lines.append("")
            lines.append("No recognised DTU_* variables found.")
        if self.unknown:
            lines.append("")
            lines.append("Ignored (unknown) keys:")
            for k in self.unknown:
                lines.append(f"  • {k}")
        if self.errors:
            lines.append("")
            lines.append("Parse errors:")
            for e in self.errors:
                lines.append(f"  • {e}")
        return "\n".join(lines)


def parse_env_file(path: Path) -> EnvLoadResult:
    result = EnvLoadResult(path=path)
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        result.errors.append(f"Could not read file: {exc}")
        return result

    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].lstrip()
        if "=" not in line:
            result.errors.append(f"line {lineno}: missing '=' — {raw!r}")
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if not key.replace("_", "").isalnum():
            result.errors.append(f"line {lineno}: invalid key {key!r}")
            continue
        # Strip an inline comment only when the value is unquoted.
        try:
            tokens = shlex.split(value, comments=False, posix=True)
            value_clean = tokens[0] if tokens else ""
        except ValueError as exc:
            result.errors.append(f"line {lineno}: {exc}")
            continue

        if key in KNOWN_VARS:
            result.values[key] = value_clean
        elif key.startswith("DTU_"):
            result.unknown.append(key)
    return result
