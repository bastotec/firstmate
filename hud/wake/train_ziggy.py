#!/usr/bin/env python3
"""train_ziggy.py - train the "Ziggy" classifier used by ziggy_spotter.py.

Inputs
  --manifest M.json (repeatable)  clips: [{"path", "wakes": [[start,end],..],
                                  "kind", "split"}], 16 kHz mono s16le PCM.
                                  Clips with "split": "test" are skipped.
                                  kind "pos"/"mention" carry wakes; anything
                                  else is a negative clip.
  data/acav_part.npy              openWakeWord precomputed negative features
                                  (a slice of the ACAV100M set, general audio)
  data/validation_set_features.npy  ~11 h of general audio features: first
                                  half joins the negatives, second half
                                  picks the threshold for a target
                                  false-accept rate per hour.
Output
  models/ziggy.npz                weights + normalisation + threshold

A clip's windows are labelled by the time their last frame lands:
  positive  within [word_end - 0.08, word_end + POS_AFTER] of a wake word
  negative  before the word starts, or once it has left the ~2 s window
  ignored   everything in between (partial word / word still in context)
"""

import argparse
import json
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ziggy_spotter as zs     # noqa: E402

SR = zs.SR
POS_AFTER = 0.40
CHUNK = 1280                   # one embedding frame per chunk
rng = np.random.default_rng(0)


def room(n, rms):
    w = rng.standard_normal(n).astype(np.float32)
    b = np.cumsum(w)
    b -= np.convolve(b, np.ones(400) / 400, mode="same")
    b = b / (b.std() + 1e-9) * rms * 0.7
    return b + rng.standard_normal(n).astype(np.float32) * rms * 0.3


def augment(x):
    """Gain, speed, reverb and extra noise. Returns (audio, time_scale)."""
    x = x.astype(np.float32)
    speed = rng.uniform(0.9, 1.1)
    n = int(len(x) / speed)
    x = np.interp(np.arange(n) * speed, np.arange(len(x)), x)
    if rng.random() < 0.4:
        rt = rng.uniform(0.08, 0.35)
        m = int(rt * SR)
        ir = rng.standard_normal(m) * np.exp(-6.9 * np.arange(m) / m)
        ir[0] = 1.0
        ir /= np.sqrt((ir ** 2).sum())
        x = np.convolve(x, ir)[:n]
    x = x * rng.uniform(0.25, 2.5)
    x = x + room(len(x), rng.choice([0, 100, 400, 1000, 2000]))
    return np.clip(x, -32768, 32767), 1.0 / speed


def clip_windows(feat, x, lead_rms):
    """Stream x through the front end (after 1.5 s of room tone so the
    buffer holds real context). Yield (window 16x96, end_time_in_clip)."""
    feat.reset()
    pre = room(int(1.5 * SR), lead_rms)
    x = np.concatenate([pre, x]).astype(np.int16)
    off = len(pre)
    out, times = [], []
    for i in range(0, len(x) - CHUNK + 1, CHUNK):
        feat(x[i:i + CHUNK])
        end = i + CHUNK
        if end <= off:
            continue
        out.append(feat.get_features(zs.N_FRAMES)[0].copy())
        times.append((end - off) / SR)
    return np.array(out, np.float32), np.array(times)


def label(times, wakes, scale=1.0):
    y = np.full(len(times), 0, np.int8)            # 0 neg, 1 pos, -1 ignore
    for s, e in wakes:
        s, e = s * scale, e * scale
        pos = (times >= e - 0.08) & (times <= e + POS_AFTER)
        ign = (times >= s + 0.15) & (times <= e + 2.1) & ~pos
        y[ign] = -1
        y[pos] = 1
    return y


def clip_features(manifests, n_aug_pos, n_aug_neg, real_boost):
    feat = zs.load_features()
    X, Y, W = [], [], []
    t0 = time.time()
    clips = []
    for m in manifests:
        for c in json.load(open(m)):
            if c.get("split") == "test":
                continue
            clips.append(c)
    for k, c in enumerate(clips):
        x = np.fromfile(c["path"], "<i2").astype(np.float32)
        wakes = c.get("wakes") or []
        real = c.get("real", False)
        n_aug = n_aug_pos if wakes else n_aug_neg
        weight = real_boost if real else 1.0
        for a in range(n_aug + 1):
            xa, sc = (x, 1.0) if a == 0 else augment(x)
            w, t = clip_windows(feat, xa, rng.choice([30, 300, 800]))
            y = label(t, wakes, sc)
            keep = y >= 0
            X.append(w[keep])
            Y.append(y[keep])
            W.append(np.full(keep.sum(), weight, np.float32))
        if k % 100 == 0:
            print("  clip %d/%d  %.0fs" % (k, len(clips), time.time() - t0),
                  flush=True)
    return np.concatenate(X), np.concatenate(Y), np.concatenate(W)


