#!/usr/bin/env python3
"""Observe both executable agents against isolated Python hubs.

No source matching or fleet endpoints: real PTYs, real HTTP, and explicit
agent-reported close/ack records are the only positive verdicts.
"""
import base64
import http.server
import json
import os
from pathlib import Path
import signal
import shlex
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

ROOT, LAB = map(Path, sys.argv[1:3])
PUB, CTL = "pilot-publish-private", "pilot-control-private"
ENV = dict(os.environ, SHELL="/bin/bash")
for key in ("FM_HOME", "FM_STREAM_HUB", "FM_STREAM_TOKEN", "FM_STREAM_ENDPOINT_ID"):
    ENV.pop(key, None)
AGENTS = ([sys.executable, str(ROOT / "bin/fm-stream-agent.py")],
          [str(ROOT / "target/debug/fm-stream-agent")])


def wait(check, description, tries=200):
    for _ in range(tries):
        result = check()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError(description)


def call(url, method, path, payload=None, token=CTL, capability=""):
    data = None if payload is None else json.dumps(payload).encode()
    headers = {"Authorization": "Bearer " + token, "X-Endpoint-Capability": capability}
    if data is not None:
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url + path, data=data, headers=headers, method=method)
    try:
        response = urllib.request.urlopen(request, timeout=15)
    except urllib.error.HTTPError as exc:
        response = exc
    with response:
        body = response.read().decode()
        try:
            body = json.loads(body)
        except json.JSONDecodeError:
            pass
        return response.code, body


