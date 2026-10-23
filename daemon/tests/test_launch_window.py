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
QT_FRAMELESS = "0x6400004"   # _KDE_NET_WM_WINDOW_TYPE_OVERRIDE, then NORMAL
QT_UTILITY = "0x6400005"     # UTILITY, the KDE atom, then NORMAL


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
        self.assertEqual(self.d.events("app_window"), [], "seen, but kept behind the black launcher (D77)")
        self.assertNotIn(["wmctrl", "-i", "-a", bi.norm_wid(PLEX)], self.d.ran)
        self.at(1.0 + bi.APP_REVEAL_S)
        self.assertEqual(self.d.events("app_window"), [{"evt": "app_window", "id": "plex"}])
        self.assertIn(["wmctrl", "-i", "-a", bi.norm_wid(PLEX)], self.d.ran,
                      "then raised above the waiting launcher (D65)")
        self.d.active = PLEX          # Plex took the focus
        self.at(1.5 + bi.APP_REVEAL_S)
        self.assertIsNone(self.d.app.activate_until, "focus hand-off done")
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
        self.at(1.0 + bi.APP_REVEAL_S)
        self.assertEqual(len(self.d.events("app_window")), 1)

    def test_splash_counts(self):
        self.d.open_windows.append(SPLASH)
        self.at(0.5)
        self.at(0.5 + bi.APP_REVEAL_S)
        self.assertEqual(len(self.d.events("app_window")), 1)

    def test_app_that_exits_during_the_reveal_wait_is_not_raised(self):
        self.d.open_windows.append(PLEX)
        self.at(1.0)
        self.d.app.proc.kill()
        self.d.app.proc.wait()
        self.at(1.1)
        self.at(1.0 + bi.APP_REVEAL_S)
        self.assertEqual(self.d.events("app_window"), [])
        self.assertNotIn(["wmctrl", "-i", "-a", bi.norm_wid(PLEX)], self.d.ran)

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

    def test_launch_while_the_timed_out_app_closes_sends_no_show(self):
        # "Plex took too long to open", and the viewer picks it again at
        # once, inside the SIGTERM grace (D86).
        self.at(15.0)
        self.assertTrue(self.d.app.show_after)
        self.d.handle({"cmd": "launch", "id": "plex", "argv": ["sleep", "60"]})
        self.assertFalse(self.d.app.show_after, "the launcher asked for an app, not Home")
        self.d.clock = None
        self.assertTrue(self.d.pump(lambda: self.d.app and not self.d.app.closing))
        self.assertEqual([e.get("replaced") for e in self.d.events("app_exited")], [True])
        self.assertEqual(self.d.events("show"), [])
        self.assertNotIn(["wmctrl", "-F", "-a", bi.LAUNCHER_TITLE], self.d.ran)


