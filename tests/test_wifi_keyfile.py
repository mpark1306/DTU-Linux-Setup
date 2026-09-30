"""wifi.sh writes the DTUSecure profile as a NetworkManager keyfile.

It used to call `nmcli connection add ... 802-1x.password "$PASSWORD"`, which
puts the domain password in the process list for every local user to read.
Writing the file directly avoids that, but moves the escaping onto us: NM
reads the file with GLib's GKeyFile, and a password with a backslash, a
leading space or a newline would come back different from what the user
typed. The Wi-Fi would then reject it with no visible reason.

So every case here writes a profile with wifi.sh's own function and reads it
back with GLib.KeyFile, the same parser NetworkManager uses.
"""
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
WIFI = REPO / "scripts" / "ubuntu" / "wifi.sh"

try:
    from gi.repository import GLib  # type: ignore
except Exception:  # pragma: no cover - depends on the machine
    GLib = None

NASTY = [
    "simple123",
    "back\\slash",
    "ends with backslash\\",
    "\\n is not a newline",
    " leading space",
    "trailing space ",
    "  two leading",
    "semi;colon;",
    "hash # not a comment",
    "equals=inside=",
    "quote\"and'single",
    "dollar $HOME and `backticks`",
    "æøå ÆØÅ ünïcödé",
    "tab\there",
    "percent %s %d",
    "[section]",
]


def write(tmp: Path, password: str, identity: str = "mpark@win.dtu.dk",
          ssid: str = "DTUSecure", match: str = "") -> Path:
    out = tmp / "p.nmconnection"
    if out.exists():
        out.unlink()
    env = {**os.environ, "DTU_WIFI_SOURCE_ONLY": "1",
           "PW": password, "ID": identity, "SSID": ssid, "MATCH": match,
           "OUT": str(out)}
    subprocess.run(
        ["bash", "-c",
         f'source "{WIFI}"; write_wifi_keyfile "$OUT" '
         '00000000-0000-4000-8000-000000000000 "$SSID" "$ID" "$PW" "$MATCH"'],
        env=env, check=True, capture_output=True, text=True)
    return out


@unittest.skipUnless(GLib, "python3-gi not installed")
class TestKeyfileRoundTrip(unittest.TestCase):

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)

    def tearDown(self):
        self._tmp.cleanup()

    @staticmethod
    def keys(kf, group: str) -> list:
        # PyGObject does not bind g_key_file_has_key.
        return list(kf.get_keys(group)[0])

    def load(self, path: Path):
        kf = GLib.KeyFile()
        kf.load_from_file(str(path), GLib.KeyFileFlags.NONE)
        return kf

    def test_every_awkward_password_comes_back_exactly(self):
        for pw in NASTY:
            with self.subTest(password=pw):
                kf = self.load(write(self.tmp, pw))
                self.assertEqual(kf.get_string("802-1x", "password"), pw)

    def test_a_newline_in_the_password_cannot_inject_a_key(self):
        """Without escaping, the second line would become a real key."""
        pw = "abc\nca-cert=/tmp/evil.pem"
        kf = self.load(write(self.tmp, pw))
        self.assertEqual(kf.get_string("802-1x", "password"), pw)
        self.assertNotIn("ca-cert", self.keys(kf, "802-1x"))

    def test_identity_and_ssid_survive_too(self):
        kf = self.load(write(self.tmp, "x", identity=" we\\ird@win.dtu.dk", ssid="DTU Secure"))
        self.assertEqual(kf.get_string("802-1x", "identity"), " we\\ird@win.dtu.dk")
        self.assertEqual(kf.get_string("wifi", "ssid"), "DTU Secure")
        self.assertEqual(kf.get_string("connection", "id"), "DTU Secure")

    def test_the_profile_is_what_dtusecure_needs(self):
        kf = self.load(write(self.tmp, "x"))
        self.assertEqual(kf.get_string("connection", "type"), "wifi")
        self.assertEqual(kf.get_string("wifi-security", "key-mgmt"), "wpa-eap")
        self.assertEqual(kf.get_string_list("802-1x", "eap"), ["peap"])
        self.assertEqual(kf.get_string("802-1x", "phase2-auth"), "mschapv2")
        self.assertEqual(kf.get_string("connection", "autoconnect-priority"), "10")
        # Empty permissions = available to every user and before login. A
        # profile bound to the admin who created it would not connect for
        # anyone else.
        self.assertEqual(kf.get_string("connection", "permissions"), "")

    def test_no_certificate_check_unless_configured(self):
        kf = self.load(write(self.tmp, "x"))
        self.assertNotIn("domain-suffix-match", self.keys(kf, "802-1x"))

    def test_certificate_check_when_configured(self):
        kf = self.load(write(self.tmp, "x", match="radius.example.dk"))
        self.assertEqual(kf.get_string("802-1x", "domain-suffix-match"), "radius.example.dk")
        self.assertEqual(kf.get_string("802-1x", "ca-cert"),
                         "/etc/ssl/certs/ca-certificates.crt")


class TestKeyfilePermissions(unittest.TestCase):
    """The file holds the domain password. It must be 0600 from the first
    byte, not chmod'ed afterwards: that gap is the followme.sh finding."""

    def test_created_0600_even_with_a_permissive_umask(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "p.nmconnection"
            subprocess.run(
                ["bash", "-c",
                 f'umask 000; source "{WIFI}"; '
                 f'write_wifi_keyfile "{out}" u DTUSecure id pw'],
                env={**os.environ, "DTU_WIFI_SOURCE_ONLY": "1"},
                check=True, capture_output=True)
            self.assertEqual(stat.S_IMODE(out.stat().st_mode), 0o600)


class TestPasswordStaysOutOfArgv(unittest.TestCase):

    def test_no_nmcli_call_carries_the_password(self):
        text = WIFI.read_text(encoding="utf-8")
        code = "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))
        self.assertNotIn("802-1x.password", code)
        for line in code.splitlines():
            if "nmcli" in line:
                with self.subTest(line=line.strip()):
                    self.assertNotIn("PASSWORD", line)

    def test_the_keyfile_is_written_with_builtins_only(self):
        """printf is a builtin: no new process, so nothing in /proc/*/cmdline.
        A `cat <<EOF` or `tee` would be a separate program."""
        text = WIFI.read_text(encoding="utf-8")
        start = text.index("write_wifi_keyfile() {")
        body = text[start:text.index("\n}\n", start)]
        for forbidden in ("cat ", "tee ", "echo ", "nmcli"):
            with self.subTest(command=forbidden):
                self.assertNotIn(forbidden, body)


class TestReplacesEveryOldProfile(unittest.TestCase):
    """The admin's profile survived because only a profile with one exact
    name was deleted. Now every profile for the SSID goes, and only once the
    new one is in place."""

    def setUp(self):
        self.text = WIFI.read_text(encoding="utf-8")

    def test_old_profiles_are_found_by_ssid_not_by_name(self):
        self.assertIn("802-11-wireless.ssid", self.text)
        self.assertNotIn('nmcli connection delete "$CON_NAME"', self.text)

    def test_the_old_ones_are_deleted_only_after_the_new_one_is_loaded(self):
        self.assertLess(self.text.index('nmcli connection load "$NEW_FILE"'),
                        self.text.index('nmcli connection delete uuid'))

    def test_a_failed_load_keeps_the_existing_wifi(self):
        idx = self.text.index('nmcli connection load "$NEW_FILE"')
        self.assertIn("left as it was", self.text[idx:idx + 600])


if __name__ == "__main__":
    unittest.main()
