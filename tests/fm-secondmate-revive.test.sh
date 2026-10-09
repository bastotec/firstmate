#!/usr/bin/env bash
# tests/fm-secondmate-revive.test.sh - the mid-session second-mate revival owned
# by bin/fm-secondmate-revive.sh and run by bin/fm-watch.sh.
#
# Session start was the only place a dead second mate came back, so a mate that
# died mid-session stayed down until somebody looked. The guarantees under test:
#   - a dead local endpoint (bare shell) is relaunched, and a missing local
#     endpoint is recovered, through bin/fm-control.sh - never anything lower;
#   - a down reading is acted on only after it was seen on two scans, so one
#     transient reading never relaunches anything;
#   - a live mate, a non-secondmate record, an unknown reading, and a mate
#     stopped on purpose (state/<id>.held-stopped) are left alone;
#   - two failed revivals queue exactly ONE check wake for the captain and stop
#     the retries until the mate is seen alive again;
#   - a remote route is probed on its host, relaunched there when dead, and a
#     remote endpoint that is gone is escalated, since only its host can
#     recover it;
#   - the real watcher runs the scan on its own cadence without blocking its
#     liveness beacon, so a dead mate comes back with no first-mate turn.
#
# bin/ is copied into each case with bin/fm-control.sh and bin/fm-on.sh replaced
# by recording stubs, so the lifecycle actions the scan chooses are observed
# without launching agents. Endpoints are fake stream endpoints on the suite's
# stub hub (tests/fixtures.sh), read through the real stream adapter.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-secondmate-revive)
fm_test_fake_stream_ensure || fail "the fake stream hub did not start"

# new_case <name>: a home whose bin/ records fm-control and fm-on calls.
new_case() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config"
  cp -R "$ROOT/bin" "$dir/bin"
  cat > "$dir/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/control-calls"
[ ! -f "$FM_HOME/control-sleep" ] || sleep "$(cat "$FM_HOME/control-sleep")"
[ ! -f "$FM_HOME/control-sleep-$1" ] || sleep "$(cat "$FM_HOME/control-sleep-$1")"
case " $* " in
  *" --unless-held-stopped "*)
    if [ -e "$FM_HOME/state/$1.held-stopped" ]; then
      echo "error: task $1 was stopped on purpose (state/$1.held-stopped); relaunch it without --unless-held-stopped to bring it back" >&2
      exit 1
    fi
    ;;
esac
if [ -f "$FM_HOME/control-busy" ]; then
  echo "error: another lifecycle action is already running for task $1" >&2
  exit 1
fi
if [ -f "$FM_HOME/control-fails" ]; then
  echo "warning: composer state stayed 'unknown'" >&2
  echo "error: the replacement agent for $1 did not come up within 90s" >&2
  exit 1
fi
echo "relaunched $1 harness=deck"
SH
  cat > "$dir/bin/fm-on.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/on-calls"
[ -f "$FM_HOME/remote-unreachable" ] && exit 255
cat "$FM_HOME/remote-state"
SH
  chmod +x "$dir/bin/fm-control.sh" "$dir/bin/fm-on.sh"
  printf '%s\n' "$dir"
}

# add_local_mate <case-dir> <id> <foreground>
add_local_mate() {
  local dir=$1 id=$2 fg=$3 target
  fm_test_stream_secondmate_meta "$dir/home/state/$id.meta" "$dir/$id-home" alpha deck \
    || fail "could not register $id's endpoint"
  target=$(fm_test_stream_target_of "$dir/home/state" "$id")
  fm_test_fake_stream_foreground "$target" "$fg"
  printf '%s\n' "$target"
}

add_remote_mate() {  # <case-dir> <id>
  local dir=$1 id=$2
  printf '%s\n' "window=remote:$id" "endpoint_task_id=$id" "kind=secondmate" "harness=deck" \
    "home=/remote/$id" "remote_host=fakehost" "remote_root=/remote/fm" > "$dir/home/state/$id.meta"
}

scan() {  # <case-dir>
  FM_HOME="$1/home" FM_SECONDMATE_REVIVE_CONFIRM_SECS=0 "$1/bin/fm-secondmate-revive.sh" scan
}

calls() {  # <case-dir>
  cat "$1/home/control-calls" 2>/dev/null || true
}

queued_revive_wakes() {  # <case-dir>
  if [ -f "$1/home/state/.wake-queue" ]; then
    grep -c 'secondmate-revive:' "$1/home/state/.wake-queue" || true
  else
    echo 0
  fi
}

