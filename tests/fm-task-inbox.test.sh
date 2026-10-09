#!/usr/bin/env bash
# tests/fm-task-inbox.test.sh - the per-task steering inbox
# (bin/fm-task-inbox-lib.sh) and the watcher's re-ring ladder.
#
# The inbox+doorbell design replaces typed steer payloads with durable
# sequenced records acknowledged by an atomic mv into handled/; the terminal
# carries only a constant doorbell line, and the watcher re-rings an
# unacknowledged message before escalating once as an ordinary stale wake.
# These tests pin the semantics with real processes:
#   1. A message is written durably and appears in the inbox, byte-exact
#      including newlines, with a doorbell naming the inbox glob, numeric order,
#      and handled/.
#   2. Sequencing dedups per worker lifetime: the handled mv retires a record,
#      re-acking it is a no-op, and an acknowledged sequence is never reissued.
#      The idempotent enqueue (the remote steer leg's primitive) additionally
#      dedups an exact-body re-run onto the existing record, handled or not.
#   3. Concurrent writers serialize on the sequence lock: no clobbered records.
#   4. The re-ring ladder: within grace is quiet, past grace rings, ring
#      spacing holds, a spent budget escalates exactly once, and an
#      acknowledgement resets the ladder for the next message.
#   5. A real fm-watch.sh subprocess re-rings the doorbell for an unhandled
#      aged message on an idle pane WITHOUT waking firstmate, waits on a busy
#      pane, stays silent on a healthy/empty inbox, surfaces unwritable ladder
#      bookkeeping only while its record remains unhandled, and emits exactly
#      one stale wake once the ring budget is spent.
#   6. Dead panes: the doorbell line is a shell no-op when executed by a bare
#      shell, the ring skips an agent the backend classifies dead, and the
#      watcher surfaces such a record exactly once instead of re-ringing.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-inbox)
# The doorbell line canonicalizes its paths, so keep the fixture root
# canonical too (a trailing-slash TMPDIR otherwise yields a double slash).
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Run one library function against a state dir through a subshell that sources
# the production library, so the tests exercise the executable surface rather
# than re-implementing any format knowledge here.
inbox_lib() {  # <state> <function> [args...]
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fn=$2
    shift 2
    "$fn" "$@"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$@"
}

# Task t1 is a fake stream endpoint (tests/fixtures.sh). Its launch log is the
# case's send log, so a doorbell ring is observable; its screen replays an idle
# composer unless a case points it elsewhere; and its foreground process is
# what the agent-state classifier reads (`zsh` is a dead bare shell, `claude` a
# live agent, none at all is unclassifiable).
make_watch_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  make_fake_crew_state "$fb" >/dev/null
  printf '%s\n' "$fb"
}

# t1_endpoint <state> <log> [agent|missing|-]: (re)register t1's endpoint with
# <log> as its launch log, set its foreground process (or make the hub forget
# it), and print its target.
t1_endpoint() {  # <state> <log> [agent]
  local state=$1 log=$2 agent=${3:--} target
  fm_test_stream_task "$state" t1 "$log" >/dev/null || return 1
  target=$(fm_test_stream_target_of "$state" t1)
  fm_test_fake_stream_set "$target" '{"foreground": []}'
  case "$agent" in
    -) ;;
    missing) fm_test_fake_stream_set "$target" '{"forget": true}' ;;
    *) fm_test_fake_stream_foreground "$target" "$agent" ;;
  esac
  printf '%s\n' "$target"
}

# ring_t1 <state> <log> <agent|missing|-> <record>: ring t1's doorbell through
# the production library and return its status.
ring_t1() {  # <state> <log> <agent> <record>
  local target
  target=$(t1_endpoint "$1" "$2" "$3") || return 9
  inbox_lib "$1" fm_task_inbox_ring stream "$target" "$4" fm-t1
}

# watch_bg also takes the endpoint settings FM_SEND_LOG=<log>,
# FM_FAKE_CAPTURE=<screen-file>, FM_FAKE_AGENT=<process> and
# FM_ACK_RECORD=<record> (the agent acknowledges that record when a doorbell
# is typed), applies them to t1's endpoint, and passes every other assignment
# to the watcher.
watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3 kv log=/dev/null capture='' agent=- ack='' target hook
  local envs=()
  shift 3
  for kv in "$@"; do
    case "$kv" in
      FM_SEND_LOG=*) log=${kv#*=} ;;
      FM_FAKE_CAPTURE=*) capture=${kv#*=} ;;
      FM_FAKE_AGENT=*) agent=${kv#*=} ;;
      FM_ACK_RECORD=*) ack=${kv#*=} ;;
      *) envs+=("$kv") ;;
    esac
  done
  target=$(t1_endpoint "$state" "$log" "$agent") || fail "could not register t1's endpoint"
  [ -z "$capture" ] || stream_capture "$target" "$capture"
  if [ -n "$ack" ]; then
    hook="$state/../ack-hook"
    printf '#!/bin/sh\n[ -f %s ] && mv %s %s/handled/\nexit 0\n' "'$ack'" "'$ack'" "'${ack%/*}'" > "$hook"
    chmod +x "$hook"
    fm_test_fake_stream_set "$target" "$(jq -nc --arg h "$hook" '{on_text: $h}')"
  fi
  set -- ${envs[@]+"${envs[@]}"}
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_TASK_INBOX_GRACE_SECS=1 \
    env "$@" "$WATCH" > "$out" 2>/dev/null &
}

