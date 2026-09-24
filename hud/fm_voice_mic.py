#!/usr/bin/env python3
"""fm_voice_mic.py - the microphone, gated by the wake layer.

The microphone is the captain's, and it stays local: every block from the
device goes to the energy gate and nothing else, until the wake word fires.
Only then does audio cross into the relay child, and only while the turn is
open. hud/fm_voice_wake.py owns both decisions (is this speech, is this the
word); this module owns the plumbing: blocks in, turn lifecycle out.

Two capture ends, one contract:
  DeviceMic  the real microphone, through sounddevice. UNVERIFIED headlessly
             for the same reason the client's is: no audio device exists in
             a worker shell. Written from the sounddevice interface.
  FileMic    a PCM file read as blocks. This is the end every offline check
             drives, because audio in checks is files, never a live device.

The decoder is a separate process by design: it reads PCM blocks and returns
transcript lines, so the model stack never enters this process. Its command
comes from config (config/voice-hud-decoder); absent means gate-only, in
which the HUD hears speech and never wakes - fail-loud happens at the bridge,
which knows whether a mic is attached.
"""

import os
import subprocess
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fm_voice_wake as wake_mod          # noqa: E402

# 100 ms at 16 kHz mono 16-bit, matching the client's chunk: the wake gate's
# timing bounds are expressed against this block size.
BLOCK = 3200

# Seconds after a wake with no further speech before the HUD gives up on the
# turn and says so. The turn is never opened, so nothing reaches the relay:
# a wake into silence must not cost the captain a model turn.
POST_WAKE_SPEECH_TIMEOUT = 5.0


class FileMic:
    """Read a 16 kHz mono 16-bit LE PCM file as blocks. The testable end."""

    def __init__(self, path):
        self._handle = open(path, "rb")
        self._closed = False

    def blocks(self):
        """Yield BLOCK-sized chunks until the file ends or close() is called."""
        while not self._closed:
            block = self._handle.read(BLOCK)
            if not block:
                return
            yield block

    def close(self):
        # Idempotent and called from another thread than the reader: the
        # reader checks _closed each loop, so the handle closes after the
        # in-flight read, never under it.
        if self._closed:
            return
        self._closed = True
        try:
            self._handle.close()
        except OSError:
            pass


class DeviceMic:
    """Capture from the microphone. UNVERIFIED: written from the sounddevice
    interface, never run against a real device from a worker shell. The
    stream stays open for the whole session because the wake gate, not the
    device, decides what is sent.
    """

    def __init__(self, device=None):
        import sounddevice                    # noqa: PLC0415
        self._q = None
        self._stream = sounddevice.RawInputStream(
            samplerate=16000, channels=1, dtype="int16",
            blocksize=BLOCK // 2, device=device, latency="low",
            callback=self._callback)
        self._stream.start()

    def _callback(self, indata, frames_read, time_info, status):
        del frames_read, time_info, status
        if self._q is not None:
            self._q.put(bytes(indata))

    def start(self, out_q):
        self._q = out_q

    def close(self):
        self._stream.stop()
        self._stream.close()


class DecoderCommand:
    """A decoder child: PCM blocks in on stdin, transcript lines out on stdout.

    The real decoder is the local Parakeet stack in its own virtual
    environment; this wrapper only speaks its generic contract, so the HUD
    process never imports model code. Transcript lines are final lines: one
    per utterance, in arrival order.
    """

    def __init__(self, argv):
        self.argv = list(argv)
        self.proc = None
        self.lock = threading.Lock()

    def start(self):
        self.proc = subprocess.Popen(
            self.argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    def feed(self, block):
        """Send one block; return every complete transcript line it produced."""
        with self.lock:
            if self.proc.stdin.closed:
                return []
            self.proc.stdin.write(block)
            self.proc.stdin.flush()
        # Non-blocking-ish: the decoder answers per utterance, not per block,
        # so lines are drained opportunistically; the director polls.
        return []

    def poll_transcripts(self):
        """Return transcript lines that have arrived, without blocking."""
        lines = []
        while True:
            line = self.proc.stdout.readline()
            if not line:
                break
            text = line.decode("utf-8", "replace").strip()
            if text:
                lines.append(text)
        return lines

    def close(self):
        if self.proc is None:
            return
        try:
            self.proc.stdin.close()
        except OSError:
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.proc.kill()


class NullDecoder:
    """Gate-only mode: speech is heard, no transcript ever arrives, the HUD
    never wakes. Exists so the bridge can run its engine and panel wiring
    before a decoder is configured."""

    def start(self):
        pass

    def feed(self, block):
        return []

    def poll_transcripts(self):
        return []

    def close(self):
        pass


class TurnDirector:
    """Own the turn lifecycle from gated mic blocks.

    The rules, one per line:
    - A block is speech or it is not (the gate decides).
    - Speech is the wake word or it is not (the keyword match decides, over
      decoder transcripts).
    - Only a wake opens a turn; while a turn is open every block goes to the
      engine; when the gate goes quiet past its hangover the turn ends.
    - A wake into silence never opens a turn: after POST_WAKE_SPEECH_TIMEOUT
      the HUD reports no-speech and re-arms, because a silent turn would cost
      the captain a model turn and answer nothing.
    """

    LISTENING = "listening"
    IN_WAKE = "in-wake"
    IN_TURN = "in-turn"

    def __init__(self, engine, gate, keyword, decoder, on_notice=None,
                 speech_timeout=POST_WAKE_SPEECH_TIMEOUT):
        self.engine = engine
        self.gate = gate
        self.keyword = keyword
        self.decoder = decoder
        self.on_notice = on_notice or (lambda event: None)
        self.speech_timeout = speech_timeout
        self.phase = self.LISTENING
        self._wake_at = None
        self._turned = False

    def feed(self, block, now):
        """Feed one block at monotonic time `now`. Returns the phase after.

        The energy gate is the first and cheapest decision: a silent block
        goes nowhere at all - not to the decoder, not to the engine - so the
        microphone streams nowhere while the room is quiet. Only voiced
        blocks are decoded, and only after a wake does audio reach the
        engine.

        Two different facts must not be confused: whether the channel is
        active (speech, or a pause shorter than the hangover) and whether
        THIS block carries speech. A turn opens only on the second: opening
        on hangover-held silence streamed half a second of zeros to the
        relay and cost a model turn whenever the captain said the wake word
        and then paused.
        """
        loud = wake_mod.block_energy(block) >= self.gate.floor
        channel = self.gate.feed(block, now)

        if not loud:
            # Silence or room tone, whatever the hangover says about the
            # pause. The block itself is forwarded nowhere.
            if self.phase == self.IN_TURN and not channel:
                self.engine.end_turn()
                self.phase = self.LISTENING
                self._wake_at = None
            elif self.phase == self.IN_WAKE and \
                    now - self._wake_at >= self.speech_timeout:
                self.phase = self.LISTENING
                self._wake_at = None
                self.on_notice("no-speech")
            return self.phase

        self.decoder.feed(block)

        if self.phase == self.LISTENING:
            for text in self.decoder.poll_transcripts():
                if self.keyword.feed(text):
                    self.phase = self.IN_WAKE
                    self._wake_at = now
                    self.on_notice("wake")
                    break
        elif self.phase == self.IN_WAKE:
            # Speech followed the wake: open the turn and stream.
            self.engine.begin_turn()
            self.engine.feed(block)
            self.phase = self.IN_TURN
        elif self.phase == self.IN_TURN:
            self.engine.feed(block)
        return self.phase
