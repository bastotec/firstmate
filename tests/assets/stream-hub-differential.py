#!/usr/bin/env python3
"""Drive two isolated hubs through HTTP and the deployed Python peers.

Normalize only independently generated identities and measured clocks, never
status, refusal codes, order outcomes, byte payloads or lifecycle attribution.
The optional measurement output is observational, not a performance gate.
"""
import base64
import concurrent.futures
import http.client
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
RUST = Path(sys.argv[1]).resolve()
CLOCKS = {"created_at", "closed_at", "requested_at", "started_at", "first_seen",
          "last_seen", "state_age_secs", "agent_silent_for_secs", "silent_for_secs",
          "machine_silent_for_secs", "producer_monotonic_ms", "hub_arrival_ms"}


def normalized(value, identities=None):
    identities = identities or {}
    if isinstance(value, dict):
        return {k: (None if v is None else "clock") if k in CLOCKS else
                normalized(v, identities) for k, v in value.items()
                if k not in ("command_capability", "generation")}
    if isinstance(value, (list, tuple)):
        return [normalized(v, identities) for v in value]
    if isinstance(value, str):
        for identity, substitute in identities.items():
            value = value.replace(identity, substitute)
    return value


class Pilot:
    def __init__(self, command, directory):
        self.command = command
        self.directory = directory
        self.directory.mkdir()
        self.processes = []
        self.capabilities = {}
        self.directory.joinpath("tokens").write_text(
            "publish:pub\nsubscribe,control:ctl\nview\nsubscribe:union\ncontrol:union\n")
        self.directory.joinpath("pub").write_text("pub\n")
        self.directory.joinpath("view").write_text("view\n")
        self.start()

    def start(self, port=0):
        ready = self.directory / "ready"
        ready.unlink(missing_ok=True)
        self.log = open(self.directory / "hub.log", "ab")
        begin = time.monotonic()
        self.hub = subprocess.Popen(self.command + ["serve", "--port", str(port),
            "--token-file", str(self.directory / "tokens"), "--ready-file", str(ready),
            "--command-ack-secs", "0.25", "--state-max-age-secs", "0.5"],
            stdout=self.log, stderr=self.log)
        for _ in range(300):
            if ready.exists() and ready.stat().st_size:
                break
            assert self.hub.poll() is None, (self.directory / "hub.log").read_text()
            time.sleep(0.01)
        else:
            raise AssertionError("hub readiness timeout")
        self.startup_ms = (time.monotonic() - begin) * 1000
        host, port = ready.read_text().split()
        self.url = "http://%s:%s" % (host, port)
        self.generation = self.api("GET", "/v1/health", token="pub")[1]["generation"]

    def api(self, method, path, payload=None, token="ctl", capability=None):
        headers = {}
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        if capability is not None:
            headers["X-Endpoint-Capability"] = capability
        data = None if payload is None else json.dumps(payload).encode()
        request = urllib.request.Request(self.url + path, data=data, headers=headers,
                                         method=method)
        try:
            # This is a client-side fixture deadline, not a hub liveness budget.
            # Bulk screen updates can take longer on heavily loaded test hosts.
            response = urllib.request.urlopen(request, timeout=60)
        except urllib.error.HTTPError as exc:
            response = exc
        except TimeoutError as exc:
            raise AssertionError(
                f"{self.directory.name}: {method} {path} timed out after 60s"
            ) from exc
        with response:
            raw = response.read()
            if response.headers.get("Content-Type", "").startswith("application/json"):
                raw = json.loads(raw)
            return response.status, raw

    def register(self, eid, label="worker", **extra):
        p = dict(protocol=3, endpoint_id=eid, machine="box", label=label,
                 rows=4, cols=40, cwd="/tmp", capabilities=["idempotent_command_results"])
        p.update(extra)
        code, answer = self.api("POST", "/v1/agent/endpoints", p, "pub",
                                self.capabilities.get(eid))
        if code == 201:
            self.capabilities[eid] = answer["command_capability"]
        return code, answer

    def frame(self, eid, data=b"", **extra):
        frame = dict(endpoint_id=eid, b64=base64.b64encode(data).decode())
        frame.update(extra)
        return self.api("POST", "/v1/agent/frames",
                        dict(machine="box", frames=[frame]), "pub")

    def take(self, eid, capability=None):
        return self.api("GET", "/v1/agent/commands?machine=box&endpoint=" + eid + "&wait=0",
                        token="pub", capability=capability or self.capabilities[eid])

    def result(self, cid, eid, ok=True, error="", capability=None):
        return self.api("POST", "/v1/agent/results",
            dict(machine="box", command_id=cid, ok=ok, error=error), "pub",
            capability or self.capabilities[eid])

    def order(self, eid, oid="order", **extra):
        p = dict(leaf_worker_id="box/worker", execution_id=eid, order_id=oid,
                 text="hello", submit=True, hub_generation=self.generation)
        p.update(extra)
        return self.api("POST", "/v1/orders", p)

    def stop(self):
        if self.hub.poll() is None:
            self.hub.terminate()
            self.hub.wait(timeout=5)
        self.log.close()
        assert not (self.directory / "ready").exists(), "hub must retire its ready file"

    def close(self):
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
        self.stop()


