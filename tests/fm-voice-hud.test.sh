#!/usr/bin/env bash
# tests/fm-voice-hud.test.sh - the spoken HUD's wake gate, engine wiring and states.
#
# Every case here runs offline. The HUD's guarantees are offline properties:
# the wake gate keeps the microphone local until the wake word fires, the
# engine wiring speaks the relay's frame wire exactly (verified against a stub
# relay, never a live model), and the HUD state machine transitions on the
# events it can synthesize. What cannot be verified without the captain's Mac
# - drag, always-on-top against real windows, lived wake-word feel - is named
# in the PR body as hands-on items, not asserted here.
#
# The stub relay speaks the real wire: MAGIC, ready notice, reply audio,
# transcripts, the reply_end mark that completes a turn, and BYE on quit. A
# stub proves the engine's side of the contract; it cannot prove the relay's,
# which tests/fm-voice-relay.test.sh already owns.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-voice-hud)

# --- the wake gate -----------------------------------------------------------
#
# Two offline gates: an energy gate that decides when speech exists at all, and
# a keyword match over locally decoded text. Silence never becomes a transcript
# and quiet speech without the word never wakes the HUD.

python3 - "$ROOT" <<'PY' || fail "wake gate"
import importlib.util, os, struct, sys
spec = importlib.util.spec_from_file_location(
    "wake", os.path.join(sys.argv[1], "hud", "fm_voice_wake.py"))
wake = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wake)

def check(cond, label):
    if not cond:
        sys.exit("wake: " + label)

# 100 ms of 16 kHz 16-bit mono.
BLOCK = 3200
def tone(freq=440, amp=12000, blocks=1):
    import math
    out = bytearray()
    rate = 16000
    for b in range(blocks):
        for i in range(BLOCK // 2):
            v = int(amp * math.sin(2 * math.pi * freq * i / rate))
            out += struct.pack("<h", v)
    return bytes(out)

silence = bytes(BLOCK)
loud = tone(blocks=1)

gate = wake.EnergyGate()
check(not gate.feed(silence, 0.0), "silence must never count as speech")
check(gate.feed(loud, 0.1), "speech above the floor must count as voiced")
check(gate.active(0.1 + wake.HANGOVER_SECONDS / 2), "hangover must hold the channel open through a pause")
check(not gate.active(0.1 + wake.HANGOVER_SECONDS * 2), "hangover must close after the quiet bound")

listener = wake.KeywordListener()
check(listener.feed("hey Ziggy"), "the wake word must wake")
check(not listener.feed("what time is it"), "a question without the word must not wake")
check(not listener.feed("I love ziggywithnospaces"), "the word must match as a whole word")
check(listener.feed("Ziggie, can you help"), "an observed mishearing must wake")
check(not listener.feed(""), "empty text must not wake")

# A loud clip clears the energy floor and silence does not: the two gates are
# independent and the fixture is internally consistent.
check(wake.block_energy(loud) > wake.ENERGY_FLOOR, "the test tone must clear the floor")
check(wake.block_energy(silence) < wake.ENERGY_FLOOR, "silence must sit below the floor")
PY
pass "the wake gate keeps silence quiet and wakes only on the word"

# --- the energy gate in a real room -------------------------------------------
#
# The absolute floor assumes a quiet machine, and a real one is not: the
# captain's MacBook measures about 2.5e5 mean square of idle room tone
# (an AGC-managed laptop microphone), a hundred times ENERGY_FLOOR. On that
# machine a gate fixed at the absolute floor calls the room itself speech:
# the decoder is fed forever and a turn, once open, never sees the quiet
# that ends it - the HUD listens and never answers. The gate must learn the
# room: sustained tone becomes the floor, speech must clear it, a room that
# quiets down must not stay deaf, and the turn must end when the room
# returns after speech.

python3 - "$ROOT" <<'PY' || fail "energy gate tracks the real room"
import importlib.util, math, os, random, struct, sys
spec = importlib.util.spec_from_file_location(
    "wake", os.path.join(sys.argv[1], "hud", "fm_voice_wake.py"))
wake = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wake)

sys.path.insert(0, os.path.join(sys.argv[1], "hud"))
import importlib
mic_mod = importlib.import_module("fm_voice_mic")

def check(cond, label):
    if not cond:
        sys.exit("room gate: " + label)

random.seed(7)
BLOCK = 3200

def room(rms=500, blocks=1):
    # Gaussian noise whose mean square sits where the captain's MacBook's
    # idle room does: rms 500 -> about 2.5e5, a hundred times ENERGY_FLOOR.
    out = bytearray()
    for _ in range(blocks):
        out += struct.pack("<1600h",
                           *(int(random.gauss(0, rms)) for _ in range(1600)))
    return bytes(out)

def tone(amp=12000, blocks=1):
    out = bytearray()
    for _ in range(blocks):
        out += struct.pack("<1600h",
                           *(int(amp * math.sin(2 * math.pi * 440 * i / 16000))
                             for i in range(1600)))
    return bytes(out)

# Sustained room tone must stop counting as speech: a cold start measures
# with the absolute floor, then adopts the sustained level as the room.
gate = wake.EnergyGate()
voiced = [gate.feed(room(), 0.1 * i) for i in range(40)]
check(voiced[0], "a cold start must still measure before it judges")
check(not voiced[35], "a real room's floor must not count as speech")
check(gate.floor > 4 * wake.ENERGY_FLOOR,
      "the tracked floor must sit above the quiet-room minimum")

# Speech in that room is still voiced, and the channel holds through a
# single sub-floor dip (microphone AGC pulls speech down mid-word).
check(gate.feed(tone(), 4.1), "speech must clear the tracked room floor")
check(gate.feed(room(), 4.2), "a dip inside speech is quiet, not speech")
check(gate.active(4.2 + wake.HANGOVER_SECONDS / 2),
      "the hangover must hold the channel across a dip")

# A room that quiets down must not stay deaf: after real silence, audio far
# above ENERGY_FLOOR but below the loud room's threshold is speech again.
for i in range(44, 64):
    gate.feed(bytes(BLOCK), 0.1 * i)
check(gate.feed(room(rms=80), 6.5),
      "a quieter room must re-open the gate's sensitivity")

# The lifecycle the gate exists for, in that same loud room: the wake opens
# the turn and the RETURN OF ROOM TONE ends it - the end on quiet a fixed
# floor can never reach on a real machine.
class ScriptedDecoder:
    """A scripted per-utterance decoder. It counts only speech-level audio
    toward an utterance - room tone is noise to a real VAD - and lands the
    final line once the utterance has run."""
    def __init__(self, lines):
        self.lines = list(lines)
        self._run = 0
    def start(self):
        pass
    def feed(self, block):
        if wake.block_energy(block) >= 1e6:
            self._run += 1
        return []
    def poll_transcripts(self):
        if self.lines and self._run >= 3:
            self._run = 0
            return [self.lines.pop(0)]
        return []
    def close(self):
        pass

class ScriptedEngine:
    def __init__(self):
        self.begun = 0
        self.ended = 0
    def begin_turn(self):
        self.begun += 1
    def feed(self, pcm):
        pass
    def end_turn(self):
        self.ended += 1

gate2 = wake.EnergyGate()
engine = ScriptedEngine()
director = mic_mod.TurnDirector(
    engine, gate2, wake.KeywordListener(),
    ScriptedDecoder(["Ziggy"]))
for i in range(30):                      # the loud room, learned as the floor
    director.feed(room(), 0.1 * i)
check(engine.begun == 0, "the loud room alone must never open a turn")
t = 3.0
for i in range(6):                       # the wake word, spoken in that room
    director.feed(tone(), t)
    t += 0.1
check(engine.begun == 1, "speech in the loud room must open the turn")
closed = False
for i in range(20):                      # speech stops; the room remains
    director.feed(room(), t)
    t += 0.1
    if engine.ended == 1:
        closed = True
        break
check(closed, "the turn must end when speech stops and the room remains")
PY
pass "the energy gate learns the real room so turns can end"

# --- wake detection over the committed PCM clips ------------------------------
#
# The brief's offline detector check: fixed clips containing and lacking the
# keyword, asserting detect/no-detect. The clips are committed 16 kHz mono
# 16-bit LE PCM: one with real speech-band energy, one pure silence, one quiet
# room tone. Energy is the gate half that can be asserted on real bytes; the
# keyword half needs a transcript, so the decoded-text path is exercised with
# and without the word.

python3 - "$ROOT" <<'PY' || fail "wake PCM clips"
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location(
    "wake", os.path.join(sys.argv[1], "hud", "fm_voice_wake.py"))
wake = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wake)

def check(cond, label):
    if not cond:
        sys.exit("wake clips: " + label)

BLOCK = 3200
def voiced_blocks(path):
    pcm = open(path, "rb").read()
    return sum(1 for i in range(0, len(pcm) - BLOCK + 1, BLOCK)
               if wake.block_energy(pcm[i:i + BLOCK]) >= wake.ENERGY_FLOOR)

assets = os.path.join(sys.argv[1], "tests", "assets")
speech = os.path.join(assets, "voice-hud-speech.pcm")
silence = os.path.join(assets, "voice-hud-silence.pcm")
quiet = os.path.join(assets, "voice-hud-quiet.pcm")

# The speech clip is voiced somewhere; silence and room tone are not voiced at
# all. This is the gate half of the guarantee that the microphone is not
# streaming anywhere until the wake word fires.
check(voiced_blocks(speech) > 0, "the speech clip must contain voiced blocks")
check(voiced_blocks(silence) == 0, "the silence clip must never be voiced")
check(voiced_blocks(quiet) == 0, "the quiet clip must never be voiced")

