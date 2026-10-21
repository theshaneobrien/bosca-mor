"""Return to Bosca Mor: window listing from xprop text, filtering, the close
poll with a fake clock, Still open, Show me and Close anyway."""
import os
import unittest

os.environ["BOSCAMOR_DRY_RUN"] = "1"

from test_daemon import Recorder, bi  # noqa: E402  (loads the daemon module)

HERE = os.path.dirname(os.path.abspath(__file__))
XPROP = os.path.join(HERE, "fixtures", "xprop")
APPS = os.path.join(HERE, "fixtures", "applications")


def read(name):
    with open(os.path.join(XPROP, name)) as f:
        return f.read()


class FakeX(Recorder):
    """A daemon whose xprop answers come from the fixtures, with a window
    list the test can change, and a clock it sets."""

    def __init__(self, **kw):
        super().__init__(**kw)
        self.open_windows = [w.strip() for w in read("root.txt").split("#", 1)[1].split(",")]
        self.app_dirs = [APPS]
        self.clock = 1000.0
        self.xprop_calls = 0
        self.active = None

    def run_capture(self, argv):
        self.xprop_calls += 1
        if argv[:3] == ["xprop", "-root", "_NET_ACTIVE_WINDOW"]:
            return "_NET_ACTIVE_WINDOW(WINDOW): window id # %s\n" % (self.active or "0x0")
        if argv[:2] == ["xprop", "-root"]:
            return "_NET_CLIENT_LIST(WINDOW): window id # " + ", ".join(self.open_windows) + "\n"
        if argv[:2] == ["xprop", "-id"]:
            return read(bi.norm_wid(argv[2]) + ".txt")
        return ""

    def close_window(self, wid):
        self.open_windows = [w for w in self.open_windows if bi.norm_wid(w) != wid]

    def acted(self):
        return [line for line in self.logs if "dry run" in line]


class TestParsing(unittest.TestCase):
    def test_client_list(self):
        self.assertEqual(bi.parse_client_list(read("root.txt")), [
            "0x1c00003", "0x1e00004", "0x2a00003", "0x3a00007", "0x3a0012a",
            "0x4400002", "0x5200005", "0x5800009"])
        self.assertEqual(bi.parse_client_list("_NET_CLIENT_LIST:  not found.\n"), [])

    def test_window_props(self):
        p = bi.parse_window(read("0x3a0012a.txt"))
        self.assertEqual(p["types"], ["DIALOG"])
        self.assertEqual(p["classes"], ["libreoffice", "libreoffice-writer"])
        self.assertEqual(p["name"], "Save Document?")
        self.assertEqual(p["transient_for"], "0x3a00007")
        editor = bi.parse_window(read("0x4400002.txt"))
        self.assertEqual(editor["types"], [])
        self.assertEqual(editor["name"], '*Unsaved Document 1 "notes" - Text Editor')
        self.assertIsNone(editor["transient_for"])

    def test_right_windows_kept_and_skipped(self):
        d = FakeX()
        kept = [w for w, p in d.list_windows() if bi.closable(w, p)]
        # Firefox, Writer, and the editor (no type, so NORMAL). Not the
        # desktop, the panel, Writer's save dialog, the launcher or the toast.
        self.assertEqual(kept, ["0x2a00003", "0x3a00007", "0x4400002"])
        d.close()