wait_watcher_gone() {  # <pid> [limit-ticks]
  local pid=$1 limit=${2:-120} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

age_path() {  # <path>  (set mtime well past any grace under test)
  touch -t 202001010000 "$1"
}

test_write_is_durable_and_exact() {
  local state rec rec2 doorbell doorbell2 expected actual expected2 actual2 text
  state="$TMP_ROOT/write/state"; mkdir -p "$state"
  text=$'line one\nline two with  spaces\n/slash body\n\n'
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "$text") \
    || fail "inbox write failed"
  [ -f "$rec" ] || fail "inbox write printed a path that does not exist: $rec"
  case "$rec" in
    "$state/t1.inbox/001.msg") : ;;
    *) fail "first record should be 001.msg under the task inbox, got $rec" ;;
  esac
  expected="$state/expected.body"
  actual="$state/actual.body"
  printf '%s' "$text" > "$expected"
  inbox_lib "$state" fm_task_inbox_body "$rec" > "$actual" \
    || fail "record body could not be read"
  cmp -s "$expected" "$actual" \
    || fail "record body did not preserve trailing and blank-line bytes"
  rec2=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "no trailing newline") \
    || fail "second inbox write failed"
  expected2="$state/expected-no-newline.body"
  actual2="$state/actual-no-newline.body"
  printf '%s' "no trailing newline" > "$expected2"
  inbox_lib "$state" fm_task_inbox_body "$rec2" > "$actual2" \
    || fail "second record body could not be read"
  cmp -s "$expected2" "$actual2" \
    || fail "record body added a trailing newline"
  doorbell=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec")
  doorbell2=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec2")
  [ "$doorbell" = "$doorbell2" ] \
    || fail "every record in one inbox should ring the same drain-all doorbell"
  assert_contains "$doorbell" "'$state/t1.inbox'/*.msg" "doorbell should quote and name all unhandled records"
  assert_contains "$doorbell" "numeric order" "doorbell should require ordered processing"
  assert_contains "$doorbell" "'$state/t1.inbox'/handled/" "doorbell should quote and name the handled dir"
  assert_contains "$doorbell" "Firstmate instruction waiting" "doorbell should be self-describing"
  case "$doorbell" in
    *$'\n'*) fail "the doorbell must be a single line" ;;
  esac
  pass "inbox: a steer is written durably and round-trips byte-exact with a self-describing doorbell"
}

# The doorbell may land in a pane whose agent has exited, where it is a shell
# command line. Execute the real line in real shells and assert it is inert:
# exit 0, no output, and nothing in the inbox touched.
test_doorbell_is_a_shell_noop() {
  local state rec doorbell sh out before after marker
  state="$TMP_ROOT/noop/x; touch marker; #'s space/state"
  marker="$state/marker"
  mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  doorbell=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec")
  case "$doorbell" in
    ': '*) ;;
    *) fail "the doorbell must start with the shell no-op prefix, got: $doorbell" ;;
  esac
  assert_contains "$doorbell" "'\\''s space/state/t1.inbox'" \
    "the doorbell should escape an embedded single quote in its quoted path"
  before=$(ls -R "$state/t1.inbox")
  for sh in sh bash zsh; do
    command -v "$sh" >/dev/null 2>&1 || continue
    out=$(cd "$state" && "$sh" -c "$doorbell" 2>&1) \
      || fail "$sh executed the hostile-path doorbell with a non-zero status: $out"
    [ -z "$out" ] || fail "$sh produced output while executing the hostile-path doorbell: $out"
    [ ! -e "$marker" ] || fail "$sh executed shell syntax embedded in the inbox path"
  done
  # An interactive-style zsh with the line fed on stdin, the closest portable
  # stand-in for a dead pane's login shell reading typed keystrokes.
  if command -v zsh >/dev/null 2>&1; then
    out=$(cd "$state" && printf '%s\n' "$doorbell" | zsh -s 2>&1) \
      || fail "zsh reading the hostile-path doorbell from stdin failed: $out"
    [ -z "$out" ] || fail "zsh printed while reading the hostile-path doorbell: $out"
    [ ! -e "$marker" ] || fail "zsh executed shell syntax from the stdin doorbell"
  fi
  after=$(ls -R "$state/t1.inbox")
  [ "$before" = "$after" ] || fail "executing the doorbell changed the inbox:"$'\n'"$after"
  [ -f "$rec" ] || fail "executing the doorbell removed the unhandled record"
  pass "inbox: a hostile-path doorbell executes as a no-op in bare shells"
}

