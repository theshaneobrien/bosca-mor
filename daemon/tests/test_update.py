"""The daemon's updater (D103) against a release server in this process.

The server stands in for GitHub: /latest is the release JSON and
/boscamor.tar.xz the update, with Range support. Nothing here reaches the
network or a real install: the install tests run install.sh --update into a
scratch root with the stand-in tools from test_install.
"""
import hashlib
import http.server
import io
import json
import os
import shutil
import socket
import sys
import tarfile
import tempfile
import threading
import time
import unittest
from unittest import mock

os.environ["BOSCAMOR_DRY_RUN"] = "1"  # always, before anything can act

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from test_daemon import Recorder, bi, scratch_paths  # noqa: E402
import test_install  # noqa: E402

REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
LINUX = test_install.LINUX


def launcher_stub(says):
    """A launcher whose self-test says this."""
    return ("#!/usr/bin/env bash\n[ \"${!#}\" = --self-test ] && echo 'self-test ok %s'\nexit 0\n" % says).encode()


def bundle(version="0.14.0", launcher=None, extra=None, install_sh=None, pad=0):
    """An update archive laid out like tools/update-bundle.sh's. pad adds
    bytes that don't compress, so a download takes many reads."""
    buf = io.BytesIO()

    def add(tar, name, data, mode=0o644):
        info = tarfile.TarInfo(name)
        info.size = len(data)
        info.mode = mode
        tar.addfile(info, io.BytesIO(data))

    with tarfile.open(fileobj=buf, mode="w:xz") as tar:
        add(tar, "version", (version + "\n").encode())
        add(tar, "build/boscamor", launcher if launcher is not None else launcher_stub(version), 0o755)
        with open(os.path.join(REPO, "daemon", "boscamor-input.py"), "rb") as f:
            add(tar, "daemon/boscamor-input.py", f.read(), 0o755)
        if install_sh is None:
            with open(os.path.join(REPO, "install", "install.sh"), "rb") as f:
                install_sh = f.read()
        add(tar, "install/install.sh", install_sh, 0o755)
        for d in ("install/files", "launcher/assets/icon"):
            for name in sorted(os.listdir(os.path.join(REPO, d))):
                with open(os.path.join(REPO, d, name), "rb") as f:
                    mode = 0o755 if os.access(os.path.join(REPO, d, name), os.X_OK) else 0o644
                    add(tar, "%s/%s" % (d, name), f.read(), mode)
        for name, data in (extra or {}).items():
            add(tar, name, data)
        if pad:
            add(tar, "padding", os.urandom(pad))
    return buf.getvalue()


