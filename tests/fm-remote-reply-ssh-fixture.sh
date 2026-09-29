#!/usr/bin/env bash
# Opt-in transport fixture for tests/fm-remote-reply.test.sh, not a standalone rig.
# Requires FM_REMOTE_REPLY_SSH_HOST and FM_REMOTE_REPLY_SSH_TREE naming an
# explicitly authorized ABSENT disposable remote tree under /tmp/fm-procevent-live-*.
# No credential, permission, shared service, or production record is changed.
# The remote scripts are byte-identical copies; a bash environment wrapper only
# confines their ephemeral staging after the worker's env -i clears TMPDIR.
# Both generations run through real OpenSSH, fm-on, entrypoint, and job worker.
# Cleanup stops only this tree's worker and runners, inventories the exact tree,
# removes it, and proves absence on success and failure alike.

set -eu
SSH_HOST=${FM_REMOTE_REPLY_SSH_HOST:?explicit SSH host is required}
SSH_TREE=${FM_REMOTE_REPLY_SSH_TREE:?explicit authorized remote tree is required}
case "$SSH_HOST" in ''|-*|*[!A-Za-z0-9._-]*) fail "unsafe SSH host" ;; esac
case "$SSH_TREE" in /tmp/fm-procevent-live-*) ;; *) fail "remote tree is not a dedicated live-test tree" ;; esac
case "${SSH_TREE#/tmp/}" in *[!A-Za-z0-9._-]*) fail "unsafe remote tree" ;; esac
SSH_REAL=$(command -v ssh) || fail "OpenSSH is required"
SSH_OPTIONS=(-o BatchMode=yes -o ConnectTimeout=10 -o ForwardAgent=no -o ClearAllForwardings=yes -o 'SendEnv=-*' -o ControlMaster=no -o ControlPath=none)
ssh_fixture() { "$SSH_REAL" "${SSH_OPTIONS[@]}" -- "$SSH_HOST" "umask 077; $*"; }

TMP_ROOT=$(fm_test_tmproot fm-remote-reply-ssh)
PARENT="$TMP_ROOT/parent"
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$CLAIMS" "$TMP_ROOT/pack/bin"
REMOTE_CREATED=0
ssh_cleanup() {
  local rc=$? cleanup_rc=0
  trap - EXIT INT TERM
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || cleanup_rc=1
  if [ "$REMOTE_CREATED" -eq 1 ]; then
    ssh_fixture "bash -s -- '$SSH_TREE'" <<'SH' || cleanup_rc=1
set -eu
r=$1
[ -d "$r" ] && [ ! -L "$r" ]
export FM_HOME="$r/home" FM_REMOTE_JOB_STATE_ROOT="$r/jobs" TMPDIR="$r/tmp"
. "$r/code/bin/fm-remote-job-lib.sh"
if [ -f "$r/jobs/worker.pid" ]; then
  pid=$(cat "$r/jobs/worker.pid")
  fm_remote_job_stop_worker_tree "$pid"
fi
printf '\nREMOTE INVENTORY BEFORE CLEANUP (only authorized tree):\n'
find "$r" -printf '%m %y %p\n' | sort
# No worker, entrypoint, or polling descendant may remain when code is removed.
remaining=$(ps -eo args= | awk -v p="$r/" 'index($0,p) && $0 !~ /awk -v p=/')
[ -z "$remaining" ] || { printf 'Synthetic processes remain:\n%s\n' "$remaining"; exit 1; }
rm -rf -- "$r"
[ ! -e "$r" ] && [ ! -L "$r" ]
printf 'REMOTE INVENTORY AFTER CLEANUP: %s absent; no synthetic processes remain.\n' "$r"
SH
  fi
  fm_test_cleanup
  [ "$cleanup_rc" -eq 0 ] || rc=1
  exit "$rc"
}
trap ssh_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Refuse an existing tree BEFORE any remote mutation; never adopt or clean it.
ssh_fixture "test ! -e '$SSH_TREE' && test ! -L '$SSH_TREE' && printf 'REMOTE INVENTORY BEFORE: $SSH_TREE absent\\n' && test \"\$(uname -s)\" = Linux && command -v bash git perl python3" \
  || fail "remote isolation or required Linux tools could not be established"
for file in AGENTS.md bin/fm-remote-entrypoint.sh bin/fm-remote-job-lib.sh \
  bin/fm-remote-job-worker.sh bin/fm-remote-delta-read.sh bin/fm-remote-file.sh bin/fm-wake-lib.sh; do
  cp "$ROOT/$file" "$TMP_ROOT/pack/$file"