class Rig:
    def __init__(self, name):
        self.dir = LAB / name
        self.dir.mkdir()
        (self.dir / "tokens").write_text(f"publish:{PUB}\nsubscribe,control:{CTL}\n")
        (self.dir / "token").write_text(PUB + "\n")
        self.children = []
        self.workers = []
        self.hub = None
        self.url = ""
        try:
            self.start_hub()
        except BaseException:
            self.close()
            raise

    def spawn(self, args, **kwargs):
        log = open(self.dir / f"process-{len(self.children)}.log", "wb")
        proc = subprocess.Popen(args, env=ENV, stdout=log, stderr=log, **kwargs)
        log.close()
        self.children.append(proc)
        return proc

    def start_hub(self, port=0):
        ready = self.dir / "hub-ready"
        ready.unlink(missing_ok=True)
        self.hub = self.spawn([sys.executable, str(ROOT / "bin/fm-stream-hub.py"),
                               "serve", "--bind", "127.0.0.1", "--port", str(port),
                               "--token-file", str(self.dir / "tokens"),
                               "--ready-file", str(ready), "--state-max-age-secs", "3",
                               "--command-ack-secs", "4"])
        wait(lambda: ready.exists() and ready.read_text().strip(), "hub readiness")
        host, port = ready.read_text().split()
        self.url = f"http://{host}:{port}"

    def restart(self):
        port = int(self.url.rsplit(":", 1)[1])
        self.hub.terminate()
        self.hub.wait(timeout=10)
        self.start_hub(port)

    def agent(self, executable, label="worker", url=None, extra=()):
        ready = self.dir / f"ready-{label}"
        status = self.dir / f"status-{label}"
        proc = self.spawn(executable + ["serve", "--hub", url or self.url,
                                       "--token-file", str(self.dir / "token"),
                                       "--machine", "pilot", "--label", label,
                                       "--cwd", str(self.dir), "--ready-file", str(ready),
                                       "--status-path", str(status), "--poll-secs", "1",
                                       "--state-interval", "0.5"] + list(extra))
        wait(lambda: ready.exists() and ready.read_text().strip(), "agent readiness")
        machine, endpoint = ready.read_text().split()
        assert machine == "pilot" and len(endpoint) == 32
        return proc, endpoint, status

    def task(self, endpoint):
        code, body = call(self.url, "GET", f"/v1/tasks/{endpoint}")
        return body.get("task", {}) if code == 200 else {}

    def input(self, endpoint, text=None, keys=None, submit=True):
        payload = {"submit": submit}
        if text is not None:
            payload["text"] = text
        if keys is not None:
            payload["keys"] = keys
        code, body = call(self.url, "POST", f"/v1/tasks/{endpoint}/input", payload)
        assert code == 200 and body["delivered"] == endpoint, (code, body)

    def capture(self, endpoint):
        code, body = call(self.url, "GET", f"/v1/tasks/{endpoint}/capture?lines=100")
        return body if code == 200 else ""

    def marker(self, endpoint, marker):
        self.input(endpoint, "printf '%s\\n' '" + marker + "'")
        wait(lambda: ("\n" + marker + "\n") in self.capture(endpoint), "real child output " + marker)

    def remember_worker(self, endpoint):
        # This PID comes from the endpoint's own foreground identity, not a
        # namespace sweep. Save it for leak checking, never use it for cleanup.
        code, body = call(self.url, "GET", f"/v1/tasks/{endpoint}/processes")
        assert code == 200, body
        records = body["foreground"]
        assert records, body
        self.workers.extend(int(p["pid"]) for p in records)
        return records

    def close(self):
        # Tell every owned publisher to close its own PTY BEFORE stopping hubs.
        for proc in reversed(self.children):
            if proc is not self.hub and proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait(timeout=5)
        if self.hub and self.hub.poll() is None:
            self.hub.terminate()
            self.hub.wait(timeout=10)
        for pid in self.workers:
            assert not alive(pid), f"leaked PTY child {pid}"


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def lifecycle(executable, name):
    rig = Rig(name)
    try:
        proc, endpoint, status = rig.agent(executable)
        foreground = rig.remember_worker(endpoint)
        assert all(p["pid"] and p["argv0"] and p["args"] for p in foreground)
        rig.marker(endpoint, "REAL-PTY-UTF8-é-中")
        rig.input(endpoint, "printf 'RAW\\000\\377END\\n'")
        rig.marker(endpoint, "RAW-BYTES-DRAINED")
        request = urllib.request.Request(rig.url + f"/v1/tasks/{endpoint}/stream?replay=1", headers={"Authorization": "Bearer " + CTL})
        with urllib.request.urlopen(request, timeout=5) as response:
            record = json.loads(response.readline().removeprefix(b"data: "))
        assert b"RAW\x00\xffEND\r\n" in base64.b64decode(record["b64"]), "PTY byte stream was recoded"
        rig.input(endpoint, "printf 'ENV:%s:%s:%s\\n' \"${FM_STREAM_TOKEN-unset}\" \"$FM_STREAM_ENDPOINT_ID\" \"$FM_STREAM_HUB\"")
        wait(lambda: f"ENV:unset:{endpoint}:" in rig.capture(endpoint), "child token hygiene")
        assert PUB not in rig.capture(endpoint)
        # Geometry and foreground cwd must describe this PTY, not publisher.
        rig.input(endpoint, "stty size; mkdir -p sub; cd sub")
        wait(lambda: "40 200" in rig.capture(endpoint), "PTY geometry")
        wait(lambda: call(rig.url, "GET", f"/v1/tasks/{endpoint}/cwd")[1].get("cwd") == str(rig.dir / "sub"), "foreground cwd")
        code, body = call(rig.url, "POST", f"/v1/tasks/{endpoint}/status", {"state": "working", "note": "one\n  local\t record"})
        assert code == 200, body
        assert status.read_text() == "working: one local record\n"
        code, body = call(rig.url, "POST", f"/v1/tasks/{endpoint}/status", {"state": "working", "note": 42})
        assert code == 200, body
        assert status.read_text() == "working: one local record\nworking: 42\n"
        # Keys preserve Ctrl-U and Enter semantics, including submit bytes.
        rig.input(endpoint, "THIS MUST BE ERASED", submit=False)
        rig.input(endpoint, keys=["C-u"], submit=False)
        rig.marker(endpoint, "AFTER-ERASE")
        # Foreground SIGINT goes to a real job, not the publisher/session.
        rig.input(endpoint, "sleep 60")
        wait(lambda: any(p["name"].endswith("sleep") for p in call(rig.url, "GET", f"/v1/tasks/{endpoint}/processes")[1].get("foreground", [])), "foreground sleep")
        rig.input(endpoint, keys=["C-c"], submit=False)
        rig.marker(endpoint, "AFTER-INTERRUPT")
        # Private capability must not be inferable from endpoint identity.
        path = f"/v1/agent/commands?machine=pilot&endpoint={endpoint}&wait=0"
        code, body = call(rig.url, "GET", path, token=PUB, capability="invalid-capability")
        assert code == 403 and body["error"] == "endpoint_unauthorized", (code, body)
        rig.restart()
        wait(lambda: rig.task(endpoint).get("state_age_secs") is not None, "same-id restart/rejoin", 300)
        assert proc.poll() is None
        rig.marker(endpoint, "AFTER-REJOIN")
        rig.input(endpoint, "exit 7")
        proc.wait(timeout=15)
        task = wait(lambda: rig.task(endpoint) if rig.task(endpoint).get("closed_by") == "agent" else None, "authoritative failed close")
        assert task["exit_code"] == 7 and task["endpoint_id"] == endpoint
        proc2, endpoint2, _ = rig.agent(executable, "clean")
        rig.remember_worker(endpoint2)
        rig.input(endpoint2, "exit 0")
        proc2.wait(timeout=15)
        task2 = wait(lambda: rig.task(endpoint2) if rig.task(endpoint2).get("closed_by") == "agent" else None, "clean close")
        assert task2["exit_code"] == 0
        proc3, endpoint3, _ = rig.agent(executable, "signal")
        rig.remember_worker(endpoint3)
        rig.input(endpoint3, "exec sleep 60")
        time.sleep(0.3)
        proc3.send_signal(signal.SIGTERM)
        proc3.wait(timeout=15)
        task3 = wait(lambda: rig.task(endpoint3) if rig.task(endpoint3).get("closed_by") == "agent" else None, "signal close")
        assert task3["exit_code"] == -signal.SIGTERM, task3
        return (status.read_text(), task["closed_by"], task["exit_code"], task2["exit_code"], task3["exit_code"])
    finally:
        rig.close()


