# Security Policy

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Report privately to the maintainer via GitHub's
[private vulnerability reporting](https://github.com/mpark1306/DTU-Linux-Setup/security/advisories/new)
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
- Privileged modules are run as `pkexec bash -s` with the wrapper script fed
  on **stdin**, never written to a file. A wrapper file in `/tmp` would be
  owned by the unprivileged user but executed by root only after the PolicyKit
  prompt is answered, leaving a window in which another process running as the
  same user could replace its contents. Piping removes that window and keeps
  the password off the filesystem entirely.
- The password is still present in the environment of the root process for the
  lifetime of the module, and therefore visible to root (`/proc/<pid>/environ`).
  This is inherent to the design; it is not readable by other users.
- CIFS credentials are stored at `/home/<user>/.smbcred-*` with mode `0600`
  and ownership of the target user.
- WiFi (`802-1x.password`) is stored by NetworkManager in
  `/etc/NetworkManager/system-connections/*.nmconnection` (mode 0600, root).
- Kerberos tickets live in the standard `/tmp/krb5cc_*` cache.

## Hardening recommendations for IT admins

- Restrict who is in the polkit/sudoers admin group
  (`SITE_AD_ADMIN_GROUP` in `site.conf`). The PolicyKit module refuses to run
  when this is unset rather than falling back to a guessed group name.
- Review `data/software.conf` before letting non-admins run the Software
  module
- Keep `/etc/dtu-setup/site.conf` at mode `0644` root-owned; it contains
  infrastructure hostnames but no secrets