test_doorbell_rejects_terminal_controls() {
  local dir state rec doorbell control label log marker rc
  dir="$TMP_ROOT/control-path"
  marker="$dir/marker"
  mkdir -p "$dir"
  make_watch_stubs "$dir" >/dev/null
  for label in etx esc; do
    case "$label" in
      etx) control=$'\003' ;;
      esc) control=$'\033' ;;
    esac
    state="$dir/${control}touch marker; # $label/state"
    mkdir -p "$state"
    rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
    doorbell=
    rc=0
    doorbell=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec") || rc=$?
    [ "$rc" -ne 0 ] || fail "a $label path should make doorbell construction fail"
    [ -z "$doorbell" ] || fail "a rejected $label path emitted doorbell bytes"
    log="$dir/$label.send.log"; : > "$log"
    rc=0
    ring_t1 "$state" "$log" - "$rec" || rc=$?
    [ "$rc" = 2 ] || fail "a rejected $label path should return send-failed status 2, got $rc"
    [ ! -s "$log" ] || fail "a $label path reached the endpoint:"$'\n'"$(cat "$log")"
    [ ! -e "$marker" ] || fail "a $label path executed its crafted command"
    [ -f "$rec" ] || fail "rejecting a $label path removed the durable record"
  done
  pass "inbox: terminal-control paths are rejected without typing"
}

# fm_task_inbox_ring against a backend whose agent classifies dead or missing:
# nothing is typed and the distinct return code lets callers route to recovery.
# An unreadable endpoint still rings, so a blind classifier never starves a
# live worker.
test_ring_skips_dead_agent() {
  local dir state rec log rc
  dir="$TMP_ROOT/ring-dead"
  state="$dir/state"
  mkdir -p "$state"
  make_watch_stubs "$dir" >/dev/null
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  log="$dir/send.log"; : > "$log"
  rc=0
  ring_t1 "$state" "$log" zsh "$rec" || rc=$?
  [ "$rc" = 3 ] || fail "a dead agent should return 3 from the ring, got $rc"
  [ ! -s "$log" ] || fail "a dead pane was typed into:"$'\n'"$(cat "$log")"
  [ -f "$rec" ] || fail "skipping the ring must leave the durable record in place"
  rc=0
  ring_t1 "$state" "$log" missing "$rec" || rc=$?
  [ "$rc" = 3 ] || fail "a missing endpoint should return 3 from the ring, got $rc"
  [ ! -s "$log" ] || fail "a missing endpoint was typed into:"$'\n'"$(cat "$log")"
  [ -f "$rec" ] || fail "skipping a missing endpoint must leave the durable record in place"
  rc=0
  ring_t1 "$state" "$log" claude "$rec" || rc=$?
  [ "$rc" = 0 ] || fail "a live agent should still be rung, got $rc"
  grep -qF 'Firstmate instruction waiting' "$log" || fail "a live agent did not receive the doorbell"
  : > "$log"
  rc=0
  ring_t1 "$state" "$log" - "$rec" || rc=$?
  [ "$rc" = 0 ] || fail "an endpoint the classifier cannot see should still be rung, got $rc"
  grep -qF 'Firstmate instruction waiting' "$log" || fail "an unclassifiable endpoint did not receive the doorbell"
  pass "inbox: the ring skips dead or missing endpoints and still rings live or unclassifiable endpoints"
}

