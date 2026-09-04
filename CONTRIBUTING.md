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
scripts source it on startup.

Values in `<angle brackets>` are placeholders, not defaults: `load_site_conf()`
blanks them out, and a module that needs one stops via `site_require` with an
error naming the variable. Declare what your module needs the same way.

The ready-made DTU Sustain and AIT profiles are **not** in this repo; they are
distributed out-of-band by DTU IT.

### The internal-values guard

`tests/check-no-internal-values.sh` fails the build if a commit puts concrete
DTU infrastructure into a tracked file. It runs in CI via `make test`.

It works on **structure, not a blocklist** — a list of the internal values in a
public repo would publish exactly what it is meant to keep out:

1. `SITE_*` may only be assigned an approved site-independent default, a
   `<placeholder>`, an empty value, or another shell variable.
2. Only publicly-advertised `*.dtu.dk` hostnames may appear.
3. `SERVER`, `Q_SHARE_PATH` and `P_SHARE_PATH` must be assigned from
   configuration, never from a literal — note that a single-quoted value never
   expands, so `'name$'` is a literal, not a variable reference.

If your change legitimately needs a new public value, add it to the approved
list in that script and explain in the commit message why it is safe to
publish. Test fixtures should use the reserved `.invalid` TLD rather than a
plausible-looking DTU hostname.

## Colours and themes

Never write a hex colour into a widget. Every colour comes from
`src/dtu_sustain_setup/theme.py`, which exposes a `palette()` with a named
token for each role and two full sets of values behind it — one for light
desktops, one for dark. Which set is used is decided once at startup from the
running application's own palette, so the tool follows the desktop instead of
forcing a look.

If you need a colour that has no token yet, add the token to **both** `LIGHT`
and `DARK`. `tests/test_theme.py` will fail if only one of them defines it.

That test also measures WCAG contrast for every foreground/background pair the
UI actually paints, so a token that looks fine on your machine but fails at
4.5:1 is caught before it ships — which is how the tool became unreadable on
dark Plasma in the first place. Borders that merely decorate are held to a
lower bar than borders that carry meaning (success vs failure); the reasoning
is written into the test.

To check a change by eye without switching your desktop theme:

```bash
DTU_SETUP_THEME=dark  make run
DTU_SETUP_THEME=light make run
```

`tests/test_main_window_smoke.py` builds the whole window under offscreen Qt in
both modes and fails on any hex that is not a palette token, so a hardcoded
colour cannot creep back in unnoticed.

## Coding guidelines

- **Bash:** always `set -euo pipefail`; source `scripts/common.sh`; use the
  `banner / ok / warn / fail` helpers; call `need_root` if applicable.
- **Python:** PyQt6, type hints, dataclasses for module definitions.
- Keep `main_window.py` about building and wiring the UI. The catalogue of
  modules lives in `modules.py`, colours in `theme.py`, the Run All queue in
  `batch.py`, and the input dialogs a module needs in `prompts.py` — those four
  are free of window state and are where new logic should go.
- Branch on `${DTU_DEPARTMENT:-sustain}` (or another site flag) when behaviour
  differs between profiles — never hard-code institution-specific strings.

## Pull requests

1. Fork → feature branch
2. `bash -n` all changed scripts
4. Open a PR against `main` describing what changed and why

## Reporting bugs

Open a GitHub Issue. Include distro + version, full module log, and any
relevant fragments from `journalctl`.