def command_values(executable, name):
    rig = Rig(name)
    try:
        proc, endpoint, status = rig.agent(executable)
        rig.remember_worker(endpoint)
        values = [
            "ordinary 'quoted' UTF8-é-中 \\",
            9223372036854775809,
            18446744073709551615,
            18446744073709551617,
            -18446744073709551617,
            float("nan"),
            float("inf"),
            -float("inf"),
            [float("nan"), float("inf"), -float("inf")],
            {"NaN": "NaN Infinity -Infinity \\\"", "nested": [{"nan": float("nan"), "positive": float("inf"), "negative": -float("inf")}], "integers": [10**20, 10**21, 10**22, -(10**20)], "escaped": '\\"NaN\\" \\\\Infinity'},
            {"z": True, "attempt": [None, False, {"text": "it's a quote", "both": "'\"", "escapes": "\\\n\t\r\x00\x1b\u00a0\u200b\ue000\U000f0000", "utf8": "é-中-😀"}], "a": 9223372036854775809},
            [1.0, -0.0, 1e-5, 1e16, True, None, ["nested", {"unsigned": 18446744073709551615}]],
            False,
            0,
            [],
            {},
        ]
        expected = ""
        for value in values + [None, "one\n  local\t record", "python\x1c\x1d\x1e\x1f separators"]:
            code, body = call(rig.url, "POST", f"/v1/tasks/{endpoint}/status", {"state": "working", "note": value})
            assert code == 200, body
            delivered_value = json.loads(json.dumps(value, sort_keys=True))
            expected += "working: " + " ".join(str(delivered_value or "").split()) + "\n"
            assert status.read_text() == expected, (value, status.read_text(), expected)
        receiver_ready = rig.dir / "receiver-ready"
        received = rig.dir / "received-input"
        receiver = ("import base64,sys; from pathlib import Path; "
                    "Path(sys.argv[1]).touch(); "
                    "out=open(sys.argv[2],'ab',buffering=0); "
                    f"[(out.write(base64.b64encode(sys.stdin.buffer.readline().removesuffix(b'\\n'))+b'\\n')) for _ in range({len(values)})]")
        rig.input(endpoint, f"{shlex.quote(sys.executable)} -c {shlex.quote(receiver)} {shlex.quote(str(receiver_ready))} {shlex.quote(str(received))}")
        wait(receiver_ready.exists, "real PTY input receiver")
        typed = []
        for value in values:
            rig.input(endpoint, value)
            delivered_value = json.loads(json.dumps(value, sort_keys=True))
            typed.append(base64.b64encode(str(delivered_value).encode()))
            wait(lambda: received.exists() and len(received.read_bytes().splitlines()) == len(typed), "converted PTY bytes")
            assert received.read_bytes().splitlines() == typed, value
        rig.marker(endpoint, "CONVERSION-COMPLETE")
        proc.terminate()
        proc.wait(timeout=15)
        return expected, received.read_bytes()
    finally:
        rig.close()