# A composer holding nothing but the doorbell itself (a swallowed Enter, here
# wrapped mid-word at the terminal width) is firstmate's own text: the ring
# submits it instead of deferring to it forever. The doorbell with anything
# after it, or other text, is still protected and skipped.
test_ring_submits_own_unsubmitted_doorbell() {
  local dir state rec log target doorbell head tail rc rows
  dir="$TMP_ROOT/ring-own-doorbell"
  state="$dir/state"
  mkdir -p "$state"
  make_watch_stubs "$dir" >/dev/null
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  doorbell=$(inbox_lib "$state" fm_task_inbox_doorbell_line "$rec")
  head=${doorbell:0:60}
  tail=${doorbell:60}
  log="$dir/send.log"
  ring_composer() {  # <rows-json>
    : > "$log"; : > "$log.keys"
    target=$(t1_endpoint "$state" "$log" fm-deck-worker) || return 9
    fm_test_fake_stream_set "$target" "$(jq -nc --argjson r "$1" '{screen_rows: $r, cursor_row: ($r | length - 1)}')"
    rc=0
    inbox_lib "$state" fm_task_inbox_ring stream "$target" "$rec" fm-t1 || rc=$?
  }
  rows=$(jq -nc --arg h "❯ $head" --arg t "$tail" '["idle since earlier", $h, $t]')
  ring_composer "$rows"
  [ "$rc" = 0 ] || fail "a composer holding only its own doorbell should count as rung, got $rc"
  grep -qx '\[key\] Enter' "$log.keys" || fail "the pending doorbell was not submitted with Enter"
  [ ! -s "$log" ] || fail "the doorbell was retyped onto its own pending copy:"$'\n'"$(cat "$log")"
  rows=$(jq -nc --arg h "❯ $doorbell$doorbell" '["idle since earlier", $h]')
  ring_composer "$rows"
  [ "$rc" = 0 ] || fail "repeated copies of the doorbell should still count as rung, got $rc"
  grep -qx '\[key\] Enter' "$log.keys" || fail "repeated pending doorbells were not submitted"
  rows=$(jq -nc --arg h "❯ $head" --arg t "$tail" '["idle since earlier", $h, $t, "Please type yes, no or the fingerprint:"]')
  ring_composer "$rows"
  [ "$rc" = 1 ] || fail "the doorbell followed by other text must stay protected, got $rc"
  [ ! -s "$log.keys" ] && [ ! -s "$log" ] || fail "text after the doorbell was touched"
  rows=$(jq -nc '["idle since earlier", "❯ a half-typed captain note"]')
  ring_composer "$rows"
  [ "$rc" = 1 ] || fail "other pending text must still skip the ring, got $rc"
  [ ! -s "$log.keys" ] && [ ! -s "$log" ] || fail "other pending text was touched"
  pass "inbox: the ring submits its own unsubmitted doorbell and still protects any other pending text"
}

test_idempotent_write_dedups_exact_body() {
  local state r1 r2 r3 r4 count text
  state="$TMP_ROOT/idem/state"; mkdir -p "$state"
  text=$'re-runnable steer\nsecond line'
  r1=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "idempotent write failed"
  [ "$r1" = "$state/t1.inbox/001.msg" ] || fail "first idempotent write should create 001.msg, got $r1"
  # Re-running the same enqueue (the safe recovery after an ambiguous remote
  # transport failure) lands on the SAME record, never a duplicate.
  r2=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "idempotent re-run failed"
  [ "$r2" = "$r1" ] || fail "an identical re-run should return the existing record, got $r2"
  count=$(find "$state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "an identical re-run must not enqueue a duplicate, found $count records"
  # A different body - two logical requests differ at least by their embedded
  # correlation token - still enqueues normally.
  r3=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 $'re-runnable steer\nsecond line changed') \
    || fail "idempotent write of a different body failed"
  [ "$r3" = "$state/t1.inbox/002.msg" ] || fail "a different body should enqueue a new record, got $r3"
  # A body the worker already acknowledged still dedups: the re-run reports
  # the handled record rather than re-delivering an instruction that was
  # already acted on.
  mv "$r1" "$state/t1.inbox/handled/"
  r4=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "idempotent re-run after the ack failed"
  [ "$r4" = "$state/t1.inbox/handled/001.msg" ] \
    || fail "a re-run of an acknowledged steer should land on the handled record, got $r4"
  count=$(find "$state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "a re-run of an acknowledged steer must not re-enqueue it, found $count unhandled records"
  pass "inbox: the idempotent enqueue dedups an exact re-run onto the same record, handled or not"
}

test_idempotent_write_follows_concurrent_ack() {
  local state rec result count text
  state="$TMP_ROOT/idem-ack-race/state"; mkdir -p "$state"
  text="acknowledge while dedup scans"
  rec=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "$text") \
    || fail "race fixture write failed"
  result=$(FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    eval "$(declare -f fm_task_inbox_body | sed "1s/fm_task_inbox_body/_original_fm_task_inbox_body/")"
    fm_task_inbox_body() {
      candidate=$1
      case "$candidate" in
        */handled/*) ;;
        *) mv "$candidate" "${candidate%/*}/handled/" || return 1
           candidate="${candidate%/*}/handled/${candidate##*/}" ;;
      esac
      _original_fm_task_inbox_body "$candidate"
    }
    fm_task_inbox_write_idempotent "$2" t1 "$3"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$state" "$text") \
    || fail "idempotent enqueue failed while acknowledgement moved its candidate"
  [ "$result" = "$state/t1.inbox/handled/${rec##*/}" ] \
    || fail "dedup did not follow the concurrently acknowledged record: $result"
  count=$(find "$state/t1.inbox" -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 1 ] || fail "acknowledgement racing dedup created a duplicate record"
  pass "inbox: idempotent enqueue follows a record concurrently moved to handled"
}

