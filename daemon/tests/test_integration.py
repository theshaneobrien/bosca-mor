"""A headless launcher connects to a real daemon, launches, and hears app_exited.

The daemon runs with --dev-port and the launcher finds it through BOSCAMOR_IPC,
the way the Windows launcher reaches the WSL2 daemon (SPEC "IPC", Dev override).

Needs Godot: `godot` on PATH, or BOSCAMOR_GODOT set to the binary. Skipped
otherwise. A Windows godot.exe under WSL works too.
"""
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
DAEMON = os.path.join(REPO, "daemon", "boscamor-input.py")
GODOT = os.environ.get("BOSCAMOR_GODOT") or shutil.which("godot")
WINDOWS_GODOT = bool(GODOT) and GODOT.lower().endswith(".exe")


def host_path(path):
    """The path as Godot sees it; a Windows Godot under WSL needs C:\\ paths."""
    if WINDOWS_GODOT:
        return subprocess.check_output(["wslpath", "-w", path], text=True).strip()
    return path


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@unittest.skipUnless(GODOT, "no Godot binary (set BOSCAMOR_GODOT)")
class TestLauncherRoundtrip(unittest.TestCase):
    def test_launch_and_app_exited(self):
        os.makedirs(os.path.join(REPO, "build"), exist_ok=True)
        # Its own BOSCAMOR_HOME, so the runtime files never touch a real daemon's.
        home = tempfile.mkdtemp(prefix="it-home-", dir=os.path.join(REPO, "build"))
        env = dict(os.environ, BOSCAMOR_DRY_RUN="1", BOSCAMOR_HOME=home)
        env.pop("BOSCAMOR_RUNTIME_DIR", None)
        daemon = subprocess.Popen(
            [sys.executable, DAEMON, "--no-evdev", "--dev-port", str(free_port())], env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        lines = []
        reader = threading.Thread(target=lambda: lines.extend(daemon.stdout), daemon=True)
        reader.start()
        try:
            deadline = time.monotonic() + 5
            ipc = None
            while ipc is None:
                self.assertLess(time.monotonic(), deadline, "daemon printed no token: %s" % lines)
                ipc = next((l.strip().split("=", 1)[1] for l in list(lines)
                            if l.startswith("BOSCAMOR_IPC=")), None)
                time.sleep(0.05)
            genv = dict(os.environ, BOSCAMOR_IPC=ipc)
            if WINDOWS_GODOT:  # WSL passes only the variables WSLENV names to Windows
                genv["WSLENV"] = ":".join(filter(None, [os.environ.get("WSLENV"), "BOSCAMOR_IPC"]))
            godot = subprocess.run(
                [GODOT, "--headless", "--path", host_path(os.path.join(REPO, "launcher")),
                 "-s", "res://tests/daemon_roundtrip.gd"],
                env=genv, capture_output=True, text=True, timeout=60)
            out = godot.stdout + godot.stderr
            self.assertEqual(godot.returncode, 0, out)
            self.assertIn("roundtrip: launch and app_exited ok", out)
        finally:
            daemon.terminate()
            daemon.wait(timeout=5)
            reader.join(5)
            daemon.stdout.close()
            shutil.rmtree(home, ignore_errors=True)
        log = "".join(lines)
        self.assertIn("launched dummy", log)
        self.assertIn("dummy exited with 0", log)


if __name__ == "__main__":
    unittest.main()