# The keyword half: a transcript with the word wakes, the same words without
# the word do not, and no amount of silence produces a transcript at all.
listener = wake.KeywordListener()
check(listener.feed("Ziggy, what's on my plate today"), "speech clip transcript must wake")
check(not listener.feed("what's on my plate today"), "the same words without the word must not wake")
check(not listener.feed(""), "silence must never produce a transcript")
PY
pass "wake detection fires on the speech clip and stays quiet on silence and room tone"

# --- the engine wiring against a stub relay -----------------------------------
#
# The engine spawns the relay as a child and speaks the frame wire. A stub
# relay proves this side of the contract: the MAGIC handshake, the ready
# notice, one S/A/E turn whose audio and reply_end mark come back in order,
# the QUIT/BYE close. The real relay's side is owned by
# tests/fm-voice-relay.test.sh.

STUB="$TMP_ROOT/stub-relay.py"
cat > "$STUB" <<'STUBPY'
import sys
sys.path.insert(0, sys.argv[1])
import fm_voice_frame as frame
import time

sys.stdout.buffer.write(frame.MAGIC)
sys.stdout.buffer.flush()
out = frame.Writer(sys.stdout.buffer)

def notice(event, **kw):
    obj = {"event": event}
    obj.update(kw)
    out.send_json(frame.NOTICE, obj)

notice("ready", model="stub", read_scope="counts")

reader = frame.Reader(sys.stdin.buffer)
saw_start = False
audio_bytes = 0
while True:
    got = reader.read()
    if got is None:
        break
    kind, payload = got
    if kind == frame.TALK_START:
        saw_start = True
    elif kind == frame.AUDIO:
        audio_bytes += len(payload)
    elif kind == frame.TALK_END:
        # One full turn, in wire order: transcript of what was heard, reply
        # audio, the reply_end mark that completes the turn.
        out.send_json(frame.TEXT, {"role": "USER", "text": "stub heard you"})
        out.send(frame.AUDIO, b"\x01\x02" * 240)
        out.send_json(frame.MARK, {"mark": "reply_end", "since_talk_end": 0.1})
    elif kind == frame.QUIT:
        break
try:
    out.send(frame.BYE)
except BrokenPipeError:
    pass
STUBPY

python3 - "$ROOT" "$STUB" <<'PY' || fail "engine wiring"
import importlib.util, os, sys, threading, time
root, stub = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "engine", os.path.join(root, "hud", "fm_voice_engine.py"))
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)

def check(cond, label):
    if not cond:
        sys.exit("engine: " + label)

states = []
audio = []
transcripts = []
notices = []

eng = engine.Engine(
    [sys.executable, stub, os.path.join(root, "bin")],
    ready_timeout=10,
    on_state=states.append,
    on_audio=audio.append,
    on_transcript=lambda role, text: transcripts.append((role, text)),
    on_notice=lambda event, obj: notices.append((event, obj)))
eng.start()
check(eng.ready.is_set(), "the stub relay must report ready")
check(eng.ready_notice.get("model") == "stub", "the ready notice must carry the model")

eng.begin_turn()
eng.feed(b"\x01\x02" * 320)
turn = eng.end_turn(timeout=10)
check(turn == 1, "the first turn must be id 1")
check(transcripts == [("USER", "stub heard you")], "the transcript must arrive")
check(sum(len(a) for a in audio) == 480, "the reply audio must arrive whole")
check(states == ["thinking", "speaking", "listening"], "the states must transition in order: " + repr(states))
check(not eng.closed.is_set(), "the engine must stay open after one turn")

eng.close()
check(eng.closed.is_set(), "close must mark the engine closed")
check(eng.proc.poll() is not None, "the relay child must be reaped")
PY
pass "the engine wiring speaks the frame wire against a stub relay"

# --- a failed turn releases the waiter, promptly and with its reason --------
#
# The relay's own failure path: the model stream breaks mid-turn and the
# relay says turn-failed while staying alive. That notice is the only thing
# that releases a client waiting for a reply, so the engine must bring its
# waiter back at once - not burn the whole turn timeout - and carry the
# failure to the HUD's notice wire.

STUB_FAIL="$TMP_ROOT/stub-fail-relay.py"
cat > "$STUB_FAIL" <<'STUBFAIL'
import sys
sys.path.insert(0, sys.argv[1])
import fm_voice_frame as frame

sys.stdout.buffer.write(frame.MAGIC)
sys.stdout.buffer.flush()
out = frame.Writer(sys.stdout.buffer)
out.send_json(frame.NOTICE, {"event": "ready", "model": "stub"})

reader = frame.Reader(sys.stdin.buffer)
while True:
    got = reader.read()
    if got is None:
        break
    kind, payload = got
    if kind == frame.TALK_END:
        # The turn dies without an answer and without the reply_end mark.
        out.send_json(frame.NOTICE, {
            "event": "turn-failed",
            "error": "RuntimeError: the model stream broke"})
    elif kind == frame.QUIT:
        break
try:
    out.send(frame.BYE)
except BrokenPipeError:
    pass
STUBFAIL

python3 - "$ROOT" "$STUB_FAIL" <<'PY' || fail "turn-failed release"
import importlib.util, os, sys, time
root, stub = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "engine", os.path.join(root, "hud", "fm_voice_engine.py"))
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)

states = []
notices = []
eng = engine.Engine(
    [sys.executable, stub, os.path.join(root, "bin")],
    ready_timeout=10,
    on_state=states.append,
    on_notice=lambda event, obj: notices.append((event, obj)))
eng.start()

eng.begin_turn()
eng.feed(b"\x01\x02" * 320)
t0 = time.monotonic()
try:
    turn = eng.end_turn(timeout=8)
except engine.EngineError as exc:
    sys.exit("turn-failed: the waiter burned its timeout on a failed turn: "
             + str(exc))
elapsed = time.monotonic() - t0
if elapsed > 5:
    sys.exit("turn-failed: the release must be prompt, took {:.1f}s".format(
        elapsed))
if turn != 1:
    sys.exit("turn-failed: the released turn must be id 1: " + str(turn))
if states != ["thinking", "listening"]:
    sys.exit("turn-failed: the states must return to listening: "
             + repr(states))
if not any(event == "turn-failed"
           and obj.get("error") == "RuntimeError: the model stream broke"
           for event, obj in notices):
    sys.exit("turn-failed: the notice must carry the reason: " + repr(notices))
if eng.closed.is_set():
    sys.exit("turn-failed: a failed turn must not close the engine")

# The relay stayed alive and renews: the next turn opens on the same wire.
eng.begin_turn()
eng.feed(b"\x01\x02" * 320)
t0 = time.monotonic()
try:
    turn = eng.end_turn(timeout=8)
except engine.EngineError as exc:
    sys.exit("turn-failed: the second turn must also be released: " + str(exc))
if turn != 2:
    sys.exit("turn-failed: the second turn must be id 2: " + str(turn))

eng.close()
PY
pass "a relay turn-failed notice releases the waiter promptly with its reason"

# --- a mid-turn failure releases the turn the captain still holds -------------
#
# The relay's failure flow fires mid-turn, before the captain stops talking:
# the notice releases the open turn, and the relay then drops the late
# TALK_END on its spent session. end_turn must not erase that delivered
# release - the mic thread comes back at once instead of waiting out the
# full turn timeout on a wire that will never answer.

STUB_MIDFAIL="$TMP_ROOT/stub-midfail-relay.py"
cat > "$STUB_MIDFAIL" <<'STUBMID'
import sys
sys.path.insert(0, sys.argv[1])
import fm_voice_frame as frame

sys.stdout.buffer.write(frame.MAGIC)
sys.stdout.buffer.flush()
out = frame.Writer(sys.stdout.buffer)
out.send_json(frame.NOTICE, {"event": "ready", "model": "stub"})

failed = False
reader = frame.Reader(sys.stdin.buffer)
while True:
    got = reader.read()
    if got is None:
        break
    kind, payload = got
    if kind == frame.TALK_START:
        # A new talk key renews the spent session, as the relay documents.
        failed = False
    elif kind == frame.AUDIO and not failed:
        # The model stream breaks mid-turn: the failure is named while the
        # relay stays alive, and the session is spent from here.
        failed = True
        out.send_json(frame.NOTICE, {
            "event": "turn-failed",
            "error": "RuntimeError: the model stream broke"})
    elif kind == frame.TALK_END and not failed:
        out.send(frame.AUDIO, b"\x01\x02" * 240)
        out.send_json(frame.MARK, {"mark": "reply_end", "since_talk_end": 0.1})
    elif kind == frame.QUIT:
        break
try:
    out.send(frame.BYE)
except BrokenPipeError:
    pass
STUBMID

python3 - "$ROOT" "$STUB_MIDFAIL" <<'PY' || fail "mid-turn failure release"
import importlib.util, os, sys, time
root, stub = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location(
    "engine", os.path.join(root, "hud", "fm_voice_engine.py"))
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)

notices = []
eng = engine.Engine(
    [sys.executable, stub, os.path.join(root, "bin")],
    ready_timeout=10,
    on_notice=lambda event, obj: notices.append(event))
eng.start()

# The turn opens and the captain is still talking when the relay fails it.
eng.begin_turn()
eng.feed(b"\x01\x02" * 320)
deadline = time.monotonic() + 5
while "turn-failed" not in notices:
    if time.monotonic() > deadline:
        eng.close()
        sys.exit("mid-turn failure: the notice never arrived")
    time.sleep(0.02)

# The release was delivered while the turn was open. Ending the turn now
# must return at once, not erase the release and wait out the timeout on a
# spent session that drops the late TALK_END.
t0 = time.monotonic()
try:
    turn = eng.end_turn(timeout=8)