def terminal_compatibility(p):
    """Exercise terminal parser boundaries through the public frame/read APIs."""
    records = []
    eid = "e" * 32
    records.append(p.register(eid, label="terminal", rows=4, cols=8))
    frames = [
        "ab\u17d8cd", "ab\u2e3acd", "ab\u2e3bcd", "ab中cd",
        "\x1b[31mab\u0301\x1b[0m中\x1b[2mc  \x1b[0m",
        "\x1b[3;4H\x1b[-9223372036854775808Gx",
        "\x1b[3;4H\x1b[9223372036854775808Gx",
        "\x1b[3;4H\x1b[9223372036854775808;9223372036854775808Hx",
    ]
    for kind in ("]", "P", "X", "^", "_"):
        for length in (65, 4098, 4099):
            frames.append("start\x1b" + kind + "é" * length + "\x1b\\ ok")
    frames.append(("\x1b]52;" + "x" * 4000 + "\x07\x1bP" + "x" * 4000 + "\x1b\\+") * 100)
    for frame in frames:
        assert p.frame(eid, b"\x1bc")[0] == 200
        data = frame.encode()
        # Include split UTF-8/control sequences rather than only whole strings.
        split = min(31, len(data))
        assert p.frame(eid, data[:split])[0] == 200
        assert p.frame(eid, data[split:])[0] == 200
        for suffix in ("screen", "screen?format=ansi", "capture?format=ansi"):
            records.append(p.api("GET", "/v1/tasks/" + eid + "/" + suffix))
        health = p.api("GET", "/v1/health", token="pub")
        assert health[0] == 200
    narrow = "f" * 32
    records.append(p.register(narrow, label="narrow", rows=3, cols=1))
    for frame in ("中\u0301", "\x08x"):
        assert p.frame(narrow, frame.encode())[0] == 200
        records.append(p.api("GET", "/v1/tasks/" + narrow + "/screen"))
    return [normalized(record) for record in records]


