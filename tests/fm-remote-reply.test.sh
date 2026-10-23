#!/usr/bin/env bash
# End-to-end remote reply relay through fm-on and the process-event runner.
# FM_REMOTE_REPLY_REAL_SSH=1 selects the opt-in real-SSH fixture; its header
# owns the required host and explicitly authorized disposable remote tree.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset FM_REMOTE_JOB_ACTIVE

if [ "${FM_REMOTE_REPLY_REAL_SSH:-0}" = 1 ]; then
  # shellcheck source=tests/fm-remote-reply-ssh-fixture.sh
  . "$(dirname "${BASH_SOURCE[0]}")/fm-remote-reply-ssh-fixture.sh"
  exit "$?"
fi

# An isolated code snapshot allows all fixture homes to remain inside a gate
# worktree without overlapping the entrypoint's configured code root.
ROOT=${FM_REMOTE_REPLY_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}
TMP_ROOT=$(fm_test_tmproot fm-remote-reply)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE="$TMP_ROOT/remote"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
CLAIMS="$TMP_ROOT/claims"
mkdir -p "$PARENT/data" "$PARENT/state" "$REMOTE/state" "$REMOTE/data/reply" "$CLAIMS"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"
# The recorded worker pid is the serving child, not its restart supervisor, so
# stopping that pid alone leaves the supervisor to respawn - the leak
# tests/fm-remote-job-orphan-reap.test.sh pins. Stop the whole worker tree.
cleanup() {
  local worker_pid=''
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    fm_remote_job_stop_worker_tree "$worker_pid" || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

cat > "$PARENT/data/secondmates.md" <<EOF
- ios - iOS delivery (host: remote-mac; root: $ROOT; home: $REMOTE; scope: iOS work; projects: alpha; added 2026-08-02)
EOF
printf '# Detailed remote answer\n\nThe build is green.\n' > "$REMOTE/data/reply/report.md"
: > "$REMOTE/state/parent-replies.status"
SOURCE_BEFORE="$TMP_ROOT/source-before"
cp "$REMOTE/state/parent-replies.status" "$SOURCE_BEFORE"

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_REMOTE_REPLY_WAIT_SECONDS=10 \
  "$@"
}

