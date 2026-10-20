#!/usr/bin/env python3
"""Offline stand-in for `deck run` used by tests/fm-specialist.test.sh and
tests/fm-group.test.sh.

It keeps a per-session prompt log under $DECK_STATE/sessions/<id>.json so a
test can prove a later turn resumed the same session, writes RESULT_FILE (and
appends to MEMORY_FILE) named in the prompt, runs the pre_complete hook the way
deck does (exit 2 refuses), and records concurrency in $STUB_RUNNING_DIR.
STUB_SLEEP delays each run; STUB_MODE=hang never finishes; STUB_MODE=lazy
writes nothing so the hook refuses; STUB_MODE=tool-fail replays one failed
run_command through post_tool_use hooks, logs the next pre_tool_use hook's exit
to gate.log, then writes nothing.
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
prompt = sys.stdin.read() if args[1] == "-" else args[1]
session = None
ephemeral = "--ephemeral" in args
tool_concurrency = None
hooks = []
i = 2
while i < len(args):
    if args[i] == "--session":
        session = args[i + 1]
        i += 2
    elif args[i] == "--tool-concurrency":
        tool_concurrency = int(args[i + 1])
        i += 2
    elif args[i] == "--hook":
        hooks.append(args[i + 1])
        i += 2
    else:
        i += 1

state = Path(os.environ.get("DECK_STATE", Path.cwd() / "deck-state"))
sessions = state / "sessions"
sessions.mkdir(parents=True, exist_ok=True)
log = state / "argv.jsonl"
with open(log, "a") as fh:
    fh.write(json.dumps({"session": session, "ephemeral": ephemeral, "cwd": os.getcwd(),
                         "tool_concurrency": tool_concurrency,
                         "pid": os.getpid(), "stdin_prompt": args[1] == "-", "prompt_bytes": len(prompt.encode()),
                         "environment": {"gh_token": "GH_TOKEN" in os.environ,
                                         "gateway_key": "PROXAI_API_KEY" in os.environ or "PROXAI_API_KEY_FILE" in os.environ,
                                         "allowed": os.environ.get("CREW_ALLOWED_TEST"),
                                         "empty": os.environ.get("CREW_EMPTY_TEST"),
                                         "unset": "CREW_UNSET_TEST" in os.environ,
                                         "home": os.environ.get("HOME"), "path": os.environ.get("PATH")},
                         "skills": str((Path.cwd() / ".agents" / "skills").resolve())}) + "\n")

turns = []
if session:
    path = sessions / f"{session}.json"
    if path.exists():
        turns = json.loads(path.read_text())
print(json.dumps({"type": "run_started", "session": session or "ephemeral"}), flush=True)
if os.environ.get("STUB_REMOVE_LAUNCHER"):
    Path(os.environ["FM_DECK_BIN"]).unlink(missing_ok=True)

running = Path(os.environ.get("STUB_RUNNING_DIR", state / "running"))
running.mkdir(parents=True, exist_ok=True)
me = running / str(os.getpid())
me.write_text("")
with open(state / "concurrency.log", "a") as fh:
    fh.write(f"{len(list(running.iterdir()))}\n")
try:
    mode = os.environ.get("STUB_MODE", "")
    if prompt.startswith("You merge"):
        mode = os.environ.get("STUB_MERGE_MODE", mode)
    if mode == "hang":
        while True:
            time.sleep(1)
    time.sleep(float(os.environ.get("STUB_SLEEP", "0")))
    if mode == "fail":
        sys.exit(1)

    def field(name):
        m = re.search(rf"^{name}: (.+)$", prompt, re.M)
        return Path(m.group(1).strip()) if m else None

    result = field("RESULT_FILE")
    memory = field("MEMORY_FILE")
    if mode == "tool-fail":
        # Replay one failed run_command through the hooks, then try another tool.
        failed = {"hook_event_name": "post_tool_use", "tool_name": "run_command", "args": {"command": "psql -c 'select stopReason'"},
                  "tool_output": json.dumps({"exit_code": 1, "stderr": "ERROR: column stopReason does not exist (42703)", "stdout": "", "timed_out": False})}
        nxt = {"hook_event_name": "pre_tool_use", "tool_name": "run_command", "args": {"command": "curl https://example.invalid"}}
        for hook in hooks:
            event, _, cmd = hook.partition("=")
            if event == "post_tool_use":
                subprocess.run(cmd, shell=True, input=json.dumps(failed), text=True)
        for hook in hooks:
            event, _, cmd = hook.partition("=")
            if event == "pre_tool_use":
                rc = subprocess.run(cmd, shell=True, input=json.dumps(nxt), text=True, capture_output=True).returncode
                with open(state / "gate.log", "a") as fh:
                    fh.write(f"{rc}\n")
        mode = "lazy"
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
            if os.environ.get("STUB_RESULT_BYTES"):
                with open(result, "a") as fh:
                    fh.write("e" * int(os.environ["STUB_RESULT_BYTES"]) + "\n")
        if memory and job and mode != "result-only":
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
