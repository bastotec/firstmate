#!/usr/bin/env bash
set -u
. /tmp/fm-recover-live/rig.sh
probe() { rig_env bash -c '. "$0"/bin/fm-backend.sh; fm_backend_source tmux; fm_backend_agent_state tmux '"$1" "$ROOT"; }
snap()  { md5 -q "$RIG/home/state/$1.meta"; md5 -q "$RIG/home/data/$1/brief.md"; }

RC_SLEEP=2 rig_reset

echo "################ A. a LIVE endpoint must refuse #################"
rig_task a1 fmlive
rig_tmux new-session -d -s fmlive -c "$RIG/wt-a1" -x 200 -y 50
rig_tmux new-window -d -t fmlive -n fm-a1 -c "$RIG/wt-a1"
rig_tmux send-keys -t fmlive:fm-a1 -l "claude"; rig_tmux send-keys -t fmlive:fm-a1 Enter
until [ "$(probe fmlive:fm-a1)" = alive ]; do sleep 0.5; done
echo "endpoint state: $(probe fmlive:fm-a1)  (a worker is at the keyboard)"
before=$(snap a1)
rig_control a1 recover-missing --note "rescue me"; echo "rc=$?"
[ "$before" = "$(snap a1)" ] && echo "durable record and instructions: byte-identical" || echo "CHANGED!"
echo "windows: $(rig_tmux list-windows -t fmlive -F '#{window_name}' | tr '\n' ' ')"

echo
echo "################ B. an AMBIGUOUS endpoint must refuse #################"
rig_task a2 fmlive
rig_tmux new-window -d -t fmlive -n fm-a2 -c "$RIG/wt-a2"
rig_tmux send-keys -t fmlive:fm-a2 -l "vim"; rig_tmux send-keys -t fmlive:fm-a2 Enter
until [ "$(probe fmlive:fm-a2)" = ambiguous ]; do sleep 0.5; done
echo "endpoint state: $(probe fmlive:fm-a2)  (a stranger's process holds the pane)"
before=$(snap a2)
rig_control a2 recover-missing --note "rescue me"; echo "rc=$?"
[ "$before" = "$(snap a2)" ] && echo "durable record and instructions: byte-identical" || echo "CHANGED!"

echo
echo "################ C. real uncommitted work must refuse #################"
rig_task a3 fmlive
echo "half-finished work" > "$RIG/wt-a3/notes.txt"
echo "worktree status: $(git -C "$RIG/wt-a3" status --porcelain | tr '\n' ' ')"
before=$(snap a3)
rig_control a3 recover-missing --note "rescue me"; echo "rc=$?"
[ "$before" = "$(snap a3)" ] && echo "durable record and instructions: byte-identical" || echo "CHANGED!"
echo "the uncommitted work is still there: $(cat "$RIG/wt-a3/notes.txt")"

echo
echo "################ D. the previous spawn's own leftovers still recover #################"
rig_task a4 fmlive
mkdir -p "$RIG/wt-a4/.claude"; echo '{}' > "$RIG/wt-a4/.claude/settings.local.json"
echo "worktree status: $(git -C "$RIG/wt-a4" status --porcelain | tr '\n' ' ')"
rig_control a4 recover-missing --note "only the previous worker's own leftovers are here"; echo "rc=$?"
echo "endpoint state: $(probe fmlive:fm-a4)"
echo "the leftovers were not cleaned: $(git -C "$RIG/wt-a4" status --porcelain | tr '\n' ' ')"

echo
echo "################ E. runtime-switch flags belong to relaunch #################"
rig_control a4 recover-missing --harness codex --note x; echo "rc=$?"