done
cat > "$TMP_ROOT/pack/bin/bash" <<SH
#!/bin/bash
export TMPDIR='$SSH_TREE/tmp'
exec /bin/bash "\$@"
SH
chmod +x "$TMP_ROOT/pack/bin/bash"
# Atomic mkdir owns the tree; the EXIT trap owns it from this point onward.
ssh_fixture "umask 077; mkdir -m 700 -- '$SSH_TREE'" || fail "could not reserve synthetic tree"
REMOTE_CREATED=1
ssh_fixture "mkdir -p '$SSH_TREE/code' '$SSH_TREE/home/state' '$SSH_TREE/home/data/reply' '$SSH_TREE/tmp'; stat -c 'REMOTE ROOT MODE: %a' '$SSH_TREE'"
COPYFILE_DISABLE=1 tar -C "$TMP_ROOT/pack" -cf - . | ssh_fixture "tar -C '$SSH_TREE/code' -xf -"
ssh_fixture "env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C '$SSH_TREE/code' init -q && env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git -C '$SSH_TREE/code' add AGENTS.md bin && : > '$SSH_TREE/home/state/parent-replies.status' && printf '# Detailed remote answer\\n\\nThe build is green.\\n' > '$SSH_TREE/home/data/reply/report.md'"
# Prove the minimal product snapshot matches, independent of Git's new index.
for file in AGENTS.md bin/fm-remote-entrypoint.sh bin/fm-remote-job-lib.sh \
  bin/fm-remote-job-worker.sh bin/fm-remote-delta-read.sh bin/fm-remote-file.sh bin/fm-wake-lib.sh; do
  ssh_fixture "cat '$SSH_TREE/code/$file'" > "$TMP_ROOT/remote-copy"
  cmp "$ROOT/$file" "$TMP_ROOT/remote-copy" || fail "remote product snapshot differs: $file"
done
printf 'Remote product snapshot is byte-identical; only bash wrapper supplies isolated TMPDIR.\n'

# fm-on's fixed entrypoint name is routed to the private snapshot, not the
# account-wide install. This wrapper delegates every byte to real OpenSSH.
cat > "$TMP_ROOT/ssh-route" <<SH
#!/bin/bash
set -eu
while [ "\$#" -gt 0 ]; do
  case "\$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "\$1" = '$SSH_HOST' ] && [ "\$2" = fm-remote-entrypoint.sh ] || exit 91
shift 2
[ "\$#" -eq 4 ] || exit 92
for arg in "\$@"; do case "\$arg" in *[!A-Za-z0-9+/=]*) exit 93 ;; esac; done
exec '$SSH_REAL' -o BatchMode=yes -o ConnectTimeout=10 -o ForwardAgent=no \\
  -o ClearAllForwardings=yes -o 'SendEnv=-*' -o ControlMaster=no -o ControlPath=none \\
  -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -- '$SSH_HOST' \\
  "env TMPDIR='$SSH_TREE/tmp' FM_REMOTE_JOB_STATE_ROOT='$SSH_TREE/jobs' '$SSH_TREE/code/bin/fm-remote-entrypoint.sh' \$1 \$2 \$3 \$4"
SH
chmod +x "$TMP_ROOT/ssh-route"
cat > "$PARENT/data/secondmates.md" <<EOF
- synthetic - synthetic remote reply (host: $SSH_HOST; root: $SSH_TREE/code; home: $SSH_TREE/home; scope: test only; projects: none; added 2026-08-02)
EOF
export FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" FM_SSH_BIN="$TMP_ROOT/ssh-route"
export FM_ROOT_OVERRIDE="$ROOT" FM_REMOTE_REPLY_WAIT_SECONDS=30
fm_test_track_procevent_home "$PARENT"
ADAPTER="$ROOT/bin/fm-procevent-remote-reply.sh"
SID=$("$ADAPTER" source-id synthetic)
"$ADAPTER" arm synthetic
wait_path() {
  local path=$1
  for _ in $(seq 1 600); do [ -f "$path" ] && [ ! -L "$path" ] && return 0; sleep 0.1; done
  return 1
}

