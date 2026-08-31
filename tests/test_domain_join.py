"""What domain-join.sh writes into krb5.conf and sssd.conf.

Both files are rewritten on a machine that is already joined and working, so
the failure modes here are quiet and expensive: a Kerberos client with DNS
discovery switched off and no KDC list cannot log anyone in, and flipping
ldap_id_mapping renumbers every domain user and orphans their home directory.

The tests run the real blocks out of the script rather than a copy, so the
script cannot drift away from them.
"""

from __future__ import annotations

import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPT = REPO / "scripts" / "ubuntu" / "domain-join.sh"
TEXT = SCRIPT.read_text(encoding="utf-8")

# sssd.conf as `realm join` leaves it on Ubuntu 24.04.
REALM_JOIN_CONF = textwrap.dedent("""\
    [sssd]
    domains = win.dtu.dk
    config_file_version = 2
    services = nss, pam

    [domain/win.dtu.dk]
    default_shell = /bin/bash
    krb5_store_password_if_offline = True
    cache_credentials = True
    krb5_realm = WIN.DTU.DK
    realmd_tags = manages-system joined-with-adcli
    id_provider = ad
    fallback_homedir = /home/%u@%d
    ad_domain = win.dtu.dk
    use_fully_qualified_names = True
    ldap_id_mapping = True
    access_provider = ad
    """)


def _sssd_rewriter() -> str:
    """The Python heredoc from step [6/9], with its target path left open."""
    body = TEXT.split("<<'PYEOF'", 1)[1].split("\nPYEOF", 1)[0]
    assert "sssd.conf" in body, "could not find the sssd rewriter in the script"
    return body


def run_rewriter(conf_text: str, env: dict | None = None) -> tuple[int, str, str]:
    with tempfile.TemporaryDirectory() as tmp:
        target = Path(tmp) / "sssd.conf"
        target.write_text(conf_text, encoding="utf-8")
        code = _sssd_rewriter().replace(
            "PATH = '/etc/sssd/sssd.conf'", f"PATH = {str(target)!r}")
        proc = subprocess.run(["python3", "-c", code], capture_output=True,
                              text=True, env={**os.environ, **(env or {})})
        return proc.returncode, target.read_text(encoding="utf-8"), proc.stderr


def value_of(conf: str, key: str) -> str | None:
    m = re.search(rf"^{re.escape(key)}\s*=\s*(.*)$", conf, re.MULTILINE)
    return m.group(1).strip() if m else None


class TestSssdRewrite(unittest.TestCase):
    def setUp(self):
        self.rc, self.out, self.err = run_rewriter(REALM_JOIN_CONF)
        self.assertEqual(self.rc, 0, self.err)

    def test_services_line_is_removed(self):
        """Listing the responders here makes SSSD's monitor race systemd for
        the same socket and crash-loop. This is the v1.4.0 fix, and the one
        thing Speedup_Login.sh undid by writing the line straight back."""
        self.assertIsNone(value_of(self.out, "services"))

    def test_desktop_behaviour(self):
        self.assertEqual(value_of(self.out, "use_fully_qualified_names"), "False")
        self.assertEqual(value_of(self.out, "fallback_homedir"), "/home/%u")
        self.assertEqual(value_of(self.out, "override_homedir"), "/home/%u")
        self.assertEqual(value_of(self.out, "cache_credentials"), "True")

    def test_login_speed_settings(self):
        for key, expected in [
            ("entry_cache_timeout", "14400"),
            ("entry_cache_user_timeout", "14400"),
            ("entry_cache_group_timeout", "14400"),
            ("enumerate", "False"),
            ("ad_enable_gc", "False"),
            ("ldap_use_tokengroups", "False"),
            ("ldap_group_nesting_level", "0"),
            ("ad_gpo_access_control", "permissive"),
            ("ldap_network_timeout", "3"),
            ("offline_timeout", "10"),
        ]:
            with self.subTest(key=key):
                self.assertEqual(value_of(self.out, key), expected)

    def test_ignore_group_members_lands_in_nss_not_the_domain(self):
        nss = self.out.split("[nss]", 1)[1]
        self.assertIn("ignore_group_members = True", nss)

    def test_existing_ldap_id_mapping_is_left_alone(self):
        """It decides whether UIDs come from the AD SID or from POSIX
        attributes. Overwriting it on a joined machine renumbers every user
        and orphans their home directory."""
        conf = REALM_JOIN_CONF.replace("ldap_id_mapping = True",
                                       "ldap_id_mapping = False")
        rc, out, err = run_rewriter(conf)
        self.assertEqual(rc, 0, err)
        self.assertEqual(value_of(out, "ldap_id_mapping"), "False")

    def test_access_provider_is_not_touched_by_default(self):
        """'permit' lets every domain user log in. That is an access
        decision and must never be a side effect of a speed change."""
        self.assertEqual(value_of(self.out, "access_provider"), "ad")

    def test_access_provider_is_applied_when_site_conf_asks(self):
        rc, out, err = run_rewriter(
            REALM_JOIN_CONF, {"SITE_AD_ACCESS_PROVIDER": "permit"})
        self.assertEqual(rc, 0, err)
        self.assertEqual(value_of(out, "access_provider"), "permit")

    def test_running_twice_changes_nothing(self):
        rc, second, err = run_rewriter(self.out)
        self.assertEqual(rc, 0, err)
        self.assertEqual(second, self.out)

    def test_a_file_without_a_domain_section_is_left_untouched(self):
        conf = "[sssd]\nservices = nss, pam\n"
        rc, out, _ = run_rewriter(conf)
        self.assertNotEqual(rc, 0, "should refuse, not guess")
        self.assertEqual(out, conf)