test_dead_local_mate_is_relaunched_after_a_confirmed_reading() {
  local dir
  dir=$(new_case dead)
  add_local_mate "$dir" sm1 zsh >/dev/null
  scan "$dir" || fail "the first scan failed"
  [ -z "$(calls "$dir")" ] || fail "a single down reading relaunched the mate: $(calls "$dir")"
  scan "$dir" || fail "the second scan failed"
  case "$(calls "$dir")" in
    "sm1 relaunch --unless-held-stopped --note "*) ;;
    *) fail "a confirmed dead mate was not relaunched through fm-control: $(calls "$dir")" ;;
  esac
  [ ! -e "$dir/home/state/sm1.revive" ] || fail "a successful revival left its revive record behind"
  grep -q 'revived sm1' "$dir/home/state/secondmate-revive.log" \
    || fail "a successful revival was not logged"
  [ "$(queued_revive_wakes "$dir")" = 0 ] || fail "a successful revival woke the first mate"
  pass "a dead local second mate is relaunched through fm-control after two readings"
}

test_missing_local_mate_is_recovered() {
  local dir target
  dir=$(new_case missing)
  target=$(add_local_mate "$dir" sm1 fm-deck-worker)
  fm_test_fake_stream_set "$target" '{"forget": true}'
  scan "$dir"; scan "$dir"
  case "$(calls "$dir")" in
    "sm1 recover-missing --unless-held-stopped --note "*) ;;
    *) fail "a confirmed missing mate was not recovered through fm-control: $(calls "$dir")" ;;
  esac
  pass "a missing local second mate is recovered through fm-control recover-missing"
}

test_live_unknown_held_and_non_secondmate_records_are_left_alone() {
  local dir target
  dir=$(new_case quiet)
  add_local_mate "$dir" live fm-deck-worker >/dev/null
  add_local_mate "$dir" odd node >/dev/null
  add_local_mate "$dir" held zsh >/dev/null
  printf 'stopped_at=1\n' > "$dir/home/state/held.held-stopped"
  fm_test_stream_task "$dir/home/state" crew > "$dir/home/state/crew.meta" || fail "crew endpoint"
  printf 'kind=ship\nharness=deck\n' >> "$dir/home/state/crew.meta"
  target=$(fm_test_stream_target_of "$dir/home/state" crew)
  fm_test_fake_stream_foreground "$target" zsh
  printf 'stopped_at=1\n' > "$dir/home/state/live.held-stopped"
  scan "$dir"; scan "$dir"; scan "$dir"
  [ -z "$(calls "$dir")" ] || fail "a scan acted on a mate it must leave alone: $(calls "$dir")"
  [ ! -e "$dir/home/state/live.held-stopped" ] \
    || fail "a mate seen alive kept its deliberate-stop marker"
  [ -e "$dir/home/state/held.held-stopped" ] || fail "a held mate lost its marker while down"
  pass "live, ambiguous, held, and non-secondmate records are left alone"
}

test_two_failed_revivals_escalate_once_and_stop() {
  local dir target
  dir=$(new_case failing)
  target=$(add_local_mate "$dir" sm1 zsh)
  : > "$dir/home/control-fails"
  scan "$dir"; scan "$dir"
  [ "$(calls "$dir" | wc -l | tr -d ' ')" = 1 ] || fail "the first confirmed reading did not try once: $(calls "$dir")"
  [ "$(queued_revive_wakes "$dir")" = 0 ] || fail "one failed revival escalated before its budget"
  FM_HOME="$dir/home" FM_SECONDMATE_REVIVE_CONFIRM_SECS=3600 "$dir/bin/fm-secondmate-revive.sh" scan
  [ "$(calls "$dir" | wc -l | tr -d ' ')" = 1 ] || fail "a failed revival retried without a new confirmation window"
  scan "$dir"
  [ "$(calls "$dir" | wc -l | tr -d ' ')" = 2 ] || fail "the second attempt did not run: $(calls "$dir")"
  [ "$(queued_revive_wakes "$dir")" = 1 ] || fail "two failed revivals did not queue exactly one wake"
  grep 'secondmate-revive:sm1' "$dir/home/state/.wake-queue" | grep -q 'did not come up within 90s' \
    || fail "the escalation did not carry the failure that decided it: $(cat "$dir/home/state/.wake-queue")"
  grep 'secondmate-revive:sm1' "$dir/home/state/.wake-queue" | grep -q 'warning:' \
    && fail "the escalation reported a warning instead of the failure"
  scan "$dir"; scan "$dir"; scan "$dir"
  [ "$(calls "$dir" | wc -l | tr -d ' ')" = 2 ] || fail "an escalated mate kept being relaunched"
  [ "$(queued_revive_wakes "$dir")" = 1 ] || fail "an escalated mate woke the first mate again"
  # Seen alive again, the budget resets for a later death.
  fm_test_fake_stream_foreground "$target" fm-deck-worker
  scan "$dir"
  [ ! -e "$dir/home/state/sm1.revive" ] || fail "a mate seen alive kept its revive record"
  rm -f "$dir/home/control-fails"
  fm_test_fake_stream_foreground "$target" zsh
  scan "$dir"; scan "$dir"
  [ "$(calls "$dir" | wc -l | tr -d ' ')" = 3 ] || fail "a later death was not revived after recovery: $(calls "$dir")"
  pass "two failed revivals queue one wake, stop retrying, and reset once the mate is alive"
}

