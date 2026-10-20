#!/usr/bin/env python3
"""boscamor-input: the launcher's companion daemon.

Watches the global keys (Home, Guide, Super + Home, Power) while another app
has focus, starts and ends apps for the launcher, runs confirmed power
actions, and sends the Desktop notification. Python 3 stdlib only; see
docs/SPEC.md "Companion daemon".

  boscamor-input.py                 run the daemon
  boscamor-input.py --fake-input    also read home/guide/super+home/power lines on stdin
  boscamor-input.py --return        ask the running daemon to return from the desktop

BOSCAMOR_DRY_RUN=1 logs power actions instead of running them.
BOSCAMOR_RUNTIME_DIR overrides where the port and token files go.
"""

import argparse
import errno
import json
import logging
import os
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
POWER_COMMANDS = {
    "poweroff": ["systemctl", "poweroff"],
    "reboot": ["systemctl", "reboot"],
}


def dry_run():
    return os.environ.get("BOSCAMOR_DRY_RUN") == "1"


def runtime_dir():
    override = os.environ.get("BOSCAMOR_RUNTIME_DIR")
    if override:
        return override
    base = os.environ.get("XDG_RUNTIME_DIR") or "/tmp/boscamor-%d" % os.getuid()
    return os.path.join(base, "boscamor")


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
    def __init__(self, runtime=None, proc_root="/proc", fake_input=False, evdev=True):
        self.runtime = runtime or runtime_dir()
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

    # Setup --------------------------------------------------------------------

    def start(self):
        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server.bind(("127.0.0.1", 0))
        self.server.listen(4)
        self.server.setblocking(False)
        self.port = self.server.getsockname()[1]
        self.sel.register(self.server, selectors.EVENT_READ, self._accept)
        self._write_runtime()
        if self.fake_input:
            self.sel.register(sys.stdin, selectors.EVENT_READ, self._read_stdin)
        log.info("listening on 127.0.0.1:%d, runtime %s%s", self.port, self.runtime,
                 " (dry run)" if dry_run() else "")

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
            self.run_cmd(["notify-send", NOTIFY_TITLE, NOTIFY_BODY])
        elif cmd == "return":
            self.return_from_desktop()
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

    def return_from_desktop(self):
        # Step 8 replaces this with the Return to Bosca Mor flow.
        self.desktop = False
        self.show()

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
    runtime = runtime or runtime_dir()
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
    args = p.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    if args.ret:
        return send_return()
    d = Daemon(fake_input=args.fake_input, evdev=not args.no_evdev)
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
