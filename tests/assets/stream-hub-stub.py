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
"""

import argparse
import http.server
import json
import socketserver
import threading
import time


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
    }
    open(options.journal, "a", encoding="utf-8").close()
    if options.ready_file:
        host, port = server.server_address[0], server.server_address[1]
        with open(options.ready_file, "w", encoding="utf-8") as fh:
            fh.write("%s %s\n" % (host, port))
    server.serve_forever(poll_interval=0.2)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
