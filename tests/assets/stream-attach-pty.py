#!/usr/bin/env python3
"""Drive `fm-stream.sh attach --interactive` from a real pseudoterminal.

Usage: stream-attach-pty.py ROOT NATIVE_DIR LAB

Starts a disposable native hub (loopback, ephemeral port, private token) and a
native agent running bash, then attaches through firstmate's own entry point
and proves: the existing screen is painted on connect, keystrokes reach the
child, a local resize reaches the child's PTY (`stty size`), and the detach key
leaves the endpoint running. Exits non-zero with a reason on the first failure.
"""
import base64
import fcntl
import http.server
import json
import os
import pty
import secrets
import select
import struct
import subprocess
import sys
import termios
import time
import threading
import urllib.request

ROOT, NATIVE, LAB = sys.argv[1:4]
TOKEN = secrets.token_hex(16)
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


os.makedirs(LAB + "/home/config", exist_ok=True)
os.makedirs(LAB + "/home/state", exist_ok=True)
os.makedirs(LAB + "/cwd", exist_ok=True)
token_file = LAB + "/token"
with open(token_file, "w") as handle:
    handle.write(TOKEN + "\n")
os.chmod(token_file, 0o600)
env = dict(os.environ, FM_STREAM_TOKEN=TOKEN)
try:
    procs.append(subprocess.Popen(
        [NATIVE + "/fm-stream-hub", "serve", "--bind", "127.0.0.1", "--port", "0",
         "--ready-file", LAB + "/hub.ready", "--pid-file", LAB + "/hub.pid"],
        env=env, stdout=subprocess.DEVNULL, stderr=open(LAB + "/hub.log", "w")))
    host, port = wait_file(LAB + "/hub.ready")
    URL = "http://%s:%s" % (host, port)
    agent_env = dict(os.environ, SHELL="/bin/bash", TERM="xterm-256color")
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
                      FM_STREAM_TOKEN=TOKEN, FM_STREAM_NATIVE_DIR=NATIVE, TERM="xterm-256color")
    def start_attach(hub=URL):
        global pid, master, seen
        seen = b""
        pid, master = pty.fork()
        if pid == 0:
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
            env = dict(attach_env, FM_STREAM_HUB=hub)
            os.execve(ROOT + "/bin/fm-stream.sh",
                      [ROOT + "/bin/fm-stream.sh", "attach", "--interactive", endpoint], env)

    start_attach()

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
    start_attach()
    if not read_until(b"after-2"):
        fail("reattach failed")
    os.write(master, b"exit 7\r")
    if not read_until(b"endpoint closed, exit 7"):
        fail("endpoint exit was not reported: %r" % seen[-400:])
    _, status = os.waitpid(pid, 0)
    if os.WEXITSTATUS(status) != 7 or reset not in seen:
        fail("endpoint status or display cleanup was lost")
    os.close(master)

    class RefusingHub(http.server.BaseHTTPRequestHandler):
        mode = 403
        received = []

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
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b": ready\n\n")
                self.wfile.flush()
                time.sleep(5)
            elif self.path.endswith("/snapshot"):
                self.reply(200, {"screen": "stub-ready", "stream_offset": 0})
            else:
                self.reply(200, {"task": {"closed_at": None}})

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if self.path.endswith("/resize"):
                self.reply(200, {"ok": True})
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
