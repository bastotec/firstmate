#!/bin/sh
# Build the voice HUD and install it as /Applications/Ziggy.app, then restart it.
#
#   hud/install-app.sh            build, install, restart
#   hud/install-app.sh --no-build install what hud/swift/.build/release holds
#
# The app is ad-hoc signed. Only the binaries inside are (re)signed, never the
# bundle itself: that is what has kept the microphone, screen recording and
# accessibility grants across rebuilds so far.
#
# Runtime paths (the Python venv, its model cache, the first mate's home) come
# from the environment, with this Mac's current defaults.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
APP=${ZIGGY_APP:-/Applications/Ziggy.app}
VOICE=${ZIGGY_VOICE_ENV:-$HOME/.treehouse/firstmate-0243e2/15/firstmate/scratchpad-voice}
FM_HOME=${FM_HOME:-$HOME/Projects/firstmate}

if [ "${1:-}" != "--no-build" ]; then
  (cd "$HERE/swift" && xcrun swift build -c release)
fi
BUILD="$HERE/swift/.build/release"

mkdir -p "$APP/Contents/MacOS"
if [ ! -f "$APP/Contents/Info.plist" ]; then
  cp "$HERE/swift/Info.plist" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable Ziggy" \
    -c "Add :CFBundleDisplayName string Ziggy" \
    -c "Set :CFBundleName Ziggy" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

for bin in VoiceHUD VoiceAudio ScreenText; do
  target=$bin
  [ "$bin" = VoiceHUD ] && target=VoiceHUD.bin
  cp "$BUILD/$bin" "$APP/Contents/MacOS/$target.new"
  mv "$APP/Contents/MacOS/$target.new" "$APP/Contents/MacOS/$target"
  codesign --force -s - "$APP/Contents/MacOS/$target"
done

# The launch wrapper: the bundle's executable. It sets the runtime and execs
# the panel from its own folder, so the app works wherever it is installed.
cat > "$APP/Contents/MacOS/Ziggy" <<EOF
#!/bin/sh
# Launch wrapper, written by hud/install-app.sh: the voice HUD's runtime, then
# the panel. The bundle identity keeps macOS permissions with this app.
HERE=\$(cd "\$(dirname "\$0")" && pwd)
export FM_HOME="$FM_HOME"
export PATH="$VOICE/shim:$VOICE/venv/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export HF_HOME="$VOICE/hf-cache"
export FM_VOICE_AUDIO_HELPER="\$HERE/VoiceAudio"
export FM_VOICE_SCREEN_TEXT="\$HERE/ScreenText"
export VOICEAUDIO_LOG=/tmp/voiceaudio-underruns.log
cd "$ROOT" || exit 1
exec "\$HERE/VoiceHUD.bin" "\$@"
EOF
chmod 755 "$APP/Contents/MacOS/Ziggy"

# Restart: the panel's quit also stops the bridge, relay and audio helper.
pkill -f "Contents/MacOS/VoiceHUD.bin" 2>/dev/null || true
sleep 2
pkill -f fm_voice_hud_bridge.py 2>/dev/null || true
pkill -f "fm-voice-relay.py --serve" 2>/dev/null || true
pkill -f ziggy_spotter 2>/dev/null || true
pkill -x VoiceAudio 2>/dev/null || true
open "$APP"
echo "installed and started $APP"
