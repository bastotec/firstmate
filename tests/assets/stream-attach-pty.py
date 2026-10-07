#!/usr/bin/env python3
"""Drive `fm-stream.sh attach --interactive` from a real pseudoterminal.

Usage: stream-attach-pty.py ROOT NATIVE_DIR LAB

Starts a disposable native hub (loopback, ephemeral port, private token) and a
native agent running bash, then attaches through firstmate's own entry point
and proves: the existing screen is painted on connect, keystrokes reach the
child, a local resize reaches the child's PTY (`stty size`), and the detach key
leaves the endpoint running - over the hub (FM_STREAM_ATTACH_LOCAL=0) and over
the agent's same-machine socket, which must keep working with no hub at all.
Exits non-zero with a reason on the first failure.
"""
import base64
import fcntl
import http.server
import json
import os
import pty
import secrets
import select
import shutil
import signal
import struct
import subprocess
import sys
import stat
import tempfile
import termios
import time
import threading
import urllib.request

ROOT, NATIVE, LAB = sys.argv[1:4]
TOKEN = secrets.token_hex(16)
# Short on purpose: a unix socket path must fit in 104 bytes on macOS.
LOCAL = tempfile.mkdtemp(prefix="fmsa-", dir="/tmp")
procs = []


def fail(message):
    print("FAIL: " + message, file=sys.stderr)
    sys.exit(1)


def wait_file(path, secs=20):
    end = time.time() + secs
    while time.time() < end:
        if os.path.exists(path) and os.path.getsize(path) > 0:
            return open(path).read().split()
        time.sleep(0.05)
    fail("timed out waiting for " + path)


def api(method, path, body=None):
    request = urllib.request.Request(
        URL + path, method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=20) as response:
        data = response.read()
    return data.decode()


def cleanup():
    for proc in procs:
        try:
            proc.terminate()
            proc.wait(5)
        except Exception:
            proc.kill()
    shutil.rmtree(LOCAL, ignore_errors=True)


os.makedirs(LAB + "/home/config", exist_ok=True)
os.makedirs(LAB + "/home/state", exist_ok=True)
os.makedirs(LAB + "/cwd", exist_ok=True)
token_file = LAB + "/token"
with open(token_file, "w") as handle:
    handle.write(TOKEN + "\n")