class TestLauncherBack(LaunchCase):
    """The launcher comes back on screen while the app is still opening:
    Power on the loading screen, Home on a keep_on_home app, the launcher's
    own deadline (D85). Nothing raises the app over it."""

    def raises(self):
        return [r for r in self.d.ran if r == ["wmctrl", "-i", "-a", PLEX]]

    def test_back_before_the_reveal_ends_the_app(self):
        self.d.handle({"cmd": "state", "visible": False})   # the launch fade ended
        self.d.open_windows.append(PLEX)
        self.at(1.0)
        self.d.handle({"cmd": "state", "visible": True})    # Power
        self.assertEqual([s for s, _ in self.d.signals], [signal.SIGTERM])
        self.assertIsNone(self.d.app.reveal_at)
        self.at(1.0 + bi.APP_REVEAL_S)
        self.at(5.0)
        self.assertEqual(self.raises(), [])
        self.assertEqual(self.d.events("app_window"), [])

    def test_kept_app_is_left_behind_the_launcher(self):
        self.d.app.keep_on_home = True
        self.d.handle({"cmd": "state", "visible": False})
        self.d.open_windows.append(PLEX)
        self.d.active = LAUNCHER
        self.at(1.0)
        self.d.handle({"cmd": "state", "visible": True})
        self.assertEqual(self.d.signals, [])
        self.assertEqual(self.d.events("app_window"), [{"evt": "app_window", "id": "plex"}],
                         "its window is up: the launcher stops waiting")
        for t in (1.0 + bi.APP_REVEAL_S, 4.0, 4.5, 6.0):
            self.at(t)
        self.assertEqual(self.raises(), [])
        self.assertEqual(len(self.d.events("app_window")), 1)
        self.assertIsNone(self.d.app.activate_until)

    def test_kept_app_window_after_home_is_not_raised(self):
        # Home on the loading screen of a keep_on_home app: Home shows, and
        # the app's window comes later.
        self.d.app.keep_on_home = True
        self.d.handle({"cmd": "state", "visible": False})
        self.at(1.0)
        self.d.on_home()
        self.assertEqual(self.d.events("show"), [{"evt": "show"}])
        self.d.handle({"cmd": "state", "visible": True})
        self.d.open_windows.append(PLEX)
        self.at(2.0)
        self.at(2.0 + bi.APP_REVEAL_S)
        self.assertEqual(self.d.events("app_window"), [{"evt": "app_window", "id": "plex"}])
        self.assertEqual(self.raises(), [])
        self.d.on_home()
        self.assertEqual(len(self.d.events("show")), 1, "the launcher sees Home itself now")

    def test_back_during_the_hand_off_stops_it(self):
        self.d.handle({"cmd": "state", "visible": False})
        self.d.open_windows.append(PLEX)
        self.d.active = LAUNCHER
        self.at(0.5)
        self.at(0.5 + bi.APP_REVEAL_S)
        self.assertEqual(len(self.raises()), 1)
        self.d.handle({"cmd": "state", "visible": True})   # Power while the app takes over
        for t in (3.0, 3.5, 4.0, 5.0):
            self.at(t)
        self.assertEqual(len(self.raises()), 1, "no raise over the confirm")
        self.assertEqual([s for s, _ in self.d.signals], [signal.SIGTERM])

    def test_launcher_that_never_left_the_screen(self):
        # Power during the launch fade: the launcher was on screen at the
        # launch and never reported itself off it, so there is no edge.
        self.d.visible = True
        self.d.open_windows.append(PLEX)
        self.at(0.5)
        self.at(0.5 + bi.APP_REVEAL_S)
        self.assertEqual(self.raises(), [])
        self.assertEqual(self.d.events("app_window"), [{"evt": "app_window", "id": "plex"}])
        self.assertEqual([s for s, _ in self.d.signals], [signal.SIGTERM],
                         "not left running unseen behind the launcher")


class TestClosingDoesNotSpin(LaunchCase):
    """Home while the reveal or the focus hand-off is due: the loop wakes
    every CLOSING_POLL_S, not at once, while the app ends."""

    def test_home_during_the_reveal_wait(self):
        self.d.handle({"cmd": "state", "visible": False})
        self.d.open_windows.append(PLEX)
        self.at(1.0)
        self.d.clock = 1001.5
        self.d.on_home()
        self.d.clock = 1001.0 + bi.APP_REVEAL_S + 0.5
        self.assertIsNone(self.d.app.reveal_at)
        self.assertGreaterEqual(self.d.next_timeout(), bi.CLOSING_POLL_S - 1e-9)

    def test_home_during_the_hand_off(self):
        self.d.handle({"cmd": "state", "visible": False})
        self.d.open_windows.append(PLEX)
        self.d.active = LAUNCHER
        self.at(0.5)
        self.at(0.5 + bi.APP_REVEAL_S)
        self.d.clock = 1000.6 + bi.APP_REVEAL_S
        self.d.on_home()
        self.d.clock = 1001.5 + bi.APP_REVEAL_S   # past next_activate
        self.assertIsNone(self.d.app.activate_until)
        self.assertGreaterEqual(self.d.next_timeout(), bi.CLOSING_POLL_S - 1e-9)


