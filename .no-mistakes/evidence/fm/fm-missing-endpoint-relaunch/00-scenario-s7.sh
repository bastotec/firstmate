#!/usr/bin/env bash
set -u
. /tmp/fm-recover-live/rig.sh
POOL="$RIG/pool"
printf 'task=someone-elses-task\nhome=/tmp/other\n' > "$POOL/1/.fm-slot-owner"
echo "the slot's owner claim:"; sed 's/^/  /' "$POOL/1/.fm-slot-owner"
before=$(md5 -q "$RIG/home/state/g1.meta")
rig_control g1 recover-missing --note "rescue me"; echo "rc=$?"
[ "$before" = "$(md5 -q "$RIG/home/state/g1.meta")" ] && echo "durable record: byte-identical" || echo "CHANGED!"
echo "the other task's claim is untouched:"; sed 's/^/  /' "$POOL/1/.fm-slot-owner"
echo "no terminal was created for g1: $(rig_tmux list-windows -t fmlive -F '#{window_name}' | tr '\n' ' ')"

echo
echo "#### H. the task's OWN claim on its own slot recovers, claim untouched ####"
printf 'task=g1\nhome=%s\n' "$POOL/1/checkout" > "$POOL/1/.fm-slot-owner"
rig_control g1 recover-missing --note "rescue me on my own slot"; echo "rc=$?"
echo "claim after recovery:"; sed 's/^/  /' "$POOL/1/.fm-slot-owner"
echo "endpoint state: $(rig_env bash -c '. "$0"/bin/fm-backend.sh; fm_backend_source tmux; fm_backend_agent_state tmux fmlive:fm-g1' "$ROOT")"
