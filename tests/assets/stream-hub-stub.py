#!/usr/bin/env python3
"""A stand-in hub that answers a real agent badly, on purpose.

The re-registration cases need a hub that keeps saying one exact thing, which
the real hub cannot be asked to do: it is correct, so it forgets an endpoint
only by restarting, and that does not hold still long enough to measure how an
agent paces itself against it. This serves the agent's own routes and answers
each one as a case dictates.

It is deliberately not a hub. It holds no ring buffer, relays no command, and
answers no subscriber route; anything asserting hub behaviour belongs against
the real one. What it does own is a JOURNAL - one "<elapsed> <METHOD> <path>"
line per request - which is what turns "the agent backs off" into something a
test can measure rather than infer.

  --port N                 loopback port to bind (0 for an ephemeral one)
  --ready-file PATH        "<host> <port>" written there once bound
  --journal PATH           one line per request, appended
  --frames-ok-first N      let the first N frame posts through, forgetting the
                           endpoint on every frame after those
  --accept-registrations N how many registrations to accept (-1 for all)
  --command-id ID          deliver one successful status command with this id
  --second-command-id ID   deliver another command after the first
  --delay-command-secs N   delay the first command response
  --reject-result-command ID reject results for this command id
  --reject-result-error CODE error code for a rejected result
  --fail-results-first N   refuse the first N result posts
  --result-file PATH       write the accepted result payload there
  --closed-file PATH       write the accepted closing frame there
  --omit-result-capability omit result retry support from health
  --fleet                  also serve the firstmate-facing task routes against
                           fake endpoints (see "Fleet mode" below)

The stub stops itself once the test suite that started it is gone: tests/lib.sh
exports FM_TEST_OWNER_PID, and a suite killed too hard for its cleanup trap to
run would otherwise leave this server listening indefinitely.

Fleet mode is what tests/fixtures.sh's fm_test_fake_stream runs. Endpoints are
registered by tests/assets/stream-agent-stub.py, which bin/backends/stream.sh
starts in place of the real agent, and each one is a fake shell held here: a
submitted line is recorded and echoed, a line naming a harness (deck,
fm-deck-worker, pi, claude, codex) makes that harness the foreground process,
and /quit or /exit returns it to the shell. `cd [--] <dir>` moves the
endpoint's cwd, and `treehouse get` moves it to the endpoint's own
treehouse_cwd (registered from the agent stub's FM_FAKE_PANE_PATH), else the
stub-wide one (POST /v1/test/config {"treehouse_cwd": ...}), standing in for
the worktree treehouse would hand a spawn; {"stale_cwd": path,
"stale_cwd_reads": n} makes the first n cwd reads after `treehouse get`
report that transient path instead, and each endpoint counts those reads
(cwd_reads in the listing). An endpoint registered with a
launch_log appends every text it receives to that file, one per line, and every
key to <launch_log>.keys as "[key] <name>"; {"fail_keys": [...]} makes those
keys fail delivery (logged there as "[key-failed] <name>"); {"swallow_keys":
[...]} accepts the next key of each listed name and drops it, one listed entry
per key, as an agent that swallowed it (logged as "[key-swallowed] <name>");
{"on_text": path}
runs that executable with each received text as its argument, for a suite to
model the agent reacting to it; {"fail_input": true} refuses every input;
{"fail_submit_text": "substring"} delivers an input whose submission submits
a line containing it - the agent acts on it - and then answers 502, as a
transport that failed after the endpoint already acted; {"fail_text_and_exit":
"substring"} refuses a text containing it (502) while the agent exits anyway
(the foreground returns to the shell), a stop whose own delivery reported
failure; {"on_request": path}
runs that executable with "<METHOD> <route-tail>" (tail empty for the task
itself) before every request to the endpoint's task routes, for a suite to
observe or stall reads; {"busy_reads": n} makes the next n process reads
report an unattributable non-shell foreground ("node"), as a just-created
shell still running its rc files, before the real one; POST /v1/test/config
{"task_routes_unavailable": true} makes every task route answer 503 from then
on, a hub that stopped answering;
{"fail_text": "substring"} refuses only a text containing it;
{"kill_undelivered": true} answers a kill with delivered=false and leaves the
endpoint exactly as it was (a kill its agent never acknowledged);
{"fail_capture": true} fails every screen read and {"capture_fail_after": n}
every read after the first n; {"tick_format": "...{t}.{d}s...", "tick_base": b,
"tick_file": path} renders one row anew on every screen read (t = b + reads,
d = reads % 10) and writes the read count to tick_file. POST /v1/test/config {"endpoint_defaults":
{knob: value}} applies those knobs to every endpoint registered afterwards
(one a spawn creates); {"on_kill": path} runs that executable with the endpoint
id whenever a kill for the endpoint arrives (it must not call the hub). A registration carrying replace_label closes
an earlier live endpoint with the same label instead of refusing it, for a
suite's next case reusing a task id. The screen ends in a bordered
composer box holding the typed-but-unsubmitted text, with the cursor on it, so
the shared composer classifier reads empty or pending. Tests steer the fake
through /v1/test/endpoints (GET lists every endpoint with its submitted lines;
POST /v1/test/endpoints/<id> patches foreground, alive, stale, closed_by, or
forgets the endpoint so the hub answers 404 for it; {"history": [...]}
replaces the rendered lines above the composer; {"capture_file": path} makes
capture and screen read that file instead). A suite can also register an
endpoint itself (POST /v1/agent/endpoints with the agent's fields plus any of
launch_log, treehouse_cwd, capture_file). Status posts append the
ordinary "<state>: <note>" line to the status path the stub agent registered.
"""

