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
WATCHED_KEYS = (KEY_HOMEPAGE, BTN_MODE, KEY_POWER, KEY_HOME)
META_KEYS = (KEY_LEFTMETA, KEY_RIGHTMETA)
PRESS = 1  # 0 release, 2 repeat

RESCAN_S = 3.0
GRACE_S = 3.0
CLOSING_POLL_S = 0.05
HANDSHAKE_S = 2.0
RAISE_FALLBACK_S = 0.5
MEM_SAMPLE_S = 10.0
MEM_LOG_S = 60.0
MEM_LOW_MB = 512
MEM_LOW_FOR_S = 30.0
MAX_LINE = 65536

NOTIFY_TITLE = "Launcher closed"
NOTIFY_BODY = "Press Home on the remote, the Guide button, or Super + Home to bring it back."
LAUNCHER_TITLE = "Launcher"  # the launcher's window title, for the wmctrl raise fallback
RETURN_POLL_S = 0.25
RETURN_WAIT_S = 5.0
# Window types Return to Bosca Mor never closes. Dialogs belong to a parent.
SKIP_TYPES = {"DESKTOP", "DOCK", "NOTIFICATION", "SPLASH", "TOOLBAR", "MENU",
              "DIALOG", "UTILITY", "DROPDOWN_MENU", "POPUP_MENU", "TOOLTIP", "COMBO", "DND"}
# WM_CLASS values (either half) of windows that are part of the desktop or the launcher.
SKIP_CLASSES = {"cinnamon", "nemo-desktop", "boscamor", "launcher"}
WID = re.compile(r"^0x[0-9a-f]+$")
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # for a relative BOSCAMOR_HOME
POWER_COMMANDS = {
    "poweroff": ["systemctl", "poweroff"],
    "reboot": ["systemctl", "reboot"],
}


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
    """Type, class, name and transient-for from `xprop -id <wid> ...`."""
    props = {"types": [], "classes": [], "name": "", "transient_for": None}
    for line in text.splitlines():
        if "not found" in line or "no such atom" in line:
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


