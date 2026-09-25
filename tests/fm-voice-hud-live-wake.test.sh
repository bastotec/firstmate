#!/usr/bin/env bash
# tests/fm-voice-hud-live-wake.test.sh - the spoken HUD's wake loop, live.
#
# The one proof the offline rig cannot give: real audio from the machine's
# own microphone and speakers driving the shipped wake path end to end -
# the wake word spoken aloud, the local decoder transcribing it, the wake
# gate opening a session, the turn routing to the engine only after the
# wake, the turn ending when speech stops (the room's own tone returning),
# and the reply coming back through the wire. The model brain behind the
# relay is a stub that speaks the real frame wire, so the loop runs live
# without opening a paid model session; the real-model reply stays the
# captain's own live drive.
#
# Opt-in because it makes noise and needs ears: FM_VOICE_HUD_LIVE=1 (or
# FM_LIVE=1). Skips cleanly where sounddevice, numpy or faster-whisper is
# not importable by this python3 (pip install sounddevice numpy
# faster-whisper per docs/voice-relay.md), where say does not exist, where
# no input device exists, or where the device delivers nothing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v say >/dev/null 2>&1 || { echo "skip: say not found (macOS only)"; exit 0; }

fm_live_gate opt-in FM_VOICE_HUD_LIVE python3

TMP_ROOT=$(fm_test_tmproot fm-voice-hud-live-wake)

TMP_WAKE="$TMP_ROOT/live-wake"
mkdir -p "$TMP_WAKE"

# The stub relay: the real frame wire, one canned turn - transcript, reply
# audio, reply_end - so the loop completes without a paid model session.
cat > "$TMP_WAKE/stub-relay.py" <<'STUBPY'
import sys
sys.path.insert(0, sys.argv[1])
import fm_voice_frame as frame
import os
sys.stdout.buffer.write(frame.MAGIC)
sys.stdout.buffer.flush()
out = frame.Writer(sys.stdout.buffer)
out.send_json(frame.NOTICE, {"event": "ready", "model": "stub",
                             "read_scope": "counts"})
reader = frame.Reader(sys.stdin.buffer)
while True:
    got = reader.read()
    if got is None:
        break
    kind, payload = got
    if kind == frame.TALK_END:
        out.send_json(frame.TEXT, {"role": "USER", "text": "stub heard you"})
        out.send(frame.AUDIO, b"\x01\x02" * 240)
        out.send_json(frame.MARK, {"mark": "reply_end",
                                   "since_talk_end": 0.1})
    elif kind == frame.QUIT:
        break
try:
    out.send(frame.BYE)
except BrokenPipeError:
    pass
STUBPY

# A real local decoder for the HUD's pluggable contract: PCM blocks in on
# stdin, one final transcript line per utterance out on stdout. The
# director sends only voiced listening-phase blocks, so an utterance's
# trailing silence arrives as a drought in the input, not as samples: a
# 0.7s gap with no data is the utterance boundary (the director's own gate
# stops sending 0.6s after the last voiced block), and the line is written
# the moment the utterance ends so the next loud block can poll it.
cat > "$TMP_WAKE/decoder.py" <<'DECPY'
import os
import select
import sys

import numpy as np
from faster_whisper import WhisperModel

BLOCK = 3200
model = WhisperModel(os.environ.get("FM_DECODER_MODEL", "base.en"),
                     device="cpu", compute_type="int8")
# Warm the first transcribe too, so the ready line below means the whole
# stack is hot and every later utterance answers at steady-state speed.
model.transcribe(np.zeros(1600, dtype=np.float32), language="en")
print("decoder ready", file=sys.stderr)

utterance = bytearray()

def finalize():
    global utterance
    if not utterance:
        return None
    audio = np.frombuffer(bytes(utterance), dtype="<i2") \
        .astype(np.float32) / 32768.0
    utterance = bytearray()
    segs, _ = model.transcribe(audio, language="en", beam_size=1,
                               vad_filter=False,
                               condition_on_previous_text=False)
    return " ".join(s.text.strip() for s in segs).strip() or None

def emit_line():
    text = finalize()
    if text:
        sys.stdout.write(text + "\n")
        sys.stdout.flush()

stdin = sys.stdin.buffer
while True:
    ready, _, _ = select.select([stdin], [], [], 0.7)
    if not ready:
        emit_line()                    # the drought that ends an utterance
        continue
    block = stdin.read(BLOCK)
    if not block:
        break
    utterance.extend(block)
emit_line()
DECPY

python3 - "$ROOT" "$TMP_WAKE" <<'PY' || fail "live wake loop"
import json
import os
import subprocess
import sys
import threading
import time