import argparse
import http.server
import json
import os
import re
import socketserver
import subprocess
import threading
import time

HARNESS_RE = re.compile(r"(?:^|[\s/])(fm-deck-worker|deck|pi|claude|codex)(?=\s|$)")
SHELL = {"pid": "", "name": "bash", "argv0": "-bash", "args": "-bash"}
SHELL_NAMES = ("bash", "zsh", "sh", "fish", "dash")
SGR_RE = re.compile("\x1b\\[[0-9;:]*m")
# Per-endpoint lifecycle knobs a suite patches through /v1/test/endpoints/<id>.
KNOBS = ("foreground", "alive", "stale", "closed_by", "composer", "history",
         "capture_file", "fail_keys", "never_dies", "becomes", "interrupt_stops",
         "clear_repaints", "dead_on_clear", "cursor_row", "screen_rows", "cwd", "on_text", "fail_input",
         "kill_undelivered", "fail_text", "fail_capture", "capture_fail_after", "swallow_keys",
         "fail_submit_text", "on_request", "busy_reads", "fail_text_and_exit",
         "tick_format", "tick_base", "tick_file", "on_kill")
STATUS_STATES = ("working", "needs-decision", "blocked", "paused", "done",
                 "failed", "resolved")


class Stub(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # noqa: ARG002 - silence the default log
        pass

    # --- answers ----------------------------------------------------------

    def _json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _refuse(self, status: int, code: str, message: str) -> None:
        self._json(status, {"ok": False, "error": code, "message": message})

    def _read_body(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        body = self.rfile.read(length).decode("utf-8", "replace")
        try:
            return json.loads(body)
        except json.JSONDecodeError:
            return {}

    def _record(self) -> str:
        """Journal this request and answer with the path it was made against."""
        state = self.server.state
        path = self.path.split("?", 1)[0]
        with state["lock"]:
            line = "%.3f %s %s\n" % (time.monotonic() - state["started"],
                                     self.command, path)
            with open(state["journal"], "a", encoding="utf-8") as fh:
                fh.write(line)
        return path

    # --- routes -----------------------------------------------------------

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler's spelling
        path = self._record()
        if self.server.state["fleet"] and self._fleet("GET", path, {}):
            return
        if path == "/v1/health":
            capabilities = [] if self.server.state["omit_result_capability"] else [
                "idempotent_command_results"]
            self._json(200, {
                "ok": True,
                "protocol": 3,
                "version": "stub",
                "capabilities": capabilities,
                "state_max_age_secs": 10,
                "command_ack_secs": 10,
            })
            return
        if path == "/v1/agent/commands":
            with self.server.state["lock"]:
                index = self.server.state["command_index"]
                command_ids = self.server.state["command_ids"]
                send_command = index < len(command_ids)
                command_id = command_ids[index] if send_command else ""
                delay_command = (self.server.state["delay_command_secs"]
                                 if index == 0 else 0.0)
                if send_command:
                    self.server.state["command_index"] += 1
            if send_command:
                if delay_command > 0:
                    time.sleep(delay_command)
                self._json(200, {"ok": True, "commands": [{
                    "command_id": command_id,
                    "kind": "status",
                    "payload": {"state": "working", "note": "result retry"},
                }]})
                return
            # The agent's command poll is a long poll, and answering it at once
            # would spin it - burning this host's cpu and burying the journal
            # this case reads. Held for the wait the agent asked for, which is
            # what the real hub does when it has nothing to hand over.
            wait = 3.0
            for part in self.path.split("?", 1)[-1].split("&"):
                if part.startswith("wait="):
                    try:
                        wait = min(float(part[5:]), 10.0)
                    except ValueError:
                        pass
            time.sleep(wait)
            self._json(200, {"ok": True, "commands": []})
            return
        self._refuse(404, "no_such_route", "the stub serves agent routes only")

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler's spelling
        path = self._record()
        payload = self._read_body()
        state = self.server.state
        if state["fleet"] and self._fleet("POST", path, payload):
            return
        if path == "/v1/agent/endpoints":
            with state["lock"]:
                state["registrations"] += 1
                accepted = (state["accept_registrations"] < 0
                            or state["registrations"] <= state["accept_registrations"])
            if not accepted:
                self._refuse(503, "hub_unready", "the stub is not taking registrations")
                return
            self._json(201, {"ok": True, "endpoint": {}})
            return
        if path == "/v1/agent/frames":
            with state["lock"]:
                state["frames"] += 1
                allowed = state["frames"] <= state["frames_ok_first"]
            closing = next((frame for frame in payload.get("frames", [])
                            if isinstance(frame, dict) and frame.get("closed")), None)
            if closing is not None and state["closed_file"]:
                with open(state["closed_file"], "w", encoding="utf-8") as fh:
                    json.dump(closing, fh)
            if allowed:
                self._json(200, {"ok": True, "accepted": 1})
                return
            self._refuse(404, "no_such_endpoint",
                         "the stub has forgotten this endpoint by design")
            return
        if path == "/v1/agent/results":
            with state["lock"]:
                state["result_attempts"] += 1
                refuse = state["result_attempts"] <= state["fail_results_first"]
                reject = (payload.get("command_id")
                          == state["reject_result_command"])
            if reject:
                code = state["reject_result_error"]
                status = 403 if code == "endpoint_unauthorized" else 404
                self._refuse(status, code, "the result was rejected by design")
                return
            if refuse:
                self._refuse(503, "result_unavailable", "the result route is unavailable")
                return
            if state["result_file"]:
                with open(state["result_file"], "w", encoding="utf-8") as fh:
                    json.dump(payload, fh)
            self._json(200, {"ok": True})
            return
        self._refuse(404, "no_such_route", "the stub serves agent routes only")


    def do_DELETE(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler's spelling
        path = self._record()
        if self.server.state["fleet"] and self._fleet("DELETE", path, {}):
            return
        self._refuse(404, "no_such_route", "the stub serves agent routes only")

    # --- fleet mode -------------------------------------------------------

    def _text(self, status: int, body: str) -> None:
        raw = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    @staticmethod
    def _screen(endpoint: dict) -> tuple:
        if endpoint.get("tick_format"):
            # A screen that renders anew on every read (an elapsed-time footer).
            n = endpoint.get("ticks", 0) + 1
            endpoint["ticks"] = n
            if endpoint.get("tick_file"):
                with open(endpoint["tick_file"], "w", encoding="utf-8") as fh:
                    fh.write("%d\n" % n)
            row = endpoint["tick_format"].format(n=n, d=n % 10, t=int(endpoint.get("tick_base") or 0) + n)
            return [row], 0
        if isinstance(endpoint.get("screen_rows"), list):
            rows = list(endpoint["screen_rows"])
            cursor = endpoint.get("cursor_row")
            return rows, cursor if isinstance(cursor, int) else max(0, len(rows) - 1)
        if endpoint.get("capture_file"):
            try:
                with open(endpoint["capture_file"], encoding="utf-8") as fh:
                    rows = fh.read().split("\n")
            except OSError:
                rows = []
            if rows and rows[-1] == "":
                rows.pop()
            cursor = endpoint.get("cursor_row")
            if isinstance(cursor, int):
                return rows, cursor
            return rows, max(0, len(rows) - 1)
        composer = endpoint["composer"]
        width = max(4, len(composer) + 2)
        rows = endpoint["history"][-30:] + [
            "\u256d" + "\u2500" * width + "\u256e",
            "\u2502 " + composer.ljust(width - 2) + " \u2502",
            "\u2570" + "\u2500" * width + "\u256f",
        ]
        return rows, len(rows) - 2

    @staticmethod
    def _describe(endpoint: dict) -> dict:
        return {key: endpoint[key] for key in (
            "endpoint_id", "machine", "label", "cwd", "closed_at", "closed_by")}

    @staticmethod
    def _on_kill(endpoint: dict, endpoint_id: str) -> None:
        """A suite's witness that cleanup reached this endpoint's kill."""
        if endpoint.get("on_kill"):
            subprocess.run([endpoint["on_kill"], endpoint_id], timeout=30, check=False,
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL)

    @staticmethod
    def _capture_refused(endpoint: dict) -> bool:
        """Count a screen read; True when the suite made this one fail."""
        endpoint["capture_reads"] = endpoint.get("capture_reads", 0) + 1
        after = endpoint.get("capture_fail_after")
        return bool(endpoint.get("fail_capture")) or (
            isinstance(after, int) and endpoint["capture_reads"] > after)

    @staticmethod
    def _harness_runs(endpoint: dict) -> bool:
        """Whether a non-shell process holds the endpoint's foreground."""
        return any(p.get("name") not in SHELL_NAMES for p in endpoint["foreground"])

    def _submit(self, endpoint: dict) -> None:
        line = endpoint["composer"]
        endpoint["composer"] = ""
        endpoint["history"].append("$ " + line)
        endpoint["submitted"].append(line)
        harness = self._harness_runs(endpoint)
        if harness and line.strip() in ("/quit", "/exit"):
            if not endpoint.get("never_dies"):
                endpoint["foreground"] = [dict(SHELL)]
            return
        if endpoint.get("becomes") and "encode launch-brief" in line:
            name = endpoint["becomes"]
            endpoint["foreground"] = [{"pid": "", "name": name, "argv0": name,
                                       "args": line}]
            return
        words = line.split()
        if not harness and words[:1] == ["cd"]:
            target = [w for w in words[1:] if w != "--"]
            if target:
                endpoint["cwd"] = target[0].strip("'\"")
            return
        if not harness and words[:2] == ["treehouse", "get"]:
            target = endpoint.get("treehouse_cwd") or self.server.state["treehouse_cwd"]
            if target:
                endpoint["cwd"] = target
            endpoint["cwd_reads"] = 0
            if self.server.state.get("stale_cwd"):
                endpoint["stale_cwd"] = self.server.state["stale_cwd"]
                endpoint["stale_cwd_reads"] = int(self.server.state.get("stale_cwd_reads") or 0)
            return
        match = HARNESS_RE.search(line)
        if not harness and match:
            name = match.group(1)
            endpoint["foreground"] = [{"pid": "", "name": name, "argv0": name,
                                       "args": line}]

    def _input(self, endpoint: dict, payload: dict) -> None:
        text = payload.get("text")
        if text is not None:
            if endpoint.get("launch_log"):
                with open(endpoint["launch_log"], "a", encoding="utf-8") as fh:
                    fh.write(str(text) + "\n")
            if endpoint.get("on_text"):
                # A suite's stand-in for the agent reacting to what it was
                # typed (acknowledging a doorbell, answering on its channel).
                subprocess.run([endpoint["on_text"], str(text)], timeout=30, check=False,
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)
            endpoint["composer"] += str(text)
            if payload.get("submit"):
                self._submit(endpoint)
        for key in payload.get("keys") or []:
            swallow = endpoint.get("swallow_keys")
            if isinstance(swallow, list) and key in swallow:
                # Delivered, and lost: the agent never acted on this key.
                swallow.remove(key)
                if endpoint.get("launch_log"):
                    with open(endpoint["launch_log"] + ".keys", "a", encoding="utf-8") as fh:
                        fh.write("[key-swallowed] %s\n" % key)
                continue
            if endpoint.get("launch_log"):
                with open(endpoint["launch_log"] + ".keys", "a", encoding="utf-8") as fh:
                    fh.write("[key] %s\n" % key)
            harness = self._harness_runs(endpoint)
            if key in ("Escape", "C-c") and harness and endpoint.get("interrupt_stops"):
                endpoint["foreground"] = [dict(SHELL)]
            if key == "C-u":
                if endpoint.get("clear_repaints"):
                    # The clear repaints the bare prompt row, cursor on it.
                    endpoint["screen_rows"] = ["\u276f "]
                    endpoint["cursor_row"] = 0
                if endpoint.get("dead_on_clear"):
                    endpoint["foreground"] = [dict(SHELL)]
            if key == "Enter":
                self._submit(endpoint)
            elif key in ("C-u", "C-c"):
                endpoint["composer"] = ""

    def _fleet(self, method: str, path: str, payload: dict) -> bool:
        """Serve one fleet-mode route; False leaves it to the agent routes."""
        state = self.server.state
        endpoints = state["endpoints"]
        with state["lock"]:
            if method == "POST" and path == "/v1/agent/endpoints":
                machine = str(payload.get("machine") or "")
                label = str(payload.get("label") or "")
                same = endpoints.get(str(payload.get("endpoint_id") or ""))
                if same is not None and not same["closed_at"]:
                    # A suite re-registering its own endpoint refreshes the
                    # test knobs rather than colliding with itself.
                    for key in ("launch_log", "treehouse_cwd", "capture_file"):
                        if key in payload:
                            same[key] = str(payload.get(key) or "")
                    self._json(201, {"ok": True, "endpoint": {"endpoint_id": same["endpoint_id"]}})
                    return True
                for other in endpoints.values():
                    if (not other["closed_at"] and other["machine"] == machine
                            and other["label"] == label):
                        if payload.get("replace_label"):
                            # A suite's next case reusing a task id: the earlier
                            # case's endpoint is over, so it closes here.
                            other["closed_at"] = time.time()
                            other["closed_by"] = "test-replace"
                            other["alive"] = False
                            continue
                        self._refuse(409, "duplicate_label",
                                     "machine %s already has a live endpoint labelled %s"
                                     % (machine, label))
                        return True
                endpoint_id = str(payload.get("endpoint_id") or "")
                endpoints[endpoint_id] = {
                    "endpoint_id": endpoint_id, "machine": machine, "label": label,
                    "cwd": str(payload.get("cwd") or ""),
                    "status_path": str(payload.get("status_path") or ""),
                    "closed_at": None, "closed_by": None, "alive": True,
                    "stale": False, "history": [], "composer": "",
                    "submitted": [],
                    "foreground": (payload["foreground"] if isinstance(payload.get("foreground"), list)
                                   else [dict(SHELL)]),
                    "launch_log": str(payload.get("launch_log") or ""),
                    "treehouse_cwd": str(payload.get("treehouse_cwd") or ""),
                    "capture_file": str(payload.get("capture_file") or ""),
                }
                endpoints[endpoint_id].update(state.get("endpoint_defaults") or {})
                self._json(201, {"ok": True, "endpoint": {"endpoint_id": endpoint_id}})
                return True
            if method == "GET" and path == "/v1/tasks":
                self._json(200, {"ok": True, "tasks": [
                    self._describe(e) for e in endpoints.values()]})
                return True
            if path == "/v1/test/config" and method == "POST":
                if "treehouse_cwd" in payload:
                    state["treehouse_cwd"] = str(payload["treehouse_cwd"] or "")
                if isinstance(payload.get("endpoint_defaults"), dict):
                    state["endpoint_defaults"] = {
                        k: v for k, v in payload["endpoint_defaults"].items() if k in KNOBS}
                if "task_routes_unavailable" in payload:
                    state["task_routes_unavailable"] = bool(payload["task_routes_unavailable"])
                if "stale_cwd" in payload:
                    state["stale_cwd"] = str(payload["stale_cwd"] or "")
                    state["stale_cwd_reads"] = int(payload.get("stale_cwd_reads") or 0)
                self._json(200, {"ok": True})
                return True
            if path == "/v1/test/endpoints" and method == "GET":
                self._json(200, {"ok": True, "endpoints": [
                    {key: value for key, value in e.items() if key != "history"}
                    for e in endpoints.values()]})
                return True
            match = re.match(r"\A/v1/(tasks|test/endpoints)/([0-9a-f]+)(?:/([a-z]+))?\Z", path)
            if not match:
                return False
            kind, endpoint_id, tail = match.group(1), match.group(2), match.group(3) or ""
            endpoint = endpoints.get(endpoint_id)
            if kind == "tasks" and state.get("task_routes_unavailable"):
                self._refuse(503, "hub_unavailable", "the hub is not answering task routes")
                return True
            if kind == "test/endpoints":
                if endpoint is None:
                    self._refuse(404, "no_such_endpoint", "no endpoint %s" % endpoint_id)
                    return True
                if payload.get("forget"):
                    del endpoints[endpoint_id]
                for key in KNOBS:
                    if key in payload:
                        endpoint[key] = payload[key]
                if payload.get("closed_by"):
                    endpoint["closed_at"] = endpoint["closed_at"] or time.time()
                self._json(200, {"ok": True})
                return True
            if endpoint is None:
                self._refuse(404, "no_such_endpoint", "no endpoint %s" % endpoint_id)
                return True
            if endpoint.get("on_request"):
                # A suite observing (or stalling) the reads and writes made of
                # this endpoint, before the hub answers them.
                subprocess.run([endpoint["on_request"], method, tail], timeout=30, check=False,
                               stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL)
            if method == "GET" and tail == "":
                self._json(200, {"ok": True, "task": self._describe(endpoint)})
            elif method == "GET" and tail in ("capture", "screen") and self._capture_refused(endpoint):
                self._refuse(502, "capture_failed", "the screen of %s could not be read" % endpoint_id)
            elif method == "GET" and tail == "capture":
                # A capture is plain text, like the hub's: SGR styling stays
                # only in the screen read asked for format=ansi.
                rows, _ = self._screen(endpoint)
                self._text(200, "\n".join(SGR_RE.sub("", r) for r in rows) + "\n")
            elif method == "GET" and tail == "screen":
                rows, cursor = self._screen(endpoint)
                if "format=ansi" not in self.path:
                    rows = [SGR_RE.sub("", r) for r in rows]
                self._json(200, {"ok": True, "cursor_row": cursor, "screen": "\n".join(rows)})
            elif method == "GET" and tail in ("processes", "cwd"):
                answer = {"ok": True, "endpoint_id": endpoint_id,
                          "machine": endpoint["machine"], "stale": bool(endpoint["stale"]),
                          "closed": bool(endpoint["closed_at"]),
                          "closed_by": endpoint["closed_by"], "exit_code": None}
                if not endpoint["stale"]:
                    answer["alive"] = bool(endpoint["alive"])
                    if tail == "processes":
                        answer["foreground"] = endpoint["foreground"] if endpoint["alive"] else []
                        if endpoint["alive"] and int(endpoint.get("busy_reads") or 0) > 0:
                            endpoint["busy_reads"] = int(endpoint["busy_reads"]) - 1
                            answer["foreground"] = [{"pid": "", "name": "node", "argv0": "node",
                                                     "args": "node"}]
                    else:
                        endpoint["cwd_reads"] = endpoint.get("cwd_reads", 0) + 1
                        if endpoint.get("stale_cwd_reads", 0) > 0:
                            # A pane still settling after `treehouse get`
                            # reports a transient path first, one per read.
                            endpoint["stale_cwd_reads"] -= 1
                            answer["cwd"] = endpoint["stale_cwd"]
                        else:
                            answer["cwd"] = endpoint["cwd"]
                self._json(200, answer)
            elif method == "POST" and tail == "input":
                if endpoint["closed_at"]:
                    self._refuse(410, "endpoint_closed", "endpoint %s is closed" % endpoint_id)
                    return True
                if endpoint.get("fail_input"):
                    self._refuse(502, "input_failed", "input to %s was not delivered" % endpoint_id)
                    return True
                if (endpoint.get("fail_text_and_exit") and payload.get("text") is not None
                        and endpoint["fail_text_and_exit"] in str(payload.get("text"))):
                    endpoint["foreground"] = [dict(SHELL)]
                    self._refuse(502, "input_failed", "input to %s was not delivered" % endpoint_id)
                    return True
                if (endpoint.get("fail_text") and payload.get("text") is not None
                        and endpoint["fail_text"] in str(payload.get("text"))):
                    self._refuse(502, "input_failed", "input to %s was not delivered" % endpoint_id)
                    return True
                failing = [k for k in payload.get("keys") or [] if k in (endpoint.get("fail_keys") or [])]
                if failing:
                    if endpoint.get("launch_log"):
                        with open(endpoint["launch_log"] + ".keys", "a", encoding="utf-8") as fh:
                            fh.write("[key-failed] %s\n" % failing[0])
                    self._refuse(502, "input_failed", "key %s was not delivered" % failing[0])
                    return True
                submitted_before = len(endpoint["submitted"])
                self._input(endpoint, payload)
                after = endpoint.get("fail_submit_text")
                if after and any(after in line for line in endpoint["submitted"][submitted_before:]):
                    self._refuse(502, "input_failed", "input to %s was not acknowledged" % endpoint_id)
                    return True
                self._json(200, {"ok": True, "delivered": endpoint_id})
            elif method == "POST" and tail == "status":
                if payload.get("state") not in STATUS_STATES or not endpoint["status_path"]:
                    self._refuse(400, "bad_state", "unknown status state or no status path")
                    return True
                with open(endpoint["status_path"], "a", encoding="utf-8") as fh:
                    fh.write("%s: %s\n" % (payload["state"],
                                           " ".join(str(payload.get("note") or "").split())))
                self._json(200, {"ok": True, "appended": endpoint_id})
            elif method == "DELETE" and tail == "" and endpoint.get("kill_undelivered"):
                self._on_kill(endpoint, endpoint_id)
                # The agent never acknowledges this kill: the record stays as it
                # was and the hub says so, the shape a kill nothing confirmed has.
                self._json(200, {"ok": True, "closed": endpoint_id,
                                 "machine": endpoint["machine"], "delivered": False})
            elif method == "DELETE" and tail == "":
                self._on_kill(endpoint, endpoint_id)
                endpoint["closed_at"] = endpoint["closed_at"] or time.time()
                endpoint["closed_by"] = "agent"
                endpoint["alive"] = False
                self._json(200, {"ok": True, "closed": endpoint_id,
                                 "machine": endpoint["machine"], "delivered": True})
            else:
                self._refuse(404, "no_such_route", "no such endpoint route: %s" % tail)
            return True


class StubServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main() -> int:
    parser = argparse.ArgumentParser(description="a hub stand-in for the agent's routes")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--ready-file", default="")
    parser.add_argument("--journal", required=True)
    parser.add_argument("--frames-ok-first", type=int, default=1)
    parser.add_argument("--accept-registrations", type=int, default=-1)
    parser.add_argument("--command-id", default="")
    parser.add_argument("--second-command-id", default="")
    parser.add_argument("--delay-command-secs", type=float, default=0.0)
    parser.add_argument("--reject-result-command", default="")
    parser.add_argument("--reject-result-error", default="no_such_command")
    parser.add_argument("--fail-results-first", type=int, default=0)
    parser.add_argument("--result-file", default="")
    parser.add_argument("--closed-file", default="")
    parser.add_argument("--omit-result-capability", action="store_true")
    parser.add_argument("--fleet", action="store_true")
    options = parser.parse_args()

    server = StubServer(("127.0.0.1", options.port), Stub)
    server.state = {
        "lock": threading.Lock(),
        "started": time.monotonic(),
        "journal": options.journal,
        "frames_ok_first": options.frames_ok_first,
        "accept_registrations": options.accept_registrations,
        "registrations": 0,
        "frames": 0,
        "command_ids": [value for value in
                        (options.command_id, options.second_command_id) if value],
        "command_index": 0,
        "delay_command_secs": options.delay_command_secs,
        "reject_result_command": options.reject_result_command,
        "reject_result_error": options.reject_result_error,
        "fail_results_first": options.fail_results_first,
        "result_attempts": 0,
        "result_file": options.result_file,
        "closed_file": options.closed_file,
        "omit_result_capability": options.omit_result_capability,
        "fleet": options.fleet,
        "endpoints": {},
        "treehouse_cwd": "",
        "endpoint_defaults": {},
    }
    open(options.journal, "a", encoding="utf-8").close()
    if options.ready_file:
        host, port = server.server_address[0], server.server_address[1]
        with open(options.ready_file, "w", encoding="utf-8") as fh:
            fh.write("%s %s\n" % (host, port))
    watch_owner(server, os.environ.get("FM_TEST_OWNER_PID", ""))
    server.serve_forever(poll_interval=0.2)
    return 0


def watch_owner(server, owner: str) -> None:
    """Shut the server down once the owning test process has exited."""
    if not owner.isdigit() or int(owner) <= 1:
        return

    def run() -> None:
        while True:
            time.sleep(1)
            try:
                os.kill(int(owner), 0)
            except ProcessLookupError:
                server.shutdown()
                return
            except PermissionError:
                pass

    threading.Thread(target=run, daemon=True).start()


if __name__ == "__main__":
    raise SystemExit(main())
