#!/usr/bin/env bash
# Disposable, real-SSH scenario driver; no production registrations are used.
set -eu
ROOT=$PWD
LOCAL="$ROOT/.test-tmp/round4"
REMOTE=/tmp/fm-procevent-live-01M3Q2CVXNFM8FR64YHCHYYB7T
export FM_HOME="$LOCAL/parent" FM_PROCEVENT_CLAIM_ROOT="$LOCAL/claims"
export TMPDIR="$LOCAL/tmp" FM_REMOTE_REPLY_WAIT_SECONDS=60
export FM_SSH_BIN="$LOCAL/ssh-transport"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 -o ControlMaster=no -o ControlPath=none -o UpdateHostKeys=no)
CREATED=0
cleanup() {
  local rc=$?
  trap - EXIT
  printf '\nCLEANUP (scenario exit=%s)\n' "$rc"
  "$ROOT/bin/fm-procevent.sh" sweep-home || rc=1
  if [ "$CREATED" -eq 1 ]; then
    "${SSH[@]}" workload 'set -eu
p=/tmp/fm-procevent-live-01M3Q2CVXNFM8FR64YHCHYYB7T
printf "Remote inventory before cleanup:\n"
find "$p" -printf "%m %y %P\n" | sort
if test -f "$p/jobs/worker.pid"; then
  pid=$(<"$p/jobs/worker.pid")
  . "$p/code/bin/fm-remote-job-lib.sh"
  cmd=$(fm_remote_job_process_command "$pid" || true)
  case "$cmd" in *"$p/code/bin/fm-remote-job-worker.sh"*) fm_remote_job_stop_worker_tree "$pid" ;; "") ;; *) echo "worker identity mismatch; preserve fixture"; exit 1 ;; esac
fi
python3 - "$p" <<"PY"
import os, sys, time
p=sys.argv[1].encode()
for attempt in range(100):
    survivors=[]
    for pid in os.listdir("/proc"):
        if not pid.isdigit() or int(pid) in (os.getpid(), os.getppid()): continue
        try:
            argv=open("/proc/"+pid+"/cmdline","rb").read().split(b"\0")
        except OSError: continue
        if any(arg.startswith(p+b"/") for arg in argv): survivors.append((pid,argv))
    if not survivors: break
    time.sleep(.05)
assert not survivors, survivors
print("Synthetic worker/command processes: none")
PY
rm -rf -- "$p"
test ! -e "$p" && test ! -L "$p"
printf "After inventory: authorized tree absent\n"' || rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
mkdir -p "$FM_HOME/data" "$FM_HOME/state" "$FM_PROCEVENT_CLAIM_ROOT" "$TMPDIR" "$LOCAL/snapshot/bin"
printf 'HEAD='; git rev-parse HEAD
printf 'Real SSH preflight:\n'
"${SSH[@]}" workload 'set -eu; p=/tmp/fm-procevent-live-01M3Q2CVXNFM8FR64YHCHYYB7T; test ! -e "$p" && test ! -L "$p"; printf "Before inventory: authorized tree absent\n"; uname -s; id; for t in bash git python3 perl tar mktemp; do command -v "$t"; done'
# The minimal snapshot contains unmodified product executables and their libraries.
cp AGENTS.md "$LOCAL/snapshot/"
for file in fm-remote-entrypoint.sh fm-remote-job-lib.sh fm-remote-job-worker.sh fm-remote-delta-read.sh fm-remote-file.sh fm-wake-lib.sh; do
  cp "bin/$file" "$LOCAL/snapshot/bin/"
done
# The worker deliberately strips TMPDIR from child environments. This fixture-only
# mktemp shim redirects staging templates, not transport or product behavior.
cat > "$LOCAL/snapshot/bin/mktemp" <<'SH'
#!/bin/bash
set -eu
p=/tmp/fm-procevent-live-01M3Q2CVXNFM8FR64YHCHYYB7T
args=()
for arg in "$@"; do
  case "$arg" in /tmp/*) arg="$p/tmp/${arg##*/}" ;; esac
  args+=("$arg")
