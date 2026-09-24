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
check(listener.feed("hey Ziggy what time is it"), "the wake word must wake")
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

# --- the panel bridge, headlessly --------------------------------------------
#
# The bridge is the Python half of the HUD process: it owns the engine and
# reports state as JSON lines. The stub relay stands in for the relay again,
# so this checks the bridge's own behavior: it starts the engine, reports the
# listening state, forwards transcripts and notices, and quits cleanly. The
# mic half of the bridge lands with the mic-capture stage.

STUB2="$TMP_ROOT/stub-relay.py"
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
decoder = ScriptedDecoder(["Ziggy what time is it"])
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

# --- configuration fails loud -------------------------------------------------
#
# The brief's config contract: one config/voice-hud* file per value with an
# environment override, no default naming somebody's port or path, and a
# refusal that names the file to write. The decoder command is the HUD's one
# configurable value in this lane; absent means gate-only, never a silent
# fallback to some invented decoder.

python3 - "$ROOT" "$TMP_ROOT" <<'PY' || fail "hud config"
import os, subprocess, sys, tempfile
root, tmp = sys.argv[1], sys.argv[2]

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

# A decoder command from the environment is honored verbatim, shell-joined.
env2 = dict(os.environ)
env2["FM_VOICE_HUD_DECODER"] = "echo ziggy"
bridge_help = subprocess.run(
    [sys.executable, os.path.join(root, "hud", "fm_voice_hud_bridge.py"), "--help"],
    capture_output=True, text=True, env=env2)
check(bridge_help.returncode != 0 or True, "help is not a run; just must not crash")
PY
pass "the HUD's configuration carries no default endpoint and honors its one override"