def exercise(p):
    records = []
    def save(answer):
        records.append(normalized(answer))
        return answer
    a, b, c = "a" * 32, "b" * 32, "c" * 32
    for token in (None, "wrong", "pub", "view", "ctl", "union"):
        save(p.api("GET", "/v1/health", token=token))
        save(p.api("GET", "/v1/tasks", token=token))
        save(p.api("POST", "/v1/agent/endpoints", {}, token))
    # A denied body must not poison a kept-alive connection; oversized bodies
    # close it without waiting for the caller to send attacker-controlled bytes.
    host = urllib.parse.urlsplit(p.url)
    connection = http.client.HTTPConnection(host.hostname, host.port, timeout=5)
    connection.request("POST", "/v1/agent/endpoints", json.dumps({"padding": "x" * 100000}),
                       {"Authorization": "Bearer view"})
    response = connection.getresponse()
    save((response.status, json.loads(response.read())))
    connection.request("GET", "/v1/health", headers={"Authorization": "Bearer pub"})
    response = connection.getresponse()
    save((response.status, json.loads(response.read())))
    connection.putrequest("POST", "/v1/agent/endpoints")
    connection.putheader("Authorization", "Bearer view")
    connection.putheader("Content-Length", str(4 * 1024 * 1024 + 1))
    connection.endheaders()
    response = connection.getresponse()
    save((response.status, json.loads(response.read())))
    assert response.getheader("Connection") == "close"
    connection.close()
    save(p.register(a, protocol=2))
    for malformed in ({"machine": "bad machine"}, {"label": "bad/label"},
                      {"rows": 0}, {"cols": "bad"}, {"capabilities": [False]}):
        save(p.register(a, **malformed))
    save(p.register(a))
    save(p.register(a))
    save(p.register(a, capabilities=[]))
    save(p.register(a, machine="other"))
    save(p.take(a, capability="invalid"))
    save(p.frame(a, b"start\r\n\x1b[2mghost\x1b[0m\r\n\xe4"))
    save(p.frame(a, b"\xb8\xad\x1b[38;2;5;6;7mcolour\x1b[0m", state={
        "alive": True, "foreground": ["python worker"], "cwd": "/tmp", "seq": 4,
        "tokens": 12, "messages": 2}))
    for tail in ("screen", "screen?format=ansi", "capture", "capture?format=ansi",
                 "processes", "cwd"):
        save(p.api("GET", "/v1/tasks/" + a + "/" + tail))
    records.extend(terminal_compatibility(p))
    save(p.register(b))  # A speaking agent contests a duplicate label.
    save(p.register(b, label="sibling"))
    save(p.take(b))
    save(p.api("GET", "/v1/tasks"))
    for eid, kind in ((a, "input"), (b, "status")):
        payload = {"text": "hello", "submit": True} if kind == "input" else {
            "state": "working", "note": "test"}
        with concurrent.futures.ThreadPoolExecutor() as pool:
            future = pool.submit(p.api, "POST", "/v1/tasks/" + eid + "/" + kind, payload)
            commands = []
            for _ in range(100):
                commands = p.take(eid)[1].get("commands", [])
                if commands:
                    break
                time.sleep(.001)
            assert len(commands) == 1
            command = commands[0]
            records.append(normalized(command, {command["command_id"]: "command"}))
            save(p.result(command["command_id"], eid))
            save(future.result())
            save(p.result(command["command_id"], eid))
            # Message contains a generated command id: normalize that id only.
            records.append(normalized(p.result(command["command_id"], eid, False, "no"),
                                      {command["command_id"]: "command"}))
    # Concurrent resends reserve one order id and type once.
    with concurrent.futures.ThreadPoolExecutor() as pool:
        futures = [pool.submit(p.order, a) for _ in range(3)]
        for _ in range(100):
            commands = p.take(a)[1]["commands"]
            if commands:
                break
            time.sleep(.001)
        assert len(commands) == 1
        cid = commands[0]["command_id"]
        save(p.result(cid, a))
        for f in futures:
            save(f.result())
    save(p.take(a))
    save(p.order(a))
    save(p.order(a, text="changed"))
    save(p.order(a, oid="stale-gen", hub_generation="stale"))
    save(p.order(c, oid="stale-execution"))
    # Taken with no result is unresolved, late ack settles it, negative ack
    # is an authoritative refusal rather than an unresolved outcome.
    for oid, ok in (("late", True), ("nack", False)):
        with concurrent.futures.ThreadPoolExecutor() as pool:
            future = pool.submit(p.order, a, oid)
            for _ in range(100):
                commands = p.take(a)[1]["commands"]
                if commands:
                    break
                time.sleep(.001)
            cid = commands[0]["command_id"]
            if ok:
                timed_out = future.result()
                assert timed_out[0] == 504 and timed_out[1]["delivered"] is None
                assert not timed_out[1]["worker_gone"]
                # The timeout diagnostic includes a measured age; the outcome
                # and refusal remain compared while that time is rounded away.
                timed_out[1]["message"] = "timed-out taken command (measured age)"
                save(timed_out)
            save(p.result(cid, a, ok, "" if ok else "agent says no"))
            if not ok:
                save(future.result())
            save(p.order(a, oid))
    # Never taken means NOT delivered, unlike the taken timeout above.
    timeout = p.order(b, "never", leaf_worker_id="box/sibling")
    assert timeout[0] == 504 and timeout[1]["delivered"] is False
    timeout[1]["message"] = "timed-out untaken command (measured age)"
    save(timeout)
    save(p.take(b))
    # Ring retention has exact byte offsets; capture's scrollback remains
    # bounded while the stream keeps the last 256 KiB of uninterpreted bytes.
    save(p.frame(b, b"0123456789" * 30000))
    save(p.frame(b, closed=True, exit_code=0))
    save(p.take(b))  # close revokes the endpoint command capability
    stream = p.api("GET", "/v1/tasks/" + b + "/stream?replay=1")
    assert stream[0] == 200
    events = [json.loads(line[6:]) for line in stream[1].splitlines() if line.startswith(b"data: ")]
    assert len(events) == 2 and len(base64.b64decode(events[0]["b64"])) == 262144
    assert events[-1]["closed"] and events[0]["offset"] == 300000
    save((200, stream[1]))
    save(p.order(b, "closed", leaf_worker_id="box/sibling"))
    save(p.register(c, label="legacy", capabilities=[]))
    save(p.order(c, "legacy", leaf_worker_id="box/legacy"))
    # Journal retention evicts old ids, does not mutate current records.
    for i in range(513):
        result = p.order(c, "bound-%d" % i, leaf_worker_id="box/legacy")
        assert result[0] == 409 and result[1]["error"] == "endpoint_not_orderable"
    save(p.order(c, "legacy", text="new binding after eviction", leaf_worker_id="box/legacy"))
    # Missing membership is not gone, including after a restart clears state.
    old_generation = p.generation
    port = int(p.url.rsplit(":", 1)[1])
    p.stop()
    p.start(port)
    assert p.generation != old_generation
    save(p.order(a, "old-generation", hub_generation=old_generation))
    unresolved = p.order(a, "missing")
    assert unresolved[1]["outcome"] == "unconfirmed"
    assert unresolved[1]["delivered"] is None and not unresolved[1]["worker_gone"]
    save(unresolved)
    save(p.register(a))
    save(p.frame(a, closed=True, exit_code=3))
    save(p.order(a, "missing"))  # An identical resend may resolve membership.
    return records


