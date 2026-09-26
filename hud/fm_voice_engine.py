#!/usr/bin/env python3
"""fm_voice_engine.py - the HUD's turn engine, attached to the existing relay.

The HUD never reimplements the speech pipeline. It spawns the relay in --serve
mode as a local child and speaks the same frame wire fm-voice-client.py speaks
over SSH: MAGIC handshake, S/A/E/Q up, A/T/V/M/B down. bin/fm_voice_frame.py
owns that format; this module owns only the local wiring.

Wake-word listening keeps the microphone local. Only after a wake does a
turn's audio cross this boundary, and only into the relay child: the thinking
gateway is never attached to the microphone.

The relay is addressed by absolute path so a HUD started from anywhere talks
to this repo's relay, and its settings resolve through the relay's own records
reader against the home the HUD is configured with, so no endpoint, port or
account is ever named here.
"""

import os
import queue
import subprocess
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "bin"))

import fm_voice_frame as frame              # noqa: E402

# Anything a login shell prints ahead of the relay's MAGIC is discarded, up to
# this much; past it the child is not a relay. Same bound as the client's.
MAX_PREAMBLE = 8192

# Default seconds end_turn waits for the relay's reply_end mark. Generous on
# purpose: the hybrid pipeline's measured end-of-speech to first audio is a few
# seconds and a full answer runs longer, while a relay that accepts audio but
# never answers nor fails must not hold the HUD forever.
TURN_TIMEOUT = 120.0

READY_TIMEOUT = 30.0
CLOSE_TIMEOUT = 10.0


class EngineError(Exception):
    """The engine could not start, or the wire stopped being a frame stream."""


def relay_argv(home=None, relay_path=None, verbose=False):
    """Return the argv that starts the relay as a local child in --serve mode."""
    relay = relay_path or os.path.join(ROOT, "bin", "fm-voice-relay.py")
    argv = [sys.executable, relay, "--serve"]
    if home:
        argv += ["--home", home]
    if verbose:
        argv.append("--verbose")
    return argv


