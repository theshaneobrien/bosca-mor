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
    # Every package is installed, except the ones listed in $STUB_STATE/missing.
    "dpkg-query": r"""#!/usr/bin/env bash
grep -qxF -- "${!#}" "$STUB_STATE/missing" 2>/dev/null && exit 1
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
		case " ${STUB_FAIL:-} " in *" apt-install "*) exit 100 ;; esac
		for a in "$@"; do
			if [ "$a" = spotify-client ]; then printf '#!/bin/sh\n' > "$STUB_DIR/spotify"; chmod +x "$STUB_DIR/spotify"; fi
		done ;;
esac
""",
    # Tailscale, up and logged in; Tailscale SSH is on once "set --ssh" ran.
    "tailscale": r"""#!/usr/bin/env bash
case "$1" in
	ip) echo 100.101.102.103 ;;
	debug) printf '{\n\t"RunSSH": %s,\n\t"WantRunning": true\n}\n' "$([ -e "$STUB_STATE/tailscale-ssh" ] && echo true || echo false)" ;;
	set) [ "$2" = --ssh ] && touch "$STUB_STATE/tailscale-ssh" ;;
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
        shutil.copytree(os.path.join(REPO, "launcher", "assets", "icon"),
                        os.path.join(self.repo, "launcher", "assets", "icon"))
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

    def run_script(self, script, *args, fail="", typed=None, env=None):
        full = {
            "PATH": self.stubs + ":" + os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": self.home, "LANG": "C", "BOSCAMOR_ROOT": self.sys,
            "STUB_DIR": self.stubs, "STUB_STATE": self.state, "STUB_LOG": self.log, "STUB_FAIL": fail,
        }
        full.update(env or {})
        # typed: what the user types at the script's prompts, if anything.
        stdin = {"input": typed} if typed is not None else {"stdin": subprocess.DEVNULL}
        return subprocess.run(["bash", os.path.join(self.repo, script), *args], env=full,
                              capture_output=True, text=True, timeout=120, **stdin)

    def logged(self):
        return self.read(self.log).splitlines() if os.path.exists(self.log) else []


class TestShareScreen(Scratch):
    """install/files/share-screen with tailscale and x11vnc stand-ins."""

    X11VNC = r"""#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_STATE/x11vnc-args"