root, tmp = sys.argv[1], sys.argv[2]

try:
    import faster_whisper                # noqa: F401
    import sounddevice                   # noqa: F401
except ImportError as exc:
    print("skip: live: this python3 cannot import the live stack ({}); "
          "pip install sounddevice numpy faster-whisper".format(exc))
    sys.exit(0)

inputs = [d for d in sounddevice.query_devices()
          if d.get("max_input_channels", 0) > 0]
if not inputs:
    print("skip: live: no input device on this machine")
    sys.exit(0)

def fail_now(msg):
    print("live wake: " + msg)
    print("wire events seen: " + repr(events))
    sys.exit(1)

env = dict(os.environ)
env["FM_VOICE_HUD_DECODER"] = "{} {}".format(
    sys.executable, os.path.join(tmp, "decoder.py"))

errfile = open(os.path.join(tmp, "bridge.err"), "w")
errpath = os.path.join(tmp, "bridge.err")
proc = subprocess.Popen(
    [sys.executable, os.path.join(root, "hud", "fm_voice_hud_bridge.py"),
     "--stub-relay", os.path.join(tmp, "stub-relay.py")],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=errfile, env=env)

events = []
def read_wire():
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except ValueError:
            events.append({"type": "raw", "text": line})
thread = threading.Thread(target=read_wire, daemon=True)
thread.start()

def wait_for(predicate, timeout, what):
    """Wait until an event satisfying predicate arrives; newest wins."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        if proc.poll() is not None:
            fail_now("the bridge died mid-loop (exit {})".format(
                proc.returncode))
        time.sleep(0.1)
    fail_now("timed out waiting for " + what)

def saw(type_=None, **kw):
    def pred():
        for e in reversed(events):
            if type_ is not None and e.get("type") != type_:
                continue
            if all(e.get(k) == v for k, v in kw.items()):
                return True
        return False
    return pred

try:
    # The bridge, the decoder model and the say voice all have cold starts;
    # wait for each by name instead of guessing delays, so the loop below
    # runs against a hot stack.
    wait_for(saw(type_="mic"), 20, "the first mic level from the real mic")
    warm = subprocess.run(["say", "ready"])
    if warm.returncode != 0:
        print("skip: live: say cannot speak on this machine")
        raise SystemExit(0)
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        try:
            if "decoder ready" in open(errpath).read():
                break
        except OSError:
            pass
        if proc.poll() is not None:
            fail_now("the bridge died while the decoder loaded")
        time.sleep(0.5)
    else:
        fail_now("the decoder never reported ready")

    # The wake word, spoken aloud per the usage contract: the word, a
    # pause, then the command.
    subprocess.run(["say", "Ziggy"])
    time.sleep(2.5)
    subprocess.run(["say", "what time is it in Lisbon right now"])

    wait_for(saw(type_="notice", event="wake"), 60,
             "the wake after speaking the wake word")
    if saw(type_="notice", event="no-speech")():
        fail_now("the wake armed but no speech followed it")

    wait_for(saw(type_="mic", gate="in-turn"), 40,
             "the turn opening on the command's speech")

    wait_for(saw(type_="transcript", text="stub heard you"), 30,
             "the reply transcript through the relay wire")

    wait_for(saw(type_="state", state="listening"), 30,
             "the HUD back to listening after the reply")

    # The turn must have ended on quiet while the room kept talking its
    # usual tone: the gate left in-turn and came back through listening.
    gates = [e.get("gate") for e in events if e.get("type") == "mic"]
    states = [e.get("state") for e in events if e.get("type") == "state"]
    if "in-turn" not in gates:
        fail_now("the command never routed to the engine")
    if states[-1] != "listening":
        fail_now("the HUD did not return to listening: " + repr(states))
    if "thinking" not in states:
        fail_now("the turn never showed as thinking: " + repr(states))
    print("live: gates " + "->".join(
        g for i, g in enumerate(gates) if i == 0 or g != gates[i - 1]))
    print("live: states " + "->".join(
        s for i, s in enumerate(states) if i == 0 or s != states[i - 1]))
finally:
    try:
        proc.stdin.write(b"quit\n")
        proc.stdin.flush()
    except (BrokenPipeError, OSError):
        pass
    try:
        rc = proc.wait(timeout=45)
    except subprocess.TimeoutExpired:
        proc.kill()
        rc = proc.wait()
    errfile.close()
print("live: the spoken loop ran - wake word heard, turn routed after "
      "the wake, ended on quiet, reply back on the wire (stub model), "
      "bridge exit {}".format(rc))
if rc != 0:
    fail_now("the bridge must exit zero on a clean quit")
PY
pass "the spoken HUD's wake loop runs live on real audio"