test_handled_mv_dedups_by_sequence() {
  local state r1 r2 oldest r3
  state="$TMP_ROOT/dedup/state"; mkdir -p "$state"
  r1=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "first")
  r2=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "second")
  [ "$r2" = "$state/t1.inbox/002.msg" ] || fail "second record should be 002.msg, got $r2"
  oldest=$(inbox_lib "$state" fm_task_inbox_oldest_unhandled "$state" t1)
  [ "$oldest" = "$r1" ] || fail "oldest unhandled should be 001, got $oldest"
  mv "$r1" "$state/t1.inbox/handled/"
  oldest=$(inbox_lib "$state" fm_task_inbox_oldest_unhandled "$state" t1)
  [ "$oldest" = "$r2" ] || fail "after the ack mv the oldest should advance to 002, got $oldest"
  # Re-acking the same message is a no-op: the record is already retired and
  # nothing re-lists it as unhandled.
  mv "$state/t1.inbox/001.msg" "$state/t1.inbox/handled/" 2>/dev/null \
    && fail "a second mv of an acked record should find nothing to move"
  mv "$r2" "$state/t1.inbox/handled/"
  if inbox_lib "$state" fm_task_inbox_oldest_unhandled "$state" t1 >/dev/null; then
    fail "a fully handled inbox should report no unhandled record"
  fi
  # An acknowledged sequence is never reissued, so a message is processed at
  # most once per worker lifetime even if every doorbell is duplicated.
  r3=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "third")
  [ "$r3" = "$state/t1.inbox/003.msg" ] || fail "a handled sequence was reissued: $r3"
  pass "inbox: the handled mv is the idempotent ack and sequences are never reissued"
}

test_concurrent_writers_never_clobber() {
  local state i pids=() count
  state="$TMP_ROOT/race/state"; mkdir -p "$state"
  for i in 1 2 3 4 5 6; do
    inbox_lib "$state" fm_task_inbox_write "$state" t1 "steer number $i" >/dev/null &
    pids+=($!)
  done
  for i in "${pids[@]}"; do
    wait "$i" || fail "a concurrent inbox write failed"
  done
  count=$(find "$state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
  [ "$count" = 6 ] || fail "6 concurrent writes should yield 6 records, got $count:"$'\n'"$(ls "$state/t1.inbox")"
  for i in 1 2 3 4 5 6; do
    grep -rqF "steer number $i" "$state/t1.inbox" \
      || fail "steer number $i was lost in the concurrent write race"
  done
  pass "inbox: concurrent writers serialize on the sequence lock and lose nothing"
}

test_writer_retries_after_a_vanished_lock_collision() {
  local state fakebin marker rec real_ln
  state="$TMP_ROOT/vanished-lock-race/state"
  fakebin="$TMP_ROOT/vanished-lock-race/fakebin"
  marker="$TMP_ROOT/vanished-lock-race/first-ln-failed"
  mkdir -p "$state" "$fakebin"
  real_ln=$(command -v ln)
  cat > "$fakebin/ln" <<'SH'
#!/usr/bin/env bash
set -u
if [ ! -e "$FM_FAKE_LN_MARKER" ]; then
  : > "$FM_FAKE_LN_MARKER"
  exit 1
fi
exec "$FM_REAL_LN" "$@"
SH
  chmod +x "$fakebin/ln"

  rec=$(PATH="$fakebin:$PATH" FM_REAL_LN="$real_ln" FM_FAKE_LN_MARKER="$marker" \
    inbox_lib "$state" fm_task_inbox_write "$state" t1 "steer after collision") \
    || fail "a writer abandoned an acquisition whose competing lock had already vanished"
  [ -f "$rec" ] || fail "the retry after a vanished lock collision did not write its record"
  pass "inbox: a writer retries when a competing lock vanishes after its failed claim"
}

test_ladder_writes_ignore_vanished_inbox() {
  local state rec
  state="$TMP_ROOT/vanished/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "retired task")
  rm -rf "$state/t1.inbox"
  inbox_lib "$state" fm_task_inbox_record_ring "$state" t1 "$rec" \
    || fail "ring bookkeeping should ignore a concurrently removed inbox"
  inbox_lib "$state" fm_task_inbox_record_escalated "$state" t1 "$rec" \
    || fail "escalation bookkeeping should ignore a concurrently removed inbox"
  [ ! -e "$state/t1.inbox" ] || fail "bookkeeping recreated a retired task inbox"
  pass "inbox: ladder bookkeeping ignores a concurrently removed inbox"
}

test_fire_and_forget_records_never_enter_the_ladder() {
  local state fire tracked action
  state="$TMP_ROOT/fire-and-forget/state"; mkdir -p "$state"
  fire=$(inbox_lib "$state" fm_task_inbox_write_idempotent "$state" t1 "one-shot steer" fire-and-forget)
  age_path "$fire"
  action=$(FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=0 \
    inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "a fire-and-forget record entered the re-ring ladder: $action"
  tracked=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "tracked steer")
  age_path "$tracked"
  action=$(FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=0 \
    inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "escalate $tracked 0" ] \
    || fail "a fire-and-forget record hid the later tracked steer: $action"
  [ -f "$fire" ] || fail "excluding fire-and-forget from escalation removed its durable record"
  pass "inbox: fire-and-forget records stay durable and outside the ladder"
}

test_ring_ladder_policy() {
  local state rec action
  state="$TMP_ROOT/ladder/state"; mkdir -p "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "do the thing")
  # Within grace: quiet.
  action=$(FM_TASK_INBOX_GRACE_SECS=3600 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "a fresh unhandled message inside grace should be quiet, got: $action"
  # Past grace: one ring is due.
  age_path "$rec"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "ring $rec" ] || fail "an aged unhandled message should be due a ring, got: $action"
  # A just-recorded ring holds the spacing: quiet until another grace elapses.
  inbox_lib "$state" fm_task_inbox_record_ring "$state" t1 "$rec"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "a ring within the spacing window should be quiet, got: $action"
  # Backdate the ladder: the next ring becomes due, and at the budget the
  # action turns into a single escalation.
  printf '001.msg\t1\t100\n' > "$state/t1.inbox/.ring-state"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "ring $rec" ] || fail "an aged ladder should ring again, got: $action"
  printf '001.msg\t3\t100\n' > "$state/t1.inbox/.ring-state"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "escalate $rec 3" ] || fail "a spent ring budget should escalate, got: $action"
  # Escalation fires at most once per message.
  inbox_lib "$state" fm_task_inbox_record_escalated "$state" t1 "$rec"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "an escalated message should stay quiet for recovery, got: $action"
  # The acknowledgement resets the ladder: the next message starts fresh.
  mv "$rec" "$state/t1.inbox/handled/"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = quiet ] || fail "a handled inbox should be quiet, got: $action"
  [ ! -e "$state/t1.inbox/.escalated" ] || fail "the ack should clear the escalation marker"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "next thing")
  age_path "$rec"
  action=$(FM_TASK_INBOX_GRACE_SECS=60 FM_TASK_INBOX_RING_MAX=3 inbox_lib "$state" fm_task_inbox_due_action "$state" t1)
  [ "$action" = "ring $rec" ] || fail "the next message should start a fresh ladder, got: $action"
  pass "inbox: the re-ring ladder paces by grace, escalates once, and resets on ack"
}

