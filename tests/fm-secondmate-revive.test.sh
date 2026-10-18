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
#     remote endpoint that is gone is recovered through fm-control
#     recover-missing like a local one, within the same budget;
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
  *" --model "*)
    [ ! -f "$FM_HOME/control-stop-on-switch" ] || : > "$FM_HOME/state/$1.held-stopped"
    ;;
esac
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
id=$1
while [ "$#" -gt 0 ]; do
  if [ "$1" = --model ]; then
    printf 'model=%s\n' "$2" >> "$FM_HOME/state/$id.meta"
    break
  fi
  shift
done
echo "relaunched $id harness=deck"
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

assert_shared_relaunch_count() {  # <case-dir> <count>
  local dir=$1 expected=$2
  printf '#!/usr/bin/env bash\nprintf "{}\\n"\n' > "$dir/report"
  chmod +x "$dir/report"
  DECK_STATE="$dir/deck" FM_DREAM_REPORT="$dir/report" FM_DREAM_NO_MISTAKES_DB="$dir/absent.sqlite" \
    FM_DREAM_NOW="$(date +%s)" FM_DREAM_SKIP_ZIGGY_WAIT=1 FM_DREAM_MIN_FREE_GB=0 \
    python3 "$ROOT/bin/fm_dream.py" run --home "$dir/home" --only collect > "$dir/collect.json" \
    || fail "collecting the two-lane heal log failed"
  python3 - "$dir" "$expected" <<'PY' || fail "shared relaunch logs or nightly count differ from completed actions"
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
expected = int(sys.argv[2])
completed = [line for line in (root / 'home/state/secondmate-revive.log').read_text().splitlines()
             if ' relaunched ' in line]
assert len(completed) == expected, completed
assert all('inner monologue (supervisor) and conversation lane' in line for line in completed), completed
assert len((root / 'home/control-calls').read_text().splitlines()) == expected
result = json.loads((root / 'collect.json').read_text())
assert result['steps']['collect']['revives'] == expected, result
PY
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

test_a_lane_failing_on_its_model_is_moved_to_a_healthy_mates_model() {
  local dir st
  dir=$(new_case model-switch)
  add_local_mate "$dir" pat fm-deck-worker >/dev/null
  add_local_mate "$dir" sib fm-deck-worker >/dev/null
  add_local_mate "$dir" sib2 fm-deck-worker >/dev/null
  add_local_mate "$dir" minority fm-deck-worker >/dev/null
  printf 'model=codex/flaky-model\n' >> "$dir/home/state/pat.meta"
  printf 'model=codex/steady-model\n' >> "$dir/home/state/sib.meta"
  printf 'model=codex/steady-model\n' >> "$dir/home/state/sib2.meta"
  printf 'model=codex/other-model\n' >> "$dir/home/state/minority.meta"
  st="$dir/home/state/pat.status"
  printf 'blocked [key=supervisor-failing-pat]: pat supervisor is failing every turn (3 consecutive): model gateway request failed (HTTP 502), since 2026-10-18T02:28:25Z; nothing handed to it is being acted on\n' > "$st"
  scan "$dir"
  [ "$(calls "$dir" | grep -c '^pat relaunch ')" = 1 ] || fail "the failing lane is relaunched first: $(calls "$dir")"
  FM_HOME="$dir/home" FM_SECONDMATE_REVIVE_CONFIRM_SECS=0 FM_LANE_HEAL_GRACE_SECS=0 "$dir/bin/fm-secondmate-revive.sh" scan
  calls "$dir" | grep '^pat relaunch ' | tail -1 | grep -q -- '--model codex/steady-model --note ' \
    || fail "a lane still failing on a model-service error is moved to the model a healthy mate runs: $(calls "$dir")"
  [ "$(grep -c 'lane-heal:pat:' "$dir/home/state/.wake-queue" 2>/dev/null || echo 0)" = 0 ] || fail "the model switch is tried before anyone is told"
  FM_HOME="$dir/home" FM_SECONDMATE_REVIVE_CONFIRM_SECS=0 FM_LANE_HEAL_GRACE_SECS=0 "$dir/bin/fm-secondmate-revive.sh" scan
  [ "$(calls "$dir" | grep -c '^pat relaunch ')" = 2 ] || fail "the model is switched only once: $(calls "$dir")"
  assert_grep 'also after switching it to codex/steady-model' "$dir/home/state/.wake-queue" "the escalation says the switch was tried"
  pass "a lane failing on its model is moved once to a healthy mate's model before it is raised"
}

test_all_http_5xx_model_failures_try_the_alternate() {
  local dir code form error expected
  for form in raw gateway; do
    for code in 400 499 500 501 505 599 600; do
      dir=$(new_case "http-$form-$code")
      add_remote_mate "$dir" pat
      add_remote_mate "$dir" sib
      printf 'alive\n' > "$dir/home/remote-state"
      printf 'model=codex/flaky-model\n' >> "$dir/home/state/pat.meta"
      printf 'model=codex/steady-model\n' >> "$dir/home/state/sib.meta"
      error="HTTP $code"
      [ "$form" != gateway ] || error="model gateway request failed ($error)"
      printf 'blocked [key=supervisor-failing-pat]: %s, since a\n' "$error" > "$dir/home/state/pat.status"
      scan "$dir"
      FM_LANE_HEAL_GRACE_SECS=0 scan "$dir"
      expected=1
      if [ "$code" -ge 500 ] && [ "$code" -le 599 ]; then
        expected=2
        calls "$dir" | grep -q -- '--model codex/steady-model --note ' || fail "$error did not try the alternate model"
        assert_grep 'switched_to=codex/steady-model' "$dir/home/state/pat.lane-heal-supervisor" "$error records the switch"
        [ ! -e "$dir/home/state/.wake-queue" ] || fail "$error escalated before the switch grace"
      else
        assert_grep 'second mate pat is stuck' "$dir/home/state/.wake-queue" "$error keeps the previous escalation"
      fi
      [ "$(calls "$dir" | wc -l | tr -d ' ')" = "$expected" ] || fail "$error took the wrong recovery path: $(calls "$dir")"
    done
  done
  pass "raw and gateway HTTP 5xx failures try an alternate while other statuses escalate"
}

test_default_and_unset_sibling_models_do_not_replace_a_concrete_choice() {
  local dir id
  dir=$(new_case no-concrete-alternate)
  for id in pat defaulted unset; do
    add_local_mate "$dir" "$id" fm-deck-worker >/dev/null
  done
  printf 'model=codex/flaky-model\n' >> "$dir/home/state/pat.meta"
  printf 'model=default\n' >> "$dir/home/state/defaulted.meta"
  printf 'model=\n' >> "$dir/home/state/unset.meta"
  printf 'blocked [key=supervisor-failing-pat]: HTTP 502, since a\n' > "$dir/home/state/pat.status"
  scan "$dir"
  FM_LANE_HEAL_GRACE_SECS=0 scan "$dir"
  [ "$(calls "$dir" | grep -c '^pat relaunch ')" = 1 ] || fail "an unset/default alternate consumed another relaunch: $(calls "$dir")"
  assert_grep 'second mate pat is stuck' "$dir/home/state/.wake-queue" "no concrete alternate keeps the ordinary escalation"
  [ "$(sed -n 's/^model=//p' "$dir/home/state/pat.meta" | tail -1)" = codex/flaky-model ] || fail "the concrete model choice was cleared"
  pass "unset and default sibling models never replace a concrete choice"
}

test_only_live_siblings_without_parent_channel_lane_failures_supply_models() {
  local dir mode target tag
  for mode in dead missing unknown remote-supervisor remote-conversation; do
    dir=$(new_case "unhealthy-model-$mode")
    add_local_mate "$dir" pat fm-deck-worker >/dev/null
    printf 'model=codex/flaky-model\n' >> "$dir/home/state/pat.meta"
    case "$mode" in
      remote-*)
        add_remote_mate "$dir" sib
        printf 'alive\n' > "$dir/home/remote-state"
        tag=${mode#remote-}
        printf 'blocked [key=%s-failing-sib]: HTTP 400, since a\n' "$tag" > "$dir/home/state/sib.status"
        ;;
      *)
        target=$(add_local_mate "$dir" sib zsh)
        case "$mode" in
          missing) fm_test_fake_stream_set "$target" '{"forget": true}' ;;
          unknown) fm_test_fake_stream_foreground "$target" node ;;
        esac
        : > "$dir/home/state/sib.held-stopped"
        ;;
    esac
    printf 'model=codex/unhealthy-model\n' >> "$dir/home/state/sib.meta"
    printf 'blocked [key=supervisor-failing-pat]: HTTP 502, since a\n' > "$dir/home/state/pat.status"
    scan "$dir"
    FM_LANE_HEAL_GRACE_SECS=0 scan "$dir"
    [ "$(calls "$dir" | grep -c '^pat relaunch ')" = 1 ] || fail "$mode sibling supplied an alternate: $(calls "$dir")"
    grep 'lane-heal:pat:' "$dir/home/state/.wake-queue" | grep -q 'is stuck' || fail "no healthy alternate must escalate for $mode"
  done
  dir=$(new_case resolved-remote-model)
  add_local_mate "$dir" pat fm-deck-worker >/dev/null
  add_remote_mate "$dir" sib
  printf 'alive\n' > "$dir/home/remote-state"
  printf 'model=codex/flaky-model\n' >> "$dir/home/state/pat.meta"
  printf 'model=codex/healthy-remote\n' >> "$dir/home/state/sib.meta"
  printf 'blocked [key=supervisor-failing-sib]: old failure\nresolved [key=supervisor-failing-sib]: recovered\n' > "$dir/home/state/sib.status"
  printf 'blocked [key=supervisor-failing-pat]: HTTP 502, since a\n' > "$dir/home/state/pat.status"
  scan "$dir"
  FM_LANE_HEAL_GRACE_SECS=0 scan "$dir"
  calls "$dir" | grep -q -- '--model codex/healthy-remote --note ' || fail "a recovered live remote sibling did not qualify: $(calls "$dir")"
  pass "alternate models require alive endpoints and no open parent-channel lane failure"
}