for a in "$@"; do case "$a" in rm:*) cat "${a#rm:}" > "$STUB_STATE/x11vnc-pass" ;; esac; done
[ -e "$STUB_STATE/x11vnc-fail" ] && { echo "listen failed: address in use"; exit 1; }
exit 0
"""

    def share(self):
        self.write(os.path.join(self.stubs, "x11vnc"), self.X11VNC, 0o755)
        return self.run_script("install/files/share-screen")

    def test_shares_on_the_tailscale_address_with_a_new_password(self):
        p = self.share()
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        args = self.read(os.path.join(self.state, "x11vnc-args")).split()
        for want in (["-listen", "100.101.102.103"], ["-rfbport", "5900"], ["-timeout", "120"]):
            i = args.index(want[0])
            self.assertEqual(args[i:i + 2], want)
        self.assertIn("-once", args)
        self.assertIn("-no6", args)
        password = self.read(os.path.join(self.state, "x11vnc-pass")).strip()
        self.assertRegex(password, r"^[0-9a-f]{8}$")
        self.assertIn("password:           " + password, p.stdout)
        self.assertIn("100.101.102.103:5900", p.stdout)
        pwfile = [a for a in args if a.startswith("rm:")][0][3:]
        self.assertFalse(os.path.exists(pwfile), "password file left behind")

    def test_an_x11vnc_error_is_shown(self):
        open(os.path.join(self.state, "x11vnc-fail"), "w").close()
        p = self.share()
        self.assertEqual(p.returncode, 1)
        self.assertIn("address in use", p.stderr)

    def test_no_tailscale_address_stops_before_x11vnc(self):
        self.write(os.path.join(self.stubs, "tailscale"), "#!/usr/bin/env bash\nexit 1\n", 0o755)
        p = self.share()
        self.assertEqual(p.returncode, 1)
        self.assertIn("Tailscale has no address", p.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.state, "x11vnc-args")))


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

    def test_remote_help_turns_on_tailscale_ssh_and_installs_share_screen(self):
        out = self.install()
        self.assertIn("change  turn on Tailscale SSH", out)
        self.assertIn("tailscale set --ssh", self.logged())
        script = os.path.join(self.dest, "share-screen")
        self.assertEqual(self.read(script), self.read(os.path.join(REPO, "install/files/share-screen")))
        self.assertTrue(os.stat(script).st_mode & stat.S_IXUSR)
        self.assertIn("ok      Tailscale SSH is on", self.install())

    def test_tailscale_down_warns_and_changes_nothing_there(self):
        self.write(os.path.join(self.stubs, "tailscale"), "#!/usr/bin/env bash\nexit 1\n", 0o755)
        out = self.install()
        self.assertIn("warning: Tailscale isn't up", out)
        self.assertNotIn("tailscale set --ssh", self.logged())
        self.assert_system_steps_done()

    def test_update_lists_system_changes_and_runs_no_sudo(self):
        # What the daemon runs for an update (D103): nobody is there to type a password.
        with open(os.path.join(self.state, "missing"), "w") as f:
            f.write("x11vnc\n")
        p = self.run_script("install/install.sh", "--update")
        self.assertEqual(p.returncode, 3, p.stdout + p.stderr)
        # The stand-in sudo logs its commands; systemctl logs as "systemctl ...".
        self.assertEqual([l for l in self.logged() if not l.startswith("systemctl ")], [], "sudo ran")
        self.assertNotIn("systemctl --user restart boscamor-input.service", self.logged())
        self.assertIn("needs sudo: apt-get install -y x11vnc", p.stdout)
        self.assertIn("needs sudo: install -D -m 0644", p.stdout)        # logind and lightdm
        self.assertIn("system changes need sudo: run install/install.sh on the box by hand", p.stdout)
        self.assertIn("ok      skipped (--no-apps)", p.stdout)
        self.assertFalse(os.path.exists(self.sys_path("/etc/systemd/logind.conf.d/boscamor.conf")))
        # The user's own files are written.
        self.assertTrue(os.path.isfile(self.sys_path("/opt/boscamor/boscamor-input.py")))
        self.assertTrue(os.path.isfile(os.path.join(self.home, ".config/autostart/boscamor-input.desktop")))

    def test_update_after_an_install_restarts_nothing_itself(self):
        self.install("--no-apps")
        os.remove(self.log)
        with open(os.path.join(self.repo, "daemon", "boscamor-input.py"), "a") as f:
            f.write("# a new daemon\n")
        p = self.run_script("install/install.sh", "--update")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("the daemon restarts itself after the update", p.stdout)
        self.assertNotIn("needs sudo", p.stdout)
        self.assertEqual(self.logged(), [], "no sudo, and no systemctl restart of the daemon running the update")
        self.assertTrue(self.read(self.sys_path("/opt/boscamor/boscamor-input.py")).endswith("# a new daemon\n"))

    def test_v0_14_4s_x_start_mode_is_taken_out(self):
        # D105's xorg.conf.d file left the box with no signal at every boot
        # and a frozen session after a replug (D106).
        conf = self.sys_path("/etc/X11/xorg.conf.d/90-boscamor.conf")
        self.write(conf, 'Section "Monitor"\n\tIdentifier "DP-1"\nEndSection\n')
        p = self.run_script("install/install.sh", "--update")
        self.assertEqual(p.returncode, 3, p.stdout + p.stderr)
        self.assertIn("needs sudo: rm -f %s" % conf, p.stdout)
        self.assertTrue(os.path.exists(conf), "an update removes no system file")
        out = self.install("--no-apps")
        self.assertIn("change  remove %s" % conf, out)
        self.assertFalse(os.path.exists(conf))
        self.assertIn("ok      none", self.install("--no-apps"))

    def test_the_launcher_icon_is_installed_for_the_menu_and_taskbar(self):
        self.install()
        icons = os.path.join(self.home, ".local/share/icons/hicolor")
        for px in (16, 32, 48, 256):
            got = os.path.join(icons, "%dx%d/apps/boscamor-launcher.png" % (px, px))
            with open(got, "rb") as a, open(os.path.join(REPO, "launcher/assets/icon/launcher-%d.png" % px), "rb") as b:
                self.assertEqual(a.read(), b.read(), got)
        self.assertTrue(os.path.isfile(os.path.join(icons, "scalable/apps/boscamor-launcher.svg")))
        entry = self.read(os.path.join(self.home, ".local/share/applications/boscamor-launcher.desktop"))
        self.assertIn("Icon=boscamor-launcher\n", entry)
        self.assertIn("StartupWMClass=Launcher\n", entry, "the taskbar matches the window to this entry")

    def test_minimise_effect_is_set_when_gsettings_keeps_writing(self):
        # Box install log, 25 Oct: under pipefail, grep -q stopped reading at
        # the key, gsettings got SIGPIPE on its next line, and the installer
        # said the key wasn't there.
        self.write(os.path.join(self.stubs, "gsettings"), """#!/usr/bin/env bash