except engine.EngineError as exc:
    sys.exit("mid-turn failure: end_turn burned its timeout on a released "
             "turn: " + str(exc))
elapsed = time.monotonic() - t0
if elapsed > 3:
    sys.exit("mid-turn failure: the return must be prompt, took {:.1f}s".format(
        elapsed))
if turn != 1:
    sys.exit("mid-turn failure: the ended turn must be id 1: " + str(turn))

# The engine renews on the next turn: a fresh full round trip.
eng.begin_turn()
eng.feed(b"\x01\x02" * 320)
t0 = time.monotonic()
try:
    turn = eng.end_turn(timeout=8)
except engine.EngineError as exc:
    sys.exit("mid-turn failure: the renewed turn must complete: " + str(exc))
if turn != 2:
    sys.exit("mid-turn failure: the renewed turn must be id 2: " + str(turn))
eng.close()
PY
pass "a mid-turn failure releases the open turn and the engine renews"

# --- the panel bridge, headlessly --------------------------------------------
#
# The bridge is the Python half of the HUD process: it owns the engine and
# reports state as JSON lines. The stub relay stands in for the relay again,
# so this checks the bridge's own behavior: it starts the engine, reports the
# listening state, forwards transcripts and notices, and quits cleanly. The
# mic half of the bridge lands with the mic-capture stage.

python3 - "$ROOT" "$STUB" <<'PY' || fail "bridge"
import json, os, subprocess, sys, threading, time
root, stub = sys.argv[1], sys.argv[2]

def check(cond, label):
    if not cond:
        sys.exit("bridge: " + label)