class Engine:
    """One relay child plus the threads that keep the wire coherent.

    The sender thread owns the whole uplink so a turn's control frames and
    audio can never overtake each other; the client documents losing a whole
    session to exactly that fault. The reader thread owns the downlink and
    completes a turn on the relay's reply_end mark, guarding stale frames with
    a turn id so a late chunk is credited to the turn it belongs to and never
    to the one now open.
    """

    def __init__(self, argv, turn_timeout=TURN_TIMEOUT, ready_timeout=READY_TIMEOUT,
                 on_state=None, on_transcript=None, on_audio=None,
                 on_notice=None, verbose=False):
        self.argv = list(argv)
        self.turn_timeout = turn_timeout
        self.ready_timeout = ready_timeout
        self.verbose = verbose
        self.proc = None
        self.reader = None
        self.uplink = None
        self.up_q = queue.Queue()
        self.sender_thread = None
        # Mirrors the client's turn identity guard.
        self.turn_id = 0
        self.ready = threading.Event()
        self.reply_done = threading.Event()
        self.closed = threading.Event()
        self.quitting = threading.Event()
        self.ready_notice = {}
        self.last_error = None
        self.lock = threading.Lock()
        # HUD-layer callbacks, invoked on the reader thread. on_state names the
        # HUD's three states: listening / thinking / speaking.
        self.on_state = on_state or (lambda state: None)
        self.on_transcript = on_transcript or (lambda role, text: None)
        # Reply audio, 24000 Hz mono 16-bit LE, handed to the player whole.
        self.on_audio = on_audio or (lambda pcm: None)
        self.on_notice = on_notice or (lambda event, obj: None)

    def _vlog(self, message):
        if self.verbose:
            sys.stderr.write("engine: {}\n".format(message))
            sys.stderr.flush()

    # --------------------------------------------------------------- lifecycle

    def start(self):
        """Spawn the relay child and wait for its ready notice.

        A startup that refuses part way through releases what it already
        started, so a refused startup leaves no orphan child behind.
        """
        try:
            self._start()
        except BaseException:
            self.close()
            raise

    def _start(self):
        self._vlog("starting relay: {}".format(" ".join(self.argv)))
        self.proc = subprocess.Popen(
            self.argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self._sync_magic()
        self.reader = frame.Reader(self.proc.stdout)
        self.uplink = frame.Writer(self.proc.stdin)
        self.sender_thread = threading.Thread(
            target=self._sender, daemon=True)
        self.sender_thread.start()
        reader_thread = threading.Thread(target=self._reader, daemon=True)
        reader_thread.start()
        self._wait_ready()

    def _sync_magic(self):
        """Discard anything the child's shell printed ahead of the MAGIC."""
        seen = bytearray()
        while True:
            byte = self.proc.stdout.read(1)
            if not byte:
                raise EngineError(
                    "the relay closed before it said hello; run by hand: "
                    + " ".join(self.argv))
            seen += byte
            if seen.endswith(frame.MAGIC):
                junk = bytes(seen[:-len(frame.MAGIC)])
                if junk:
                    self._vlog("discarded {} bytes ahead of the handshake: "
                               "{!r}".format(len(junk), junk[:200]))
                return
            if len(seen) > MAX_PREAMBLE:
                raise EngineError(
                    "no relay handshake in the first {} bytes; the child is "
                    "not a relay".format(MAX_PREAMBLE))

    def _wait_ready(self):
        deadline = time.monotonic() + self.ready_timeout
        while not self.ready.is_set():
            if self.closed.is_set():
                raise EngineError(
                    "the relay closed before it was ready; run by hand: "
                    + " ".join(self.argv))
            if time.monotonic() >= deadline:
                raise EngineError(
                    "the relay never reported ready within {}s; run by hand: "
                    "{}".format(READY_TIMEOUT, " ".join(self.argv)))
            self.ready.wait(0.2)

    # ------------------------------------------------------------------ turns

    def begin_turn(self):
        """Open a turn; audio fed after this belongs to it.

        The control frame goes through the queue rather than straight to the
        wire so it can never be overtaken by the turn's own first audio chunk.
        """
        if self.closed.is_set():
            raise EngineError("the engine is closed")
        with self.lock:
            self.turn_id += 1
            self.reply_done.clear()
        self.up_q.put(frame.TALK_START)
        self.on_state("thinking")

    def feed(self, pcm):
        """Stream one chunk of 16 kHz mono 16-bit LE audio into the open turn."""
        self.up_q.put(pcm)

    def end_turn(self, timeout=None):
        """Close the turn's uplink side and wait for the relay to finish it.

        Returns the id of the turn that was ended. Raises EngineError when the
        reply does not complete in time: the relay owns what a lost turn means
        and speaks its own failure line, so the HUD surfaces the timeout rather
        than silently swallowing the captain's question. After a timeout the
        next begin_turn's TALK_START makes the relay open a replacement
        session, which is its documented renewal path.

        The reply_done wait is not cleared here: a release the relay already
        delivered mid-turn - its turn-failed notice, which is the only thing
        that ends a turn whose session is spent - must survive to this wait,
        or the late TALK_END the spent session drops would strand the caller
        for the whole timeout. begin_turn owns the clear, for the next turn.
        """
        with self.lock:
            turn = self.turn_id
        self.up_q.put(frame.TALK_END)
        if not self.reply_done.wait(timeout=timeout or self.turn_timeout):
            raise EngineError(
                "the reply did not complete within {}s".format(
                    timeout or self.turn_timeout))
        return turn

    # ------------------------------------------------------------------ close

    def close(self):
        """End the session, bounded, releasing every held resource.

        Every step is guarded and every field is checked, because close() also
        runs from a startup that refused part way through, where the later
        fields are still None and the original refusal is the message worth
        keeping.
        """
        if self.closed.is_set():
            return
        self.closed.set()
        # Before the frame, so the goodbye that answers it is read as the
        # answer to a question this end asked rather than the relay dying.
        self.quitting.set()
        self._quiet(lambda: self.up_q.put(frame.QUIT))
        # And the sender's exit sentinel behind it, so the thread that owns
        # the uplink finishes instead of blocking on an empty queue while
        # close() waits out its whole join timeout.
        self._quiet(lambda: self.up_q.put(None))
        if self.sender_thread is not None:
            self.sender_thread.join(timeout=CLOSE_TIMEOUT)
        if self.proc is not None:
            if self.proc.stdin is not None:
                try:
                    self.proc.stdin.close()
                except OSError:
                    pass
            try:
                self.proc.wait(timeout=CLOSE_TIMEOUT)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=CLOSE_TIMEOUT)

    def _quiet(self, action):
        try:
            action()
        except Exception as exc:                   # noqa: BLE001
            self._vlog("close step did not finish cleanly: {}: {}".format(
                type(exc).__name__, exc))

    # ----------------------------------------------------------------- threads

    def _sender(self):
        """Own the whole uplink so nothing on it is sent out of order.

        Every frame a turn consists of goes through this one queue, talk start
        included; the client documents the cost of doing otherwise. A dead
        child ends this thread quietly, because the reader has already named
        the closure.
        """
        while True:
            item = self.up_q.get()
            if item is None:
                return
            try:
                if item is frame.TALK_END or item is frame.TALK_START \
                        or item is frame.QUIT:
                    self.uplink.send(item)
                else:
                    self.uplink.send(frame.AUDIO, item)
            except (BrokenPipeError, OSError):
                return

    def _reader(self):
        """Read the downlink, apply frames, and complete turns.

        The reply_end mark is what completes a turn, exactly as in the client:
        the relay puts every audio chunk and that mark on one ordered stream,
        so by the time it arrives the whole answer has already been handed to
        the player. Stale frames are dropped by turn id, never applied to the
        turn now open.
        """
        while True:
            try:
                got = self.reader.read()
            except (frame.FrameError, OSError) as exc:
                self._fail("connection lost: {}".format(exc))
                return
            if got is None:
                if not self.quitting.is_set():
                    self._fail("the connection ended")
                else:
                    with self.lock:
                        self.closed.set()
                return
            kind, payload = got
            # Which turn this frame belongs to, taken the moment it arrives,
            # so a frame from an abandoned turn is never applied to the one
            # now open.
            with self.lock:
                arrived_in = self.turn_id
            try:
                if kind == frame.AUDIO:
                    self.on_audio(payload)
                    self.on_state("speaking")
                elif kind == frame.TEXT:
                    obj = frame.decode_json(payload)
                    text = (obj.get("text") or "").strip()
                    if text:
                        self.on_transcript(obj.get("role") or "", text)
                elif kind == frame.NOTICE:
                    obj = frame.decode_json(payload)
                    event = obj.get("event", "")
                    if event == "ready":
                        self.ready_notice = obj
                        self.ready.set()
                    elif event in ("turn-failed", "session-ended"):
                        # The relay's own release for a turn that will never
                        # answer, sent while the relay stays alive: the
                        # waiter must come back now, and only the turn the
                        # failure arrived in may be released - a stale one
                        # from an abandoned turn must not end the turn now
                        # open. Checked and released in one critical
                        # section, so no turn is released without being
                        # able to say why.
                        with self.lock:
                            release = arrived_in == self.turn_id
                            if release:
                                self.reply_done.set()
                        if release:
                            self.on_state("listening")
                        self.on_notice(event, obj)
                    else:
                        self.on_notice(event, obj)
                elif kind == frame.MARK:
                    obj = frame.decode_json(payload)
                    if obj.get("mark") == "reply_end":
                        # The same turn identity guard the failure release
                        # uses: end_turn no longer clears the wait, so a
                        # stale mark from an abandoned turn must not
                        # complete the turn now open.
                        with self.lock:
                            mine = arrived_in == self.turn_id
                            if mine:
                                self.reply_done.set()
                        if mine:
                            self.on_state("listening")
                elif kind == frame.BYE:
                    with self.lock:
                        self.closed.set()
                    return
            except frame.FrameError as exc:
                self._fail("bad frame on the downlink: {}".format(exc))
                return

    def _fail(self, why):
        """Record a wire fault and wake every waiter so nothing hangs."""
        with self.lock:
            self.last_error = why
            self.closed.set()
        self.ready.set()
        self.reply_done.set()
        self.on_notice("engine-fault", {"error": why})
        self._vlog(why)
