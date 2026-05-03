# Security Policy

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Report privately to the maintainer via GitHub's
[private vulnerability reporting](https://github.com/mpark1306/DTU-Umbrella/security/advisories/new)
or by email. You will get an acknowledgement within a few working days.

## Scope

This project executes shell scripts as root via `pkexec`. Anything that:

- Allows privilege escalation outside the intended polkit policy
- Leaks credentials (`DTU_PASSWORD`, `DTU_ADMIN_PASSWORD`, etc.) to disk,
  logs, process arguments, or other users
- Bypasses the explicit user confirmation in the GUI
- Allows arbitrary command execution from untrusted input fields

…is in scope.

## Sensitive site data

This repository must **never** contain:

- Real user passwords or pre-shared keys
- Service account credentials (Bitwarden, AD admin, sus-root, etc.)
- Production GPG signing keys
- Proprietary third-party redistributables (e.g. Cisco Secure Client tarballs)
- Pre-built `.deb` / `.rpm` packages

If you find any of the above accidentally committed, please report it as a
security issue so it can be purged from history (`git filter-repo`).

## Credential handling

- Passwords are passed from GUI → script via environment variables only,
  never via command-line arguments.
- CIFS credentials are stored at `/home/<user>/.smbcred-*` with mode `0600`
  and ownership of the target user.
- WiFi (`802-1x.password`) is stored by NetworkManager in
  `/etc/NetworkManager/system-connections/*.nmconnection` (mode 0600, root).
- Kerberos tickets live in the standard `/tmp/krb5cc_*` cache.

## Hardening recommendations for IT admins

- Restrict who is in the polkit/sudoers admin group
  (`SITE_ADMIN_GROUP` in `site.conf`)
- Review `data/software.conf` before letting non-admins run the Software
  module
- Disable `Ansible Onboarding` in environments that don't run the central
  Ansible controller