proc = subprocess.Popen(
    [sys.executable, os.path.join(root, "hud", "fm_voice_hud_bridge.py"),
     "--stub-relay", stub,
     "--mic-file", os.path.join(root, "tests/assets/voice-hud-silence.pcm")],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

events = []
def read_events():
    for line in proc.stdout:
        line = line.strip()
        if line:
            events.append(json.loads(line))
threading.Thread(target=read_events, daemon=True).start()

deadline = time.monotonic() + 10
while not any(e.get("type") == "state" and e.get("state") == "listening"
              for e in events):
    if time.monotonic() > deadline:
        sys.exit("bridge: never reported listening")
    time.sleep(0.1)

proc.stdin.write("quit\n")
proc.stdin.flush()
try:
    rc = proc.wait(timeout=10)
except subprocess.TimeoutExpired:
    proc.kill()
    sys.exit("bridge: did not exit on quit")
check(rc == 0, "the bridge must exit zero on a clean quit")
PY
pass "the panel bridge reports state and quits cleanly over the boundary"

# --- the mic attach: wake-driven turn lifecycle over PCM files ----------------
#
# The brief's core guarantee: the mic is local until the wake word fires, and
# only then does audio reach the engine. These checks drive TurnDirector over
# the committed clips with a scripted engine that records exactly what it was
# handed, so the assertion is what crossed the wake boundary, not what the
# source says. The speech clip's transcript contains the wake word (that is
# what the clip was built for); the quiet clip never wakes anything.

python3 - "$ROOT" <<'PY' || fail "mic attach"
import importlib.util, os, sys
root = sys.argv[1]

def load(name, relpath):
    spec = importlib.util.spec_from_file_location(
        name, os.path.join(root, relpath))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

wake = load("wake", "hud/fm_voice_wake.py")
mic_mod = load("micmod", "hud/fm_voice_mic.py")

def check(cond, label):
    if not cond:
        sys.exit("mic: " + label)

class ScriptedDecoder:
    """Returns scripted transcript lines after a voiced run ends, like a real
    decoder that answers per utterance, not per block."""
    def __init__(self, lines):
        self.lines = list(lines)
        self.fed = 0
        self._voiced_run = 0
    def start(self):
        pass
    def feed(self, block):
        self.fed += 1
        self._voiced_run += 1
        return []
    def poll_transcripts(self):
        # A transcript lands after a few voiced blocks (the utterance ran);
        # silence between utterances is when the real decoder would flush.
        if self.lines and self._voiced_run >= 3:
            self._voiced_run = 0
            return [self.lines.pop(0)]
        return []
    def close(self):
        pass

class ScriptedEngine:
    """Records what it was handed, so the check asserts the boundary."""
    def __init__(self):
        self.begun = 0
        self.fed = 0
        self.ended = 0
        self.blocks = []
    def begin_turn(self):
        self.begun += 1
    def feed(self, pcm):
        self.fed += 1
        events.append(pcm)
    def end_turn(self):
        self.ended += 1

events = []
engine = ScriptedEngine()
notices = []
gate = wake.EnergyGate()
keyword = wake.KeywordListener()
decoder = ScriptedDecoder(["Ziggy"])
director = mic_mod.TurnDirector(
    engine, gate, keyword, decoder, on_notice=notices.append)

speech = open(os.path.join(root, "tests/assets/voice-hud-speech.pcm"), "rb").read()
silence = open(os.path.join(root, "tests/assets/voice-hud-silence.pcm"), "rb").read()
quiet = open(os.path.join(root, "tests/assets/voice-hud-quiet.pcm"), "rb").read()

# Silence first: no transcript, no wake, nothing crosses to the engine.
t = 0.0
for i in range(0, len(silence) - 3200 + 1, 3200):
    director.feed(silence[i:i + 3200], t)
    t += 0.1
check(engine.begun == 0, "silence must never open a turn")
check(decoder.fed == 0, "silence must never be sent to the decoder: fed=" + str(decoder.fed))

# Quiet room tone: same, never a wake.
for i in range(0, len(quiet) - 3200 + 1, 3200):
    director.feed(quiet[i:i + 3200], t)
    t += 0.1
check(engine.begun == 0, "quiet room tone must never open a turn")

# The speech clip with the wake word in its transcript: a wake, then a turn.
turn_blocks = 0
for i in range(0, len(speech) - 3200 + 1, 3200):
    director.feed(speech[i:i + 3200], t)
    t += 0.1
    turn_blocks += 1
    if engine.begun > 0:
        break
check(engine.begun == 1, "the wake word must open exactly one turn, began=" + str(engine.begun))
check(notices == ["wake"], "the wake must be noticed: " + repr(notices))

# The turn ends when the gate goes quiet past its hangover.
closed = False
for _ in range(20):
    director.feed(bytes(3200), t)
    t += 0.1
    if engine.ended == 1:
        closed = True
        break
check(closed, "the turn must end when speech stops past the hangover")

# A wake into silence never opens a turn and says so. Three voiced blocks
# arm the wake via the transcript (the utterance ends with its last block);
# then nothing but silence follows.
gate2 = wake.EnergyGate()
engine2 = ScriptedEngine()
notices2 = []
decoder2 = ScriptedDecoder(["Ziggy"])
director2 = mic_mod.TurnDirector(
    engine2, gate2, keyword, decoder2, on_notice=notices2.append)
import math, struct
loud_block = b"".join(
    struct.pack("<h", int(12000 * math.sin(2 * math.pi * 440 * i / 16000)))
    for i in range(1600))
director2.feed(loud_block * 2, 0.0)
director2.feed(loud_block * 2, 0.1)
director2.feed(loud_block * 2, 0.2)
check(director2.phase == "in-wake", "the wake must arm: " + director2.phase)
check(engine2.begun == 0, "arming the wake alone must not open a turn")
closed2 = False
for n in range(100):
    director2.feed(bytes(3200), 0.1 * (n + 1))
    if director2.phase == "listening":
        closed2 = True
        break
check(closed2, "a wake into silence must re-arm without opening a turn")
check(engine2.begun == 0, "a wake into silence must never open a turn")
check("no-speech" in notices2, "a wake into silence must say so: " + repr(notices2))
PY
pass "the mic attach wakes on the word, streams only after the wake, and never opens a turn on silence"

# --- "Ziggy, <command>" in one breath is sent as one turn ----------------------
#
# The decoder names the wake word only once the whole utterance has ended, so
# a command said in the same breath as the name would be lost if the audio
# were not held. The held utterance must be sent as the turn at once; a
# sentence that merely mentions the name, or the name alone, must not be.

python3 - "$ROOT" <<'PY' || fail "one-breath wake"
import importlib.util, math, os, struct, sys
root = sys.argv[1]

def load(name, relpath):
    spec = importlib.util.spec_from_file_location(
        name, os.path.join(root, relpath))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

wake = load("wake", "hud/fm_voice_wake.py")
mic_mod = load("micmod", "hud/fm_voice_mic.py")

def check(cond, label):
    if not cond:
        sys.exit("one-breath wake: " + label)

class LineAfterDecoder:
    """Returns its line once `after` blocks were fed and the caller polls in
    the utterance's trailing quiet, like a real per-utterance decoder."""
    def __init__(self, text, after):
        self.text, self.after, self.fed, self.done = text, after, 0, False
    def start(self): pass
    def feed(self, block): self.fed += 1
    def poll_transcripts(self):
        if not self.done and self.fed >= self.after:
            self.done = True
            return [self.text]
        return []
    def close(self): pass

class RecordingEngine:
    def __init__(self):
        self.begun = self.ended = 0
        self.fed = []
    def begin_turn(self): self.begun += 1
    def feed(self, pcm): self.fed.append(pcm)
    def end_turn(self): self.ended += 1

loud = b"".join(
    struct.pack("<h", int(12000 * math.sin(2 * math.pi * 440 * i / 16000)))
    for i in range(1600)) * 2
quiet = bytes(3200)

def run(text, loud_blocks=12):
    engine, notices = RecordingEngine(), []
    director = mic_mod.TurnDirector(
        engine, wake.EnergyGate(), wake.KeywordListener(),
        LineAfterDecoder(text, loud_blocks), on_notice=notices.append)
    t = 0.0
    for _ in range(loud_blocks):
        director.feed(loud, t); t += 0.1
    # The final line lands in the trailing quiet, after the last loud block.
    for _ in range(3):
        director.feed(quiet, t); t += 0.1
    return engine, director, notices

engine, director, notices = run("Ziggy, what is the status?")
check(engine.begun == 1 and engine.ended == 1,
      "a one-breath command must open and close one turn: %d/%d" % (engine.begun, engine.ended))
check(sum(len(b) for b in engine.fed) >= 12 * 3200,
      "the whole held utterance must reach the engine, got %d bytes" % sum(len(b) for b in engine.fed))
check(director.phase == "listening", "the HUD must be listening again: " + director.phase)
check(notices == ["wake"], "the wake must be noticed once: " + repr(notices))

engine, director, notices = run("Ziggy.")
check(engine.begun == 0 and director.phase == "in-wake",
      "the name alone must arm the wake and wait for the command")

engine, director, notices = run("I told Ziggy about it yesterday")
check(engine.begun == 0,
      "a sentence that only mentions the name must never be sent as a turn")
PY
pass "a one-breath \"Ziggy, <command>\" is sent as one turn; the name alone still waits"

# --- the fast spotter opens the turn at the name, with the held pre-roll -----
#
# With a spotter configured the HUD wakes the moment the name is spotted, not
# after the decoder's final line: the turn opens then, carries the held
# pre-roll so "Ziggy" and the start of the command are not clipped, streams
# the command, and ends on quiet. The name alone keeps the turn open for the
# command grace before it gives up.

python3 - "$ROOT" <<'PY' || fail "spotter wake"
import importlib.util, math, os, struct, sys
root = sys.argv[1]

def load(name, relpath):
    spec = importlib.util.spec_from_file_location(
        name, os.path.join(root, relpath))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

wake = load("wake", "hud/fm_voice_wake.py")
mic_mod = load("micmod", "hud/fm_voice_mic.py")

def check(cond, label):
    if not cond:
        sys.exit("spotter wake: " + label)

class ScriptedSpotter:
    """Spots on the Nth block fed."""
    def __init__(self, at):
        self.at, self.fed = at, 0
    def feed(self, block): self.fed += 1
    def poll(self): return [(0.99, 0.0)] if self.fed == self.at else []

class NoDecoder:
    def start(self): pass
    def feed(self, block): raise AssertionError("the decoder must not be fed")
    def poll_transcripts(self): raise AssertionError("the decoder must not be read")
    def close(self): pass

class RecordingEngine:
    def __init__(self):
        self.begun = self.ended = 0
        self.fed = 0
    def begin_turn(self): self.begun += 1
    def feed(self, pcm): self.fed += len(pcm)
    def end_turn(self): self.ended += 1

loud = b"".join(
    struct.pack("<h", int(12000 * math.sin(2 * math.pi * 440 * i / 16000)))
    for i in range(1600)) * 2
quiet = bytes(3200)

def run(blocks, spot_at, follow_up=0):
    engine, notices = RecordingEngine(), []
    director = mic_mod.TurnDirector(
        engine, wake.EnergyGate(), wake.KeywordListener(), NoDecoder(),
        on_notice=notices.append, spotter=ScriptedSpotter(spot_at))
    director.follow_up_seconds = follow_up
    t, opened_at = 0.0, None
    for block in blocks:
        director.feed(block, t)
        if engine.begun and opened_at is None:
            opened_at = t
        t += 0.1
    return engine, director, notices, opened_at

# "Ziggy, what is the status?": 5 loud blocks of name, spotted on the 5th,
# then 10 loud blocks of command, then quiet.
engine, director, notices, opened_at = run([loud] * 15 + [quiet] * 15, 5)
check(engine.begun == 1, "the spot must open exactly one turn")
check(abs(opened_at - 0.4) < 1e-6, "the turn must open on the spotted block, at %r" % opened_at)
check(engine.fed >= 15 * 3200, "pre-roll plus command must all be sent, got %d bytes" % engine.fed)
check(engine.ended == 1 and director.phase == "listening", "the turn must end on quiet")
check(notices == ["wake", "stand-by"], "the wake must be noticed once: %r" % notices)

# The conversation window: after the reply, speech opens the next turn with no
# wake word; quiet past the window stands the HUD down to wake-word mode.
engine, director, notices, _ = run(
    [loud] * 10 + [quiet] * 15 + [loud] * 6 + [quiet] * 15, 5, follow_up=8.0)
check(engine.begun == 2, "speech in the window must open a second turn without the name: %d" % engine.begun)
check("follow-up-turn" in notices, "the follow-up turn must be noticed: %r" % notices)
engine, director, notices, _ = run([loud] * 10 + [quiet] * 110, 5, follow_up=8.0)
check(engine.begun == 1 and director.phase == "listening" and notices[-1] == "stand-by",
      "quiet past the window must return to wake-word mode: %r %s" % (notices, director.phase))
# Standing down closes the window at once.
engine, director, notices, _ = run([loud] * 10 + [quiet] * 15, 5, follow_up=8.0)
check(director.phase == "follow-up", "the window must be open after a reply: " + director.phase)
director.stand_down()
check(director.phase == "listening" and notices[-1] == "stand-by", "stand down must close the window")

# "Ziggy" then a pause longer than the hangover but shorter than the grace,
# then the command: one turn, not ended in the pause.
engine, director, notices, _ = run([loud] * 5 + [quiet] * 15 + [loud] * 8 + [quiet] * 15, 5)
check(engine.begun == 1 and engine.ended == 1,
      "a pause after the name must not end the turn before the command")
check(engine.fed >= 13 * 3200, "the name and the later command must both be sent")

# The name alone: the turn ends once the grace runs out.
engine, director, notices, _ = run([loud] * 5 + [quiet] * 40, 5)
check(engine.ended == 1 and director.phase == "listening",
      "the name alone must end its turn after the grace")
PY
pass "the fast spotter opens the turn at the name with its pre-roll and ends it on quiet"

# --- a wake word spoken inside a turn never arms a stale wake ----------------
#
# The decoder finalizes each utterance's line only after it ended, so a
# wake word said inside an open turn arrives as a transcript while the
# director is in the turn. That line belongs to the turn's own speech: it
# must be drained and discarded there, never buffered to re-wake the HUD
# once the turn closes - the buffered form is exactly how a stray word
# after a turn costs the captain a model turn.

python3 - "$ROOT" <<'PY' || fail "stale transcripts"
import importlib.util, math, os, struct, sys
root = sys.argv[1]

def load(name, relpath):
    spec = importlib.util.spec_from_file_location(
        name, os.path.join(root, relpath))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

wake = load("wake", "hud/fm_voice_wake.py")
mic_mod = load("micmod", "hud/fm_voice_mic.py")

def check(cond, label):
    if not cond:
        sys.exit("stale transcripts: " + label)

class UtteranceDecoder:
    """Final lines land a set number of fed blocks after their utterance
    began, like a real decoder that answers per utterance."""
    def __init__(self, lines_at):
        self.pending = list(lines_at)
        self.fed = 0
    def start(self):
        pass
    def feed(self, block):
        self.fed += 1
        return []
    def poll_transcripts(self):
        out = []
        rest = []
        for at, text in self.pending:
            if self.fed >= at:
                out.append(text)
            else:
                rest.append((at, text))
        self.pending = rest
        return out
    def close(self):
        pass

class ScriptedEngine:
    def __init__(self):
        self.begun = 0
        self.ended = 0
    def begin_turn(self):
        self.begun += 1
    def feed(self, pcm):
        pass
    def end_turn(self):
        self.ended += 1

loud = b"".join(
    struct.pack("<h", int(12000 * math.sin(2 * math.pi * 440 * i / 16000)))
    for i in range(1600)) * 2

engine = ScriptedEngine()
decoder = UtteranceDecoder([
    (4, "Ziggy"),
    (10, "Ziggy I mean what time"),
    (15, "hello there"),
])
director = mic_mod.TurnDirector(
    engine, wake.EnergyGate(), wake.KeywordListener(), decoder)

# Four loud blocks: the wake fires on the finalized first utterance.
t = 0.0
for _ in range(4):
    director.feed(loud, t)
    t += 0.1
check(director.phase == "in-wake",
      "the wake must fire on the first utterance: " + director.phase)

# A fifth loud block opens the turn; blocks 6-10 are speech inside it,
# including a second wake word whose transcript finalizes at block 10.
for _ in range(6):
    director.feed(loud, t)
    t += 0.1
check(director.phase == "in-turn", "the turn must be open")
check(engine.begun == 1, "exactly one turn must have opened")

# Quiet past the hangover ends the turn.
for _ in range(12):
    director.feed(bytes(3200), t)
    t += 0.1
check(director.phase == "listening" and engine.ended == 1,
      "the turn must end on quiet: " + director.phase)

# Fresh speech after the turn must not open a second turn on the wake word
# that was spoken inside it.
for _ in range(2):
    director.feed(loud, t)
    t += 0.1
check(director.phase == "listening",
      "the director must stay listening without a fresh wake: "
      + director.phase)
check(engine.begun == 1,
      "a wake word spoken inside the turn must not re-wake the HUD: "
      "begun=" + str(engine.begun))

# And the buffered line is gone for good: later speech, still no wake.
for _ in range(2):
    director.feed(loud, t)
    t += 0.1
check(engine.begun == 1, "no stale line may survive later blocks either")
PY
pass "a wake word spoken inside a turn never arms a stale wake after it"

# --- a late final line never arms a stale wake -------------------------------
#
# A per-utterance decoder finalizes each utterance's line only after its
# audio ended - for the utterance that ended a turn, that lands during the
# trailing quiet, after the turn's last loud block, so no poll inside the
# turn can drain it. The decoder never hears turn speech at all (audio
# crosses into it only while the HUD listens), so however late a line
# lands, nothing from inside a turn exists in it to re-wake the HUD with.

python3 - "$ROOT" <<'PY' || fail "late final lines"
import importlib.util, math, os, struct, sys
root = sys.argv[1]

def load(name, relpath):
    spec = importlib.util.spec_from_file_location(
        name, os.path.join(root, relpath))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

wake = load("wake", "hud/fm_voice_wake.py")
mic_mod = load("micmod", "hud/fm_voice_mic.py")

def check(cond, label):
    if not cond:
        sys.exit("late final lines: " + label)

class LateFinalDecoder:
    """A per-utterance decoder: a line exists only once its utterance's
    audio has been fed, and lands in the pipe a chosen number of polls
    later - for the utterance that ended a turn, during the trailing
    quiet, where no poll runs at all."""
    def __init__(self, lines):
        self.pending = list(lines)   # (fed blocks needed, poll lag, text)
        self.fed = 0
        self.polled = 0
    def start(self):
        pass
    def feed(self, block):
        self.fed += 1
        return []
    def poll_transcripts(self):
        self.polled += 1
        out = []
        rest = []
        for need, lag, text in self.pending:
            if self.fed >= need and self.polled >= need + lag:
                out.append(text)
            else:
                rest.append((need, lag, text))
        self.pending = rest
        return out
    def close(self):
        pass

class ScriptedEngine:
    def __init__(self):
        self.begun = 0
        self.ended = 0
    def begin_turn(self):
        self.begun += 1
    def feed(self, pcm):
        pass
    def end_turn(self):
        self.ended += 1

loud = b"".join(
    struct.pack("<h", int(12000 * math.sin(2 * math.pi * 440 * i / 16000)))
    for i in range(1600)) * 2

engine = ScriptedEngine()
decoder = LateFinalDecoder([
    (4, 0, "Ziggy"),
    # Said inside the turn: ten loud blocks, its line landing two polls
    # after they end - in the trailing quiet, past every in-turn poll.
    (10, 2, "Ziggy I mean what time"),
])
director = mic_mod.TurnDirector(
    engine, wake.EnergyGate(), wake.KeywordListener(), decoder)

# Four loud blocks arm the wake on the first utterance's line.
t = 0.0
for _ in range(4):
    director.feed(loud, t)
    t += 0.1
check(director.phase == "in-wake",
      "the wake must fire on the first utterance: " + director.phase)

# A loud block opens the turn; six more are speech inside it.
for _ in range(7):
    director.feed(loud, t)
    t += 0.1
check(director.phase == "in-turn", "the turn must be open")
check(engine.begun == 1, "exactly one turn must have opened")

# Quiet past the hangover ends the turn; the mid-turn utterance's line
# lands in the pipe during this quiet, where no poll runs.
for _ in range(12):
    director.feed(bytes(3200), t)
    t += 0.1
check(director.phase == "listening" and engine.ended == 1,
      "the turn must end on quiet: " + director.phase)

# Fresh speech after the turn: the first loud block polls the pipe, and a
# late line belonging to turn speech must not arm a wake on it.
for _ in range(2):
    director.feed(loud, t)
    t += 0.1
check(director.phase == "listening",
      "a late line from inside the turn must not re-wake: "
      + director.phase)
check(engine.begun == 1,
      "no model turn may open on turn speech: begun=" + str(engine.begun))
PY
pass "a late final line from a finished turn never arms a stale wake"

# --- the device mic end, against a stub sounddevice ---------------------------
#
# The real capture end cannot run here - no audio device exists in a worker
# shell - but its contract can: the device's callback fills a queue and
# blocks() yields what it captured, in order, and close() ends the stream.

python3 - "$ROOT" <<'PY' || fail "device mic"
import importlib.util, os, sys, threading, time, types

class StubRawInputStream:
    instances = []
    def __init__(self, samplerate, channels, dtype, blocksize, device,
                 latency, callback):
        self.settings = (samplerate, channels, dtype, blocksize, device, latency)
        self.callback = callback
        self.started = 0
        self.stopped = 0
        self.closed = 0
        StubRawInputStream.instances.append(self)
    def start(self):
        self.started += 1
    def stop(self):
        self.stopped += 1
    def close(self):
        self.closed += 1

stub = types.ModuleType("sounddevice")
stub.RawInputStream = StubRawInputStream
sys.modules["sounddevice"] = stub

spec = importlib.util.spec_from_file_location(
    "micmod", os.path.join(sys.argv[1], "hud", "fm_voice_mic.py"))
mic_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mic_mod)

