#!/usr/bin/env python3
"""Test-only relay: real hub + real agents + fm-stream-bridge.py serve; its stdout is
served over HTTP (CORS) so the Bridge UI page can hand each line to ingest_record.
The relay is NOT part of the change - it stands in for the transport the docs say is open."""
import json, os, subprocess, sys, threading, time, urllib.request
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

sys.argv = [sys.argv[0]]
exec(open("/tmp/fmbridge-live/drive.py").read().split("T0 = time.monotonic()")[0].replace("live-driver-transcript.txt", "relay-transcript.txt").replace("/tmp/fmbridge-live/run", "/tmp/fmbridge-live/relayrun"))
T0 = time.monotonic()
RELAY_PORT = int(os.environ.get("RELAY_PORT", "47817"))
lines, agents = [], {}
hub = start_hub("relay")
for m, l in (("box-a", "task-alpha"), ("box-a", "task-bravo"), ("box-b", "task-alpha")):
    agents[m + "/" + l] = start_agent(m, l)
bridge = subprocess.Popen([sys.executable, WT + "/bin/fm-stream-bridge.py", "serve", "--hub", URL,
                           "--token-file", D + "/view-token", "--fleet-id", "live-test"],
                          stdout=subprocess.PIPE, stderr=open(EV + "/relay-bridge-stderr.txt", "w"), text=True)
procs.append(bridge)
tee = open(EV + "/relay-serve-feed.ndjson", "w")
def pump():
    for line in bridge.stdout:
        lines.append(line.strip()); tee.write(line); tee.flush()
threading.Thread(target=pump, daemon=True).start()

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith("/records"):
            start = int(self.path.split("from=")[1]) if "from=" in self.path else 0
            body = json.dumps(lines[start:]).encode()
        elif self.path.startswith("/act/exit/"):
            leaf, code = self.path[len("/act/exit/"):].rsplit("/", 1)
            leaf = leaf.replace(":", "/")
            type_into(agents[leaf][1], "exit %s" % code); body = b'"ok"'
        else:
            self.send_response(404); self.end_headers(); return
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Type", "application/json")
        self.end_headers(); self.wfile.write(body)

say("relay on %d, hub %s" % (RELAY_PORT, URL))
try:
    ThreadingHTTPServer(("127.0.0.1", RELAY_PORT), H).serve_forever()
finally:
    for p in procs:
        if p.poll() is None: p.terminate()