def intervals(executable, name):
    outcomes = []
    for index, extra in enumerate((
            ("--state-interval", "90000"),
            ("--poll-secs", "90000"),
            ("--state-interval", "0"),
            ("--poll-secs", "0"))):
        rig = Rig(f"{name}-{index}")
        try:
            proc, endpoint, status = rig.agent(executable, extra=extra)
            rig.remember_worker(endpoint)
            code, body = call(rig.url, "POST", f"/v1/tasks/{endpoint}/status", {"state": "working", "note": "interval accepted"})
            assert code == 200, (extra, code, body)
            assert status.read_text() == "working: interval accepted\n"
            rig.marker(endpoint, "INTERVAL-PTY-ACTIVE")
            code, body = call(rig.url, "DELETE", f"/v1/tasks/{endpoint}")
            assert code == 200 and body["delivered"], (extra, code, body)
            proc.wait(timeout=15)
            task = rig.task(endpoint)
            assert task["closed_by"] == "agent", (extra, task)
            outcomes.append(status.read_text())
        finally:
            rig.close()
    return outcomes


def unsafe_intervals():
    rig = Rig("unsafe-intervals-rust")
    try:
        for option in ("--state-interval", "--poll-secs"):
            for index, value in enumerate(("-1", "NaN", "Infinity", "-Infinity", "1e300", "1e19")):
                ready = rig.dir / f"ready-{option}-{index}"
                completed = subprocess.run(AGENTS[1] + ["serve", "--hub", rig.url, "--token-file", str(rig.dir / "token"), "--label", "unsafe", "--cwd", str(rig.dir), "--ready-file", str(ready), option, value], env=ENV, capture_output=True, timeout=15)
                assert completed.returncode == 1 and not ready.exists(), (option, value, completed)
                assert PUB.encode() not in completed.stderr
                assert call(rig.url, "GET", "/v1/tasks")[1]["tasks"] == []
    finally:
        rig.close()
    print("ok: unsafe intervals refused before endpoint creation", flush=True)