done
exec /usr/bin/mktemp "${args[@]}"
SH
chmod +x "$LOCAL/snapshot/bin/mktemp"
# Only this exact synthetic remote tree is created. No installed entrypoint,
# account queue, SSH config, credential, or production mate is touched.
"${SSH[@]}" workload 'set -eu; p=/tmp/fm-procevent-live-01M3Q2CVXNFM8FR64YHCHYYB7T; umask 077; mkdir -m 700 "$p"; mkdir "$p/code" "$p/tmp" "$p/jobs" "$p/home"; mkdir -p "$p/home/state" "$p/home/data/reply"; stat -c "fixture mode=%a" "$p"'
CREATED=1
tar -C "$LOCAL/snapshot" -cf - AGENTS.md bin | "${SSH[@]}" workload 'set -eu; p=/tmp/fm-procevent-live-01M3Q2CVXNFM8FR64YHCHYYB7T; tar -C "$p/code" -xf -; git -c init.templateDir= init -q "$p/code"; git -C "$p/code" add AGENTS.md bin; : > "$p/home/state/parent-replies.status"; printf "# Synthetic remote answer\n\nBuild verified through real SSH.\n" > "$p/home/data/reply/report.md"; printf "Minimal snapshot hashes:\n"; sha256sum "$p"/code/bin/fm-*.sh'
cat > "$FM_HOME/data/secondmates.md" <<EOF
- synthetic - isolated reply validation (host: workload; root: $REMOTE/code; home: $REMOTE/home; scope: synthetic validation; projects: none; added 2026-08-02)
EOF
# fm-on still supplies the real encoded protocol. Replace only entrypoint location
# and test isolation environment before handing it to the actual OpenSSH binary.
cat > "$FM_SSH_BIN" <<'SH'
#!/usr/bin/env bash
set -eu
opts=()
while [ "$#" -gt 0 ]; do
  case "$1" in -o) opts+=("$1" "$2"); shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "$1" = workload ] && [ "$2" = fm-remote-entrypoint.sh ] || exit 91
shift 2
p=/tmp/fm-procevent-live-01M3Q2CVXNFM8FR64YHCHYYB7T
printf 'REAL SSH protocol=%s root64=%s home64=%s argv64=%s\n' "$@" >&2
exec /usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=10 -o ControlMaster=no -o ControlPath=none -o UpdateHostKeys=no "${opts[@]}" -- workload env "TMPDIR=$p/tmp" "PATH=$p/code/bin:/usr/bin:/bin" "FM_REMOTE_JOB_STATE_ROOT=$p/jobs" "$p/code/bin/fm-remote-entrypoint.sh" "$@"
SH
chmod +x "$FM_SSH_BIN"
ADAPTER="$ROOT/bin/fm-procevent-remote-reply.sh"
SID=$($ADAPTER source-id synthetic)
$ADAPTER arm synthetic
for gen in 1 2; do
  printf '\nGENERATION %s: launch handshake\n' "$gen"
  "$ROOT/bin/fm-procevent.sh" reconcile
  "$ROOT/bin/fm-procevent.sh" list
  test -f "$FM_PROCEVENT_CLAIM_ROOT/$SID.claim"
  printf 'Durable claim protocol:\n'; cat "$FM_PROCEVENT_CLAIM_ROOT/$SID.claim"
  # Prove the real remote worker is running a blocking delta read before append.
  "${SSH[@]}" workload 'set -eu; p=/tmp/fm-procevent-live-01M3Q2CVXNFM8FR64YHCHYYB7T
found=0
for attempt in $(seq 1 200); do
  for j in "$p/jobs/jobs"/job-*; do
    test -f "$j/state" || continue
    if test "$(<"$j/state")" = running; then
      printf "Remote running job %s\n" "$j"; cat "$j/state" "$j/home" "$j/root"; tr "\000" "\n" < "$j/argv"; found=1; break
    fi
  done
  test "$found" -eq 0 || break
  sleep .1
