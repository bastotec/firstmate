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
import queue
import select
import subprocess
import sys
import threading

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fm_voice_wake as wake_mod          # noqa: E402

# 100 ms at 16 kHz mono 16-bit, matching the client's chunk: the wake gate's
# timing bounds are expressed against this block size.
BLOCK = 3200

# Seconds of the shipped capture bound that all-zero input must persist
# before the HUD says so on the wire. A microphone the system denies does
# not fail to open - it opens and delivers digital silence, which is
# indistinguishable from not-heard unless someone counts. The count is the
# product's own: after this bound the panel is told the mic is denied.
SILENT_NOTICE_AFTER_SECONDS = 2.0

# Seconds after a wake with no further speech before the HUD gives up on the
# turn and says so. The turn is never opened, so nothing reaches the relay:
# a wake into silence must not cost the captain a model turn.
POST_WAKE_SPEECH_TIMEOUT = 5.0

# Longest listening utterance kept for a one-breath "Ziggy, <command>" turn.
# The decoder names the wake word only after the whole utterance ends, so the
# command's audio has to be held until then or it is gone. 30 s at BLOCK size.
UTTERANCE_KEEP_BLOCKS = 300

# With the fast spotter: audio sent ahead of the spot, so the turn carries
# "Ziggy" itself and anything said in the same breath (1.5 s at BLOCK size).
SPOT_PREROLL_BLOCKS = 15

# With the fast spotter: after the name, how long a pause may last before the
# command starts ("Ziggy ... what's the status?") without the turn ending.
SPOT_COMMAND_GRACE = 3.0

# Conversation window: after Ziggy answers, speech opens the next turn without
# the wake word until this many seconds pass with no speech, or the captain
# stands Ziggy down.
FOLLOW_UP_SECONDS = 8.0

# Blocks of audio kept ahead of speech that opens a follow-up turn, so its
# first syllable is not clipped (0.4 s).
FOLLOW_UP_PREROLL_BLOCKS = 4