wait_for() {
  local path=$1
  for _ in $(seq 1 100); do
    [ -e "$path" ] && return 0
    sleep 0.05
  done
  return 1
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

ADAPTER="$ROOT/bin/fm-procevent-remote-reply.sh"
SID=$(remote_env "$ADAPTER" source-id ios)
out=$(remote_env "$ADAPTER" arm ios)
assert_contains "$out" "armed: $SID offset=0" "remote reply source was not armed at the empty cursor"

remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/start-one.out" 2>&1 &
RUNNER=$!
wait_for "$CLAIMS/$SID.claim" || fail "process-event runner never claimed the remote reply source"
printf 'done [corr=0123456789abcdef]: build verified (data/reply/report.md)\n' \
  >> "$REMOTE/state/parent-replies.status"
wait "$RUNNER" || fail "remote reply source failed to capture its first delta"
RESULT=$(find "$PARENT/state/procevent-inbox" -name "$SID.1.result" -print -quit 2>/dev/null)
if [ -z "$RESULT" ]; then
  printf 'runner output:\n%s\n' "$(cat "$TMP_ROOT/start-one.out")" >&2
  fail "the remote reply delta was not durably captured"
fi
assert_grep 'done [corr=0123456789abcdef]' "$RESULT" "captured delta lost the correlated status line"
# One remote note, one announcement: the adapter declares self-announcing, so a
# fully autohandled capture publishes NO check wake - the mirrored status bytes
# are the single announcement, observed here through the same signature-vs-seen
# gate the watcher's signal scan and the drain's annotation check consume.
if [ -e "$PARENT/state/.wake-queue" ] && grep -q "procevent remote-reply $SID 1" "$PARENT/state/.wake-queue"; then
  fail "an autohandled remote-reply capture still published a duplicate check wake"
fi
FM_STATE_OVERRIDE="$PARENT/state" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_wake_signal_seen_current "$2/state" "$2/state/ios.status"
' _ "$ROOT" "$PARENT" && fail "the mirrored reply bytes are not visible to the watcher signal scan"
cmp -s "$SOURCE_BEFORE" "$REMOTE/state/parent-replies.status" \
  && fail "fixture did not append the expected source line"
SOURCE_AFTER="$TMP_ROOT/source-after"
cp "$REMOTE/state/parent-replies.status" "$SOURCE_AFTER"
pass "a blocking non-destructive remote delta reaches durable process-event capture"

# The runner applies a captured result through this adapter itself, so the reply
# is already mirrored, acknowledged, and the next source re-armed before any
# handler runs. That is the primary guarantee; assert it before exercising the
# handler's own path below.
assert_grep 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status" \
  "the captured reply was not applied to the parent status stream at capture"
assert_present "$PARENT/state/procevent-inbox/$SID.1.handled" \
  "the applied capture was left unacknowledged"
assert_present "$PARENT/state/procevent/$SID.source" \
  "applying the capture left the relay unarmed for the next delta"
pass "a captured delta is applied, acknowledged, and re-armed without a handler"
printf '\nREMOTE REPLY EVIDENCE (real scripts and worker; SSH transport is stubbed)\n'
cat "$TMP_ROOT/start-one.out"
printf 'Captured delta protocol:\n'; cat "$RESULT"
printf 'Mirrored status stream:\n'; cat "$PARENT/state/ios.status"
printf 'Committed cursor protocol:\n'; cat "$PARENT/state/remote-replies/ios.cursor"
printf 'Durable handled marker present and next source re-armed.\n'

# Now the handler's own retry path, from the state a crash between applying and
# acknowledging leaves behind: the acknowledgement is gone and re-arming fails.
rm -f "$PARENT/state/procevent-inbox/$SID.1.handled"
rm -rf "$PARENT/state/procevent"
: > "$PARENT/state/procevent"
set +e
remote_env "$ADAPTER" handle ios 1 "$RESULT" > "$TMP_ROOT/handle-arm-fail.out" 2>&1
handle_arm_rc=$?
set -e
[ "$handle_arm_rc" -ne 0 ] || fail "reply handling acknowledged a result whose re-arm failed"
assert_grep 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status" "failed re-arm lost the ingested reply"
assert_grep 'ingested: ios appended=0' "$TMP_ROOT/handle-arm-fail.out" "failed re-arm did not replay the committed reply"
rm -f "$PARENT/state/procevent"
mkdir "$PARENT/state/procevent"
reconcile_out=$(remote_env "$ROOT/bin/fm-procevent.sh" reconcile)
assert_contains "$reconcile_out" 'published=1' "failed re-arm did not leave the result eligible for retry"
out=$(remote_env "$ADAPTER" handle ios 1 "$RESULT")
assert_contains "$out" 'ingested: ios appended=0' "retried reply ingest was not idempotent"
assert_contains "$out" 'handled: remote-reply-ios 1' "captured generation was not acknowledged"
assert_grep 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status" "parent status did not receive the correlated reply"
assert_grep 'data/remote-secondmates/ios/data/reply/report.md' "$PARENT/state/ios.status" "remote document pointer was not rewritten locally"
cmp -s "$REMOTE/data/reply/report.md" "$PARENT/data/remote-secondmates/ios/data/reply/report.md" \
  || fail "the path-confined remote document copy is not byte-identical"
cmp -s "$SOURCE_AFTER" "$REMOTE/state/parent-replies.status" \
  || fail "handling consumed or rewrote the remote append-only log"
expected_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$expected_offset" "$PARENT/state/remote-replies/ios.cursor" "reply cursor did not advance to the committed delta"
pass "ingest appends one validated line, fetches its document, and advances the cursor"

out=$(remote_env "$ADAPTER" handle ios 1 "$RESULT")
assert_contains "$out" 'ingested: ios appended=0' "replayed result was not deduplicated"
assert_contains "$out" 'already-handled: remote-reply-ios 1' "replayed generation was not acknowledged idempotently"
[ "$(grep -cF 'done [corr=0123456789abcdef]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "replayed ingest duplicated the parent status line"
pass "replayed capture has one deduplicated append and one durable handling identity"

printf 'working [corr=1111111111111111]: second generation\n' \
  >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "second reply generation was not captured"
RESULT_TWO="$PARENT/state/procevent-inbox/$SID.2.result"
# The runner already applied and acknowledged this capture. Drop that genuine
# acknowledgement and put an unsafe one in its place, so the handler's refusal
# to trust a non-regular marker stays under test.
rm -f "$PARENT/state/procevent-inbox/$SID.2.handled"
ln -s "$TMP_ROOT/missing-handled-marker" "$PARENT/state/procevent-inbox/$SID.2.handled"
set +e
remote_env "$ADAPTER" handle ios 2 "$RESULT_TWO" > "$TMP_ROOT/handle-two-unacked.out" 2>&1
handle_two_rc=$?
set -e
[ "$handle_two_rc" -ne 0 ] || fail "second generation acknowledged through an unsafe handled marker"
assert_grep 'working [corr=1111111111111111]' "$PARENT/state/ios.status" "unacknowledged generation was not ingested"
printf 'done [corr=2222222222222222]: third generation\n' \
  >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "third reply generation was not captured"
RESULT_THREE="$PARENT/state/procevent-inbox/$SID.3.result"
remote_env "$ADAPTER" handle ios 3 "$RESULT_THREE" >/dev/null \
  || fail "third reply generation was not handled"
rm -f "$PARENT/state/procevent-inbox/$SID.2.handled"
out=$(remote_env "$ADAPTER" handle ios 2 "$RESULT_TWO")
assert_contains "$out" 'ingested: ios appended=0' "earlier generation did not replay from its durable ingestion receipt"
assert_contains "$out" 'handled: remote-reply-ios 2' "earlier generation remained unacknowledged after later cursor advancement"
[ "$(grep -cF 'working [corr=1111111111111111]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "earlier generation replay duplicated its parent status"
pass "later generations cannot invalidate an unacknowledged ingested result"

# The channel mirrors the remote mate's content-bearing status lines at most once
# while omitting blank separators. A remote mate's own progress line and a NEWLY
# raised needs-decision carry no corr= by charter contract, and a delta carrying
# them alongside a correlated answer must ingest whole: every content-bearing
# line reaches the parent stream, the new decision reaches the parent's
# open-decision fold, the correlated line still settles its pending-reply record,
# and the cursor advances so the channel cannot wedge on a line it once refused.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$ROOT/bin/fm-pending-reply-lib.sh"
PENDING_CORR=$(fm_pending_reply_create "$PARENT" "$PARENT/state" ios 'audit the release chain')
[ -n "$PENDING_CORR" ] || fail "could not create the parent pending-reply record"
fm_pending_reply_mark_delivered "$PARENT/state" "$PENDING_CORR" \
  || fail "could not mark the pending-reply request delivered"
{
  printf 'working [key=version-audit]: family --version audit complete (data/reply/report.md)\n'
  printf 'needs-decision [key=rough-cut-version]: implement --version or retire the tool\n'
  printf 'done [corr=%s]: release chain audited\n' "$PENDING_CORR"
} >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "the mirrored status stream was not captured"
RESULT_FOUR="$PARENT/state/procevent-inbox/$SID.4.result"
remote_env "$ADAPTER" handle ios 4 "$RESULT_FOUR" > "$TMP_ROOT/handle-mirror.out" 2>&1 \
  || fail "an uncorrelated status line stopped the delta: $(cat "$TMP_ROOT/handle-mirror.out")"
assert_grep 'working [key=version-audit]' "$PARENT/state/ios.status" "an uncorrelated progress line never reached the parent stream"
assert_grep 'needs-decision [key=rough-cut-version]' "$PARENT/state/ios.status" "a newly raised remote decision never reached the parent stream"
assert_grep "done [corr=$PENDING_CORR]" "$PARENT/state/ios.status" "the correlated answer sharing the delta was lost"
mirror_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$mirror_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the cursor did not advance past an uncorrelated line"
pass "the remote status and decision model mirrors and the cursor advances"

# The newly raised decision must be indistinguishable from a local mate's, so the
# shared fold - not this adapter - decides it is open.
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
OPEN=$(status_open_decisions "$PARENT/state/ios.status")
printf '%s' "$OPEN" | grep -q '^rough-cut-version	needs-decision	' \
  || fail "the remote mate's new decision did not surface as open to the parent: $OPEN"
[ "$(fm_pending_reply_get "$PARENT/state/pending-replies/$PENDING_CORR" phase)" = resolved ] \
  || fail "the correlated answer in the same delta did not settle its pending-reply record"
pass "a remote mate's new decision folds open exactly as a local mate's does"

# Ingesting the same generation again is idempotent: no duplicated lines and no
# cursor movement, so a replay can never wedge or double-count the stream.
remote_env "$ADAPTER" handle ios 4 "$RESULT_FOUR" >/dev/null 2>&1 || true
[ "$(grep -cF 'needs-decision [key=rough-cut-version]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "replaying the mirrored delta duplicated the new decision"
assert_grep "offset=$mirror_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "replaying the mirrored delta moved the cursor"
pass "a replayed mirrored delta is idempotent in both the stream and the cursor"

# Bytes crossing a machine boundary are normalized, never dropped: a control
# character cannot make the parent's status file unsafe and cannot stop the
# stream either.
printf 'blocked [key=ctl]: escape \033[31mhere\033[0m bell \007 caf\xc3\xa9 end\n' \
  >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "the control-character line was not captured"
RESULT_FIVE="$PARENT/state/procevent-inbox/$SID.5.result"
remote_env "$ADAPTER" handle ios 5 "$RESULT_FIVE" >/dev/null 2>&1 \
  || fail "a control character stopped the stream"
assert_grep 'blocked [key=ctl]: escape ?[31mhere' "$PARENT/state/ios.status" \
  "the control-character line was not mirrored in normalized form"
[ -z "$(LC_ALL=C tr -d '\11\12\40-\176\200-\377' < "$PARENT/state/ios.status")" ] \
  || fail "a control byte reached the parent status file"
assert_grep "$(printf 'caf\xc3\xa9 end')" "$PARENT/state/ios.status" \
  "normalization mangled a UTF-8 note a local secondmate could have written"
ctl_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$ctl_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the cursor did not advance past a control-character line"
pass "transported control bytes are normalized in place and never stop the stream"

printf 'status=delta\n' >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "the header-collision line was not captured"
RESULT_SIX="$PARENT/state/procevent-inbox/$SID.6.result"
remote_env "$ADAPTER" handle ios 6 "$RESULT_SIX" >/dev/null 2>&1 \
  || fail "a payload protocol-field name stopped the stream"
assert_grep 'status=delta' "$PARENT/state/ios.status" \
  "the payload protocol-field line did not reach the parent stream"
collision_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$collision_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the cursor did not advance past a payload protocol-field line"
pass "payload protocol-field names cannot collide with transport metadata"

printf 'working [key=nul-byte]: before\000after\n' >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "the NUL-bearing line was not captured"
RESULT_SEVEN="$PARENT/state/procevent-inbox/$SID.7.result"
remote_env "$ADAPTER" handle ios 7 "$RESULT_SEVEN" >/dev/null 2>&1 \
  || fail "a NUL byte stopped the stream"
assert_grep 'working [key=nul-byte]: before?after' "$PARENT/state/ios.status" \
  "the NUL byte was not normalized in place"
nul_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$nul_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the cursor did not advance past a NUL-bearing line"
pass "NUL bytes are normalized in place before shell line processing"

printf '# Retryable remote answer\n' > "$REMOTE/data/reply/retry.md"
printf 'done [key=retry-document]: retry local storage (data/reply/retry.md)\n' \
  >> "$REMOTE/state/parent-replies.status"
# Obstruct local document storage BEFORE the capture, so the runner's own
# automatic application fails for real. That is the documented fallback: a
# capture whose application does not complete stays unacknowledged and
# uncommitted, and the handler finishes it once storage recovers.
retry_destination="$PARENT/data/remote-secondmates/ios/data/reply/retry.md"
retry_decoy="$TMP_ROOT/retry-decoy.md"
printf 'local decoy\n' > "$retry_decoy"
ln -s "$retry_decoy" "$retry_destination"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 \
  || fail "the retryable document line was not captured"
RESULT_EIGHT="$PARENT/state/procevent-inbox/$SID.8.result"
assert_absent "$PARENT/state/procevent-inbox/$SID.8.handled" \
  "a capture whose automatic application failed was acknowledged anyway"
# The self-announcing declaration never silences a capture the adapter could
# NOT fully apply: this one must still publish its check wake for the handler.
assert_grep "procevent remote-reply $SID 8" "$PARENT/state/.wake-queue" \
  "a not-fully-applied capture lost its check-wake announcement"
assert_no_grep 'retry local storage' "$PARENT/state/.wake-queue" \
  "reply payload leaked into the event queue"
retry_cursor_before=$(cat "$PARENT/state/remote-replies/ios.cursor")
set +e
remote_env "$ADAPTER" handle ios 8 "$RESULT_EIGHT" > "$TMP_ROOT/handle-local-document-failure.out" 2>&1
local_document_rc=$?
set -e
[ "$local_document_rc" -ne 0 ] || fail "local document storage failure committed the delta"
assert_grep 'could not store referenced remote document' "$TMP_ROOT/handle-local-document-failure.out" \
  "local document storage failure was misclassified as remote refusal"
[ "$(cat "$PARENT/state/remote-replies/ios.cursor")" = "$retry_cursor_before" ] \
  || fail "local document storage failure advanced the cursor"
assert_no_grep 'done [key=retry-document]' "$PARENT/state/ios.status" \
  "local document storage failure mirrored an undelivered line"
assert_no_grep 'blocked [key=remote-reply-document-ios]' "$PARENT/state/ios.status" \
  "local document storage failure raised a permanent remote refusal"
rm -f "$retry_destination"
remote_env "$ADAPTER" handle ios 8 "$RESULT_EIGHT" >/dev/null \
  || fail "the document delta did not succeed after local storage recovered"
assert_grep 'data/remote-secondmates/ios/data/reply/retry.md' "$PARENT/state/ios.status" \
  "the retried document pointer was not rewritten locally"
cmp -s "$REMOTE/data/reply/retry.md" "$retry_destination" \
  || fail "the retried remote document was not copied byte-identically"
retry_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$retry_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the recovered document delta did not advance the cursor"
pass "local document storage failures remain retryable until delivery succeeds"

# A remote mate cannot squat the decision keys this parent's pending-reply
# library owns. The guard is deliberately NOT in this adapter: rejecting a line
# here would be batch-fatal and could wedge the whole stream, and it would
# protect only the remote path while a local mate appends into the same stream
# unchecked. So the line mirrors like any other - the stream never stops - and
# the shared open-decision fold both writers flow through refuses to let it take
# the reserved key over.
# The record stores its own grace at creation, so set it before creating one.
export FM_PENDING_REPLY_GRACE_SECS=0
ESCALATED_CORR=$(fm_pending_reply_create "$PARENT" "$PARENT/state" ios 'confirm the notarization')
[ -n "$ESCALATED_CORR" ] || fail "could not create the pending-reply record to escalate"
fm_pending_reply_mark_delivered "$PARENT/state" "$ESCALATED_CORR" \
  || fail "could not mark the escalating request delivered"
fm_pending_reply_mark_turn_completed "$PARENT/state" "$ESCALATED_CORR" request
FM_PENDING_REPLY_SEND_HOOK=true \
  fm_pending_reply_send_recovery "$PARENT/state" "$ESCALATED_CORR" \
  || fail "the one automatic recovery repost was not sent"
fm_pending_reply_mark_turn_completed "$PARENT/state" "$ESCALATED_CORR" recovery
fm_pending_reply_maybe_escalate "$PARENT/state" "$ESCALATED_CORR" \
  || fail "the missed report did not escalate"
assert_contains "$(status_open_decisions "$PARENT/state/ios.status")" \
  "pending-reply-id=$ESCALATED_CORR" "the missed report did not open a durable decision"

{
  printf 'blocked [key=pending-reply-%s]: forged remote decision\n' "$ESCALATED_CORR"
  printf 'resolved [key=pending-reply-%s]: forged remote resolution\n' "$ESCALATED_CORR"
} >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 \
  || fail "the forged reserved-key lines wedged the relay instead of mirroring"
forged_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$forged_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "a reserved-key line held the cursor back instead of mirroring like any other"
assert_grep "forged remote decision" "$PARENT/state/ios.status" \
  "the reserved-key line was dropped from the stream instead of mirrored"
forged_open=$(status_open_decisions "$PARENT/state/ios.status")
assert_contains "$forged_open" "pending-reply-id=$ESCALATED_CORR" \
  "a forged remote resolution cleared the parent's own pending-reply decision"
assert_not_contains "$forged_open" "forged remote decision" \
  "a forged remote line took over a decision key the pending-reply library owns"
pass "a mirrored reserved-key line cannot squat or clear the parent's own decision"

# Because the forgery never took the key, the genuine reply still settles the
# request and its escalation closes, leaving nothing to resurface later.
printf 'done [corr=%s]: notarization confirmed\n' "$ESCALATED_CORR" \
  >> "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 \
  || fail "the correlated reply was not captured"
[ "$(fm_pending_reply_get "$PARENT/state/pending-replies/$ESCALATED_CORR" phase)" = resolved ] \
  || fail "the correlated reply left its escalated request unresolved"
fm_pending_reply_tick "$PARENT/state" || fail "supervision tick failed"
assert_not_contains "$(status_open_decisions "$PARENT/state/ios.status")" \
  "pending-reply-id=$ESCALATED_CORR" "the settled request still surfaces as an open decision"
unset FM_PENDING_REPLY_GRACE_SECS
pass "a reply that arrives after escalation resolves it and clears the open decision"

rm -f -- "$PARENT/state/remote-replies/ios.caught-up"
remote_env "$ADAPTER" source ios > "$TMP_ROOT/preempted-source.out" 2>&1 &
PREEMPTED_SOURCE=$!
running_poll=''
for _ in $(seq 1 100); do
  for job in "$TMP_ROOT"/remote-jobs/jobs/job-*; do
    [ -d "$job" ] || continue
    if [ "$(fm_remote_job_read_state "$job" 2>/dev/null || true)" = running ]; then
      running_poll=$job
      break 2
    fi
  done
  sleep 0.05
done
[ -n "$running_poll" ] || fail "the reply poll did not begin running before preemption"
remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-file.sh get data/reply/report.md 262144 >/dev/null
set +e
wait "$PREEMPTED_SOURCE"
preempted_rc=$?
set -e
[ "$preempted_rc" -eq "$FM_REMOTE_JOB_PREEMPTED_EXIT" ] \
  || fail "the reply poll did not expose remote-job preemption: $preempted_rc"
assert_absent "$PARENT/state/remote-replies/ios.caught-up" \
  "a preempted reply poll published a caught-up watermark"
pass "a preempted reply poll cannot publish channel freshness"

# A quiet window is the one moment this channel can prove it is NOT behind, and
# the parent's pending-reply guard needs that proof: a remote report that exists
# but has not been mirrored yet must never be mistaken for a report the mate
# never wrote. The window opened with the log matching the committed cursor, so
# the published watermark is the window's start.
watermark_before=$(date +%s)
set +e
FM_REMOTE_REPLY_WAIT_SECONDS=1 remote_env "$ADAPTER" source ios >/dev/null 2>&1
quiet_rc=$?
set -e
[ "$quiet_rc" -eq 75 ] || fail "a quiet reply window exited with an unexpected status: $quiet_rc"
watermark_after=$(date +%s)
caught_up=$(FM_STATE_OVERRIDE="$PARENT/state" bash -c '
  . "$1/bin/fm-pending-reply-lib.sh"
  fm_pending_reply_remote_channel_epoch "$2/state" ios
' _ "$ROOT" "$PARENT")
[ -n "$caught_up" ] || fail "a quiet reply window published no caught-up watermark"
[ "$caught_up" -ge "$watermark_before" ] && [ "$caught_up" -le "$watermark_after" ] \
  || fail "the caught-up watermark ($caught_up) is outside the quiet window"
pass "a quiet reply window publishes the caught-up watermark the reply guard reads"

# The observed already-handled replay class: a lost cursor (an update or
# convergence retire) makes the next armed source recapture the WHOLE remote
# log from offset 0. Every line is already mirrored, so the at-most-once
# append adds no bytes, the adapter acknowledges the generation, and the
# self-announcing runner publishes nothing - the replay stays completely
# quiet, observed through the same seen-signature gate the watcher consumes.
FM_STATE_OVERRIDE="$PARENT/state" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_wake_status_mark_current "$2/state" "$2/state/ios.status"
' _ "$ROOT" "$PARENT" || fail "could not prime the seen marker for the replay leg"
cp "$PARENT/state/ios.status" "$TMP_ROOT/ios-status-before-replay"
mv "$PARENT/state/.wake-queue" "$TMP_ROOT/wake-queue-before-replay" 2>/dev/null || true
rm -f "$PARENT/state/remote-replies/ios.cursor"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 \
  || fail "the cursor-loss recapture was not captured"
assert_present "$PARENT/state/procevent-inbox/$SID.11.handled" \
  "the whole-log recapture was not acknowledged by the adapter"
cmp -s "$TMP_ROOT/ios-status-before-replay" "$PARENT/state/ios.status" \
  || fail "the whole-log recapture duplicated already-mirrored lines"
if [ -e "$PARENT/state/.wake-queue" ] && grep -q "procevent remote-reply $SID 11" "$PARENT/state/.wake-queue"; then
  fail "an already-mirrored recapture still published a check wake"
fi
FM_STATE_OVERRIDE="$PARENT/state" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_wake_signal_seen_current "$2/state" "$2/state/ios.status"
' _ "$ROOT" "$PARENT" || fail "a byte-identical recapture left unannounced status bytes behind"
replay_offset=$(LC_ALL=C wc -c < "$REMOTE/state/parent-replies.status" | tr -d ' ')
assert_grep "offset=$replay_offset" "$PARENT/state/remote-replies/ios.cursor" \
  "the recapture did not rebuild the lost cursor"
pass "a cursor-loss whole-log recapture is acknowledged quietly with no duplicate wake"

# The adapter re-armed at the committed cursor. A mate that rewrites its reply
# log in place breaks that cursor; the break is recovered by replaying the log
# from the start, which delivers exactly the lines this home has not mirrored.
cp "$PARENT/state/ios.status" "$TMP_ROOT/ios-status-before-rewrite"
{ cat "$REMOTE/state/parent-replies.status"; printf 'done [corr=fedcba9876543210]: written after an in-place edit\n'; } \
  | sed '1s/^/edited /' > "$TMP_ROOT/rewritten" && mv "$TMP_ROOT/rewritten" "$REMOTE/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/start-two.out" 2>&1 \
  || fail "continuity break was not captured as a structured result"
RESULT_TWELVE=$(find "$PARENT/state/procevent-inbox" -name "$SID.12.result" -print -quit)
[ -n "$RESULT_TWELVE" ] || fail "continuity break produced no durable result"
[ "$(remote_env "$ADAPTER" classify "$RESULT_TWELVE")" = continuity-broken ] \
  || fail "a rewritten source was not classified as a continuity break"
assert_present "$PARENT/state/procevent-inbox/$SID.12.handled" "the continuity break was not handled"
assert_present "$PARENT/state/procevent/$SID.source" "a recoverable continuity break was not re-armed"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null 2>&1 || fail "the replay was not captured"
assert_present "$PARENT/state/procevent-inbox/$SID.13.handled" "the replay was not ingested"
[ "$(grep -cF 'done [corr=fedcba9876543210]: written after an in-place edit' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "the line written after the rewrite was not delivered exactly once"
[ "$(grep -c '^edited ' "$PARENT/state/ios.status")" -eq 1 ] || fail "the edited line was not delivered exactly once"
[ "$(wc -l < "$PARENT/state/ios.status")" -eq $(( $(wc -l < "$TMP_ROOT/ios-status-before-rewrite") + 2 )) ] \
  || fail "the replay duplicated lines this home had already mirrored"
assert_no_grep 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status" "a recovered break was escalated"
pass "an in-place rewrite of the reply log is recovered by a replay that delivers only unseen lines"

# A log that keeps breaking past its hourly recovery budget is escalated once and
# left stopped rather than replayed forever.
printf 'failed [corr=0123456789abcdef]: source was replaced\n' > "$REMOTE/state/parent-replies.status"
FM_REMOTE_REPLY_RECOVERY_LIMIT=0 remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" > "$TMP_ROOT/start-three.out" 2>&1 \
  || fail "the second continuity break was not captured"
RESULT_TWELVE=$(find "$PARENT/state/procevent-inbox" -name "$SID.14.result" -print -quit)
[ -n "$RESULT_TWELVE" ] || fail "the second continuity break produced no durable result"
assert_grep 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status" "an exhausted recovery budget did not escalate"
assert_absent "$PARENT/state/procevent/$SID.source" "a break past the recovery budget was re-armed"
[ "$(grep -cF 'blocked [key=remote-reply-continuity-ios]' "$PARENT/state/ios.status")" -eq 1 ] \
  || fail "continuity handling duplicated the escalation"
out=$(remote_env "$ADAPTER" arm ios 2>&1) || fail "arming a stopped reply source failed: $out"
assert_contains "$out" "stopped: ios" "automatic arming did not report the recorded stop"
assert_absent "$PARENT/state/procevent/$SID.source" "automatic arming lifted a recorded continuity stop"
pass "a reply log that keeps breaking is escalated once and not rebased past its budget"

rm -f "$PARENT/state/procevent-inbox/$SID.14.handled"
if remote_env "$ADAPTER" retire ios > "$TMP_ROOT/retire-pending.out" 2>&1; then
  fail "remote reply retirement accepted an unhandled captured result"
fi
assert_grep 'unhandled captured result' "$TMP_ROOT/retire-pending.out" \
  "remote reply retirement did not explain its pending-result refusal"
assert_absent "$PARENT/state/procevent/$SID.source" \
  "refused retirement left the reply source running past its pending-result check"
FM_REMOTE_REPLY_RECOVERY_LIMIT=0 remote_env "$ADAPTER" handle ios 14 "$RESULT_TWELVE" >/dev/null 2>&1 || [ "$?" -eq 3 ] \
  || fail "pending continuity result could not be acknowledged after retirement refusal"
remote_env "$ADAPTER" retire ios >/dev/null
assert_absent "$PARENT/state/remote-replies/ios.cursor" "adapter retirement left its cursor"
assert_absent "$PARENT/state/remote-replies/ios.caught-up" \
  "adapter retirement left a caught-up watermark a later route could inherit"
pass "remote reply retirement quiesces and refuses unhandled captured results"

# Reproduce capture/ingest ordering without touching a live remote cursor.
# Capture one remains pending while either a larger same-start capture or a
# disjoint successor is accepted, followed by another ordinary successor.
# Receipt-backed coverage or successors permit acknowledging the earlier
# generation; mirrored text alone is insufficient.
for reconcile_shape in covering covering-nonzero successor successor-missing; do
(
  PARENT="$TMP_ROOT/reconcile-parent-$reconcile_shape"
  READER_HOME="$TMP_ROOT/reconcile-reader-$reconcile_shape"
  mkdir -p "$PARENT/state/procevent-inbox" "$PARENT/data" "$READER_HOME/state"
  cp "$TMP_ROOT/parent/data/secondmates.md" "$PARENT/data/secondmates.md"
  inbox="$PARENT/state/procevent-inbox"
  old="$inbox/$SID.1.result"
  newer="$inbox/$SID.2.result"
  latest="$inbox/$SID.3.result"
  : > "$TMP_ROOT/reconcile-empty"
  empty=$(sha256_file "$TMP_ROOT/reconcile-empty")
  start=0
  start_hash=$empty
  : > "$READER_HOME/state/parent-replies.status"
  if [ "$reconcile_shape" != covering ]; then
    printf 'working: synthetic baseline\n' > "$READER_HOME/state/parent-replies.status"
    baseline="$inbox/$SID.0.result"
    FM_HOME="$READER_HOME" "$ROOT/bin/fm-remote-delta-read.sh" \
      state/parent-replies.status 0 "$empty" 1 > "$baseline"
    printf 'remote-reply\n' > "${baseline%.result}.adapter"
    remote_env "$ADAPTER" handle ios 0 "$baseline" >/dev/null \
      || fail "baseline ingestion failed"
    start=$(wc -c < "$READER_HOME/state/parent-replies.status" | tr -d ' ')
    start_hash=$(sha256_file "$READER_HOME/state/parent-replies.status")
  fi
  printf 'working: earlier synthetic report\n' >> "$READER_HOME/state/parent-replies.status"
  if [ "$reconcile_shape" = covering-nonzero ]; then
    printf 'working: retry document (data/reply/report.md)\n' >> "$READER_HOME/state/parent-replies.status"
  fi
  FM_HOME="$READER_HOME" "$ROOT/bin/fm-remote-delta-read.sh" \
    state/parent-replies.status "$start" "$start_hash" 1 > "$old"
  printf 'remote-reply\n' > "${old%.result}.adapter"
  from=$start
  from_hash=$start_hash
  if [ "$reconcile_shape" = covering-nonzero ]; then
    destination="$PARENT/data/remote-secondmates/ios/data/reply/report.md"
    mkdir -p "$(dirname "$destination")"
    ln -s "$REMOTE/data/reply/report.md" "$destination"
    cp "$PARENT/state/remote-replies/ios.cursor" "$TMP_ROOT/reconcile-baseline-cursor"
    if remote_env "$ADAPTER" handle ios 1 "$old" > "$TMP_ROOT/reconcile-ingest-failure" 2>&1; then
      fail "pending capture did not fail on obstructed document storage"
    fi
    assert_grep 'could not store referenced remote document' "$TMP_ROOT/reconcile-ingest-failure" \
      "pending capture failed for an unexpected reason"
    assert_absent "$inbox/$SID.1.handled" "failed pending capture was acknowledged"
    assert_absent "$PARENT/state/remote-replies/ios.1.ingested" "failed pending capture got a receipt"
    cmp -s "$PARENT/state/remote-replies/ios.cursor" "$TMP_ROOT/reconcile-baseline-cursor" \
      || fail "failed pending capture advanced the baseline cursor"
    rm "$destination"
  fi
  if [ "$reconcile_shape" = successor ] || [ "$reconcile_shape" = successor-missing ]; then
    # The low-level ingest interface commits bytes/cursor without a generation
    # receipt, reproducing an older capture whose acceptance was not recorded.
    remote_env "$ADAPTER" ingest ios "$old" >/dev/null || fail "legacy ingestion failed"
    from=$(wc -c < "$READER_HOME/state/parent-replies.status" | tr -d ' ')
    from_hash=$(sha256_file "$READER_HOME/state/parent-replies.status")
  fi
  printf 'done: later synthetic report\n' >> "$READER_HOME/state/parent-replies.status"
  FM_HOME="$READER_HOME" "$ROOT/bin/fm-remote-delta-read.sh" \
    state/parent-replies.status "$from" "$from_hash" 1 > "$newer"
  printf 'remote-reply\n' > "${newer%.result}.adapter"
  remote_env "$ADAPTER" handle ios 2 "$newer" >/dev/null || fail "covering capture failed"
  if [ "$reconcile_shape" = covering-nonzero ]; then
    cmp -s "$REMOTE/data/reply/report.md" "$destination" \
      || fail "covering capture lost the pending document effect"
  fi
  offset=$(wc -c < "$READER_HOME/state/parent-replies.status" | tr -d ' ')
  prefix=$(sha256_file "$READER_HOME/state/parent-replies.status")
  printf 'working: newest synthetic report\n' >> "$READER_HOME/state/parent-replies.status"
  FM_HOME="$READER_HOME" "$ROOT/bin/fm-remote-delta-read.sh" \
    state/parent-replies.status "$offset" "$prefix" 1 > "$latest"
  printf 'remote-reply\n' > "${latest%.result}.adapter"
  remote_env "$ADAPTER" handle ios 3 "$latest" >/dev/null || fail "successor capture failed"
  cp "$PARENT/state/remote-replies/ios.cursor" "$TMP_ROOT/reconcile-cursor"
  if [ "$reconcile_shape" = successor-missing ]; then
    # Model a partially missing local mirror: ancestry must not mean skipping
    # the pending delta's own effects just because its successors have receipts.
    grep -v 'earlier synthetic report' "$PARENT/state/ios.status" > "$TMP_ROOT/reconcile-partial"
    mv "$TMP_ROOT/reconcile-partial" "$PARENT/state/ios.status"
  fi
  cp "$PARENT/state/ios.status" "$TMP_ROOT/reconcile-status"
  cp "$old" "$TMP_ROOT/reconcile-old"
  receipt="$PARENT/state/remote-replies/ios.2.ingested"
  cp "$receipt" "$TMP_ROOT/reconcile-receipt"

  refused() {
    if remote_env "$ADAPTER" handle ios 1 "${2:-$old}" > "$TMP_ROOT/reconcile-refusal" 2>&1; then
      fail "unproven pending capture was accepted: $1"
    fi
    assert_grep 'does not continue the current cursor' "$TMP_ROOT/reconcile-refusal" "$1"
    assert_absent "$inbox/$SID.1.handled" "refusal acknowledged the pending capture"
    assert_absent "$PARENT/state/remote-replies/ios.1.ingested" "refusal fabricated a receipt"
    cmp -s "$PARENT/state/remote-replies/ios.cursor" "$TMP_ROOT/reconcile-cursor" \
      || fail "refusal changed later cursor progress"
    cmp -s "$PARENT/state/ios.status" "$TMP_ROOT/reconcile-status" \
      || fail "refusal changed later status progress"
  }
  rm "$receipt"
  refused 'mirrored bytes without an accepted receipt are not proof'
  cp "$TMP_ROOT/reconcile-receipt" "$receipt"
  printf 'tampered\n' >> "$receipt"
  refused 'a malformed receipt cannot prove coverage'
  cp "$TMP_ROOT/reconcile-receipt" "$receipt"
  refused 'an external file cannot borrow the pending capture identity' "$TMP_ROOT/reconcile-old"
  rm "${old%.result}.adapter"
  refused 'a pending capture requires its own adapter provenance'
  printf 'remote-reply\n' > "${old%.result}.adapter"
  printf 'lavish\n' > "${newer%.result}.adapter"
  refused 'a different captured adapter cannot prove coverage'
  printf 'remote-reply\n' > "${newer%.result}.adapter"
  cp "$latest" "$TMP_ROOT/reconcile-latest"
  printf 'tampered\n' >> "$latest"
  refused 'a changed receipt-backed successor cannot prove current cursor ancestry'
  cp "$TMP_ROOT/reconcile-latest" "$latest"
  if [ "$reconcile_shape" = covering-nonzero ]; then
    baseline_receipt="$PARENT/state/remote-replies/ios.0.ingested"
    cp "$baseline_receipt" "$TMP_ROOT/reconcile-baseline-receipt"
    rm "$baseline_receipt"
    refused 'nonzero coverage needs receipt-backed prefix bytes, not mirror text'
    cp "$TMP_ROOT/reconcile-baseline-receipt" "$baseline_receipt"
    printf 'lavish\n' > "${baseline%.result}.adapter"
    refused 'nonzero covering prefix requires adapter provenance'
    printf 'remote-reply\n' > "${baseline%.result}.adapter"
    cp "$baseline" "$TMP_ROOT/reconcile-baseline"
    { printf 'schema=fm-remote-delta.v1\n'; cat "$TMP_ROOT/reconcile-baseline"; } > "$baseline"
    printf 'result_sha256=%s\n' "$(sha256_file "$baseline")" > "$baseline_receipt"
    refused 'receipt-backed ambiguous prefix headers cannot prove coverage'
    cp "$TMP_ROOT/reconcile-baseline" "$baseline"
    cp "$TMP_ROOT/reconcile-baseline-receipt" "$baseline_receipt"
    sed "s/^from_prefix_sha256=.*/from_prefix_sha256=$empty/" "$TMP_ROOT/reconcile-old" > "$old"
    refused 'nonzero coverage must verify the pending start hash'
    sed "s/^to_prefix_sha256=.*/to_prefix_sha256=$empty/" "$TMP_ROOT/reconcile-old" > "$old"
    refused 'nonzero coverage must verify the pending end hash'
    cp "$TMP_ROOT/reconcile-old" "$old"
  fi
  # A valid but different earlier delta must not be accepted on offsets alone.
  printf 'working: another synthetic report\n' > "$READER_HOME/state/parent-replies.status"
  FM_HOME="$READER_HOME" "$ROOT/bin/fm-remote-delta-read.sh" \
    state/parent-replies.status 0 "$empty" 1 > "$old"
  refused 'a different pending payload cannot borrow accepted provenance'
  cp "$TMP_ROOT/reconcile-old" "$old"
  out=$(remote_env "$ADAPTER" handle ios 1 "$old") || fail "proven stale capture did not reconcile"
  assert_contains "$out" 'handled: remote-reply-ios 1' "pending generation remained unhandled"
  assert_present "$PARENT/state/remote-replies/ios.1.ingested" "pending capture got no exact receipt"
  printf 'result_sha256=%s\n' "$(sha256_file "$old")" > "$TMP_ROOT/reconcile-pending-receipt"
  cmp -s "$PARENT/state/remote-replies/ios.1.ingested" "$TMP_ROOT/reconcile-pending-receipt" \
    || fail "pending receipt did not commit the captured bytes"
  if [ "$reconcile_shape" = successor-missing ]; then
    printf 'working: earlier synthetic report\n' >> "$TMP_ROOT/reconcile-status"
  fi
  remote_env "$ADAPTER" handle ios 1 "$old" >/dev/null || fail "reconciliation was not idempotent"
  cmp -s "$old" "$TMP_ROOT/reconcile-old" || fail "reconciliation rewrote captured bytes"
  cmp -s "$receipt" "$TMP_ROOT/reconcile-receipt" || fail "reconciliation changed receipt provenance"
  cmp -s "$PARENT/state/remote-replies/ios.cursor" "$TMP_ROOT/reconcile-cursor" \
    || fail "reconciliation rewound later cursor progress"
  cmp -s "$PARENT/state/ios.status" "$TMP_ROOT/reconcile-status" \
    || fail "reconciliation duplicated or dropped later status bytes"
  remote_env "$ADAPTER" retire ios >/dev/null
) || fail "stale pending receipt reconciliation failed ($reconcile_shape)"
done
pass "receipt-backed ancestry reconciles an older pending capture without losing later progress"

echo "ALL TESTS PASSED"
