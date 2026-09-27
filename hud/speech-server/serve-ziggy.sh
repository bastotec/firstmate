#!/bin/sh
# Ziggy's local speech server (STT + TTS + gateway text), with its MLX models
# pinned in memory so a quiet spell never costs an ~11 s cold start.
. /Users/bastotecnologia/voice-lab/serve-env.sh
export S2S_WIRED_LIMIT_GB="${S2S_WIRED_LIMIT_GB:-6}"
export S2S_TTS_KEEPWARM_S="${S2S_TTS_KEEPWARM_S:-45}"
exec /Users/bastotecnologia/voice-lab/hf-speech-to-speech/.venv/bin/speech-to-speech serve \
  --host 127.0.0.1 --port 49597 --stt fluidaudio \
  --llm_backend chat-completions --model_name vercel/openai/gpt-6-luna \
  --responses_api_base_url http://127.0.0.1:8329/v1 --responses_api_stream True \
  --responses_api_disable_thinking False --stream_batch_sentences 1 \
  --responses_api_reasoning_effort low --compact_history False --tts kokoro --kokoro_voice bm_fable --kokoro_lang_code b --no_smart_turn \
  >> /Users/bastotecnologia/.treehouse/firstmate-0243e2/15/firstmate/scratchpad-voice/engine.log 2>&1
