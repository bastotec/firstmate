#!/usr/bin/env bash
# Token-free native Deck deadline protocol guard against a loopback HTTP server.
# No gateway credentials or external model endpoint are used.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_DECK_DEADLINE_LIVE deck python3
python3 - "$(command -v deck)" <<'PY'
import http.server
import json
import os
import subprocess
import sys
import tempfile
import threading
import time

binary = sys.argv[1]
version = subprocess.check_output([binary, "--version"], text=True).strip()
requested = threading.Event()


class SlowGateway(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        requested.set()
        time.sleep(10)

    def log_message(self, *_):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), SlowGateway)
threading.Thread(target=server.serve_forever, daemon=True).start()
with tempfile.TemporaryDirectory(prefix="fm-deck-deadline-") as root:
    key = os.path.join(root, "test.key")
    with open(key, "w") as stream:
        stream.write("loopback-only-test-key")
    env = dict(os.environ, HOME=root, XDG_CONFIG_HOME=root, XDG_DATA_HOME=root)
    env.pop("PROXAI_API_KEY", None)
    result = subprocess.run(
        [binary, "run", "Wait for the local test response", "--ephemeral",
         "--deadline-secs", "2", "--model", "test/deadline",
         "--base-url", f"http://127.0.0.1:{server.server_port}/v1",
         "--api-key-file", key],
        cwd=root, env=env, text=True, capture_output=True, timeout=20,
    )
    events = [json.loads(line) for line in result.stdout.splitlines()]
    assert requested.is_set(), f"{version}: deadline test never reached loopback server: {result.stderr}"
    assert result.returncode != 0, f"{version}: deadline unexpectedly succeeded"
    assert any(event.get("type") == "run_started" and event.get("session") for event in events), events
    assert events[-1] == {"type": "run_failed", "error": "run exceeded 2s deadline"}, (
        version, events, result.stderr
    )
server.shutdown()
print(f"ok - {version}: native deadline emits resumable session and exact run_failed reason")
PY
