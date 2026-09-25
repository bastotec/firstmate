#!/usr/bin/env bash
# tests/fm-voice-hud-live-e2e.test.sh - the HUD's real microphone end, live.
#
# The one proof this repo cannot fake: the shipped DeviceMic end capturing
# real audio from the machine it runs on for a couple of seconds, through
# the product's own code path, and reporting whether the samples are
# non-silent or all-zero - the exact signature a denied microphone produces.
# Whichever verdict the machine gives, the product's own notice path must
# agree with it: all-zero fires mic-denied on the wire, non-silent does not.
#
# Opt-in because it needs a live input device: FM_VOICE_HUD_LIVE=1 (or
# FM_LIVE=1). Skips cleanly where sounddevice is missing, no input device
# exists, or the device delivers nothing (no microphone permission).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

fm_live_gate opt-in FM_VOICE_HUD_LIVE python3

python3 - "$ROOT" <<'PY' || fail "live mic capture"
import importlib.util, os, sys, time

try:
    import sounddevice
except ImportError:
    print("skip: live: sounddevice is not importable by this python3 "
          "(pip install sounddevice per docs/voice-relay.md)")
    sys.exit(0)

inputs = [d for d in sounddevice.query_devices()
          if d.get("max_input_channels", 0) > 0]
if not inputs:
    print("skip: live: no input device on this machine")
    sys.exit(0)


def load(name, relpath):
    spec = importlib.util.spec_from_file_location(
        name, os.path.join(sys.argv[1], relpath))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


mic_mod = load("micmod", "hud/fm_voice_mic.py")
wake = load("wake", "hud/fm_voice_wake.py")

notices = []
try:
    mic = mic_mod.DeviceMic(
        on_silent=lambda: notices.append("mic-denied"),
        on_status=lambda flag: notices.append("mic-status: " + flag),
        silent_after_blocks=10)      # a 1.0s bound inside the 2s proof
except Exception as exc:
    print("skip: live: the input stream refused to open: {}: {}".format(
        type(exc).__name__, exc))
    sys.exit(0)

blocks = []
deadline = time.monotonic() + 2.0
try:
    for block in mic.blocks():
        blocks.append(block)
        if time.monotonic() > deadline:
            break
finally:
    mic.close()

if not blocks:
    print("skip: live: the device delivered no audio "
          "(microphone permission not granted?)")
    sys.exit(0)

seconds = len(blocks) * mic_mod.BLOCK / 32000.0
energies = [wake.block_energy(b) for b in blocks]
silent = all(not any(b) for b in blocks)
print("live: captured {:.1f}s in {} blocks, peak energy {:.0f}".format(
    seconds, len(blocks), max(energies)))

if silent:
    if "mic-denied" not in notices:
        sys.exit("live mic: an all-zero capture must fire the mic-denied "
                 "notice: " + repr(notices))
    print("live: all-zero capture - the denied signature, and the "
          "mic-denied notice fired on the product path")
else:
    if "mic-denied" in notices:
        sys.exit("live mic: a non-silent capture must not report a denied "
                 "mic: " + repr(notices))
    print("live: non-silent capture - the microphone path is live and audible")
PY
pass "the HUD's real microphone end captures and names what it hears"
