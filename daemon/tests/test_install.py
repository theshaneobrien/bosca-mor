"""install/install.sh and tools/boot-splash.sh, run into a scratch root (D53).

Nothing here touches the real system. BOSCAMOR_ROOT and HOME point into a
temp folder, and sudo, apt-get, flatpak, curl, gsettings, systemctl and the
rest are stand-ins on PATH. The stand-in sudo logs every command, runs only
other stand-ins, and runs install, chmod and rm only into the scratch root.
Linux only (bash, GNU stat); run under WSL on the dev machine.
"""
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
LINUX = sys.platform.startswith("linux") and shutil.which("bash") is not None

STUBS = {
    "sudo": r"""#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
refuse() { echo "stand-in sudo refused: $*" >&2; exit 1; }
[ -n "${BOSCAMOR_ROOT:-}" ] || refuse "no BOSCAMOR_ROOT"
under() { case "$1" in "$BOSCAMOR_ROOT"/*) return 0 ;; *) return 1 ;; esac; }
cmd="$1"; shift
case "$cmd" in
	install|chmod|rm) ;;
	*) if [ -x "$STUB_DIR/$cmd" ]; then exec "$STUB_DIR/$cmd" "$@"; fi; exit 0 ;;
esac
args=()
while [ $# -gt 0 ]; do
	case "$1" in -o|-g) shift 2; continue ;; esac
	args+=("$1"); shift
done
case "$cmd" in
	install) under "${args[-1]}" || refuse "$cmd ${args[*]}" ;;
	chmod) for a in "${args[@]:1}"; do under "$a" || refuse "$cmd ${args[*]}"; done ;;
	rm) for a in "${args[@]}"; do case "$a" in -*) ;; *) under "$a" || refuse "$cmd ${args[*]}" ;; esac; done ;;
esac
exec "$cmd" "${args[@]}"
""",
    "id": r"""#!/usr/bin/env bash
case "$1" in
	-u) echo 1000 ;;
	-un|-gn) echo tv ;;
	-nG) echo "tv $(cat "$STUB_STATE/groups" 2>/dev/null | tr '\n' ' ')" ;;
	*) echo "uid=1000(tv) gid=1000(tv) groups=1000(tv)" ;;
esac
""",
    "usermod": r"""#!/usr/bin/env bash
echo "$2" >> "$STUB_STATE/groups"
""",
    "dpkg-query": r"""#!/usr/bin/env bash
printf 'install ok installed'
""",
    "getent": "#!/usr/bin/env bash\nexit 2\n",
    "gsettings": "#!/usr/bin/env bash\nexit 1\n",
    "xdg-user-dir": "#!/usr/bin/env bash\necho \"$HOME/Desktop\"\n",
    "systemctl": "#!/usr/bin/env bash\nprintf 'systemctl %s\\n' \"$*\" >> \"$STUB_LOG\"\n",
    "gio": r"""#!/usr/bin/env bash
case "$1" in
	info) [ -e "$STUB_STATE/trusted-$(printf %s "$4" | tr / _)" ] && echo "  metadata::trusted: true"; exit 0 ;;
	set) touch "$STUB_STATE/trusted-$(printf %s "$2" | tr / _)" ;;
esac
""",
    "flatpak": r"""#!/usr/bin/env bash
case " ${STUB_FAIL:-} " in *" flatpak "*) fail=1 ;; *) fail=0 ;; esac
case "$1" in
	remotes) [ -e "$STUB_STATE/flathub" ] && echo flathub; exit 0 ;;
	remote-add) [ "$fail" = 0 ] || exit 1; touch "$STUB_STATE/flathub" ;;
	info) [ -e "$STUB_STATE/app-$2" ] ;;
	install)
		[ "$fail" = 0 ] || exit 1
		case " $* " in
			*" --bundle "*) touch "$STUB_STATE/app-io.music_assistant.Companion" ;;
			*) touch "$STUB_STATE/app-${!#}" ;;
		esac ;;
esac
""",
    "curl": r"""#!/usr/bin/env bash
case " ${STUB_FAIL:-} " in *" curl "*) exit 22 ;; esac
url="${!#}" out=""
while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done
case "$url" in
	*api.github.com*) body='{"assets": [{"name": "c.flatpak", "browser_download_url": "https://example.invalid/c.flatpak"}]}' ;;
	*) body="download of $url" ;;
esac
if [ -n "$out" ]; then printf '%s\n' "$body" > "$out"; else printf '%s\n' "$body"; fi
""",
    "gpg": r"""#!/usr/bin/env bash
src="${!#}" out=""
while [ $# -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done
cp "$src" "$out"
""",
    "apt-get": r"""#!/usr/bin/env bash
case "$1" in
	update) case " ${STUB_FAIL:-} " in *" apt-update "*) exit 100 ;; esac ;;
	install)
		for a in "$@"; do
			if [ "$a" = spotify-client ]; then printf '#!/bin/sh\n' > "$STUB_DIR/spotify"; chmod +x "$STUB_DIR/spotify"; fi
		done ;;
esac
""",
    # Just enough of update-alternatives for one group, kept in a JSON file.
    "update-alternatives": r"""#!/usr/bin/env python3
import json, os, sys
path = os.path.join(os.environ["STUB_STATE"], "alternatives.json")
st = json.load(open(path)) if os.path.exists(path) else {"mode": "auto", "value": "", "alts": {}}
def best():
    return max(st["alts"], key=lambda p: st["alts"][p]) if st["alts"] else ""
def save():
    json.dump(st, open(path, "w"))
a = sys.argv[1:]
if a[0] == "--query":
    if not st["alts"]:
        sys.exit(2)
    print("Name: default.plymouth\nStatus: %s\nBest: %s\nValue: %s\n" % (st["mode"], best(), st["value"]))
elif a[0] == "--list":
    if not st["alts"]:
        sys.exit(2)
    print("\n".join(st["alts"]))
elif a[0] == "--install":
    st["alts"][a[3]] = int(a[4])
    if st["mode"] == "auto":
        st["value"] = best()
    save()
elif a[0] == "--set":
    st["mode"], st["value"] = "manual", a[2]
    save()
elif a[0] == "--remove":
    st["alts"].pop(a[2], None)
    if st["value"] == a[2]:
        st["mode"], st["value"] = "auto", best()
    save()
""",
}


