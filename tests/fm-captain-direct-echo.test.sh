#!/usr/bin/env bash
# Captain-direct messages reach a secondmate once (bin/fm-captain-direct-lib.sh).
#
# When the captain writes to a secondmate himself, the parent first mate is
# told with one FYI note, and a later parent steer that repeats or reconciles
# his message is not sent, so the mate never answers him twice. Hermetic (the
# fake stream hub, no real agent):
#   1. --from-captain to a secondmate prints corr= and first_mate=told, queues
#      one FYI inbox note naming the corr, and records the delivery.
#   2. A same-corr resend does not queue a second FYI note.
#   3. A parent steer naming the corr, talking about the captain's direct
#      message, or restating a run of his words is suppressed: exit 0,
#      suppressed= on stdout, nothing enqueued, a log line.
#   4. --correction sends it anyway; an unrelated steer and a steer after the
#      window are sent; a --resolve-key answer is never held back.
#   5. --correction cannot accompany --from-captain.
#   6. A captain-direct pending reply never sends the repost request and
#      resolves on its own after grace.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-marker-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pending-reply-lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-captain-direct)
CAPTAIN_TEXT="Yeah, I don't care if it's the only mode. My user should be a super admin, so implement this thing so the dashboard is actually useful."

make_stubs() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/sleep"
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

# run_send <fakebin> <home> <log> <stdout-file> -- <fm-send args...>
run_send() {
  local fb=$1 home=$2 log=$3 out=$4; shift 4
  env PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_LOG="$log" FM_SEND_SETTLE=0 \
    "$SEND" "$@" > "$out" 2>/dev/null
}

setup() {  # <name> -> sets HOME_DIR FB LOG OUT
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  FB=$(make_stubs "$dir"); LOG="$dir/send.log"; OUT="$dir/out"
  HOME_DIR="$dir/home"
  mkdir -p "$HOME_DIR/state"
  fm_test_stream_secondmate_meta "$HOME_DIR/state/domain.meta" "$HOME_DIR" alpha echo "$LOG"
}

inbox_count() {
  find "$HOME_DIR/state/domain.inbox" -name '*.msg' 2>/dev/null | wc -l | tr -d ' '
}

notes() {
  cat "$HOME_DIR/state/inbox/"*.note 2>/dev/null
}

deliver_captain() {  # -> sets CORR
  run_send "$FB" "$HOME_DIR" "$LOG" "$OUT" domain --from-captain "$CAPTAIN_TEXT" \
    || fail "the captain's message should be delivered"
  CORR=$(sed -n 's/^corr=//p' "$OUT")
  [ "${#CORR}" -eq 16 ] || fail "fm-send must print the delivered corr: $(cat "$OUT")"
}

test_delivery_tells_first_mate_once() {
  local n
  setup tell
  deliver_captain
  assert_contains "$(cat "$OUT")" "first_mate=told" "fm-send must say the first mate was told"
  n=$(find "$HOME_DIR/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" = 1 ] || fail "expected exactly one FYI note, got $n"
  assert_contains "$(notes)" "Captain steered domain directly (corr=$CORR). FYI only" "the note must name the mate and corr"
  assert_contains "$(notes)" "Do not forward it, steer domain about it, or re-ask domain" "the note must say not to re-deliver"
  assert_contains "$(notes)" "$CAPTAIN_TEXT" "the note must carry his words"
  [ -f "$HOME_DIR/state/captain-direct/$CORR" ] || fail "the delivery must be recorded for the echo guard"
  env FM_PENDING_REPLY_EXISTING_CORR="$CORR" PATH="$FB:$PATH" FM_ROOT_OVERRIDE="$HOME_DIR" FM_HOME="$HOME_DIR" \
    FM_SEND_LOG="$LOG" FM_SEND_SETTLE=0 "$SEND" domain --from-captain "$CAPTAIN_TEXT" > "$OUT" 2>/dev/null \
    || fail "a same-corr resend should succeed"
  n=$(find "$HOME_DIR/state/inbox" -maxdepth 1 -name '*.note' 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" = 1 ] || fail "a same-corr resend must not queue a second FYI note (got $n)"
  pass "captain-direct: delivery tells the first mate once, with the corr"
}

expect_suppressed() {  # <why> <text...>
  local why=$1 before; shift
  before=$(inbox_count)
  run_send "$FB" "$HOME_DIR" "$LOG" "$OUT" domain "$@" || fail "$why: a suppressed echo exits 0"
  assert_contains "$(cat "$OUT")" "suppressed=captain-direct-echo corr=$CORR" "$why: stdout must say it was suppressed"
  [ "$(inbox_count)" = "$before" ] || fail "$why: a suppressed echo must enqueue nothing"
}

expect_sent() {  # <why> <args...>
  local why=$1 before; shift
  before=$(inbox_count)
  run_send "$FB" "$HOME_DIR" "$LOG" "$OUT" domain "$@" || fail "$why: should be sent"
  case "$(cat "$OUT")" in *suppressed=*) fail "$why: must not be suppressed" ;; esac
  [ "$(inbox_count)" -gt "$before" ] || fail "$why: must enqueue a record"
}

