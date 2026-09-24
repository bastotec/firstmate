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
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "hud"))
sys.path.insert(0, os.path.join(ROOT, "bin"))

import fm_voice_engine as engine_mod      # noqa: E402
import fm_voice_mic as mic_mod            # noqa: E402
import fm_voice_speaker as speaker_mod    # noqa: E402
import fm_voice_wake as wake_mod          # noqa: E402


def emit(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def arg_after(flag):
    if flag in sys.argv:
        return sys.argv[sys.argv.index(flag) + 1]
    return None


def output_device_arg():
    """The --output-device value as sounddevice takes it: an index when
    the value is digits, a name otherwise - the client's selector rule."""
    value = arg_after("--output-device")
    if value is None:
        return None
    return int(value) if value.isdigit() else value


def main():
    verbose = "--verbose" in sys.argv
    home = arg_after("--home")
    argv = engine_mod.relay_argv(home=home, verbose=verbose)
    stub = arg_after("--stub-relay")
    if stub:
        # Offline checks: a stub relay stands in for the real one, exactly as
        # tests/fm-voice-hud.test.sh does for the engine wiring alone. The
        # stub gets the repo's bin dir so it can import the frame module.
        argv = [sys.executable, stub, os.path.join(ROOT, "bin")]

    # The reply player: the engine hands reply audio to it whole. A machine
    # with no output device keeps a working HUD - the transcript still
    # arrives - and says so on the wire rather than dying at startup.
    speaker = None
    try:
        speaker = speaker_mod.Speaker(device=output_device_arg())
    except Exception as exc:                  # noqa: BLE001
        emit({"type": "notice", "event": "output-unavailable",
              "error": "{}: {}".format(type(exc).__name__, exc)})

    engine_fault = threading.Event()

    def report_fault():
        # The engine's own notice already said it when the wire died; this
        # is the same news from the mic loop's side, said once.
        if engine_fault.is_set():
            return
        engine_fault.set()
        emit({"type": "notice", "event": "engine-fault"})

    def on_engine_notice(event, obj):
        if event == "engine-fault":
            report_fault()
        else:
            emit({"type": "notice", "event": event})

    engine = engine_mod.Engine(
        argv,
        on_state=lambda state: emit({"type": "state", "state": state}),
        on_transcript=lambda role, text: emit({
            "type": "transcript",
            "role": "user" if role == "USER" else "assistant",
            "text": text}),
        on_audio=speaker.write if speaker else (lambda pcm: None),
        on_notice=on_engine_notice,
        verbose=verbose)
    engine.start()
    emit({"type": "state", "state": "listening"})

    # The wake layer owns the microphone from here. The decoder child is a
    # separate process; absent config means gate-only (the HUD hears speech
    # and never wakes, which the panel shows as listening forever).
    decoder_argv = None
    decoder_config = os.path.join(ROOT, "config", "voice-hud-decoder")
    env_decoder = os.environ.get("FM_VOICE_HUD_DECODER")
    source = None
    if env_decoder:
        decoder_argv = ["sh", "-c", env_decoder]
        source = "FM_VOICE_HUD_DECODER"
    elif os.path.isfile(decoder_config):
        first = open(decoder_config).read().splitlines()
        first = [ln.strip() for ln in first if ln.strip() and not ln.startswith("#")]
        if first:
            decoder_argv = ["sh", "-c", first[0]]
            source = "config/voice-hud-decoder"

    decoder = mic_mod.DecoderCommand(decoder_argv) if decoder_argv \
        else mic_mod.NullDecoder()
    decoder.start()
    if source:
        emit({"type": "notice", "event": "decoder", "source": source})

    # The mic end: a PCM file for offline checks (--mic-file), the real
    # microphone otherwise. The device end is UNVERIFIED from a worker shell
    # for the same reason the client's is; the file end is what every check
    # here drives.
    mic_file = arg_after("--mic-file")
    if mic_file:
        mic = mic_mod.FileMic(mic_file)
    else:
        mic = mic_mod.DeviceMic()

    director = mic_mod.TurnDirector(
        engine, wake_mod.EnergyGate(), wake_mod.KeywordListener(), decoder,
        on_notice=lambda event: emit({"type": "notice", "event": event}))

    stop = threading.Event()

    def run_mic():
        # The mic thread owns block timing; the director's decisions come
        # back as engine callbacks, which emit on this same stdout safely
        # because emit is the only writer and stays line-atomic. An engine
        # fault here is reported on the wire, never allowed to die with a
        # traceback the panel cannot see: a closed engine leaves the HUD
        # deaf until restart, and a turn the engine abandoned mid-reply is
        # re-armed, because the relay's renewal path is the next turn.
        block_period = mic_mod.BLOCK / 16000.0
        next_at = time.monotonic()
        for block in mic.blocks():
            if stop.is_set():
                return
            try:
                director.feed(block, time.monotonic())
            except engine_mod.EngineError as exc:
                if engine.closed.is_set():
                    report_fault()
                    return
                emit({"type": "notice", "event": "turn-timeout",
                      "error": str(exc)})
                director.recover()
                continue
            next_at += block_period
            delay = next_at - time.monotonic()
            if delay > 0:
                stop.wait(delay)

    mic_thread = threading.Thread(target=run_mic, daemon=True)
    mic_thread.start()

    try:
        # The main thread owns the quit signal; the mic thread owns blocks.
        for line in sys.stdin:
            if line.strip() == "quit":
                break
    finally:
        stop.set()
        mic.close()
        decoder.close()
        engine.close()
        if speaker is not None:
            speaker.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