test_both_lanes_share_the_model_switch_and_its_grace() {
  local dir tag rec switched_at
  dir=$(new_case both-lanes-model-switch)
  add_local_mate "$dir" pat fm-deck-worker >/dev/null
  add_local_mate "$dir" sib fm-deck-worker >/dev/null
  printf 'model=codex/flaky-model\n' >> "$dir/home/state/pat.meta"
  printf 'model=codex/steady-model\n' >> "$dir/home/state/sib.meta"
  printf 'blocked [key=supervisor-failing-pat]: HTTP 502, since a\nblocked [key=conversation-failing-pat]: HTTP 502, since b\n' > "$dir/home/state/pat.status"
  scan "$dir"
  assert_shared_relaunch_count "$dir" 1
  FM_LANE_HEAL_GRACE_SECS=0 scan "$dir"
  [ "$(calls "$dir" | grep -c '^pat relaunch ')" = 2 ] || fail "both lanes must share the model switch: $(calls "$dir")"
  assert_shared_relaunch_count "$dir" 2
  [ ! -e "$dir/home/state/.wake-queue" ] || fail "a lane escalated during the model switch"
  switched_at=$(sed -n 's/^model_switched=//p' "$dir/home/state/pat.lane-heal-supervisor")
  [ -n "$switched_at" ] || fail "the model switch was not recorded"
  for tag in supervisor conversation; do
    rec="$dir/home/state/pat.lane-heal-$tag"
    [ "$(sed -n 's/^relaunched=//p' "$rec")" = "$switched_at" ] || fail "$tag did not restart its grace"
    [ "$(sed -n 's/^model_switched=//p' "$rec")" = "$switched_at" ] || fail "$tag did not share the model switch"
    assert_grep 'switched_to=codex/steady-model' "$rec" "$tag records the chosen alternate"
  done
  scan "$dir"
  [ ! -e "$dir/home/state/.wake-queue" ] || fail "a lane escalated before the post-switch grace"
  FM_LANE_HEAL_GRACE_SECS=0 scan "$dir"
  [ "$(grep -c 'also after switching it to codex/steady-model' "$dir/home/state/.wake-queue")" = 2 ] || fail "both escalations must mention the switch"
  [ "$(calls "$dir" | grep -c '^pat relaunch ')" = 2 ] || fail "the shared switch was retried"
  pass "both failing lanes share one model switch, grace, and escalation context"
}