class Net:
    """Tiny MLP trained with Adam in numpy (no torch needed on the Mac)."""

    def __init__(self, sizes):
        self.W = [rng.standard_normal((a, b)).astype(np.float32)
                  * np.sqrt(2.0 / a) for a, b in zip(sizes, sizes[1:])]
        self.b = [np.zeros(b, np.float32) for b in sizes[1:]]

    def forward(self, x):
        hs = [x]
        for i, (w, b) in enumerate(zip(self.W, self.b)):
            x = x @ w + b
            if i < len(self.W) - 1:
                x = np.maximum(x, 0)
            hs.append(x)
        return hs

    def fit(self, X, Y, Wt, epochs, lr=1e-3, batch=512, l2=1e-4):
        params = self.W + self.b
        m = [np.zeros_like(p) for p in params]
        v = [np.zeros_like(p) for p in params]
        step = 0
        for ep in range(epochs):
            idx = rng.permutation(len(X))
            tot = 0.0
            for s in range(0, len(X), batch):
                j = idx[s:s + batch]
                hs = self.forward(X[j])
                z = hs[-1][:, 0]
                p = 1 / (1 + np.exp(-z))
                y, w = Y[j], Wt[j]
                tot += float((w * (np.logaddexp(0, z) - y * z)).sum())
                g = (w * (p - y) / w.sum())[:, None].astype(np.float32)
                gW, gb = [], []
                for i in range(len(self.W) - 1, -1, -1):
                    gW.insert(0, hs[i].T @ g + l2 * self.W[i])
                    gb.insert(0, g.sum(0))
                    if i:
                        g = (g @ self.W[i].T) * (hs[i] > 0)
                step += 1
                for k, (p_, gr) in enumerate(zip(params, gW + gb)):
                    m[k] = 0.9 * m[k] + 0.1 * gr
                    v[k] = 0.999 * v[k] + 0.001 * gr * gr
                    mh = m[k] / (1 - 0.9 ** step)
                    vh = v[k] / (1 - 0.999 ** step)
                    p_ -= lr * mh / (np.sqrt(vh) + 1e-8)
            print("  epoch %d loss %.4f" % (ep, tot / Wt.sum()), flush=True)

    def predict(self, X, batch=8192):
        out = []
        for s in range(0, len(X), batch):
            z = self.forward(X[s:s + batch])[-1][:, 0]
            out.append(1 / (1 + np.exp(-z)))
        return np.concatenate(out)