class TestReturnFlow(unittest.TestCase):
    def setUp(self):
        self.d = FakeX()
        self.d.logs = []
        self.handler = _ListHandler(self.d.logs)
        bi.log.addHandler(self.handler)
        self.level = bi.log.level
        bi.log.setLevel(bi.logging.INFO)

    def tearDown(self):
        bi.log.setLevel(self.level)
        bi.log.removeHandler(self.handler)
        self.d.close()

    def test_polite_close_then_home_when_all_gone(self):
        d = self.d
        d.handle({"cmd": "return"})
        self.assertEqual(d.acted(), ["dry run: would run wmctrl -i -c 0x2a00003",
                                     "dry run: would run wmctrl -i -c 0x3a00007",
                                     "dry run: would run wmctrl -i -c 0x4400002"])
        self.assertEqual(d.sent, [])
        # 250 ms later Firefox has gone; at 500 ms the others have too.
        for wid in ("0x2a00003",):
            d.close_window(wid)
        d.clock = 1000.25
        d.tick()
        self.assertEqual(d.sent, [])
        for wid in ("0x3a00007", "0x3a0012a", "0x4400002"):
            d.close_window(wid)
        d.clock = 1000.5
        d.tick()
        self.assertEqual(d.sent, [{"evt": "show"}])
        self.assertIsNone(d.returning, "polling stops early")
        calls = d.xprop_calls
        d.clock = 1003.0
        d.tick()
        self.assertEqual(d.xprop_calls, calls, "no polls after it stopped")

    def test_still_open_after_five_seconds(self):
        d = self.d
        d.handle({"cmd": "return"})
        d.close_window("0x2a00003")
        d.close_window("0x3a0012a")   # no save prompt up: nothing to wait for
        polls = 0
        t = 1000.0
        while d.returning and t < 1010:
            t += 0.25
            d.clock = t
            d.tick()
            polls += 1
        self.assertEqual(polls, 20, "every 250 ms for 5 s")
        self.assertEqual(d.sent, [{"evt": "still_open", "apps": [
            {"wid": "0x3a00007", "name": "LibreOffice Writer", "icon": "libreoffice-writer", "asking": False},
            {"wid": "0x4400002", "name": "Text Editor", "icon": "accessories-text-editor", "asking": False},
        ]}])

    # Box test: the launcher came back over the editor's save prompt, which
    # lost the focus. While a prompt is up, Return waits for the answer (D70).
    def test_waits_while_a_save_prompt_is_up(self):
        d = self.d
        d.handle({"cmd": "return"})
        d.close_window("0x2a00003")
        d.close_window("0x4400002")   # Writer is left, asking to save
        for i in range(1, 121):
            d.clock = 1000.0 + i * 0.25
            d.tick()
        self.assertEqual(d.sent, [], "30 s on, still waiting for the answer")
        self.assertIsNotNone(d.returning)
        # The viewer answers Don't Save: the prompt and the window go.
        d.close_window("0x3a0012a")
        d.close_window("0x3a00007")
        d.clock = 1030.25
        d.tick()
        self.assertEqual(d.sent, [{"evt": "show"}], "Home, with nothing left")

    def test_cancelled_prompt_shows_still_open(self):
        d = self.d
        d.handle({"cmd": "return"})
        d.close_window("0x2a00003")
        d.close_window("0x4400002")
        d.clock = 1010.0
        d.tick()
        self.assertEqual(d.sent, [], "prompt up: waiting")
        d.close_window("0x3a0012a")   # Cancel: the prompt goes, the window stays
        d.clock = 1010.25
        d.tick()
        still = d.events("still_open")
        self.assertEqual(len(still), 1, "past 5 s with no prompt: Still open")
        self.assertEqual(still[0]["apps"][0]["wid"], "0x3a00007")

    def test_prompt_wait_has_a_limit(self):
        d = self.d
        d.handle({"cmd": "return"})
        d.close_window("0x2a00003")
        d.close_window("0x4400002")
        d.clock = 1000.0 + bi.RETURN_PROMPT_WAIT_S + 0.25
        d.tick()
        self.assertEqual(len(d.events("still_open")), 1, "Still open after the limit")

    def test_nothing_open_shows_home_at_once(self):
        d = self.d
        d.open_windows = ["0x1c00003", "0x1e00004", "0x5200005"]
        d.handle({"cmd": "return"})
        self.assertEqual(d.sent, [{"evt": "show"}])
        self.assertIsNone(d.returning)
        self.assertEqual(d.acted(), [])

    def test_home_on_the_desktop_starts_the_flow(self):
        d = self.d
        d.handle({"cmd": "desktop"})
        d.on_home()
        self.assertIsNotNone(d.returning)
        self.assertEqual(len(d.acted()), 3)

    def test_show_me_raises_and_next_home_starts_again(self):
        d = self.d
        d.handle({"cmd": "show_window", "wid": "0x3a00007"})
        self.assertEqual(d.ran, [["wmctrl", "-i", "-a", "0x3a00007"]])
        self.assertTrue(d.desktop)
        d.on_home()
        self.assertIsNotNone(d.returning, "Home on the desktop runs Return again")

    def test_close_anyway_uses_xkill_by_window_id(self):
        d = self.d
        d.handle({"cmd": "force_close", "wids": ["0x3a00007", "0x4400002", "1234", "0x1;rm"]})
        self.assertEqual(d.acted(), ["dry run: would run xkill -id 0x3a00007",
                                     "dry run: would run xkill -id 0x4400002"])
        self.assertEqual(d.ran, [], "nothing actually run under dry run")
        self.assertEqual(d.signals, [], "no process signalled")

    def test_desktop_without_notification(self):
        d = self.d
        d.handle({"cmd": "desktop", "notify": False})
        self.assertTrue(d.desktop)
        self.assertEqual(d.ran, [])


class _ListHandler(bi.logging.Handler):
    def __init__(self, sink):
        super().__init__()
        self.sink = sink

    def emit(self, record):
        self.sink.append(record.getMessage())


if __name__ == "__main__":
    unittest.main()


class TestBoxWindows(unittest.TestCase):
    """Windows captured on the box (21 Oct 2026), in fixtures/xprop-box/."""

    def props(self, wid):
        with open(os.path.join(HERE, "fixtures", "xprop-box", wid + ".txt")) as f:
            return bi.parse_window(f.read())

    def test_launcher_is_never_closed(self):
        launcher = self.props("0x2e00007")
        self.assertEqual(launcher["classes"], ["Godot_Engine", "Launcher"])
        self.assertFalse(bi.closable("0x2e00007", launcher))
        self.assertFalse(bi.is_app_window(launcher))

    def test_desktop_skipped_apps_closed(self):
        self.assertFalse(bi.closable("0x2a00003", self.props("0x2a00003")), "nemo-desktop")
        for wid in ("0x3000007", "0x3400325", "0x4000006"):  # Nemo, Xed, terminal
            self.assertTrue(bi.closable(wid, self.props(wid)), wid)