test_a_mate_owned_by_another_lifecycle_action_is_not_a_failure() {
  local dir
  dir=$(new_case busy)
  add_local_mate "$dir" sm1 zsh >/dev/null
  : > "$dir/home/control-busy"
  scan "$dir"; scan "$dir"; scan "$dir"; scan "$dir"
  [ "$(queued_revive_wakes "$dir")" = 0 ] \
    || fail "a relaunch already running elsewhere was escalated as a failed revival"
  rm -f "$dir/home/control-busy"
  scan "$dir"
  [ "$(calls "$dir" | tail -1 | cut -d' ' -f1-2)" = "sm1 relaunch" ] \
    || fail "the mate was not revived once the other action finished: $(calls "$dir")"
  pass "a mate held by another lifecycle action is retried later, not escalated"
}

test_remote_mate_is_probed_and_relaunched_on_its_host() {
  local dir
  dir=$(new_case remote)
  add_remote_mate "$dir" rm1
  printf 'dead\n' > "$dir/home/remote-state"
  scan "$dir"; scan "$dir"
  grep -q 'rm1 fm-remote-secondmate-control.sh state rm1' "$dir/home/on-calls" \
    || fail "the remote mate was not probed on its host"
  case "$(calls "$dir")" in
    "rm1 relaunch --unless-held-stopped --note "*) ;;
    *) fail "a confirmed dead remote mate was not relaunched through fm-control: $(calls "$dir")" ;;
  esac
  : > "$dir/home/control-calls"
  : > "$dir/home/remote-unreachable"
  scan "$dir"; scan "$dir"
  [ -z "$(calls "$dir")" ] || fail "an unreachable host was treated as a dead mate"
  rm -f "$dir/home/remote-unreachable"
  printf 'missing\n' > "$dir/home/remote-state"
  scan "$dir"; scan "$dir"
  [ -z "$(calls "$dir")" ] || fail "a gone remote endpoint was acted on from the primary"
  [ "$(queued_revive_wakes "$dir")" = 1 ] || fail "a gone remote endpoint was not escalated once"
  scan "$dir"
  [ "$(queued_revive_wakes "$dir")" = 1 ] || fail "a gone remote endpoint was escalated twice"
  pass "a remote mate is probed and relaunched on its host, and a gone remote endpoint escalates once"
}

test_a_spent_budget_retries_only_the_escalation() {
  local dir
  dir=$(new_case unwritable)
  add_local_mate "$dir" sm1 zsh >/dev/null
  : > "$dir/home/control-fails"
  mkdir "$dir/home/state/.wake-queue"
  scan "$dir"; scan "$dir"; scan "$dir"
  [ "$(calls "$dir" | wc -l | tr -d ' ')" = 2 ] || fail "the budget did not stop at two attempts: $(calls "$dir")"
  scan "$dir"; scan "$dir"; scan "$dir"
  [ "$(calls "$dir" | wc -l | tr -d ' ')" = 2 ] \
    || fail "an unpublished escalation let the scan keep relaunching: $(calls "$dir")"
  rmdir "$dir/home/state/.wake-queue"
  scan "$dir"
  [ "$(queued_revive_wakes "$dir")" = 1 ] || fail "the escalation was not published once the queue was writable"
  [ "$(calls "$dir" | wc -l | tr -d ' ')" = 2 ] || fail "publishing the escalation relaunched the mate again"
  pass "a spent budget retries only its escalation, never another revival"
}

