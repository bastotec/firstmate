#!/usr/bin/env python3
"""A stand-in for bin/fm-stream-agent.py against a fleet-mode hub stub.

bin/backends/stream.sh starts this in place of the real agent when
FM_STREAM_AGENT_BIN points here (tests/fixtures.sh's fm_test_fake_stream).
It takes the real agent's `serve` arguments, registers one endpoint with
tests/assets/stream-hub-stub.py --fleet, writes the ready file the adapter
waits for, and exits: the stub itself holds the fake endpoint, so no pty and
no shell process exist. The status path is handed to the stub, which appends
status lines exactly where the real agent would.

Two test knobs ride along from this process's environment, so a suite that
sets them for one spawn gets them on that spawn's endpoint only:
FM_FAKE_LAUNCH_LOG (the stub appends every text the endpoint receives to that
file, one per line) and FM_FAKE_PANE_PATH (where a `treehouse get` typed into
the endpoint moves its cwd). FM_FAKE_AGENT_REGISTER_FAIL makes this agent fail
to register (an endpoint that could not be created), and with
FM_FAKE_AGENT_BREAK_HUB it first tells the hub stub to stop answering task
routes, a hub lost in the same moment.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command")
    serve = sub.add_parser("serve")
    for flag in ("--hub", "--token-file", "--machine", "--label", "--cwd",
                 "--status-path", "--ready-file", "--state-interval"):
        serve.add_argument(flag, default="")
    options = parser.parse_args()
    if options.command != "serve":
        print("stream-agent-stub: only 'serve' is supported", file=sys.stderr)
        return 2
    if os.environ.get("FM_FAKE_AGENT_REGISTER_FAIL"):
        if os.environ.get("FM_FAKE_AGENT_BREAK_HUB"):
            broken = urllib.request.Request(
                options.hub.rstrip("/") + "/v1/test/config",
                data=json.dumps({"task_routes_unavailable": True}).encode("utf-8"),
                method="POST", headers={"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(broken, timeout=10) as response:
                    response.read()
            except OSError:
                pass
        print("hub unreachable: registration failed by design", file=sys.stderr)
        return 1
    endpoint_id = os.urandom(16).hex()
    body = json.dumps({
        "endpoint_id": endpoint_id,
        "machine": options.machine,
        "label": options.label,
        "cwd": options.cwd,
        "status_path": options.status_path,
        "launch_log": os.environ.get("FM_FAKE_LAUNCH_LOG", ""),
        "treehouse_cwd": os.environ.get("FM_FAKE_PANE_PATH", ""),
    }).encode("utf-8")
    request = urllib.request.Request(
        options.hub.rstrip("/") + "/v1/agent/endpoints", data=body, method="POST",
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            response.read()
    except urllib.error.HTTPError as exc:
        try:
            message = json.loads(exc.read().decode("utf-8")).get("message", "")
        except (ValueError, AttributeError):
            message = ""
        print("registration refused: %s" % (message or exc.code), file=sys.stderr)
        return 1
    except OSError as exc:
        print("hub unreachable: %s" % exc, file=sys.stderr)
        return 1
    with open(options.ready_file, "w", encoding="utf-8") as fh:
        fh.write("registered %s\n" % endpoint_id)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
