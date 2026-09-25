"""Negative clips of non-speech events: noise that switches on/off abruptly
(fan, AC), hum, keyboard-like clicks, door-knock-like thumps."""
import json
import os
import sys

import numpy as np

SR = 16000
out = sys.argv[1]
split = sys.argv[2]
n_clips = int(sys.argv[3])
rng = np.random.default_rng(11 if split == "train" else 12)
os.makedirs(os.path.join(out, split), exist_ok=True)


def colored(n, kind):
    w = rng.standard_normal(n)
    if kind == "white":
        return w
    if kind == "brown":
        b = np.cumsum(w)
        return b - np.convolve(b, np.ones(400) / 400, mode="same")
    f = np.fft.rfft(w)                       # pink
    f /= np.sqrt(np.arange(1, len(f) + 1))
    return np.fft.irfft(f, n)


man = []
for k in range(n_clips):
    dur = rng.uniform(4, 8)
    n = int(dur * SR)
    x = rng.standard_normal(n) * rng.choice([5, 30, 100])
    kind = rng.choice(["onset", "hum", "clicks", "thumps"])
    if kind == "onset":
        c = colored(n, rng.choice(["white", "brown", "pink"]))
        c = c / c.std() * rng.choice([300, 600, 900, 1500, 3000])
        a, b = sorted(rng.uniform(0.3, dur, 2))
        env = np.zeros(n)
        env[int(a * SR):int(b * SR)] = 1
        ramp = int(rng.uniform(0.005, 0.2) * SR)
        env = np.convolve(env, np.ones(ramp) / ramp, mode="same")
        x += c * env
    elif kind == "hum":
        t = np.arange(n) / SR
        f0 = rng.choice([50, 60, 100, 120])
        x += sum(np.sin(2 * np.pi * f0 * h * t) / h for h in range(1, 6)) \
            * rng.choice([300, 1000, 3000])
    else:
        rate = rng.uniform(3, 12) if kind == "clicks" else rng.uniform(0.5, 3)
        for t0 in np.cumsum(rng.exponential(1 / rate, 200)):
            i = int(t0 * SR)
            if i >= n - 2000:
                break
            m = rng.integers(80, 400) if kind == "clicks" else 1600
            burst = rng.standard_normal(m) * np.exp(-np.arange(m) / (m / 5))
            if kind == "thumps":
                burst = np.convolve(burst, np.ones(40) / 40, mode="same")
            x[i:i + m] += burst * rng.choice([2000, 6000, 12000])
    pcm = np.clip(x, -32768, 32767).astype("<i2")
    path = os.path.join(out, split, "noise%03d_%s.pcm" % (k, kind))
    pcm.tofile(path)
    man.append(dict(split=split, path=path, wakes=[], kind="room",
                    text=kind, voice="", dur=round(dur, 2)))
json.dump(man, open(os.path.join(out, "manifest-%s.json" % split), "w"),
          indent=1)
print(len(man))
