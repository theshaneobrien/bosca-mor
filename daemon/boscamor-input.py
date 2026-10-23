#!/usr/bin/env python3
"""boscamor-input: the launcher's companion daemon.

Watches the global keys (Home, Guide, Super + Home, Power) while another app
has focus, starts and ends apps for the launcher, runs confirmed power
actions, and sends the Desktop notification. Python 3 stdlib only; see
docs/SPEC.md "Companion daemon".

  boscamor-input.py                 run the daemon
  boscamor-input.py --fake-input    also read home/guide/super+home/power lines on stdin
  boscamor-input.py --return        ask the running daemon to return from the desktop
  boscamor-input.py --dev-port N    dev machine: fixed port, prints BOSCAMOR_IPC=N:<token>

BOSCAMOR_DRY_RUN=1 logs power actions instead of running them.
BOSCAMOR_HOME moves every path under it (see paths()).
BOSCAMOR_RUNTIME_DIR overrides where the port and token files go.
"""

import argparse
import errno
import json
import logging
import os
import re
import secrets
import selectors
import signal
import socket
import struct
import subprocess
import sys
import time

log = logging.getLogger("boscamor-input")

# struct input_event on x86_64: seconds, microseconds, type, code, value.
EVENT = struct.Struct("llHHi")
EV_KEY = 1
KEY_HOME = 102
KEY_POWER = 116
KEY_LEFTMETA = 125
KEY_RIGHTMETA = 126
KEY_HOMEPAGE = 172
BTN_MODE = 316
# OK on some remotes. X has no key for these, so the launcher never sees
# them; the daemon passes them on as Accept while it is on screen (D82).
KEY_OK = 352
KEY_SELECT = 353
WATCHED_KEYS = (KEY_HOMEPAGE, BTN_MODE, KEY_POWER, KEY_HOME)
META_KEYS = (KEY_LEFTMETA, KEY_RIGHTMETA)
PRESS = 1  # 0 release, 2 repeat

RESCAN_S = 3.0
GRACE_S = 3.0
CLOSING_POLL_S = 0.05
HANDSHAKE_S = 2.0
MEM_SAMPLE_S = 10.0
MEM_LOG_S = 60.0
MEM_LOW_MB = 512
MEM_LOW_FOR_S = 30.0
MAX_LINE = 65536
LAUNCH_TIMEOUT_S = 15.0  # SPEC: no window within 15 s and the launch has failed
WINDOW_POLL_S = 0.5      # D63: how often the window list is read while waiting
# First window types that count as an app having opened (D63).
APP_WINDOW_TYPES = {"NORMAL", "DIALOG", "SPLASH"}

NOTIFY_TITLE = "Launcher closed"
NOTIFY_BODY = "Press Home on the remote, the Guide button, or Super + Home to bring it back."
LAUNCHER_TITLE = "Launcher"  # the launcher's window title, for the wmctrl raise fallback
RETURN_POLL_S = 0.25
RETURN_WAIT_S = 5.0
# While a window is asking to save, Return keeps waiting for the viewer to
# answer, up to this long, before showing Still open (D70).
RETURN_PROMPT_WAIT_S = 120.0
# After the app's first window shows, keep activating it until it has the
# keyboard focus, for up to this long (D69).
ACTIVATE_FOR_S = 3.0
ACTIVATE_EVERY_S = 0.5
# The app's first window stays hidden behind the black launcher this long,
# while it finishes going full screen, before it is raised (D77).
APP_REVEAL_S = 2.0
# After the launcher connects or is shown, keep activating its window until
# it has the keyboard focus, for up to this long (D78). At login the desktop
# can take the focus after the launcher's window is up.
LAUNCHER_FOCUS_S = 15.0
# Window types Return to Bosca Mor never closes. Dialogs belong to a parent.
SKIP_TYPES = {"DESKTOP", "DOCK", "NOTIFICATION", "SPLASH", "TOOLBAR", "MENU",
              "DIALOG", "UTILITY", "DROPDOWN_MENU", "POPUP_MENU", "TOOLTIP", "COMBO", "DND"}
# Every EWMH window type, without the _NET_WM_WINDOW_TYPE_ prefix.
EWMH_TYPES = {"NORMAL", "DIALOG", "SPLASH", "DESKTOP", "DOCK", "TOOLBAR", "MENU", "UTILITY",
              "DROPDOWN_MENU", "POPUP_MENU", "TOOLTIP", "NOTIFICATION", "COMBO", "DND"}
# What window_props asks xprop for, one output line each.
WINDOW_PROPS = ("_NET_WM_WINDOW_TYPE", "WM_CLASS", "_NET_WM_NAME", "WM_NAME", "WM_TRANSIENT_FOR")
# WM_CLASS values (either half) of windows that are part of the desktop or the launcher.
SKIP_CLASSES = {"cinnamon", "nemo-desktop", "boscamor", "launcher"}
WID = re.compile(r"^0x[0-9a-f]+$")
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # for a relative BOSCAMOR_HOME
POWER_COMMANDS = {
    "poweroff": ["systemctl", "poweroff"],
    "reboot": ["systemctl", "reboot"],
}
# How long a power command gets to say it was refused. Still running after
# this, it counts as working: the box is going down.
POWER_WAIT_S = 5.0


def dry_run():
    return os.environ.get("BOSCAMOR_DRY_RUN") == "1"