test_model_switch_admission_refusals_do_not_consume_recovery() {
  local dir mode tag target
  for mode in busy stopped fails; do
    dir=$(new_case "model-switch-$mode")
    target=$(add_local_mate "$dir" pat fm-deck-worker)
    add_local_mate "$dir" sib fm-deck-worker >/dev/null
    printf 'model=codex/flaky-model\n' >> "$dir/home/state/pat.meta"
    printf 'model=codex/steady-model\n' >> "$dir/home/state/sib.meta"
    printf 'blocked [key=supervisor-failing-pat]: HTTP 502, since a\nblocked [key=conversation-failing-pat]: HTTP 502, since b\n' > "$dir/home/state/pat.status"
    scan "$dir"
    case "$mode" in
      stopped) : > "$dir/home/control-stop-on-switch" ;;
      *) : > "$dir/home/control-$mode" ;;
    esac
    FM_LANE_HEAL_GRACE_SECS=0 scan "$dir"
    [ "$(calls "$dir" | grep -c '^pat relaunch ')" = 2 ] || fail "both lanes must share one $mode switch attempt: $(calls "$dir")"
    if [ "$mode" = fails ]; then
      [ "$(grep -c 'switching it to codex/steady-model failed:' "$dir/home/state/.wake-queue")" = 2 ] || fail "real switch failures must escalate both lanes"
      FM_LANE_HEAL_GRACE_SECS=0 scan "$dir"
      [ "$(calls "$dir" | grep -c '^pat relaunch ')" = 2 ] || fail "a failed switch was retried after escalation"
      continue
    fi
    [ ! -e "$dir/home/state/.wake-queue" ] || fail "$mode admission refusal escalated"
    for tag in supervisor conversation; do
      if [ "$mode" = stopped ]; then
        [ ! -e "$dir/home/state/pat.lane-heal-$tag" ] || fail "a deliberate stop kept $tag's healing record"
      else
        assert_grep 'escalated=0' "$dir/home/state/pat.lane-heal-$tag" "a busy switch does not escalate $tag"
        grep -q '^model_switched=' "$dir/home/state/pat.lane-heal-$tag" && fail "a busy switch consumed $tag's recovery"
      fi
    done
    if [ "$mode" = stopped ]; then
      fm_test_fake_stream_foreground "$target" zsh
      scan "$dir"
      [ -e "$dir/home/state/pat.held-stopped" ] || fail "the deliberate stop was lost"
      [ "$(calls "$dir" | grep -c '^pat relaunch ')" = 2 ] || fail "a deliberately stopped mate was retried"
    else
      rm -f "$dir/home/control-busy"
      FM_LANE_HEAL_GRACE_SECS=0 scan "$dir"
      [ "$(calls "$dir" | grep -c '^pat relaunch ')" = 3 ] || fail "a deferred switch was not retried once"
      for tag in supervisor conversation; do
        assert_grep 'switched_to=codex/steady-model' "$dir/home/state/pat.lane-heal-$tag" "the deferred $tag switch succeeded"
      done
      [ ! -e "$dir/home/state/.wake-queue" ] || fail "the deferred switch escalated on success"
    fi
  done
  pass "switch admission defers contention, honors deliberate stops, and only escalates real failures"
}