def closable(wid, props):
    """True for the windows Return to Bosca Mor asks to close."""
    types = props["types"] or (["DIALOG"] if props["transient_for"] else ["NORMAL"])
    if types[0] != "NORMAL" or any(t in SKIP_TYPES for t in types):
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
        self.raise_at = None
        self.next_rescan = 0.0
        self.next_mem = 0.0
        self.last_mem_log = 0.0
        self.low_since = None
        self.mem_warned = False
        self.server = None
        self.port = None
        self._denied = set()
        self.returning = None  # {"deadline", "next"} while closing desktop windows
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
        if self.evdev and now >= self.next_rescan:
            self.rescan()
            self.next_rescan = now + RESCAN_S
        if now >= self.next_mem:
            self.sample_memory()
            self.next_mem = now + MEM_SAMPLE_S
        if self.returning and now >= self.returning["next"]:
            self.poll_return()
        if self.raise_at is not None and now >= self.raise_at:
            self.raise_at = None
            if not self.visible:
                log.info("launcher did not report visible; raising it with wmctrl")
                self.run_cmd(["wmctrl", "-F", "-a", LAUNCHER_TITLE])
        for c in list(self.clients):
            if not c.authed and now - c.since > HANDSHAKE_S:
                log.warning("dropping a client that sent no token")
                self._drop(c)

    def next_timeout(self):
        now = self.now()
        due = [self.next_mem]
        if self.evdev:
            due.append(self.next_rescan)
        if self.raise_at is not None:
            due.append(self.raise_at)
        if self.app and self.app.closing:
            due.append(now + CLOSING_POLL_S)
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
        except ValueError:
            log.warning("ignoring a line that is not JSON")
            return
        if isinstance(msg, dict):
            self.handle(msg)

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
            self.visible = bool(msg.get("visible"))
            if self.visible:
                self.desktop = False
                self.raise_at = None
        elif cmd == "launch":
            self.launch(msg.get("id"), msg.get("argv"), bool(msg.get("keep_on_home")))
        elif cmd == "power":
            self.power(msg.get("action"))
        elif cmd == "desktop":
            self.desktop = True
            self.visible = False
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

    def on_power(self):
        log.info("power key: asking the launcher to confirm")
        self.send({"evt": "power_confirm"})

    def on_home(self):
        if self.visible:
            return  # the launcher sees Home itself
        app = self.app
        if app and app.closing:
            return
        if app and not app.keep_on_home:
            log.info("home: closing %s", app.id)
            self.close_app(then_show=True)
            return
        if self.desktop and not app:
            self.return_from_desktop()
            return
        self.show()

    def show(self):
        self.send({"evt": "show"})
        self.raise_at = self.now() + RAISE_FALLBACK_S

    # Return to Bosca Mor ------------------------------------------------------

    def list_windows(self):
        """Every client window: [(wid, props)]."""
        root = self.run_capture(["xprop", "-root", "_NET_CLIENT_LIST"])
        out = []
        for wid in parse_client_list(root):
            text = self.run_capture(["xprop", "-id", wid, "_NET_WM_WINDOW_TYPE", "WM_CLASS",
                                     "_NET_WM_NAME", "WM_NAME", "WM_TRANSIENT_FOR"])
            out.append((wid, parse_window(text)))
        return out

    def return_from_desktop(self):
        """Ask every desktop window to close, then show Home or Still open."""
        if self.returning:
            return
        self.desktop = False
        windows = [(w, p) for w, p in self.list_windows() if closable(w, p)]
        if not windows:
            self.show()
            return
        for wid, props in windows:
            log.info("return: closing %s (%s)", wid, props["name"])
            self.act(["wmctrl", "-i", "-c", wid])
        now = self.now()
        self.returning = {"deadline": now + RETURN_WAIT_S, "next": now + RETURN_POLL_S}

    def poll_return(self):
        """Every 250 ms for up to 5 s: done once nothing closable is left."""
        windows = self.list_windows()
        left = [(w, p) for w, p in windows if closable(w, p)]
        now = self.now()
        if not left:
            self.returning = None
            self.show()
        elif now >= self.returning["deadline"]:
            self.returning = None
            self.send({"evt": "still_open", "apps": [self.describe(w, p, windows) for w, p in left]})
        else:
            self.returning["next"] = now + RETURN_POLL_S

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
            if not self.app.closing:
                self.close_app(then_show=False)
            return
        self._spawn(app_id, argv, keep_on_home)

    def _spawn(self, app_id, argv, keep_on_home):
        try:
            proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, start_new_session=True)
        except OSError as e:
            log.warning("launch %s failed: %s", app_id, e)
            self.send({"evt": "launch_failed", "id": app_id, "error": str(e)})
            return
        log.info("launched %s as pid %d", app_id, proc.pid)
        self.app = App(app_id, proc, keep_on_home)

    def close_app(self, then_show):
        app = self.app
        app.closing = True
        app.show_after = app.show_after or then_show
        app.deadline = self.now() + GRACE_S
        self._signal(app, signal.SIGTERM)

    def _signal(self, app, sig):
        try:
            self.signal_group(app.pgid, sig)
        except ProcessLookupError:
            pass

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
                if not app.killed and self.now() >= app.deadline:
                    log.info("%s still running after %.0f s: SIGKILL", app.id, GRACE_S)
                    self._signal(app, signal.SIGKILL)
                    app.killed = True
                return
            if code is None:
                return
        elif code is None:
            return
        self._finish(app, code)

    def _finish(self, app, code):
        log.info("%s exited with %s", app.id, code)
        self.app = None
        self.send({"evt": "app_exited", "id": app.id, "code": code})
        if app.show_after:
            self.show()
        if self.pending:
            pending, self.pending = self.pending, None
            self._spawn(*pending)

    # Power --------------------------------------------------------------------

    def power(self, action):
        argv = POWER_COMMANDS.get(action)
        if not argv:
            log.warning("unknown power action %r", action)
            return
        if dry_run():
            log.info("dry run: would run %s", " ".join(argv))
            return
        log.info("running %s", " ".join(argv))
        self.run_cmd(argv)

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