def paths():
    """The one place the daemon builds its paths (Law 13), mirroring the
    launcher's paths.gd. XDG on the box; when BOSCAMOR_HOME is set, everything
    of ours sits under it (relative values resolve against the repo root).
    app_dirs are where other apps install .desktop files, so they never move."""
    env = os.environ
    home = os.path.expanduser("~")

    def xdg(var, fallback):
        return env.get(var) or os.path.join(home, fallback)

    dev = env.get("BOSCAMOR_HOME", "").strip()
    if dev:
        dev = os.path.normpath(os.path.join(REPO, dev))  # join keeps an absolute dev
        config = os.path.join(dev, "config")
        p = {
            "state_json": os.path.join(dev, "state", "state.json"),
            "icon_cache": os.path.join(dev, "cache", "icons"),
            "profiles": os.path.join(dev, "profiles"),
            "autostart": os.path.join(dev, "autostart", "boscamor.desktop"),
            "runtime": os.path.join(dev, "runtime"),
        }
    else:
        config = os.path.join(xdg("XDG_CONFIG_HOME", ".config"), "boscamor")
        run_base = env.get("XDG_RUNTIME_DIR") or "/tmp/boscamor-%d" % os.getuid()
        p = {
            "state_json": os.path.join(xdg("XDG_STATE_HOME", ".local/state"), "boscamor", "state.json"),
            "icon_cache": os.path.join(xdg("XDG_CACHE_HOME", ".cache"), "boscamor", "icons"),
            "profiles": os.path.join(home, ".local/share/boscamor/profiles"),
            "autostart": os.path.join(xdg("XDG_CONFIG_HOME", ".config"), "autostart", "boscamor.desktop"),
            "runtime": os.path.join(run_base, "boscamor"),
        }
    if env.get("BOSCAMOR_RUNTIME_DIR"):  # D29: tests give the daemon its own folder
        p["runtime"] = env["BOSCAMOR_RUNTIME_DIR"]
    data_home = xdg("XDG_DATA_HOME", ".local/share")
    p.update({
        "home": dev,
        "config": config,
        "apps_json": os.path.join(config, "apps.json"),
        "icons": os.path.join(config, "icons"),
        "app_dirs": [
            os.path.join(data_home, "applications"),
            os.path.join(data_home, "flatpak/exports/share/applications"),
            "/var/lib/flatpak/exports/share/applications",
            "/usr/local/share/applications",
            "/usr/share/applications",
        ],
    })
    return p


# evdev ------------------------------------------------------------------------

def parse_events(buf):
    """Splits raw evdev bytes into (sec, usec, type, code, value) tuples.

    Returns the events and any trailing partial event."""
    whole = len(buf) - len(buf) % EVENT.size
    events = [EVENT.unpack_from(buf, i) for i in range(0, whole, EVENT.size)]
    return events, buf[whole:]


def has_key(bitmap, code):
    """True if a /proc/bus/input/devices KEY= bitmap includes the key code.

    The bitmap is hex words, most significant first, one per C long."""
    words = bitmap.split()
    bits = struct.calcsize("l") * 8
    index = len(words) - 1 - code // bits
    if index < 0:
        return False
    return bool(int(words[index], 16) >> (code % bits) & 1)


def parse_devices(text):
    """Maps /dev/input/eventN to device name for devices with a watched key."""
    found = {}
    for block in text.split("\n\n"):
        name, handlers, keys = "", [], ""
        for line in block.splitlines():
            if line.startswith("N: Name="):
                name = line[8:].strip().strip('"')
            elif line.startswith("H: Handlers="):
                handlers = line[12:].split()
            elif line.startswith("B: KEY="):
                keys = line[7:]
        if not keys or not any(has_key(keys, k) for k in WATCHED_KEYS):
            continue
        for h in handlers:
            if h.startswith("event"):
                found["/dev/input/" + h] = name
    return found


# Windows (xprop text) -------------------------------------------------------------

def norm_wid(text):
    """0x03a00007 and 0x3a00007 are the same window."""
    return "0x%x" % int(text, 16)


def parse_client_list(text):
    """Window ids from `xprop -root _NET_CLIENT_LIST`."""
    if "#" not in text:
        return []
    return [norm_wid(w) for w in re.findall(r"0x[0-9a-fA-F]+", text.split("#", 1)[1])]


def parse_window(text):
    """Type, class, name and transient-for from `xprop -id <wid> ...`.
    "read" is False when xprop printed none of them: the window has gone
    (BadWindow), or xprop failed. A live window gets a line for each."""
    props = {"types": [], "classes": [], "name": "", "transient_for": None, "read": False}
    for line in text.splitlines():
        if line.startswith(WINDOW_PROPS):
            props["read"] = True
        # "NAME:  not found." and "NAME:  no such atom on any window." have no
        # "(TYPE) =" part. Matching only that form keeps a title such as
        # "Page not found - Mozilla Firefox".
        if re.match(r"^\w+:\s", line):
            continue
        if line.startswith("_NET_WM_WINDOW_TYPE"):
            props["types"] = [a.strip().replace("_NET_WM_WINDOW_TYPE_", "")
                              for a in line.split("=", 1)[-1].split(",") if a.strip()]
        elif line.startswith("WM_CLASS"):
            props["classes"] = [_unquote(q) for q in re.findall(r'"((?:[^"\\]|\\.)*)"', line)]
        elif line.startswith("_NET_WM_NAME") or (line.startswith("WM_NAME") and not props["name"]):
            found = re.search(r'"((?:[^"\\]|\\.)*)"', line)
            if found:
                props["name"] = _unquote(found.group(1))
        elif line.startswith("WM_TRANSIENT_FOR"):
            found = re.search(r"0x[0-9a-fA-F]+", line)
            if found:
                props["transient_for"] = norm_wid(found.group(0))
    return props


def _unquote(s):
    return re.sub(r"\\(.)", r"\1", s)


def window_types(props):
    """The window's EWMH types in order of preference, or the EWMH default
    when it lists none. Atoms that aren't EWMH types are skipped, as Muffin
    skips them: Qt lists _KDE_NET_WM_WINDOW_TYPE_OVERRIDE before NORMAL on
    frameless windows."""
    known = [t for t in props["types"] if t in EWMH_TYPES]
    return known or (["DIALOG"] if props["transient_for"] else ["NORMAL"])


def is_splash(props):
    return window_types(props)[0] == "SPLASH"


def closable(wid, props):
    """True for the windows Return to Bosca Mor asks to close."""
    if not props["read"]:
        return False  # gone already, or xprop failed
    types = window_types(props)
    if types[0] != "NORMAL" or any(t in SKIP_TYPES for t in types):
        return False
    if any(c.lower() in SKIP_CLASSES for c in props["classes"]):
        return False
    return props["name"] != LAUNCHER_TITLE


def is_app_window(props):
    """True for a new client that shows the launched app has opened: a normal
    window, dialog or splash that isn't the desktop's or the launcher's (D63)."""
    if not props["read"]:
        return False  # gone already, or xprop failed
    types = window_types(props)
    if types[0] not in APP_WINDOW_TYPES:
        return False
    if any(c.lower() in SKIP_CLASSES for c in props["classes"]):
        return False
    return props["name"] != LAUNCHER_TITLE