test_a_live_mate_with_a_failing_lane_is_relaunched_then_escalated_once() {
  local dir st
  dir=$(new_case failing-lane)
  add_local_mate "$dir" pat fm-deck-worker >/dev/null
  st="$dir/home/state/pat.status"
  printf 'blocked [key=supervisor-failing-pat]: pat supervisor is failing every turn (3 consecutive): model gateway request failed (HTTP 400), since 2026-10-15T23:42:00Z; nothing handed to it is being acted on\n' > "$st"
  scan "$dir"
  [ "$(calls "$dir" | grep -c '^pat relaunch ')" = 1 ] || fail "a failing lane was not relaunched first: $(calls "$dir")"
  [ "$(grep -c 'lane-heal:' "$dir/home/state/.wake-queue" 2>/dev/null || echo 0)" = 0 ] || fail "nobody is told before the relaunch had its chance"
  scan "$dir"
  [ "$(calls "$dir" | grep -c '^pat relaunch ')" = 1 ] || fail "the relaunch is tried once per episode"
  FM_HOME="$dir/home" FM_SECONDMATE_REVIVE_CONFIRM_SECS=0 FM_LANE_HEAL_GRACE_SECS=0 "$dir/bin/fm-secondmate-revive.sh" scan
  FM_HOME="$dir/home" FM_SECONDMATE_REVIVE_CONFIRM_SECS=0 FM_LANE_HEAL_GRACE_SECS=0 "$dir/bin/fm-secondmate-revive.sh" scan
  [ "$(grep -c 'lane-heal:pat:' "$dir/home/state/.wake-queue")" = 1 ] || fail "a lane still failing after the relaunch must be raised exactly once"
  assert_grep 'second mate pat is stuck: its inner monologue (supervisor) keeps failing after an automatic relaunch' "$dir/home/state/.wake-queue" "the escalation names the mate and the lane"
  assert_grep 'model gateway request failed (HTTP 400), since 2026-10-15T23:42:00Z' "$dir/home/state/.wake-queue" "the escalation carries the error and since when"
  printf 'resolved [key=supervisor-failing-pat]: pat supervisor is working again\n' >> "$st"
  scan "$dir"
  assert_grep 'second mate pat recovered' "$dir/home/state/.wake-queue" "a recovery after an escalation clears the blocker"
  [ ! -e "$dir/home/state/pat.lane-heal-supervisor" ] || fail "a recovered lane keeps no heal record"
  # It fails again later: a new episode gets its own relaunch.
  printf 'blocked [key=supervisor-failing-pat]: pat supervisor is failing every turn (3 consecutive): x, since 2026-10-16T09:00:00Z; nothing\n' >> "$st"
  scan "$dir"
  [ "$(calls "$dir" | grep -c '^pat relaunch ')" = 2 ] || fail "a new failing episode gets its own relaunch: $(calls "$dir")"
  assert_grep '--replace-live' "$dir/home/control-calls" "the lane-health relaunch replaces the live mate"
  pass "a live mate whose lane keeps failing is relaunched once, then raised once, and cleared on recovery"
}

