"""Open-vocabulary keyword spotting with sherpa-onnx (no training needed).

A 3.3M-parameter streaming zipformer transducer trained on GigaSpeech. The
keyword is given as BPE tokens, so "Ziggy" works without any recordings.
Used as a baseline next to the trained openWakeWord-style classifier.
"""

import os

import numpy as np
import sherpa_onnx

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL_DIR = os.path.join(
    HERE, "models", "sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01")

# Spellings the tokenizer splits differently; any of them counts as a wake.
VARIANTS = ["ZIGGY", "ZIGGIE", "ZIGGI"]


def write_keywords(path, score=1.5, threshold=0.25):
    lines = []
    for word in VARIANTS:
        toks = sherpa_onnx.text2token(
            [word], tokens=os.path.join(MODEL_DIR, "tokens.txt"),
            tokens_type="bpe", bpe_model=os.path.join(MODEL_DIR, "bpe.model"))
        lines.append(" ".join(toks[0]) + " :{} #{} @{}".format(
            score, threshold, word))
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


class SherpaKws:
    """feed(pcm16 bytes) -> list of keyword strings detected in this block."""

    def __init__(self, score=1.5, threshold=0.25, trailing_blanks=1,
                 int8=True, threads=1):
        kw = os.path.join(MODEL_DIR, "keywords-ziggy-{}-{}.txt".format(
            score, threshold))
        if not os.path.exists(kw):
            write_keywords(kw, score, threshold)
        suffix = ".int8.onnx" if int8 else ".onnx"
        stem = "-epoch-12-avg-2-chunk-16-left-64"
        self.kws = sherpa_onnx.KeywordSpotter(
            tokens=os.path.join(MODEL_DIR, "tokens.txt"),
            encoder=os.path.join(MODEL_DIR, "encoder" + stem + suffix),
            decoder=os.path.join(MODEL_DIR, "decoder" + stem + suffix),
            joiner=os.path.join(MODEL_DIR, "joiner" + stem + suffix),
            keywords_file=kw, num_threads=threads,
            num_trailing_blanks=trailing_blanks, provider="cpu")
        self.stream = self.kws.create_stream()

    def feed(self, block):
        x = np.frombuffer(block, dtype="<i2").astype(np.float32) / 32768.0
        self.stream.accept_waveform(16000, x)
        hits = []
        while self.kws.is_ready(self.stream):
            self.kws.decode_stream(self.stream)
            r = self.kws.get_result(self.stream)
            if r:
                hits.append(r)
                self.kws.reset_stream(self.stream)
        return hits