setup_watch_case() {  # <name> -> echoes case dir; state in <dir>/state
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state"
  make_watch_stubs "$dir" >/dev/null
  { fm_test_stream_task "$dir/state" t1; printf '%s\n' kind=ship harness=deck; } > "$dir/state/t1.meta"
  printf '%s\n' "$dir"
}

# Record a running turn the way the Pi extension does: arm the task's busy gen,
# then apply a deck-wrapper turn-start through the production busy-event writer.
mark_turn_busy() {  # <state>
  local gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$1" t1) || fail "busy arm failed"
  "$ROOT/bin/fm-busy-event.sh" apply "$1" t1 busy --gen "$gen" --source deck-wrapper --event turn-start \
    || fail "busy apply failed"
}

idle_capture() {  # <dir>
  printf '╭────╮\n│    │\n╰────╯\n' > "$1/idle.capture"
  printf '%s\n' "$1/idle.capture"
}

test_watcher_rerings_idle_pane_quietly() {
  local dir state out log pid rec
  dir=$(setup_watch_case rering)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=99
  pid=$!
  local i=0
  while [ "$i" -lt 100 ]; do
    grep -qF 'Firstmate instruction waiting' "$log" 2>/dev/null && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  grep -qF "Firstmate instruction waiting: list '$state/t1.inbox'/*.msg" "$log" \
    || { kill "$pid" 2>/dev/null; fail "the watcher never re-rang the doorbell:"$'\n'"$(cat "$log")"; }
  kill -0 "$pid" 2>/dev/null \
    || fail "a healthy re-ring must not wake firstmate (watcher exited):"$'\n'"$(cat "$out")"
  [ ! -s "$state/.wake-queue" ] \
    || { kill "$pid" 2>/dev/null; fail "a healthy re-ring queued a wake:"$'\n'"$(cat "$state/.wake-queue")"; }
  # The acknowledgement silences the ladder: no further doorbells after the mv.
  mv "$rec" "$state/t1.inbox/handled/"
  sleep 2.5
  : > "$log"
  sleep 2.5
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ ! -s "$log" ] || fail "the watcher kept ringing after the ack:"$'\n'"$(cat "$log")"
  pass "watcher: an unhandled aged message on an idle pane re-rings without waking firstmate, and the ack silences it"
}