def concurrent_status(executable, name):
    rig = Rig(name)
    try:
        proc, endpoint, status = rig.agent(executable)
        rig.remember_worker(endpoint)
        stop, count = rig.dir / "writer-stop", rig.dir / "writer-count"
        writer_code = (
            "import os,sys,time\nfrom pathlib import Path\n"
            "fd=os.open(sys.argv[1],os.O_WRONLY|os.O_CREAT|os.O_APPEND,0o600)\n"
            "i=0\n"
            "while not Path(sys.argv[2]).exists():\n"
            " os.write(fd,('done: direct-%d\\n'%i).encode()); i+=1\n"
            " if i%128==0: time.sleep(0.001)\n"
            "os.close(fd)\nPath(sys.argv[3]).write_text(str(i))\n"
        )
        writer = rig.spawn([sys.executable, "-c", writer_code, str(status), str(stop), str(count)])
        wait(lambda: status.exists() and status.stat().st_size > 0, "direct status writer")
        expected = [f"working: agent-{i}-" + "x" * 128 for i in range(80)]
        before = status.stat().st_size
        for line in expected:
            code, body = call(rig.url, "POST", f"/v1/tasks/{endpoint}/status", {"state": "working", "note": line.removeprefix("working: ")})
            assert code == 200, body
        assert writer.poll() is None and status.stat().st_size > before
        stop.touch()
        writer.wait(timeout=5)
        assert writer.returncode == 0
        raw = status.read_bytes()
        assert raw.endswith(b"\n")
        lines = raw.decode().splitlines()
        direct_count = int(count.read_text())
        assert direct_count >= 128
        assert [line for line in lines if line.startswith("working: ")] == expected
        assert [line for line in lines if line.startswith("done: ")] == [f"done: direct-{i}" for i in range(direct_count)]
        assert len(lines) == direct_count + len(expected), "interleaved status records"
        proc.terminate()
        proc.wait(timeout=15)
        return expected
    finally:
        rig.close()


def generation_refusal(executable, name):
    rig = Rig(name)
    try:
        proc, endpoint, status = rig.agent(executable)
        rig.remember_worker(endpoint)
        rig.marker(endpoint, "BEFORE-GENERATION-CHANGE")
        code, health = call(rig.url, "GET", "/v1/health")
        assert code == 200 and health["generation"]
        old_generation = health["generation"]
        rig.restart()
        wait(lambda: rig.task(endpoint).get("state_age_secs") is not None, "generation refusal same-id rejoin", 300)
        rig.marker(endpoint, "AFTER-GENERATION-CHANGE")
        code, health = call(rig.url, "GET", "/v1/health")
        assert code == 200 and health["generation"] != old_generation
        code, body = call(rig.url, "POST", f"/v1/tasks/{endpoint}/status", {"state": "working", "note": "generation baseline"})
        assert code == 200, body
        capture_before, status_before = rig.capture(endpoint), status.read_bytes()
        effect = rig.dir / "order-executed"
        order = {"leaf_worker_id": "pilot/worker", "execution_id": endpoint,
                 "order_id": "generation-refusal", "hub_generation": old_generation,
                 "text": f"printf 'ORDER-EXECUTED\\n'; touch {shlex.quote(str(effect))}; printf 'done: generation-order\\n' >> {shlex.quote(str(status))}",
                 "submit": True}
        code, body = call(rig.url, "POST", "/v1/orders", order)
        assert code == 409 and body["error"] == "hub_generation_changed", (code, body)
        time.sleep(0.3)
        assert proc.poll() is None and not effect.exists()
        assert rig.capture(endpoint) == capture_before and status.read_bytes() == status_before
        order["hub_generation"] = health["generation"]
        code, body = call(rig.url, "POST", "/v1/orders", order)
        assert code == 200, body
        rig.marker(endpoint, "CURRENT-GENERATION-ORDER-DRAINED")
        assert effect.exists() and "\nORDER-EXECUTED\n" in rig.capture(endpoint)
        assert status.read_bytes() == status_before + b"done: generation-order\n"
        private_endpoint = "e" * 32
        registration = {"endpoint_id": private_endpoint, "machine": "pilot", "label": "revocable", "cwd": str(rig.dir), "protocol": 3, "capabilities": ["idempotent_command_results"]}
        code, body = call(rig.url, "POST", "/v1/agent/endpoints", registration, token=PUB)
        assert code == 201, body
        capability = body["command_capability"]
        assert capability
        path = f"/v1/agent/commands?machine=pilot&endpoint={private_endpoint}&wait=0"
        code, body = call(rig.url, "GET", path, token=PUB, capability=capability)
        assert code == 200 and body["commands"] == [], body
        code, body = call(rig.url, "POST", "/v1/agent/frames", {"machine": "pilot", "frames": [{"endpoint_id": private_endpoint, "closed": True, "exit_code": 0}]}, token=PUB, capability=capability)
        assert code == 200, body
        code, body = call(rig.url, "GET", path, token=PUB, capability=capability)
        assert code == 403 and body["error"] == "endpoint_unauthorized", (code, body)
        proc.terminate()
        proc.wait(timeout=15)
        return status.read_bytes()
    finally:
        rig.close()


