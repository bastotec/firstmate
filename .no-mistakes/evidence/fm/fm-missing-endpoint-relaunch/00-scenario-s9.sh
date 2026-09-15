#!/usr/bin/env bash
set -u
. /tmp/fm-recover-live/rig.sh
probe() { rig_env bash -c '. "$0"/bin/fm-backend.sh; fm_backend_source tmux; fm_backend_agent_state tmux '"$1" "$ROOT"; }
RC_SLEEP=3 rig_reset
# A genuinely heavy login shell, the round-1 failure condition: nvm-style node,
# a prompt git call and a sleep, all before the shell reaches its prompt.
sed -i '' 's/^export FM_RIG_HEAVY_RC=.*/export FM_RIG_HEAVY_RC=1/' "$RIG/user-home/.zshenv"
grep -n 'FM_RIG_HEAVY_RC' "$RIG/user-home/.zshenv"
rig_task h1 fmlive
rig_tmux new-session -d -s fmlive -c "$RIG" -x 160 -y 40
echo "endpoint before: $(probe fmlive:fm-h1)"
start=$(date +%s)
rig_control h1 recover-missing --note "the terminal was closed out from under it; continue the same run"
echo "recover-missing rc=$? (took $(( $(date +%s) - start ))s, default 30s settle budget)"
echo "endpoint after: $(probe fmlive:fm-h1)"
echo
echo "== the recovered terminal, as the captain sees it on screen =="
rig_tmux capture-pane -p -S -20 -t fmlive:fm-h1