def false_accepts_per_hour(scores, thr, refractory_frames=19):
    """Count wakes over a continuous score track (one score per 80 ms)."""
    n, last = 0, -10 ** 9
    for i in np.flatnonzero(scores >= thr):
        if i - last >= refractory_frames:
            n += 1
            last = i
    return n / (len(scores) * 0.08 / 3600)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", action="append", required=True)
    ap.add_argument("--out", default=os.path.join(HERE, "models", "ziggy.npz"))
    ap.add_argument("--acav", default=os.path.join(HERE, "data",
                                                   "acav_part.npy"))
    ap.add_argument("--acav-n", type=int, default=150000)
    ap.add_argument("--val", default=os.path.join(
        HERE, "data", "validation_set_features.npy"))
    ap.add_argument("--aug-pos", type=int, default=5)
    ap.add_argument("--aug-neg", type=int, default=1)
    ap.add_argument("--real-boost", type=float, default=5.0,
                    help="loss weight of the captain's own recordings")
    ap.add_argument("--neg-weight", type=float, default=3.0)
    ap.add_argument("--no-cache", dest="cache", action="store_false",
                    help="always re-extract clip features (by default each "
                    "manifest's features are cached next to it)")
    ap.add_argument("--hidden", default="64,32")
    ap.add_argument("--clip-neg-weight", type=float, default=3.0,
                    help="extra weight of spoken negative clips (confusable "
                    "words, other sentences)")
    ap.add_argument("--hard-rounds", type=int, default=2)
    ap.add_argument("--hard-boost", type=float, default=5.0)
    ap.add_argument("--epochs", type=int, default=12)
    ap.add_argument("--target-fa", type=float, default=0.5,
                    help="false accepts per hour on the validation set")
    args = ap.parse_args()

    t0 = time.time()
    print("clip features ...", flush=True)
    parts = []
    for man in args.manifest:
        # One cache file per manifest, next to it: retraining after new
        # recordings only extracts the manifest that changed.
        cache = man + ".features.npz"
        stamp = os.path.getmtime(man)
        if args.cache and os.path.exists(cache) and \
                float(np.load(cache)["stamp"]) == stamp:
            z = np.load(cache)
            parts.append((z["X"], z["Y"], z["W"]))
            continue
        print("extracting", man, flush=True)
        X_, Y_, W_ = clip_features([man], args.aug_pos, args.aug_neg,
                                   args.real_boost)
        if args.cache:
            np.savez(cache, X=X_, Y=Y_, W=W_, stamp=stamp)
        parts.append((X_, Y_, W_))
    Xc = np.concatenate([p[0] for p in parts])
    Yc = np.concatenate([p[1] for p in parts])
    Wc = np.concatenate([p[2] for p in parts])
    print("clip windows: %d pos, %d neg (%.0fs)" % (
        (Yc == 1).sum(), (Yc == 0).sum(), time.time() - t0), flush=True)
    acav = np.load(args.acav, mmap_mode="r")
    n = min(args.acav_n, len(acav))
    Xa = np.asarray(acav[:n], dtype=np.float32)
    # The ~11 h validation track: the first half (every 2nd window) joins the
    # negatives, the second half is never trained on and sets the threshold.
    val = np.load(args.val).astype(np.float32)
    half = len(val) // 2
    vwin = np.lib.stride_tricks.sliding_window_view(
        val[:half], (zs.N_FRAMES, 96)).reshape(-1, zs.N_FRAMES, 96)
    Xv = np.ascontiguousarray(vwin[::2])
    held = val[half:]
    Wc = Wc.copy()
    Wc[Yc == 0] *= args.clip_neg_weight
    X = np.concatenate([Xc, Xa, Xv]).reshape(-1, zs.N_FRAMES * 96)
    del Xa, Xv
    Y = np.concatenate([Yc, np.zeros(len(X) - len(Yc), np.int8)]) \
        .astype(np.float32)
    Wt = np.concatenate([Wc, np.ones(len(X) - len(Yc), np.float32)])
    # Balance: positives as a whole weigh as much as negatives / neg_weight.
    pos = Y == 1
    Wt[pos] *= (Wt[~pos].sum() / args.neg_weight) / Wt[pos].sum()
    mean, std = X.mean(0), X.std(0) + 1e-6
    Xn = ((X - mean) / std).astype(np.float32)
    del X
    net = Net([Xn.shape[1]] + [int(h) for h in args.hidden.split(",")] + [1])
    print("training on %d windows ..." % len(Xn), flush=True)
    net.fit(Xn, Y, Wt, args.epochs)
    # Hard negatives: whatever negative still scores high is weighted up and
    # the net trained a few more epochs at a lower rate.
    for r in range(args.hard_rounds):
        p = net.predict(Xn)
        hard = (~pos) & (p > 0.2)
        print("  hard round %d: %d hard negatives" % (r, hard.sum()),
              flush=True)
        Wt[hard] *= args.hard_boost
        net.fit(Xn, Y, Wt, 3, lr=3e-4)
    print("trained (%.0fs)" % (time.time() - t0), flush=True)

    win = np.lib.stride_tricks.sliding_window_view(
        held, (zs.N_FRAMES, 96)).reshape(-1, zs.N_FRAMES, 96)
    s = np.concatenate([net.predict(
        ((win[i:i + 20000].reshape(-1, zs.N_FRAMES * 96) - mean) / std)
        .astype(np.float32)) for i in range(0, len(win), 20000)])
    hours = len(s) * 0.08 / 3600
    thr = 0.99
    for cand in list(np.arange(0.30, 0.99, 0.01)) + [0.99, 0.995, 0.998]:
        if false_accepts_per_hour(s, cand) <= args.target_fa:
            thr = float(cand)
            break
    for t in (0.5, 0.8, 0.9, 0.95, 0.99, thr):
        print("  held-out %.1f h: thr %.3f -> %.2f FA/h" % (
            hours, t, false_accepts_per_hour(s, t)))
    ptr = net.predict(Xn[pos])
    print("  train positives over thr: %.3f" % (ptr >= thr).mean())
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    save = {"n_layers": len(net.W), "mean": mean, "std": std,
            "threshold": thr}
    for i, (w, b) in enumerate(zip(net.W, net.b)):
        save["W%d" % i], save["b%d" % i] = w, b
    np.savez(args.out, **save)
    print("wrote %s threshold %.2f (%.0fs total)" % (args.out, thr,
                                                    time.time() - t0))


if __name__ == "__main__":
    main()