test_a_lane_that_recovers_after_the_relaunch_is_never_raised() {
  local dir st
  dir=$(new_case healed-lane)
  add_local_mate "$dir" pat fm-deck-worker >/dev/null
  st="$dir/home/state/pat.status"
  printf 'blocked [key=conversation-failing-pat]: pat conversation is failing every turn (3 consecutive): x, since y\n' > "$st"
  scan "$dir"
  printf 'resolved [key=conversation-failing-pat]: pat conversation is answering again\n' >> "$st"
  FM_HOME="$dir/home" FM_SECONDMATE_REVIVE_CONFIRM_SECS=0 FM_LANE_HEAL_GRACE_SECS=0 "$dir/bin/fm-secondmate-revive.sh" scan
  [ "$(grep -c 'lane-heal:' "$dir/home/state/.wake-queue" 2>/dev/null || echo 0)" = 0 ] || fail "a lane the relaunch fixed must never reach the captain"
  [ ! -e "$dir/home/state/pat.lane-heal-conversation" ] || fail "a healed lane keeps no record"
  pass "a lane that the automatic relaunch fixed never reaches the captain"
}

test_each_failing_lane_is_raised_and_cleared_on_its_own() {
  local dir st
  dir=$(new_case both-lanes)
  add_local_mate "$dir" pat fm-deck-worker >/dev/null
  st="$dir/home/state/pat.status"
  { printf 'blocked [key=supervisor-failing-pat]: pat supervisor is failing every turn (3 consecutive): s-err, since a\n'
    printf 'blocked [key=conversation-failing-pat]: pat conversation is failing every turn (3 consecutive): c-err, since b\n'
  } > "$st"
  scan "$dir"
  [ "$(calls "$dir" | grep -c '^pat relaunch ')" = 1 ] || fail "two failing lanes share one relaunch: $(calls "$dir")"
  assert_shared_relaunch_count "$dir" 1
  FM_HOME="$dir/home" FM_SECONDMATE_REVIVE_CONFIRM_SECS=0 FM_LANE_HEAL_GRACE_SECS=0 "$dir/bin/fm-secondmate-revive.sh" scan
  assert_grep 'its inner monologue (supervisor) keeps failing' "$dir/home/state/.wake-queue" "the failing supervisor is raised"
  assert_grep 'its conversation lane keeps failing' "$dir/home/state/.wake-queue" "the failing conversation is raised too"
  printf 'resolved [key=supervisor-failing-pat]: pat supervisor is working again\n' >> "$st"
  scan "$dir"
  assert_grep 'second mate pat recovered: its inner monologue (supervisor) is working again' "$dir/home/state/.wake-queue" "the recovered lane is cleared"
  grep -q 'recovered: its conversation lane' "$dir/home/state/.wake-queue" && fail "one lane recovering must not clear the other"
  [ -f "$dir/home/state/pat.lane-heal-conversation" ] || fail "the still-failing lane keeps its record"
  FM_HOME="$dir/home" FM_SECONDMATE_REVIVE_CONFIRM_SECS=0 FM_LANE_HEAL_GRACE_SECS=0 "$dir/bin/fm-secondmate-revive.sh" scan
  [ "$(grep -c 'its conversation lane keeps failing' "$dir/home/state/.wake-queue")" = 1 ] || fail "the still-failing lane is raised once"
  pass "each failing lane of a mate is raised and cleared on its own"
}