: > "$TMP_ROOT/expected-source"
FIRST_CLAIM=
for generation in 1 2; do
  printf '\nREAL SSH GENERATION %s\n' "$generation"
  recon=$("$ROOT/bin/fm-procevent.sh" reconcile)
  printf 'fm-procevent reconcile: %s\n' "$recon"
  assert_contains "$recon" 'started=1' "remote reply runner did not start"
  assert_contains "$recon" 'failed=0' "healthy real-SSH reply runner reported launch failure"
  wait_path "$CLAIMS/$SID.claim" || fail "real-SSH reply runner never claimed"
  printf 'Claim protocol:\n'; cat "$CLAIMS/$SID.claim"
  "$ROOT/bin/fm-procevent.sh" list
  current_claim=$(cat "$CLAIMS/$SID.claim")
  if [ "$generation" -eq 1 ]; then FIRST_CLAIM=$current_claim; else
    [ "$current_claim" != "$FIRST_CLAIM" ] || fail "re-arm reused the previous claim"
  fi
  # Observe the actual isolated worker executing the blocking delta reader
  # before the synthetic mate appends, not merely an SSH login smoke test.
  ssh_fixture "bash -s -- '$SSH_TREE'" <<'SH'
set -eu
r=$1
for _ in $(seq 1 300); do
  for job in "$r/jobs/jobs"/job-*; do
    [ -f "$job/state" ] || continue
    if [ "$(cat "$job/state")" = running ]; then
      printf 'Real remote job running: %s\n' "$job"
      printf 'Remote job argv: '; tr '\000' ' ' < "$job/argv"; printf '\n'
      ps -o pid=,ppid=,pgid=,args= -p "$(cat "$r/jobs/worker.pid")"
      exit 0
    fi
  done
  sleep 0.1
done
exit 1
SH
  line="done [corr=0123456789abcde$generation]: SSH generation $generation verified (data/reply/report.md)"
  printf '%s\n' "$line" >> "$TMP_ROOT/expected-source"
  printf '%s\n' "$line" | ssh_fixture "cat >> '$SSH_TREE/home/state/parent-replies.status'"
  wait_path "$PARENT/state/procevent-inbox/$SID.$generation.handled" || fail "real-SSH delta was not automatically applied and acknowledged"
  result="$PARENT/state/procevent-inbox/$SID.$generation.result"
  printf 'Captured delta protocol:\n'; cat "$result"
  assert_grep "$line" "$result" "capture lost the real-SSH reply"
  printf 'Mirrored status stream:\n'; cat "$PARENT/state/synthetic.status"
  assert_grep "SSH generation $generation verified (data/remote-secondmates/synthetic/data/reply/report.md)" "$PARENT/state/synthetic.status" "mirror did not rewrite the document pointer"
  printf 'Durable empty handled-marker contract:\n'
  ls -l "$PARENT/state/procevent-inbox/$SID.$generation.handled"
  printf 'Committed cursor protocol:\n'; cat "$PARENT/state/remote-replies/synthetic.cursor"
  assert_present "$PARENT/state/procevent/$SID.source" "capture did not re-arm the next source"
  printf 'Re-armed registration protocol:\n'; cat "$PARENT/state/procevent/$SID.source"
  "$ROOT/bin/fm-on.sh" synthetic fm-remote-file.sh get state/parent-replies.status 262144 > "$TMP_ROOT/source-after"
  cmp "$TMP_ROOT/expected-source" "$TMP_ROOT/source-after" || fail "capture consumed or rewrote the remote source"
  "$ROOT/bin/fm-on.sh" synthetic fm-remote-file.sh get data/reply/report.md 262144 > "$TMP_ROOT/document-after"
  cmp "$TMP_ROOT/document-after" "$PARENT/data/remote-secondmates/synthetic/data/reply/report.md" || fail "remote document mirror differs"
  offset=$(wc -c < "$TMP_ROOT/expected-source" | tr -d ' ')
  assert_grep "offset=$offset" "$PARENT/state/remote-replies/synthetic.cursor" "committed cursor did not cover the source"
  assert_absent "$PARENT/state/procevent/.${SID}.launch-failed" "a healthy remote runner opened a launch-failure episode"
  [ "$(grep -cF "SSH generation $generation verified" "$PARENT/state/synthetic.status")" -eq 1 ] || fail "reply mirrored more than once"
  printf 'Source bytes preserved, document byte-identical, acknowledgement durable, next registration present, launch-failure episode absent.\n'
  printf 'Idempotent handler confirmation after automatic application and re-arm:\n'
  "$ADAPTER" handle synthetic "$generation" "$result"
done
pass "real SSH claims, non-destructive captures, mirrors, acknowledges, and re-arms for a second reply"
