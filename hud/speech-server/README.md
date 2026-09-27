# Ziggy's local speech server

Ziggy's speech runs on [hf-speech-to-speech](https://github.com/gkintu/hf-speech-to-speech) with three local patches on top of upstream `99749e5` (see `UPSTREAM_BASE`):

1. `0001` FluidAudio STT backend (Parakeet v3 on the Neural Engine, ~0.1 s) and an opt-in MLX wired-memory limit.
2. `0002` Qwen3-TTS keep-warm: a silent synthesis while idle (`S2S_TTS_KEEPWARM_S`), so the first reply after a quiet spell isn't an 11 s cold start.
3. `0003` the same keep-warm for Kokoro, the voice Ziggy uses now (first sentence after idle went from 14-44 s to under a second).

## Set up

```bash
git clone https://github.com/gkintu/hf-speech-to-speech ~/voice-lab/hf-speech-to-speech
cd ~/voice-lab/hf-speech-to-speech
git checkout -b ziggy $(cat ~/Projects/firstmate-voice/hud/speech-server/UPSTREAM_BASE)
git am ~/Projects/firstmate-voice/hud/speech-server/patches/*.patch
```

Then copy `serve-env.example.sh` to `~/voice-lab/serve-env.sh` (mode 600, with the proxai key) and `serve-ziggy.sh` to `~/voice-lab/`.

`serve-ziggy.sh` starts the server on `ws://127.0.0.1:49597`: FluidAudio STT, Luna through proxai with `reasoning_effort low`, Kokoro `bm_fable`, keep-warm every 45 s.