@unittest.skipUnless(LINUX, "needs Linux (bash, GNU coreutils)")
class Scratch(unittest.TestCase):
    """A copy of the repo's install and daemon files, a home, a system root."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="install-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.repo = os.path.join(self.tmp, "repo")
        shutil.copytree(os.path.join(REPO, "install"), os.path.join(self.repo, "install"))
        shutil.copytree(os.path.join(REPO, "tools"), os.path.join(self.repo, "tools"))
        os.makedirs(os.path.join(self.repo, "daemon"))
        shutil.copy(os.path.join(REPO, "daemon", "boscamor-input.py"), os.path.join(self.repo, "daemon"))
        self.sys = os.path.join(self.tmp, "sys")
        self.home = os.path.join(self.tmp, "home")
        self.stubs = os.path.join(self.tmp, "stubs")
        self.state = os.path.join(self.tmp, "state")
        for d in (self.sys, self.home, self.stubs, self.state):
            os.makedirs(d)
        for name, text in STUBS.items():
            self.write(os.path.join(self.stubs, name), text, 0o755)
        self.log = os.path.join(self.tmp, "sudo.log")
        self.dest = os.path.join(self.sys, "opt", "boscamor")

    def write(self, path, text, mode=0o644):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(text if isinstance(text, bytes) else text.encode())
        os.chmod(path, mode)

    def read(self, path):
        with open(path) as f:
            return f.read()

    def run_script(self, script, *args, fail=""):
        env = {
            "PATH": self.stubs + ":" + os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": self.home, "LANG": "C", "BOSCAMOR_ROOT": self.sys,
            "STUB_DIR": self.stubs, "STUB_STATE": self.state, "STUB_LOG": self.log, "STUB_FAIL": fail,
        }
        return subprocess.run(["bash", os.path.join(self.repo, script), *args], env=env,
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)


class TestInstaller(Scratch):
    def install(self, *args, fail=""):
        p = self.run_script("install/install.sh", *args, fail=fail)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        return p.stdout

    def sys_path(self, path):
        return os.path.join(self.sys, path.lstrip("/"))

    def assert_system_steps_done(self):
        for path in ("/etc/systemd/logind.conf.d/boscamor.conf",
                     "/etc/lightdm/lightdm.conf.d/90-boscamor.conf",
                     "/opt/boscamor/boscamor-input.py"):
            self.assertTrue(os.path.isfile(self.sys_path(path)), path)
        self.assertTrue(os.path.isfile(os.path.join(self.home, ".config/autostart/boscamor-input.desktop")))

    def test_dry_run_changes_nothing(self):
        out = self.install("--dry-run")
        self.assertIn("changes would be made", out)
        written = [os.path.join(d, f) for top in (self.sys, self.home) for d, _, fs in os.walk(top) for f in fs]
        self.assertEqual(written, [])
        self.assertFalse(os.path.exists(self.log), "sudo ran in a dry run")

    def test_second_run_makes_no_changes(self):
        self.install()
        self.assertIn("No changes", self.install())

    def test_failed_app_installs_warn_and_the_system_steps_still_run(self):
        out = self.install(fail="curl flatpak")
        self.assert_system_steps_done()
        self.assertIn("warning: could not add the Flathub remote", out)
        self.assertIn("warning: could not install rocks.shy.VacuumTube from Flathub", out)
        self.assertIn("warning: could not read the latest Music Assistant release", out)
        self.assertIn("warning: could not fetch Spotify's key", out)
        self.assertFalse(os.path.exists(self.sys_path("/etc/apt/sources.list.d/spotify.list")))
        # Apps come last, after the files.
        self.assertLess(out.index("7. Firefox kiosk profiles"), out.index("8. Apps"))

    def test_rejected_spotify_repository_is_taken_out_again(self):
        out = self.install(fail="apt-update")
        self.assertIn("warning: apt update failed with Spotify's repository added", out)
        self.assertFalse(os.path.exists(self.sys_path("/etc/apt/sources.list.d/spotify.list")))
        self.assertFalse(os.path.exists(self.sys_path("/etc/apt/keyrings/spotify.gpg")))
        self.assert_system_steps_done()

    def test_spotify_key_signs_only_spotify(self):
        self.install()
        source = self.read(self.sys_path("/etc/apt/sources.list.d/spotify.list"))
        self.assertIn("[signed-by=/etc/apt/keyrings/spotify.gpg]", source)
        self.assertTrue(os.path.isfile(self.sys_path("/etc/apt/keyrings/spotify.gpg")))
        self.assertFalse(os.path.exists(self.sys_path("/etc/apt/trusted.gpg.d/spotify.gpg")))

    def test_old_trusted_key_moves_to_a_keyring(self):
        self.write(self.sys_path("/etc/apt/trusted.gpg.d/spotify.gpg"), b"old key")
        self.write(os.path.join(self.stubs, "spotify"), "#!/bin/sh\n", 0o755)  # Spotify already there
        self.install()
        with open(self.sys_path("/etc/apt/keyrings/spotify.gpg"), "rb") as f:
            self.assertEqual(f.read(), b"old key")
        self.assertFalse(os.path.exists(self.sys_path("/etc/apt/trusted.gpg.d/spotify.gpg")))
        self.assertIn("signed-by=", self.read(self.sys_path("/etc/apt/sources.list.d/spotify.list")))
        self.assertIn("No changes", self.install())

    def test_a_download_that_is_not_a_linux_build_is_not_installed(self):
        self.write(os.path.join(self.dest, "boscamor"), b"\x7fELF working", 0o755)
        self.write(os.path.join(self.repo, "build", "boscamor"), b"Not Found", 0o755)
        out = self.install("--no-apps")
        self.assertIn("is not a Linux build", out)
        with open(os.path.join(self.dest, "boscamor"), "rb") as f:
            self.assertEqual(f.read(), b"\x7fELF working")

    def test_a_linux_build_is_installed(self):
        self.write(os.path.join(self.repo, "build", "boscamor"), b"\x7fELF new", 0o644)
        self.install("--no-apps")
        path = os.path.join(self.dest, "boscamor")
        with open(path, "rb") as f:
            self.assertEqual(f.read(), b"\x7fELF new")
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o755)

    def test_world_writable_files_are_repaired(self):
        # tools/deploy.sh from WSL used to copy the Windows drive's 0777.
        self.write(os.path.join(self.repo, "build", "boscamor"), b"\x7fELF build", 0o755)
        self.install("--no-apps")
        daemon, launcher = os.path.join(self.dest, "boscamor-input.py"), os.path.join(self.dest, "boscamor")
        os.chmod(daemon, 0o777)
        os.chmod(launcher, 0o777)
        out = self.install("--no-apps")
        self.assertIn("chmod 0755 %s (was 777)" % daemon, out)
        self.assertEqual(stat.S_IMODE(os.stat(daemon).st_mode), 0o755)
        self.assertEqual(stat.S_IMODE(os.stat(launcher).st_mode), 0o755)
        self.assertIn("No changes", self.install("--no-apps"))

    def test_lightdm_conf_overriding_auto_login_warns(self):
        self.write(self.sys_path("/etc/lightdm/lightdm.conf"),
                   "[Seat:*]\n# autologin-user=tv\nautologin-user=\ngreeter-hide-users=false\n")
        out = self.install("--no-apps")
        self.assertIn("lightdm.conf sets autologin-user=, not tv", out)

    def test_lightdm_conf_that_agrees_does_not_warn(self):
        self.write(self.sys_path("/etc/lightdm/lightdm.conf"),
                   "[Seat:*]\nautologin-user=tv\n[Seat:seat1]\nautologin-user=someone\n")
        self.assertNotIn("lightdm.conf sets", self.install("--no-apps"))


class TestBootSplash(Scratch):
    MINT = "/usr/share/plymouth/themes/mint-logo/mint-logo.plymouth"
    BGRT = "/usr/share/plymouth/themes/bgrt/bgrt.plymouth"

    def setUp(self):
        super().setUp()
        os.makedirs(os.path.join(self.sys, "usr/share/plymouth/themes"))
        self.picture = os.path.join(self.tmp, "splash.png")
        self.write(self.picture, b"\x89PNG\r\n\x1a\n picture")

    def alternatives(self, mode, value):
        self.write(os.path.join(self.state, "alternatives.json"),
                   json.dumps({"mode": mode, "value": value, "alts": {self.MINT: 100, self.BGRT: 110}}))

    def splash(self, *args):
        p = self.run_script("tools/boot-splash.sh", *args)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        with open(os.path.join(self.state, "alternatives.json")) as f:
            return json.load(f)

    def test_restore_brings_back_a_theme_chosen_by_hand(self):
        # Mint's ranks below bgrt here, so falling back to auto would pick bgrt.
        self.alternatives("manual", self.MINT)
        ours = os.path.join(self.sys, "usr/share/plymouth/themes/boscamor-splash/boscamor-splash.plymouth")
        self.assertEqual(self.splash(self.picture)["value"], ours)
        st = self.splash("--restore")
        self.assertEqual((st["mode"], st["value"]), ("manual", self.MINT))
        self.assertNotIn(ours, st["alts"])

    def test_restore_leaves_auto_mode_as_it_was(self):
        self.alternatives("auto", self.BGRT)
        self.splash(self.picture)
        st = self.splash("--restore")
        self.assertEqual((st["mode"], st["value"]), ("auto", self.BGRT))


if __name__ == "__main__":
    unittest.main()