test_echoes_are_suppressed() {
  setup echo
  deliver_captain
  expect_suppressed "a reconciliation steer" --fire-and-forget 92e476fa8b10c3d5 \
    "The captain-direct follow-up now explicitly authorizes implementing useful dashboard editing."
  expect_suppressed "a direct-message reference" \
    "Preserve the direct message correlation from the captain and file the question."
  expect_suppressed "a restated run of his words" \
    "Please make sure my user should be a super admin, so implement it."
  expect_suppressed "a corr reference" "Follow up on corr=$CORR please."
  assert_contains "$(cat "$HOME_DIR/state/captain-direct.log")" "suppressed corr=$CORR task=domain" \
    "every suppression must be logged"
  pass "captain-direct: parent steers that repeat or reconcile it are not sent"
}

test_corrections_and_unrelated_steers_are_sent() {
  setup send
  deliver_captain
  expect_sent "a --correction steer" --correction \
    "The captain-direct reply missed the staging deploy; redeploy staging."
  assert_contains "$(cat "$HOME_DIR/state/captain-direct.log")" "correction-sent corr=$CORR" \
    "a correction must be logged"
  expect_sent "an unrelated steer" "Rebase the landing page branch onto main."
  FM_CAPTAIN_DIRECT_NOW=$(( $(date +%s) + 7201 )) expect_sent "a steer after the window" \
    "The captain asked me directly about billing; check the invoice job."
  pass "captain-direct: corrections, unrelated steers, and late steers are sent"
}

test_correction_refused_with_from_captain() {
  setup refuse
  if run_send "$FB" "$HOME_DIR" "$LOG" "$OUT" domain --correction --from-captain "hi"; then
    fail "--correction with --from-captain must be refused"
  fi
  [ "$(inbox_count)" = 0 ] || fail "a refused send must enqueue nothing"
  pass "captain-direct: --correction cannot accompany --from-captain"
}

test_pending_reply_never_reposts() {
  local rec delivered sent=0
  setup pending
  deliver_captain
  rec=$(fm_pending_reply_path "$HOME_DIR/state" "$CORR")
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  [ -n "$delivered" ] || fail "the captain-direct record must be marked delivered"
  export FM_PENDING_REPLY_SEND_HOOK="$TMP_ROOT/pending/hook"
  printf '#!/usr/bin/env bash\necho sent >> %q\n' "$TMP_ROOT/pending/hook.log" > "$FM_PENDING_REPLY_SEND_HOOK"
  chmod +x "$FM_PENDING_REPLY_SEND_HOOK"
  FM_PENDING_REPLY_NOW=$((delivered + 30)) fm_pending_reply_tick_one "$HOME_DIR/state" "$CORR" idle
  assert_contains "$(cat "$rec")" "phase=awaiting_report" "inside grace the record stays open"
  FM_PENDING_REPLY_NOW=$((delivered + 600)) fm_pending_reply_tick_one "$HOME_DIR/state" "$CORR" idle
  FM_PENDING_REPLY_NOW=$((delivered + 1200)) fm_pending_reply_tick_one "$HOME_DIR/state" "$CORR" idle
  unset FM_PENDING_REPLY_SEND_HOOK
  [ -f "$TMP_ROOT/pending/hook.log" ] && sent=1
  [ "$sent" = 0 ] || fail "a captain-direct record must never send the repost request"
  assert_contains "$(cat "$rec")" "phase=resolved" "after grace the record resolves on its own"
  assert_contains "$(cat "$rec")" "resolved_via=captain-direct" "it resolves as captain-direct"
  [ -z "$(fm_pending_reply_get "$rec" escalated_epoch)" ] || fail "a captain-direct record must never escalate"
  pass "captain-direct: the pending reply never reposts or escalates"
}