if [ "$1" = list-keys ] && [ "$2" = org.cinnamon ]; then
  echo desktop-effects-minimize
  sleep 0.3
  for i in $(seq 1 3000); do echo "other-key-$i"; done
  exit 0
fi
if [ "$1" = get ] && [ "$3" = desktop-effects-minimize ]; then echo "'traditional'"; exit 0; fi
if [ "$1" = set ]; then echo "$*" >> "$STUB_STATE/gsettings.log"; exit 0; fi
exit 1
""", 0o755)
        out = self.install()
        self.assertNotIn("no org.cinnamon desktop-effects-minimize here", out)
        self.assertIn("set org.cinnamon desktop-effects-minimize none",
                      self.read(os.path.join(self.state, "gsettings.log")))

    def test_rejected_spotify_repository_is_taken_out_again(self):
        out = self.install(fail="apt-update")
        self.assertIn("warning: apt update failed with Spotify's repository added", out)
        self.assertFalse(os.path.exists(self.sys_path("/etc/apt/sources.list.d/spotify.list")))
        self.assertFalse(os.path.exists(self.sys_path("/etc/apt/keyrings/spotify.gpg")))
        self.assert_system_steps_done()

    def test_failed_apt_update_still_installs_and_runs_the_system_steps(self):
        # A broken third-party repository (Spotify's rotated key) fails the
        # update in step 1 on a re-run that adds a package.
        self.write(os.path.join(self.state, "missing"), "evtest\n")
        self.write(self.sys_path("/etc/apt/trusted.gpg.d/spotify.gpg"), b"old key")
        self.write(os.path.join(self.stubs, "spotify"), "#!/bin/sh\n", 0o755)
        out = self.install(fail="apt-update")
        self.assertIn("warning: apt update failed (a third-party repository?)", out)
        self.assertIn("apt-get install -y evtest", self.logged())
        self.assert_system_steps_done()
        # Step 8's keyring move still ran.
        self.assertTrue(os.path.isfile(self.sys_path("/etc/apt/keyrings/spotify.gpg")))
        self.assertFalse(os.path.exists(self.sys_path("/etc/apt/trusted.gpg.d/spotify.gpg")))

    def test_failed_package_install_warns_and_the_system_steps_still_run(self):
        self.write(os.path.join(self.state, "missing"), "evtest\n")
        out = self.install("--no-apps", fail="apt-install")
        self.assertIn("warning: could not install evtest", out)
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
    def setUp(self):
        super().setUp()
        # Under the scratch root, where the script looks for themes.
        themes = os.path.join(self.sys, "usr/share/plymouth/themes")
        os.makedirs(themes)
        self.MINT = os.path.join(themes, "mint-logo/mint-logo.plymouth")
        self.BGRT = os.path.join(themes, "bgrt/bgrt.plymouth")
        self.ours_dir = os.path.join(themes, "boscamor-splash")
        self.ours = os.path.join(self.ours_dir, "boscamor-splash.plymouth")
        self.picture = os.path.join(self.tmp, "splash.png")
        self.write(self.picture, b"\x89PNG\r\n\x1a\n picture")

    def alternatives(self, mode, value, **more):
        self.write(os.path.join(self.state, "alternatives.json"),
                   json.dumps({"mode": mode, "value": value,
                               "alts": {self.MINT: 100, self.BGRT: 110, **more}}))

    def older_install(self, mode, value):
        """The splash as the older script left it: ours a theme, no record."""
        self.write(os.path.join(self.ours_dir, "splash.png"), b"\x89PNG\r\n\x1a\n old")
        self.write(self.ours, "[Plymouth Theme]\n")
        self.alternatives(mode, value, **{self.ours: 100})

    def splash(self, *args):
        p = self.run_script("tools/boot-splash.sh", *args)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        with open(os.path.join(self.state, "alternatives.json")) as f:
            return json.load(f)

    def test_restore_brings_back_a_theme_chosen_by_hand(self):
        # Mint's ranks below bgrt here, so falling back to auto would pick bgrt.
        self.alternatives("manual", self.MINT)
        self.assertEqual(self.splash(self.picture)["value"], self.ours)
        st = self.splash("--restore")
        self.assertEqual((st["mode"], st["value"]), ("manual", self.MINT))
        self.assertNotIn(self.ours, st["alts"])

    def test_restore_leaves_auto_mode_as_it_was(self):
        self.alternatives("auto", self.BGRT)
        self.splash(self.picture)
        st = self.splash("--restore")
        self.assertEqual((st["mode"], st["value"]), ("auto", self.BGRT))

    def test_restore_after_the_older_script_picks_mint(self):
        # Ours is the manual default with no record of what came before, and
        # Mint's ranks below bgrt, so auto mode alone would end on bgrt.
        self.older_install("manual", self.ours)
        self.assertEqual(self.splash(self.picture)["value"], self.ours)
        self.assertFalse(os.path.exists(os.path.join(self.ours_dir, "previous-theme")))
        st = self.splash("--restore")
        self.assertEqual((st["mode"], st["value"]), ("manual", self.MINT))
        self.assertNotIn(self.ours, st["alts"])
        self.assertFalse(os.path.exists(self.ours_dir))

    def test_restore_with_no_record_keeps_a_theme_chosen_since(self):
        # Ours is installed but someone chose bgrt by hand after: leave it.
        self.older_install("manual", self.BGRT)
        st = self.splash("--restore")
        self.assertEqual((st["mode"], st["value"]), ("manual", self.BGRT))
        self.assertNotIn(self.ours, st["alts"])


class TestBoxReportKeys(Scratch):
    """tools/box-report.sh --keys and the daemon service it pauses. The
    capture itself (python3) and sleep are stand-ins; ps reports the daemon's
    children from $STUB_STATE/children-<call>, else $STUB_STATE/children."""

    STUBS = {
        "systemctl": r"""#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >> "$STUB_LOG"
