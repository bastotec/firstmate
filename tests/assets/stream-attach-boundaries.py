#!/usr/bin/env python3
"""Public socket/HTTP/PTY regressions for attach geometry, resize and input."""
import concurrent.futures
import fcntl
import http.server
import json
import os
from pathlib import Path
import pty
import select
import shlex
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import termios
import threading
import time
import urllib.error
import urllib.request

ROOT, NATIVE, LAB = map(Path, sys.argv[1:4])
LOCAL = tempfile.mkdtemp(prefix="attach-boundary-", dir="/tmp")
TOKEN = "isolated-boundary-token"
children = []


def wait(check, message, seconds=15):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        value = check()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError(message)


def spawn(args, env=None):
    log = open(LAB / ("log-%d" % len(children)), "wb")
    proc = subprocess.Popen(list(map(str, args)), env=env, stdout=log, stderr=log)
    log.close()
    children.append(proc)
    return proc


def request(url, path, body=None, capability=""):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(url + path, data=data,
        headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json",
                 "X-Endpoint-Capability": capability})
    try:
        response = urllib.request.urlopen(req, timeout=20)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, response.read()


def frame(peer, tag, body):
    if not isinstance(body, bytes):
        body = json.dumps(body).encode()
    peer.sendall(tag + struct.pack("!I", len(body)) + body)


def receive(peer):
    def exact(n):
        result = b""
        while len(result) < n:
            part = peer.recv(n - len(result))
            assert part, "unexpected socket EOF"
            result += part
        return result
    head = exact(5)
    return head[:1], exact(struct.unpack("!I", head[1:])[0])


class Proxy(http.server.BaseHTTPRequestHandler):
    fail_geometry = False
    failed = threading.Event()
    stall = False
    stalled = threading.Event()
    release = threading.Event()
    delivery_log = []
    delivery_lock = threading.Lock()
    request_log = []
    registered = threading.Event()

    def log_message(self, *args):
        pass

    def relay(self):
        body = None
        if self.command == "POST":
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        output = self.path == "/v1/agent/frames" and any("b64" in f for f in body["frames"])
        geometry = self.path == "/v1/agent/frames" and any(
            f.get("geometry", {}).get("rows") == 37 for f in body["frames"])
        if Proxy.fail_geometry and geometry:
            Proxy.fail_geometry = False
            Proxy.failed.set()
            status, raw = 503, b'{}'
        else:
            if Proxy.stall and output:
                Proxy.stalled.set()
                Proxy.release.wait(20)
            status, raw = request(HUB, self.path, body, self.headers.get("X-Endpoint-Capability", ""))
        Proxy.request_log.append("%s %s upstream=%s" % (self.command, self.path, status))
        if self.path == "/v1/agent/endpoints" and status == 201:
            Proxy.registered.set()
        with Proxy.delivery_lock:
            if status == 200 and self.path.startswith("/v1/agent/commands?"):
                for command in json.loads(raw).get("commands", []):
                    if command.get("kind") == "input":
                        Proxy.delivery_log.append({"taken": command["command_id"],
                            "bytes": len(command["payload"].get("text", "").encode())})
            elif self.path == "/v1/agent/results":
                Proxy.delivery_log.append({"result": body, "status": status})
        self.send_response(status)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    do_GET = relay
    do_POST = relay