class Releases(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.data = b""
        self.release = {}
        self.ranges = []       # the Range header of each download request ("" for none)
        self.cut_after = None  # send this many bytes, then hang up (once)
        self.slow = 0.0        # seconds between 64 KB pieces
        self.fail = None       # an HTTP status for /latest
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()

    def url(self, path):
        return "http://127.0.0.1:%d%s" % (self.server_address[1], path)

    def publish(self, data, tag="v0.14.0", digest=None, name="boscamor.tar.xz"):
        self.data = data
        self.release = {"tag_name": tag, "assets": [{
            "name": name, "size": len(data), "browser_download_url": self.url("/" + name),
            "digest": digest or "sha256:" + hashlib.sha256(data).hexdigest()}]}

    def close(self):
        self.shutdown()
        self.server_close()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        srv = self.server
        if self.path == "/latest":
            if srv.fail:
                self.send_error(srv.fail)
                return
            body = json.dumps(srv.release).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        rng = self.headers.get("Range", "")
        srv.ranges.append(rng)
        start = int(rng[len("bytes="):].rstrip("-")) if rng.startswith("bytes=") else 0
        if start >= len(srv.data) and start:
            self.send_response(416)
            self.end_headers()
            return
        body = srv.data[start:]
        self.send_response(206 if start else 200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if srv.cut_after is not None:
            n, srv.cut_after = srv.cut_after, None
            self.wfile.write(body[:n])
            self.wfile.flush()
            self.connection.shutdown(socket.SHUT_RDWR)
            return
        for i in range(0, len(body), 65536):
            try:
                self.wfile.write(body[i:i + 65536])
                self.wfile.flush()
            except OSError:
                return
            if srv.slow:
                time.sleep(srv.slow)


class Base(unittest.TestCase):
    def setUp(self):
        self.srv = Releases()
        self.addCleanup(self.srv.close)
        self.p = scratch_paths()
        self.u = bi.Updater(p=self.p, api=self.srv.url("/latest"))

    def statuses(self):
        return [e["status"] for e in self.u.events()]

    def run_job(self, busy=False):
        self.u.tick(time.monotonic(), busy)
        self.u.wait()
        self.u.tick(time.monotonic(), busy)

    def check(self, installed="0.13.3"):
        self.u.hello(installed)
        self.assertTrue(self.u.check())
        self.u.wait()


class TestVersions(unittest.TestCase):
    def test_versions(self):
        self.assertEqual(bi.parse_version("v0.13.3"), (0, 13, 3))
        self.assertEqual(bi.parse_version("0.14.0"), (0, 14, 0))
        self.assertLess(bi.parse_version("0.9.9"), bi.parse_version("0.10.0"))
        for bad in ("", None, "v1.2", "1.2.3-beta", "latest"):
            self.assertIsNone(bi.parse_version(bad), bad)

    def test_a_release_without_the_update_says_why(self):
        ok = {"tag_name": "v0.14.0", "assets": [{"name": "boscamor.tar.xz", "size": 3,
              "browser_download_url": "https://x/y", "digest": "sha256:" + "a" * 64}]}
        self.assertEqual(bi.parse_release(ok)["sha256"], "a" * 64)
        cases = {
            "The latest release has no version": dict(ok, tag_name="nightly"),
            "The latest release has no update file": dict(ok, assets=[{"name": "boscamor"}]),
            "The latest release has no checksum": dict(ok, assets=[dict(ok["assets"][0], digest=None)]),
        }
        for words, data in cases.items():
            with self.assertRaises(ValueError) as e:
                bi.parse_release(data)
            self.assertEqual(str(e.exception), words)


class TestCheck(Base):
    def test_nothing_happens_before_a_launcher_says_hello(self):
        self.assertFalse(self.u.check())
        self.assertIsNone(self.u.next_due(time.monotonic()))
        self.u.hello("0.13.3")
        self.assertGreater(self.u.next_due(time.monotonic()), time.monotonic() + 60)

    def test_a_newer_release_is_found(self):
        self.srv.publish(b"x")
        self.check()
        self.assertEqual(self.statuses(), ["checking", "available"])
        self.assertEqual(self.u.status, {"status": "available", "version": "0.14.0"})

    def test_the_same_or_an_older_release_is_up_to_date(self):
        self.srv.publish(b"x", tag="v0.13.3")
        self.check()
        self.assertEqual(self.u.status, {"status": "current", "version": "0.13.3"})
        self.srv.publish(b"x", tag="v0.12.0")
        self.check()
        self.assertEqual(self.u.status["status"], "current")

    def test_no_internet_says_so(self):
        self.srv.fail = 503
        self.check()
        self.assertEqual(self.u.status["status"], "failed")
        self.assertEqual(self.u.status["error"], "Couldn't reach GitHub")

    def test_a_release_without_the_update_file_says_so(self):
        self.srv.publish(b"x", name="boscamor")
        self.check()
        self.assertEqual(self.u.status["error"], "The latest release has no update file")


class TestDownload(Base):
    def test_downloads_checks_and_tests_the_new_version(self):
        data = bundle()
        self.srv.publish(data)
        self.check()
        self.run_job()
        st = self.statuses()
        self.assertEqual(st[:3], ["checking", "available", "downloading"])
        self.assertEqual(st[-1], "ready")
        self.assertEqual(self.u.status, {"status": "ready", "version": "0.14.0"})
        self.assertTrue(os.path.isfile(os.path.join(self.u.ready, "install", "install.sh")))
        self.assertFalse([f for f in os.listdir(self.u.dir) if f.endswith(".part")])
        self.assertEqual(self.srv.ranges, [""])

    def test_a_damaged_download_is_deleted(self):
        self.srv.publish(bundle(), digest="sha256:" + "0" * 64)
        self.check()
        self.run_job()
        self.assertEqual(self.u.status["error"], "The download was damaged")
        self.assertEqual(os.listdir(self.u.dir), [])
        self.assertIsNone(self.u.ready)
        # Not again until the next check.
        self.u.tick(time.monotonic(), False)
        self.assertIsNone(self.u.job)

    def test_a_cut_download_carries_on_where_it_stopped(self):
        self.srv.publish(bundle(pad=1_000_000))
        self.srv.cut_after = 100000
        self.check()
        self.run_job()
        self.assertEqual(self.u.status["error"], "Couldn't download it")
        self.check()
        self.run_job()
        self.assertEqual(self.u.status["status"], "ready")
        self.assertEqual(self.srv.ranges, ["", "bytes=100000-"])

    def test_an_app_pauses_the_download_and_it_carries_on_after(self):
        self.srv.publish(bundle(pad=1_000_000))
        self.srv.slow = 0.05
        self.check()
        self.u.tick(time.monotonic(), False)
        self.assertEqual(self.u.job, "download")
        end = time.monotonic() + 10
        while self.u.status.get("percent", 0) < 5 and time.monotonic() < end:
            time.sleep(0.05)
            self.u.tick(time.monotonic(), False)
        self.assertGreaterEqual(self.u.status.get("percent", 0), 5, "under way")
        self.u.tick(time.monotonic(), True)       # an app opened
        self.u.wait()
        self.u.tick(time.monotonic(), True)
        self.assertEqual(self.u.status["status"], "available")
        self.assertIsNone(self.u.job, "no download while the app runs")
        self.srv.slow = 0.0
        self.run_job()                              # the app closed
        self.assertEqual(self.u.status["status"], "ready")
        self.assertEqual(len(self.srv.ranges), 2)
        self.assertRegex(self.srv.ranges[1], r"^bytes=[1-9]\d*-$")

    def test_a_launcher_that_does_not_start_is_not_installed(self):
        self.srv.publish(bundle(launcher=launcher_stub("0.13.9")))
        self.check()
        self.run_job()
        self.assertEqual(self.u.status["error"], "The new version didn't start")
        self.assertIsNone(self.u.ready)
        self.assertEqual(os.listdir(self.u.dir), [])

    def test_an_archive_reaching_outside_its_folder_is_refused(self):
        self.srv.publish(bundle(extra={"../escaped": b"x"}))
        self.check()
        self.run_job()
        self.assertEqual(self.u.status["error"], "The download was damaged")
        self.assertFalse(os.path.exists(os.path.join(os.path.dirname(self.u.dir), "escaped")))

    def test_installed_by_hand_meanwhile_forgets_the_download(self):
        self.srv.publish(bundle())
        self.check()
        self.run_job()
        self.u.events()
        self.u.hello("0.14.0")
        self.assertEqual(self.u.status, {"status": "current", "version": "0.14.0"})
        self.assertIsNone(self.u.ready)


@unittest.skipUnless(LINUX, "needs Linux (bash, GNU coreutils)")
class TestInstall(Base, test_install.Scratch):
    """install.sh --update from the downloaded update, into a scratch root."""

    def setUp(self):
        Base.setUp(self)
        test_install.Scratch.setUp(self)
        self.p["install"] = self.dest
        self.u = bi.Updater(p=self.p, api=self.srv.url("/latest"))
        env = {"PATH": self.stubs + ":" + os.environ.get("PATH", "/usr/bin:/bin"), "HOME": self.home,
               "BOSCAMOR_ROOT": self.sys, "STUB_DIR": self.stubs, "STUB_STATE": self.state,
               "STUB_LOG": self.log, "STUB_FAIL": "", "LANG": "C"}
        patch = mock.patch.dict(os.environ, env)
        patch.start()
        self.addCleanup(patch.stop)
        os.makedirs(self.dest)
        for name in ("boscamor", "boscamor-input.py", "share-screen"):
            self.write(os.path.join(self.dest, name), "old " + name, 0o755)
        # Everything the system steps want is in place already.
        p = self.run_script("install/install.sh", "--no-apps")
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        for name in ("boscamor", "boscamor-input.py", "share-screen"):
            self.write(os.path.join(self.dest, name), "old " + name, 0o755)
        os.remove(self.log)

    def ready(self, **kw):
        """Ready to install, as after a download. The launcher here is no real
        build, so the download's self-test is skipped (TestDownload has it)."""
        self.launcher = b"\x7fELF new launcher"
        archive = os.path.join(self.tmp, "update.tar.xz")
        self.write(archive, bundle(launcher=self.launcher, **kw))
        os.makedirs(self.u.dir, exist_ok=True)
        target = os.path.join(self.u.dir, "0.14.0")
        bi.unpack(archive, target)
        self.u.hello("0.13.3")
        self.u.release = {"version": "0.14.0", "url": "", "size": 0, "sha256": ""}
        self.u.ready = target

    def test_installs_keeps_the_old_version_and_restarts(self):
        self.ready()
        self.assertTrue(self.u.install())
        self.run_job()
        self.assertEqual(self.statuses(), ["installing"])
        self.assertTrue(self.u.restart_daemon)
        with open(os.path.join(self.dest, "boscamor"), "rb") as f:
            self.assertEqual(f.read(), self.launcher)
        self.assertEqual(self.read(os.path.join(self.dest, "boscamor-input.py")),
                         self.read(os.path.join(REPO, "daemon", "boscamor-input.py")))
        for name in ("boscamor", "boscamor-input.py", "share-screen"):
            self.assertEqual(self.read(os.path.join(self.dest, "previous", name)), "old " + name)
        with open(self.p["update_json"]) as f:
            st = json.load(f)
        self.assertEqual((st["version"], st["from"], st["restart"], st["needs_sudo"]),
                         ("0.14.0", "0.13.3", True, False))
        log = self.read(self.p["update_log"])
        self.assertIn("the daemon restarts itself after the update", log)
        self.assertEqual(self.logged(), [], "nothing ran through sudo, and nothing restarted the service")
        self.assertEqual([f for f in os.listdir(self.u.dir) if f != "installed.json"], [])

    def test_system_changes_are_listed_for_later(self):
        with open(os.path.join(self.state, "missing"), "w") as f:
            f.write("x11vnc\n")
        self.ready()
        self.u.install()
        self.run_job()
        self.assertTrue(self.u.restart_daemon)
        with open(self.p["update_json"]) as f:
            self.assertTrue(json.load(f)["needs_sudo"])
        self.assertIn("needs sudo: apt-get install -y x11vnc", self.read(self.p["update_log"]))
        self.assertEqual(self.logged(), [])

    def test_a_failed_install_puts_the_old_version_back(self):
        script = b"#!/usr/bin/env bash\necho half > \"$BOSCAMOR_ROOT/opt/boscamor/boscamor\"\nexit 1\n"
        self.ready(install_sh=script)
        self.u.install()
        self.run_job()
        self.assertEqual(self.u.status["error"], "Couldn't install it")
        self.assertFalse(self.u.restart_daemon)
        self.assertEqual(self.read(os.path.join(self.dest, "boscamor")), "old boscamor")
        self.assertFalse(os.path.exists(self.p["update_json"]))

    def test_after_the_restart_the_old_launcher_hands_over_to_the_new(self):
        self.ready()
        self.u.install()
        self.run_job()
        d = Recorder(updater=bi.Updater(p=self.p, api=self.srv.url("/latest")))
        self.assertEqual(d.updater.handover, "0.14.0")
        old, old_end = self.client(d)
        d.handle({"cmd": "hello", "version": "0.13.3"}, old)
        self.assertEqual(self.said(old_end), [{"evt": "update", "status": "restart", "version": "0.14.0"}])
        new, new_end = self.client(d)
        d.handle({"cmd": "hello", "version": "0.14.0"}, new)
        self.assertEqual(self.said(old_end), [{"evt": "quit"}])
        self.assertNotIn(old, d.clients)
        # Until the old window has gone, a focused "Launcher" may be the old one.
        d.handle({"cmd": "state", "visible": True}, new)
        d.poll_launcher_focus()
        self.assertIsNotNone(d.focus_until, "the focus loop goes on")
        self.assertGreaterEqual(d.next_focus, d.now() + 1.5, "and looks again once the old window has gone")
        self.assertEqual(self.said(new_end), [{"evt": "update", "status": "current", "version": "0.14.0", "installed": True}])
        self.assertIsNone(d.updater.handover)
        # Once only: a daemon started again later asks nobody to restart.
        self.assertIsNone(bi.Updater(p=self.p).handover)

    def client(self, d):
        a, b = socket.socketpair()
        self.addCleanup(a.close)
        self.addCleanup(b.close)
        c = bi.Client(a, d.now())
        c.authed = True
        d.clients.append(c)
        return c, b

    def said(self, end):
        end.settimeout(1.0)
        data = b""
        while not data.endswith(b"\n"):
            data += end.recv(4096)
        return [json.loads(line) for line in data.decode().splitlines()]


class TestDaemon(Base):
    """The daemon's side: commands, the busy rule, the app ended for an install."""

    def daemon(self):
        d = Recorder(updater=self.u)
        self.addCleanup(d.close)
        return d

    def test_hello_then_a_check_on_request(self):
        self.srv.publish(bundle())
        d = self.daemon()
        d.handle({"cmd": "hello", "version": "0.13.3"})
        d.handle({"cmd": "update_check"})
        self.u.wait()
        d.tick()
        self.assertEqual([e["status"] for e in d.events("update")][:2], ["checking", "available"])

    def test_check_before_hello_answers_with_the_status(self):
        d = self.daemon()
        d.handle({"cmd": "update_check"})
        self.assertEqual(d.events("update"), [{"evt": "update", "status": "unknown"}])

    def test_no_download_while_on_the_desktop(self):
        self.srv.publish(bundle())
        d = self.daemon()
        d.handle({"cmd": "hello", "version": "0.13.3"})
        self.u.check()
        self.u.wait()
        d.handle({"cmd": "desktop", "notify": False})
        d.tick()
        self.assertIsNone(self.u.job)
        d.handle({"cmd": "state", "visible": True})
        d.tick()
        self.assertEqual(self.u.job, "download")
        self.u.wait()

    def test_install_ends_a_running_app_first(self):
        self.srv.publish(bundle())
        d = self.daemon()
        d.handle({"cmd": "hello", "version": "0.13.3"})
        self.u.check()
        self.u.wait()
        self.run_job()
        self.assertEqual(self.u.status["status"], "ready")
        d.launch("music", ["sleep", "30"], keep_on_home=True)
        d.handle({"cmd": "update_install"})
        self.assertTrue(d.app.closing)
        self.assertTrue(d.install_asked)
        self.assertTrue(d.pump(lambda: d.app is None))
        d.tick()
        self.u.wait()
        d.tick()
        st = [e["status"] for e in d.events("update")]
        self.assertEqual(st[-2:], ["installing", "failed"])
        # Under a dry run with no scratch root, nothing is installed.
        self.assertEqual(d.events("update")[-1]["error"], "Dry run: nothing was installed")

    def test_install_with_nothing_ready_says_so(self):
        d = self.daemon()
        d.handle({"cmd": "hello", "version": "0.13.3"})
        d.handle({"cmd": "update_install"})
        d.tick()
        self.assertEqual(d.events("update")[-1]["error"], "No update is ready to install")


if __name__ == "__main__":
    unittest.main()
