#!/usr/bin/env python3
"""record_samples.py - record the captain's own "Ziggy" samples for training.

Run it yourself, in a quiet-ish room, at your usual distance from the Mac:

    cd ~/Projects/firstmate-voice/hud/wake
    .venv/bin/python record_samples.py            # ~60 prompts, ~5 minutes

Each prompt: press Enter, wait for "speak", say the line, stay quiet until
the next prompt. Say "Ziggy" the way you will really say it - vary speed,
volume and distance a little; turn your head away for a few. Ctrl-C stops at
any point and keeps what was recorded. Run it again another day (different
room noise, a fan on) and the new takes are added, not replaced.

Output: samples/<session>/NNN.pcm (16 kHz mono s16le) plus
samples/manifest.json. Then retrain:

    .venv/bin/python train_ziggy.py \
        --manifest synth/manifest.json --manifest synth/noise/manifest-train.json \
        --manifest samples/manifest.json

The word end in each "Ziggy" take is found automatically from the audio
energy (the first pause after the word). Check with --review.
"""

import argparse
import json
import os
import random
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
SAMPLES = os.path.join(HERE, "samples")
SR = 16000

WAKE_PROMPTS = (["Ziggy"] * 20 + ["Ziggy (quietly)"] * 4 +
                ["Ziggy (from further away)"] * 4 +
                ["Ziggy (fast, a bit bored)"] * 4)
COMMAND_PROMPTS = ["Ziggy, what is the status?", "Ziggy, open the logs.",
                   "Ziggy, stop.", "Ziggy, how many crew are running?",
                   "Ziggy, read me the last message.", "Hey Ziggy, pause.",
                   "Ziggy... what did the build say?", "Ziggy, cancel that."]
NEGATIVE_PROMPTS = ["Iggy", "jiggy", "piggy", "Siggy", "zig zag", "biggie",
                    "sticky", "the key", "Izzy", "Zippy",
                    "I think the pipeline is green now.",
                    "Let's call it a day.", "Can you open the settings?",
                    "Good catch, makes sense.",
                    "(say anything in Portuguese)",
                    "(say anything in Portuguese)"]


def word_span(x):
    """(start, end) in seconds of the first spoken word: first >=150 ms pause after
    speech onset, from 20 ms frame energies against the take's own floor."""
    f = 320
    e = np.array([np.mean(x[i:i + f].astype(np.float64) ** 2)
                  for i in range(0, len(x) - f, f)])
    if not len(e):
        return None
    floor = np.percentile(e, 10)
    thr = max(floor * 8, np.percentile(e, 95) * 0.02, 2e4)
    voiced = e > thr
    on = np.flatnonzero(voiced)
    if not len(on):
        return None
    i, quiet = on[0], 0
    while i < len(voiced):
        quiet = 0 if voiced[i] else quiet + 1
        if quiet >= 8:                   # 160 ms of pause
            return (round(on[0] * f / SR, 3),
                    round((i - quiet + 1) * f / SR, 3))
        i += 1
    return round(on[0] * f / SR, 3), round((on[-1] + 1) * f / SR, 3)


def record(sd, seconds):
    x = sd.rec(int(seconds * SR), samplerate=SR, channels=1, dtype="int16")
    sd.wait()
    return x[:, 0]


def load_manifest(path):
    if os.path.exists(path):
        return json.load(open(path))
    return []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--review", action="store_true",
                    help="list recorded takes and their detected word ends")
    ap.add_argument("--no-negatives", action="store_true")
    args = ap.parse_args()
    man_path = os.path.join(SAMPLES, "manifest.json")
    manifest = load_manifest(man_path)
    if args.review:
        for m in manifest:
            print("%-40s %-8s %s  %s" % (os.path.relpath(m["path"], HERE),
                                        m["kind"], m["wakes"], m["text"]))
        return

    import sounddevice as sd             # noqa: PLC0415
    session = time.strftime("%Y%m%d-%H%M%S")
    out = os.path.join(SAMPLES, session)
    os.makedirs(out, exist_ok=True)
    prompts = [(p, "pos", 2.5) for p in WAKE_PROMPTS] + \
        [(p, "pos", 4.5) for p in COMMAND_PROMPTS]
    if not args.no_negatives:
        prompts += [(p, "neg", 3.5) for p in NEGATIVE_PROMPTS]
    random.shuffle(prompts)
    prompts.insert(0, ("(stay silent - room tone)", "room", 15.0))
    print("%d prompts. Enter = record, Ctrl-C = stop and save.\n" %
          len(prompts))
    n = 0
    try:
        for k, (text, kind, secs) in enumerate(prompts):
            input("[%d/%d] next: %s   (Enter)" % (k + 1, len(prompts), text))
            time.sleep(0.3)
            print("   speak ...", flush=True)
            x = record(sd, secs)
            if not x.any():
                print("\n   The microphone delivered pure silence. macOS does that when this")
                print("   app is not allowed to use the microphone: allow your terminal in")
                print("   System Settings > Privacy & Security > Microphone, restart the")
                print("   terminal, and run this again.")
                return
            path = os.path.join(out, "%03d.pcm" % k)
            x.astype("<i2").tofile(path)
            wakes = []
            if kind == "pos":
                span = word_span(x)
                if span is None:
                    print("   (heard nothing - skipped)")
                    os.remove(path)
                    continue
                wakes = [list(span)]
                print("   ok, word at %.2f-%.2fs" % span)
            manifest.append({"path": path, "wakes": wakes, "kind": kind,
                             "text": text, "split": "train", "real": True})
            n += 1
    except KeyboardInterrupt:
        print()
    os.makedirs(SAMPLES, exist_ok=True)
    json.dump(manifest, open(man_path, "w"), indent=1)
    print("saved %d takes to %s" % (n, out))


if __name__ == "__main__":
    sys.exit(main())