try:
    LAB.mkdir(parents=True, exist_ok=True)
    (LAB / "token").write_text(TOKEN)
    env = dict(os.environ, FM_STREAM_TOKEN=TOKEN, FM_STREAM_LOCAL_DIR=LOCAL, SHELL="/bin/bash")
    hub = spawn([NATIVE / "fm-stream-hub", "serve", "--bind", "127.0.0.1", "--port", "0",
                 "--ready-file", LAB / "hub.ready"], env)
    wait(lambda: (LAB / "hub.ready").exists(), "hub readiness")
    host, port = (LAB / "hub.ready").read_text().split()
    HUB = "http://%s:%s" % (host, port)
    proxy = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Proxy)
    threading.Thread(target=proxy.serve_forever, daemon=True).start()
    URL = "http://127.0.0.1:%d" % proxy.server_port
    agent = spawn([NATIVE / "fm-stream-agent", "serve", "--hub", URL,
                   "--token-file", LAB / "token", "--machine", "boundaries", "--label", "boundaries",
                   "--cwd", LAB, "--ready-file", LAB / "agent.ready", "--poll-secs", "1"], env)
    assert Proxy.registered.wait(15), "registration did not answer 201"
    wait(lambda: (LAB / "agent.ready").exists(), "agent readiness")
    endpoint = (LAB / "agent.ready").read_text().split()[1]

    def connect(rows=None):
        peer = socket.socket(socket.AF_UNIX)
        peer.settimeout(5)
        peer.connect(LOCAL + "/" + endpoint + ".sock")
        hello = {"endpoint": endpoint}
        if rows is not None:
            hello.update(rows=rows, cols=80)
        frame(peer, b'H', hello)
        tag, raw = receive(peer)
        assert tag == b'S', (tag, raw)
        return peer, json.loads(raw)

    peer, _ = connect()
    Proxy.fail_geometry = True
    frame(peer, b'Z', {"rows": 37, "cols": 80})
    frame(peer, b'I', b"printf '\\033[37;1Hlost-geometry'\r")
    assert Proxy.failed.wait(10), "geometry failure was not injected"
    frame(peer, b'I', b"printf '\\033[37;1Hrecovered-size'\r")
    def recovered():
        code, raw = request(HUB, "/v1/tasks/%s/snapshot" % endpoint)
        value = json.loads(raw)
        return code == 200 and value.get("rows") == 37 and "recovered-size" in value.get("screen", "")
    wait(recovered, "subsequent output was parsed at the lost geometry")
    peer.close()
    print("ok: attach geometry survives publication failure")

    # The default case proves network-independent resizing with small writes.
    # Filling the 1 MiB hub queue is deliberately opt-in, not a throughput test.
    long_timeout = os.environ.get("FM_STREAM_ATTACH_LONG_TIMEOUT") == "1"
    flood_writes = 288 if long_timeout else 4
    peer, _ = connect()
    Proxy.stall = True
    command = ("python3 -c 'import os; [os.write(1,b\"x\\n\"*2048) "
               "for _ in range(%d)]'; touch flood-finished\r" % flood_writes)
    frame(peer, b'I', command.encode())
    assert Proxy.stalled.wait(10), "output POST was not stalled"
    time.sleep(1)
    started = time.monotonic()
    resized, snapshot = connect(38)
    assert time.monotonic() - started < 4, "local resize waited for the hub"
    assert len(snapshot["screen"].split("\n")) == 38, snapshot
    resized.close()
    Proxy.stall = False
    Proxy.release.set()
    peer.close()
    wait(lambda: (LAB / "flood-finished").exists(), "output flood completion", 120 if long_timeout else 5)
    print("ok: local resize does not wait for network progress")

    # A raw child deliberately leaves both large input writes backpressured,
    # then records their byte order. Exercise local input and hub input together.
    script = LAB / "read-input.py"
    script.write_text("import os,time,tty\nfrom pathlib import Path\ntty.setraw(0)\n"
        "Path('input-ready').touch()\ntime.sleep(2)\ndata=b''\n"
        "while len(data)<65536:\n data+=os.read(0,4096)\n Path('input-progress').write_text(str(len(data)))\n"
        "Path('input-result').write_bytes(data)\n")
    peer, _ = connect()
    frame(peer, b'I', ("python3 %s\r" % shlex.quote(str(script))).encode())
    wait(lambda: (LAB / "input-ready").exists(), "raw input child readiness")
    with concurrent.futures.ThreadPoolExecutor() as pool:
        local = pool.submit(frame, peer, b'I', b'A' * 32768)
        remote = pool.submit(request, HUB, "/v1/tasks/%s/input" % endpoint, {"text": "B" * 32768})
        local.result(timeout=20)
        result = remote.result(timeout=25)
        assert result[0] == 200, result
    wait(lambda: (LAB / "input-result").exists(), "raw child input result")
    data = (LAB / "input-result").read_bytes()
    assert data in (b'A' * 32768 + b'B' * 32768, b'B' * 32768 + b'A' * 32768), "PTY writers interleaved"
    taken = [record["taken"] for record in Proxy.delivery_log if record.get("bytes") == 32768]
    assert len(taken) == 1, Proxy.delivery_log
    wait(lambda: any(record.get("result", {}).get("command_id") == taken[0]
                     and record["result"].get("ok") is True and record["status"] == 200
                     for record in Proxy.delivery_log), "hub input completion record")
    peer.close()
    print("ok: local and hub PTY writes are serialized")

    # A public local-socket fixture accepts the hello and never reads input.
    # The real attach executable must still consume Ctrl-] behind a full socket.
    fake_id = "d" * 32
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(LOCAL + "/" + fake_id + ".sock")
    os.chmod(LOCAL + "/" + fake_id + ".sock", 0o600)
    listener.listen()
    accepted = threading.Event()
    release = threading.Event()
    def stalled_peer():
        conn, _ = listener.accept()
        conn.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        assert receive(conn)[0] == b'H'
        frame(conn, b'S', {"screen": "backpressure-ready", "rows": 24, "cols": 80})
        accepted.set()
        release.wait(15)
        conn.close()
    threading.Thread(target=stalled_peer, daemon=True).start()
    pid, master = pty.fork()
    if pid == 0:
        os.execve(str(NATIVE / "fm-stream-agent"), [str(NATIVE / "fm-stream-agent"), "attach",
            "--hub", HUB, "--endpoint", fake_id], env)
    try:
        assert accepted.wait(5), "attach fixture handshake"
        seen = b""
        def read_message():
            global seen
            if select.select([master], [], [], 0.05)[0]:
                try:
                    seen += os.read(master, 65536)
                except OSError:
                    pass
            return b"backpressure-ready" in seen
        wait(read_message, "attach paint")
        os.set_blocking(master, False)
        payload = b'x' * 262144 + b'\x1d'
        until = time.monotonic() + 8
        while payload and time.monotonic() < until:
            if select.select([], [master], [], 0.05)[1]:
                try:
                    payload = payload[os.write(master, payload[:4096]):]
                except BlockingIOError:
                    pass
        assert not payload, "input reader stopped consuming before the detach key"
        started = time.monotonic()
        def ended():
            read_message()
            return os.waitpid(pid, os.WNOHANG)[1]
        status = wait(ended, "Ctrl-] did not exit under backpressure", 4)
        assert os.WIFEXITED(status) and os.WEXITSTATUS(status) == 1
        assert b"detach drain timed out" in seen, seen[-400:]
        assert time.monotonic() - started < 4
        print("ok: detach backpressure is bounded")
    finally:
        release.set()
        listener.close()
        os.close(master)
        try:
            os.kill(pid, signal.SIGTERM)
            os.waitpid(pid, 0)
        except ProcessLookupError:
            pass
        except ChildProcessError:
            pass
finally:
    if sys.exc_info()[0] is not None:
        print("proxy requests:\n" + "\n".join(Proxy.request_log), file=sys.stderr)
        if "HUB" in globals():
            status, raw = request(HUB, "/v1/health")
            print("hub registration count: %s" % json.loads(raw).get("endpoints"), file=sys.stderr)
        for log in sorted(LAB.glob("log-*")):
            print("%s: %s" % (log.name, log.read_text(errors="replace")[-2000:]), file=sys.stderr)
    if (LAB / "input-progress").exists() and not (LAB / "input-result").exists():
        print("raw child input progress: " + (LAB / "input-progress").read_text(), file=sys.stderr)
    Proxy.release.set()
    for proc in reversed(children):
        proc.terminate()
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
    shutil.rmtree(LOCAL, ignore_errors=True)