def lost_result(executable, name, kill=False):
    rig = Rig(name)
    try:
        ready, dropped = rig.dir / "proxy-ready", rig.dir / "dropped"
        proxy = rig.spawn([sys.executable, str(ROOT / "tests/assets/stream-drop-response-proxy.py"),
                           "--target", rig.url, "--drop-path", "/v1/agent/results",
                           "--drop-number", "1", "--dropped-file", str(dropped), "--ready-file", str(ready)])
        wait(lambda: ready.exists() and ready.read_text().strip(), "proxy readiness")
        host, port = ready.read_text().split()
        proc, endpoint, status = rig.agent(executable, url=f"http://{host}:{port}")
        rig.remember_worker(endpoint)
        if kill:
            code, body = call(rig.url, "DELETE", f"/v1/tasks/{endpoint}")
            assert code == 200 and body["delivered"], body
            wait(lambda: dropped.exists(), "kill result response dropped")
            proc.wait(timeout=15)
            task = rig.task(endpoint)
            assert task["closed_by"] == "agent" and task["exit_code"] == -signal.SIGKILL, task
            return task["exit_code"]
        code, body = call(rig.url, "POST", f"/v1/tasks/{endpoint}/status", {"state": "working", "note": "exactly once"})
        assert code == 200, body
        wait(lambda: dropped.exists(), "applied result response dropped")
        # A subsequent accepted command proves the first retry completed.
        rig.marker(endpoint, "RESULT-RECONCILED")
        assert status.read_text() == "working: exactly once\n"
        proc.terminate()
        proc.wait(timeout=15)
        assert rig.task(endpoint)["closed_by"] == "agent"
        assert proxy.poll() is None
        return status.read_text()
    finally:
        rig.close()


def lost_kill_result(executable, name):
    return lost_result(executable, name, kill=True)


def redirected_background_exit(executable, name):
    rig = Rig(name)
    ready = rig.dir / "background-ready"
    worker_pid = None
    try:
        proc, endpoint, status = rig.agent(executable)
        rig.remember_worker(endpoint)
        rig.input(endpoint, "set +H")
        rig.marker(endpoint, "BEFORE-REDIRECTED-BACKGROUND")
        code, body = call(rig.url, "POST", f"/v1/tasks/{endpoint}/status", {"state": "working", "note": "redirected background"})
        assert code == 200, body
        rig.input(endpoint, f"trap '' HUP; sleep 15 </dev/null >/dev/null 2>&1 & printf '%s\\n' \"$!\" > {shlex.quote(str(ready))}")
        worker_pid = wait(lambda: int(ready.read_text()) if ready.exists() and ready.read_text().strip() else None, "redirected background readiness")
        assert alive(worker_pid)
        rig.input(endpoint, "exit 7")
        proc.wait(timeout=10)
        task = wait(lambda: rig.task(endpoint) if rig.task(endpoint).get("closed_by") == "agent" else None, "prompt final close with background child", 50)
        assert task["exit_code"] == 7 and task["endpoint_id"] == endpoint, task
        assert alive(worker_pid), "close depended on background completion"
        assert status.read_text() == "working: redirected background\n"
        return task["closed_by"], task["exit_code"], status.read_text()
    finally:
        try:
            if worker_pid is not None:
                wait(lambda: not alive(worker_pid), "bounded background self-termination", 200)
        finally:
            rig.close()


