#!/usr/bin/env python3
"""fm_voice_speaker.py - the HUD's reply player.

The engine hands reply audio to the player whole - 24000 Hz mono 16-bit LE,
the relay's answer rate - and this module owns the output device from there.
It is the client's speaker playback carried into the HUD: the same
RawOutputStream, the same callback-drained buffer, minus the measurement
accounting that exists only for the client's turn records.

The DEVICE is UNVERIFIED, as the client's is: no output device exists in a
worker shell, so the first live run is on the captain's Mac. The buffering
and the close discipline are what the offline checks drive, against a stub
stream with the callback driven by hand.
"""

import threading
import time

# 100 ms at the reply rate, the client's output block.
OUT_BLOCK = 2400


class Speaker:
    """Play reply PCM through the output device.

    write() queues bytes from the engine's reader thread; the device's own
    callback drains the queue in order and pads with silence whenever the
    engine has not kept it full, so a slow reply never blocks the wire and a
    fast one never plays out of order.
    """

    def __init__(self, device=None):
        import sounddevice                    # noqa: PLC0415
        self._buffer = bytearray()
        self._lock = threading.Lock()
        self._closed = False
        # Monotonic time the device last played reply audio; the mic side
        # reads it to stay deaf to the HUD's own voice.
        self.last_sound = None
        self.muted = False
        self.out_level = 0.0
        self._stream = sounddevice.RawOutputStream(
            samplerate=24000, channels=1, dtype="int16",
            blocksize=OUT_BLOCK, device=device, latency="low",
            callback=self._callback)
        self._stream.start()

    def _callback(self, outdata, frames_wanted, time_info, status):
        del time_info, status
        want = frames_wanted * 2
        with self._lock:
            take = min(want, len(self._buffer))
            chunk = bytes(self._buffer[:take])
            del self._buffer[:take]
        outdata[:take] = chunk
        if take:
            self.last_sound = time.monotonic()
            # Loudness of what is playing, 0..1, for the critter's mouth.
            samples = [int.from_bytes(chunk[i:i + 2], "little", signed=True)
                       for i in range(0, take - 1, 64)]
            if samples:
                peak = max(abs(v) for v in samples)
                self.out_level = min(1.0, peak / 12000.0)
        else:
            self.out_level = 0.0
        if take < want:
            outdata[take:want] = b"\x00" * (want - take)

    def write(self, pcm):
        """Queue one chunk of reply audio; a write after close is dropped,
        because no callback remains to drain it, and so is one while muted."""
        with self._lock:
            if self._closed or self.muted:
                return
            self._buffer += pcm

    def set_muted(self, muted):
        """The panel's mute: silence Ziggy's voice too, dropping anything
        queued, so a guest in the room hears nothing from it."""
        with self._lock:
            self.muted = muted
            if muted:
                self._buffer = bytearray()

    def sounding(self, tail=0.8):
        """Whether reply audio is queued, playing, or ended under `tail` seconds
        ago (room echo). Unsolicited speech - a background answer - reaches
        the speaker with no turn blocking the microphone, so the mic side
        asks this instead."""
        with self._lock:
            if self._buffer:
                return True
        last = self.last_sound
        return last is not None and time.monotonic() - last < tail

    def drain(self, timeout=30):
        """Wait for the buffered reply to finish, so a quit right after an
        answer does not cut it off."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self._lock:
                if not self._buffer:
                    break
            time.sleep(0.05)
        time.sleep(0.2)

    def close(self):
        # Marked before the stream is stopped and not while the lock is
        # held: the device callback takes this lock, and stop() waits for a
        # callback already running, so holding it across the stop is a
        # deadlock.
        with self._lock:
            self._closed = True
        try:
            self._stream.stop()
            self._stream.close()
        except Exception:                      # noqa: BLE001
            pass
