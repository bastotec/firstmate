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

test_delivery_tells_first_mate_once
test_echoes_are_suppressed
test_corrections_and_unrelated_steers_are_sent
test_correction_refused_with_from_captain
test_pending_reply_never_reposts
