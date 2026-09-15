#!/usr/bin/env bash
set -u
. /tmp/fm-recover-live/rig.sh
RC_SLEEP=${RC_SLEEP:-2} rig_reset
rig_task s2 oes-demo || { echo "SETUP FAIL"; exit 1; }
WT="$RIG/wt-s2"
probe() { rig_env bash -c '. "$0"/bin/fm-backend.sh; fm_backend_source tmux; fm_backend_agent_state tmux '"$1" "$ROOT"; }

echo "== the firstmate-account-slot-routing shape: the task records a session that no longer exists"
grep '^window=' "$RIG/home/state/s2.meta"
echo "tmux server state: $(rig_tmux ls 2>&1 | tr '\n' ' ')"
echo "endpoint state: $(probe oes-demo:fm-s2)"

echo
echo "== the rescue, in ONE cold command (no tmux server running at all)"
rig_control s2 recover-missing --note "the whole session was gone; continue the same run"
echo "recover-missing rc=$?"

echo
echo "== afterwards"
echo "sessions: $(rig_tmux ls 2>&1 | tr '\n' ' ')"
echo "windows in oes-demo: $(rig_tmux list-windows -t oes-demo -F '#{window_name}' | tr '\n' ' ')"
echo "endpoint state: $(probe oes-demo:fm-s2)"
echo "pane cwd: $(rig_tmux display-message -p -t oes-demo:fm-s2 '#{pane_current_path}')"
echo "recorded window still: $(grep '^window=' "$RIG/home/state/s2.meta")"
echo "recorded worktree still: $(grep '^worktree=' "$RIG/home/state/s2.meta")"
echo "journal phase: $(grep '^phase=' "$RIG/home/state/s2.control-relaunch" | tail -1)"
