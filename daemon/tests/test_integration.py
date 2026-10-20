"""A headless launcher connects to a real daemon, launches, and hears app_exited.

Needs Godot: `godot` on PATH, or BOSCAMOR_GODOT set to the binary. Skipped
otherwise. A Windows godot.exe under WSL works too; paths are translated.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
DAEMON = os.path.join(REPO, "daemon", "boscamor-input.py")
GODOT = os.environ.get("BOSCAMOR_GODOT") or shutil.which("godot")


def host_path(path):
    """The path as Godot sees it; a Windows Godot under WSL needs C:\ paths."""
    if GODOT and GODOT.lower().endswith(".exe"):
        return subprocess.check_output(["wslpath", "-w", path], text=True).strip()
    return path


@unittest.skipUnless(GODOT, "no Godot binary (set BOSCAMOR_GODOT)")
class TestLauncherRoundtrip(unittest.TestCase):
    def test_launch_and_app_exited(self):
        os.makedirs(os.path.join(REPO, "build"), exist_ok=True)
        # Under the repo so a Windows Godot can read it too.
        runtime = tempfile.mkdtemp(prefix="it-runtime-", dir=os.path.join(REPO, "build"))
        env = dict(os.environ, BOSCAMOR_DRY_RUN="1", BOSCAMOR_RUNTIME_DIR=runtime)
        daemon = subprocess.Popen([sys.executable, DAEMON, "--no-evdev"], env=env,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        try:
            deadline = time.monotonic() + 5
            while not os.path.exists(os.path.join(runtime, "token")):
                self.assertLess(time.monotonic(), deadline, "daemon wrote no token")
                time.sleep(0.05)
            godot = subprocess.run(
                [GODOT, "--headless", "--path", host_path(os.path.join(REPO, "launcher")),
                 "-s", "res://tests/daemon_roundtrip.gd", "--", "--runtime-dir=" + host_path(runtime)],
                capture_output=True, text=True, timeout=60)
            out = godot.stdout + godot.stderr
            self.assertEqual(godot.returncode, 0, out)
            self.assertIn("roundtrip: launch and app_exited ok", out)
        finally:
            daemon.terminate()
            log = daemon.communicate(timeout=5)[0]
            shutil.rmtree(runtime, ignore_errors=True)
        self.assertIn("launched dummy", log)
        self.assertIn("dummy exited with 0", log)


if __name__ == "__main__":
    unittest.main()