class TestFirstWindowGone(LaunchCase):
    """A splash or updater window can close and give way to the main window
    before the reveal, or just after it."""

    def test_splash_replaced_before_the_reveal(self):
        self.d.active = LAUNCHER
        self.d.open_windows.append(SPLASH)
        self.at(0.5)
        self.d.open_windows.remove(SPLASH)
        self.d.open_windows.append(PLEX)
        self.at(0.5 + bi.APP_REVEAL_S)
        self.assertIn(["wmctrl", "-i", "-a", PLEX], self.d.ran)
        self.assertNotIn(["wmctrl", "-i", "-a", SPLASH], self.d.ran)
        self.assertEqual(len(self.d.events("app_window")), 1)

    def test_splash_gone_with_nothing_in_its_place_watches_again(self):
        self.d.open_windows.append(SPLASH)
        self.at(0.5)
        self.d.open_windows.remove(SPLASH)
        self.at(0.5 + bi.APP_REVEAL_S)
        self.assertEqual(self.d.events("app_window"), [], "the loading screen stays up")
        self.assertEqual(self.d.ran, [])
        self.assertEqual(self.d.app.window_deadline, 1000.0 + bi.LAUNCH_TIMEOUT_S,
                         "still the launch's own 15 s")
        self.d.open_windows.append(PLEX)
        self.at(5.0)
        self.at(5.0 + bi.APP_REVEAL_S)
        self.assertEqual(self.d.events("app_window"), [{"evt": "app_window", "id": "plex"}])
        self.assertIn(["wmctrl", "-i", "-a", PLEX], self.d.ran)

    def test_splash_gone_and_nothing_else_still_times_out(self):
        self.d.open_windows.append(SPLASH)
        self.at(0.5)
        self.d.open_windows.remove(SPLASH)
        self.at(0.5 + bi.APP_REVEAL_S)
        self.at(14.9)
        self.assertEqual(self.d.events("launch_timeout"), [])
        self.at(15.0)
        self.assertEqual(self.d.events("launch_timeout"), [{"evt": "launch_timeout", "id": "plex"}])

    def test_main_window_after_a_focused_splash_is_raised(self):
        self.d.open_windows.append(SPLASH)
        self.d.active = SPLASH            # the splash took the focus
        self.at(0.5)
        self.at(0.5 + bi.APP_REVEAL_S)
        self.at(1.0 + bi.APP_REVEAL_S)
        self.assertIsNotNone(self.d.app.activate_until, "a splash: keep watching")
        # The splash closes; the main window maps behind the launcher.
        self.d.open_windows.remove(SPLASH)
        self.d.open_windows.append(PLEX)
        self.d.active = LAUNCHER
        self.at(1.5 + bi.APP_REVEAL_S)
        self.assertIn(["wmctrl", "-i", "-a", PLEX], self.d.ran)
        self.d.active = PLEX
        self.at(2.0 + bi.APP_REVEAL_S)
        self.assertIsNone(self.d.app.activate_until, "the main window has the focus")

    def test_splash_watch_has_a_limit(self):
        self.d.open_windows.append(SPLASH)
        self.d.active = SPLASH
        t = 0.0
        while t < 30.0:
            t += 0.5
            self.at(t)
        self.assertIsNone(self.d.app.activate_until)
        calls = self.d.xprop_calls
        self.at(40.0)
        self.assertEqual(self.d.xprop_calls, calls, "nothing polls once it gave up")


class TestUnreadWindow(LaunchCase):
    def test_window_that_cannot_be_read_is_tried_again(self):
        # BadWindow: listed when the list was read, gone when its own xprop ran.
        real = self.d.run_capture
        dead = {PLEX}

        def capture(argv):
            if argv[:2] == ["xprop", "-id"] and argv[2] in dead:
                self.d.xprop_calls += 1
                return ""
            return real(argv)
        self.d.run_capture = capture
        self.d.open_windows.append(PLEX)
        self.at(0.5)
        self.assertIsNone(self.d.app.reveal_at, "not taken as the app's window")
        self.assertNotIn(PLEX, self.d.app.known)
        dead.clear()
        self.at(1.0)
        self.assertIsNotNone(self.d.app.reveal_at, "read on the next poll")

    def test_frameless_qt_window_counts(self):
        self.d.open_windows.append(QT_FRAMELESS)
        self.at(0.5)
        self.at(0.5 + bi.APP_REVEAL_S)
        self.assertEqual(self.d.events("app_window"), [{"evt": "app_window", "id": "plex"}])
        self.assertEqual(self.d.events("launch_timeout"), [])


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
        # Qt lists its own atom first on frameless windows; Muffin skips it.
        self.assertEqual(props(QT_FRAMELESS)["types"], ["_KDEOVERRIDE", "NORMAL"])
        self.assertTrue(bi.is_app_window(props(QT_FRAMELESS)))
        self.assertTrue(bi.closable(QT_FRAMELESS, props(QT_FRAMELESS)))
        self.assertFalse(bi.is_app_window(props(QT_UTILITY)))
        self.assertFalse(bi.closable(QT_UTILITY, props(QT_UTILITY)))

    def test_failed_read_is_no_window(self):
        gone = bi.parse_window("")
        self.assertFalse(gone["read"])
        self.assertFalse(bi.is_app_window(gone))
        self.assertFalse(bi.closable("0x1", gone))
        self.assertTrue(bi.parse_window("_NET_WM_WINDOW_TYPE:  not found.\n")["read"],
                        "a live window that lacks the property was still read")

    def test_title_with_not_found_is_kept(self):
        p = bi.parse_window('_NET_WM_WINDOW_TYPE(ATOM) = _NET_WM_WINDOW_TYPE_NORMAL\n'
                            'WM_CLASS(STRING) = "Navigator", "firefox"\n'
                            '_NET_WM_NAME(UTF8_STRING) = "Page not found - Mozilla Firefox"\n'
                            'WM_NAME(STRING) = "no such atom - Mozilla Firefox"\n'
                            'WM_TRANSIENT_FOR:  not found.\n')
        self.assertEqual(p["name"], "Page not found - Mozilla Firefox")
        self.assertIsNone(p["transient_for"])
        self.assertEqual(bi.parse_window('WM_NAME(STRING) = "no such atom here"\n')["name"],
                         "no such atom here")