def desktop_entry_for(classes, dirs):
    """Name and Icon of the .desktop entry matching a WM_CLASS, or None."""
    want = {c.lower() for c in classes}
    for d in dirs:
        try:
            files = sorted(os.listdir(d))
        except OSError:
            continue
        for f in files:
            if not f.endswith(".desktop"):
                continue
            keys = {}
            try:
                with open(os.path.join(d, f), encoding="utf-8", errors="replace") as fh:
                    group = ""
                    for line in fh:
                        line = line.strip()
                        if line.startswith("["):
                            group = line
                        elif group == "[Desktop Entry]" and "=" in line:
                            k, v = line.split("=", 1)
                            keys.setdefault(k.strip(), v.strip())
            except OSError:
                continue
            names = {f[:-8].lower(), keys.get("StartupWMClass", "").lower()}
            if want & names and keys.get("Name"):
                return {"name": keys["Name"], "icon": keys.get("Icon", "")}
    return None


# The daemon -------------------------------------------------------------------

class App:
    def __init__(self, app_id, proc, keep_on_home):
        self.id = app_id
        self.proc = proc
        self.pgid = proc.pid  # start_new_session makes it the group leader
        self.keep_on_home = keep_on_home
        self.closing = False
        self.deadline = 0.0
        self.killed = False
        self.show_after = False
        # Home was pressed on the desktop: once the app has gone, Return runs.
        self.return_after = False
        # Waiting for the first window (D63): the client list at launch, and
        # when to look again or give up. None once a window showed.
        self.known = set()
        self.window_deadline = None
        self.next_window_poll = 0.0
        self.launched_at = 0.0
        # Windows open before the launch, and the focus hand-off (D69).
        self.baseline = set()
        self.activate_wid = None
        self.activate_until = None
        self.next_activate = 0.0
        self.reveal_at = None
        # A keep_on_home app running behind the launcher: its own windows,
        # which Return leaves open, and the viewer's, which Return has asked
        # to close or which were opened on a desktop visit, and which never
        # count as its own.
        self.owned = set()
        self.not_owned = set()


class Client:
    def __init__(self, sock, now):
        self.sock = sock
        self.buf = b""
        self.authed = False
        self.since = now