def check(cond, label):
    if not cond:
        sys.exit("device mic: " + label)

mic = mic_mod.DeviceMic(device=3)
stream = StubRawInputStream.instances[-1]
check(stream.started == 1, "the stream must start at construction")
check(stream.settings == (16000, 1, "int16", 1600, 3, "low"),
      "the stream must be 16 kHz mono int16 at the wake block size: "
      + repr(stream.settings))

blocks = []
def collect():
    for block in mic.blocks():
        blocks.append(block)
reader = threading.Thread(target=collect, daemon=True)
reader.start()

first = b"\x01\x02" * 1600
second = b"\x03\x04" * 1600
stream.callback(first, 1600, None, None)
stream.callback(second, 1600, None, None)
deadline = time.monotonic() + 2
while len(blocks) < 2 and time.monotonic() < deadline:
    time.sleep(0.02)
check(blocks[:2] == [first, second],
      "blocks() must yield the captured blocks in order: " + repr(blocks[:2]))

mic.close()
check(stream.stopped == 1 and stream.closed == 1,
      "close must stop and close the stream")
reader.join(timeout=2)
check(not reader.is_alive(), "close must end the blocks() generator")
PY
pass "the device mic end yields captured blocks and ends at close"

# --- the device mic's health: denied silence is named, not rendered --------
#
# A microphone the system denies does not fail to open - it opens and
# delivers digital silence, which is indistinguishable from not-heard
# unless someone counts. The count is the product's own: after a bound of
# all-zero input the HUD says so on the wire (mic-denied), once per silent
# run, and a PortAudio status flag surfaces once per distinct flag.

python3 - "$ROOT" <<'PY' || fail "mic health"
import importlib.util, os, sys, types

class StubRawInputStream:
    instances = []
    def __init__(self, samplerate, channels, dtype, blocksize, device,
                 latency, callback):
        self.settings = (samplerate, channels, dtype, blocksize, device, latency)
        self.callback = callback
        StubRawInputStream.instances.append(self)
    def start(self):
        pass
    def stop(self):
        pass
    def close(self):
        pass

stub = types.ModuleType("sounddevice")
stub.RawInputStream = StubRawInputStream
stub.default = types.SimpleNamespace(device=[2, 9])
sys.modules["sounddevice"] = stub

spec = importlib.util.spec_from_file_location(
    "micmod", os.path.join(sys.argv[1], "hud", "fm_voice_mic.py"))
mic_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mic_mod)

def check(cond, label):
    if not cond:
        sys.exit("mic health: " + label)

silent = []
status = []
mic = mic_mod.DeviceMic(on_silent=lambda: silent.append(True),
                        on_status=status.append,
                        silent_after_blocks=4)
stream = StubRawInputStream.instances[-1]
check(stream.settings[4] == 2,
      "the default input device must be picked explicitly: " + repr(stream.settings))

zero = bytes(3200)
loud = b"\x01\x02" * 1600

# Three zero blocks stay quiet; the fourth crosses the bound and says so.
for _ in range(3):
    stream.callback(zero, 1600, None, None)
check(silent == [], "zeros under the bound must stay quiet: " + repr(silent))
stream.callback(zero, 1600, None, None)
check(silent == [True], "the bound of all-zero input must fire once: " + repr(silent))
for _ in range(5):
    stream.callback(zero, 1600, None, None)
check(silent == [True], "one notice per silent run: " + repr(silent))

# Real audio resets the run, so a later silent run is news again.
stream.callback(loud, 1600, None, None)
check(silent == [True], "speech must never fire the silent notice")
for _ in range(4):
    stream.callback(zero, 1600, None, None)
check(silent == [True, True],
      "a fresh silent run after speech must be news again: " + repr(silent))

# A PortAudio status flag surfaces once per distinct flag.
stream.callback(zero, 1600, None, "input overflow")
stream.callback(zero, 1600, None, "input overflow")
check(status == ["input overflow"],
      "each distinct status flag surfaces once: " + repr(status))
PY
pass "a denied-silent microphone is named on the wire after a bounded run"

# --- synthetic zero input reaches the panel over the bridge wire ------------
#
# The synthetic reproduction of the captain's blocker: the shipped mic end
# (no --mic-file) opens fine and delivers pure digital silence - exactly
# what a denied TCC microphone produces. The notice path is the fix: the
# panel hears mic-denied on the wire, the mic level events keep flowing so
# the silence is visible, and the bridge stays quittable.

SDSTUB_SILENT_MIC="$TMP_ROOT/sdstub-silent-mic"
mkdir -p "$SDSTUB_SILENT_MIC"
cat > "$SDSTUB_SILENT_MIC/sounddevice.py" <<'SDPY'
import threading
import time


class RawOutputStream:
    def __init__(self, **kwargs):
        pass

    def start(self):
        pass

    def stop(self):
        pass

    def close(self):
        pass