test_one_slow_revival_does_not_delay_another_mate() {
  local dir started elapsed
  dir=$(new_case parallel)
  add_local_mate "$dir" sm1 zsh >/dev/null
  add_local_mate "$dir" sm2 zsh >/dev/null
  printf '3\n' > "$dir/home/control-sleep"
  scan "$dir"
  started=$(date +%s)
  scan "$dir"
  elapsed=$(( $(date +%s) - started ))
  [ "$(calls "$dir" | wc -l | tr -d ' ')" = 2 ] || fail "both dead mates were not revived: $(calls "$dir")"
  [ "$elapsed" -lt 6 ] || fail "the mates were revived one after another (${elapsed}s)"
  pass "each mate is revived on its own, so one slow relaunch does not delay another"
}

test_watcher_surfaces_a_failed_revival_on_its_own() {
  local dir watcher i
  dir=$(new_case surface)
  add_local_mate "$dir" sm1 zsh >/dev/null
  : > "$dir/home/control-fails"
  scan "$dir"; scan "$dir"; scan "$dir"
  [ "$(queued_revive_wakes "$dir")" = 1 ] || fail "the failed revival was not queued"
  FM_HOME="$dir/home" FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=999999 FM_SECONDMATE_REVIVE_INTERVAL=999999 \
    "$dir/bin/fm-watch.sh" > "$dir/watch.out" 2> "$dir/watch.err" &
  watcher=$!
  i=0
  while kill -0 "$watcher" 2>/dev/null && [ "$i" -lt 300 ]; do sleep 0.05; i=$((i + 1)); done
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  grep -q 'check: secondmate revival failed: sm1' "$dir/watch.out" \
    || fail "the watcher did not wake the first mate for the failed revival: $(cat "$dir/watch.out") $(cat "$dir/watch.err")"
  pass "the watcher wakes the first mate for a failed revival with nothing else happening"
}

test_a_slow_mate_does_not_hold_back_later_scans_of_another() {
  local dir slow i
  dir=$(new_case slow-scan)
  add_local_mate "$dir" sm1 zsh >/dev/null
  printf '8\n' > "$dir/home/control-sleep-sm1"
  scan "$dir"
  scan "$dir" &
  slow=$!
  i=0
  while ! grep -q 'reviving sm1' "$dir/home/state/secondmate-revive.log" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.05; i=$((i + 1))
  done
  add_local_mate "$dir" sm2 zsh >/dev/null
  scan "$dir"; scan "$dir"
  grep -q '^sm2 relaunch ' "$dir/home/control-calls" 2>/dev/null \
    || fail "a slow revival of one mate held back another mate's revival"
  kill -0 "$slow" 2>/dev/null || fail "the slow revival finished too early to prove anything"
  wait "$slow"
  [ "$(grep -c '^sm1 relaunch ' "$dir/home/control-calls")" = 1 ] \
    || fail "an overlapping scan relaunched the slow mate twice: $(calls "$dir")"
  pass "a slow revival of one mate never holds back later scans of another"
}

test_a_fresh_exit_keeps_its_record_while_the_control_lock_is_held() {
  local dir holder
  dir=$(new_case held-lock)
  add_local_mate "$dir" sm1 fm-deck-worker >/dev/null
  printf 'stopped_at=1\n' > "$dir/home/state/sm1.held-stopped"
  sleep 30 &
  holder=$!
  mkdir "$dir/home/state/.control-sm1.lock"
  printf '%s\n' "$holder" > "$dir/home/state/.control-sm1.lock/pid"
  scan "$dir"
  [ -e "$dir/home/state/sm1.held-stopped" ] \
    || fail "a deliberate-stop record was withdrawn while a lifecycle action held the mate's control lock"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  rm -rf "$dir/home/state/.control-sm1.lock"
  scan "$dir"
  [ ! -e "$dir/home/state/sm1.held-stopped" ] || fail "a live mate kept a stale deliberate-stop record"
  pass "a deliberate-stop record is withdrawn only under the mate's control lock"
}

test_a_refused_held_relaunch_is_not_a_failure() {
  local dir
  dir=$(new_case held-refused)
  add_local_mate "$dir" sm1 zsh >/dev/null
  scan "$dir"
  # The deliberate exit lands after the scan's own record check: model it by
  # writing the record only once fm-control is invoked, so the refusal comes
  # from fm-control's check under the mate's control lock.
  mv "$dir/bin/fm-control.sh" "$dir/bin/fm-control.real"
  cat > "$dir/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
: > "$FM_HOME/state/$1.held-stopped"
exec bash "$(dirname "$0")/fm-control.real" "$@"
SH
  chmod +x "$dir/bin/fm-control.sh"
  scan "$dir"; scan "$dir"; scan "$dir"
  [ "$(calls "$dir" | wc -l | tr -d ' ')" = 1 ] || fail "a deliberately stopped mate was relaunched again: $(calls "$dir")"
  [ "$(queued_revive_wakes "$dir")" = 0 ] || fail "a deliberate stop was escalated as a failed revival"
  [ -e "$dir/home/state/sm1.held-stopped" ] || fail "the deliberate-stop record was lost"
  pass "a relaunch refused because the mate was stopped on purpose is not a failure"
}

