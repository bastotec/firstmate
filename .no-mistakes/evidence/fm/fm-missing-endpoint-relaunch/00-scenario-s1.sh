#!/usr/bin/env bash
set -u
. /tmp/fm-recover-live/rig.sh
RC_SLEEP=${RC_SLEEP:-2} rig_reset
rig_task s1 fmlive || { echo "SETUP FAIL: task"; exit 1; }
WT="$RIG/wt-s1"

echo "== 1. stand the task up the way a spawn leaves it: real tmux session + task window running the agent"
rig_tmux new-session -d -s fmlive -c "$WT" -x 200 -y 50
rig_tmux new-window -d -t fmlive -n fm-s1 -c "$WT"
rig_tmux send-keys -t fmlive:fm-s1 -l "claude --resume"; rig_tmux send-keys -t fmlive:fm-s1 Enter
for _ in $(seq 1 60); do
  st=$(rig_env bash -c '. "$0"/bin/fm-backend.sh; fm_backend_source tmux; fm_backend_agent_state tmux fmlive:fm-s1' "$ROOT")
  [ "$st" = alive ] && break
  sleep 0.5
done
echo "endpoint state with the agent up: $st"

echo
echo "== 2. the terminal is closed out from under the task (window killed, session survives)"
rig_tmux kill-window -t fmlive:fm-s1
st=$(rig_env bash -c '. "$0"/bin/fm-backend.sh; fm_backend_source tmux; fm_backend_agent_state tmux fmlive:fm-s1' "$ROOT")
echo "endpoint state now: $st"
echo "windows left in the session: $(rig_tmux list-windows -t fmlive -F '#{window_name}' | tr '\n' ' ')"

echo
echo "== 4. the rescue, in ONE cold command"
date -u +%H:%M:%S
rig_control s1 recover-missing --note "the terminal was closed out from under it; continue the same run"
echo "recover-missing rc=$?"
date -u +%H:%M:%S

echo
echo "== 5. what the product looks like afterwards"
echo "windows: $(rig_tmux list-windows -t fmlive -F '#{window_name}' | tr '\n' ' ')"
st=$(rig_env bash -c '. "$0"/bin/fm-backend.sh; fm_backend_source tmux; fm_backend_agent_state tmux fmlive:fm-s1' "$ROOT")
echo "endpoint state: $st"
echo "pane cwd: $(rig_tmux display-message -p -t fmlive:fm-s1 '#{pane_current_path}')"
echo "--- durable record ---"; cat "$RIG/home/state/s1.meta"
echo "--- journal ---"; cat "$RIG/home/state/s1.control-relaunch" 2>/dev/null | sed -n '1,40p'
echo "--- instructions tail ---"; tail -20 "$RIG/home/data/s1/brief.md"
echo "--- worktree still the same checkout ---"; git -C "$WT" status --short --branch
echo "--- pane, as the captain would see it ---"
rig_tmux capture-pane -p -t fmlive:fm-s1 | tail -15
