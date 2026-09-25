"""Generate labelled 16 kHz mono PCM test/training clips with macOS `say`.

Every clip = lead room tone + [wake part] + gap + [rest] + tail room tone.
The wake word is synthesized as its own utterance, so its end time is
known exactly (trailing TTS silence trimmed by an energy threshold).
Writes <out>/<split>/<name>.pcm and <out>/manifest.json.
"""
import json
import os
import random
import subprocess
import sys
import tempfile

import numpy as np

SR = 16000
OUT = sys.argv[1]
random.seed(7)
np.random.seed(7)

TEST_VOICES = ["Samantha", "Daniel", "Karen", "Moira", "Rishi", "Tessa",
               "Fred", "Flo (English (US))", "Reed (English (UK))", "Luciana",
               "Eddy (Portuguese (Brazil))"]
TRAIN_VOICES = ["Albert", "Aman", "Eddy (English (UK))", "Eddy (English (US))",
                "Flo (English (UK))", "Grandma (English (UK))",
                "Grandma (English (US))", "Grandpa (English (UK))",
                "Grandpa (English (US))", "Junior", "Kathy", "Ralph",
                "Reed (English (US))", "Rocko (English (UK))",
                "Rocko (English (US))", "Sandy (English (UK))",
                "Sandy (English (US))", "Shelley (English (UK))",
                "Shelley (English (US))", "Tara",
                "Sandy (Portuguese (Brazil))", "Shelley (Portuguese (Brazil))"]

COMMANDS = ["what is the status?", "open the logs.", "stop.",
            "how many crew are running?", "read me the last message.",
            "pause everything.", "what did the build say?"]
MENTIONS = [("I told ", "Ziggy", " about the deploy yesterday."),
            ("Ask ", "Ziggy", " later, not now."),
            ("Hey ", "Ziggy", ", what's up?")]
CONFUSABLES = ["Iggy", "Ziggurat", "jiggy", "piggy", "Siggy", "zig zag",
               "biggie", "sticky", "Ziggler", "zinger", "digging", "the key",
               "Zeke", "Izzy", "tricky", "Figgy", "wiggly", "cigarette",
               "Zippy", "soggy"]
SENTENCES = ["The build finished with two warnings.",
             "Can you pass me the coffee?",
             "Let's call it a day and push the rest tomorrow.",
             "I think the pipeline is green now.",
             "My dog is sleeping on the couch again.",
             "We need to rerun the tests on the staging branch.",
             "Please open the settings page.",
             "What time is the meeting with the design team?",
             "The printer jammed halfway through the benchy.",
             "Good catch, I'll fix it in the next commit.",
             "Is the fridge making that noise again?",
             "Send the report to the whole team.",
             "It's a jiggly piggy on a zig zag road.",
             "Big city lights and busy streets.",
             "Easy, see, it's in the log file.",
             ]


def say(text, voice, rate=None):
    with tempfile.TemporaryDirectory() as d:
        path = os.path.join(d, "o.wav")
        cmd = ["say", "-v", voice, "-o", path, "--file-format=WAVE",
               "--data-format=LEI16@16000"]
        if rate:
            cmd += ["-r", str(rate)]
        subprocess.run(cmd + [text], check=True)
        data = open(path, "rb").read()
    # find the data chunk
    i = data.find(b"data")
    n = int.from_bytes(data[i + 4:i + 8], "little")
    return np.frombuffer(data[i + 8:i + 8 + n], dtype="<i2").astype(np.float32)


def trim(x, thr=300.0):
    """Trim leading/trailing TTS silence (abs amplitude)."""
    idx = np.where(np.abs(x) > thr)[0]
    if len(idx) == 0:
        return x[:0]
    return x[max(0, idx[0] - 80): idx[-1] + 80]


def room(n, level_rms):
    """Brown-ish room tone at a target RMS."""
    w = np.random.randn(n).astype(np.float32)
    b = np.cumsum(w)
    b -= np.convolve(b, np.ones(400) / 400, mode="same")   # remove drift
    b = b / (np.std(b) + 1e-9) * level_rms * 0.7
    return b + np.random.randn(n).astype(np.float32) * level_rms * 0.3


def scale(x, rms):
    return x / (np.sqrt(np.mean(x ** 2)) + 1e-9) * rms


