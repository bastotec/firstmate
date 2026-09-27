# Copy to ~/voice-lab/serve-env.sh (mode 600) and fill in. serve-ziggy.sh sources it.
export PATH="$HOME/voice-lab/hf-speech-to-speech/.venv/bin:/opt/homebrew/bin:/usr/bin:/bin"
export HOME="$HOME/voice-lab"                     # keeps the server's caches under voice-lab
export HF_HOME="$HOME/model-cache"
export OPENAI_API_KEY=""                          # the proxai client key, never committed
