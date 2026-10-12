#!/usr/bin/env python3
"""Offline stand-in for `deck run` used by tests/fm-specialist.test.sh and
tests/fm-group.test.sh.

It keeps a per-session prompt log under $DECK_STATE/sessions/<id>.json so a
test can prove a later turn resumed the same session, writes RESULT_FILE (and
appends to MEMORY_FILE) named in the prompt, runs the pre_complete hook the way
deck does (exit 2 refuses), and records concurrency in $STUB_RUNNING_DIR.
STUB_SLEEP delays each run; STUB_MODE=hang never finishes; STUB_MODE=lazy
writes nothing so the hook refuses.
"""
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

args = sys.argv[1:]
if not args or args[0] != "run":
    sys.exit(0)
prompt = args[1]
session = None
ephemeral = "--ephemeral" in args
hooks = []
i = 2
while i < len(args):
    if args[i] == "--session":
        session = args[i + 1]
        i += 2
    elif args[i] == "--hook":
        hooks.append(args[i + 1])
        i += 2
    else:
        i += 1

state = Path(os.environ["DECK_STATE"])
sessions = state / "sessions"
sessions.mkdir(parents=True, exist_ok=True)
log = state / "argv.jsonl"
with open(log, "a") as fh:
    fh.write(json.dumps({"session": session, "ephemeral": ephemeral, "cwd": os.getcwd(),
                         "skills": os.environ.get("DECK_SKILLS_DIRS")}) + "\n")

turns = []
if session:
    path = sessions / f"{session}.json"
    if path.exists():
        turns = json.loads(path.read_text())
print(json.dumps({"type": "run_started", "session": session or "ephemeral"}), flush=True)

running = Path(os.environ.get("STUB_RUNNING_DIR", state / "running"))
running.mkdir(parents=True, exist_ok=True)
me = running / str(os.getpid())
me.write_text("")
with open(state / "concurrency.log", "a") as fh:
    fh.write(f"{len(list(running.iterdir()))}\n")
try:
    mode = os.environ.get("STUB_MODE", "")
    if mode == "hang":
        while True:
            time.sleep(1)
    time.sleep(float(os.environ.get("STUB_SLEEP", "0")))

    def field(name):
        m = re.search(rf"^{name}: (.+)$", prompt, re.M)
        return Path(m.group(1).strip()) if m else None

    result = field("RESULT_FILE")
    memory = field("MEMORY_FILE")
    job = re.search(r"^Job: (\S+)$", prompt, re.M)
    if mode != "lazy" and result:
        if prompt.startswith("You merge"):
            n = len(re.findall(r"^### Member ", prompt, re.M))
            result.write_text(f"merged {n} member results\nrecommended decision: stub\n")
        else:
            earlier = [re.search(r"^Job: (\S+)$", t, re.M) for t in turns]
            earlier = [m.group(1) for m in earlier if m]
            seen = "learned in" in prompt
            angle = re.search(r"## Your angle\n\n(.+)", prompt)
            result.write_text(
                f"turns-in-session: {len(turns) + 1}\n"
                f"earlier-jobs: {','.join(earlier)}\n"
                f"memory-seen-at-start: {'yes' if seen else 'no'}\n"
                f"angle: {angle.group(1) if angle else ''}\n"
            )
        if memory and job:
            with open(memory, "a") as fh:
                fh.write(f"- learned in {job.group(1)}\n")
    for hook in hooks:
        event, _, cmd = hook.partition("=")
        if event == "pre_complete":
            rc = subprocess.run(cmd, shell=True).returncode
            if rc == 2:
                print(json.dumps({"type": "run_stopped", "reason": "pre_complete refused"}), flush=True)
                sys.exit(1)
    if session:
        turns.append(prompt)
        (sessions / f"{session}.json").write_text(json.dumps(turns))
    print(json.dumps({"type": "run_finished"}), flush=True)
finally:
    me.unlink(missing_ok=True)
