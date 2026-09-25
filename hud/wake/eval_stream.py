"""Stream every test clip, back to back with 1 s of room tone between them,
through one detector instance in 100 ms blocks, the way the HUD would.

Latency per positive = (end of the block whose feed() returned the wake,
in audio time) - (true end of the word) + (compute time of that feed()).
That is the delay from the captain finishing "Ziggy" to the event, given
the HUD delivers 100 ms blocks.
"""
import json
import os
import sys
import time

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
BLOCK = 3200
SR = 16000


def build_stream(man, split="test"):
    rng = np.random.default_rng(1)
    parts, spans = [], []
    t = 0
    for m in man:
        if m["split"] != split:
            continue
        gap = (rng.standard_normal(SR) * 40).astype("<i2")
        parts.append(gap)
        t += len(gap)
        x = np.fromfile(m["path"], "<i2")
        parts.append(x)
        spans.append((t / SR, (t + len(x)) / SR, m))
        t += len(x)
    x = np.concatenate(parts)
    pad = (-len(x)) % (BLOCK // 2)
    return np.concatenate([x, np.zeros(pad, "<i2")]).tobytes(), spans


def run(detector, stream):
    events, costs = [], []
    for i in range(0, len(stream), BLOCK):
        t0 = time.perf_counter()
        hits = detector.feed(stream[i:i + BLOCK])
        c = time.perf_counter() - t0
        costs.append(c)
        for h in hits:
            events.append(((i + BLOCK) / 2 / SR, c, h))
    return events, np.array(costs)


def score(events, spans, label):
    rows = {"pos": [0, 0], "mention": [0, 0], "confusable": [0, 0],
            "neg": [0, 0], "room": [0, 0]}
    lat, fa = [], []
    ev_t = np.array([e[0] for e in events]) if events else np.zeros(0)
    for s, e, m in spans:
        k = m["kind"]
        rows[k][1] += 1
        inside = [ev for ev in events if s <= ev[0] < e + 0.0]
        if m["wakes"]:
            ws, we = m["wakes"][0]
            good = [ev for ev in inside if s + ws <= ev[0] <= s + we + 1.0]
            if good:
                rows[k][0] += 1
                if k == "pos":
                    lat.append(good[0][0] - (s + we) + good[0][1])
            extra = len(inside) - (1 if good else 0)
            if extra:
                fa.append((os.path.basename(m["path"]), extra))
        elif inside:
            rows[k][0] += 1
            fa.append((os.path.basename(m["path"]), len(inside)))
    lat = np.array(lat)
    print("== %s" % label)
    for k, (a, n) in rows.items():
        what = "detected" if k in ("pos", "mention") else "false-accept clips"
        print("  %-10s %3d/%3d %s" % (k, a, n, what))
    if len(lat):
        print("  latency after word end (s): p50 %.3f  p90 %.3f  max %.3f  "
              "min %.3f" % (np.median(lat), np.percentile(lat, 90), lat.max(),
                            lat.min()))
    return lat, fa


if __name__ == "__main__":
    man = sum((json.load(open(p)) for p in sys.argv[1].split(",")), [])
    which = sys.argv[2]
    stream, spans = build_stream(man)
    hours = len(stream) / 2 / SR / 3600
    print("stream %.1f min" % (hours * 60))
    if which == "sherpa":
        import sherpa_kws
        for thr in [float(v) for v in sys.argv[3].split(",")]:
            det = sherpa_kws.SherpaKws(threshold=thr,
                                       score=float(sys.argv[4]) if
                                       len(sys.argv) > 4 else 1.5)
            ev, costs = run(det, stream)
            lat, fa = score(ev, spans, "sherpa thr %.2f" % thr)
            print("  compute/block ms p50 %.1f p99 %.1f" % (
                np.median(costs) * 1e3, np.percentile(costs, 99) * 1e3))
            print("  FA:", fa[:12])
    else:
        import ziggy_spotter
        model = sys.argv[3]
        for thr in [float(v) for v in sys.argv[4].split(",")]:
            det = ziggy_spotter.ZiggySpotter(model, threshold=thr)
            ev, costs = run(det, stream)
            lat, fa = score(ev, spans, "ziggy mlp thr %.2f" % thr)
            print("  compute/block ms p50 %.1f p99 %.1f" % (
                np.median(costs) * 1e3, np.percentile(costs, 99) * 1e3))
            print("  FA:", fa[:12])
