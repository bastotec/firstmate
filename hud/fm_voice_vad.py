"""fm_voice_vad.py - Silero VAD for the HUD: is this block speech?

The HUD's energy gate calls anything loud "speech", so room hum, clicks and
Ziggy's own voice leaking past the echo canceller reopened conversations and
kept turns open. Silero VAD (MIT, snakers4/silero-vad; the same model the
speech server uses) is a small speech classifier: 32 ms windows at 16 kHz,
well under a millisecond each on the CPU.

    vad = SileroVAD()             # None-safe: load() returns None without the model
    prob = vad(block)             # 0..1 for one 100 ms mic block (max over windows)
"""

import os

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL = os.path.join(HERE, "wake", "models", "silero_vad.onnx")
WINDOW = 512          # samples per model call at 16 kHz
CONTEXT = 64          # samples of the previous window the model expects in front


class SileroVAD:
    def __init__(self, model=MODEL):
        import onnxruntime                          # noqa: PLC0415
        options = onnxruntime.SessionOptions()
        options.intra_op_num_threads = 1
        options.inter_op_num_threads = 1
        self.session = onnxruntime.InferenceSession(model, options,
                                                    providers=["CPUExecutionProvider"])
        self.reset()

    def reset(self):
        self._state = np.zeros((2, 1, 128), dtype=np.float32)
        self._context = np.zeros((1, CONTEXT), dtype=np.float32)
        self._pending = np.zeros(0, dtype=np.float32)

    def __call__(self, block):
        """Speech probability for one block of s16le mono 16 kHz PCM: the
        highest over the 32 ms windows it completes (leftovers carry over)."""
        x = np.frombuffer(block, dtype="<i2").astype(np.float32) / 32768.0
        audio = np.concatenate([self._pending, x])
        best = 0.0
        n = len(audio) // WINDOW
        for i in range(n):
            window = audio[i * WINDOW:(i + 1) * WINDOW][None, :]
            feed = {"input": np.concatenate([self._context, window], axis=1),
                    "state": self._state, "sr": np.array(16000, dtype=np.int64)}
            out, self._state = self.session.run(None, feed)
            self._context = window[:, -CONTEXT:]
            best = max(best, float(out[0][0]))
        self._pending = audio[n * WINDOW:]
        return best


def load():
    """The VAD, or None when the model or onnxruntime is missing."""
    try:
        return SileroVAD()
    except Exception:                               # noqa: BLE001
        return None
