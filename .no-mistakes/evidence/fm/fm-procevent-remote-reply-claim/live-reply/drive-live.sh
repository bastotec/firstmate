#!/usr/bin/env bash
set -euo pipefail
ROOT=/Users/bastotecnologia/.no-mistakes/worktrees/5a1fd3284f12/01M3Q2CVXNFM8FR64YHCHYYB7T
D=$ROOT/.no-mistakes/live-reply-isolation
R=$D/runtime
export TMPDIR=$R/tmp FM_PROCEVENT_CLAIM_ROOT=$R/claims
mkdir -p "$FM_PROCEVENT_CLAIM_ROOT" "$R/contended/state" "$R/uncertain/state" "$R/failure/state" "$R/parent/data" "$R/parent/state" "$R/remote/data/reply" "$R/remote/state"
pe() { FM_HOME="$R/$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }
wait_path() {
  local p=$1
  for ((i=0;i<600;i++)); do [ -e "$p" ] && return 0; sleep 0.05; done
  echo "FAIL waiting for $p" >&2; return 1
}
contains() { [[ "$1" == *"$2"* ]] || { echo "FAIL missing $2 in $1" >&2; return 1; }; }
hold() {
  FM_HOME="$R/contended" bash -c '
    . "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-procevent-lib.sh"
    fm_procevent_source_lock_acquire "$2" || exit 1
    trap "fm_procevent_source_lock_release \"$2\"" EXIT
    printf "ready\n" > "$3"
    for ((i=0;i<1200;i++)); do [ -e "$4" ] && exit 0; sleep 0.05; done
    exit 1
  ' _ "$ROOT" "$1" "$R/$1.ready" "$R/$1.release" &
  HOLDER=$!
}
cleanup() {
  touch "$R/aa-live.release" "$R/zz-live.release"
  for h in contended uncertain failure parent; do pe "$h" sweep-home || true; done
  if [ -f "$R/jobs/worker.pid" ]; then
    . "$ROOT/bin/fm-remote-job-lib.sh"
    fm_remote_job_stop_worker_tree "$(< "$R/jobs/worker.pid")" || true
  fi
}
trap cleanup EXIT
if [ "${1:-all}" != remote ]; then
printf 'SCENARIO 1: real reconcile, sleeping long-poll processes, held source locks\n'
pe contended register lavish aa-live -- /bin/sleep 120
pe contended register lavish zz-live -- /bin/sleep 120
stamp=$(FM_HOME="$R/contended" bash -c '
  . "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-procevent-lib.sh"
  identity=$(fm_pr_file_identity "$2/state/procevent/aa-live.source")
  fm_procevent_launch_floor_stamp_path "$2/state" aa-live "$identity"
' _ "$ROOT" "$R/contended")
perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e 'print clock_gettime(CLOCK_MONOTONIC), "\n"' > "$stamp"
hold zz-live; ZZ=$HOLDER
wait_path "$R/zz-live.ready"
FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=4 FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=20 pe contended reconcile > "$R/contention.out" 2>&1 &
REC=$!
wait_path "$FM_PROCEVENT_CLAIM_ROOT/aa-live.claim"
hold aa-live; AA=$HOLDER
wait_path "$R/aa-live.ready"
touch "$R/zz-live.release"
wait "$REC"
out=$(< "$R/contention.out"); printf '%s\n' "$out"
contains "$out" 'started=2'; contains "$out" 'failed=0'
[ ! -e "$R/contended/state/procevent/.aa-live.launch-failed" ]
# Confirm the claim is still live while the holder owns the lock.
FM_HOME="$R/contended" bash -c '
  . "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-procevent-lib.sh"
  fm_procevent_claim_state_observed aa-live
  printf "observed-live pid=%s\n" "$FM_PROCEVENT_CLAIM_PID"
  kill -0 "$FM_PROCEVENT_CLAIM_PID"
' _ "$ROOT"
touch "$R/aa-live.release"; wait "$AA"; wait "$ZZ"
out=$(pe contended list); printf '%s\n' "$out"; contains "$out" 'live'
pe contended sweep-home
printf 'PASS scenario 1\n'

printf 'SCENARIO 2: unreadable serialized claim, no guessed ownership\n'
pe uncertain register lavish unreadable-live -- /bin/sleep 120
printf 'torn\n' > "$FM_PROCEVENT_CLAIM_ROOT/unreadable-live.claim"
chmod 600 "$FM_PROCEVENT_CLAIM_ROOT/unreadable-live.claim"
FM_HOME="$R/uncertain" bash -c '
  . "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-procevent-lib.sh"
  fm_procevent_claim_state_observed unreadable-live; rc=$?
  printf "lock-free observation rc=%s\n" "$rc"
  [ "$rc" -eq 2 ]
' _ "$ROOT"
out=$(pe uncertain reconcile); printf '%s\n' "$out"
contains "$out" 'started=0'; contains "$out" 'uncertain=1'; contains "$out" 'failed=0'
out=$(pe uncertain list); printf '%s\n' "$out"; contains "$out" uncertain
[ "$(< "$FM_PROCEVENT_CLAIM_ROOT/unreadable-live.claim")" = torn ]
rm "$FM_PROCEVENT_CLAIM_ROOT/unreadable-live.claim"
pe uncertain sweep-home
printf 'PASS scenario 2\n'

printf 'SCENARIO 3: unstartable registration, failure cleanup, repair\n'
pe failure register lavish broken-live -- /bin/sleep 120
source=$R/failure/state/procevent/broken-live.source
awk '/^argv:$/ { print; exit } { print }' "$source" > "$source.tmp"
mv "$source.tmp" "$source"; chmod 600 "$source"
rc=0; out=$(FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=2 pe failure reconcile) || rc=$?
printf 'rc=%s %s\n' "$rc" "$out"
[ "$rc" -ne 0 ]; contains "$out" 'failed=1'
[ ! -e "$FM_PROCEVENT_CLAIM_ROOT/broken-live.claim" ]
[ ! -e "$R/failure/state/procevent/broken-live.runner" ]
[ -z "$(find "$R/failure/state/procevent" -name '.broken-live.*.output' -print)" ]
[ -e "$R/failure/state/procevent/.broken-live.launch-failed" ]
cat "$R/failure/state/.wake-queue"
pe failure register lavish broken-live -- /bin/sleep 120
out=$(pe failure reconcile); printf '%s\n' "$out"; contains "$out" started=1; contains "$out" failed=0
[ ! -e "$R/failure/state/procevent/.broken-live.launch-failed" ]
pe failure list
pe failure sweep-home
printf 'PASS scenario 3\n'
fi

printf 'SCENARIO 4: dedicated synthetic mate via real authenticated OpenSSH\n'
printf -- '- synthetic - live reply validation (host: live-synthetic; root: %s; home: %s; scope: synthetic only; projects: none; added 2026-08-13)\n' "$D/code" "$R/remote" > "$R/parent/data/secondmates.md"
printf '# Synthetic answer\n\nLive SSH transport verified.\n' > "$R/remote/data/reply/report.md"
: > "$R/remote/state/parent-replies.status"
export FM_SSH_BIN=$D/ssh-transport.sh FM_REMOTE_REPLY_WAIT_SECONDS=30
remote() { FM_HOME="$R/parent" "$@"; }
remote "$ROOT/bin/fm-procevent-remote-reply.sh" arm synthetic
out=$(remote "$ROOT/bin/fm-procevent.sh" reconcile); printf '%s\n' "$out"; contains "$out" started=1; contains "$out" failed=0
wait_path "$FM_PROCEVENT_CLAIM_ROOT/remote-reply-synthetic.claim"
cat "$FM_PROCEVENT_CLAIM_ROOT/remote-reply-synthetic.claim"
PORT=$(< "$D/port")
ssh_remote() {
  /usr/bin/ssh -F /dev/null -p "$PORT" -i "$D/client-key" -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$D/known_hosts" -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no -o ControlMaster=no -o ControlPath=none -- bastotecnologia@127.0.0.1 "$@"
}
# A separate remote SSH session appends the mate's reply, while fm-on polls via
# the real entrypoint, job worker, and cursor-anchored delta executable.
ssh_remote "printf '%s\\n' 'done [corr=0123456789abcdef]: live first reply (data/reply/report.md)' >> '$R/remote/state/parent-replies.status'"
wait_path "$R/parent/state/procevent-inbox/remote-reply-synthetic.1.handled"
cat "$R/parent/state/procevent-inbox/remote-reply-synthetic.1.result"
cat "$R/parent/state/remote-replies/synthetic.cursor"
cat "$R/parent/state/synthetic.status"
cmp "$R/remote/data/reply/report.md" "$R/parent/data/remote-secondmates/synthetic/data/reply/report.md"
[ "$(wc -l < "$R/remote/state/parent-replies.status" | tr -d ' ')" -eq 1 ]
[ -e "$R/parent/state/procevent/remote-reply-synthetic.source" ]
[ "$(wc -c < "$R/remote/state/parent-replies.status" | tr -d ' ')" = "$(awk -F= '$1=="offset" {print $2}' "$R/parent/state/remote-replies/synthetic.cursor")" ]
# Autohandle publishes its marker before the capturing runner releases the
# previous claim. Wait for release before the next watcher-equivalent cycle.
for ((i=0;i<600;i++)); do
  [ ! -e "$FM_PROCEVENT_CLAIM_ROOT/remote-reply-synthetic.claim" ] && break
  sleep 0.05
done
[ ! -e "$FM_PROCEVENT_CLAIM_ROOT/remote-reply-synthetic.claim" ]
out=$(remote "$ROOT/bin/fm-procevent.sh" reconcile); printf '%s\n' "$out"; contains "$out" started=1; contains "$out" failed=0
wait_path "$FM_PROCEVENT_CLAIM_ROOT/remote-reply-synthetic.claim"
ssh_remote "printf '%s\\n' 'done [corr=fedcba9876543210]: live second reply' >> '$R/remote/state/parent-replies.status'"
wait_path "$R/parent/state/procevent-inbox/remote-reply-synthetic.2.handled"
cat "$R/parent/state/procevent-inbox/remote-reply-synthetic.2.result"
cat "$R/parent/state/synthetic.status"
[ "$(wc -l < "$R/remote/state/parent-replies.status" | tr -d ' ')" -eq 2 ]
[ "$(wc -l < "$R/parent/state/synthetic.status" | tr -d ' ')" -eq 2 ]
[ -e "$R/parent/state/procevent/remote-reply-synthetic.source" ]
[ "$(wc -c < "$R/remote/state/parent-replies.status" | tr -d ' ')" = "$(awk -F= '$1=="offset" {print $2}' "$R/parent/state/remote-replies/synthetic.cursor")" ]
[ ! -e "$R/parent/state/procevent/.remote-reply-synthetic.launch-failed" ]
printf 'PASS scenario 4\n'
printf 'PASS requested isolated live scenarios\n'