test_a_gone_remote_endpoint_is_reported_without_claiming_attempts() {
  local dir
  dir=$(new_case remote-gone)
  add_remote_mate "$dir" rm1
  printf 'missing\n' > "$dir/home/remote-state"
  scan "$dir"; scan "$dir"
  grep 'secondmate-revive:rm1' "$dir/home/state/.wake-queue" | grep -q 'no automatic revival was tried' \
    || fail "a gone remote endpoint did not say no revival was tried: $(cat "$dir/home/state/.wake-queue")"
  grep 'secondmate-revive:rm1' "$dir/home/state/.wake-queue" | grep -q 'automatic revivals did not' \
    && fail "a gone remote endpoint claimed revival attempts that never ran"
  pass "a gone remote endpoint is reported without claiming revival attempts"
}

test_watcher_revives_a_dead_mate_without_a_turn() {
  local dir watcher i beat_before beat_after advanced=0
  dir=$(new_case watcher)
  add_local_mate "$dir" sm1 zsh >/dev/null
  # The stub relaunch takes long enough to prove the watcher does not wait on it.
  cat > "$dir/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
sleep 4
printf '%s\n' "$*" >> "$FM_HOME/control-calls"
echo "relaunched $1 harness=deck"
SH
  chmod +x "$dir/bin/fm-control.sh"
  FM_HOME="$dir/home" FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=999999 \
    FM_SECONDMATE_REVIVE_INTERVAL=1 FM_SECONDMATE_REVIVE_CONFIRM_SECS=1 \
    "$dir/bin/fm-watch.sh" > "$dir/watch.out" 2> "$dir/watch.err" &
  watcher=$!
  i=0
  while [ ! -s "$dir/home/state/sm1.revive" ] && [ ! -s "$dir/home/control-calls" ] && [ "$i" -lt 200 ]; do
    sleep 0.05; i=$((i + 1))
  done
  [ -e "$dir/home/state/.last-watcher-beat" ] || fail "the watcher never beat: $(cat "$dir/watch.err")"
  beat_before=$(stat -c %Y "$dir/home/state/.last-watcher-beat" 2>/dev/null || stat -f %m "$dir/home/state/.last-watcher-beat")
  i=0
  while [ ! -s "$dir/home/control-calls" ] && [ "$i" -lt 600 ]; do
    beat_after=$(stat -c %Y "$dir/home/state/.last-watcher-beat" 2>/dev/null || stat -f %m "$dir/home/state/.last-watcher-beat")
    [ "$beat_after" -le "$beat_before" ] || advanced=1
    sleep 0.05; i=$((i + 1))
  done
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  case "$(calls "$dir")" in
    "sm1 relaunch --unless-held-stopped --note "*) ;;
    *) fail "the watcher did not revive the dead mate: $(calls "$dir") $(cat "$dir/watch.err")" ;;
  esac
  [ "$advanced" = 1 ] || fail "the watcher beacon stalled behind the revival"
  pass "the watcher revives a dead second mate on its own cadence without blocking"
}

test_dead_local_mate_is_relaunched_after_a_confirmed_reading
test_missing_local_mate_is_recovered
test_live_unknown_held_and_non_secondmate_records_are_left_alone
test_two_failed_revivals_escalate_once_and_stop
test_a_mate_owned_by_another_lifecycle_action_is_not_a_failure
test_remote_mate_is_probed_and_relaunched_on_its_host
test_a_spent_budget_retries_only_the_escalation
test_one_slow_revival_does_not_delay_another_mate
test_watcher_surfaces_a_failed_revival_on_its_own
test_a_slow_mate_does_not_hold_back_later_scans_of_another
test_a_fresh_exit_keeps_its_record_while_the_control_lock_is_held
test_a_refused_held_relaunch_is_not_a_failure
test_a_gone_remote_endpoint_is_reported_without_claiming_attempts
test_watcher_revives_a_dead_mate_without_a_turn
echo "# all fm-secondmate-revive tests passed"
