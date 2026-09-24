#!/usr/bin/env python3
"""fm_voice_hud_bridge.py - the process boundary between the panel and the voice stack.

The panel is Swift; the wake layer, the engine wiring and the relay are Python
in this repo. This bridge is the Python half of the HUD process: it owns the
wake gate, the decoder child and the engine, and reports state to the panel as
one JSON event per line on stdout. The panel sends nothing back except a quit
line on stdin, so the boundary is a one-way report wire plus a stop signal.

Events, one compact JSON object per line:
  {"type": "state", "state": "listening"|"thinking"|"speaking"}
  {"type": "transcript", "role": "user"|"assistant", "text": "..."}
  {"type": "notice", "event": "...", ...}

The bridge never speaks for the model and never decides policy: the wake layer
decides when a turn starts, the relay decides when it ends, and this file only
carries the news. Bin fm_voice_wake.py owns the wake decision, hud/fm_voice_engine.py
owns the wire, and bin/fm-voice-relay.py owns everything behind it.
"""

import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "hud"))
sys.path.insert(0, os.path.join(ROOT, "bin"))

import fm_voice_engine as engine_mod      # noqa: E402
import fm_voice_wake as wake_mod          # noqa: E402


def emit(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main():
    verbose = "--verbose" in sys.argv
    home = None
    if "--home" in sys.argv:
        home = sys.argv[sys.argv.index("--home") + 1]
    argv = engine_mod.relay_argv(home=home, verbose=verbose)
    if "--stub-relay" in sys.argv:
        # Offline checks: a stub relay stands in for the real one, exactly as
        # tests/fm-voice-hud.test.sh does for the engine wiring alone. The
        # stub gets the repo's bin dir so it can import the frame module.
        argv = [sys.executable, sys.argv[sys.argv.index("--stub-relay") + 1],
                os.path.join(ROOT, "bin")]

    engine = engine_mod.Engine(
        argv,
        on_state=lambda state: emit({"type": "state", "state": state}),
        on_transcript=lambda role, text: emit({
            "type": "transcript",
            "role": "user" if role == "USER" else "assistant",
            "text": text}),
        on_audio=lambda pcm: None,
        on_notice=lambda event, obj: emit({"type": "notice", "event": event}),
        verbose=verbose)
    engine.start()
    emit({"type": "state", "state": "listening"})
    try:
        # The wake layer owns the microphone from here. The decoder child and
        # the mic attach land with the mic-capture stage; this bridge holds
        # the engine side of the boundary ready for them.
        for line in sys.stdin:
            if line.strip() == "quit":
                break
    finally:
        engine.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
