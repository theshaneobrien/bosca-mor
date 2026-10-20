import importlib.util
import json
import os
import signal
import socket
import struct
import sys
import tempfile
import threading
import time
import unittest

os.environ["BOSCAMOR_DRY_RUN"] = "1"  # always, before anything can act

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "boscamor_input", os.path.join(HERE, "..", "boscamor-input.py"))
bi = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bi)


def bitmap(codes):
    """A /proc/bus/input/devices KEY= bitmap with these codes set."""
    words = [0] * (max(codes) // 64 + 1)
    for c in codes:
        words[c // 64] |= 1 << (c % 64)
    return " ".join("%x" % w for w in reversed(words))


class Recorder(bi.Daemon):
    """A daemon that records what it sends, runs and signals."""

    def __init__(self, **kw):
        kw.setdefault("runtime", tempfile.mkdtemp())
        kw.setdefault("evdev", False)
        super().__init__(**kw)
        self.sent = []
        self.ran = []
        self.signals = []
        self.clock = None

    def now(self):
        return self.clock if self.clock is not None else super().now()

    def send(self, evt):
        self.sent.append(evt)
        super().send(evt)

    def run_cmd(self, argv):
        self.ran.append(argv)

    def signal_group(self, pgid, sig):
        if sig:
            self.signals.append((sig, time.monotonic()))
        super().signal_group(pgid, sig)

    def events(self, name):
        return [e for e in self.sent if e.get("evt") == name]

    def pump(self, until, timeout=6.0):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            self.run_once(0.02)
            if until():
                return True
        return False


class DaemonCase(unittest.TestCase):
    def setUp(self):
        self.d = Recorder()

    def tearDown(self):
        if self.d.app:
            try:
                os.killpg(self.d.app.pgid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.d.app.proc.wait()
        self.d.close()


class TestEvdev(unittest.TestCase):
    def test_packed_events_parse(self):
        raw = (struct.pack("llHHi", 1700000000, 250000, 1, 172, 1)
               + struct.pack("llHHi", 1700000000, 250100, 0, 0, 0)
               + struct.pack("llHHi", 1700000001, 5, 1, 172, 0))
        self.assertEqual(bi.EVENT.size, 24)
        events, rest = bi.parse_events(raw + raw[:10])
        self.assertEqual(events, [
            (1700000000, 250000, 1, 172, 1),
            (1700000000, 250100, 0, 0, 0),
            (1700000001, 5, 1, 172, 0),
        ])
        self.assertEqual(rest, raw[:10])
        more, rest = bi.parse_events(rest + raw[10:24])
        self.assertEqual(more, [(1700000000, 250000, 1, 172, 1)])
        self.assertEqual(rest, b"")

    def test_key_bitmap(self):
        self.assertTrue(bi.has_key("10000000000000 0", bi.KEY_POWER))  # ACPI power button
        self.assertFalse(bi.has_key("10000000000000 0", bi.KEY_HOMEPAGE))
        bm = bitmap([bi.KEY_HOMEPAGE, bi.BTN_MODE])
        self.assertTrue(bi.has_key(bm, bi.BTN_MODE))
        self.assertTrue(bi.has_key(bm, bi.KEY_HOMEPAGE))
        self.assertFalse(bi.has_key(bm, bi.KEY_POWER))
        self.assertFalse(bi.has_key("0", bi.BTN_MODE))

    def test_devices_with_watched_keys_are_picked(self):
        with open(os.path.join(HERE, "fixtures", "proc_bus_input_devices.txt")) as f:
            found = bi.parse_devices(f.read())
        self.assertEqual(found, {
            "/dev/input/event2": "Power Button",
            "/dev/input/event5": "G20S remote",
            "/dev/input/event9": "Xbox Wireless Controller",
        })


class TestKeys(DaemonCase):
    def test_power_key_only_asks_to_confirm(self):
        self.d.on_key("kbd", bi.KEY_POWER, 1)
        self.assertEqual(self.d.events("power_confirm"), [{"evt": "power_confirm"}])
        self.assertEqual(self.d.ran, [])

    def test_repeats_and_releases_ignored(self):
        self.d.on_key("kbd", bi.KEY_POWER, 2)
        self.d.on_key("kbd", bi.KEY_HOMEPAGE, 0)
        self.d.on_key("kbd", bi.KEY_HOMEPAGE, 2)
        self.assertEqual(self.d.sent, [])

    def test_home_ignored_while_launcher_shows(self):
        self.d.handle({"cmd": "state", "visible": True})
        self.d.on_key("kbd", bi.KEY_HOMEPAGE, 1)
        self.d.on_key("pad", bi.BTN_MODE, 1)
        self.assertEqual(self.d.sent, [])

    def test_home_guide_and_super_home_show_when_hidden(self):
        self.d.handle({"cmd": "state", "visible": False})
        self.d.on_key("kbd", bi.KEY_HOMEPAGE, 1)
        self.d.on_key("pad", bi.BTN_MODE, 1)
        self.d.on_key("kbd", bi.KEY_HOME, 1)  # Home alone is the launcher's own key
        self.assertEqual(len(self.d.events("show")), 2)
        self.d.on_key("kbd", bi.KEY_LEFTMETA, 1)
        self.d.on_key("kbd", bi.KEY_HOME, 1)
        self.assertEqual(len(self.d.events("show")), 3)
        self.d.on_key("kbd", bi.KEY_LEFTMETA, 0)
        self.d.on_key("kbd", bi.KEY_HOME, 1)
        self.assertEqual(len(self.d.events("show")), 3)

    def test_wmctrl_raises_if_launcher_stays_hidden(self):
        self.d.clock = 100.0
        self.d.on_home()
        self.d.clock = 100.6
        self.d.tick()
        self.assertEqual(self.d.ran, [["wmctrl", "-F", "-a", bi.LAUNCHER_TITLE]])

    def test_no_raise_if_launcher_reports_visible(self):
        self.d.clock = 100.0
        self.d.on_home()
        self.d.handle({"cmd": "state", "visible": True})
        self.d.clock = 101.0
        self.d.tick()
        self.assertEqual(self.d.ran, [])

    def test_desktop_sends_notification(self):
        self.d.handle({"cmd": "desktop"})
        self.assertEqual(self.d.ran, [["notify-send", bi.NOTIFY_TITLE, bi.NOTIFY_BODY]])
        self.assertNotIn("Bosca", bi.NOTIFY_TITLE + bi.NOTIFY_BODY)


class TestPower(DaemonCase):
    def test_power_is_dry_run_under_tests(self):
        self.assertEqual(os.environ.get("BOSCAMOR_DRY_RUN"), "1")
        with self.assertLogs("boscamor-input", "INFO") as logs:
            self.d.handle({"cmd": "power", "action": "poweroff"})
            self.d.handle({"cmd": "power", "action": "reboot"})
        self.assertEqual(self.d.ran, [])
        self.assertIn("dry run: would run systemctl poweroff", "\n".join(logs.output))
        self.assertIn("dry run: would run systemctl reboot", "\n".join(logs.output))

    def test_unknown_power_action_does_nothing(self):
        self.d.handle({"cmd": "power", "action": "halt"})
        self.d.handle({"cmd": "power"})
        self.assertEqual(self.d.ran, [])


class TestApps(DaemonCase):
    def test_launch_reports_exit(self):
        self.d.handle({"cmd": "launch", "id": "dummy", "argv": ["sleep", "0.2"]})
        self.assertEqual(self.d.app.id, "dummy")
        self.assertTrue(self.d.pump(lambda: self.d.events("app_exited")))
        self.assertEqual(self.d.events("app_exited"), [{"evt": "app_exited", "id": "dummy", "code": 0}])
        self.assertIsNone(self.d.app)

    def test_launch_failure_reported(self):
        self.d.handle({"cmd": "launch", "id": "nope", "argv": ["/no/such/binary"]})
        failed = self.d.events("launch_failed")
        self.assertEqual(len(failed), 1)
        self.assertEqual(failed[0]["id"], "nope")
        self.d.handle({"cmd": "launch", "id": "bad", "argv": "sleep 60"})
        self.assertEqual(len(self.d.events("launch_failed")), 2)
        self.assertIsNone(self.d.app)

    def test_home_terms_the_group_then_shows(self):
        self.d.handle({"cmd": "launch", "id": "dummy", "argv": ["sleep", "60"]})
        self.d.handle({"cmd": "state", "visible": False})
        self.d.on_home()
        self.assertTrue(self.d.pump(lambda: self.d.events("show")))
        self.assertEqual([s for s, _ in self.d.signals], [signal.SIGTERM])
        self.assertEqual(self.d.events("app_exited")[0]["id"], "dummy")
        self.assertLess(self.d.sent.index(self.d.events("app_exited")[0]),
                        self.d.sent.index({"evt": "show"}))

    def test_home_kills_after_three_seconds(self):
        # The shell ignores SIGTERM, and so does the sleep it starts.
        self.d.handle({"cmd": "launch", "id": "stubborn",
                       "argv": ["sh", "-c", "trap '' TERM; sleep 60; true"]})
        time.sleep(0.2)
        self.d.handle({"cmd": "state", "visible": False})
        start = time.monotonic()
        self.d.on_home()
        self.assertTrue(self.d.pump(lambda: self.d.events("show"), timeout=8))
        sigs = self.d.signals
        self.assertEqual([s for s, _ in sigs], [signal.SIGTERM, signal.SIGKILL])
        self.assertGreaterEqual(sigs[1][1] - start, bi.GRACE_S - 0.05)
        self.assertLess(sigs[1][1] - start, bi.GRACE_S + 0.5)
        self.assertEqual(self.d.events("app_exited")[0]["code"], -signal.SIGKILL)

    def test_keep_on_home_keeps_running(self):
        self.d.handle({"cmd": "launch", "id": "music", "argv": ["sleep", "60"], "keep_on_home": True})
        self.d.handle({"cmd": "state", "visible": False})
        self.d.on_home()
        self.assertEqual(self.d.events("show"), [{"evt": "show"}])
        self.assertEqual(self.d.signals, [])
        self.assertEqual(self.d.app.id, "music")

    def test_second_launch_ends_the_first(self):
        self.d.handle({"cmd": "launch", "id": "a", "argv": ["sleep", "60"]})
        first = self.d.app.proc
        self.d.handle({"cmd": "launch", "id": "b", "argv": ["sleep", "60"]})
        self.assertTrue(self.d.pump(lambda: self.d.app and self.d.app.id == "b"))
        self.assertIsNotNone(first.poll())
        self.assertEqual(self.d.events("app_exited")[0]["id"], "a")
        self.assertEqual(self.d.events("show"), [])
        self.assertEqual(self.d.signals[0][0], signal.SIGTERM)

    def test_only_signals_its_own_group(self):
        self.d.handle({"cmd": "launch", "id": "dummy", "argv": ["sleep", "60"]})
        self.assertEqual(self.d.app.pgid, self.d.app.proc.pid)
        self.assertEqual(os.getpgid(self.d.app.proc.pid), self.d.app.proc.pid)
        self.assertNotEqual(os.getpgid(self.d.app.proc.pid), os.getpgrp())


class TestMemory(DaemonCase):
    def setUp(self):
        super().setUp()
        self.proc = tempfile.mkdtemp()
        self.d.proc_root = self.proc

    def meminfo(self, avail_mb):
        with open(os.path.join(self.proc, "meminfo"), "w") as f:
            f.write("MemTotal:        3900000 kB\nMemAvailable:    %d kB\n" % (avail_mb * 1024))

    def test_warns_once_after_thirty_seconds_low(self):
        self.meminfo(400)
        for t in (0, 10, 20):
            self.d.clock = float(t)
            self.d.sample_memory()
        self.assertEqual(self.d.events("memory_warning"), [])
        for t in (30, 40):
            self.d.clock = float(t)
            self.d.sample_memory()
        warn = self.d.events("memory_warning")
        self.assertEqual(len(warn), 1)
        self.assertEqual(warn[0]["available_mb"], 400)
        self.meminfo(900)
        self.d.clock = 50.0
        self.d.sample_memory()
        self.meminfo(300)
        for t in (60, 70, 80, 90):
            self.d.clock = float(t)
            self.d.sample_memory()
        self.assertEqual(len(self.d.events("memory_warning")), 2)

    def test_short_dip_does_not_warn(self):
        for t, mb in ((0, 400), (10, 400), (20, 600), (30, 400), (40, 400)):
            self.meminfo(mb)
            self.d.clock = float(t)
            self.d.sample_memory()
        self.assertEqual(self.d.events("memory_warning"), [])

    def test_group_rss_sums_the_app_group(self):
        def proc(pid, pgrp, rss_kb):
            os.makedirs(os.path.join(self.proc, str(pid)))
            with open(os.path.join(self.proc, str(pid), "stat"), "w") as f:
                f.write("%d (a (weird) name) S 1 %d %d 0 -1\n" % (pid, pgrp, pgrp))
            with open(os.path.join(self.proc, str(pid), "status"), "w") as f:
                f.write("Name:\tx\nVmRSS:\t   %d kB\n" % rss_kb)
        proc(500, 500, 102400)
        proc(501, 500, 51200)
        proc(600, 600, 999999)
        self.assertEqual(self.d.group_rss_mb(500), 150)


class TestIPC(unittest.TestCase):
    def setUp(self):
        self.runtime = os.path.join(tempfile.mkdtemp(), "boscamor")
        self.d = Recorder(runtime=self.runtime)
        self.d.start()
        self.stop = False
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()

    def _loop(self):
        while not self.stop:
            self.d.run_once(0.02)

    def tearDown(self):
        self.stop = True
        self.thread.join(2)
        self.d.close()

    def connect(self, first_line):
        s = socket.create_connection(("127.0.0.1", self.d.port), timeout=2)
        s.sendall(first_line + b"\n")
        return s

    def token(self):
        with open(os.path.join(self.runtime, "token")) as f:
            return f.read().strip()

    def test_runtime_files(self):
        self.assertEqual(os.stat(self.runtime).st_mode & 0o777, 0o700)
        with open(os.path.join(self.runtime, "port")) as f:
            self.assertEqual(int(f.read()), self.d.port)
        self.assertEqual(len(bytes.fromhex(self.token())), 32)
        self.assertEqual(os.stat(os.path.join(self.runtime, "token")).st_mode & 0o777, 0o600)

    def test_bad_token_is_dropped(self):
        s = self.connect(b"not-the-token")
        s.sendall(b'{"cmd":"state","visible":false}\n')
        self.assertEqual(s.recv(100), b"")  # closed by the daemon
        s.close()
        time.sleep(0.1)
        self.assertEqual(self.d.clients, [])
        self.assertFalse(self.d.visible)

    def test_silent_client_is_dropped(self):
        s = socket.create_connection(("127.0.0.1", self.d.port), timeout=4)
        self.assertEqual(s.recv(100), b"")
        s.close()

    def test_good_token_then_messages(self):
        s = self.connect(self.token().encode())
        s.sendall(b'{"cmd":"state","visible":false}\nnot json\n')
        time.sleep(0.2)
        self.d.on_power()
        self.assertEqual(json.loads(s.makefile().readline()), {"evt": "power_confirm"})
        s.close()

    def test_return_shortcut(self):
        s = self.connect(self.token().encode())
        s.sendall(b'{"cmd":"state","visible":false}\n')
        time.sleep(0.1)
        self.assertEqual(bi.send_return(self.runtime), 0)
        self.assertEqual(json.loads(s.makefile().readline()), {"evt": "show"})
        s.close()

    def test_return_without_daemon(self):
        self.assertEqual(bi.send_return(tempfile.mkdtemp()), 1)


if __name__ == "__main__":
    unittest.main()
