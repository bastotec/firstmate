#!/usr/bin/env bash
set -u
. /tmp/fm-recover-live/rig.sh
probe() { rig_env bash -c '. "$0"/bin/fm-backend.sh; fm_backend_source tmux; fm_backend_agent_state tmux '"$1" "$ROOT"; }
snap()  { md5 -q "$RIG/home/state/$1.meta"; md5 -q "$RIG/home/data/$1/brief.md"; }
RC_SLEEP=2 rig_reset
rig_tmux new-session -d -s fmlive -c "$RIG" -x 200 -y 50

echo "#### D. a worktree holding only the previous worker's own spawn leftovers still recovers ####"
rig_task d1 fmlive
mkdir -p "$RIG/wt-d1/.claude"; echo '{}' > "$RIG/wt-d1/.claude/agents.json"
printf '' > "$RIG/wt-d1/.fm-grok-turnend"
echo "status as the product reads it: $(rig_env git -C "$RIG/wt-d1" status --porcelain | tr '\n' ' ')"
rig_control d1 recover-missing --note "only the previous worker's own leftovers are here"; echo "rc=$?"
echo "endpoint state: $(probe fmlive:fm-d1)"
echo "leftovers untouched: $(rig_env git -C "$RIG/wt-d1" status --porcelain | tr '\n' ' ')"

echo
echo "#### D2. the same worktree plus ONE real untracked source file must refuse ####"
rig_task d2 fmlive
mkdir -p "$RIG/wt-d2/.claude"; echo '{}' > "$RIG/wt-d2/.claude/agents.json"
echo 'half-finished work' > "$RIG/wt-d2/feature.py"
echo "status as the product reads it: $(rig_env git -C "$RIG/wt-d2" status --porcelain | tr '\n' ' ')"
before=$(snap d2)
rig_control d2 recover-missing --note "rescue me"; echo "rc=$?"
[ "$before" = "$(snap d2)" ] && echo "durable record and instructions: byte-identical" || echo "CHANGED!"
echo "the unsaved work is still there: $(cat "$RIG/wt-d2/feature.py")"
echo "no terminal was created: $(rig_tmux list-windows -t fmlive -F '#{window_name}' | tr '\n' ' ')"
