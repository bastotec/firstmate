#!/usr/bin/env bash
set -u
. /tmp/fm-recover-live/rig.sh
probe() { rig_env bash -c '. "$0"/bin/fm-backend.sh; fm_backend_source tmux; fm_backend_agent_state tmux '"$1" "$ROOT"; }
RC_SLEEP=1 rig_reset
rig_task j1 fmlive
rig_tmux new-session -d -s fmlive -c "$RIG" -x 160 -y 40
rig_tmux new-window -d -t fmlive -n fm-j1 -c "$RIG/wt-j1"
until [ "$(probe fmlive:fm-j1)" = dead ]; do sleep 0.5; done
echo "== the terminal is THERE but the agent exited: a dead endpoint, not a missing one"
echo "endpoint state: $(probe fmlive:fm-j1)"
before=$(md5 -q "$RIG/home/state/j1.meta"); bbefore=$(md5 -q "$RIG/home/data/j1/brief.md")
rig_control j1 recover-missing --note "rescue me"; echo "rc=$?"
[ "$before" = "$(md5 -q "$RIG/home/state/j1.meta")" ] && [ "$bbefore" = "$(md5 -q "$RIG/home/data/j1/brief.md")" ] \
  && echo "durable record and instructions: byte-identical" || echo "CHANGED!"
echo
echo "== and the verb that DOES own a dead endpoint still works, unchanged =="
rig_control j1 relaunch --note "the agent exited; continue the same run"; echo "relaunch rc=$?"
echo "endpoint state: $(probe fmlive:fm-j1)"
