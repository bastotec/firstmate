#!/usr/bin/env bash
# tests/fm-voice-hud-panel.test.sh - the overlay panel's Swift surface.
#
# The panel's whole headless surface runs here: the HUDModel state machine
# (including the loud microphone-blocked face and the live mic level), the
# Bridge wire parse, and the one shipped-artifact fact macOS itself consumes
# - the app binary embedding NSMicrophoneUsageDescription in its
# __TEXT,__info_plist section, which is what makes a relaunch raise the real
# TCC microphone prompt instead of a silent denial. The GUI panel itself
# (drag, always-on-top, live rendering) needs the captain's Mac and is named
# in the PR body, not asserted here.
#
# Skips cleanly off macOS or where swift is not installed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ "$(uname -s)" = "Darwin" ] || { echo "skip: the overlay panel builds on macOS only"; exit 0; }
command -v swift >/dev/null 2>&1 || { echo "skip: swift not found"; exit 0; }

# The panel's own test target: the model, the blocked face, the level, the
# wire parse. This is the same `swift test` the package ships.
if ! (cd "$ROOT/hud/swift" && swift test >/dev/null 2>&1); then
    (cd "$ROOT/hud/swift" && swift test 2>&1 | tail -25) >&2
    fail "the panel's Swift tests"
fi
pass "the panel model, blocked face and wire parse pass their Swift tests"

# The shipped binary carries the microphone usage description in the section
# macOS reads for the TCC prompt. Parsed as the plist it is, never grepped:
# the assertion is the machine-consumed artifact, not source text.
python3 - "$ROOT/hud/swift/.build/debug/VoiceHUD" <<'PY' || fail "shipped usage description"
import plistlib, subprocess, sys

binary = sys.argv[1]
out = subprocess.run(
    ["otool", "-s", "__TEXT", "__info_plist", binary],
    capture_output=True, text=True, check=True).stdout
data = bytearray()
for line in out.splitlines():
    parts = line.split()
    # Hex dump rows: a 16-hex address, then 4-byte words to byte-swap.
    if not parts or len(parts[0]) != 16:
        continue
    try:
        row = b"".join(bytes.fromhex(w)[::-1] for w in parts[1:] if w)
    except ValueError:
        continue
    data += row
if not data.startswith(b"<?xml"):
    sys.exit("usage description: the binary carries no readable __info_plist "
             "section: " + repr(bytes(data[:32])))
info = plistlib.loads(bytes(data))
desc = info.get("NSMicrophoneUsageDescription")
if not isinstance(desc, str) or not desc.strip():
    sys.exit("usage description: NSMicrophoneUsageDescription is missing or "
             "empty: " + repr(info))
print("shipped: NSMicrophoneUsageDescription embedded in the app binary")
PY
pass "the shipped app binary embeds the microphone usage description"
