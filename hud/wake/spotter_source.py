"""spotter_source.py - the wake spotter as a child process, for TurnDirector.

Same shape as fm_voice_mic.DecoderCommand: PCM blocks in on stdin, lines
out on stdout, so no model code enters the HUD process. The spotter sees
EVERY block (quiet ones too: its 2 s context window needs continuous
audio, and a block costs ~1-2 ms), and answers within the same block.

    src = SpotterCommand([venv_python, ".../hud/wake/ziggy_spotter.py"])
    src.start()
    src.feed(block)             # every mic block
    for wake in src.poll():     # non-blocking; [(score, audio_seconds)]
        ...
"""

import os
import select
import subprocess


class SpotterCommand:
    def __init__(self, argv):
        self.argv = list(argv)
        self.proc = None
        self._buf = bytearray()
        self.dead = None

    def start(self):
        self.proc = subprocess.Popen(self.argv, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE)

    def feed(self, block):
        if self.dead is not None:
            return
        try:
            self.proc.stdin.write(block)
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError) as exc:
            # The spotter only speeds the wake up; the decoder still wakes
            # the HUD without it, so a dead spotter is latched, not raised.
            self.dead = "{}: {}".format(type(exc).__name__, exc)

    def poll(self):
        if self.proc is None:
            return []
        fd = self.proc.stdout.fileno()
        while select.select([fd], [], [], 0)[0]:
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            self._buf += chunk
        out = []
        while b"\n" in self._buf:
            line, _, self._buf = self._buf.partition(b"\n")
            parts = line.decode("utf-8", "replace").split()
            if len(parts) == 3 and parts[0] == "wake":
                out.append((float(parts[1]), float(parts[2])))
        return out

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


class NullSpotter:
    def start(self):
        pass

    def feed(self, block):
        pass

    def poll(self):
        return []

    def close(self):
        pass