os.chmod(token_file, 0o600)
env = dict(os.environ, FM_STREAM_TOKEN=TOKEN, FM_STREAM_LOCAL_DIR=LOCAL)
try:
    procs.append(subprocess.Popen(
        [NATIVE + "/fm-stream-hub", "serve", "--bind", "127.0.0.1", "--port", "0",
         "--ready-file", LAB + "/hub.ready", "--pid-file", LAB + "/hub.pid"],
        env=env, stdout=subprocess.DEVNULL, stderr=open(LAB + "/hub.log", "w")))
    host, port = wait_file(LAB + "/hub.ready")
    URL = "http://%s:%s" % (host, port)
    agent_env = dict(os.environ, SHELL="/bin/bash", TERM="xterm-256color", FM_STREAM_LOCAL_DIR=LOCAL)
    agent_env.pop("FM_STREAM_TOKEN", None)
    procs.append(subprocess.Popen(
        [NATIVE + "/fm-stream-agent", "serve", "--hub", URL, "--token-file", token_file,
         "--machine", "attach-test", "--label", "attach-%d" % os.getpid(),
         "--cwd", LAB + "/cwd", "--ready-file", LAB + "/agent.ready",
         "--rows", "40", "--cols", "200", "--poll-secs", "1"],
        env=agent_env, stdout=subprocess.DEVNULL, stderr=open(LAB + "/agent.log", "w")))
    _, endpoint = wait_file(LAB + "/agent.ready")

    # Something on screen before anyone attaches: the paint must show it.
    api("POST", "/v1/tasks/%s/input" % endpoint, {"text": "echo before-$((20+1))", "submit": True})
    end = time.time() + 10
    while "before-21" not in api("GET", "/v1/tasks/%s/capture?lines=40" % endpoint):
        if time.time() > end:
            fail("the endpoint never rendered its pre-attach output")
        time.sleep(0.1)

    attach_env = dict(os.environ, FM_HOME=LAB + "/home", FM_STREAM_HUB=URL,
                      FM_STREAM_TOKEN=TOKEN, FM_STREAM_NATIVE_DIR=NATIVE, TERM="xterm-256color",
                      FM_STREAM_LOCAL_DIR=LOCAL)
    def start_attach(hub=URL, local=True):
        global pid, master, seen
        seen = b""
        pid, master = pty.fork()
        if pid == 0:
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
            env = dict(attach_env, FM_STREAM_HUB=hub, FM_STREAM_ATTACH_LOCAL="1" if local else "0")
            os.execve(ROOT + "/bin/fm-stream.sh",
                      [ROOT + "/bin/fm-stream.sh", "attach", "--interactive", endpoint], env)

    socket_path = os.path.join(LOCAL, endpoint + ".sock")
    if not os.path.exists(socket_path):
        fail("the agent did not offer its same-machine socket")
    if stat.S_IMODE(os.stat(socket_path).st_mode) != 0o600 or stat.S_IMODE(os.stat(LOCAL).st_mode) != 0o700:
        fail("the same-machine socket is not private")

    # The hub path first, forced: everything below must hold without the socket.
    start_attach(local=False)

    def read_until(needle, secs=15):
        global seen
        end = time.time() + secs
        while time.time() < end:
            ready, _, _ = select.select([master], [], [], 0.1)
            if ready:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                seen += chunk
            if needle in seen:
                return True
        return needle in seen

    if not read_until(b"before-21"):
        fail("attach did not paint the existing screen: %r" % seen[-400:])
    task = json.loads(api("GET", "/v1/tasks/" + endpoint))["task"]
    if (task["rows"], task["cols"]) != (24, 80):
        fail("the initial snapshot was painted before resizing")
    os.write(master, b"echo typed-$((40+2))\r")
    if not read_until(b"typed-42"):
        fail("a keystroke did not reach the child: %r" % seen[-400:])
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
    time.sleep(1.0)
    os.write(master, b"stty size\r")
    if not read_until(b"30 100"):
        fail("the local resize did not reach the child's pty: %r" % seen[-400:])
    os.write(master, b"printf '\\033[?25l\\033[?1049h\\033[?2004h\\033[?1000h'; echo modes-$((1+1))\r")
    if not read_until(b"modes-2"):
        fail("endpoint display modes did not reach the client")
    os.write(master, b"echo drained-$((5+1))\r\x1d")
    if not read_until(b"detached from"):
        fail("the detach key did not detach: %r" % seen[-400:])
    _, status = os.waitpid(pid, 0)
    if os.WEXITSTATUS(status) != 0:
        fail("attach exited %d after a detach" % os.WEXITSTATUS(status))

    reset = b"\x1b[?1049l\x1b[?1047l\x1b[?47l\x1b[?25h\x1b[?2004l"
    if reset not in seen or seen.index(reset) > seen.index(b"detached from"):
        fail("local display modes were not restored before the detach message")
    os.close(master)
    end = time.time() + 10
    while "drained-6" not in api("GET", "/v1/tasks/%s/capture?lines=40" % endpoint):
        if time.time() > end:
            fail("detach abandoned preceding input")
        time.sleep(0.05)
    task = json.loads(api("GET", "/v1/tasks/" + endpoint))["task"]
    if task.get("closed_at") is not None:
        fail("detaching closed the endpoint")
    if procs[1].poll() is not None:
        fail("detaching ended the agent")
    api("POST", "/v1/tasks/%s/input" % endpoint, {"text": "echo after-$((1+1))", "submit": True})
    end = time.time() + 10
    while "after-2" not in api("GET", "/v1/tasks/%s/capture?lines=40" % endpoint):
        if time.time() > end:
            fail("the endpoint stopped taking input after the detach")
        time.sleep(0.1)
    if json.loads(api("GET", "/v1/tasks/" + endpoint))["task"]["rows"] != 30:
        fail("the hub's screen did not follow the resize")

    # Same machine: the socket alone carries the session, so a dead hub
    # address changes nothing - paint, keys, resize, drained detach.
    start_attach("http://127.0.0.1:9")
    if not read_until(b"after-2"):
        fail("local attach did not paint the existing screen: %r" % seen[-400:])
    os.write(master, b"echo local-$((3+4))\r")
    if not read_until(b"local-7"):
        fail("a keystroke did not reach the child locally: %r" % seen[-400:])
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 31, 101, 0, 0))
    time.sleep(0.5)
    os.write(master, b"stty size\r")
    if not read_until(b"31 101"):
        fail("the local resize did not reach the child's pty: %r" % seen[-400:])
    os.write(master, b"echo local-drained-$((4+5))\r\x1d")
    if not read_until(b"detached from"):
        fail("the detach key did not detach locally: %r" % seen[-400:])
    _, status = os.waitpid(pid, 0)
    if os.WEXITSTATUS(status) != 0 or reset not in seen:
        fail("local detach returned %d or left display modes set" % os.WEXITSTATUS(status))
    os.close(master)
    end = time.time() + 10
    while "local-drained-9" not in api("GET", "/v1/tasks/%s/capture?lines=40" % endpoint):
        if time.time() > end:
            fail("local detach abandoned preceding input, or its output never reached the hub")
        time.sleep(0.05)
    end = time.time() + 5
    while json.loads(api("GET", "/v1/tasks/" + endpoint))["task"]["rows"] != 31:
        if time.time() > end:
            fail("the hub's screen did not follow the local resize")
        time.sleep(0.05)

    start_attach()
    if not read_until(b"local-drained-9"):
        fail("reattach failed")
    os.write(master, b"exit 7\r")
    if not read_until(b"endpoint closed, exit 7"):
        fail("endpoint exit was not reported: %r" % seen[-400:])
    _, status = os.waitpid(pid, 0)
    if os.WEXITSTATUS(status) != 7 or reset not in seen:
        fail("endpoint status or display cleanup was lost")
    os.close(master)
    end = time.time() + 10
    while os.path.exists(socket_path):
        if time.time() > end:
            fail("the closed endpoint left its socket behind")
        time.sleep(0.05)

    procs.append(subprocess.Popen(
        [sys.executable, ROOT + "/bin/fm-stream-agent.py", "serve", "--hub", URL,
         "--token-file", token_file, "--machine", "mixed-test", "--label", "mixed",
         "--cwd", LAB + "/cwd", "--ready-file", LAB + "/mixed.ready", "--poll-secs", "1"],
        env=agent_env, stdout=subprocess.DEVNULL, stderr=open(LAB + "/mixed.log", "w")))
    _, mixed_endpoint = wait_file(LAB + "/mixed.ready")
    native_endpoint, endpoint = endpoint, mixed_endpoint
    api("POST", "/v1/tasks/%s/input" % endpoint, {"text": "echo mixed-$((1+1))", "submit": True})
    end = time.time() + 10
    while "mixed-2" not in api("GET", "/v1/tasks/%s/capture" % endpoint):
        if time.time() > end:
            fail("Python endpoint did not produce pre-attach output")
        time.sleep(0.1)
    start_attach()
    if not read_until(b"mixed-2"):
        fail("native hub/Python endpoint attach failed: %r" % seen)
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
    os.write(master, b"echo mixed-typed-$((2+1))\r")
    if not read_until(b"mixed-typed-3"):
        fail("mixed deployment did not stay interactive")
    os.write(master, b"\x1d")
    if not read_until(b"detached from"):
        fail("mixed deployment did not detach")
    _, status = os.waitpid(pid, 0)
    if os.WEXITSTATUS(status) != 0:
        fail("unsupported mixed-deployment resize ended the session")
    os.close(master)
    endpoint = native_endpoint

    for args in [[endpoint, "--interactive"], [endpoint, "--replay", "--interactive"]]:
        result = subprocess.run([ROOT + "/bin/fm-stream.sh", "attach"] + args,
                                env=attach_env, capture_output=True, timeout=5)
        if result.returncode == 0 or b"unknown option for attach: --interactive" not in result.stderr:
            fail("trailing interactive syntax was not rejected")

    class RefusingHub(http.server.BaseHTTPRequestHandler):
        mode = 403
        received = []
        resize_mode = 200
        resize_received = []
        stream_mode = 200
        snapshot_requested = threading.Event()
        snapshot_release = None

        def log_message(self, *args):
            pass

        def reply(self, status, body):
            raw = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self):
            if "/stream" in self.path:
                if self.stream_mode == 409:
                    self.reply(409, {"error": "stream_continuity_error",
                                     "message": "stream continuity lost: offset outside retained range"})
                    return
                self.send_response(200)
                self.end_headers()
                if self.stream_mode == "overflow":
                    self.wfile.write(b'data: {"error":"stream_continuity_error","message":"stream continuity lost: ring overflow"}\n\n')
                    self.wfile.flush()
                    return
                self.wfile.write(b": ready\n\n")
                self.wfile.flush()
                time.sleep(5)
            elif self.path.endswith("/snapshot"):
                release = self.snapshot_release
                if release is not None:
                    self.snapshot_requested.set()
                    release.wait(10)
                self.reply(200, {"screen": "stub-ready", "stream_offset": 0})
            else:
                self.reply(200, {"task": {"closed_at": None}})

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if self.path.endswith("/resize"):
                self.resize_received.append(body)
                if self.resize_mode == "transport":
                    self.close_connection = True
                elif isinstance(self.resize_mode, tuple):
                    self.reply(*self.resize_mode)
                else:
                    self.reply(self.resize_mode, {"ok": self.resize_mode == 200})
                return
            self.received.append(body)
            if self.mode == "transport":
                self.close_connection = True
            elif self.mode == "stall":
                time.sleep(5)
            else:
                self.reply(self.mode, {"ok": self.mode == 200})

    stub = http.server.ThreadingHTTPServer(("127.0.0.1", 0), RefusingHub)
    threading.Thread(target=stub.serve_forever, daemon=True).start()
    try:
        for mode in [200, "stall"]:
            RefusingHub.mode = mode
            RefusingHub.received = []
            RefusingHub.resize_received = []
            RefusingHub.snapshot_requested.clear()
            RefusingHub.snapshot_release = threading.Event()
            start_attach("http://127.0.0.1:%d" % stub.server_port)
            if not RefusingHub.snapshot_requested.wait(4):
                fail("attach did not reach the delayed startup snapshot")
            saved_mode = termios.tcgetattr(master)
            if RefusingHub.resize_received != [{"rows": 24, "cols": 80}]:
                fail("attach did not sample the initial terminal geometry")
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 33, 103, 0, 0))
            RefusingHub.snapshot_release.set()
            if not read_until(b"stub-ready"):
                fail("delayed startup attach did not paint")
            end = time.monotonic() + 2
            while len(RefusingHub.resize_received) < 2:
                if time.monotonic() > end:
                    fail("resize during startup was lost")
                time.sleep(0.05)
            if RefusingHub.resize_received[-1] != {"rows": 33, "cols": 103}:
                fail("startup resize forwarded stale geometry")
            if termios.tcgetattr(master)[3] & (termios.ICANON | termios.ECHO | termios.ISIG):
                fail("attach did not enter raw mode")
            keys = b"\x03" if mode == 200 else b"x"
            os.write(master, keys)
            end = time.monotonic() + 2
            while not RefusingHub.received:
                if time.monotonic() > end:
                    fail("input did not reach the hub before interrupt")
                time.sleep(0.05)
            if RefusingHub.received != [{"text": keys.decode()}]:
                fail("typed Ctrl-C was not forwarded as ordinary input")
            started = time.monotonic()
            os.kill(pid, signal.SIGINT)
            message = b"detached from" if mode == 200 else b"detach drain timed out"
            if not read_until(message, 4):
                fail("external SIGINT bypassed cleanup: %r" % seen)
            _, status = os.waitpid(pid, 0)
            if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != (0 if mode == 200 else 1):
                fail("external SIGINT returned the wrong status")
            if mode == "stall" and time.monotonic() - started > 3:
                fail("SIGINT drain exceeded its bound")
            if reset not in seen or seen.index(reset) > seen.index(message):
                fail("SIGINT did not restore display modes before the final message")
            if termios.tcgetattr(master) != saved_mode:
                fail("SIGINT did not restore the saved terminal mode")
            os.close(master)
        RefusingHub.snapshot_release = None

        for mode, keys, message in [
            (403, b"x", b"input delivery failed: HTTP 403"),
            (504, b"x", b"input delivery failed: HTTP 504"),
            ("transport", b"x", b"input delivery uncertain:"),
            ("stall", b"x\x1d", b"detach drain timed out"),
            (200, b"\xc3\x1d", b"detached from"),
        ]:
            RefusingHub.mode = mode
            RefusingHub.received = []
            start_attach("http://127.0.0.1:%d" % stub.server_port)
            if not read_until(b"stub-ready"):
                fail("stub attach did not start")
            started = time.monotonic()
            os.write(master, keys)
            if not read_until(message, 4):
                fail("input failure/drain was not reported: %r" % seen)
            _, status = os.waitpid(pid, 0)
            if os.WEXITSTATUS(status) != (0 if mode == 200 else 1):
                fail("input delivery outcome returned the wrong status")
            if mode == "stall" and time.monotonic() - started > 3:
                fail("detach drain exceeded its bound")
            if len(RefusingHub.received) != 1:
                fail("input was retried or abandoned")
            if mode == 200 and base64.b64decode(RefusingHub.received[0]["b64"]) != b"\xc3":
                fail("detach did not flush pending partial bytes")
            if reset not in seen:
                fail("input failure did not restore display modes")
            os.close(master)

        unknown_kind = (502, {"error": "agent_refused", "message": "unknown command kind 'resize'"})
        for initial in [True, False]:
            for mode, message in [
                (404, None),
                (unknown_kind, None),
                (403, b"resize delivery failed: HTTP 403"),
                (504, b"resize delivery failed: HTTP 504"),
                ((502, {"error": "agent_refused", "message": "cannot resize PTY"}),
                 b"resize delivery failed: HTTP 502"),
                ((502, {"error": "proxy_error", "message": "unknown command kind"}),
                 b"resize delivery failed: HTTP 502"),
                ("transport", b"resize delivery uncertain:"),
            ]:
                RefusingHub.resize_mode = mode if initial else 200
                RefusingHub.resize_received = []
                start_attach("http://127.0.0.1:%d" % stub.server_port)
                if not initial:
                    if not read_until(b"stub-ready"):
                        fail("resize test attach did not start")
                    RefusingHub.resize_mode = mode
                    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
                if message is None:
                    if not read_until(b"stub-ready"):
                        fail("unsupported resize ended attach: %r" % seen)
                    end = time.monotonic() + 2
                    expected = 1 if initial else 2
                    while len(RefusingHub.resize_received) < expected:
                        if time.monotonic() > end:
                            fail("resize was not attempted")
                        time.sleep(0.05)
                    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 102, 0, 0))
                    time.sleep(0.25)
                    os.write(master, b"\x1d")
                    message = b"detached from"
                    expected_status = 0
                else:
                    expected_status = 1
                if not read_until(message, 4):
                    fail("resize outcome was not reported: %r" % seen)
                _, status = os.waitpid(pid, 0)
                if os.WEXITSTATUS(status) != expected_status:
                    fail("resize outcome returned the wrong status")
                if len(RefusingHub.resize_received) != (1 if initial else 2):
                    fail("failed or unsupported resize was retried")
                if not initial and reset not in seen:
                    fail("resize failure did not restore display modes")
                os.close(master)

        RefusingHub.resize_mode = 200
        for mode in [409, "overflow"]:
            RefusingHub.stream_mode = mode
            start_attach("http://127.0.0.1:%d" % stub.server_port)
            if not read_until(b"stream continuity lost", 4):
                fail("stream discontinuity was not reported: %r" % seen)
            _, status = os.waitpid(pid, 0)
            if os.WEXITSTATUS(status) != 1:
                fail("stream discontinuity returned success")
            if mode == "overflow" and reset not in seen:
                fail("stream overflow did not restore display modes")
            os.close(master)
    finally:
        stub.shutdown()
        stub.server_close()

    procs.append(subprocess.Popen(
        [sys.executable, ROOT + "/bin/fm-stream-hub.py", "serve", "--port", "0",
         "--ready-file", LAB + "/python.ready"], env=env,
        stdout=subprocess.DEVNULL, stderr=open(LAB + "/python.log", "w")))
    host, port = wait_file(LAB + "/python.ready")
    URL = "http://%s:%s" % (host, port)
    rollback_id = "c" * 32
    api("POST", "/v1/agent/endpoints", {"protocol": 3, "machine": "rollback",
        "endpoint_id": rollback_id, "label": "rollback", "rows": 2, "cols": 4})
    answer = json.loads(api("POST", "/v1/agent/frames", {"machine": "rollback", "frames": [
        {"endpoint_id": rollback_id, "geometry": {"rows": 2, "cols": 8}},
        {"endpoint_id": rollback_id, "b64": base64.b64encode(b"abcd").decode()},
    ]}))
    if answer["accepted"] != 2:
        fail("Python rollback hub did not ignore the unknown geometry field")
    task = json.loads(api("GET", "/v1/tasks/" + rollback_id))["task"]
    if (task["rows"], task["cols"]) != (2, 4):
        fail("Python rollback hub unexpectedly applied geometry")
    if "abcd" not in api("GET", "/v1/tasks/%s/capture" % rollback_id):
        fail("Python rollback hub stopped processing output after geometry")
    print("ok")
finally:
    cleanup()