test_notification_failure_retry() {
  local n id
  setup notification-failure
  : > "$HOME_DIR/state/inbox"
  deliver_captain
  assert_contains "$(cat "$OUT")" "first_mate=failed" "an unqueued FYI must report failure"
  [ -f "$HOME_DIR/state/captain-direct/$CORR" ] || fail "the delivery ledger must exist despite notification failure"
  rm "$HOME_DIR/state/inbox"
  FM_PENDING_REPLY_EXISTING_CORR="$CORR" run_send "$FB" "$HOME_DIR" "$LOG" "$OUT" \
    domain --from-captain "$CAPTAIN_TEXT" || fail "notification retry should succeed"
  assert_contains "$(cat "$OUT")" "first_mate=told" "retry must queue the missing FYI"
  n=$(find "$HOME_DIR/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')
  [ "$n" = 1 ] || fail "retry must queue exactly one FYI, got $n"
  FM_PENDING_REPLY_EXISTING_CORR="$CORR" run_send "$FB" "$HOME_DIR" "$LOG" "$OUT" \
    domain --from-captain "$CAPTAIN_TEXT" || fail "queued-note retry should succeed"
  n=$(find "$HOME_DIR/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d ' ')
  [ "$n" = 1 ] || fail "queued FYI must not be duplicated"
  id=$(find "$HOME_DIR/state/inbox" -maxdepth 1 -name '*.note')
  id=${id##*/}; id=${id%.note}
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-inbox.sh" drain --ack "$id" >/dev/null || fail "FYI acknowledgement failed"
  FM_PENDING_REPLY_EXISTING_CORR="$CORR" run_send "$FB" "$HOME_DIR" "$LOG" "$OUT" \
    domain --from-captain "$CAPTAIN_TEXT" || fail "handled-note retry should succeed"
  assert_contains "$(cat "$OUT")" "first_mate=told" "handled FYI still proves notification"
  n=$(find "$HOME_DIR/state/inbox" -name '*.note' | wc -l | tr -d ' ')
  [ "$n" = 1 ] || fail "handled FYI must not be duplicated"
  pass "captain-direct: retry repairs a missing FYI without duplicating queued or handled notes"
}

test_non_ascii_captain_message() {
  local rec delivered before
  setup non-ascii
  run_send "$FB" "$HOME_DIR" "$LOG" "$OUT" domain --from-captain "👍" || fail "emoji delivery failed"
  CORR=$(sed -n 's/^corr=//p' "$OUT")
  rec=$(fm_pending_reply_path "$HOME_DIR/state" "$CORR")
  [ "$(fm_pending_reply_get "$rec" request_summary)" = 'from the captain:' ] || fail "expected sanitized emoji-only summary"
  delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
  before=$(inbox_count)
  FM_PENDING_REPLY_NOW=$((delivered + 600)) fm_pending_reply_tick_one "$HOME_DIR/state" "$CORR" idle
  FM_PENDING_REPLY_NOW=$((delivered + 1200)) fm_pending_reply_maybe_escalate "$HOME_DIR/state" "$CORR" || true
  [ "$(fm_pending_reply_get "$rec" resolved_via)" = captain-direct ] || fail "emoji-only message must settle as captain-direct"
  [ -z "$(fm_pending_reply_get "$rec" recovery_attempted_epoch)" ] || fail "emoji-only message must not attempt recovery"
  [ -z "$(fm_pending_reply_get "$rec" escalated_epoch)" ] || fail "emoji-only message must not escalate"
  [ "$(inbox_count)" = "$before" ] || fail "emoji-only message must not repost"
  pass "captain-direct: non-ASCII-only message settles without recovery or escalation"
}

test_accented_captain_message_keeps_its_letters() {
  local rec
  setup accented
  run_send "$FB" "$HOME_DIR" "$LOG" "$OUT" domain --from-captain "Mas você tem certeza de que essa conta pessoa física dá para fazer pagamento via API? 👍" \
    || fail "accented delivery failed"
  CORR=$(sed -n 's/^corr=//p' "$OUT")
  rec=$(fm_pending_reply_path "$HOME_DIR/state" "$CORR")
  # Fleet Town shows this summary as the captain's words: accents stay, the emoji goes, and the
  # 120-character cap counts characters, so no letter is cut in half
  [ "$(fm_pending_reply_get "$rec" request_summary)" = 'from the captain: Mas você tem certeza de que essa conta pessoa física dá para fazer pagamento via API?' ] \
    || fail "accents were stripped: $(fm_pending_reply_get "$rec" request_summary)"
  [ "$(fm_pending_reply_summarize "$(printf 'é%.0s' $(seq 1 200))" | perl -CSD -ne 'print length')" = 120 ] \
    || fail "the cap must count characters"
  # plain ASCII stays as typed, backticks and carets included
  # shellcheck disable=SC2016 # Literal backticks are the input under test.
  [ "$(fm_pending_reply_summarize 'run `npm test` ^2')" = 'run `npm test` ^2' ] \
    || fail "ASCII backticks or carets were dropped"
  # without perl the old ASCII filter and the plain cap still give a summary, never an empty one
  # shellcheck disable=SC2329 # the stub shadows perl for the call inside the same substitution
  [ "$(perl() { return 127; }; fm_pending_reply_summarize "from the captain: $(printf 'x%.0s' $(seq 1 200))")" = "from the captain: $(printf 'x%.0s' $(seq 1 99))..." ] \
    || fail "the no-perl fallback lost the summary"
  pass "captain-direct: an accented message keeps its letters in the pending-reply summary"
}

test_ledger_retention() {
  setup retention
  FM_CAPTAIN_DIRECT_NOW=1000000 deliver_captain
  FM_CAPTAIN_DIRECT_NOW=1604800 expect_suppressed "corr at the retention boundary" "Follow up on corr=$CORR please."
  FM_CAPTAIN_DIRECT_NOW=1604801 expect_sent "corr after retention" "Follow up on corr=$CORR please."
  [ ! -e "$HOME_DIR/state/captain-direct/$CORR" ] || fail "echo lookup must prune an expired ledger entry"
  [ ! -e "$HOME_DIR/state/captain-direct/$CORR.text" ] || fail "echo lookup must prune expired captain words"
  pass "captain-direct: correlation matching expires after seven days without another captain send"
}

setup_remote() {
  local rh target eid
  setup "$1"
  rh="$TMP_ROOT/$1/remote"
  eid=0123456789abcdef0123456789abcdef
  target="127.0.0.1-9:$eid"
  mkdir -p "$rh/state/parent-route" "$rh/bin" "$HOME_DIR/data"
  printf 'domain\n' > "$rh/.fm-secondmate-home"
  printf '# remote fixture\n' > "$rh/AGENTS.md"
  fm_write_meta "$rh/state/parent-route/domain.meta" \
    "window=$target" "worktree=-" "project=-" "backend=stream" "stream_hub=http://127.0.0.1:9" \
    "stream_endpoint_id=$eid" "endpoint_task_id=domain" "harness=deck"
  fm_write_meta "$HOME_DIR/state/domain.meta" \
    "window=$target" "endpoint_task_id=domain" "harness=deck" "kind=secondmate" \
    "mode=secondmate" "remote_host=remote-mac" "remote_root=/remote/root" \
    "remote_backend=stream" "remote_stream_hub=http://127.0.0.1:9" \
    "remote_stream_endpoint_id=$eid" "remote_target=$target"
  printf '%s\n' "- domain - test domain (host: remote-mac; root: /remote/root; home: $rh; scope: testing; projects: alpha; added 2026-08-02)" \
    > "$HOME_DIR/data/secondmates.md"
  cat > "$FB/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
shift 2
remote_home=$(perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$3")
args=()
while IFS= read -r -d '' a; do args+=("$a"); done \
  < <(perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$4")
env -u FM_STREAM_HUB -u FM_STREAM_TOKEN FM_HOME="$remote_home" FM_ROOT_OVERRIDE="$FM_REMOTE_CODE_ROOT" \
  "$FM_REMOTE_CODE_ROOT/bin/${args[0]}" "${args[@]:1}" || exit $?
[ "${FM_FAKE_SSH_AMBIGUOUS:-0}" = 0 ] || exit 255
SH
  chmod +x "$FB/fake-ssh"
}

remote_send() {
  env PATH="$FB:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_SEND_LOG="$LOG" FM_SEND_SETTLE=0 \
    FM_SSH_BIN="$FB/fake-ssh" FM_REMOTE_CODE_ROOT="$ROOT" \
    "$SEND" domain --from-captain "$CAPTAIN_TEXT" > "$OUT" 2> "$OUT.err"
}

test_unknown_delivery_never_escalates() {
  local rec rh count created before
  setup_remote unknown-delivery
  rh="$TMP_ROOT/unknown-delivery/remote"
  if FM_FAKE_SSH_AMBIGUOUS=1 remote_send; then
    fail "lost remote completion must report an unconfirmed send"
  fi
  rec=$(find "$HOME_DIR/state/pending-replies" -maxdepth 1 -type f ! -name '.*' | head -1)
  [ -n "$rec" ] || fail "unconfirmed captain send must keep its pending record: $(cat "$OUT.err")"
  CORR=${rec##*/}
  created=$(fm_pending_reply_get "$rec" created_epoch)
  [ "$(fm_pending_reply_get "$rec" phase)" = delivery_unknown ] || fail "expected unknown delivery"
  [ -z "$(fm_pending_reply_get "$rec" delivered_epoch)" ] || fail "unknown delivery must not be confirmed"
  count=$(find "$rh/state/parent-route/domain.inbox" -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "ambiguous remote attempts must deduplicate"
  FM_PENDING_REPLY_NOW=$((created + 1200)) fm_pending_reply_tick_one "$HOME_DIR/state" "$CORR" unknown
  FM_PENDING_REPLY_NOW=$((created + 2400)) fm_pending_reply_maybe_escalate "$HOME_DIR/state" "$CORR" || true
  [ "$(fm_pending_reply_get "$rec" phase)" = delivery_unknown ] || fail "captain record must remain retryable while unconfirmed"
  [ -z "$(fm_pending_reply_get "$rec" recovery_attempted_epoch)" ] || fail "unconfirmed captain send must never recover"
  [ -z "$(fm_pending_reply_get "$rec" escalated_epoch)" ] || fail "unconfirmed captain send must never escalate"
  [ ! -s "$HOME_DIR/state/domain.status" ] || fail "unconfirmed captain send must not open a blocked decision"
  FM_PENDING_REPLY_EXISTING_CORR="$CORR" remote_send || fail "same-corr remote resend failed: $(cat "$OUT.err")"
  assert_contains "$(cat "$OUT")" "corr=$CORR" "resend must preserve correlation"
  assert_contains "$(cat "$OUT")" "first_mate=told" "confirmed resend must notify the parent"
  count=$(find "$rh/state/parent-route/domain.inbox" -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "same-corr remote resend must not duplicate delivery"
  printf 'working: corr=%s handled captain direction\n' "$CORR" > "$HOME_DIR/state/domain.status"
  fm_pending_reply_tick_one "$HOME_DIR/state" "$CORR" idle
  [ "$(fm_pending_reply_get "$rec" resolved_via)" = status ] || fail "correlated resolution must win after resend"
  before=$(find "$HOME_DIR/state/pending-replies" -maxdepth 1 -type f ! -name '.*' | sort)
  if FM_FAKE_SSH_AMBIGUOUS=1 remote_send; then
    fail "second lost remote completion must be unconfirmed"
  fi
  rec=$(find "$HOME_DIR/state/pending-replies" -maxdepth 1 -type f ! -name '.*' | sort | grep -Fvx "$before")
  [ -n "$rec" ] || fail "expected another unknown-delivery record"
  CORR=${rec##*/}
  printf 'working: corr=%s handled captain direction\n' "$CORR" >> "$HOME_DIR/state/domain.status"
  fm_pending_reply_tick_one "$HOME_DIR/state" "$CORR" unknown
  [ "$(fm_pending_reply_get "$rec" resolved_via)" = status ] || fail "correlated line must resolve even an unconfirmed delivery"
  pass "captain-direct: unknown delivery never escalates, resends safely, and resolves from correlated reports"
}

test_delivery_tells_first_mate_once
test_echoes_are_suppressed
test_corrections_and_unrelated_steers_are_sent
test_correction_refused_with_from_captain
test_pending_reply_never_reposts
test_notification_failure_retry
test_non_ascii_captain_message
test_accented_captain_message_keeps_its_letters
test_ledger_retention
test_unknown_delivery_never_escalates
