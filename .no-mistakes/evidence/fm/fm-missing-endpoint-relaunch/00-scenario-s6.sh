#!/usr/bin/env bash
set -u
. /tmp/fm-recover-live/rig.sh
probe() { rig_env bash -c '. "$0"/bin/fm-backend.sh; fm_backend_source tmux; fm_backend_agent_state tmux '"$1" "$ROOT"; }
RC_SLEEP=2 rig_reset
rig_tmux new-session -d -s fmlive -c "$RIG" -x 200 -y 50

echo "#### F. a secondmate recovery continues the RECORDED runtime, not a changed configured pin ####"
mkdir -p "$RIG/home/config" "$RIG/home/data/sm1"
printf 'codex some-model high\n' > "$RIG/home/config/secondmate-harness"
echo "the configured pin now names: $(cat "$RIG/home/config/secondmate-harness")"
printf '# secondmate brief\n' > "$RIG/home/data/sm1/brief.md"
SM="$RIG/smhome"
( set -e
  git init --quiet "$RIG/proj-sm1"; cd "$RIG/proj-sm1"
  git config user.email t@e.com; git config user.name T
  echo hi > README.md; git add -A; git commit --quiet -m init
  git worktree add --quiet -b sm-branch "$SM"
  mkdir -p "$SM/state" "$SM/data" "$SM/bin"
  printf 'sm1\n' > "$SM/.fm-secondmate-home"
  printf '# agents\n' > "$SM/AGENTS.md"
  cd "$SM"; git add -A; git commit --quiet -m "secondmate home" ) >/dev/null
{ echo "window=fmlive:fm-sm1"; echo "endpoint_task_id=sm1"; echo "worktree=$SM"
  echo "project=$SM"; echo "harness=claude"; echo "kind=secondmate"; echo "mode=secondmate"
  echo "yolo=off"; echo "model=opus"; echo "effort=xhigh"; echo "home=$SM"; } > "$RIG/home/state/sm1.meta"
echo "the task's own record says: harness=claude model=opus effort=xhigh"
rig_control sm1 recover-missing; echo "rc=$?"
echo "journal runtime: $(grep -E '^to_(harness|model|effort)=' "$RIG/home/state/sm1.control-relaunch" | tr '\n' ' ')"
echo "endpoint state: $(probe fmlive:fm-sm1)"

echo
echo "#### G. a pool slot claimed by ANOTHER task refuses rather than tangling ownership ####"
POOL="$RIG/pool"; mkdir -p "$POOL/1"; printf '{}\n' > "$POOL/treehouse-state.json"
rig_task g1 fmlive "$POOL/1/checkout"
printf 'someone-elses-task\n' > "$POOL/1/.fm-slot-owner"
echo "the slot's owner claim: $(cat "$POOL/1/.fm-slot-owner")"
before=$(md5 -q "$RIG/home/state/g1.meta")
rig_control g1 recover-missing --note "rescue me"; echo "rc=$?"
[ "$before" = "$(md5 -q "$RIG/home/state/g1.meta")" ] && echo "durable record: byte-identical" || echo "CHANGED!"
echo "the other task's claim is untouched: $(cat "$POOL/1/.fm-slot-owner")"
echo "no terminal was created: $(rig_tmux list-windows -t fmlive -F '#{window_name}' | tr '\n' ' ')"
