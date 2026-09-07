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
    return _scripts_root() / "ubuntu"


def _scripts_root() -> Path:
    """Where scripts/ lives, for both layouts the package is run from.

    Installeret ligger pakken i <prefix>/dtu_sustain_setup/ ved siden af
    <prefix>/scripts/. I repoet ligger den i <repo>/src/dtu_sustain_setup/,
    hvor scripts/ er ét niveau højere. Forskellen er præcis ét src-led, så
    roden kan ikke skrives af — den skal findes.

    Indtil september 2026 stod der en hardkodet /opt/dtu-sustain-setup-sti
    som faldback, og det var den der fik installerede maskiner til at virke.
    Da distributionsvalget blev skåret ned, forsvandt den, og tilbage stod
    kun den repo-relative sti: på en installeret maskine pegede den på
    /opt/scripts/ubuntu, som ikke findes. Hvert eneste modul blev dermed
    "ikke fundet", ikke kun update-latest.

    Her ledes der i stedet efter mappen. Det dækker begge layouts og
    samtidig en installation under et andet prefix end /opt, hvilket den
    hardkodede sti ikke gjorde.
    """
    here = Path(__file__).resolve()
    for root in (here.parent.parent, here.parent.parent.parent):
        if (root / "scripts").is_dir():
            return root / "scripts"
    # Findes ingen af dem, så returnér repo-layoutet: fejlbeskeden fra
    # kalderen navngiver da en sti der ligner den forventede.
    return here.parent.parent.parent / "scripts"


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