test_both_lanes_share_a_failed_or_deferred_relaunch() {
  local dir mode tag rec
  for mode in fails busy; do
    dir=$(new_case "both-lanes-$mode")
    add_remote_mate "$dir" pat
    printf 'alive\n' > "$dir/home/remote-state"
    printf 'blocked [key=supervisor-failing-pat]: s-err, since a\nblocked [key=conversation-failing-pat]: c-err, since b\n' \
      > "$dir/home/state/pat.status"
    : > "$dir/home/control-$mode"
    scan "$dir"
    [ "$(calls "$dir" | wc -l | tr -d ' ')" = 1 ] || fail "two failing lanes duplicated the $mode relaunch: $(calls "$dir")"
    for tag in supervisor conversation; do
      rec="$dir/home/state/pat.lane-heal-$tag"
      if [ "$mode" = fails ]; then
        [ "$(sed -n 's/^relaunched=//p' "$rec")" -gt 0 ] || fail "$tag did not record its failed relaunch"
        assert_grep 'escalated=1' "$rec" "$tag escalates after a failed relaunch"
        grep 'lane-heal:pat:' "$dir/home/state/.wake-queue" | grep "${tag}-failing-pat" | grep -q 'did not come up within 90s' \
          || fail "$tag escalation lost the shared failure output"
      else
        assert_grep 'relaunched=0' "$rec" "a busy lifecycle action defers $tag without spending its attempt"
      fi
    done
    if [ "$mode" = fails ]; then
      scan "$dir"
      [ "$(calls "$dir" | wc -l | tr -d ' ')" = 1 ] || fail "a failed shared relaunch retried"
      [ "$(grep -c 'lane-heal:pat:' "$dir/home/state/.wake-queue")" = 2 ] || fail "each failed lane must escalate exactly once"
    else
      [ ! -e "$dir/home/state/.wake-queue" ] || fail "a busy lifecycle action escalated"
      rm -f "$dir/home/control-busy"
      scan "$dir"
      [ "$(calls "$dir" | wc -l | tr -d ' ')" = 2 ] || fail "deferred lanes did not share the next attempt"
    fi
  done
  pass "both lanes share one failed or deferred relaunch and retain separate outcomes"
}

test_lane_health_reads_only_status_appends_once_per_scan() {
  local dir st probe line expected before after delta i
  dir=$(new_case incremental-lanes)
  add_local_mate "$dir" pat fm-deck-worker >/dev/null
  st="$dir/home/state/pat.status"
  probe="$dir/status-reads"
  i=0
  while [ "$i" -lt 200 ]; do
    printf 'working: unrelated history %s\n' "$i"
    i=$((i + 1))
  done > "$st"
  line='blocked [key=supervisor-failing-pat]: HTTP 400, since 2026-10-15T23:42:00Z'
  printf '%s\n' "$line" >> "$st"
  printf 'blocked [key=conversation-failing-pat]: c-err, since b\n' >> "$st"
  before=$(wc -c < "$st" | tr -d ' ')
  FM_OPEN_DECISIONS_READ_PROBE="$probe" scan "$dir"
  [ "$(wc -l < "$probe" | tr -d ' ')" = 1 ] || fail "a scan must fold both lane keys together"
  [ "$(cut -f2 "$probe")" = "$before" ] || fail "the initial scan did not fold the status history"
  expected=$(printf '%s' "$line" | cksum | cut -d' ' -f1)
  assert_grep "episode=$expected" "$dir/home/state/pat.lane-heal-supervisor" "the exact blocked report identifies the episode"
  FM_OPEN_DECISIONS_READ_PROBE="$probe" scan "$dir"
  [ "$(wc -l < "$probe" | tr -d ' ')" = 1 ] || fail "an unchanged status log was reread"
  printf 'resolved [key=supervisor-failing-pat]: recovered\n' >> "$st"
  after=$(wc -c < "$st" | tr -d ' ')
  delta=$((after - before))
  FM_OPEN_DECISIONS_READ_PROBE="$probe" scan "$dir"
  [ "$(wc -l < "$probe" | tr -d ' ')" = 2 ] || fail "the appended resolution was not folded exactly once"
  [ "$(tail -1 "$probe" | cut -f2)" = "$delta" ] || fail "a scan reread history instead of only new appends"
  [ ! -e "$dir/home/state/pat.lane-heal-supervisor" ] || fail "the resolved lane kept its record"
  [ -e "$dir/home/state/pat.lane-heal-conversation" ] || fail "the still-open lane was cleared"
  [ "$(calls "$dir" | wc -l | tr -d ' ')" = 1 ] || fail "unchanged open episodes relaunched again"
  pass "lane health shares the incremental status fold without losing episode identity"
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
  scan "$dir"
  [ -z "$(calls "$dir")" ] || fail "a single missing reading recovered the remote mate: $(calls "$dir")"
  scan "$dir"
  case "$(calls "$dir")" in
    "rm1 recover-missing --unless-held-stopped --note "*) ;;
    *) fail "a confirmed gone remote endpoint was not recovered through fm-control: $(calls "$dir")" ;;
  esac
  [ "$(queued_revive_wakes "$dir")" = 0 ] || fail "a recovered remote endpoint woke the first mate"
  pass "a remote mate is probed on its host and relaunched or recovered there through fm-control"
}