class Daemon:
    def __init__(self, runtime=None, proc_root="/proc", fake_input=False, evdev=True,
                 dev_port=None):
        self.runtime = runtime or paths()["runtime"]
        self.dev_port = dev_port
        self.proc_root = proc_root
        self.fake_input = fake_input
        self.evdev = evdev
        self.token = secrets.token_hex(32)
        self.sel = selectors.DefaultSelector()
        self.clients = []
        self.devices = {}  # path -> [fd, name, partial bytes]
        self.meta_down = set()
        self.app = None
        self.pending = None  # (id, argv, keep_on_home) waiting for the old app to end
        self.visible = False
        self.desktop = False
        self.next_rescan = 0.0
        self.next_mem = 0.0
        self.last_mem_log = 0.0
        self.low_since = None
        self.mem_warned = False
        self.server = None
        self.port = None
        self._denied = set()
        self.returning = None  # {"deadline", "next"} while closing desktop windows
        self.focus_until = None  # keeping the launcher focused (D78)
        self.next_focus = 0.0
        self.app_dirs = paths()["app_dirs"]

    # Overridable for tests.
    def now(self):
        return time.monotonic()

    def run_cmd(self, argv):
        """Runs a helper binary without waiting. Never through a shell."""
        try:
            subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             start_new_session=True)
        except OSError as e:
            log.warning("could not run %s: %s", argv[0], e)

    def run_wait(self, argv):
        """Runs a helper binary and waits up to POWER_WAIT_S for its exit
        status. Never through a shell. Still running then counts as 0, and
        None means it could not start."""
        try:
            return subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                  timeout=POWER_WAIT_S).returncode
        except subprocess.TimeoutExpired:
            return 0
        except OSError as e:
            log.warning("could not run %s: %s", argv[0], e)
            return None

    def signal_group(self, pgid, sig):
        os.killpg(pgid, sig)

    def run_capture(self, argv):
        """A helper binary's stdout, or "" if it failed."""
        try:
            return subprocess.run(argv, capture_output=True, text=True, timeout=2,
                                  stdin=subprocess.DEVNULL).stdout
        except (OSError, subprocess.SubprocessError) as e:
            log.warning("could not run %s: %s", argv[0], e)
            return ""

    # Setup --------------------------------------------------------------------

    def start(self):
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server.bind(("127.0.0.1", self.dev_port or 0))
        self.server.listen(4)
        self.server.setblocking(False)
        self.port = self.server.getsockname()[1]
        self.sel.register(self.server, selectors.EVENT_READ, self._accept)
        self._write_runtime()
        if self.fake_input:
            self.sel.register(sys.stdin, selectors.EVENT_READ, self._read_stdin)
        log.info("listening on 127.0.0.1:%d, runtime %s%s", self.port, self.runtime,
                 " (dry run)" if dry_run() else "")
        if self.dev_port:
            # SPEC "IPC", Dev override: the Windows launcher can't read our runtime dir.
            print("BOSCAMOR_IPC=%d:%s" % (self.port, self.token), flush=True)

    def _write_runtime(self):
        os.makedirs(self.runtime, mode=0o700, exist_ok=True)
        os.chmod(self.runtime, 0o700)
        for name, value in (("port", str(self.port)), ("token", self.token)):
            path = os.path.join(self.runtime, name)
            tmp = path + ".tmp"
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as f:
                f.write(value + "\n")
            os.replace(tmp, path)

    def install_signals(self):
        """Wakes the loop on SIGCHLD so app exits are reported at once."""
        r, w = socket.socketpair()
        r.setblocking(False)
        w.setblocking(False)
        signal.set_wakeup_fd(w.fileno())
        signal.signal(signal.SIGCHLD, lambda *_: None)
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        self._wake = (r, w)
        self.sel.register(r, selectors.EVENT_READ, lambda s: s.recv(4096))

    def close(self):
        for c in list(self.clients):
            self._drop(c)
        for path in list(self.devices):
            self._close_device(path)
        if self.server:
            self.sel.unregister(self.server)
            self.server.close()
            self.server = None

    # Loop ---------------------------------------------------------------------

    def run(self):
        while True:
            self.run_once(self.next_timeout())

    def run_once(self, timeout):
        for key, _ in self.sel.select(timeout):
            key.data(key.fileobj)
        self.tick()

    def tick(self):
        now = self.now()
        self.poll_app()
        app = self.app
        if app and app.window_deadline is not None and not app.closing \
                and now >= app.next_window_poll:
            self.poll_window()
        app = self.app
        if app and app.reveal_at is not None and not app.closing and now >= app.reveal_at:
            self.reveal_app(app)
        app = self.app
        if app and app.activate_until is not None and not app.closing \
                and now >= app.next_activate:
            self.poll_activate(app)
        if self.focus_until is not None and now >= self.next_focus:
            self.poll_launcher_focus()
        if self.evdev and now >= self.next_rescan:
            self.rescan()
            self.next_rescan = now + RESCAN_S
        if now >= self.next_mem:
            self.sample_memory()
            self.next_mem = now + MEM_SAMPLE_S
        if self.returning and now >= self.returning["next"]:
            self.poll_return()
        for c in list(self.clients):
            if not c.authed and now - c.since > HANDSHAKE_S:
                log.warning("dropping a client that sent no token")
                self._drop(c)

    def next_timeout(self):
        now = self.now()
        due = [self.next_mem]
        if self.evdev:
            due.append(self.next_rescan)
        app = self.app
        if app and app.closing:
            # tick() skips the window watch, reveal and hand-off while it closes.
            due.append(now + CLOSING_POLL_S)
        elif app:
            if app.window_deadline is not None:
                due.append(app.next_window_poll)
            if app.activate_until is not None:
                due.append(app.next_activate)
            if app.reveal_at is not None:
                due.append(app.reveal_at)
        if self.focus_until is not None:
            due.append(self.next_focus)
        if self.returning:
            due.append(self.returning["next"])
        due += [c.since + HANDSHAKE_S for c in self.clients if not c.authed]
        return max(0.0, min(due) - now)

    # IPC ----------------------------------------------------------------------

    def _accept(self, server):
        try:
            sock, _ = server.accept()
        except BlockingIOError:
            return
        sock.setblocking(False)
        c = Client(sock, self.now())
        self.clients.append(c)
        self.sel.register(sock, selectors.EVENT_READ, lambda s, c=c: self._read_client(c))

    def _read_client(self, c):
        try:
            data = c.sock.recv(4096)
        except (BlockingIOError, InterruptedError):
            return
        except OSError:
            data = b""
        if not data:
            self._drop(c)
            return
        c.buf += data
        while b"\n" in c.buf:
            line, c.buf = c.buf.split(b"\n", 1)
            if not c.authed:
                if secrets.compare_digest(line.strip(), self.token.encode()):
                    c.authed = True
                    continue
                log.warning("dropping a client with a bad token")
                self._drop(c)
                return
            self._handle_line(line)
            if c not in self.clients:
                return
        if len(c.buf) > MAX_LINE:
            log.warning("dropping a client with an overlong line")
            self._drop(c)

    def _drop(self, c):
        if c in self.clients:
            self.clients.remove(c)
            try:
                self.sel.unregister(c.sock)
            except (KeyError, ValueError):
                pass
            c.sock.close()

    def _handle_line(self, line):
        try:
            msg = json.loads(line)
        except (ValueError, RecursionError):
            log.warning("ignoring a line that is not JSON")
            return
        if not isinstance(msg, dict):
            return
        # One bad command must not end the daemon: its restart would lose
        # track of the running app, so Home could no longer close it.
        try:
            self.handle(msg)
        except Exception:
            log.exception("command %r failed", msg.get("cmd"))

    def send(self, evt):
        data = (json.dumps(evt) + "\n").encode()
        for c in list(self.clients):
            if not c.authed:
                continue
            try:
                c.sock.sendall(data)
            except OSError:
                self._drop(c)

    def handle(self, msg):
        cmd = msg.get("cmd")
        if cmd == "state":
            was = self.visible
            self.visible = bool(msg.get("visible"))
            if self.visible:
                if self.desktop:
                    self.disown_desktop_windows()
                self.desktop = False
                if not was:
                    # The launcher is back on screen, so a Return still waiting
                    # (a save prompt left up) is over: it must never show Home
                    # or Still open later, over whatever runs next.
                    self.returning = None
                    self.focus_launcher()
                    self.launcher_over_app()
            else:
                self.focus_until = None
        elif cmd == "launch":
            self.launch(msg.get("id"), msg.get("argv"), bool(msg.get("keep_on_home")))
        elif cmd == "power":
            self.power(msg.get("action"))
        elif cmd == "desktop":
            self.note_kept_windows()
            self.desktop = True
            self.visible = False
            self.focus_until = None  # off screen: activating it would pull it over the desktop
            if msg.get("notify", True):
                self.run_cmd(["notify-send", NOTIFY_TITLE, NOTIFY_BODY])
        elif cmd == "return":
            self.return_from_desktop()
        elif cmd == "show_window":
            self.show_window(msg.get("wid"))
        elif cmd == "force_close":
            self.force_close(msg.get("wids"))
        else:
            log.warning("unknown command %r", cmd)

    # Keys ---------------------------------------------------------------------

    def on_key(self, device, code, value):
        if code in META_KEYS:
            if value == PRESS:
                self.meta_down.add(device)
            elif value == 0:
                self.meta_down.discard(device)
            return
        if value != PRESS:
            return
        if code == KEY_POWER:
            self.on_power()
        elif code in (KEY_HOMEPAGE, BTN_MODE):
            self.on_home()
        elif code == KEY_HOME and device in self.meta_down:
            self.on_home()
        elif code in (KEY_OK, KEY_SELECT) and self.visible:
            self.send({"evt": "accept"})

    def on_power(self):
        log.info("power key: asking the launcher to confirm")
        self.send({"evt": "power_confirm"})

    def on_home(self):
        if self.visible:
            return  # the launcher sees Home itself
        if self.returning:
            # Home again while Return waits on a save prompt (D70): the viewer
            # isn't answering it, so stop waiting. The next poll shows Home,
            # or Still open once the first 5 s are up.
            self.returning["started"] = self.now() - RETURN_PROMPT_WAIT_S
            return
        app = self.app
        if app and app.closing:
            return
        if app and not app.keep_on_home:
            # On the desktop, Return runs once the app has gone (_finish).
            log.info("home: closing %s", app.id)
            app.return_after = self.desktop
            self.close_app(then_show=True)
            return
        if self.desktop:
            self.return_from_desktop()  # a keep_on_home app's own windows are left open
            return
        self.show()

    def show(self):
        self.send({"evt": "show"})
        self.raise_launcher()
        self.focus_launcher()

    def focus_launcher(self):
        """Box test: at login the launcher took no keys until clicked; the
        desktop held the focus. Keep activating it until it has it (D78)."""
        now = self.now()
        self.focus_until = now + LAUNCHER_FOCUS_S
        self.next_focus = now

    def poll_launcher_focus(self):
        now = self.now()
        if not self.visible and now > self.next_focus + LAUNCHER_FOCUS_S:
            self.focus_until = None
            return
        active = self.active_window()
        if active and self.window_props(active)["name"] == LAUNCHER_TITLE:
            self.focus_until = None
            return
        if now >= self.focus_until:
            log.warning("the launcher never took the focus")
            self.focus_until = None
            return
        self.run_cmd(["wmctrl", "-F", "-a", LAUNCHER_TITLE])
        self.next_focus = now + ACTIVATE_EVERY_S

    def raise_launcher(self):
        """The launcher waits full screen behind apps (D69), so bring it to
        the front whenever it is shown, rather than only as a fallback."""
        self.run_cmd(["wmctrl", "-F", "-a", LAUNCHER_TITLE])

    # Return to Bosca Mor ------------------------------------------------------

    def list_windows(self, cache=None):
        """Every client window: [(wid, props)]. With a cache (one Return
        flow), each window is read once while it stays listed; a failed read
        is tried again on the next poll."""
        wids = parse_client_list(self.run_capture(["xprop", "-root", "_NET_CLIENT_LIST"]))
        if cache is None:
            return [(wid, self.window_props(wid)) for wid in wids]
        for gone in set(cache) - set(wids):
            del cache[gone]
        out = []
        for wid in wids:
            props = cache.get(wid)
            if props is None:
                props = self.window_props(wid)
                if props["read"]:
                    cache[wid] = props
            out.append((wid, props))
        return out

    def window_props(self, wid):
        return parse_window(self.run_capture(["xprop", "-id", wid] + list(WINDOW_PROPS)))

    def pick_app_window(self, app, wids):
        """The app window to raise: (wid, is_splash), or None if it has none
        listed. The window already chosen stays while it is listed and is
        not a splash, so a second window or a startup dialog never takes its
        place; a failed read of it (xprop timed out) changes nothing.
        Otherwise the newest listed window that wasn't open before the
        launch: one with no parent over a dialog, either over a splash. A
        splash or updater window can close and give way to the main window."""
        if wids is None:
            # No window list to check against: keep the one already seen.
            return (app.activate_wid, False) if app.activate_wid else None
        found = []
        for wid in wids:
            if wid in app.baseline:
                continue
            props = self.window_props(wid)
            if wid == app.activate_wid and (
                    not props["read"] or (is_app_window(props) and not is_splash(props))):
                return (wid, False)
            if is_app_window(props):
                found.append((wid, is_splash(props), props["transient_for"] is not None))
        main = [f for f in found if not f[1]]
        pick = [f for f in main if not f[2]] or main or found
        return pick[-1][:2] if pick else None  # the client list runs oldest first

    def reveal_app(self, app):
        """Raise the app's window above the launcher, which waits full
        screen and black behind it (D65, D69), and give it the focus."""
        now = self.now()
        app.reveal_at = None
        if self.visible or self.desktop:
            # D85: the launcher is on screen, so no raise and no hand-off;
            # app_window still stops the launcher's own deadline.
            # On the desktop the app is not raised either: the viewer is
            # using the windows there.
            # In both cases an app without keep_on_home is ended the way
            # Home ends it, since nobody is waiting for it now. On screen,
            # that covers a launcher that never reported itself off screen
            # (Power during the launch fade), so it had no hidden-to-shown
            # change to act on.
            log.info("%s showed a window, but the launcher or the desktop is on screen; "
                     "leaving it behind", app.id)
            self.send({"evt": "app_window", "id": app.id})
            if not app.keep_on_home:
                self.close_app(then_show=False)
            return
        pick = self.pick_app_window(app, self.client_list())
        if pick is None:
            # The window seen a moment ago has gone and nothing has taken its
            # place yet: watch again, within the launch's own 15 s. Every new
            # window is read again, so the same window mapped again (a Qt
            # app changing its flags) counts.
            log.info("%s: its first window has gone; watching for the next", app.id)
            app.activate_wid = None
            app.known = set(app.baseline)
            app.window_deadline = app.launched_at + LAUNCH_TIMEOUT_S
            app.next_window_poll = min(now + WINDOW_POLL_S, app.window_deadline)
            return
        app.activate_wid = pick[0]
        self.run_cmd(["wmctrl", "-i", "-a", app.activate_wid])
        app.activate_until = now + ACTIVATE_FOR_S
        app.next_activate = now + ACTIVATE_EVERY_S
        self.send({"evt": "app_window", "id": app.id})

    def active_window(self):
        """The window with the keyboard focus, or None."""
        ids = parse_client_list(self.run_capture(["xprop", "-root", "_NET_ACTIVE_WINDOW"]))
        return ids[0] if ids and ids[0] != "0x0" else None

    def poll_activate(self, app):
        """Muffin can leave the focus on the launcher when a new window maps
        (focus-stealing prevention), so the keyboard does nothing until the
        viewer clicks. Activate the app's window again until one of its new
        windows has the focus (D69)."""
        now = self.now()
        if self.visible or self.desktop:
            # D85: the launcher is back, so leave the app behind it. On the
            # desktop, likewise: activating the app would take the focus
            # from the viewer's windows.
            app.activate_until = None
            return
        active = self.active_window()
        if active and active not in app.baseline:
            props = self.window_props(active)
            if is_app_window(props) and not is_splash(props):
                log.info("%s has the focus (%s)", app.id, active)
                app.activate_until = None
                return
        # Activate the newest live app window: the first one may have gone.
        pick = self.pick_app_window(app, self.client_list())
        if pick and pick[1]:
            # Only a splash is up, and the main window may still map behind
            # the launcher: keep watching, but not past the launch's 15 s
            # plus the reveal wait.
            app.activate_until = max(app.activate_until, min(
                now + ACTIVATE_FOR_S, app.launched_at + LAUNCH_TIMEOUT_S + APP_REVEAL_S))
        if now >= app.activate_until:
            if not (pick and pick[0] == active):
                log.warning("%s never took the focus; leaving it", app.id)
            app.activate_until = None
            return
        if pick and pick[0] != active:
            app.activate_wid = pick[0]
            self.run_cmd(["wmctrl", "-i", "-a", app.activate_wid])
        app.next_activate = now + ACTIVATE_EVERY_S

    def client_list(self):
        """The client window ids, or None if the window list can't be read
        (no X server, no xprop, or a window manager that doesn't keep it)."""
        root = self.run_capture(["xprop", "-root", "_NET_CLIENT_LIST"])
        if "_NET_CLIENT_LIST(WINDOW)" not in root:
            return None
        return parse_client_list(root)

    def return_from_desktop(self):
        """Ask every desktop window to close, then show Home or Still open."""
        if self.returning:
            return
        self.desktop = False
        cache = {}
        kept = self.kept_windows()
        windows = [(w, p) for w, p in self.list_windows(cache) if closable(w, p) and w not in kept]
        if not windows:
            self.show()
            return
        for wid, props in windows:
            log.info("return: closing %s (%s)", wid, props["name"])
            self.act(["wmctrl", "-i", "-c", wid])
        if self.app:
            self.app.not_owned |= {w for w, _ in windows}
        now = self.now()
        self.returning = {"deadline": now + RETURN_WAIT_S, "next": now + RETURN_POLL_S,
                          "started": now, "props": cache}

    def poll_return(self):
        """Every 250 ms for up to 5 s: done once nothing closable is left."""
        windows = self.list_windows(self.returning["props"])
        kept = self.kept_windows()
        left = [(w, p) for w, p in windows if closable(w, p) and w not in kept]
        now = self.now()
        asking = any(p["transient_for"] == w for w, _ in left for _, p in windows)
        if not left:
            self.returning = None
            self.show()
        elif asking and now < self.returning["started"] + RETURN_PROMPT_WAIT_S:
            # A save prompt is up: the viewer is answering it, so don't put
            # Still open on top of it (D70).
            self.returning["next"] = now + RETURN_POLL_S
        elif now >= self.returning["deadline"]:
            self.returning = None
            # Read the windows left once more: a title can change while the
            # flow runs, and one may have just gone.
            left = [(w, self.window_props(w)) for w, _ in left]
            left = [(w, p) for w, p in left if p["read"]]
            if not left:
                self.show()
                return
            if self.app:
                self.app.not_owned |= {w for w, _ in left}
            self.send({"evt": "still_open", "apps": [self.describe(w, p, windows) for w, p in left]})
        else:
            self.returning["next"] = now + RETURN_POLL_S

    def note_kept_windows(self):
        """Going to the desktop with a keep_on_home app running behind the
        launcher: the windows open now that weren't before its launch are
        its own, so Return leaves them open. Windows Return has asked to
        close before, or left open on an earlier desktop visit, are the
        viewer's."""
        app = self.app
        if not app or not app.keep_on_home or app.closing:
            return
        app.owned |= set(self.client_list() or []) - app.baseline - app.not_owned

    def disown_desktop_windows(self):
        """The launcher is back from the desktop without Return (Power, or
        the viewer clicked it): the new windows still open, other than a
        keep_on_home app's own, were opened there by the viewer. The next
        Desktop visit must not count them as the app's, or Return would
        never close them."""
        app = self.app
        if not app or not app.keep_on_home or app.closing:
            return
        app.not_owned |= set(self.client_list() or []) - app.baseline - app.owned

    def kept_windows(self):
        """Windows Return never closes: a keep_on_home app's own."""
        app = self.app
        return app.owned if app and app.keep_on_home and not app.closing else set()

    def describe(self, wid, props, windows):
        """What the Still open screen lists for a window."""
        entry = desktop_entry_for(props["classes"], self.app_dirs) if props["classes"] else None
        asking = any(p["transient_for"] == wid for _, p in windows)
        return {"wid": wid, "name": entry["name"] if entry else (props["name"] or "Untitled window"),
                "icon": entry["icon"] if entry else "", "asking": asking}

    def show_window(self, wid):
        """Show me: the launcher has hidden; raise the window with its prompt."""
        if not isinstance(wid, str) or not WID.match(wid):
            log.warning("show_window: bad window id %r", wid)
            return
        self.visible = False
        self.desktop = True  # the next Home starts the flow again
        self.focus_until = None
        self.run_cmd(["wmctrl", "-i", "-a", wid])

    def force_close(self, wids):
        """Close anyway, after the launcher's confirm: xkill each window, never a PID."""
        if not isinstance(wids, list):
            return
        self.desktop = False
        for wid in wids:
            if isinstance(wid, str) and WID.match(wid):
                self.act(["xkill", "-id", wid])
            else:
                log.warning("force_close: bad window id %r", wid)

    def act(self, argv):
        """Commands that close windows; logged instead under dry run (D26)."""
        if dry_run():
            log.info("dry run: would run %s", " ".join(argv))
            return
        self.run_cmd(argv)

    # Apps ---------------------------------------------------------------------

    def launch(self, app_id, argv, keep_on_home=False):
        if not isinstance(app_id, str) or not isinstance(argv, list) or not argv \
                or not all(isinstance(a, str) for a in argv):
            self.send({"evt": "launch_failed", "id": app_id, "error": "bad launch request"})
            return
        if self.app:
            log.info("launch %s: ending %s first", app_id, self.app.id)
            self.pending = (app_id, argv, keep_on_home)
            # D86: the launcher asked for a new app, not for Home, even if the
            # old one was already ending with a show to follow (launch_timeout).
            self.app.show_after = False
            if not self.app.closing:
                self.close_app(then_show=False)
            return
        self._spawn(app_id, argv, keep_on_home)

    def _spawn(self, app_id, argv, keep_on_home):
        try:
            proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, start_new_session=True)
        except (OSError, ValueError) as e:  # ValueError: a NUL byte in argv
            log.warning("launch %s failed: %s", app_id, e)
            self.send({"evt": "launch_failed", "id": app_id, "error": str(e)})
            return
        log.info("launched %s as pid %d", app_id, proc.pid)
        self.app = App(app_id, proc, keep_on_home)
        self.watch_for_window(self.app)

    # First window (D63) --------------------------------------------------------

    def watch_for_window(self, app):
        """Remembers the windows already open, so the app's first new one
        counts. Without a window list, nothing can be timed: say the window
        is there, so the launcher stops waiting too."""
        known = self.client_list()
        if known is None:
            log.info("cannot read the window list; not timing %s", app.id)
            self.send({"evt": "app_window", "id": app.id})
            return
        now = self.now()
        app.known = set(known)
        app.baseline = set(known)
        app.launched_at = now
        app.window_deadline = now + LAUNCH_TIMEOUT_S
        app.next_window_poll = now + WINDOW_POLL_S

    def poll_window(self):
        """Every 500 ms until the app shows a window, or 15 s pass. Then the
        launch has failed: end the app the way Home does."""
        app = self.app
        now = self.now()
        for wid in self.client_list() or []:
            if wid in app.known:
                continue
            props = self.window_props(wid)
            if not props["read"]:
                continue  # gone already, or xprop failed: look again next poll
            app.known.add(wid)
            if is_app_window(props):
                log.info("%s showed window %s", app.id, wid)
                if app.keep_on_home and wid not in app.not_owned:
                    # Its own, which Return leaves open, even when it maps
                    # after the viewer has gone to the desktop.
                    app.owned.add(wid)
                app.window_deadline = None
                # Left behind the black launcher a moment longer while it
                # goes full screen, so the desktop never flashes (D77).
                app.activate_wid = wid
                app.reveal_at = now + APP_REVEAL_S
                return
        if now >= app.window_deadline:
            log.warning("%s showed no window within %.0f s; ending it", app.id, LAUNCH_TIMEOUT_S)
            app.window_deadline = None
            self.send({"evt": "launch_timeout", "id": app.id})
            self.close_app(then_show=True)
            return
        app.next_window_poll = min(now + WINDOW_POLL_S, app.window_deadline)

    def close_app(self, then_show):
        app = self.app
        app.closing = True
        # Nothing to reveal, focus or wait for now. Left set, these times
        # fall into the past in next_timeout() and the loop spins until the
        # app has gone.
        app.reveal_at = None
        app.activate_until = None
        app.window_deadline = None
        app.show_after = app.show_after or then_show
        app.deadline = self.now() + GRACE_S
        self._signal(app, signal.SIGTERM)

    def launcher_over_app(self):
        """D85: the launcher is back on screen while an app runs or is still
        starting (Power, Home on a keep_on_home app, the launcher's own
        deadline). Nothing raises or focuses the app now. An app without
        keep_on_home is ended the way Home ends it, so none runs unseen
        behind the launcher (Law 4); a keep_on_home app runs on behind it."""
        app = self.app
        if not app:
            return
        if app.closing:
            if self.pending:
                # A launch is still waiting for this app to end. Started now,
                # it would run unseen behind the launcher, so drop it, and say
                # it has ended so the launcher stops waiting for it. The old
                # app's own exit then goes out as a plain app_exited.
                app_id = self.pending[0]
                self.pending = None
                log.info("launcher shown before %s could start: not starting it", app_id)
                self.send({"evt": "app_exited", "id": app_id, "code": 0})
            return
        app.activate_until = None
        if app.reveal_at is not None:
            app.reveal_at = None
            if app.keep_on_home:
                # Its window is up, so the launcher can stop waiting for it.
                self.send({"evt": "app_window", "id": app.id})
        if not app.keep_on_home:
            log.info("launcher shown over %s: closing it", app.id)
            self.close_app(then_show=False)

    def _signal(self, app, sig):
        try:
            self.signal_group(app.pgid, sig)
        except ProcessLookupError:
            pass
        except PermissionError as e:  # a group member owned by another user
            log.warning("cannot signal %s: %s", app.id, e)

    def _group_alive(self, pgid):
        try:
            self.signal_group(pgid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    def poll_app(self):
        app = self.app
        if not app:
            return
        code = app.proc.poll()
        if app.closing:
            if self._group_alive(app.pgid):
                now = self.now()
                if not app.killed and now >= app.deadline:
                    log.info("%s still running after %.0f s: SIGKILL", app.id, GRACE_S)
                    self._signal(app, signal.SIGKILL)
                    app.killed = True
                    app.deadline = now + GRACE_S
                    return
                if not app.killed or now < app.deadline:
                    return
                # Part of the group outlived SIGKILL (uninterruptible sleep, a
                # zombie whose parent left the group, another user's process).
                # The kill stays pending on it; Home, the next launch and the
                # launcher's show must not wait on it for ever.
                log.warning("%s: part of its process group outlived SIGKILL; moving on", app.id)
                code = -signal.SIGKILL if code is None else code
            elif code is None:
                return
        elif code is None:
            return
        self._finish(app, code)

    def _finish(self, app, code):
        log.info("%s exited with %s", app.id, code)
        self.app = None
        if self.pending:
            # D86: a new launch ended it. The launcher is waiting for the new
            # app, so no show and no raise; "replaced" tells it to keep waiting.
            self.send({"evt": "app_exited", "id": app.id, "code": code, "replaced": True})
            pending, self.pending = self.pending, None
            self._spawn(*pending)
            return
        self.send({"evt": "app_exited", "id": app.id, "code": code})
        if self.returning:
            # Return is closing the desktop's windows, maybe waiting on a save
            # prompt. It shows Home or Still open itself once it is done.
            return
        if app.show_after:
            if not self.desktop:
                self.show()
            elif app.return_after:
                self.return_from_desktop()  # Home on the desktop, now the app has gone
            # Otherwise the launch timed out while the viewer was on the
            # desktop. Nobody pressed Home, so they stay there.
        elif not self.visible and not self.desktop:
            # The app closed itself; the launcher is behind it. On the
            # desktop it is minimised, and raising it would pull the viewer
            # back to Home without Return.
            self.raise_launcher()

    # Power --------------------------------------------------------------------

    def power(self, action):
        if not isinstance(action, str):
            log.warning("bad power action %r", action)
            return
        argv = POWER_COMMANDS.get(action)
        if not argv:
            log.warning("unknown power action %r", action)
            return
        if dry_run():
            log.info("dry run: would run %s", " ".join(argv))
            # The launcher shows "Shutting down" until the box goes down.
            # Nothing will, so take it back to Home.
            self.send({"evt": "show"})
            return
        log.info("running %s", " ".join(argv))
        code = self.run_wait(argv)
        if code != 0:
            # Refused (an inhibitor, polkit) or missing: the launcher says so
            # rather than showing "Shutting down" for ever.
            log.warning("%s failed: %s", " ".join(argv),
                        "could not start" if code is None else "exit status %d" % code)
            self.send({"evt": "power_failed", "action": action})

    # evdev --------------------------------------------------------------------

    def rescan(self):
        try:
            with open(os.path.join(self.proc_root, "bus/input/devices")) as f:
                wanted = parse_devices(f.read())
        except OSError:
            wanted = {}
        for path in list(self.devices):
            if path not in wanted:
                self._close_device(path)
        for path, name in wanted.items():
            if path in self.devices:
                continue
            try:
                fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
            except OSError as e:
                if path not in self._denied:
                    log.warning("cannot read %s (%s): %s", path, name, e)
                    self._denied.add(path)
                continue
            self._denied.discard(path)
            self.devices[path] = [fd, name, b""]
            self.sel.register(fd, selectors.EVENT_READ, lambda fd, p=path: self._read_device(p))
            log.info("watching %s (%s)", path, name)

    def _read_device(self, path):
        dev = self.devices.get(path)
        if not dev:
            return
        try:
            data = os.read(dev[0], EVENT.size * 64)
        except BlockingIOError:
            return
        except OSError as e:
            if e.errno == errno.ENODEV:
                log.info("%s went away", path)
            self._close_device(path)
            return
        events, dev[2] = parse_events(dev[2] + data)
        for _, _, etype, code, value in events:
            if etype == EV_KEY:
                self.on_key(path, code, value)

    def _close_device(self, path):
        fd = self.devices.pop(path)[0]
        try:
            self.sel.unregister(fd)
        except (KeyError, ValueError):
            pass
        os.close(fd)
        self.meta_down.discard(path)

    def _read_stdin(self, stdin):
        line = stdin.readline()
        if not line:
            self.sel.unregister(stdin)
            return
        word = line.strip().lower()
        if word in ("home", "guide", "super+home"):
            self.on_home()
        elif word == "power":
            self.on_power()
        elif word:
            log.warning("fake input: say home, guide, super+home or power")

    # Memory watch -------------------------------------------------------------

    def sample_memory(self):
        now = self.now()
        avail = self.mem_available_mb()
        if avail is None:
            return
        app = self.app
        rss = self.group_rss_mb(app.pgid) if app else 0
        if now - self.last_mem_log >= MEM_LOG_S:
            self.last_mem_log = now
            log.info("memory: %d MB available; %s %d MB", avail,
                     app.id if app else "no app", rss)
        if avail >= MEM_LOW_MB:
            self.low_since = None
            self.mem_warned = False
            return
        if self.low_since is None:
            self.low_since = now
        if not self.mem_warned and now - self.low_since >= MEM_LOW_FOR_S:
            self.mem_warned = True
            name = app.id if app else "no app"
            log.warning("memory low: %d MB available for %.0f s, running %s (%d MB)",
                        avail, now - self.low_since, name, rss)
            self.send({"evt": "memory_warning", "id": app.id if app else None,
                       "available_mb": avail, "app_mb": rss})

    def mem_available_mb(self):
        try:
            with open(os.path.join(self.proc_root, "meminfo")) as f:
                for line in f:
                    if line.startswith("MemAvailable:"):
                        return int(line.split()[1]) // 1024
        except (OSError, ValueError):
            pass
        return None

    def group_rss_mb(self, pgid):
        total_kb = 0
        try:
            pids = [p for p in os.listdir(self.proc_root) if p.isdigit()]
        except OSError:
            return 0
        for pid in pids:
            base = os.path.join(self.proc_root, pid)
            try:
                with open(os.path.join(base, "stat")) as f:
                    fields = f.read().rsplit(")", 1)[1].split()
                if int(fields[2]) != pgid:
                    continue
                with open(os.path.join(base, "status")) as f:
                    for line in f:
                        if line.startswith("VmRSS:"):
                            total_kb += int(line.split()[1])
                            break
            except (OSError, ValueError, IndexError):
                continue
        return total_kb // 1024


# Return shortcut client --------------------------------------------------------

def send_return(runtime=None):
    """Asks the running daemon to start Return to Bosca Mor. Exit code 0 on success."""
    runtime = runtime or paths()["runtime"]
    try:
        with open(os.path.join(runtime, "port")) as f:
            port = int(f.read())
        with open(os.path.join(runtime, "token")) as f:
            token = f.read().strip()
        with socket.create_connection(("127.0.0.1", port), timeout=2) as s:
            s.sendall((token + "\n" + json.dumps({"cmd": "return"}) + "\n").encode())
    except (OSError, ValueError) as e:
        print("boscamor-input: daemon not reachable: %s" % e, file=sys.stderr)
        return 1
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(description="Companion daemon for the launcher.")
    p.add_argument("--fake-input", action="store_true",
                   help="read home, guide, super+home or power lines on stdin")
    p.add_argument("--no-evdev", action="store_true", help="do not read /dev/input")
    p.add_argument("--return", dest="ret", action="store_true",
                   help="ask the running daemon to return from the desktop, then exit")
    p.add_argument("--dev-port", type=int, metavar="PORT",
                   help="dev machine only: bind this fixed port and print BOSCAMOR_IPC=PORT:TOKEN")
    args = p.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    if args.ret:
        return send_return()
    if args.dev_port is not None and not 0 < args.dev_port < 65536:
        p.error("--dev-port must be 1 to 65535")
    d = Daemon(fake_input=args.fake_input, evdev=not args.no_evdev, dev_port=args.dev_port)
    d.start()
    d.install_signals()
    try:
        d.run()
    except (KeyboardInterrupt, SystemExit):
        pass
    finally:
        d.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