def peers(p):
    ready = p.directory / "agent-ready"
    home = p.directory / "peer-home"
    home.mkdir()
    startup = home / "startup-sentinel"
    history = home / ".bash_history"
    startup.write_bytes(b"startup untouched\n")
    history.write_bytes(b"history untouched\n")
    for name in (".bashrc", ".bash_profile", ".profile", ".zshrc", ".zprofile"):
        home.joinpath(name).write_text("printf 'startup ran\\n' > \"$HOME/startup-sentinel\"\n")
    env = os.environ.copy()
    env.update(HOME=str(home), SHELL="/bin/bash", HISTFILE="/dev/null")
    for name in ("BASH_ENV", "ENV", "ZDOTDIR"):
        env.pop(name, None)
    log = open(p.directory / "agent.log", "wb")
    process = subprocess.Popen([sys.executable, str(ROOT / "bin/fm-stream-agent.py"),
        "serve", "--hub", p.url, "--token-file", str(p.directory / "pub"),
        "--machine", "peers", "--label", "python", "--cwd", str(p.directory),
        "--ready-file", str(ready), "--state-interval", "0.1", "--poll-secs", "1"],
        stdout=log, stderr=log, env=env)
    p.processes.append(process)
    for _ in range(300):
        if ready.exists() and ready.stat().st_size:
            break
        assert process.poll() is None, (p.directory / "agent.log").read_text()
        time.sleep(.02)
    else:
        raise AssertionError("Python agent readiness timeout")
    eid = ready.read_text().strip().split()[1]
    assert len(eid) == 32 and all(c in "0123456789abcdef" for c in eid)
    result = p.api("POST", "/v1/tasks/" + eid + "/input",
                   dict(text="printf 'PYTHON-PEER-OK:%s:%s:%s\\n' \"$HOME\" \"$SHELL\" \"$HISTFILE\"", submit=True))
    assert result[0] == 200, result
    expected = ("PYTHON-PEER-OK:%s:/bin/bash:/dev/null" % home).encode()
    for _ in range(200):
        capture = p.api("GET", "/v1/tasks/" + eid + "/capture")[1]
        if expected in capture:
            break
        time.sleep(.02)
    else:
        raise AssertionError("agent did not publish terminal bytes")
    snapshot = subprocess.run([sys.executable, str(ROOT / "bin/fm-stream-bridge.py"),
        "snapshot", "--hub", p.url, "--token-file", str(p.directory / "view"),
        "--fleet-id", "test", "--epoch", "1"], capture_output=True, timeout=10)
    assert snapshot.returncode == 0, snapshot.stderr
    records = [json.loads(line) for line in snapshot.stdout.splitlines()]
    matching = [r for r in records if r.get("identity", {}).get("leaf_worker_id") == "peers/python"]
    assert matching, records
    out = normalized(matching, {eid: "python-peer"})
    # Restart preserves the worker. Its Python agent must rejoin an empty hub.
    port = int(p.url.rsplit(":", 1)[1])
    p.stop()
    p.start(port)
    for _ in range(300):
        tasks = p.api("GET", "/v1/tasks")[1]["tasks"]
        if any(t["endpoint_id"] == eid for t in tasks):
            break
        time.sleep(.02)
    else:
        raise AssertionError("Python agent did not rejoin")
    result = p.api("POST", "/v1/tasks/" + eid + "/input",
                   dict(text="exit", submit=True))
    assert result[0] == 200, result
    for _ in range(300):
        task = p.api("GET", "/v1/tasks/" + eid)[1]["task"]
        if task["closed_by"] == "agent":
            break
        time.sleep(.02)
    else:
        raise AssertionError("Python agent did not publish final close")
    assert task["exit_code"] == 0
    process.wait(timeout=8)
    assert startup.read_bytes() == b"startup untouched\n", "peer loaded operator startup files"
    assert history.read_bytes() == b"history untouched\n", "peer modified operator history"
    log.close()
    return out


