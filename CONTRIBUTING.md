# Contributing

Thanks for considering a contribution! This project automates Linux workstation
setup at DTU but is designed so other institutions can adopt it by editing a
single configuration file.

## Quick start

```bash
git clone https://github.com/mpark1306/DTU-Umbrella.git
cd DTU-Umbrella
make run         # Run GUI from source
```

## Site configuration

All institution-specific values (AD domain, file servers, admin groups,
print servers, onboarding URLs, etc.) live in
[`data/site.conf.example`](data/site.conf.example). Copy it to
`/etc/dtu-setup/site.conf` and customise for your environment — module
scripts source it on startup. Two ready-to-use examples are provided:

- [`examples/dtu-sustain.env`](examples/dtu-sustain.env)
- [`examples/dtu-ait.env`](examples/dtu-ait.env)

## Coding guidelines

- **Bash:** always `set -euo pipefail`; source `scripts/common.sh`; use the
  `banner / ok / warn / fail` helpers; call `need_root` if applicable.
- **Python:** PyQt6, type hints, dataclasses for module definitions.
- Branch on `${DTU_DEPARTMENT:-sustain}` (or another site flag) when behaviour
  differs between profiles — never hard-code institution-specific strings.

## Pull requests

1. Fork → feature branch
2. `bash -n` all changed scripts
3. Test on at least one of: Ubuntu 24.04 LTS, openSUSE Tumbleweed
4. Open a PR against `main` describing what changed and why

## Reporting bugs

Open a GitHub Issue. Include distro + version, full module log, and any
relevant fragments from `journalctl`.
