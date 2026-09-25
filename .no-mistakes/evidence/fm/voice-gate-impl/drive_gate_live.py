#!/usr/bin/env python3
"""One live fast-layer decision through the real helper and the real gateway.

Configures a throwaway home whose voice-gate-key-var names the real secrets
variable, makes two decisions (the first is the cold-start skip, the second is
a real vendor call through bin/voice-gate/jev-route.mjs under node), then runs
the operator's report and cost views over the same records. The key value is
never read into this process and never printed.
"""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path("/Users/bastotecnologia/.no-mistakes/worktrees/5a1fd3284f12/01M3BRKT89SJ4M6BA6HGX5MRX0")
EVIDENCE = pathlib.Path("/Users/bastotecnologia/.no-mistakes/evidence/01M3BRKT89SJ4M6BA6HGX5MRX0")
KEY_VAR = "DOCANA_VERCEL_AI_GATEWAY_KEY"

case = pathlib.Path(tempfile.mkdtemp(prefix="fm-gate-live-"))
(case / "config").mkdir()
(case / "state").mkdir()
(case / "config" / "voice-gate-key-var").write_text(KEY_VAR + "\n")
# The real helper path: no FM_VOICE_GATE_HELPER override, FM_VOICE_GATE_SECRETS
# left to default to ~/.secrets where the named variable lives.

sys.path.insert(0, str(ROOT / "bin"))
import fm_voice_gate as gate  # noqa: E402

out = open(EVIDENCE / "gate-live-decision-transcript.txt", "w")


def log(*a):
    print(*a, file=out, flush=True)


try:
    fast = gate.VoiceGate(str(case))
    log("gate enabled:", fast.enabled)
    first = fast.decide("hey, how is it going over there?", 10.0)
    log("decision 1 (cold start): route=%s why=%s calls=%d"
        % (first.route, first.why, first.calls))

    began = time.monotonic()
    second = fast.decide("hey, how is it going over there?", 10.0)
    took = time.monotonic() - began
    log("decision 2 (live call):   route=%s why=%s intent=%s "
        "needs_records=%s hand_over=%s answerable_fast=%s "
        "gate_ms=%s in_tok=%d out_tok=%d calls=%d outcome=%s (%.2fs wall)"
        % (second.route, second.why, second.intent, second.needs_records,
           second.hand_over, second.answerable_fast, second.gate_ms,
           second.in_tok, second.out_tok, second.calls, second.outcome, took))
    if second.line != "-":
        log("  pre-rendered line: %r" % second.line)

    usage = case / "state" / "voice-gate" / "usage.log"
    log("usage.log rows:")
    for line in usage.read_text().splitlines():
        log("  %s" % line)

    for cmd in ("report", "cost"):
        run = subprocess.run(
            [sys.executable, str(ROOT / "bin" / "fm_voice_gate.py"), cmd,
             "--home", str(case)],
            capture_output=True, text=True, timeout=30)
        log("$ fm_voice_gate.py %s --home <case>" % cmd)
        for line in run.stdout.splitlines():
            log("  %s" % line)
        if run.stderr.strip():
            log("  stderr: %s" % run.stderr.strip())

    live_ok = (first.why == "cold-start" and first.calls == 0
               and second.route in gate.ROUTES and second.calls == 1
               and second.in_tok > 0 and second.gate_ms > 0)
    log("LIVE_OK=%s" % live_ok)
finally:
    shutil.rmtree(case, ignore_errors=True)