if __name__ == "__main__":
    unittest.main()


class TestFocusHandOff(LaunchCase):
    """Box test: the app showed but the keyboard did nothing until a click.
    The daemon keeps activating it until one of its windows has the focus (D69)."""

    def raises(self):
        return [r for r in self.d.ran if r == ["wmctrl", "-i", "-a", PLEX]]

    def test_activates_until_the_app_has_the_focus(self):
        self.d.open_windows.append(PLEX)
        self.d.active = LAUNCHER      # Muffin left the focus on the launcher
        self.at(0.5)
        r = bi.APP_REVEAL_S
        self.at(0.5 + r)
        self.assertEqual(len(self.raises()), 1)
        self.at(1.0 + r)
        self.at(1.5 + r)
        self.assertEqual(len(self.raises()), 3, "again every 500 ms")
        self.d.active = PLEX
        self.at(2.0 + r)
        self.at(2.5 + r)
        self.assertEqual(len(self.raises()), 3, "stops once Plex has the focus")
        self.assertIsNone(self.d.app.activate_until)

    def test_gives_up_after_three_seconds(self):
        self.d.open_windows.append(PLEX)
        self.d.active = LAUNCHER
        for i in range(1, 16):
            self.at(0.5 * i)
        self.assertIsNone(self.d.app.activate_until, "gave up")
        n = len(self.raises())
        self.at(8.0)
        self.assertEqual(len(self.raises()), n, "no more tries")
        self.assertLessEqual(n, 1 + int(bi.ACTIVATE_FOR_S / bi.ACTIVATE_EVERY_S))


class TestLauncherFocus(unittest.TestCase):
    """Box test: at login the launcher took no keys until it was clicked.
    The daemon keeps activating it until it has the focus (D78)."""

    def setUp(self):
        self.d = FakeX()
        self.d.open_windows.append(LAUNCHER)

    def tearDown(self):
        self.d.close()

    def raises(self):
        return [r for r in self.d.ran if r == ["wmctrl", "-F", "-a", bi.LAUNCHER_TITLE]]

    def test_activates_the_launcher_when_it_connects(self):
        self.d.active = "0x1c00003"   # the desktop has the focus at login
        self.d.handle({"cmd": "state", "visible": True})
        for i in range(4):
            self.d.clock = 1000.0 + 0.5 * i
            self.d.tick()
        self.assertEqual(len(self.raises()), 4, "every 500 ms while the desktop has it")
        self.d.active = LAUNCHER
        self.d.clock = 1002.0
        self.d.tick()
        self.d.clock = 1003.0
        self.d.tick()
        self.assertEqual(len(self.raises()), 4, "stops once the launcher has the focus")
        self.assertIsNone(self.d.focus_until)

    def test_gives_up_after_a_while(self):
        self.d.active = "0x1c00003"
        self.d.handle({"cmd": "state", "visible": True})
        for i in range(0, 40):
            self.d.clock = 1000.0 + 0.5 * i
            self.d.tick()
        self.assertIsNone(self.d.focus_until)
        self.assertLessEqual(len(self.raises()), 1 + int(bi.LAUNCHER_FOCUS_S / bi.ACTIVATE_EVERY_S))

    def test_hidden_launcher_is_left_alone(self):
        self.d.active = "0x1c00003"
        self.d.handle({"cmd": "state", "visible": True})
        self.d.handle({"cmd": "state", "visible": False})   # an app is opening
        self.d.clock = 1001.0
        self.d.tick()
        self.assertEqual(self.raises(), [])
