"""Which distribution this is, and where its scripts live.

openSUSE was supported until September 2026. It was dropped because there
is no longer an openSUSE machine to test on, and an untested code path in a
tool that runs as root is worse than no code path: it looks maintained.

The abstraction is kept rather than inlined. It is the one place that knows
the answer, and re-adding a distribution means editing it and nothing else.
"""

from __future__ import annotations

from enum import Enum
from pathlib import Path


class Distro(str, Enum):
    UBUNTU = "ubuntu"
    UNKNOWN = "unknown"


def detect_distro() -> Distro:
    data = _read_os_release()
    distro_id = data.get("ID", "").lower()
    id_like = data.get("ID_LIKE", "").lower()
    if distro_id in ("ubuntu", "debian") or "debian" in id_like:
        return Distro.UBUNTU
    return Distro.UNKNOWN


def distro_display_name() -> str:
    data = _read_os_release()
    return data.get("PRETTY_NAME") or data.get("NAME") or "Ukendt system"


def get_scripts_dir(distro: Distro) -> Path:
    """The directory holding this distribution's module scripts.

    An unknown distribution still gets the Ubuntu directory. The modules
    themselves check what they need — apt, realmd, cups — and stop with a
    message naming the missing tool. That is a better failure than a path
    that does not exist.
    """
    root = Path(__file__).resolve().parent.parent.parent / "scripts"
    return root / "ubuntu"


def _read_os_release() -> dict[str, str]:
    values: dict[str, str] = {}
    try:
        with open("/etc/os-release", encoding="utf-8") as fh:
            for line in fh:
                if "=" not in line:
                    continue
                key, _, value = line.partition("=")
                values[key.strip()] = value.strip().strip('"')
    except OSError:
        pass
    return values
