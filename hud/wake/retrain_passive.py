"""retrain_passive.py - nightly: retrain the Ziggy spotter on what the HUD heard.

Builds a "not Ziggy" manifest from passive/*/index.jsonl (utterances whose
transcript has no wake word), trains a candidate with the synthetic data and
the captain's own takes, and installs it only if it is no worse:

  - hit rate on a fixed hold-out of the captain's "Ziggy" takes must not drop;
  - false wakes on the newest day's held-out passive speech must go down.

The candidate and a one-line verdict go to passive/retrain.log. The HUD picks
the new model up when it restarts (retrain_passive.sh restarts it at night).

    .venv/bin/python retrain_passive.py [--dry-run]
"""
import argparse
import glob
import json
import os
import random
import shutil
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from ziggy_spotter import ZiggySpotter   # noqa: E402

PASSIVE = os.path.join(HERE, "passive")
MODEL = os.path.join(HERE, "models", "ziggy.npz")
PATIENCE = 2


def load_passive():
    rows = []
    for index in sorted(glob.glob(os.path.join(PASSIVE, "*", "index.jsonl"))):
        for line in open(index):
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if os.path.exists(row["path"]) and row.get("seconds", 0) >= 0.5:
                rows.append(row)
    return rows


def fires(model, path):
    spot = ZiggySpotter(model_path=model, patience=PATIENCE)
    audio = open(path, "rb").read() + bytes(32000)
    for i in range(0, len(audio) - 3200, 3200):
        if spot.feed(audio[i:i + 3200]):
            return True
    return False


def score(model, positives, negatives):
    hit = sum(fires(model, e["path"]) for e in positives) / max(1, len(positives))
    false = sum(fires(model, r["path"]) for r in negatives)
    hours = sum(r["seconds"] for r in negatives) / 3600
    return hit, false, hours


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="train and score, do not install")
    args = ap.parse_args()
    rows = [r for r in load_passive() if not r.get("ziggy")]
    if len(rows) < 50:
        print("retrain: only %d passive utterances so far; skipping" % len(rows))
        return
    # Hold out a fixed 20% of the captain's takes and of the newest day's speech.
    takes = [e for e in json.load(open(os.path.join(HERE, "samples", "manifest.json")))
             if e["kind"] == "pos" and os.path.exists(e["path"])]
    rnd = random.Random(7)
    held_takes = rnd.sample(takes, max(1, len(takes) // 5))
    newest = max(os.path.basename(os.path.dirname(r["path"])) for r in rows)
    newest_rows = [r for r in rows if os.path.basename(os.path.dirname(r["path"])) == newest]
    held_neg = rnd.sample(newest_rows, max(1, len(newest_rows) // 5))
    held_paths = {r["path"] for r in held_neg}

    man = os.path.join(PASSIVE, "manifest-neg.json")
    json.dump([{"path": r["path"], "wakes": [], "kind": "neg", "text": r["text"],
                "split": "train", "real": True}
               for r in rows if r["path"] not in held_paths], open(man, "w"))
    takes_man = os.path.join(PASSIVE, "manifest-takes-train.json")
    all_takes = json.load(open(os.path.join(HERE, "samples", "manifest.json")))
    held_take_paths = {e["path"] for e in held_takes}
    json.dump([dict(e, split="test") if e["path"] in held_take_paths else e
               for e in all_takes], open(takes_man, "w"))

    candidate = os.path.join(PASSIVE, "candidate.npz")
    began = time.time()
    subprocess.run([sys.executable, os.path.join(HERE, "train_ziggy.py"),
                    "--manifest", os.path.join(HERE, "synth", "manifest.json"),
                    "--manifest", os.path.join(HERE, "synth", "noise", "manifest-train.json"),
                    "--manifest", takes_man, "--manifest", man,
                    "--out", candidate], check=True, cwd=HERE)
    old = score(MODEL, held_takes, held_neg)
    new = score(candidate, held_takes, held_neg)
    better = new[0] >= old[0] and new[1] < old[1]
    verdict = ("%s  %d utterances (%.1f h); held-out: takes %.0f%% -> %.0f%%, "
               "false wakes %d -> %d on %.2f h; %s (%.0fs)" % (
                   time.strftime("%Y-%m-%d %H:%M"), len(rows),
                   sum(r["seconds"] for r in rows) / 3600, old[0] * 100, new[0] * 100,
                   old[1], new[1], old[2],
                   "INSTALLED" if better and not args.dry_run else
                   ("would install" if better else "kept current"),
                   time.time() - began))
    if better and not args.dry_run:
        shutil.copy2(MODEL, MODEL + time.strftime(".%Y%m%d-%H%M.bak"))
        shutil.copy2(candidate, MODEL)
    with open(os.path.join(PASSIVE, "retrain.log"), "a") as log:
        log.write(verdict + "\n")
    print(verdict)


if __name__ == "__main__":
    main()
