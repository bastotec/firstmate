#!/usr/bin/env bash
set -u
. /tmp/fm-recover-live/rig.sh
probe() { rig_env bash -c '. "$0"/bin/fm-backend.sh; fm_backend_source tmux; fm_backend_agent_state tmux '"$1" "$ROOT"; }
RC_SLEEP=2 rig_reset
rig_task i1 fmlive
rig_tmux new-session -d -s fmlive -c "$RIG" -x 200 -y 50

echo "== the motivating shape: a steering message is still pending in the task's inbox"
mkdir -p "$RIG/home/state/i1.inbox/handled"
printf 'from=captain\nRefocus on the proxy handshake before anything else.\n' > "$RIG/home/state/i1.inbox/016.msg"
echo "inbox before: $(ls "$RIG/home/state/i1.inbox" | tr '\n' ' ')"
head_before=$(git -C "$RIG/wt-i1" rev-parse HEAD)
echo "local copy HEAD before: $head_before"

rig_control i1 recover-missing --note "the terminal went missing; the no-mistakes run is still parked, continue it"
echo "recover-missing rc=$?"

echo
echo "== after the rescue"
echo "inbox after: $(ls "$RIG/home/state/i1.inbox" | tr '\n' ' ')"
echo "handled/ is still empty: [$(ls "$RIG/home/state/i1.inbox/handled" | tr '\n' ' ')]"
echo "the pending steer is byte-identical:"; sed 's/^/  /' "$RIG/home/state/i1.inbox/016.msg"
echo "local copy HEAD after: $(git -C "$RIG/wt-i1" rev-parse HEAD)  (branch $(git -C "$RIG/wt-i1" rev-parse --abbrev-ref HEAD))"
echo "endpoint: $(probe fmlive:fm-i1)"
echo "the instructions the replacement reads now point at that inbox:"
grep -n "instruction inbox" -A 3 "$RIG/home/data/i1/brief.md" | sed 's/^/  /'

echo
echo "== the same cold one-command rescue, repeated (round 1 measured 9/9 failures here)"
for n in 1 2 3 4 5; do
  rig_tmux kill-window -t fmlive:fm-i1 2>/dev/null
  st=$(probe fmlive:fm-i1)
  out=$(rig_control i1 recover-missing --note "cold rescue run $n" 2>&1 | grep -E '^(recovered|error)')
  echo "run $n: endpoint before=$st -> $out -> endpoint after=$(probe fmlive:fm-i1)"
done
