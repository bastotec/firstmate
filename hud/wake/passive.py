"""passive.py - keep what the HUD hears between turns, for retraining and recall.

Every utterance the microphone picks up while Ziggy is idle (not in a turn,
not speaking, not muted) is saved as 16 kHz mono s16le PCM, transcribed
locally with FluidAudio (Parakeet on the Neural Engine), and indexed:

    passive/YYYY-MM-DD/HHMMSS-mmm.pcm
    passive/YYYY-MM-DD/index.jsonl   {"t", "path", "seconds", "text", "ziggy"}

Utterances without the wake word become "not Ziggy" training examples for the
nightly retrain (retrain_passive.py); the index doubles as a searchable log of
what was said. Nothing leaves this Mac.
"""
import json
import os
import queue
import re
import struct
import subprocess
import sys
import tempfile
import threading
import time
import wave

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "passive")
SR = 16000
BLOCK_S = 0.1
QUIET_END_S = 0.8          # this much quiet ends an utterance
MIN_SPEECH_S = 0.4         # shorter bursts (clicks, a cough) are not kept
MAX_UTTERANCE_S = 30.0
PREROLL_BLOCKS = 3         # keep the syllable before the gate opened
WAKE = re.compile(r"\b(ziggy|ziggie|ziggi|zigy|ziggys|zeggy|zaggy|diggy|siggy)\b", re.I)
FLUID_CLI = "/Applications/Vowen.app/Contents/Resources/bin/fluidaudio-cli"
FLUID_MODEL = os.path.expanduser(
    "~/Library/Application Support/vowen/models/parakeet-tdt-0.6b-v3")


class Transcriber:
    """A private fluidaudio-cli daemon (Parakeet TDT on CoreML)."""

    def __init__(self):
        self.proc = subprocess.Popen(
            [FLUID_CLI, "--daemon", "--asr-model-dir", FLUID_MODEL, "--asr-version", "v3"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.n = 0
        while True:
            line = self.proc.stdout.readline()
            if not line or json.loads(line).get("type") == "ready":
                break

    def text(self, pcm):
        handle, path = tempfile.mkstemp(suffix=".wav", prefix="passive-")
        os.close(handle)
        with wave.open(path, "wb") as out:
            out.setnchannels(1)
            out.setsampwidth(2)
            out.setframerate(SR)
            out.writeframes(pcm)
        self.n += 1
        rid = "p%d" % self.n
        body = json.dumps({"id": rid, "type": "transcribe", "filePath": path,
                           "timestamps": False, "cleanup": True}).encode()
        self.proc.stdin.write(b"\x01" + struct.pack("<I", len(body)) + body)
        self.proc.stdin.flush()
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError("fluidaudio-cli exited")
            msg = json.loads(line)
            if msg.get("id") == rid:
                return (msg.get("text") or "").strip()

    def close(self):
        try:
            self.proc.kill()
        except OSError:
            pass


class PassiveCollector:
    """Segment idle-time speech from mic blocks and save it off the mic thread."""

    def __init__(self, floor_fn):
        # floor_fn() -> the HUD energy gate's current voiced threshold, so the
        # collector hears speech exactly where the HUD does.
        self.floor_fn = floor_fn
        self.q = queue.Queue(maxsize=64)
        self.pre = []
        self.cur = None
        self.voiced = 0
        self.quiet = 0
        threading.Thread(target=self._worker, name="passive-collector", daemon=True).start()

    def feed(self, block, idle):
        """Call for every mic block. `idle`: Ziggy is listening for its name,
        not in a turn, speaking or muted. Anything else ends the utterance
        without keeping it."""
        if not idle:
            self.pre, self.cur, self.voiced, self.quiet = [], None, 0, 0
            return
        x = np.frombuffer(block, dtype="<i2").astype(np.float64)
        loud = float(np.mean(x * x)) >= self.floor_fn()
        if self.cur is None:
            if loud:
                self.cur = self.pre + [block]
                self.voiced, self.quiet = 1, 0
            else:
                self.pre = (self.pre + [block])[-PREROLL_BLOCKS:]
            return
        self.cur.append(block)
        if loud:
            self.voiced += 1
            self.quiet = 0
        else:
            self.quiet += 1
        if self.quiet * BLOCK_S >= QUIET_END_S or len(self.cur) * BLOCK_S >= MAX_UTTERANCE_S:
            if self.voiced * BLOCK_S >= MIN_SPEECH_S:
                try:
                    self.q.put_nowait((time.time(), b"".join(self.cur)))
                except queue.Full:
                    pass
            self.pre, self.cur, self.voiced, self.quiet = [], None, 0, 0

    def _worker(self):
        asr = None
        while True:
            stamp, pcm = self.q.get()
            try:
                if asr is None:
                    asr = Transcriber()
                text = asr.text(pcm)
            except Exception as exc:        # noqa: BLE001
                if asr is not None:
                    asr.close()
                text, asr = "", None
                sys.stderr.write("passive: transcription failed: %s\n" % exc)
            day = time.strftime("%Y-%m-%d", time.localtime(stamp))
            folder = os.path.join(ROOT, day)
            os.makedirs(folder, exist_ok=True)
            name = time.strftime("%H%M%S", time.localtime(stamp)) + "-%03d.pcm" % int((stamp % 1) * 1000)
            path = os.path.join(folder, name)
            with open(path, "wb") as out:
                out.write(pcm)
            record = {"t": round(stamp, 3), "path": path,
                      "seconds": round(len(pcm) / 2 / SR, 2), "text": text,
                      "ziggy": bool(WAKE.search(text))}
            with open(os.path.join(folder, "index.jsonl"), "a") as index:
                index.write(json.dumps(record, ensure_ascii=False) + "\n")
