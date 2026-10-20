"""Scripted Responses API drives the real specialist runner and real Deck tools."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

root, lab, deck = map(Path, sys.argv[1:])
expected = os.environ.get("FM_SPECIALIST_DECK_SHA256", "841b3027311747130fc12e4c0a1929874a5e3f051612fd909120fc0aa6176363")
fingerprint = hashlib.sha256(deck.read_bytes()).hexdigest()
version = subprocess.check_output([str(deck), "--version"], text=True).strip()
assert fingerprint == expected, f"Deck {version}: unverified fingerprint {fingerprint}; refresh the explicit pin and evidence"
print(f"{version} sha256={fingerprint}", flush=True)


def run_case(name, tool, args_factory, source_size):
    case = lab / name
    case.mkdir()
    home = case / "home"
    for directory in ("state", "data", "config"):
        (home / directory).mkdir(parents=True)
    source = case / "input.txt"
    source.write_text("x" * source_size + "\n")
    before = source.read_bytes()
    memory = home / "data/specialists/probe/memory.md"
    calls = []
    requests = []
    errors = []

    def call(index, tool_name, args):
        return {"type": "function_call", "id": f"fc_{index}", "call_id": f"call_{index}",
                "name": tool_name, "arguments": json.dumps(args), "status": "completed"}

    class Provider(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_POST(self):
            try:
                request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                requests.append(request)
                assert self.path == "/v1/responses", self.path
                turn = len(requests)
                if turn == 1:
                    # Both commands are in one batch and eligible for parallel
                    # execution absent the runner's concurrency-one admission.
                    items = [call(1, tool, args_factory(source)),
                             call(2, "run_command", {"command": f"printf changed >> {shlex.quote(str(source))}"})]
                elif turn == 2:
                    items = [call(3, "run_command", {"command": f"printf changed >> {shlex.quote(str(memory))}"})]
                else:
                    items = []
                calls.extend(items)
                events = []
                for index, item in enumerate(items):
                    events.append({"type": "response.output_item.added", "output_index": index,
                                   "item": dict(item, arguments="", status="in_progress")})
                    events.append({"type": "response.function_call_arguments.delta", "output_index": index,
                                   "item_id": item["id"], "delta": item["arguments"]})
                    events.append({"type": "response.output_item.done", "output_index": index, "item": item})
                if not items:
                    events.append({"type": "response.output_text.delta", "output_index": 0,
                                   "item_id": "msg_stop", "content_index": 0, "delta": "Stopped after the first failed tool."})
                response = {"id": f"resp_{turn}", "object": "response", "created_at": 0,
                            "status": "completed", "model": "fixture", "output": [], "tools": [],
                            "usage": {"input_tokens": 1, "output_tokens": 1, "total_tokens": 2}}
                events.append({"type": "response.completed", "response": response})
                for seq, event in enumerate(events):
                    event["sequence_number"] = seq
                body = "".join(f"event: {event['type']}\ndata: {json.dumps(event)}\n\n" for event in events).encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            except Exception as error:
                errors.append(repr(error))
                self.send_error(500)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    # Do not inherit real gateway keys, machine hooks, MCP or persisted sessions.
    env = {key: value for key, value in os.environ.items()
           if key in ("PATH", "TMPDIR", "SHELL", "LANG", "FM_TEST_SERVICE_SANDBOX")}
    env.update(HOME=str(home), XDG_CONFIG_HOME=str(home / ".config"),
               XDG_STATE_HOME=str(home / ".state"), DECK_STATE=str(case / "deck"),
               FM_HOME=str(home), FM_CONFIG_OVERRIDE=str(home / "config"),
               FM_STATE_OVERRIDE=str(home / "state"), FM_DATA_OVERRIDE=str(home / "data"),
               FM_CREW_WORK_ROOT=str(case / "work"), FM_DECK_BIN=str(deck),
               FM_CREW_MAX_TURNS="5", FM_CREW_DEADLINE_SECS="30",
               PROXAI_API_KEY="synthetic-local-only", PROXAI_BASE_URL=f"http://127.0.0.1:{server.server_port}/v1")
    spec = [str(root / "bin/fm-specialist.sh")]
    record = home / "state/specialists/probe.json"
    try:
        subprocess.run(spec + ["create", "probe", "--subject", "Synthetic input reader"], env=env,
                       check=True, capture_output=True, timeout=15)
        subprocess.run(spec + ["configure", "probe", "--stop-on-tool-failure", "on"], env=env,
                       check=True, capture_output=True, timeout=15)
        memory_before = memory.read_bytes()
        result = subprocess.run(spec + ["job", "probe", "--brief", "Read the fixture.", "--wait"],
                                env=env, capture_output=True, text=True, timeout=45)
        rec = json.loads(record.read_text())
        job = home / "state/specialists/probe/jobs" / rec["last_job"]["id"]
        events = [json.loads(line) for line in (job / "events.ndjson").read_text().splitlines()]
        (case / "requests.json").write_text(json.dumps(requests, indent=2))
        assert not errors, errors
        assert len(requests) == 3, (name, result, (job / "stderr.log").read_text())
        assert result.returncode == 1, result
        assert rec["last_job"]["outcome"] == "failed", rec
        assert f"({tool})" in rec["last_job"]["stopped"], rec
        failure = json.loads((job / "tool-failure.json").read_text())
        assert json.loads(failure["args"]) == args_factory(source), failure
        assert source.read_bytes() == before, "queued same-batch call executed"
        assert memory.read_bytes() == memory_before, "later memory edit executed"
        assert not any(event.get("type") == "completion_blocked" for event in events), events
        owner_result = (job / "result.md").read_text()
        assert owner_result.startswith("# Stopped at the first failed tool call"), owner_result
        assert tool in owner_result, owner_result
        history = [json.loads(line) for line in (home / "state/specialists/probe/history.jsonl").read_text().splitlines()]
        assert len(history) == 1 and history[0]["outcome"] == "failed", history
        # Refused calls must not yield successful tool results. Exact event
        # shape is checked against the pinned executable below.
        results = [event for event in events if event.get("type") == "tool_result"]
        assert [event["id"] for event in results] == ["call_1", "call_2", "call_3"], results
        assert all(event["output"].startswith("A tool call already failed (") for event in results[1:]), results[1:]
        assert len(calls) == 3, calls
        assert failure["output"] == " ".join(results[0]["output"].split())[:600], failure
        if tool == "read_file":
            assert "bytes not shown: full output" in results[0]["output"], results[0]
            if source_size > 256 * 1024:
                stored = next((case / "deck/tool-output").glob("*/*.txt")).read_text()
                assert "\n[... truncated ...]\n" in stored, "hard cut not exercised"
        else:
            assert "[exit_code]" in results[0]["output"], results[0]
        assert history[0]["stopped"] == rec["last_job"]["stopped"], history
        print(f"{name}: first cause retained; one tool executed; queued/later calls refused; input/memory unchanged; no completion injection; failed owner result", flush=True)
    finally:
        # Detached specialist runners have their own process groups. Reap only
        # this fixture's still-running runner on timeout/assertion failure.
        if record.exists():
            current = json.loads(record.read_text()).get("current_job")
            if current:
                try:
                    os.killpg(current["pid"], signal.SIGKILL)
                except ProcessLookupError:
                    pass
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)


run_case("stored-read", "read_file", lambda path: {"path": str(path)}, 20000)
run_case("hard-read", "read_file", lambda path: {"path": str(path)}, 300000)
run_case("large-nonzero", "run_command", lambda path: {"command": f"cat {shlex.quote(str(path))}; exit 7"}, 20000)