test_legacy_remote_missing_escalations_restart_confirmation_without_resetting_spent_budgets() {
  local dir id
  dir=$(new_case remote-legacy)
  printf 'missing\n' > "$dir/home/remote-state"
  for id in rm1 held spent; do
    add_remote_mate "$dir" "$id"
    printf 'down_state=missing\nfirst_seen=1\nfailures=0\nescalated=1\nlast=\n' \
      > "$dir/home/state/$id.revive"
  done
  printf 'stopped_at=1\n' > "$dir/home/state/held.held-stopped"
  printf 'down_state=missing\nfirst_seen=1\nfailures=2\nescalated=1\nlast=host refused\n' \
    > "$dir/home/state/spent.revive"
  cp "$dir/home/state/held.revive" "$dir/held-before.revive"
  cp "$dir/home/state/spent.revive" "$dir/spent-before.revive"
  scan "$dir"
  [ -z "$(calls "$dir")" ] || fail "a legacy escalation recovered without fresh confirmation: $(calls "$dir")"
  grep -qx 'escalated=0' "$dir/home/state/rm1.revive" || fail "an unattempted legacy episode stayed escalated"
  scan "$dir"
  case "$(calls "$dir")" in
    "rm1 recover-missing --unless-held-stopped --note "*) ;;
    *) fail "an unattempted legacy remote episode was not recovered: $(calls "$dir")" ;;
  esac
  [ ! -e "$dir/home/state/rm1.revive" ] || fail "legacy recovery left its revive record"
  scan "$dir"
  [ "$(calls "$dir" | wc -l | tr -d ' ')" = 1 ] || fail "a held or spent episode was retried: $(calls "$dir")"
  cmp -s "$dir/home/state/held.revive" "$dir/held-before.revive" || fail "a deliberately stopped legacy episode was changed"
  cmp -s "$dir/home/state/spent.revive" "$dir/spent-before.revive" || fail "a spent escalation was changed"
  [ -e "$dir/home/state/held.held-stopped" ] || fail "legacy reconciliation removed a deliberate stop"
  [ "$(queued_revive_wakes "$dir")" = 0 ] || fail "legacy reconciliation queued another escalation"
  pass "legacy remote-missing escalations recover after fresh confirmation while held and spent episodes stay untouched"
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

test_recovery_between_the_scan_and_admission_is_not_a_failure() {
  local dir target worker placement
  for placement in local remote; do
    dir=$(new_case "recovered-at-admission-$placement")
    target=
    if [ "$placement" = local ]; then
      target=$(add_local_mate "$dir" sm1 zsh)
    else
      add_remote_mate "$dir" sm1
      printf 'dead\n' > "$dir/home/remote-state"
    fi
    scan "$dir"
    cp "$ROOT/bin/fm-control.sh" "$dir/bin/fm-control.real"
    cat > "$dir/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/control-calls"
: > "$FM_HOME/admission-ready"
while [ ! -e "$FM_HOME/admission-release" ]; do sleep 0.1; done
exec bash "$(dirname "$0")/fm-control.real" "$@"
SH
    chmod +x "$dir/bin/fm-control.sh"
    scan "$dir" &
    worker=$!
    fm_test_track_helper_pid "$worker"
    for _ in $(seq 100); do
      [ ! -e "$dir/home/admission-ready" ] || break
      sleep 0.1
    done
    [ -e "$dir/home/admission-ready" ] || fail "the $placement scan never reached automatic admission"
    if [ "$placement" = local ]; then
      fm_test_fake_stream_foreground "$target" fm-deck-worker
    else
      printf 'alive\n' > "$dir/home/remote-state"
    fi
    touch "$dir/home/admission-release"
    wait "$worker" || fail "the $placement scan failed after the mate recovered"
    [ ! -e "$dir/home/state/sm1.revive" ] || fail "a recovered $placement mate consumed a failed revival: $(cat "$dir/home/state/sm1.revive")"
    [ "$(queued_revive_wakes "$dir")" = 0 ] || fail "a recovered $placement mate escalated a failed revival"
    [ "$(calls "$dir" | wc -l | tr -d ' ')" = 1 ] || fail "a recovered $placement mate caused multiple control calls"
    grep -q 'sm1 is alive again' "$dir/home/state/secondmate-revive.log" || fail "the $placement admission recovery was not logged"
    scan "$dir"
    [ "$(calls "$dir" | wc -l | tr -d ' ')" = 1 ] || fail "the recovered $placement mate was retried"
  done
  pass "a mate recovered between scanning and locked admission resets its episode without a failure"
}

