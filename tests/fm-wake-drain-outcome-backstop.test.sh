#!/usr/bin/env bash
# tests/fm-wake-drain-outcome-backstop.test.sh - executable regressions for the
# drain backstop that presents a task's newest captain-facing status event once,
# even when no queue row carried it.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-drain-outcome-backstop-tests)

set_mtime() {  # <epoch> <file>
  perl -e 'utime($ARGV[0], $ARGV[0], $ARGV[1]) or exit 1' "$1" "$2"
}

backstop_body() {  # <drain-output>
  awk '
    /^STATUS OUTCOME BACKSTOP \(/ { in_section=1; next }
    in_section && /^(OPEN DECISIONS|RECORD DIVERGENCE|UNREAD STATUS|WAKE_ACK_REQUIRED)/ { exit }
    in_section { print }
  ' "$1"
}

test_uncovered_keyless_captain_events_surface_on_the_next_main_drain() {
  local dir state out body old
  dir=$(make_case uncovered-keyless)
  state="$dir/state"
  out="$dir/drain.out"
  old=$(( $(date +%s) - 20 ))

  printf 'done: PR https://example.test/3346 checks green\n' > "$state/done-task.status"
  printf 'blocked: release credential unavailable\n' > "$state/blocked-task.status"
  printf 'needs-decision: choose REST or RPC\n' > "$state/decision-task.status"
  set_mtime "$old" "$state/done-task.status"
  set_mtime "$old" "$state/blocked-task.status"
  set_mtime "$old" "$state/decision-task.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "main drain failed for uncovered keyless captain events"
  grep -F 'STATUS OUTCOME BACKSTOP (' "$out" >/dev/null \
    || fail "uncovered keyless events produced no outcome backstop: $(cat "$out")"
  body=$(backstop_body "$out")
  case "$body" in *'done-task done: PR https://example.test/3346 checks green'*) ;; *) fail "keyless done event did not surface in the backstop: $body" ;; esac
  grep -F 'blocked-task blocked: release credential unavailable' "$out" >/dev/null \
    || fail "keyless blocked event did not surface through OPEN DECISIONS: $(cat "$out")"
  grep -F 'decision-task needs-decision: choose REST or RPC' "$out" >/dev/null \
    || fail "keyless needs-decision event did not surface through OPEN DECISIONS: $(cat "$out")"
  pass "a newest keyless done, blocked, or needs-decision event surfaces on the next drain"
}

test_routine_latest_events_stay_silent() {
  local dir state out
  dir=$(make_case routine)
  state="$dir/state"
  out="$dir/drain.out"

  printf 'working: rebased onto merged #76\n' > "$state/working.status"
  printf 'paused: waiting for the scheduled release window\n' > "$state/paused.status"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "main drain failed for routine latest events"
  [ ! -s "$out" ] || fail "routine latest events broke the silent drain contract: $(cat "$out")"
  pass "routine latest events stay silent"
}

test_successful_backstop_is_idempotent_without_consuming_delayed_annotation() {
  local dir state first_out second_out signal_out
  dir=$(make_case idempotent-receipt)
  state="$dir/state"
  first_out="$dir/first.out"
  second_out="$dir/second.out"
  signal_out="$dir/signal.out"

  printf 'done: keyless completion awaiting recovery\n' > "$state/receipt-task.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$first_out" \
    || fail "first keyless backstop drain failed"
  grep -F 'receipt-task done: keyless completion awaiting recovery' "$first_out" >/dev/null \
    || fail "first drain did not surface the keyless completion: $(cat "$first_out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$second_out" \
    || fail "second keyless backstop drain failed"
  [ ! -s "$second_out" ] \
    || fail "a successful backstop presentation repeated unchanged: $(cat "$second_out")"

  append_wake "$state" signal receipt-task.status 'signal: receipt-task.status' \
    || fail "could not publish the delayed signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$signal_out" 2>/dev/null \
    || fail "delayed-signal drain failed"
  grep -F 'latest wake-EVENT observed at drain, not current state: receipt-task.status: done: keyless completion awaiting recovery' "$signal_out" >/dev/null \
    || fail "the backstop receipt consumed the delayed signal annotation: $(cat "$signal_out")"
  pass "backstop receipts prevent repeats without consuming delayed signal annotations"
}

test_output_failure_does_not_commit_the_backstop_receipt() {
  local dir state fakebin out retry_out real_cat
  dir=$(make_case output-failure)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/failed.out"
  retry_out="$dir/retry.out"
  real_cat=$(command -v cat)
  mkdir -p "$fakebin"

  printf 'done: retry after the output consumer fails\n' > "$state/output-task.status"
  cat > "$fakebin/cat" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  "$state"/.status-presentation.prepared.*) exit 1 ;;
