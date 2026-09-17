#!/usr/bin/env python3
"""A stand-in hub that answers a real agent badly, on purpose.

The re-registration cases need a hub that keeps saying one exact thing, which
the real hub cannot be asked to do: it is correct, so it forgets an endpoint
only by restarting and refuses a credential only by being reconfigured, and
neither holds still long enough to measure how an agent paces itself against
it. This serves the agent's own routes and answers each one as a case dictates.

It is deliberately not a hub. It holds no ring buffer, relays no command, and
answers no subscriber route; anything asserting hub behaviour belongs against
the real one. What it does own is a JOURNAL - one "<elapsed> <METHOD> <path>"
line per request - which is what turns "the agent backs off" into something a
test can measure rather than infer.

  --port N                 loopback port to bind (0 for an ephemeral one)
  --ready-file PATH        "<host> <port>" written there once bound
  --journal PATH           one line per request, appended
  --protocol N             the protocol every health call reports
  --frames-ok-first N      let the first N frame posts through, forgetting the
                           endpoint on every frame after those
  --accept-registrations N how many registrations to accept (-1 for all)
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

    def _read_body(self) -> None:
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)

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
        state = self.server.state
        if path == "/v1/health":
            self._json(200, {
                "ok": True,
                "protocol": state["protocol"],
                "version": "stub",
                "state_max_age_secs": 10,
                "command_ack_secs": 10,
            })
            return
        if path == "/v1/agent/commands":
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
        self._read_body()
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
            if allowed:
                self._json(200, {"ok": True, "accepted": 1})
                return
            self._refuse(404, "no_such_endpoint",
                         "the stub has forgotten this endpoint by design")
            return
        if path == "/v1/agent/results":
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
    parser.add_argument("--protocol", type=int, default=2)
    parser.add_argument("--frames-ok-first", type=int, default=1)
    parser.add_argument("--accept-registrations", type=int, default=-1)
    options = parser.parse_args()

    server = StubServer(("127.0.0.1", options.port), Stub)
    server.state = {
        "lock": threading.Lock(),
        "started": time.monotonic(),
        "journal": options.journal,
        "protocol": options.protocol,
        "frames_ok_first": options.frames_ok_first,
        "accept_registrations": options.accept_registrations,
        "registrations": 0,
        "frames": 0,
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
