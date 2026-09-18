#!/usr/bin/env python3
"""Live driver for fm-stream-bridge.py: real hub, real agents on ptys, serve streaming."""
import json, os, signal, socket, subprocess, sys, time, urllib.request

WT = "/Users/bastotecnologia/.no-mistakes/worktrees/5a1fd3284f12/01M2S55JXF2EEMVPCAQTXN3X5G"
EV = "/Users/bastotecnologia/.no-mistakes/evidence/01M2S55JXF2EEMVPCAQTXN3X5G"
D = "/tmp/fmbridge-live/run"
os.makedirs(D, exist_ok=True)
os.makedirs(D + "/cwd", exist_ok=True)
PUB, CTL, VIEW = "pub-live", "ctl-live", "view-live"
open(D + "/tokens", "w").write("publish:%s\nsubscribe,control:%s\n%s\n" % (PUB, CTL, VIEW))
for name, tok in (("view-token", VIEW), ("publish-token", PUB)):
    open(D + "/" + name, "w").write(tok + "\n")
for f in ("tokens", "view-token", "publish-token"):
    os.chmod(D + "/" + f, 0o600)

s = socket.socket(); s.bind(("127.0.0.1", 0)); PORT = s.getsockname()[1]; s.close()
URL = "http://127.0.0.1:%d" % PORT
procs = []
log = open(EV + "/live-driver-transcript.txt", "w")

def say(msg):
    line = "[%7.2fs] %s" % (time.monotonic() - T0, msg)
    print(line, flush=True); log.write(line + "\n"); log.flush()

def wait_file(path, secs=15):
    end = time.time() + secs
    while time.time() < end:
        if os.path.exists(path) and os.path.getsize(path) > 0:
            return open(path).read().split()
        time.sleep(0.1)
    raise SystemExit("timed out waiting for " + path)

def start_hub(tag):
    ready = "%s/hub-%s.ready" % (D, tag)
    p = subprocess.Popen([sys.executable, WT + "/bin/fm-stream-hub.py", "serve", "--bind", "127.0.0.1",
                          "--port", str(PORT), "--token-file", D + "/tokens", "--ready-file", ready],
                         stdout=open("%s/hub-%s.log" % (D, tag), "w"), stderr=subprocess.STDOUT)
    procs.append(p); wait_file(ready); return p

def start_agent(machine, label):
    ready = "%s/agent-%s-%s-%d.ready" % (D, machine, label, time.time_ns())
    p = subprocess.Popen([sys.executable, WT + "/bin/fm-stream-agent.py", "serve", "--hub", URL,
                          "--token-file", D + "/publish-token", "--machine", machine, "--label", label,
                          "--cwd", D + "/cwd", "--ready-file", ready, "--state-interval", "1",
                          "--poll-secs", "3"],
                         stdout=open("%s/agent-%s-%s.log" % (D, machine, label), "a"), stderr=subprocess.STDOUT)
    procs.append(p)
    endpoint = wait_file(ready)[-1]
    say("agent %s/%s registered endpoint %s" % (machine, label, endpoint))
    return p, endpoint

def type_into(endpoint, text):
    req = urllib.request.Request(URL + "/v1/tasks/%s/input" % endpoint, method="POST",
                                 data=json.dumps({"text": text, "submit": True}).encode(),
                                 headers={"Authorization": "Bearer " + CTL, "Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=10).read()
    say("typed %r into %s" % (text, endpoint))

T0 = time.monotonic()
try:
    hub = start_hub("1")
    say("hub up at %s" % URL)
    a1, e_a1 = start_agent("box-a", "task-alpha")
    a2, e_a2 = start_agent("box-a", "task-bravo")
    b1, e_b1 = start_agent("box-b", "task-alpha")
    feed = open(EV + "/live-serve-feed.ndjson", "w")
    errf = open(EV + "/live-serve-stderr.txt", "w")
    bridge = subprocess.Popen([sys.executable, WT + "/bin/fm-stream-bridge.py", "serve", "--hub", URL,
                               "--token-file", D + "/view-token", "--fleet-id", "live-test"],
                              stdout=feed, stderr=errf)
    procs.append(bridge)
    say("bridge serve started (pid %d)" % bridge.pid)
    time.sleep(3)
    say("MARK phase=running-fleet")
    type_into(e_a2, "exit 0")
    type_into(e_b1, "exit 5")
    time.sleep(6)
    say("MARK phase=after-exits")
    # Relaunch box-a/task-bravo: the old endpoint stays listed as closed.
    a2b, e_a2b = start_agent("box-a", "task-bravo")
    time.sleep(3)
    say("MARK phase=after-relaunch")
    listing = json.loads(urllib.request.urlopen(urllib.request.Request(URL + "/v1/tasks", headers={"Authorization": "Bearer " + VIEW}), timeout=10).read())
    rows = [(t["machine"], t["label"], t["endpoint_id"][:8], t.get("closed_by"), t.get("exit_code")) for t in listing["tasks"]]
    say("hub /v1/tasks after relaunch lists: %s" % rows)
    # Hub outage mid-serve.
    hub.send_signal(signal.SIGTERM); hub.wait(10)
    say("hub stopped; bridge alive=%s" % (bridge.poll() is None))
    out_before = os.path.getsize(EV + "/live-serve-feed.ndjson")
    time.sleep(3)
    out_after = os.path.getsize(EV + "/live-serve-feed.ndjson")
    say("feed bytes during outage: before=%d after=%d (grew=%s); bridge alive=%s"
        % (out_before, out_after, out_after != out_before, bridge.poll() is None))
    hub = start_hub("2")
    say("hub restarted on the same port")
    time.sleep(2)
    listing = json.loads(urllib.request.urlopen(urllib.request.Request(URL + "/v1/tasks", headers={"Authorization": "Bearer " + VIEW}), timeout=10).read())
    say("restarted hub lists %d tasks" % len(listing["tasks"]))
    c1, e_c1 = start_agent("box-c", "task-charlie")
    time.sleep(3)
    say("MARK phase=after-hub-return; bridge alive=%s" % (bridge.poll() is None))
    bridge.send_signal(signal.SIGINT); bridge.wait(10)
    say("bridge stopped rc=%s" % bridge.returncode)
    json.dump({"endpoints": {"box-a/task-alpha": e_a1, "box-a/task-bravo(old)": e_a2,
                             "box-b/task-alpha": e_b1, "box-a/task-bravo(new)": e_a2b},
               "url": URL}, open(D + "/ids.json", "w"), indent=1)
finally:
    for p in procs:
        if p.poll() is None:
            p.terminate()
    for p in procs:
        try: p.wait(5)
        except Exception: p.kill()