class TestKrb5Block(unittest.TestCase):
    """The whole point of naming the KDCs is to switch DNS discovery off.
    Doing that without them leaves the client unable to find a KDC at all."""

    def _run(self, kdcs: str) -> tuple[str, str]:
        block = TEXT.split('echo "[5/9] Optimising the Kerberos client..."', 1)[1]
        block = block.split('echo "[6/9]', 1)[0]
        with tempfile.TemporaryDirectory() as tmp:
            krb5 = Path(tmp) / "krb5.conf"
            krb5.write_text("ORIGINAL\n", encoding="utf-8")
            harness = (
                "set -euo pipefail\n"
                "ok() { :; }\nwarn() { echo \"warn: $*\"; }\n"
                "DOMAIN_UPPER=WIN.DTU.DK\nSITE_AD_REALM=win.dtu.dk\n"
                "chown() { :; }\n"
                + block.replace("/etc/krb5.conf", str(krb5))
            )
            proc = subprocess.run(["bash", "-c", harness], capture_output=True,
                                  text=True, env={**os.environ, "SITE_AD_KDCS": kdcs})
            self.assertEqual(proc.returncode, 0, proc.stderr)
            return krb5.read_text(encoding="utf-8"), proc.stdout

    def test_without_kdcs_the_file_is_not_touched(self):
        out, stdout = self._run("")
        self.assertEqual(out, "ORIGINAL\n")
        self.assertIn("warn:", stdout)

    def test_dns_lookup_is_only_disabled_alongside_a_kdc_list(self):
        out, _ = self._run("dc-a.example.invalid dc-b.example.invalid")
        kdc_lines = re.findall(r"^\s*kdc\s*=\s*(\S+)", out, re.MULTILINE)
        self.assertEqual(len(kdc_lines), 2)
        self.assertIn("dns_lookup_kdc = false", out)
        self.assertIn("dns_lookup_realm = false", out)

    def test_first_kdc_becomes_admin_server(self):
        out, _ = self._run("dc-a.example.invalid dc-b.example.invalid")
        self.assertIn("admin_server = dc-a.example.invalid", out)

    def test_realm_and_domain_realm_come_from_site_config(self):
        out, _ = self._run("dc-a.example.invalid")
        self.assertIn("default_realm = WIN.DTU.DK", out)
        self.assertIn(".win.dtu.dk = WIN.DTU.DK", out)

    def test_generated_file_parses(self):
        """A malformed krb5.conf is not a syntax error anyone sees until a
        login fails, so let the real MIT parser read it."""
        out, _ = self._run("dc-a.example.invalid")
        with tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False) as fh:
            fh.write(out)
            path = fh.name
        try:
            proc = subprocess.run(
                ["kinit", "-V", "no-such-principal@WIN.DTU.DK"],
                capture_output=True, text=True, timeout=30,
                stdin=subprocess.DEVNULL,
                env={**os.environ, "KRB5_CONFIG": path})
            self.assertNotIn("Improper format", proc.stdout + proc.stderr)
            self.assertNotIn("configuration file", proc.stderr.lower())
        except (FileNotFoundError, subprocess.TimeoutExpired):
            self.skipTest("kinit unavailable or no KDC reachable")
        finally:
            os.unlink(path)


if __name__ == "__main__":
    unittest.main()
