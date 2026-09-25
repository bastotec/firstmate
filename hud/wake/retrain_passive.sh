#!/bin/sh
# Nightly Ziggy spotter retrain on passively collected speech; restarts the HUD
# only when a better model was installed. Scheduled by
# ~/Library/LaunchAgents/com.bastotecnologia.ziggy-retrain.plist
cd "$(dirname "$0")" || exit 1
before=$(stat -f %m models/ziggy.npz)
.venv/bin/python retrain_passive.py >> passive/retrain-run.log 2>&1
after=$(stat -f %m models/ziggy.npz)
if [ "$before" != "$after" ]; then
  pkill -f "VoiceHUD.app/Contents/MacOS/VoiceHUD.bin"; sleep 3
  pkill -f "fm_voice_hud_bridge.py"; pkill -f "fm-voice-relay.py --serve"; pkill -f "ziggy_spotter.py"; sleep 1
  open /Users/bastotecnologia/.treehouse/firstmate-0243e2/15/firstmate/scratchpad-onscreen/VoiceHUD.app
fi