esac
exec "$real_cat" "\$@"
SH
  chmod +x "$fakebin/cat"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "the top-level empty-queue drain changed its compatibility exit on an output failure"
  [ ! -s "$out" ] || fail "the failed output consumer received unexpected bytes: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$retry_out" \
    || fail "backstop retry failed after the output consumer recovered"
  grep -F 'output-task done: retry after the output consumer fails' "$retry_out" >/dev/null \
    || fail "the output failure consumed the backstop receipt: $(cat "$retry_out")"
  pass "a failed output consumer leaves the backstop unacknowledged for retry"
}

test_receipt_commit_failure_repeats_the_already_presented_backstop() {
  local dir state fakebin out retry_out final_out real_mv
  dir=$(make_case receipt-commit-failure)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/failed.out"
  retry_out="$dir/retry.out"
  final_out="$dir/final.out"
  real_mv=$(command -v mv)
  mkdir -p "$fakebin"

  printf 'done: presentation precedes its durable receipt\n' > "$state/atomic-task.status"
  cat > "$fakebin/mv" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do last=\$arg; done
if [ "\${last:-}" = "$state/.status-presentation-cursor" ]; then exit 1; fi
exec "$real_mv" "\$@"
SH
  chmod +x "$fakebin/mv"

  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "the top-level empty-queue drain changed its compatibility exit on a receipt failure"
  grep -F 'atomic-task done: presentation precedes its durable receipt' "$out" >/dev/null \
    || fail "receipt failure prevented the prepared backstop presentation: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$retry_out" \
    || fail "backstop retry failed after receipt storage recovered"
  grep -F 'atomic-task done: presentation precedes its durable receipt' "$retry_out" >/dev/null \
    || fail "the uncommitted backstop did not retry after storage recovered: $(cat "$retry_out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$final_out" \
    || fail "post-recovery idempotence drain failed"
  [ ! -s "$final_out" ] \
    || fail "the successfully committed retry repeated: $(cat "$final_out")"
  pass "receipt failure may repeat a presented backstop but cannot lose it"
}

test_rejected_decision_line_surfaces_once_through_backstop() {
  local dir state first_out second_out
  dir=$(make_case rejected-decision)
  state="$dir/state"
  first_out="$dir/first.out"
  second_out="$dir/second.out"

  printf 'blocked [key=bad/value]: credential missing\n' > "$state/rejected.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$first_out" \
    || fail "rejected-decision drain failed"
  grep -F 'rejected blocked [key=bad/value]: credential missing' "$first_out" >/dev/null \
    || fail "captain-facing rejected decision was lost: $(cat "$first_out")"
  if grep -F 'OPEN DECISIONS' "$first_out" >/dev/null; then
    fail "malformed decision key entered the open-decision fold: $(cat "$first_out")"
  fi
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$second_out" \
    || fail "second rejected-decision drain failed"
  [ ! -s "$second_out" ] \
    || fail "rejected decision backstop repeated unchanged: $(cat "$second_out")"
  pass "captain-facing decisions rejected by the fold surface once"
}

test_overbound_routine_event_stays_silent() {
  local dir state out
  dir=$(make_case overbound-routine-event)
  state="$dir/state"
  out="$dir/drain.out"

  perl -e 'print "working: ", "x" x 70000, "\n"' > "$state/oversized.status"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "main drain failed for an over-bound routine event"
  [ ! -s "$out" ] \
    || fail "unclassifiable over-bound routine event was presented: $(cat "$out")"
  pass "an over-bound unclassifiable routine event stays silent"
}

test_backstop_output_is_bounded() {
  local dir state out old i payload count longest
  dir=$(make_case bounded-output)
  state="$dir/state"
  out="$dir/drain.out"
  old=$(( $(date +%s) - 20 ))
  payload=$(printf '%0300d' 0)
  i=1
  while [ "$i" -le 30 ]; do
    printf 'done: completion-%02d %s\n' "$i" "$payload" > "$state/task-$i.status"
    set_mtime "$old" "$state/task-$i.status"
    i=$((i + 1))
  done

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "main drain failed for bounded output"
  grep -F 'STATUS OUTCOME BACKSTOP:' "$out" | grep -F 'more omitted (byte cap)' >/dev/null \
    || fail "an over-budget backstop did not report bounded omission: $(cat "$out")"
  count=$(backstop_body "$out" | grep -c '^task-' || true)
  [ "$count" -gt 0 ] && [ "$count" -lt 30 ] \
    || fail "backstop byte cap presented an unexpected task count: $count"
  longest=$(backstop_body "$out" | awk '{ if (length > max) max=length } END { print max + 0 }')
  [ "$longest" -le 219 ] || fail "a backstop item exceeded its 219-character budget: $longest"
  pass "the outcome backstop caps each item and its total task output deterministically"
}

test_uncovered_keyless_captain_events_surface_on_the_next_main_drain
test_routine_latest_events_stay_silent
test_successful_backstop_is_idempotent_without_consuming_delayed_annotation
test_output_failure_does_not_commit_the_backstop_receipt
test_receipt_commit_failure_repeats_the_already_presented_backstop
test_rejected_decision_line_surfaces_once_through_backstop
test_overbound_routine_event_stays_silent
test_backstop_output_is_bounded
