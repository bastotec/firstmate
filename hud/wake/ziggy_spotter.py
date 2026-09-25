#!/usr/bin/env python3
"""ziggy_spotter.py - a streaming "Ziggy" wake-word spotter.

openWakeWord's frozen front end (melspectrogram + Google speech_embedding,
both ONNX, ~2.5 MB together) turns audio into one 96-dim embedding every
80 ms. A small MLP trained on synthetic and real "Ziggy" clips scores the
last 16 embeddings (about 2 s of context) after every block. The MLP is
plain numpy, so the runtime needs only numpy + onnxruntime + openwakeword.

Two ways to use it:

  Module:  spot = ZiggySpotter(); events = spot.feed(block_bytes)
           feed() takes any-size chunk of 16 kHz mono 16-bit LE PCM and
           returns a list of Wake(score, audio_time) - usually empty.

  Command: ziggy_spotter.py [--threshold T] < pcm
           reads PCM on stdin, writes one line per wake on stdout:
           "wake <score> <audio_seconds>"   (flushed immediately)
           The same stdin contract as the HUD decoder, so the HUD can tee
           its blocks into both children.
"""

import argparse
import collections
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_MODEL = os.path.join(HERE, "models", "ziggy.npz")
SR = 16000
N_FRAMES = 16            # embedding frames per decision window (~2 s)

Wake = collections.namedtuple("Wake", "score audio_time")


def load_features(ncpu=1):
    """openWakeWord's streaming front end, ONNX backend."""
    from openwakeword.utils import AudioFeatures   # noqa: PLC0415
    return AudioFeatures(inference_framework="onnx", ncpu=ncpu)


class Mlp:
    """Forward pass for the trained classifier, from an .npz of weights."""

    def __init__(self, path):
        z = np.load(path)
        n = int(z["n_layers"])
        self.W = [z["W%d" % i] for i in range(n)]
        self.b = [z["b%d" % i] for i in range(n)]
        self.mean = z["mean"]
        self.std = z["std"]
        self.threshold = float(z["threshold"]) if "threshold" in z else 0.5

    def __call__(self, x):
        """x: (batch, 16, 96) -> (batch,) probability of the wake word."""
        h = (x.reshape(len(x), -1) - self.mean) / self.std
        for i, (w, b) in enumerate(zip(self.W, self.b)):
            h = h @ w + b
            if i < len(self.W) - 1:
                h = np.maximum(h, 0)
        return 1.0 / (1.0 + np.exp(-h[:, 0]))


class ZiggySpotter:
    """Streaming spotter. One instance per audio stream (not thread-safe).

    threshold   score that counts as a wake (default: the one saved with
                the model at training time)
    patience    consecutive scoring steps at/over threshold before firing
    refractory  seconds after a wake during which no second wake fires
    """

    def __init__(self, model_path=DEFAULT_MODEL, threshold=None, patience=1,
                 refractory=1.5):
        self.mlp = Mlp(model_path)
        self.threshold = self.mlp.threshold if threshold is None \
            else threshold
        self.patience = patience
        self.refractory = refractory
        self.features = load_features()
        self._prime()
        self.samples = 0             # audio samples fed so far
        self._run = 0
        self._last_wake = -1e9
        self.last_score = 0.0

    def _prime(self):
        # The front end starts with embeddings of random noise in its
        # window; scoring those produced wakes in the first second of
        # room tone. Fill the window with 2.5 s of digital silence first.
        self.features.reset()
        self.features(np.zeros(int(2.56 * SR), dtype=np.int16))

    def reset(self):
        self._prime()
        self._run = 0

    def feed(self, block):
        """Feed PCM bytes (any length). Return a list of Wake events."""
        x = np.frombuffer(block, dtype="<i2")
        self.features(x)
        self.samples += len(x)
        # The front end emits embeddings in whole 80 ms steps and zeroes its
        # sample counter exactly when it did; otherwise nothing new to score.
        if self.features.accumulated_samples != 0:
            return []
        window = self.features.get_features(N_FRAMES)
        score = float(self.mlp(window)[0])
        self.last_score = score
        now = self.samples / SR
        if score >= self.threshold:
            self._run += 1
        else:
            self._run = 0
        if self._run >= self.patience and \
                now - self._last_wake >= self.refractory:
            self._last_wake = now
            self._run = 0
            return [Wake(score, now)]
        return []


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--threshold", type=float, default=None)
    ap.add_argument("--patience", type=int, default=1)
    ap.add_argument("--score-log", default=None,
                    help="append every score >= 0.5 with a wall-clock stamp")
    ap.add_argument("--block", type=int, default=3200,
                    help="bytes per read (3200 = 100 ms)")
    args = ap.parse_args()
    spot = ZiggySpotter(args.model, args.threshold, args.patience)
    print("spotter ready threshold=%.2f" % spot.threshold, file=sys.stderr,
          flush=True)
    stdin = sys.stdin.buffer
    score_log = open(args.score_log, "a", buffering=1) if args.score_log else None
    while True:
        block = stdin.read(args.block)
        if not block:
            break
        wakes = spot.feed(block)
        if score_log is not None and spot.last_score >= 0.5:
            import time
            score_log.write("%.3f %.4f%s\n" % (time.time(), spot.last_score,
                                                " WAKE" if wakes else ""))
        for w in wakes:
            sys.stdout.write("wake %.3f %.3f\n" % (w.score, w.audio_time))
            sys.stdout.flush()


if __name__ == "__main__":
    main()