def final_rejoin(executable, name):
    rig = Rig(name)
    try:
        proc, endpoint, _ = rig.agent(executable)
        rig.remember_worker(endpoint)
        rig.input(endpoint, "sleep 1; exit 9")
        proc.send_signal(signal.SIGSTOP)
        rig.restart()
        time.sleep(1.5)  # Child exits while its publisher cannot rejoin.
        proc.send_signal(signal.SIGCONT)
        proc.wait(timeout=20)
        task = rig.task(endpoint)
        assert task["closed_by"] == "agent" and task["exit_code"] == 9, task
        return task["closed_by"], task["exit_code"]
    finally:
        if 'proc' in locals() and proc.poll() is None:
            proc.send_signal(signal.SIGCONT)
        rig.close()


def contest(executable, name):
    rig = Rig(name)
    try:
        proc, endpoint, _ = rig.agent(executable)
        workers = rig.remember_worker(endpoint)
        # Freeze only this rig's publisher while a replacement claims its name
        # on a fresh hub. Its PTY process must survive the resulting stand-down.
        proc.send_signal(signal.SIGSTOP)
        rig.restart()
        replacement = "f" * 32
        payload = {"endpoint_id": replacement, "machine": "pilot", "label": "worker", "cwd": str(rig.dir), "protocol": 3, "capabilities": ["idempotent_command_results"]}
        code, body = call(rig.url, "POST", "/v1/agent/endpoints", payload, token=PUB)
        assert code == 201, body
        capability = body["command_capability"]
        call(rig.url, "POST", "/v1/agent/frames", {"machine": "pilot", "frames": [{"endpoint_id": replacement, "state": {"alive": True, "foreground": [], "cwd": str(rig.dir), "published_at": time.time()}}]}, token=PUB, capability=capability)
        proc.send_signal(signal.SIGCONT)
        time.sleep(3)
        assert proc.poll() is None and all(alive(int(p["pid"])) for p in workers)
        assert not rig.task(endpoint), "superseded agent reclaimed contested identity"
        proc.terminate()
        proc.wait(timeout=15)
        assert not rig.task(replacement).get("closed_at"), "closed somebody else's execution"
    finally:
        if 'proc' in locals() and proc.poll() is None:
            proc.send_signal(signal.SIGCONT)
        rig.close()


class Health(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        payload = self.server.payload
        body = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def refusals(executable, name):
    directory = LAB / name
    directory.mkdir()
    token = directory / "token"
    token.write_text(PUB)
    outputs = []
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Health)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        for health in ({"protocol": 99, "capabilities": ["idempotent_command_results"]}, {"protocol": 3, "capabilities": []}):
            server.payload = health
            ready = directory / "ready"
            completed = subprocess.run(executable + ["serve", "--hub", f"http://127.0.0.1:{server.server_port}", "--token-file", str(token), "--label", "refuse", "--cwd", str(directory), "--ready-file", str(ready)], env=ENV, capture_output=True, timeout=15)
            assert completed.returncode != 0 and not ready.exists()
            assert PUB.encode() not in completed.stderr
            outputs.append(completed.returncode != 0)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
    return outputs


if __name__ == "__main__":
    for function in (command_values, intervals, concurrent_status, generation_refusal, lifecycle, lost_result, lost_kill_result, redirected_background_exit, final_rejoin, contest, refusals):
        python = function(AGENTS[0], function.__name__ + "-python")
        rust = function(AGENTS[1], function.__name__ + "-rust")
        assert python == rust, (function.__name__, python, rust)
        print("ok:", function.__name__, "Python/Rust observable parity", flush=True)

    unsafe_intervals()