done
test "$found" -eq 1
printf "Remote worker PID: "; cat "$p/jobs/worker.pid"'
  if [ "$gen" -eq 1 ]; then
    "${SSH[@]}" workload 'p=/tmp/fm-procevent-live-01M3Q2CVXNFM8FR64YHCHYYB7T; printf "done [corr=0123456789abcdef]: build verified (data/reply/report.md)\n" >> "$p/home/state/parent-replies.status"; sha256sum "$p/home/state/parent-replies.status"' > "$LOCAL/source-expected"
  else
    "${SSH[@]}" workload 'p=/tmp/fm-procevent-live-01M3Q2CVXNFM8FR64YHCHYYB7T; printf "working [corr=1111111111111111]: second real SSH generation\n" >> "$p/home/state/parent-replies.status"; sha256sum "$p/home/state/parent-replies.status"' > "$LOCAL/source-expected"
  fi
  handled="$FM_HOME/state/procevent-inbox/$SID.$gen.handled"
  for attempt in $(seq 1 300); do
    [ ! -f "$handled" ] || break
    sleep .1
  done
  test -f "$handled"
  result="$FM_HOME/state/procevent-inbox/$SID.$gen.result"
  printf 'Captured delta protocol:\n'; cat "$result"
  printf 'Mirrored status stream:\n'; cat "$FM_HOME/state/synthetic.status"
  printf 'Committed cursor:\n'; cat "$FM_HOME/state/remote-replies/synthetic.cursor"
  printf 'Handled acknowledgement:\n'; ls -l "$handled"; cat "$handled"
  printf 'Next re-armed source registration:\n'; cat "$FM_HOME/state/procevent/$SID.source"
  "${SSH[@]}" workload 'p=/tmp/fm-procevent-live-01M3Q2CVXNFM8FR64YHCHYYB7T; sha256sum "$p/home/state/parent-replies.status"' > "$LOCAL/source-observed"
  cmp "$LOCAL/source-expected" "$LOCAL/source-observed"
  printf 'Non-destructive source hash unchanged:\n'; cat "$LOCAL/source-observed"
  "$ROOT/bin/fm-procevent.sh" handled "$SID" "$gen" | grep -F "already-handled: $SID $gen"
  if [ -f "$FM_HOME/state/.wake-queue" ]; then
    ! grep -F "procevent remote-reply $SID $gen" "$FM_HOME/state/.wake-queue"
    ! grep -F 'launch-failed' "$FM_HOME/state/.wake-queue"
  fi
  "$ADAPTER" handle synthetic "$gen" "$result"
  # Wait for the original owner to release before the second reconciliation.
  for attempt in $(seq 1 100); do
    [ -e "$FM_PROCEVENT_CLAIM_ROOT/$SID.claim" ] || break
    sleep .1
  done
  test ! -e "$FM_PROCEVENT_CLAIM_ROOT/$SID.claim"
done
"${SSH[@]}" workload 'p=/tmp/fm-procevent-live-01M3Q2CVXNFM8FR64YHCHYYB7T; cat "$p/home/data/reply/report.md"' > "$LOCAL/remote-document"
cmp "$LOCAL/remote-document" "$FM_HOME/data/remote-secondmates/synthetic/data/reply/report.md"
grep -F 'data/remote-secondmates/synthetic/data/reply/report.md' "$FM_HOME/state/synthetic.status"
[ "$(grep -cF 'build verified' "$FM_HOME/state/synthetic.status")" -eq 1 ]
[ "$(grep -cF 'second real SSH generation' "$FM_HOME/state/synthetic.status")" -eq 1 ]
"${SSH[@]}" workload 'p=/tmp/fm-procevent-live-01M3Q2CVXNFM8FR64YHCHYYB7T; wc -c < "$p/home/state/parent-replies.status"; sha256sum "$p/home/state/parent-replies.status"' > "$LOCAL/source-final"
python3 - "$FM_HOME/state/remote-replies/synthetic.cursor" "$LOCAL/source-final" <<'PY'
import sys
cursor=dict(line.strip().split('=',1) for line in open(sys.argv[1]))
lines=open(sys.argv[2]).readlines()
assert int(cursor['offset'])==int(lines[0])
assert cursor['prefix_sha256']==lines[1].split()[0]
print('PASS: committed cursor equals remote source byte count and SHA-256')
PY
printf '\nPASS: real SSH claim, capture, mirror, document fetch, acknowledgement, non-destructive retry, and second-generation re-arm\n'
