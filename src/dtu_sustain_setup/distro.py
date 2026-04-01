"""Distro detection for DTU Sustain Setup."""

from __future__ import annotations

import enum
import os
from pathlib import Path


class Distro(enum.Enum):
    UBUNTU = "ubuntu"
    OPENSUSE = "opensuse"
    UNKNOWN = "unknown"


def detect_distro() -> Distro:
    """Detect the current Linux distribution from /etc/os-release."""
    os_release = _read_os_release()
    distro_id = os_release.get("ID", "").lower()
    id_like = os_release.get("ID_LIKE", "").lower()

    if distro_id == "ubuntu" or "ubuntu" in id_like:
        return Distro.UBUNTU
    if distro_id == "opensuse-tumbleweed" or "suse" in id_like or "suse" in distro_id:
        return Distro.OPENSUSE
    return Distro.UNKNOWN


def distro_display_name() -> str:
    """Human-readable name from /etc/os-release PRETTY_NAME."""
    os_release = _read_os_release()
    return os_release.get("PRETTY_NAME", "Unknown Linux")


def get_scripts_dir(distro: Distro) -> Path:
    """Return the path to the scripts directory for the given distro."""
    # When installed: /opt/dtu-sustain-setup/scripts/<distro>/
    # When developing: <repo>/scripts/<distro>/
    base = Path(__file__).resolve().parent.parent.parent / "scripts"
    opt_base = Path("/opt/dtu-sustain-setup/scripts")

    if opt_base.is_dir():
        base = opt_base

    return base / distro.value


def _read_os_release() -> dict[str, str]:
    """Parse /etc/os-release into a dict."""
    result: dict[str, str] = {}
    os_release_path = Path("/etc/os-release")
    if not os_release_path.exists():
        return result

    for line in os_release_path.read_text().splitlines():
        line = line.strip()
        if "=" not in line or line.startswith("#"):
            continue
        key, _, value = line.partition("=")
        result[key.strip()] = value.strip().strip('"')
    return result