class _Default:
    device = [0, 0]


default = _Default()


class RawInputStream:
    """Delivers exactly what a microphone the system denies delivers:
    digital silence, block after block, on the real cadence."""
    def __init__(self, samplerate, channels, dtype, blocksize, device,
                 latency, callback):
        self.callback = callback
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self):
        time.sleep(0.3)
        block = bytes(3200)
        for _ in range(80):          # eight seconds of digital silence
            self.callback(block, 1600, None, None)
            time.sleep(0.05)

    def start(self):
        pass

    def stop(self):
        pass

    def close(self):
        pass
SDPY

python3 - "$ROOT" "$STUB" "$SDSTUB_SILENT_MIC" <<'PY' || fail "mic denial wire"
import json, os, subprocess, sys, threading, time
root, stub, sdstub = sys.argv[1], sys.argv[2], sys.argv[3]

env = dict(os.environ)
env.pop("FM_VOICE_HUD_DECODER", None)
env["PYTHONPATH"] = sdstub + (
    os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")

proc = subprocess.Popen(
    [sys.executable, os.path.join(root, "hud", "fm_voice_hud_bridge.py"),
     "--stub-relay", stub],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)

events = []
def read_events():
    for line in proc.stdout:
        line = line.strip()
        if line:
            events.append(json.loads(line))
threading.Thread(target=read_events, daemon=True).start()

# The mic level events flow while the input is silent (level 0, gate
# listening), then the denial itself is named on the wire.
deadline = time.monotonic() + 15
while True:
    mic_events = [e for e in events if e.get("type") == "mic"]
    denied = any(e.get("type") == "notice" and e.get("event") == "mic-denied"
                 for e in events)
    if mic_events and denied:
        break
    if time.monotonic() > deadline:
        proc.kill()
        sys.exit("mic denial: the denial never reached the wire: " + repr(events))
    time.sleep(0.1)

check_level = all(e.get("level") == 0 and e.get("gate") == "listening"
                  for e in mic_events)
if not check_level:
    sys.exit("mic denial: silent input must show level 0 at the listening gate: "
             + repr(mic_events[:4]))

proc.stdin.write("quit\n")
proc.stdin.flush()
try:
    rc = proc.wait(timeout=10)
except subprocess.TimeoutExpired:
    proc.kill()
    sys.exit("mic denial: the bridge did not stay quittable")
if rc != 0:
    sys.exit("mic denial: the bridge must quit zero after naming a silent mic: "
             + str(rc))
PY
pass "synthetic zero input reaches the panel as a mic-denied notice"

# --- the decoder drain never owns the mic thread -------------------------------
#
# poll_transcripts() runs on the mic thread while the captain is talking, so
# it must return with what has arrived and never wait for more. A real child
# that stays silent, then answers half a line at a time, is the drain's
# contract: no blocking on silence, no partial lines, no repeats.

python3 - "$ROOT" <<'PY' || fail "decoder drain"
import importlib.util, os, sys, time

spec = importlib.util.spec_from_file_location(
    "micmod", os.path.join(sys.argv[1], "hud", "fm_voice_mic.py"))
mic_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mic_mod)

def check(cond, label):
    if not cond:
        sys.exit("decoder drain: " + label)

child = (
    "import sys, time\n"
    "time.sleep(1.0)\n"
    "sys.stdout.write('zig')\n"
    "sys.stdout.flush()\n"
    "time.sleep(1.0)\n"
    "sys.stdout.write('gy hello\\n')\n"
    "sys.stdout.flush()\n"
    "sys.stdin.read()\n"
)
dec = mic_mod.DecoderCommand([sys.executable, "-c", child])
dec.start()

t0 = time.monotonic()
lines = dec.poll_transcripts()
elapsed = time.monotonic() - t0
check(elapsed < 0.5,
      "poll must return while the decoder is silent; took {:.2f}s".format(elapsed))
check(lines == [], "a silent decoder must yield no lines")

time.sleep(1.3)
lines = dec.poll_transcripts()
check(lines == [], "a partial line must not be returned: " + repr(lines))

time.sleep(1.2)
lines = dec.poll_transcripts()
check(lines == ["ziggy hello"],
      "the completed line must arrive once complete: " + repr(lines))
lines = dec.poll_transcripts()
check(lines == [], "a drained line must not repeat: " + repr(lines))

dec.close()
PY
pass "the decoder drain never blocks and completes partial lines across polls"

# --- the reply player, against a stub sounddevice ------------------------------
#
# The engine hands reply PCM to the player whole; the player hands it to the
# output stream in order and owns the stream's life. The device end is
# UNVERIFIED for the same reason the client's is; the buffering and close
# discipline are what runs here, with the stream's callback driven by hand.

python3 - "$ROOT" <<'PY' || fail "reply player"
import importlib.util, os, sys, time, types

class StubRawOutputStream:
    instances = []
    def __init__(self, samplerate, channels, dtype, blocksize, device,
                 latency, callback):
        self.settings = (samplerate, channels, dtype, blocksize, device, latency)
        self.callback = callback
        self.started = 0
        self.stopped = 0
        self.closed = 0
        StubRawOutputStream.instances.append(self)
    def start(self):
        self.started += 1
    def stop(self):
        self.stopped += 1
    def close(self):
        self.closed += 1

stub = types.ModuleType("sounddevice")
stub.RawOutputStream = StubRawOutputStream
sys.modules["sounddevice"] = stub

spec = importlib.util.spec_from_file_location(
    "speaker", os.path.join(sys.argv[1], "hud", "fm_voice_speaker.py"))
speaker_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(speaker_mod)

def check(cond, label):
    if not cond:
        sys.exit("reply player: " + label)

sp = speaker_mod.Speaker(device="ziggys speakers")
stream = StubRawOutputStream.instances[-1]
check(stream.started == 1, "the stream must start at construction")
check(stream.settings == (24000, 1, "int16", 2400, "ziggys speakers", "low"),
      "the stream must be 24 kHz mono int16 at the reply block size: "
      + repr(stream.settings))

first = b"\x01\x02" * 300
second = b"\x03\x04" * 100
sp.write(first)
sp.write(second)
out = bytearray(4800)
stream.callback(out, 2400, None, None)
check(bytes(out) == first + second + bytes(4800 - len(first) - len(second)),
      "the written PCM must reach the stream in order, silence-padded")

out = bytearray(4800)
stream.callback(out, 2400, None, None)
check(bytes(out) == bytes(4800), "an empty buffer must play silence")

sp.close()
check(stream.stopped == 1 and stream.closed == 1,
      "close must stop and close the stream exactly once")
sp.write(b"\x05\x06" * 10)
out = bytearray(4800)
stream.callback(out, 2400, None, None)
check(bytes(out) == bytes(4800),
      "audio written after close must not reach the stream")

sp2 = speaker_mod.Speaker()
stream2 = StubRawOutputStream.instances[-1]
sp2.write(b"\x07\x08" * 12000)
t0 = time.monotonic()
sp2.drain(timeout=0.3)
elapsed = time.monotonic() - t0
check(0.2 < elapsed < 2.0,
      "drain must be bounded when nothing empties the buffer: {:.2f}s".format(
          elapsed))
out = bytearray(4800)
stream2.callback(out, 2400, None, None)
check(bytes(out) == b"\x07\x08" * 2400,
      "the queued PCM must still be playable in order")
sp2.close()
PY
pass "the reply player hands engine PCM to the stream and bounds its lifecycle"

# --- an engine fault reaches the panel, not a dead thread ----------------------
#
# If the relay child dies mid-session, the fault must arrive on the boundary
# as a notice the panel can show, and the bridge must stay quittable - never
# die invisibly with a traceback while the HUD renders listening forever.

STUB_DIE="$TMP_ROOT/stub-die-relay.py"
cat > "$STUB_DIE" <<'STUBDIE'
import sys
sys.path.insert(0, sys.argv[1])
import fm_voice_frame as frame

sys.stdout.buffer.write(frame.MAGIC)
sys.stdout.buffer.flush()
out = frame.Writer(sys.stdout.buffer)
out.send_json(frame.NOTICE, {"event": "ready", "model": "stub"})
# The wire dies here without BYE: the relay process exits mid-session.
sys.exit(0)
STUBDIE

python3 - "$ROOT" "$STUB_DIE" <<'PY' || fail "engine fault"
import json, os, subprocess, sys, threading, time
root, stub = sys.argv[1], sys.argv[2]

proc = subprocess.Popen(
    [sys.executable, os.path.join(root, "hud", "fm_voice_hud_bridge.py"),
     "--stub-relay", stub,
     "--mic-file", os.path.join(root, "tests/assets/voice-hud-silence.pcm")],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)

events = []
def read_events():
    for line in proc.stdout:
        line = line.strip()
        if line:
            events.append(json.loads(line))
threading.Thread(target=read_events, daemon=True).start()

deadline = time.monotonic() + 10
while not any(e.get("type") == "notice" and e.get("event") == "engine-fault"
              for e in events):
    if time.monotonic() > deadline:
        sys.exit("engine fault: the fault notice never reached the boundary: "
                 + repr(events))
    time.sleep(0.1)

proc.stdin.write("quit\n")
proc.stdin.flush()
try:
    rc = proc.wait(timeout=10)
except subprocess.TimeoutExpired:
    proc.kill()
    sys.exit("engine fault: the bridge did not stay quittable after the fault")
if rc != 0:
    sys.exit("engine fault: the bridge must quit zero after a fault: " + str(rc))
PY
pass "an engine fault reaches the panel as a notice and the bridge stays quittable"

