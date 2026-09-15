#!/usr/bin/env bash
set -u
. /tmp/fm-recover-live/rig.sh
probe() { rig_env bash -c '. "$0"/bin/fm-backend.sh; fm_backend_source tmux; fm_backend_agent_state tmux '"$1" "$ROOT"; }
# A terminal whose login shell keeps a non-shell process in the foreground for
# 25s: far longer than the settle budget below.
RC_SLEEP=25 rig_reset
rig_task e1 fmlive
rig_tmux new-session -d -s fmlive -c "$RIG" -x 200 -y 50
meta_before=$(md5 -q "$RIG/home/state/e1.meta"); brief_before=$(md5 -q "$RIG/home/data/e1/brief.md")

echo "== a recreated terminal that will not go agent-free inside the budget"
FM_CONTROL_EXIT_WAIT=5 rig_control e1 recover-missing --note "rescue me"; echo "rc=$?"
echo "endpoint state now: $(probe fmlive:fm-e1)"
echo "the terminal does exist: $(rig_tmux list-windows -t fmlive -F '#{window_name}' | tr '\n' ' ')"
[ "$meta_before" = "$(md5 -q "$RIG/home/state/e1.meta")" ] && echo "durable record: byte-identical" || echo "durable record CHANGED"
[ "$brief_before" = "$(md5 -q "$RIG/home/data/e1/brief.md")" ] && echo "instructions: byte-identical (the progress note was rolled back)" || echo "instructions CHANGED"
echo "journal: $(grep -E '^(phase|rollback)=' "$RIG/home/state/e1.control-relaunch" | tr '\n' ' ')"
echo "no agent was launched into it: $(rig_tmux capture-pane -p -t fmlive:fm-e1 | grep -c claude) claude lines on screen"

echo
echo "== the refusal's own guidance: once the shell is idle, 'relaunch' brings the worker up"
until [ "$(probe fmlive:fm-e1)" = dead ]; do sleep 1; done
echo "endpoint state: $(probe fmlive:fm-e1)"
rig_control e1 relaunch --note "the terminal is back and idle; continue the same run"; echo "relaunch rc=$?"
echo "endpoint state: $(probe fmlive:fm-e1)"
echo "journal: $(grep -E '^phase=' "$RIG/home/state/e1.control-relaunch" | tail -1)"