test_a_gone_remote_endpoint_that_will_not_come_back_escalates_once() {
  local dir
  dir=$(new_case remote-gone)
  add_remote_mate "$dir" rm1
  printf 'missing\n' > "$dir/home/remote-state"
  # The host refuses while the forgotten agent still runs there; each refusal
  # is one failed attempt, one per confirmation window.
  : > "$dir/home/control-fails"
  scan "$dir"; scan "$dir"
  [ "$(calls "$dir" | grep -c 'rm1 recover-missing')" = 1 ] \
    || fail "the first confirmed window did not make exactly one attempt: $(calls "$dir")"
  [ "$(queued_revive_wakes "$dir")" = 0 ] || fail "one failed attempt escalated before the budget was spent"
  scan "$dir"
  [ "$(calls "$dir" | grep -c 'rm1 recover-missing')" = 2 ] \
    || fail "the second window did not retry the recovery: $(calls "$dir")"
  [ "$(queued_revive_wakes "$dir")" = 1 ] || fail "a spent budget was not escalated once"
  scan "$dir"; scan "$dir"
  [ "$(calls "$dir" | grep -c 'rm1 recover-missing')" = 2 ] || fail "a spent budget kept retrying"
  [ "$(queued_revive_wakes "$dir")" = 1 ] || fail "a spent budget was escalated twice"
  grep 'secondmate-revive:rm1' "$dir/home/state/.wake-queue" | grep -q '2 automatic revivals did not' \
    || fail "the escalation did not report the attempts: $(cat "$dir/home/state/.wake-queue")"
  pass "a gone remote endpoint that will not come back costs two attempts and one escalation"
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
test_a_live_mate_with_a_failing_lane_is_relaunched_then_escalated_once
test_a_lane_failing_on_its_model_is_moved_to_a_healthy_mates_model
test_all_http_5xx_model_failures_try_the_alternate
test_default_and_unset_sibling_models_do_not_replace_a_concrete_choice
test_only_live_siblings_without_parent_channel_lane_failures_supply_models
test_both_lanes_share_the_model_switch_and_its_grace
test_model_switch_admission_refusals_do_not_consume_recovery
test_a_lane_that_recovers_after_the_relaunch_is_never_raised
test_each_failing_lane_is_raised_and_cleared_on_its_own
test_both_lanes_share_a_failed_or_deferred_relaunch
test_lane_health_reads_only_status_appends_once_per_scan
test_two_failed_revivals_escalate_once_and_stop
test_a_mate_owned_by_another_lifecycle_action_is_not_a_failure
test_remote_mate_is_probed_and_relaunched_on_its_host
test_legacy_remote_missing_escalations_restart_confirmation_without_resetting_spent_budgets
test_a_spent_budget_retries_only_the_escalation
test_one_slow_revival_does_not_delay_another_mate
test_watcher_surfaces_a_failed_revival_on_its_own
test_a_slow_mate_does_not_hold_back_later_scans_of_another
test_a_fresh_exit_keeps_its_record_while_the_control_lock_is_held
test_a_refused_held_relaunch_is_not_a_failure
test_recovery_between_the_scan_and_admission_is_not_a_failure
test_a_gone_remote_endpoint_that_will_not_come_back_escalates_once
test_watcher_revives_a_dead_mate_without_a_turn
echo "# all fm-secondmate-revive tests passed"
