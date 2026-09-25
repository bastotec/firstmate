#!/usr/bin/env python3
"""fm_voice_wake.py - the spoken HUD's local wake gate.

Two gates keep the HUD's microphone off the thinking gateway while idle:

1. An energy gate, cheap enough to run on every audio block, decides when the
   captain is speaking at all. Silence never becomes a transcript.
2. A keyword match, run against locally decoded speech only, decides whether
   that speech was the wake word.

This module owns the DECISION logic for both gates and none of the decoding:
feed it audio blocks and transcripts, assert wake or no-wake. The local decoder
that produces transcripts is a separate process, so the model never enters the
HUD process and never blocks the interface. The wake word is the captain's
chosen product name; it is configurable because a wake word nobody can change
is a wake word nobody can fix.

The keyword matcher is deliberately forgiving. A spoken name is transcribed
with real-world noise: "Ziggy" arrives as Ziggy, Ziggie, Ziggi, Zeggy, Zaggy.
Each rule below exists for a mishearing observed in local decode runs, and the
match is on the word alone, never the surrounding sentence, because the
captain says the name and then talks.
"""

import re

# Audio block energy threshold, in squared amplitude per sample, and the
# room tracker that stands over it. A real machine's microphone floor is
# not digital silence: the captain's MacBook measures about 2.5e5 mean
# square of idle room tone (an AGC-managed laptop microphone in a live
# room), a hundred times this absolute floor, so a gate fixed at the
# absolute floor alone calls the room itself speech - the decoder is fed
# forever and a turn, once open, never sees the quiet that ends it. The
# gate therefore learns the room it sits in, and ENERGY_FLOOR remains the
# minimum threshold so a genuinely quiet room behaves exactly as before.
# The value is per-sample mean square, so it is independent of block size.
ENERGY_FLOOR = 2500.0

# Speech must clear the tracked room floor by this factor. Measured on the
# captain's MacBook: room tone sits near 2.5e5 mean square and spoken audio
# dips no lower than several times that under microphone AGC, so four
# leaves margin on both sides.
NOISE_HEADROOM = 4.0

# How fast a louder room raises the tracked floor, per quiet block (0.02 is
# about five seconds to mostly arrive). A quieter room is adopted at once,
# so the gate never stays deaf after the room calms down.
NOISE_RISE_RATE = 0.02

# A cold start counts this many voiced blocks in a row before deciding
# that sustained level is the room itself, not speech: room tone never
# pauses, while speech from a cold start is the captain talking at the
# moment the HUD launched and always pauses, and the first pause after a
# mistaken adoption pulls the floor back down. 1.5s of sustained audio.
BOOTSTRAP_VOICED_BLOCKS = 15

# How long recent speech keeps the channel "active" after the last voiced
# block, in seconds. Keeps one-word wakes from being split by a pause.
HANGOVER_SECONDS = 0.6


class WakeConfig:
    """One wake word and the matching rules for its likely mishearings."""

    def __init__(self, word, variants):
        self.word = word
        # Built once, not per call: matching happens on every transcript.
        self.pattern = re.compile(
            r"(?:^|[^a-z0-9])(" + "|".join(variants) + r")(?:[^a-z0-9]|$)",
            re.IGNORECASE)

    def matches(self, text):
        """Return True when text contains the wake word as a whole word."""
        if not text:
            return False
        return bool(self.pattern.search(text))


def default_config(word="Ziggy"):
    """The shipped wake config for the captain's chosen product name."""
    # Each entry is a mishearing observed from a local Parakeet decode of a
    # real spoken "Ziggy" in this build's test clips, plus the exact spelling.
    return WakeConfig(word, [
        word, "Ziggie", "Ziggi", "Zeggy", "Zaggy", word + "s", word + "'s",
    ])


def block_energy(block):
    """Mean-square amplitude of one block of 16-bit little-endian PCM bytes."""
    if not block:
        return 0.0
    total = 0
    count = len(block) // 2
    for i in range(0, len(block), 2):
        sample = block[i] | (block[i + 1] << 8)
        if sample >= 32768:
            sample -= 65536
        total += sample * sample
    return total / max(count, 1)


class EnergyGate:
    """Voice-activity gate over a stream of fixed-size audio blocks.

    A block is voiced when its mean-square energy clears the gate's
    threshold; speech is "active" while voiced blocks arrive and for
    HANGOVER_SECONDS after the last one, so a short pause between words
    does not close the turn. The threshold starts at `floor` and then
    tracks the room: a sustained level from a cold start is adopted as the
    room's floor, quiet blocks pull it down at once and let a louder room
    creep up slowly, and speech must clear it by `noise_headroom`. The
    attribute `floor` always names the threshold the next block must
    clear, so a caller can read it directly.
    """

    def __init__(self, floor=ENERGY_FLOOR, hangover=HANGOVER_SECONDS,
                 noise_headroom=NOISE_HEADROOM):
        self.base_floor = floor
        self.hangover = hangover
        self.noise_headroom = noise_headroom
        self.floor = floor
        self._room = None            # tracked room floor (mean-square)
        self._run = 0                # voiced blocks since the last quiet one
        self._run_min = None         # lowest energy in that voiced run
        self._last_voice = None

    def _threshold(self):
        if self._room is None:
            return self.base_floor
        return max(self.base_floor, self.noise_headroom * self._room)

    def feed(self, block, now):
        """Feed one block at time `now` (monotonic seconds). Return voiced."""
        energy = block_energy(block)
        voiced = energy >= self.floor
        if voiced:
            if self._room is None:
                # Cold start: judge by the absolute floor until a sustained
                # level proves the room is louder than that floor assumes.
                self._run += 1
                self._run_min = energy if self._run_min is None \
                    else min(self._run_min, energy)
                if self._run >= BOOTSTRAP_VOICED_BLOCKS:
                    self._room = self._run_min
                    self._run = 0
                    self._run_min = None
            self._last_voice = now
        else:
            self._run = 0
            self._run_min = None
            if self._room is not None:
                if energy < self._room:
                    self._room = energy
                else:
                    self._room += NOISE_RISE_RATE * (energy - self._room)
        self.floor = self._threshold()
        if voiced:
            return True
        return self.active(now)

    def active(self, now):
        """Whether speech is active at `now`, from history alone."""
        if self._last_voice is None:
            return False
        return (now - self._last_voice) <= self.hangover


class KeywordListener:
    """Wake decision over locally decoded transcripts."""

    def __init__(self, config=None):
        self.config = config or default_config()
        self.last_match = None

    def feed(self, text):
        """Return True exactly when text contains the wake word."""
        woke = self.config.matches(text)
        if woke:
            self.last_match = text
        return woke

    def has_command(self, text):
        """Return True when text carries words beyond the wake word itself:
        "Ziggy, what's the status?" does, "Ziggy." and "Hey Ziggy" do not."""
        match = self.config.pattern.search(text or "")
        if not match:
            return False
        # The name must open the sentence (after an optional "hey"), so talk
        # that merely mentions Ziggy is never sent as a command.
        lead = [w for w in re.findall(r"[^\W_]+", text[:match.start(1)])
                if w.lower() not in ("hey", "ok", "okay", "hi")]
        rest = re.findall(r"[^\W_]+", text[match.end(1):])
        return not lead and len(rest) >= 1