test_watcher_waits_on_busy_pane() {
  local dir state out log pid rec
  dir=$(setup_watch_case busywait)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  mark_turn_busy "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=99
  pid=$!
  sleep 4
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ ! -s "$log" ] || fail "a busy pane should wait, not ring:"$'\n'"$(cat "$log")"
  [ ! -s "$state/.wake-queue" ] || fail "a busy wait queued a wake:"$'\n'"$(cat "$state/.wake-queue")"
  pass "watcher: a busy pane just waits - the record is durable and no doorbell is typed"
}

test_watcher_quiet_on_healthy_inbox() {
  local dir state out log pid
  dir=$(setup_watch_case healthy)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  mkdir -p "$state/t1.inbox/handled"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=99
  pid=$!
  sleep 4
  kill -0 "$pid" 2>/dev/null || fail "the watcher exited on a healthy empty inbox:"$'\n'"$(cat "$out")"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ ! -s "$log" ] || fail "an empty inbox rang a doorbell:"$'\n'"$(cat "$log")"
  [ ! -s "$state/.wake-queue" ] || fail "an empty inbox queued a wake:"$'\n'"$(cat "$state/.wake-queue")"
  pass "watcher: a healthy or empty inbox stays completely silent"
}

test_watcher_ack_silences_unwritable_ladder() {
  local dir state out log pid rec rings i=0
  dir=$(setup_watch_case ack-unwritable-ladder)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  mkdir "$state/t1.inbox/.ring-state"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_CAPTURE="$(idle_capture "$dir")" \
    FM_ACK_RECORD="$rec" FM_TASK_INBOX_RING_MAX=99
  pid=$!
  while [ "$i" -lt 100 ]; do
    [ -f "$state/t1.inbox/handled/001.msg" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  [ -f "$state/t1.inbox/handled/001.msg" ] \
    || { kill "$pid" 2>/dev/null; fail "the doorbell stub did not acknowledge the record"; }
  sleep 2
  kill -0 "$pid" 2>/dev/null \
    || fail "the watcher escalated ladder failure after the record was acknowledged:"$'\n'"$(cat "$out")"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  rings=$(grep -cF 'Firstmate instruction waiting' "$log" || true)
  [ "$rings" = 1 ] || fail "acknowledgement should silence retries, got $rings doorbells:"$'\n'"$(cat "$log")"
  [ ! -s "$state/.wake-queue" ] \
    || fail "an acknowledged record queued a bookkeeping wake:"$'\n'"$(cat "$state/.wake-queue")"
  pass "watcher: acknowledgement silences an unwritable ladder without a stale wake"
}

test_watcher_surfaces_unwritable_ladder() {
  local dir state out log pid rec rings wakes
  dir=$(setup_watch_case unwritable-ladder)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  mkdir "$state/t1.inbox/.ring-state"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=99
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "the watcher silently retried with unwritable ladder bookkeeping"; }
  rings=$(grep -cF 'Firstmate instruction waiting' "$log" || true)
  [ "$rings" = 1 ] || fail "expected one doorbell before the bookkeeping wake, got $rings:"$'\n'"$(cat "$log")"
  wakes=$(grep -cF 'steering-inbox ladder bookkeeping unwritable' "$state/.wake-queue" || true)
  [ "$wakes" = 1 ] \
    || fail "expected exactly one bookkeeping-unwritable stale wake, got $wakes:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  grep -qF "$state/t1.inbox/.ring-state cannot be written" "$state/.wake-queue" \
    || fail "the stale wake did not identify the unwritable ladder:"$'\n'"$(cat "$state/.wake-queue")"
  [ -f "$rec" ] || fail "the unhandled record disappeared during bookkeeping failure"
  grep -qF 'stale:' "$out" \
    || fail "the watcher should exit through the ordinary stale wake:"$'\n'"$(cat "$out")"
  pass "watcher: unwritable ladder bookkeeping surfaces a stale wake after the doorbell"
}

test_watcher_escalates_once_after_budget() {
  local dir state out log pid rec rings
  dir=$(setup_watch_case escalate)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_CAPTURE="$(idle_capture "$dir")" \
    FM_TASK_INBOX_RING_MAX=1
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "the watcher never escalated a spent ring budget"; }
  rings=$(grep -cF 'Firstmate instruction waiting' "$log" || true)
  [ "$rings" = 1 ] || fail "expected exactly 1 doorbell before escalation, got $rings:"$'\n'"$(cat "$log")"
  grep -qF 'unread firstmate instruction' "$state/.wake-queue" \
    || fail "the escalation should queue a stale wake naming the unread instruction:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  grep -qF "$rec" "$state/.wake-queue" \
    || fail "the stale wake should name the record path:"$'\n'"$(cat "$state/.wake-queue")"
  [ "$(grep -cF 'unread firstmate instruction' "$state/.wake-queue")" = 1 ] \
    || fail "the escalation must fire exactly once:"$'\n'"$(cat "$state/.wake-queue")"
  grep -qF 'stale:' "$out" || fail "the watcher should exit through the ordinary stale wake:"$'\n'"$(cat "$out")"
  pass "watcher: a spent ring budget emits exactly one ordinary stale wake for recovery"
}