case " $* " in
	*" is-active "*) exit 0 ;;
	*" show "*) echo 4242 ;;
esac
""",
        "ps": r"""#!/usr/bin/env bash
printf 'ps %s\n' "$*" >> "$STUB_LOG"
n=$(( $(cat "$STUB_STATE/ps-calls" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$STUB_STATE/ps-calls"
f="$STUB_STATE/children-$n"
[ -f "$f" ] || f="$STUB_STATE/children"
[ -f "$f" ] && cat "$f"
exit 0
""",
        "python3": "#!/usr/bin/env bash\necho capture >> \"$STUB_LOG\"\n",
        "sleep": "#!/usr/bin/env bash\nexit 0\n",
    }

    def setUp(self):
        super().setUp()
        for name, text in self.STUBS.items():
            self.write(os.path.join(self.stubs, name), text, 0o755)

    def keys(self, typed="\n"):
        p = self.run_script("tools/box-report.sh", "--keys", typed=typed,
                            env={"BOX_REPORT_DIR": os.path.join(self.tmp, "report")})
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        self.assertIn("capture", self.logged())
        return p.stdout

    def test_no_app_open_pauses_the_service(self):
        # A zombie and a helper the daemon runs for a moment are not apps.
        self.write(os.path.join(self.state, "children"), "Z    spotify\nS    wmctrl\n")
        out = self.keys()
        self.assertNotIn("Press Home", out)
        log = self.logged()
        self.assertIn("ps --ppid 4242 -o stat=,comm=", log)
        stop = log.index("systemctl --user stop boscamor-input.service")
        self.assertLess(stop, log.index("capture"))
        self.assertLess(log.index("capture"), log.index("systemctl --user start boscamor-input.service"))

    def test_an_open_app_is_closed_first(self):
        # A flatpak app: its bwrap is the daemon's child. Home closes it.
        self.write(os.path.join(self.state, "children-1"), "Sl   bwrap\n")
        out = self.keys()
        self.assertIn("Press Home on the remote to close it, then press Enter here.", out)
        log = self.logged()
        self.assertLess(log.index("systemctl --user stop boscamor-input.service"), log.index("capture"))

    def test_an_app_still_open_keeps_the_service_running(self):
        self.write(os.path.join(self.state, "children"), "Sl   firefox\n")
        out = self.keys()
        self.assertIn("Press Home on the remote to close it", out)
        self.assertIn("The app is still open", out)
        log = self.logged()
        self.assertNotIn("systemctl --user stop boscamor-input.service", log)
        self.assertNotIn("systemctl --user start boscamor-input.service", log)


if __name__ == "__main__":
    unittest.main()
