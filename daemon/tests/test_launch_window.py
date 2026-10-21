"""The launched app's first window (D63): app_window when a new client
shows, and the 15 s give-up that ends the app the way Home does. Window
lists come from the xprop fixtures; the clock is fake."""
import os
import signal
import unittest

os.environ["BOSCAMOR_DRY_RUN"] = "1"

from test_daemon import Recorder, bi  # noqa: E402
from test_return import FakeX  # noqa: E402

NOTIFICATION = "0x5800009"
LAUNCHER = "0x5200005"
PLEX = "0x6000003"
SPLASH = "0x6200001"


class LaunchCase(unittest.TestCase):
    def setUp(self):
        self.d = FakeX()
        # The notification and the launcher's own window appear after the
        # launch in some tests, so start without them.
        self.d.open_windows = [w for w in self.d.open_windows
                               if bi.norm_wid(w) not in (NOTIFICATION, LAUNCHER)]
        self.d.handle({"cmd": "launch", "id": "plex", "argv": ["sleep", "60"]})

    def tearDown(self):
        if self.d.app:
            try:
                os.killpg(self.d.app.pgid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.d.app.proc.wait()
        self.d.close()

    def at(self, t):
        """Moves the fake clock to t seconds after launch and runs the loop once."""
        self.d.clock = 1000.0 + t
        self.d.tick()


class TestFirstWindow(LaunchCase):
    def test_new_app_window_is_reported_once(self):
        self.at(0.5)
        self.assertEqual(self.d.events("app_window"), [])
        self.d.open_windows.append(PLEX)
        self.at(1.0)
        self.assertEqual(self.d.events("app_window"), [{"evt": "app_window", "id": "plex"}])
        self.assertIn(["wmctrl", "-i", "-a", bi.norm_wid(PLEX)], self.d.ran,
                      "raised above the waiting launcher (D65)")
        calls = self.d.xprop_calls
        self.at(1.5)
        self.at(20.0)
        self.assertEqual(self.d.xprop_calls, calls, "no more polling once the window showed")
        self.assertEqual(len(self.d.events("app_window")), 1)
        self.assertEqual(self.d.events("launch_timeout"), [])
        self.assertEqual(self.d.signals, [])
        self.assertEqual(self.d.app.id, "plex")

    def test_windows_open_before_launch_do_not_count(self):
        self.at(14.5)
        self.assertEqual(self.d.events("app_window"), [], "Firefox, Writer and the editor were already open")

    def test_launcher_and_notifications_do_not_count(self):
        self.d.open_windows += [LAUNCHER, NOTIFICATION]
        self.at(0.5)
        self.assertEqual(self.d.events("app_window"), [])
        self.d.open_windows.append(PLEX)
        self.at(1.0)
        self.assertEqual(len(self.d.events("app_window")), 1)

    def test_splash_counts(self):
        self.d.open_windows.append(SPLASH)
        self.at(0.5)
        self.assertEqual(len(self.d.events("app_window")), 1)

    def test_polls_every_half_second(self):
        calls = self.d.xprop_calls
        self.at(0.2)
        self.assertEqual(self.d.xprop_calls, calls, "not before 500 ms")
        self.at(0.5)
        self.assertEqual(self.d.xprop_calls, calls + 1, "one root read, nothing new to inspect")
        self.d.clock = 1000.5
        self.assertAlmostEqual(self.d.next_timeout(), bi.WINDOW_POLL_S, places=3)


class TestGiveUp(LaunchCase):
    def test_no_window_in_15_s_ends_the_app_like_home(self):
        self.at(14.9)
        self.assertEqual(self.d.events("launch_timeout"), [])
        self.assertEqual(self.d.signals, [])
        self.at(15.0)
        self.assertEqual(self.d.events("launch_timeout"), [{"evt": "launch_timeout", "id": "plex"}])
        self.assertEqual([s for s, _ in self.d.signals], [signal.SIGTERM])
        self.assertTrue(self.d.app.closing)
        # The real sleep ends on SIGTERM; the loop reports it, then shows Home.
        self.d.clock = None
        self.assertTrue(self.d.pump(lambda: self.d.events("show")))
        self.assertEqual(self.d.events("app_exited")[0]["id"], "plex")
        self.assertLess(self.d.sent.index(self.d.events("launch_timeout")[0]),
                        self.d.sent.index(self.d.events("app_exited")[0]))
        self.assertEqual(len(self.d.events("launch_timeout")), 1)

    def test_keep_on_home_app_still_ends(self):
        self.d.app.keep_on_home = True
        self.at(15.0)
        self.assertEqual([s for s, _ in self.d.signals], [signal.SIGTERM])

    def test_app_that_exits_is_not_timed(self):
        self.d.app.proc.kill()
        self.d.app.proc.wait()
        self.at(0.1)
        self.assertIsNone(self.d.app)
        self.at(15.0)
        self.assertEqual(self.d.events("launch_timeout"), [])

    def test_home_before_the_window_stops_the_watch(self):
        self.d.handle({"cmd": "state", "visible": False})
        self.d.on_home()
        self.at(15.0)
        self.assertEqual(self.d.events("launch_timeout"), [], "Home is already ending it")


class TestNoWindowList(unittest.TestCase):
    def test_without_x_the_launch_is_not_timed(self):
        d = Recorder()  # its run_capture returns "", like a box with no xprop
        d.clock = 1000.0
        d.handle({"cmd": "launch", "id": "plex", "argv": ["sleep", "60"]})
        try:
            self.assertEqual(d.events("app_window"), [{"evt": "app_window", "id": "plex"}])
            d.clock = 1100.0
            d.tick()
            self.assertEqual(d.events("launch_timeout"), [])
            self.assertEqual(d.signals, [])
        finally:
            os.killpg(d.app.pgid, signal.SIGKILL)
            d.app.proc.wait()
            d.close()

    def test_client_list_parse(self):
        d = FakeX()
        self.assertIn("0x2a00003", d.client_list())
        d.run_capture = lambda argv: "_NET_CLIENT_LIST:  not found.\n"
        self.assertIsNone(d.client_list())
        d.close()

    def test_is_app_window(self):
        def props(name):
            with open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                   "fixtures", "xprop", name + ".txt")) as f:
                return bi.parse_window(f.read())
        self.assertTrue(bi.is_app_window(props(PLEX)))
        self.assertTrue(bi.is_app_window(props(SPLASH)))
        self.assertTrue(bi.is_app_window(props("0x4400002")), "no type: NORMAL")
        self.assertTrue(bi.is_app_window(props("0x3a0012a")), "a dialog counts")
        self.assertFalse(bi.is_app_window(props(LAUNCHER)))
        self.assertFalse(bi.is_app_window(props(NOTIFICATION)))
        self.assertFalse(bi.is_app_window(props("0x1c00003")), "desktop")
        self.assertFalse(bi.is_app_window(props("0x1e00004")), "panel")


if __name__ == "__main__":
    unittest.main()