# --- a relay that refuses at startup says so on the wire ----------------------
#
# The first live run is exactly when the home is least likely to be
# configured: a relay that never says hello must reach the panel as an
# engine-fault notice, not a traceback the wire never carries.

STUB_SILENT="$TMP_ROOT/stub-silent-relay.py"
cat > "$STUB_SILENT" <<'STUBSILENT'
import sys
# Not a relay: exits before the handshake.
sys.exit(3)
STUBSILENT

python3 - "$ROOT" "$STUB_SILENT" <<'PY' || fail "startup fault"
import json, os, subprocess, sys
root, stub = sys.argv[1], sys.argv[2]

proc = subprocess.run(
    [sys.executable, os.path.join(root, "hud", "fm_voice_hud_bridge.py"),
     "--stub-relay", stub],
    capture_output=True, text=True, timeout=30)
events = []
for ln in proc.stdout.splitlines():
    ln = ln.strip()
    if ln:
        events.append(json.loads(ln))
if proc.returncode == 0:
    sys.exit("startup fault: the bridge must exit non-zero when the relay refuses")
if not any(e.get("type") == "notice" and e.get("event") == "engine-fault"
           for e in events):
    sys.exit("startup fault: the refusal never reached the wire: "
             + repr(proc.stdout) + repr(proc.stderr[-500:]))
PY
pass "a relay refusing at startup surfaces as an engine-fault notice and a non-zero exit"

# --- a dead decoder child says so, and the bridge stays quittable -------------
#
# The wake decision needs the decoder's transcripts, so a decoder command
# that exits early - wrong path, missing venv, mid-session crash - must reach
# the panel once and never kill the mic thread with a traceback.

python3 - "$ROOT" "$STUB" <<'PY' || fail "decoder fault"
import json, math, os, struct, subprocess, sys, tempfile, threading, time
root, stub = sys.argv[1], sys.argv[2]

# Six seconds of loud tone: loud blocks keep reaching the decoder after the
# child has exited, which is when the dead pipe first speaks.
tone = b"".join(
    struct.pack("<h", int(12000 * math.sin(2 * math.pi * 440 * i / 16000)))
    for i in range(6 * 16000))
fd, mic_path = tempfile.mkstemp(suffix=".pcm")
with os.fdopen(fd, "wb") as fh:
    fh.write(tone)

env = dict(os.environ)
env["FM_VOICE_HUD_DECODER"] = "python3 -c 'import time; time.sleep(1.0)'"
proc = subprocess.Popen(
    [sys.executable, os.path.join(root, "hud", "fm_voice_hud_bridge.py"),
     "--stub-relay", stub, "--mic-file", mic_path],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)

events = []
def read_events():
    for line in proc.stdout:
        line = line.strip()
        if line:
            events.append(json.loads(line))
threading.Thread(target=read_events, daemon=True).start()

deadline = time.monotonic() + 15
while not any(e.get("type") == "notice" and e.get("event") == "decoder-fault"
              for e in events):
    if time.monotonic() > deadline:
        proc.kill()
        sys.exit("decoder fault: the fault notice never reached the wire: "
                 + repr(events))
    time.sleep(0.1)

proc.stdin.write("quit\n")
proc.stdin.flush()
try:
    rc = proc.wait(timeout=10)
except subprocess.TimeoutExpired:
    proc.kill()
    sys.exit("decoder fault: the bridge did not stay quittable after the fault")
if rc != 0:
    sys.exit("decoder fault: the bridge must quit zero after a decoder fault: "
             + str(rc))
os.unlink(mic_path)
PY
pass "a dead decoder child reaches the panel as a notice and the bridge stays quittable"

# --- a microphone that refuses to open says so on the wire --------------------
#
# The shipped path never passes --mic-file: the real microphone must attach,
# and a python3 without sounddevice or a machine with no input device is
# news the panel needs on the wire, not a traceback the wire never carries.
# The stub raises exactly where a missing device would, so the check is
# deterministic on every machine.

SDSTUB_REFUSE="$TMP_ROOT/sdstub-refuse"
mkdir -p "$SDSTUB_REFUSE"
cat > "$SDSTUB_REFUSE/sounddevice.py" <<'SDREF'
class PortAudioError(Exception):
    pass


class _Default:
    device = [0, 0]


default = _Default()


class RawOutputStream:
    def __init__(self, samplerate, channels, dtype, blocksize, device,
                 latency, callback):
        pass

    def start(self):
        pass

    def stop(self):
        pass

    def close(self):
        pass


def RawInputStream(**kwargs):
    raise PortAudioError("no input device available")
SDREF

python3 - "$ROOT" "$STUB" "$SDSTUB_REFUSE" <<'PY' || fail "mic fault"
import json, os, subprocess, sys
root, stub, sdstub = sys.argv[1], sys.argv[2], sys.argv[3]

env = dict(os.environ)
env.pop("FM_VOICE_HUD_DECODER", None)
env["PYTHONPATH"] = sdstub + (
    os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")

proc = subprocess.run(
    [sys.executable, os.path.join(root, "hud", "fm_voice_hud_bridge.py"),
     "--stub-relay", stub],
    capture_output=True, text=True, timeout=30, env=env)
events = []
for ln in proc.stdout.splitlines():
    ln = ln.strip()
    if ln:
        events.append(json.loads(ln))
faults = [e for e in events if e.get("type") == "notice"
          and e.get("event") == "mic-fault"]
if not faults:
    sys.exit("mic fault: the refusal never reached the wire: "
             + repr(proc.stdout) + repr(proc.stderr[-500:]))
if proc.returncode != 1:
    sys.exit("mic fault: the bridge must exit 1 on a refused microphone, got "
             + str(proc.returncode))
if "no input device" not in faults[0].get("error", ""):
    sys.exit("mic fault: the notice must name the error: " + repr(faults[0]))
PY
pass "a microphone refusing to open surfaces as a mic-fault notice and a non-zero exit"

# --- the spoken reply, end to end through the bridge -------------------------
#
# The whole lane with every real component a worker shell can host: the
# committed speech clip wakes through a scripted decoder, the turn crosses to
# the stub relay, the reply PCM plays through a stub output stream, and a
# quit drains the buffered tail before the stream closes. The capture file is
# what the output device actually received.

SDSTUB="$TMP_ROOT/sdstub"
mkdir -p "$SDSTUB"
cat > "$SDSTUB/sounddevice.py" <<'SDPY'
import atexit
import os
import threading
import time

received = bytearray()


class RawOutputStream:
    def __init__(self, samplerate, channels, dtype, blocksize, device,
                 latency, callback):
        self.callback = callback
        self._running = True
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self):
        out = bytearray(4800)
        while self._running:
            self.callback(out, 2400, None, None)
            received.extend(out)
            time.sleep(0.02)

    def start(self):
        pass

    def stop(self):
        self._running = False

    def close(self):
        pass


def _dump():
    path = os.environ.get("FM_TEST_SPEAKER_CAPTURE")
    if path:
        with open(path, "wb") as fh:
            fh.write(bytes(received))


atexit.register(_dump)
SDPY

python3 - "$ROOT" "$STUB" "$SDSTUB" "$TMP_ROOT" <<'PY' || fail "spoken reply"
import json, os, subprocess, sys, threading, time
root, stub, sdstub, tmp = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def check(cond, label):
    if not cond:
        sys.exit("spoken reply: " + label)

# The speech clip wakes the turn; trailing silence ends it, which is when
# the stub relay answers.
speech = open(os.path.join(root, "tests/assets/voice-hud-speech.pcm"), "rb").read()
silence = open(os.path.join(root, "tests/assets/voice-hud-silence.pcm"), "rb").read()
mic_path = os.path.join(tmp, "spoken-reply.pcm")
with open(mic_path, "wb") as fh:
    fh.write(speech + silence * 3)

capture = os.path.join(tmp, "speaker-capture.pcm")
if os.path.exists(capture):
    os.unlink(capture)

env = dict(os.environ)
env["FM_TEST_SPEAKER_CAPTURE"] = capture
env["FM_VOICE_HUD_DECODER"] = (
    "python3 -c 'import sys, time; time.sleep(0.5); "
    "print(\"Ziggy\"); sys.stdout.flush(); sys.stdin.read()'")
env["PYTHONPATH"] = sdstub + (
    os.pathsep + env["PYTHONPATH"] if env.get("PYTHONPATH") else "")

proc = subprocess.Popen(
    [sys.executable, os.path.join(root, "hud", "fm_voice_hud_bridge.py"),
     "--stub-relay", stub, "--mic-file", mic_path],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)

events = []
def read_events():
    for line in proc.stdout:
        line = line.strip()
        if line:
            events.append(json.loads(line))
threading.Thread(target=read_events, daemon=True).start()

def index_of(pred, start=0):
    for i in range(start, len(events)):
        if pred(events[i]):
            return i
    return -1

# The full reply cycle: thinking when the turn opens, speaking when the
# reply audio arrives, listening again at the reply_end mark.
deadline = time.monotonic() + 20
while True:
    spoke = index_of(lambda e: e.get("type") == "state"
                     and e.get("state") == "speaking")
    settled = index_of(lambda e: e.get("type") == "state"
                       and e.get("state") == "listening", spoke + 1)
    if spoke >= 0 and settled >= 0:
        break
    if time.monotonic() > deadline:
        proc.kill()
        sys.exit("spoken reply: the reply never settled: " + repr(events))
    time.sleep(0.1)
check(any(e.get("type") == "transcript" and e.get("text") == "stub heard you"
         for e in events), "the reply transcript must arrive: " + repr(events))

# The quit drains the buffered tail before the stream closes, and stays
# bounded well under the drain's own timeout.
proc.stdin.write("quit\n")
proc.stdin.flush()
t0 = time.monotonic()
try:
    rc = proc.wait(timeout=15)