def measure(p):
    rss = int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(p.hub.pid)]).strip())
    eid = "d" * 32
    p.register(eid, label="throughput")
    start = time.monotonic()
    for _ in range(100):
        assert p.frame(eid, b"x" * 4096)[0] == 200
    return dict(startup_ms=round(p.startup_ms, 2), rss_kib=rss,
                frame_mib_per_second=round(100 * 4096 / 1048576 / (time.monotonic() - start), 2))


def main():
    with tempfile.TemporaryDirectory(prefix="fm-hub-differential-") as tmp:
        pilots = [Pilot([sys.executable, str(ROOT / "bin/fm-stream-hub.py")], Path(tmp) / "python"),
                  Pilot([str(RUST)], Path(tmp) / "rust")]
        try:
            observations = [exercise(p) for p in pilots]
            assert len(observations[0]) == len(observations[1])
            for index, (python, rust) in enumerate(zip(*observations)):
                assert python == rust, (index, python, rust)
            peer_records = [peers(p) for p in pilots]
            assert peer_records[0] == peer_records[1], peer_records
            print("differential: %d HTTP/stream observations and Python agent/bridge lifecycle match" % len(observations[0]))
            print("measurements: " + json.dumps(dict(zip(("python", "rust"), [measure(p) for p in pilots])), sort_keys=True))
        finally:
            for p in pilots:
                p.close()


if __name__ == "__main__":
    main()