test_watcher_dead_pane_escalates_once_without_ringing() {
  local dir state out log pid rec
  dir=$(setup_watch_case dead-pane)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_CAPTURE="$(idle_capture "$dir")" \
    FM_FAKE_AGENT=zsh FM_TASK_INBOX_RING_MAX=99
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "the watcher never surfaced a dead pane's unhandled instruction"; }
  [ ! -s "$log" ] || fail "a dead pane was typed into:"$'\n'"$(cat "$log")"
  [ "$(grep -cF 'unread firstmate instruction' "$state/.wake-queue" 2>/dev/null || true)" = 1 ] \
    || fail "a dead pane should surface exactly one stale wake:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  grep -qF "agent has exited" "$state/.wake-queue" \
    || fail "the stale wake should say the agent has exited:"$'\n'"$(cat "$state/.wake-queue")"
  grep -qF "$rec" "$state/.wake-queue" || fail "the stale wake should name the record path"
  [ -f "$rec" ] || fail "the durable record must survive for recovery"
  [ "$(cat "$state/t1.inbox/.escalated")" = "${rec##*/}" ] \
    || fail "the escalation marker should suppress further surfacing of this record"
  [ ! -e "$state/t1.inbox/.ring-state" ] || fail "a dead pane must not enter the re-ring ladder"
  # The ladder is capped: nothing further is due for this record, so no later
  # poll rings the dead pane or queues a second wake.
  [ "$(inbox_lib "$state" fm_task_inbox_due_action "$state" t1)" = quiet ] \
    || fail "a dead pane already surfaced must be quiet on later polls"
  pass "watcher: a positively dead pane is never typed into and surfaces exactly one stale wake"
}

test_watcher_dead_pane_ignores_stale_busy_state() {
  local dir state out log pid rec
  dir=$(setup_watch_case dead-pane-busy)
  state="$dir/state"; out="$dir/watch.out"; log="$dir/send.log"; : > "$log"
  mark_turn_busy "$state"
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" t1 "please continue")
  age_path "$rec"
  watch_bg "$state" "$dir/fakebin" "$out" \
    FM_SEND_LOG="$log" FM_FAKE_CAPTURE="$(idle_capture "$dir")" \
    FM_FAKE_AGENT=zsh FM_TASK_INBOX_RING_MAX=99
  pid=$!
  wait_watcher_gone "$pid" \
    || { kill "$pid" 2>/dev/null; fail "stale busy state hid a dead pane's unhandled instruction"; }
  [ ! -s "$log" ] || fail "a busy-marked dead pane was typed into:"$'\n'"$(cat "$log")"
  [ "$(grep -cF 'unread firstmate instruction' "$state/.wake-queue" 2>/dev/null || true)" = 1 ] \
    || fail "a busy-marked dead pane should surface exactly once:"$'\n'"$(cat "$state/.wake-queue" 2>/dev/null)"
  [ -f "$rec" ] || fail "the durable record must survive stale busy-state recovery"
  [ "$(cat "$state/t1.inbox/.escalated")" = "${rec##*/}" ] \
    || fail "stale busy-state recovery should suppress repeated surfacing"
  pass "watcher: dead-pane recovery overrides stale busy state"
}

test_write_is_durable_and_exact
test_doorbell_is_a_shell_noop
test_doorbell_rejects_terminal_controls
test_ring_skips_dead_agent
test_ring_submits_own_unsubmitted_doorbell
test_idempotent_write_dedups_exact_body
test_idempotent_write_follows_concurrent_ack
test_handled_mv_dedups_by_sequence
test_concurrent_writers_never_clobber
test_writer_retries_after_a_vanished_lock_collision
test_ladder_writes_ignore_vanished_inbox
test_fire_and_forget_records_never_enter_the_ladder
test_ring_ladder_policy
test_watcher_rerings_idle_pane_quietly
test_watcher_waits_on_busy_pane
test_watcher_quiet_on_healthy_inbox
test_watcher_ack_silences_unwritable_ladder
test_watcher_surfaces_unwritable_ladder
test_watcher_escalates_once_after_budget
test_watcher_dead_pane_escalates_once_without_ringing
test_watcher_dead_pane_ignores_stale_busy_state
