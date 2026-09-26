#!/usr/bin/env python3
"""fm_voice_aec.py - the microphone and speaker through macOS echo cancellation.

VoiceAudio (hud/swift, target VoiceAudio) runs both ends in one
AUVoiceProcessingIO unit, the echo canceller FaceTime uses, so Ziggy's own
voice is taken out of the microphone. That is what lets the captain talk over
Ziggy: whatever the microphone still hears while Ziggy speaks is them.

One object stands in for both DeviceMic (blocks, close) and Speaker (write,
flush, sounding, set_muted, drain, close, out_level), because one child
process owns both ends. Playback timing is tracked here from what was sent:
the helper plays in real time, so a chunk written now ends at
max(now, end of the previous one) + its length.
"""

import collections
import os
import queue
import struct
import subprocess
import threading
import time

import fm_voice_mic as mic_mod
import fm_voice_speaker as speaker_mod

REPLY_RATE = 24000
AUDIO, FLUSH = 1, 2
READY_TIMEOUT = 20.0     # voice processing can take several seconds to come up


def helper_path():
    """The VoiceAudio binary: FM_VOICE_AUDIO_HELPER, or the package build."""
    path = os.environ.get("FM_VOICE_AUDIO_HELPER")
    if path:
        return path
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(here, "swift", ".build", "release", "VoiceAudio")


class VoiceIO:
    def __init__(self, helper=None, gain=speaker_mod.OUT_GAIN, on_silent=None):
        helper = helper or helper_path()
        if not os.path.isfile(helper):
            raise FileNotFoundError(helper)
        self.gain = gain
        self._proc = subprocess.Popen(
            [helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE)
        ready = []
        began = time.monotonic()
        reader = threading.Thread(
            target=lambda: ready.append(self._proc.stderr.readline()), daemon=True)
        reader.start()
        reader.join(READY_TIMEOUT)
        if not ready or b"ready" not in ready[0]:
            self._proc.kill()
            raise RuntimeError("VoiceAudio did not start: {!r}".format(
                ready[0].decode(errors="replace").strip() if ready else "timeout"))
        self.startup_seconds = round(time.monotonic() - began, 2)
        threading.Thread(target=self._drain_stderr, daemon=True).start()
        self._write_lock = threading.Lock()
        self._lock = threading.Lock()
        self._closed = False
        self.muted = False
        self._drop_until = None
        self._play_end = 0.0
        self._levels = collections.deque()   # (start, end, level) of queued chunks
        self.last_sound = None
        self._q = queue.SimpleQueue()
        self._on_silent = on_silent
        self._silent_after = max(1, int(round(
            mic_mod.SILENT_NOTICE_AFTER_SECONDS * 16000 / (mic_mod.BLOCK // 2))))
        threading.Thread(target=self._read_mic, daemon=True).start()

    # ------------------------------------------------------------ microphone

    def _drain_stderr(self):
        for _ in iter(self._proc.stderr.readline, b""):
            pass

    def _read_mic(self):
        zero_run, notified = 0, False
        out = self._proc.stdout
        while True:
            block = out.read(mic_mod.BLOCK)
            if not block or len(block) < mic_mod.BLOCK:
                break
            if any(block):
                zero_run, notified = 0, False
            else:
                zero_run += 1
                if zero_run >= self._silent_after and not notified:
                    notified = True
                    if self._on_silent is not None:
                        self._on_silent()
            self._q.put(block)
        self._q.put(None)

    def blocks(self):
        while True:
            block = self._q.get()
            if block is None:
                return
            yield block

    # ------------------------------------------------------------ speaker

    def _send(self, kind, body=b""):
        with self._write_lock:
            try:
                self._proc.stdin.write(bytes([kind]) + struct.pack("<I", len(body)) + body)
                self._proc.stdin.flush()
            except (BrokenPipeError, ValueError, OSError):
                pass

    def write(self, pcm):
        with self._lock:
            if self._closed or self.muted:
                return
            now = time.monotonic()
            if self._drop_until and now < self._drop_until:
                return
            pcm = speaker_mod.amplify(pcm, self.gain)
            start = max(now, self._play_end)
            self._play_end = start + len(pcm) / 2 / REPLY_RATE
            level = 0.0
            if len(pcm) >= 2:
                samples = memoryview(pcm).cast("h")[::32]
                level = min(1.0, max(abs(v) for v in samples) / 12000.0) if len(samples) else 0.0
            self._levels.append((start, self._play_end, level))
        self._send(AUDIO, pcm)

    def flush(self):
        with self._lock:
            self._play_end = 0.0
            self._levels.clear()
            self._drop_until = time.monotonic() + speaker_mod.FLUSH_DROP_S
        self._send(FLUSH)
        self.last_sound = None

    def set_muted(self, muted):
        with self._lock:
            self.muted = muted
        if muted:
            self.flush()

    @property
    def out_level(self):
        now = time.monotonic()
        with self._lock:
            while self._levels and self._levels[0][1] < now:
                self._levels.popleft()
            if self._levels and self._levels[0][0] <= now:
                self.last_sound = now
                return self._levels[0][2]
        return 0.0

    def sounding(self, tail=0.8):
        """Reply audio playing, or ended under `tail` seconds ago."""
        with self._lock:
            return time.monotonic() < self._play_end + tail

    def drain(self, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and self.sounding(tail=0):
            time.sleep(0.05)

    def close(self):
        with self._lock:
            if self._closed:
                return
            self._closed = True
        try:
            self._proc.stdin.close()
        except OSError:
            pass
        try:
            self._proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self._proc.kill()
