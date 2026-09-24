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

# Audio block energy threshold, in squared amplitude per sample. Speech at a
# normal desk distance sits far above this; the room floor sits far below. The
# value is per-sample mean square, so it is independent of block size.
ENERGY_FLOOR = 2500.0

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

    A block is voiced when its mean-square energy crosses ENERGY_FLOOR. Speech
    is "active" while voiced blocks arrive and for HANGOVER_SECONDS after the
    last one, so a short pause between words does not close the turn.
    """

    def __init__(self, floor=ENERGY_FLOOR, hangover=HANGOVER_SECONDS):
        self.floor = floor
        self.hangover = hangover
        self._last_voice = None

    def feed(self, block, now):
        """Feed one block at time `now` (monotonic seconds). Return voiced."""
        energy = block_energy(block)
        if energy >= self.floor:
            self._last_voice = now
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