def assemble(parts, room_rms, speech_rms, lead=0.5, tail=1.0):
    """parts: list of (audio or None-gap-seconds, is_wake). Returns pcm,
    list of (start_s, end_s) wake intervals."""
    segs = [np.zeros(int(lead * SR), np.float32)]
    t = lead
    wakes = []
    for p, is_wake in parts:
        if isinstance(p, float):
            segs.append(np.zeros(int(p * SR), np.float32))
            t += p
            continue
        p = scale(p, speech_rms)
        if is_wake:
            wakes.append((round(t, 3), round(t + len(p) / SR, 3)))
        segs.append(p)
        t += len(p) / SR
    segs.append(np.zeros(int(tail * SR), np.float32))
    x = np.concatenate(segs)
    x = x + room(len(x), room_rms)
    return np.clip(x, -32768, 32767).astype("<i2"), wakes


def emit(manifest, split, name, pcm, wakes, kind, text, voice):
        d = os.path.join(OUT, split)
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, name + ".pcm")
        pcm.tofile(path)
        manifest.append(dict(split=split, path=path, wakes=wakes, kind=kind,
                             text=text, voice=voice,
                             dur=round(len(pcm) / SR, 3)))


def one_voice(job):
    split, v = job
    manifest = []
    random.seed(hash(v) % 1000)
    np.random.seed(hash(v) % 1000)
    if True:
        if True:
            tag = "".join(ch for ch in v if ch.isalnum())[:14]
            for rate in ((None, 150, 220) if split == "test" else
                         (None, 140, 170, 200, 240)):
                rtag = rate or "def"
                room_rms = random.choice([30, 150, 500, 900])
                sp = random.choice([2500, 4000, 7000])
                zig = trim(say("Ziggy.", v, rate))
                # "Ziggy" alone
                pcm, w = assemble([(zig, True)], room_rms, sp)
                emit(manifest, split, f"alone_{tag}_{rtag}", pcm, w, "pos",
                     "Ziggy.", v)
                # "Ziggy, <command>"
                cmd = random.choice(COMMANDS)
                zc = trim(say("Ziggy,", v, rate))
                rest = trim(say(cmd, v, rate))
                pcm, w = assemble([(zc, True), (random.uniform(.08, .3), 0),
                                   (rest, False)], room_rms, sp)
                emit(manifest, split, f"cmd_{tag}_{rtag}", pcm, w, "pos",
                     "Ziggy, " + cmd, v)
            # mid-sentence mentions (default rate)
            for mi, (a, z, b) in enumerate(MENTIONS):
                pa, pz, pb = trim(say(a, v)), trim(say(z, v)), trim(say(b, v))
                pcm, w = assemble([(pa, False), (0.05, 0), (pz, True),
                                   (0.05, 0), (pb, False)],
                                  random.choice([30, 500]), 4000)
                emit(manifest, split, f"mention{mi}_{tag}", pcm, w, "mention",
                     a + z + b, v)
            # confusable words and plain sentences
            for ci, c in enumerate(CONFUSABLES):
                pcm, _ = assemble([(trim(say(c, v)), False)],
                                  random.choice([30, 500]), 4000)
                emit(manifest, split, f"conf{ci}_{tag}", pcm, [], "confusable", c, v)
            for si, s in enumerate(SENTENCES):
                pcm, _ = assemble([(trim(say(s, v)), False)],
                                  random.choice([30, 500]), 4000)
                emit(manifest, split, f"neg{si}_{tag}", pcm, [], "neg", s, v)
    print(v, "done", flush=True)
    return manifest


def main():
    from multiprocessing import Pool
    os.makedirs(OUT, exist_ok=True)
    jobs = [("test", v) for v in TEST_VOICES] + \
        [("train", v) for v in TRAIN_VOICES]
    manifest = []
    with Pool(6) as pool:
        for m in pool.imap_unordered(one_voice, jobs):
            manifest.extend(m)
    # pure room tone / silence, long
    for i, lvl in enumerate([0, 30, 150, 500, 900, 1500]):
        n = 30 * SR
        x = room(n, lvl) if lvl else np.zeros(n, np.float32)
        emit(manifest, "test", f"room{i}_{lvl}", np.clip(x, -32768, 32767).astype("<i2"),
             [], "room", "", "")
    json.dump(manifest, open(os.path.join(OUT, "manifest.json"), "w"),
              indent=1)
    print("clips:", len(manifest))


if __name__ == "__main__":
    main()
