#!/usr/bin/env python3
"""Round-2 live orchestrator (test-only, not part of the change).
Real fm-stream-hub.py + real fm-stream-agent.py workers + fm-stream-bridge.py serve.
The adapter's stdout is teed to r2-serve-feed.ndjson and exposed over a CORS HTTP
relay so the real Bridge UI page can hand each line to __chartroom.ingestRecord.
The relay stands in for the SSH/LAN transport the docs say is still open."""
import json, os, signal, socket, subprocess, sys, threading, time, urllib.request
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
WT = "/Users/bastotecnologia/.no-mistakes/worktrees/5a1fd3284f12/01M2S55JXF2EEMVPCAQTXN3X5G"
EV = "/Users/bastotecnologia/.no-mistakes/evidence/01M2S55JXF2EEMVPCAQTXN3X5G"
D = "/tmp/fmbridge-r2/run"; os.makedirs(D + "/cwd", exist_ok=True)
PUB, CTL, VIEW = "pub-r2", "ctl-r2", "view-r2"
open(D + "/tokens", "w").write("publish:%s\nsubscribe,control:%s\n%s\n" % (PUB, CTL, VIEW))
for n, t in (("view-token", VIEW), ("publish-token", PUB)): open(D + "/" + n, "w").write(t + "\n")
for f in ("tokens", "view-token", "publish-token"): os.chmod(D + "/" + f, 0o600)
s = socket.socket(); s.bind(("127.0.0.1", 0)); PORT = s.getsockname()[1]; s.close()
URL = "http://127.0.0.1:%d" % PORT
T0 = time.monotonic(); log = open(EV + "/r2-orchestrator-transcript.txt", "w")
procs, agents, lines, hub = [], {}, [], [None]
def say(m):
    l = "[%7.2fs] %s" % (time.monotonic() - T0, m); print(l, flush=True); log.write(l + "\n"); log.flush()
def wait_file(p, secs=15):
    end = time.time() + secs
    while time.time() < end:
        if os.path.exists(p) and os.path.getsize(p) > 0: return open(p).read().split()
        time.sleep(0.1)
    raise RuntimeError("timeout " + p)
def start_hub():
    r = "%s/hub-%d.ready" % (D, time.time_ns())
    p = subprocess.Popen([sys.executable, WT + "/bin/fm-stream-hub.py", "serve", "--bind", "127.0.0.1", "--port", str(PORT),
                          "--token-file", D + "/tokens", "--ready-file", r], stdout=open(D + "/hub.log", "a"), stderr=subprocess.STDOUT)
    procs.append(p); wait_file(r); hub[0] = p; say("hub up at %s" % URL)
def start_agent(m, l):
    r = "%s/agent-%s-%s-%d.ready" % (D, m, l, time.time_ns())
    p = subprocess.Popen([sys.executable, WT + "/bin/fm-stream-agent.py", "serve", "--hub", URL, "--token-file", D + "/publish-token",
                          "--machine", m, "--label", l, "--cwd", D + "/cwd", "--ready-file", r, "--state-interval", "1", "--poll-secs", "3"],
                         stdout=open("%s/agent-%s-%s.log" % (D, m, l), "a"), stderr=subprocess.STDOUT)
    procs.append(p); e = wait_file(r)[-1]; agents[m + "/" + l] = (p, e); say("agent %s/%s registered endpoint %s" % (m, l, e)); return e
def type_into(e, text):
    req = urllib.request.Request(URL + "/v1/tasks/%s/input" % e, method="POST", data=json.dumps({"text": text, "submit": True}).encode(),
                                 headers={"Authorization": "Bearer " + CTL, "Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=10).read(); say("typed %r into %s" % (text, e))
def listing():
    req = urllib.request.Request(URL + "/v1/tasks", headers={"Authorization": "Bearer " + VIEW})
    return [(t["machine"], t["label"], t["endpoint_id"][:8], t.get("closed_by"), t.get("exit_code"))
            for t in json.loads(urllib.request.urlopen(req, timeout=10).read())["tasks"]]
start_hub()
for m, l in (("box-a", "task-alpha"), ("box-a", "task-bravo"), ("box-b", "task-alpha")): start_agent(m, l)
bridge = subprocess.Popen([sys.executable, WT + "/bin/fm-stream-bridge.py", "serve", "--hub", URL, "--token-file", D + "/view-token",
                           "--fleet-id", "live-test"], stdout=subprocess.PIPE, stderr=open(EV + "/r2-serve-stderr.txt", "w"), text=True)
procs.append(bridge); say("bridge serve started pid %d" % bridge.pid)
tee = open(EV + "/r2-serve-feed.ndjson", "w")
def pump():
    for line in bridge.stdout: lines.append(line.strip()); tee.write(line); tee.flush()
threading.Thread(target=pump, daemon=True).start()
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        p = self.path; body = {"ok": True}
        try:
            if p.startswith("/records"):
                body = lines[int(p.split("from=")[1]) if "from=" in p else 0:]
            elif p.startswith("/act/exit/"):
                leaf, code = p[len("/act/exit/"):].rsplit("/", 1); type_into(agents[leaf.replace(":", "/")][1], "exit " + code)
            elif p.startswith("/act/agent/"):
                m, l = p[len("/act/agent/"):].split("/"); body = {"endpoint": start_agent(m, l)}
            elif p == "/act/hub-stop":
                hub[0].send_signal(signal.SIGTERM); hub[0].wait(10); say("hub stopped; bridge alive=%s" % (bridge.poll() is None))
            elif p == "/act/hub-start":
                start_hub()
            elif p == "/act/listing":
                body = listing(); say("hub lists %s" % body)
            elif p == "/act/status":
                body = {"bridge_alive": bridge.poll() is None, "records": len(lines)}; say("status %s" % body)
            elif p == "/act/mark":
                say("MARK " + self.headers.get("X-Mark", "")); body = {"records": len(lines)}
            else:
                self.send_response(404); self.end_headers(); return
        except Exception as exc:
            body = {"error": repr(exc)}
        data = json.dumps(body).encode()
        self.send_response(200); self.send_header("Access-Control-Allow-Origin", "*"); self.send_header("Content-Type", "application/json")
        self.end_headers(); self.wfile.write(data)
say("relay on 47827")
try: ThreadingHTTPServer(("127.0.0.1", 47827), H).serve_forever()
finally:
    for p in procs:
        if p.poll() is None: p.terminate()