except subprocess.TimeoutExpired:
    proc.kill()
    sys.exit("spoken reply: the quit drain did not stay bounded")
check(rc == 0, "the bridge must exit zero after a spoken reply: " + str(rc))
check(time.monotonic() - t0 < 10,
      "the quit drain must return well inside its bound")

with open(capture, "rb") as fh:
    played = fh.read()
check(b"\x01\x02" * 240 in played,
      "the reply PCM must have reached the output stream: {} bytes played".format(
          len(played)))
PY
pass "the spoken reply reaches the output stream end to end and a quit drains its tail"

# --- the live mic level and wake-gate state ride the wire ---------------------
#
# The debug surface that makes a silent room distinguishable from a mic not
# heard: every block the mic end captures is reported with a 0..1 level and
# the wake gate's own phase, so the panel can always show both. The speech
# clip drives the level to its top and the scripted decoder walks the gate
# from listening through the wake into the turn.

python3 - "$ROOT" "$STUB" "$TMP_ROOT" <<'PY' || fail "mic level wire"
import json, os, subprocess, sys, threading, time
root, stub, tmp = sys.argv[1], sys.argv[2], sys.argv[3]

speech = open(os.path.join(root, "tests/assets/voice-hud-speech.pcm"), "rb").read()
silence = open(os.path.join(root, "tests/assets/voice-hud-silence.pcm"), "rb").read()
mic_path = os.path.join(tmp, "mic-level.pcm")
with open(mic_path, "wb") as fh:
    fh.write(speech + silence * 2)

env = dict(os.environ)
env["FM_VOICE_HUD_DECODER"] = (
    "python3 -c 'import sys, time; time.sleep(0.5); "
    "print(\"Ziggy\"); sys.stdout.flush(); sys.stdin.read()'")
proc = subprocess.Popen(
    [sys.executable, os.path.join(root, "hud", "fm_voice_hud_bridge.py"),
     "--stub-relay", stub, "--mic-file", mic_path],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)

events = []
def read_events():
    for line in proc.stdout:
        line = line.strip()
        if line:
            events.append(json.loads(line))
threading.Thread(target=read_events, daemon=True).start()

deadline = time.monotonic() + 20
while True:
    mic_events = [e for e in events if e.get("type") == "mic"]
    gates = [e.get("gate") for e in mic_events]
    levels = [e.get("level", 0) for e in mic_events]
    # The gate must cross listening -> in-turn and come back: the return
    # happens only after the trailing silence has crossed the wire.
    reopened = False
    for i, gate in enumerate(gates):
        if gate == "in-turn":
            if "listening" in gates[i + 1:]:
                reopened = True
            break
    if mic_events and reopened and max(levels) >= 0.5:
        break
    if time.monotonic() > deadline:
        proc.kill()
        sys.exit("mic level: the level and gate never crossed the wire: "
                 + repr(mic_events[:6]))
    time.sleep(0.1)

if min(levels) != 0:
    sys.exit("mic level: silence must report level 0: " + repr(sorted(set(levels))))
if max(levels) < 0.5:
    sys.exit("mic level: the speech clip must drive the level high: "
             + str(max(levels)))

proc.stdin.write("quit\n")
proc.stdin.flush()
try:
    rc = proc.wait(timeout=10)
except subprocess.TimeoutExpired:
    proc.kill()
    sys.exit("mic level: the bridge did not stay quittable")
if rc != 0:
    sys.exit("mic level: the bridge must quit zero: " + str(rc))
PY
pass "the live mic level and wake-gate state ride the wire to the panel"

# --- a failed turn reaches the panel with its reason --------------------------
#
# The same failure against the whole bridge: the relay's turn-failed notice
# must cross the boundary as a notice carrying the reason, return the HUD to
# listening without waiting out the turn timeout, and leave the bridge
# quittable.

python3 - "$ROOT" "$STUB_FAIL" "$TMP_ROOT" <<'PY' || fail "failed turn"
import json, os, subprocess, sys, threading, time
root, stub, tmp = sys.argv[1], sys.argv[2], sys.argv[3]

speech = open(os.path.join(root, "tests/assets/voice-hud-speech.pcm"), "rb").read()
silence = open(os.path.join(root, "tests/assets/voice-hud-silence.pcm"), "rb").read()
mic_path = os.path.join(tmp, "failed-turn.pcm")
with open(mic_path, "wb") as fh:
    fh.write(speech + silence * 3)

env = dict(os.environ)
env["FM_VOICE_HUD_DECODER"] = (
    "python3 -c 'import sys, time; time.sleep(0.5); "
    "print(\"Ziggy\"); sys.stdout.flush(); sys.stdin.read()'")
proc = subprocess.Popen(
    [sys.executable, os.path.join(root, "hud", "fm_voice_hud_bridge.py"),
     "--stub-relay", stub, "--mic-file", mic_path],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)

events = []
def read_events():
    for line in proc.stdout:
        line = line.strip()
        if line:
            events.append(json.loads(line))
threading.Thread(target=read_events, daemon=True).start()

def index_of(pred, start=0):
    for i in range(start, len(events)):
        if pred(events[i]):
            return i
    return -1

# The turn opens, the relay fails it, and the HUD is listening again - all
# without the mic thread burning its 120s turn timeout. The release lands
# on the wire just ahead of the notice that names it.
deadline = time.monotonic() + 20
while True:
    opened = index_of(lambda e: e.get("type") == "state"
                      and e.get("state") == "thinking")
    failed = index_of(lambda e: e.get("type") == "notice"
                      and e.get("event") == "turn-failed", opened + 1)
    settled = index_of(lambda e: e.get("type") == "state"
                       and e.get("state") == "listening", opened + 1)
    if opened >= 0 and failed >= 0 and settled >= 0:
        break
    if time.monotonic() > deadline:
        proc.kill()
        sys.exit("failed turn: the failure never settled: " + repr(events))
    time.sleep(0.1)
if events[failed].get("error") != "RuntimeError: the model stream broke":
    sys.exit("failed turn: the notice must carry the relay's reason: "
             + repr(events[failed]))

proc.stdin.write("quit\n")
proc.stdin.flush()
try:
    rc = proc.wait(timeout=10)
except subprocess.TimeoutExpired:
    proc.kill()
    sys.exit("failed turn: the bridge did not stay quittable")
if rc != 0:
    sys.exit("failed turn: the bridge must quit zero after a failed turn: "
             + str(rc))
PY
pass "a failed turn reaches the panel with its reason and the HUD re-arms"

# --- configuration fails loud -------------------------------------------------
#
# The brief's config contract: one config/voice-hud* file per value with an
# environment override, no default naming somebody's port or path, and a
# refusal that names the file to write. The decoder command is the HUD's one
# configurable value in this lane; absent means gate-only, never a silent
# fallback to some invented decoder.

python3 - "$ROOT" "$STUB" "$TMP_ROOT" <<'PY' || fail "hud config"
import json, os, subprocess, sys, threading, time
root, stub, tmp = sys.argv[1], sys.argv[2], sys.argv[3]

def check(cond, label):
    if not cond:
        sys.exit("config: " + label)

# The engine's relay attach refuses loud when the home has no voice engine
# configured: no default endpoint, no guessed port.
env = dict(os.environ)
env.pop("FM_VOICE_HUD_DECODER", None)
proc = subprocess.run(
    [sys.executable, "-c",
     "import sys; sys.path.insert(0, sys.argv[1]); sys.path.insert(0, sys.argv[2]);"
     "import fm_voice_engine as e; print(' '.join(e.relay_argv(home=sys.argv[3])))",
     os.path.join(root, "hud"), os.path.join(root, "bin"), os.path.join(tmp, "empty-home")],
    capture_output=True, text=True, env=env)
check(proc.returncode == 0, "relay_argv must build for any home: " + proc.stderr)
check("--serve" in proc.stdout and "--home" in proc.stdout,
      "the relay attach must be --serve with the home named: " + proc.stdout)
check("127.0.0.1" not in proc.stdout and "localhost" not in proc.stdout,
      "no default endpoint may appear in the relay attach")

# A decoder command from the environment is honored verbatim, shell-joined,
# and the bridge names its source on the boundary when it attaches one.
env2 = dict(os.environ)
env2["FM_VOICE_HUD_DECODER"] = "echo ziggy"
proc = subprocess.Popen(
    [sys.executable, os.path.join(root, "hud", "fm_voice_hud_bridge.py"),
     "--stub-relay", stub,
     "--mic-file", os.path.join(root, "tests/assets/voice-hud-silence.pcm")],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env2)

events = []
def read_events():
    for line in proc.stdout:
        line = line.strip()
        if line:
            events.append(json.loads(line))
threading.Thread(target=read_events, daemon=True).start()

deadline = time.monotonic() + 10
while not any(e.get("type") == "notice" and e.get("event") == "decoder"
              for e in events):
    if time.monotonic() > deadline:
        proc.kill()
        sys.exit("config: the decoder notice never arrived: " + repr(events))
    time.sleep(0.1)
source = [e for e in events if e.get("event") == "decoder"][0].get("source")
check(source == "FM_VOICE_HUD_DECODER",
      "the environment override must be named as the decoder source: " + repr(source))
proc.stdin.write("quit\n")
proc.stdin.flush()
try:
    rc = proc.wait(timeout=10)
except subprocess.TimeoutExpired:
    proc.kill()
    sys.exit("config: the bridge did not exit on quit")
check(rc == 0, "the bridge must exit zero on a clean quit")
PY
pass "the HUD's configuration carries no default endpoint and honors its one override"