class DecoderError(Exception):
    """The decoder child stopped taking audio, so the HUD can never wake."""


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

    Health the panel needs, said on the wire instead of staying quiet:
    `on_status(flag)` fires once per distinct PortAudio callback status
    (an input overflow is news), and `on_silent()` fires once per sustained
    run of all-zero blocks longer than `silent_after_blocks` - the digital
    silence a denied microphone delivers.
    """

    def __init__(self, device=None, on_silent=None, on_status=None,
                 silent_after_blocks=None):
        import sounddevice                    # noqa: PLC0415
        if device is None:
            # Name the default input device instead of letting PortAudio
            # guess: a machine with no input device fails here with the
            # device it tried in hand.
            device = sounddevice.default.device[0]
        self._q = queue.SimpleQueue()
        self._on_silent = on_silent
        self._on_status = on_status
        if silent_after_blocks is None:
            silent_after_blocks = max(1, int(round(
                SILENT_NOTICE_AFTER_SECONDS * 16000 / (BLOCK // 2))))
        self._silent_after = silent_after_blocks
        self._zero_run = 0
        self._silent_notified = False
        self._reported_status = set()
        self._stream = sounddevice.RawInputStream(
            samplerate=16000, channels=1, dtype="int16",
            blocksize=BLOCK // 2, device=device, latency="low",
            callback=self._callback)
        self._stream.start()

    def _callback(self, indata, frames_read, time_info, status):
        del frames_read, time_info
        if status:
            flag = str(status).strip()
            if flag and flag not in self._reported_status:
                self._reported_status.add(flag)
                if self._on_status is not None:
                    self._on_status(flag)
        block = bytes(indata)
        if any(block):
            self._zero_run = 0
            self._silent_notified = False
        else:
            self._zero_run += 1
            if self._zero_run >= self._silent_after \
                    and not self._silent_notified:
                self._silent_notified = True
                if self._on_silent is not None:
                    self._on_silent()
        self._q.put(block)

    def blocks(self):
        """Yield blocks as the device produces them, until close()."""
        while True:
            block = self._q.get()
            if block is None:
                return
            yield block

    def close(self):
        self._stream.stop()
        self._stream.close()
        # The sentinel is last: stop() has already waited out any running
        # callback, so nothing queues behind it and blocks() ends.
        self._q.put(None)


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
        self.dead = None

    def start(self):
        self.proc = subprocess.Popen(
            self.argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self._buf = bytearray()

    def feed(self, block):
        """Send one block; return every complete transcript line it produced.

        A child that exited takes its stdin with it: the first write says
        so, is latched, and raises once - the wake decision needs this
        child's transcripts, so a dead decoder is a fault the HUD must
        surface, never a silent no-op on every block.
        """
        if self.dead is not None:
            return []
        with self.lock:
            if self.proc.stdin.closed:
                return []
            try:
                self.proc.stdin.write(block)
                self.proc.stdin.flush()
            except (BrokenPipeError, OSError) as exc:
                self.dead = "the decoder closed its input: {}: {}".format(
                    type(exc).__name__, exc)
                raise DecoderError(self.dead) from None
        # Non-blocking-ish: the decoder answers per utterance, not per block,
        # so lines are drained opportunistically; the director polls.
        return []

    def poll_transcripts(self):
        """Return transcript lines that have arrived, without blocking.

        A readline here would own the mic thread for as long as the decoder
        stays quiet, so the drain reads only what is already on the pipe and
        keeps any partial line for the next poll. The child's stdout is read
        through the raw fd only, never through the buffered reader, so the
        two never race for the same bytes.
        """
        fd = self.proc.stdout.fileno()
        while select.select([fd], [], [], 0)[0]:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            self._buf += chunk
        lines = []
        while b"\n" in self._buf:
            line, _, rest = self._buf.partition(b"\n")
            self._buf = rest
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
    FOLLOW_UP = "follow-up"

    def __init__(self, engine, gate, keyword, decoder, on_notice=None,
                 speech_timeout=POST_WAKE_SPEECH_TIMEOUT, spotter=None):
        self.engine = engine
        # The fast wake source (hud/wake/ziggy_spotter.py as a child). When
        # present it replaces the decoder for waking: it hears the name
        # within ~0.1 s of the word, and the turn opens right then with the
        # held pre-roll, so the relay's own speech engine transcribes the
        # command. The slow decoder is then never fed.
        self.spotter = spotter
        self._preroll = []
        self._spoke_since_wake = False
        # Conversation window state: when it closes, and whether the captain
        # asked to stand down (set from the bridge on his transcript).
        self.follow_up_seconds = FOLLOW_UP_SECONDS
        self._follow_until = None
        self._stand_down = False
        self.gate = gate
        self.keyword = keyword
        self.decoder = decoder
        self.on_notice = on_notice or (lambda event: None)
        self.speech_timeout = speech_timeout
        self.phase = self.LISTENING
        self._wake_at = None
        self._turned = False
        # Listening audio of the utterance the decoder is still finalizing:
        # voiced blocks plus the short pauses inside it (channel active).
        self._utterance = []

    def _keep(self, block):
        self._utterance.append(block)
        if len(self._utterance) > UTTERANCE_KEEP_BLOCKS:
            del self._utterance[0]

    def _one_breath_turn(self):
        """Send the held utterance as a whole turn: "Ziggy, what's the status?"
        said in one breath carries its command in the same audio as the wake
        word, and the relay's model reads the name as an address."""
        self.engine.begin_turn()
        for held in self._utterance:
            self.engine.feed(held)
        self.engine.end_turn()
        self._utterance = []
        self.phase = self.LISTENING
        self._wake_at = None

    def feed(self, block, now):
        """Feed one block at monotonic time `now`. Returns the phase after.

        The energy gate is the first and cheapest decision: a silent block
        goes nowhere at all - not to the decoder, not to the engine - so the
        microphone streams nowhere while the room is quiet. Only voiced
        blocks are decoded, and only while the HUD listens; from the wake
        onward, audio reaches the engine alone.

        Two different facts must not be confused: whether the channel is
        active (speech, or a pause shorter than the hangover) and whether
        THIS block carries speech. A turn opens only on the second: opening
        on hangover-held silence streamed half a second of zeros to the
        relay and cost a model turn whenever the captain said the wake word
        and then paused.
        """
        if self.spotter is not None:
            return self._feed_spotted(block, now)
        loud = wake_mod.block_energy(block) >= self.gate.floor
        channel = self.gate.feed(block, now)

        if not loud:
            # Silence or room tone, whatever the hangover says about the
            # pause. The block goes to no one live; a pause inside a listening
            # utterance is only held for a possible one-breath turn.
            if self.phase == self.LISTENING:
                if channel:
                    self._keep(block)
                # The decoder's final line lands in the trailing quiet, after
                # the last loud block, so it is checked here too.
                if self._check_wake(self.decoder.poll_transcripts(), now):
                    return self.phase
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

        phase = self.phase
        # The decoder hears listening-phase audio only: speech inside a wake
        # or an open turn belongs to the engine alone, so the decoder can
        # never finalize a line for it, however late that line lands - a
        # per-utterance decoder's final line arrives during the trailing
        # quiet, after the turn's last loud block. Still drained on every
        # loud block, so a late line from listening speech is discarded
        # where it sits instead of buffering to arm a stale wake.
        if phase == self.LISTENING:
            self.decoder.feed(block)
            self._keep(block)
        transcripts = self.decoder.poll_transcripts()

        if phase == self.LISTENING:
            self._check_wake(transcripts, now)
        elif phase == self.IN_WAKE:
            # Speech followed the wake: open the turn and stream.
            self.engine.begin_turn()
            self.engine.feed(block)
            self.phase = self.IN_TURN
        elif phase == self.IN_TURN:
            self.engine.feed(block)
        return self.phase

    def _feed_spotted(self, block, now):
        """The spotter path: wake on the spot, stream the turn, end on quiet."""
        loud = wake_mod.block_energy(block) >= self.gate.floor
        channel = self.gate.feed(block, now)
        self.spotter.feed(block)
        spotted = self.spotter.poll()

        if self.phase == self.LISTENING:
            self._preroll.append(block)
            if len(self._preroll) > SPOT_PREROLL_BLOCKS:
                del self._preroll[0]
            if spotted:
                self.on_notice("wake")
                self.engine.begin_turn()
                for held in self._preroll:
                    self.engine.feed(held)
                self._preroll = []
                self.phase = self.IN_TURN
                self._wake_at = now
                self._spoke_since_wake = False
            return self.phase

        if self.phase == self.FOLLOW_UP:
            if self._follow_until is None:
                # First block after the reply: the window starts now.
                self._follow_until = now + self.follow_up_seconds
            if spotted or loud:
                # The captain kept talking: the next turn, no wake word.
                self.on_notice("follow-up-turn")
                self.engine.begin_turn()
                for held in self._preroll[-FOLLOW_UP_PREROLL_BLOCKS:]:
                    self.engine.feed(held)
                self.engine.feed(block)
                self._preroll = []
                self.phase = self.IN_TURN
                self._wake_at = now
                self._spoke_since_wake = True
                return self.phase
            self._preroll.append(block)
            if len(self._preroll) > SPOT_PREROLL_BLOCKS:
                del self._preroll[0]
            if now >= self._follow_until:
                self.on_notice("stand-by")
                self.phase = self.LISTENING
                self._follow_until = None
            return self.phase

        if self.phase == self.IN_TURN:
            if loud:
                self.engine.feed(block)
                # Speech clearly after the name itself: the command began.
                if now - self._wake_at > 0.3:
                    self._spoke_since_wake = True
                return self.phase
            if channel:
                return self.phase
            # Quiet past the hangover: end once the command was said, or
            # after the grace if only the name was said.
            if self._spoke_since_wake or now - self._wake_at >= SPOT_COMMAND_GRACE:
                self.engine.end_turn()
                self._wake_at = None
                self._preroll = []
                if self._stand_down or not self.follow_up_seconds:
                    self._stand_down = False
                    self.on_notice("stand-by")
                    self.phase = self.LISTENING
                else:
                    # Ziggy has answered (end_turn waits for the reply): keep
                    # listening without the wake word for the window.
                    self.on_notice("follow-up")
                    self.phase = self.FOLLOW_UP
                    self._follow_until = None
        return self.phase

    def stand_down(self):
        """The captain said "stand down" (or similar): close the conversation
        window after the current reply instead of keeping it open."""
        self._stand_down = True
        if self.phase == self.FOLLOW_UP:
            self.phase = self.LISTENING
            self._follow_until = None
            self._stand_down = False
            self.on_notice("stand-by")

    def _check_wake(self, transcripts, now):
        """Act on finished listening lines. Returns True when one woke.

        "Ziggy" alone arms the wake and waits for the command, as before.
        "Ziggy, <command>" in one breath sends the held utterance as the turn
        at once. Any other finished line closes its utterance, so the held
        audio never spans two sentences."""
        for text in transcripts:
            if self.keyword.feed(text):
                self.on_notice("wake")
                if self.keyword.has_command(text):
                    self._one_breath_turn()
                else:
                    self._utterance = []
                    self.phase = self.IN_WAKE
                    self._wake_at = now
                return True
            self._utterance = []
        return False

    def recover(self):
        """Re-arm after a turn the engine abandoned but survived (a reply
        timeout): the relay's documented renewal is the next turn's start,
        so the director returns to listening and the next wake opens a
        fresh turn instead of feeding one that was already ended."""
        if self.phase in (self.IN_TURN, self.FOLLOW_UP):
            self.phase = self.LISTENING
            self._wake_at = None
            self._preroll = []
            self._follow_until = None
