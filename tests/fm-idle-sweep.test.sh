#!/usr/bin/env bash
# tests/fm-idle-sweep.test.sh - the watcher-run idle-worker sweep owned by
# bin/fm-idle-sweep.sh.
#
# A home kept done, dead, failed and silently blocked worker records for weeks
# because its cleanup ran only on a model heartbeat and a refusal was never
# followed up. The guarantees under test:
#   - a done worker is cleaned up through bin/fm-teardown.sh, never --force,
#     and a retired-backend refusal goes to fm-retire-endpoint.sh --finished;
#   - any other refusal, and every failed, long-blocked or dead worker, becomes
#     exactly one captain hold carrying a full retire-or-retry card;
#   - working workers, workers still inside their quiet bound, and workers the
#     captain already holds or deferred are left alone;
#   - a raised worker is not raised again until its ledger changes;
#   - a main home queues one check wake per scan that raised anything;
#   - record-less live endpoints are closed through --orphan;
#   - a second mate whose own sweep is missing or stale is escalated once per
#     episode, and an ssh transport failure proves nothing.
#
# bin/ is copied into each case with the crew-state, teardown, retirement,
# captain-hold and fm-on scripts replaced by recording stubs driven by files
# in the case home, so the decisions the sweep makes are observed directly.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-idle-sweep)

new_case() {  # <name> -> case dir; its home is <dir>/home
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config"
  cp -R "$ROOT/bin" "$dir/bin"
  cat > "$dir/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_HOME/crew-state-calls"
cat "$FM_HOME/crew/$1" 2>/dev/null || echo 'state: unknown · source: none · no fixture'
SH
  cat > "$dir/bin/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/teardown-calls"
if [ -f "$FM_HOME/refuse/$1" ]; then cat "$FM_HOME/refuse/$1" >&2; exit 1; fi
rm -f "$FM_HOME/state/$1.meta"
SH
  cat > "$dir/bin/fm-retire-endpoint.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/retire-calls"
case "$1" in
  --list-orphans) cat "$FM_HOME/orphans" 2>/dev/null; exit 0 ;;
  --finished) rm -f "$FM_HOME/state/$2.meta"; exit 0 ;;
  --orphan)
    if [ -f "$FM_HOME/orphan-refused" ]; then
      echo 'REFUSED: unlanded work remains (open PR)' >&2
      exit 1
    fi
    exit 0 ;;
esac
SH
  cat > "$dir/bin/fm-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  open|deferred) [ -f "$FM_HOME/unreadable/$1-$2" ] && exit 2 ;;
esac
case "$1" in
  open) [ -f "$FM_HOME/held/$2" ] && exit 0; exit 1 ;;
  deferred) [ -f "$FM_HOME/deferred/$2" ] && exit 0; exit 1 ;;
  hold)
    id=$2; shift 2
    card= reason= title= origin=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --card-file) card=$2; shift ;;
        --reason) reason=$2; shift ;;
        --title) title=$2; shift ;;
        --origin) origin=$2; shift ;;
        --repo) shift ;;
      esac
      shift
    done
    printf '%s\n' "$id" >> "$FM_HOME/hold-attempts"
    case "$reason" in *'('*|*')'*) echo 'reason must not contain parentheses' >&2; exit 1 ;; esac
    [ -f "$FM_HOME/hold-unavailable" ] && exit 1
    [ -f "$FM_HOME/closed/$id" ] && { echo 'task is already closed' >&2; exit 1; }
    case "$id" in idle-*) [ -n "$title" ] || exit 1 ;; esac
    printf '%s\n' "$id" >> "$FM_HOME/hold-calls"
    mkdir -p "$FM_HOME/cards"
    cp "$card" "$FM_HOME/cards/$id.json"
    printf '%s\n' "$reason" > "$FM_HOME/cards/$id.reason"
    printf '%s\n' "$origin" > "$FM_HOME/cards/$id.origin"
    ;;
esac
SH
  cat > "$dir/bin/fm-on.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/on-calls"
[ -f "$FM_HOME/remote-unreachable" ] && exit 255
cat "$FM_HOME/remote-summary" 2>/dev/null || exit 1
SH
  chmod +x "$dir"/bin/fm-crew-state.sh "$dir"/bin/fm-teardown.sh \
    "$dir"/bin/fm-retire-endpoint.sh "$dir"/bin/fm-captain-hold.sh "$dir"/bin/fm-on.sh
  mkdir -p "$dir/home/crew" "$dir/home/refuse" "$dir/home/held" "$dir/home/deferred" "$dir/home/closed" "$dir/home/unreadable"
  printf '%s\n' "$dir"
}

age_file() {  # <path> <seconds-ago>
  python3 -c 'import os,sys,time; t=time.time()-int(sys.argv[2]); os.utime(sys.argv[1],(t,t))' "$1" "$2"
}

# add_worker <dir> <id> <crew-state-line> <seconds-quiet>
add_worker() {
  local dir=$1 id=$2 line=$3 quiet=$4
  fm_write_meta "$dir/home/state/$id.meta" "kind=ship" "worktree=$dir/pool/1/firstmate"
  printf 'working: started\n' > "$dir/home/state/$id.status"
  age_file "$dir/home/state/$id.status" "$quiet"
  printf '%s\n' "$line" > "$dir/home/crew/$id"
}

sweep() {  # <dir> [args...]
  local dir=$1
  shift
  FM_HOME="$dir/home" "$dir/bin/fm-idle-sweep.sh" "$@"
}

calls() {  # <dir> <file>
  cat "$dir/home/$2" 2>/dev/null || true
}

test_done_workers_are_cleaned_up_without_force() {
  local dir
  dir=$(new_case done-workers)
  add_worker "$dir" shipped 'state: done · source: run-step · run passed: PR merged/closed' 7200
  add_worker "$dir" retired-tmux 'state: done · source: run-step · run passed: PR merged/closed' 7200
  printf "warning: endpoint x is on the retired 'tmux' backend, which firstmate can no longer close\n" \
    > "$dir/home/refuse/retired-tmux"
  add_worker "$dir" fresh-done 'state: done · source: run-step · run passed: PR merged/closed' 60

  sweep "$dir" scan --now || fail "scan failed"

  assert_absent "$dir/home/state/shipped.meta" "a done worker was not cleaned up"
  assert_absent "$dir/home/state/retired-tmux.meta" "a retired-backend done worker was not retired"
  assert_present "$dir/home/state/fresh-done.meta" "a just-finished worker was cleaned up before its owner's turn"
  assert_contains "$(calls "$dir" retire-calls)" "--finished retired-tmux" \
    "a retired-backend refusal should go to the finished retirement"
  if grep -q -- --force "$dir/home/teardown-calls"; then
    fail "the sweep passed --force to cleanup: $(calls "$dir" teardown-calls)"
  fi
  [ ! -s "$dir/home/hold-calls" ] || fail "a cleaned-up worker was raised: $(calls "$dir" hold-calls)"
  [ "$(jq -r '.workers[] | select(.id=="shipped") | .action' "$dir/home/state/idle-sweep.json")" = cleaned ] \
    || fail "the summary does not record the cleanup: $(cat "$dir/home/state/idle-sweep.json")"
  pass "fm-idle-sweep: done workers are cleaned up through the guarded paths, never forced"
}

test_refusals_and_idle_workers_become_one_decision_each() {
  local dir card
  dir=$(new_case decisions)
  add_worker "$dir" unlanded 'state: done · source: run-step · run passed: PR merged/closed' 7200
  printf 'REFUSED: task unlanded has uncommitted changes (dirty copy)\n' > "$dir/home/refuse/unlanded"
  add_worker "$dir" broke 'state: failed · source: run-step · run failed (test step)' 90000
  add_worker "$dir" waiting 'state: blocked · source: status-log · needs a token' 90000
  add_worker "$dir" vanished 'state: unknown · source: none · backend target gone: hub:abc' 90000
  add_worker "$dir" just-blocked 'state: blocked · source: status-log · needs a token' 600
  add_worker "$dir" busy 'state: working · source: pane · harness busy' 90000
  add_worker "$dir" unreachable 'state: unknown · source: none · backend unreachable' 90000
  add_worker "$dir" asked 'state: failed · source: run-step · run failed' 90000
  : > "$dir/home/held/asked"
  add_worker "$dir" parked-wait 'state: paused · source: status-log · waiting on CI' 90000
  : > "$dir/home/deferred/parked-wait"

  sweep "$dir" scan --now || fail "scan failed"

  [ "$(sort "$dir/home/hold-calls" | tr '\n' ' ')" = "broke unlanded vanished waiting " ] \
    || fail "wrong set of workers raised: $(calls "$dir" hold-calls)"
  assert_present "$dir/home/state/unlanded.meta" "a refused cleanup removed the record"
  card="$dir/home/cards/unlanded.json"
  assert_contains "$(jq -r '.options[0].label' "$card")" "Clean it up" "a refused cleanup should offer cleaning it up"
  assert_contains "$(jq -r '.situation' "$card")" "uncommitted changes" "the card should carry the refusal"
  for id in broke vanished; do
    [ "$(jq -r '.recommended' "$dir/home/cards/$id.json")" = 1 ] || fail "$id should recommend retiring"
    assert_contains "$(jq -r '[.options[].label]|join(",")' "$dir/home/cards/$id.json")" "Retire it,Retry it" \
      "$id should offer retire or retry"
  done
  [ "$(jq -r '.recommended' "$dir/home/cards/waiting.json")" = 2 ] || fail "a stalled worker should recommend retrying"
  assert_contains "$(cat "$dir/home/cards/broke.reason")" 'quiet 25h' "the hold reason should include quiet time"
  assert_contains "$(cat "$dir/home/cards/broke.reason")" 'run failed test step' "the hold reason should preserve detail without parentheses"
  [ "$(jq -r '.workers[] | select(.id=="unreachable") | .class' "$dir/home/state/idle-sweep.json")" = settling ] \
    || fail "an unavailable backend was classified as a dead worker"
  if grep -qx asked "$dir/home/crew-state-calls"; then
    fail "a worker already held for the captain was re-read"
  fi
  assert_contains "$(cat "$dir/home/state/.wake-queue")" "idle-sweep:" "a main home should queue one decision wake"
  [ "$(grep -c 'idle-sweep:' "$dir/home/state/.wake-queue")" = 1 ] || fail "more than one decision wake was queued"
  pass "fm-idle-sweep: refusals and idle workers become one retire-or-retry decision each; active, recent and held ones are left"
}

test_a_raised_worker_is_raised_again_only_after_its_ledger_changes() {
  local dir
  dir=$(new_case raised)
  add_worker "$dir" broke 'state: failed · source: run-step · run failed' 90000

  sweep "$dir" scan --now || fail "first scan failed"
  printf 'state: unknown · source: none · backend target gone\n' > "$dir/home/crew/broke"
  sweep "$dir" scan --now || fail "second scan failed"
  [ "$(grep -c . "$dir/home/hold-calls")" = 1 ] || fail "an unchanged worker was raised twice: $(calls "$dir" hold-calls)"
  [ "$(jq -r '.workers[0].class' "$dir/home/state/idle-sweep.json")" = raised ] \
    || fail "an unchanged raised worker should list as raised"

  printf 'failed: second attempt failed\n' >> "$dir/home/state/broke.status"
  age_file "$dir/home/state/broke.status" 90000
  sweep "$dir" scan --now || fail "third scan failed"
  [ "$(grep -c . "$dir/home/hold-calls")" = 2 ] || fail "a worker whose ledger changed was not raised again"

  touch "$dir/home/state/.last-idle-sweep"
  printf 'failed: third\n' >> "$dir/home/state/broke.status"
  age_file "$dir/home/state/broke.status" 90000
  sweep "$dir" scan || fail "cadence-gated scan failed"
  [ "$(grep -c . "$dir/home/hold-calls")" = 2 ] || fail "a scan inside its cadence still ran"
  pass "fm-idle-sweep: a raised worker waits for its ledger to change, and scans keep their cadence"
}

test_reassigned_slots_cannot_supply_completion() {
  local dir
  dir=$(new_case reassigned)
  add_worker "$dir" stale 'state: done · source: run-step · new owner completed' 90000
  add_worker "$dir" claimant 'state: done · source: run-step · run passed' 7200
  mkdir -p "$dir/pool/1/firstmate"
  printf 'task=claimant\nhome=%s\n' "$dir/home" > "$dir/pool/1/.fm-slot-owner"

  sweep "$dir" scan --now || fail "scan failed"

  assert_present "$dir/home/state/stale.meta" "a reassigned task was closed using the claimant's completion"
  assert_absent "$dir/home/state/claimant.meta" "the actual claimant was not cleaned up"
  [ "$(calls "$dir" teardown-calls)" = claimant ] || fail "cleanup touched the stale task"
  [ "$(calls "$dir" hold-calls)" = stale ] || fail "the stale task did not get a decision"
  [ "$(jq -r '.workers[] | select(.id=="stale") | .class' "$dir/home/state/idle-sweep.json")" = dead ] \
    || fail "the stale task was not classified as dead"
  if grep -qx stale "$dir/home/crew-state-calls"; then fail "the stale task read the claimant's run"; fi
  pass "fm-idle-sweep: a reassigned slot cannot close an unfinished task"
}

test_closed_worker_gets_a_linked_followup_hold() {
  local dir
  dir=$(new_case closed-worker)
  add_worker "$dir" closed-worker 'state: failed · source: run-step · run failed' 90000
  : > "$dir/home/closed/closed-worker"

  sweep "$dir" scan --now || fail "scan failed"

  [ "$(calls "$dir" hold-calls)" = idle-closed-worker ] || fail "a closed task did not get one followup call"
  [ "$(cat "$dir/home/cards/idle-closed-worker.origin")" = closed-worker ] || fail "the followup was not linked to its worker"
  [ "$(jq -r '.workers[0].hold_id' "$dir/home/state/idle-sweep.json")" = idle-closed-worker ] \
    || fail "the summary did not identify the followup hold"
  assert_contains "$(cat "$dir/home/state/.wake-queue")" idle-closed-worker "the wake did not name the followup call"
  assert_present "$dir/home/state/closed-worker.meta" "creating a call closed the worker"

  : > "$dir/home/held/idle-closed-worker"
  printf 'failed: another event\n' >> "$dir/home/state/closed-worker.status"
  age_file "$dir/home/state/closed-worker.status" 90000
  sweep "$dir" scan --now || fail "second scan failed"
  [ "$(grep -c . "$dir/home/hold-calls")" = 1 ] || fail "a held followup call was raised again"
  [ "$(jq -r '.workers[0].class' "$dir/home/state/idle-sweep.json")" = held ] || fail "the held followup was ignored"
  pass "fm-idle-sweep: closed tasks receive one linked followup call"
}

test_record_less_endpoints_are_closed_as_orphans() {
  local dir
  dir=$(new_case orphans)
  printf 'gone-task\teid123\n' > "$dir/home/orphans"
  sweep "$dir" scan --now || fail "scan failed"
  assert_contains "$(calls "$dir" retire-calls)" "--orphan gone-task --endpoint eid123" \
    "a record-less endpoint should be closed through the orphan close"
  pass "fm-idle-sweep: record-less live endpoints are closed through the orphan close"
}

test_refused_orphans_are_published_even_when_holding_fails() {
  local dir expected
  for expected in carded unhandled; do
    dir=$(new_case "orphan-$expected")
    printf 'gone-task\teid123\n' > "$dir/home/orphans"
    : > "$dir/home/orphan-refused"
    if [ "$expected" = unhandled ]; then : > "$dir/home/hold-unavailable"; fi

    sweep "$dir" scan --now || fail "scan failed"

    [ "$(jq -r '.workers[0].id' "$dir/home/state/idle-sweep.json")" = idle-orphan-gone-task ] \
      || fail "the refused orphan was omitted from the summary"
    [ "$(jq -r '.workers[0].action' "$dir/home/state/idle-sweep.json")" = "$expected" ] \
      || fail "the orphan's hold outcome was not published"
    if [ "$expected" = carded ]; then
      [ "$(calls "$dir" hold-calls)" = idle-orphan-gone-task ] || fail "the orphan did not receive one call"
    else
      [ ! -s "$dir/home/hold-calls" ] || fail "an unavailable hold was reported as successful"
    fi
  done
  pass "fm-idle-sweep: refused orphan summaries reflect the actual hold result"
}

test_orphan_decisions_gate_closure_and_repeated_escalation() {
  local dir mode
  for mode in held deferred; do
    dir=$(new_case "orphan-$mode")
    printf 'gone-task\teid123\n' > "$dir/home/orphans"
    : > "$dir/home/$mode/idle-orphan-gone-task"

    sweep "$dir" scan --now || fail "scan failed"

    if grep -q '^--orphan ' "$dir/home/retire-calls"; then
      fail "an orphan with a $mode decision was closed"
    fi
    [ ! -s "$dir/home/hold-calls" ] || fail "an orphan with a $mode decision was raised"
    [ "$(jq -r '.workers[0] | [.class,.action] | join(" ")' "$dir/home/state/idle-sweep.json")" = 'held none' ] \
      || fail "the $mode orphan was not published as held"
  done

  dir=$(new_case orphan-raised)
  printf 'gone-task\teid123\n' > "$dir/home/orphans"
  printf 'blocked: turn active\n' > "$dir/home/state/gone-task.status"
  : > "$dir/home/orphan-refused"
  sweep "$dir" scan --now || fail "first scan failed"
  [ "$(calls "$dir" hold-calls)" = idle-orphan-gone-task ] || fail "the orphan was not raised"

  rm -f "$dir/home/orphan-refused"
  sweep "$dir" scan --now || fail "second scan failed"
  [ "$(grep -c '^--orphan ' "$dir/home/retire-calls")" = 1 ] || fail "an unchanged raised orphan was closed"
  [ "$(jq -r '.workers[0] | [.class,.action] | join(" ")' "$dir/home/state/idle-sweep.json")" = 'raised none' ] \
    || fail "the unchanged orphan was not published as raised"

  : > "$dir/home/orphan-refused"
  sweep "$dir" scan --now || fail "third scan failed"
  [ "$(grep -c . "$dir/home/hold-calls")" = 1 ] || fail "an unchanged orphan was raised again"
  [ "$(grep -c '^--orphan ' "$dir/home/retire-calls")" = 1 ] || fail "an unchanged orphan's close was retried"

  printf 'blocked: new turn\n' >> "$dir/home/state/gone-task.status"
  sweep "$dir" scan --now || fail "fourth scan failed"
  [ "$(grep -c . "$dir/home/hold-calls")" = 2 ] || fail "a changed orphan ledger did not permit a new decision"
  [ "$(grep -c '^--orphan ' "$dir/home/retire-calls")" = 2 ] || fail "a changed orphan ledger did not permit closure"
  pass "fm-idle-sweep: orphan decisions gate closure until the actual task ledger changes"
}

test_unreadable_holds_prevent_worker_and_orphan_actions() {
  local dir probe identity prefix mode id
  for probe in open deferred; do
    for identity in own followup; do
      dir=$(new_case "unreadable-$probe-$identity")
      printf 'gone-task\teid123\n' > "$dir/home/orphans"
      printf 'blocked: turn active\n' > "$dir/home/state/gone-task.status"
      : > "$dir/home/orphan-refused"
      sweep "$dir" scan --now || fail "initial scan failed"
      [ "$(calls "$dir" hold-calls)" = idle-orphan-gone-task ] || fail "the initial orphan call was not raised"
      printf 'working: turn ended\n' >> "$dir/home/state/gone-task.status"
      rm -f "$dir/home/orphan-refused"

      add_worker "$dir" finished-worker 'state: done · source: run-step · run passed' 90000
      add_worker "$dir" failed-worker 'state: failed · source: run-step · run failed' 90000
      prefix=
      [ "$identity" != followup ] || prefix=idle-
      mode=held
      [ "$probe" != deferred ] || mode=deferred
      : > "$dir/home/$mode/${prefix}idle-orphan-gone-task"
      for id in finished-worker failed-worker idle-orphan-gone-task; do
        : > "$dir/home/unreadable/$probe-${prefix}$id"
      done

      sweep "$dir" scan --now || fail "scan failed"

      [ "$(jq '[.workers[] | select(.class=="unknown" and .action=="none")] | length' "$dir/home/state/idle-sweep.json")" = 3 ] \
        || fail "unreadable $probe calls on $identity identities were not published as unknown/none"
      assert_present "$dir/home/state/finished-worker.meta" "unreadable holds permitted finished-worker cleanup"
      [ ! -s "$dir/home/teardown-calls" ] || fail "unreadable holds permitted teardown"
      [ ! -s "$dir/home/crew-state-calls" ] || fail "unreadable holds permitted worker classification"
      [ "$(grep -c '^--orphan ' "$dir/home/retire-calls")" = 1 ] || fail "an orphan with an unreadable call was closed"
      [ "$(grep -c . "$dir/home/hold-attempts")" = 1 ] || fail "unreadable holds permitted escalation"
    done
  done
  pass "fm-idle-sweep: unreadable open or deferred calls leave workers and orphans untouched"
}

test_second_mates_that_do_not_sweep_are_escalated_once() {
  local dir mate_home
  dir=$(new_case audit)
  mate_home="$dir/mate-home"
  mkdir -p "$mate_home/state"
  fm_write_meta "$dir/home/state/local-mate.meta" "kind=secondmate" "home=$mate_home"
  fm_write_meta "$dir/home/state/far-mate.meta" "kind=secondmate" "home=/remote/far" "remote_host=box"
  : > "$dir/home/remote-unreachable"

  sweep "$dir" scan --now || fail "scan failed"
  assert_contains "$(cat "$dir/home/state/.wake-queue")" "idle-sweep-audit:local-mate:" \
    "a local mate that never swept should be escalated"
  if grep -q 'idle-sweep-audit:far-mate' "$dir/home/state/.wake-queue"; then
    fail "an unreachable remote mate was escalated on a transport failure"
  fi
  assert_contains "$(calls "$dir" on-calls)" "far-mate fm-idle-sweep.sh summary" \
    "a remote mate's sweep should be read on its host"

  sweep "$dir" scan --now || fail "second scan failed"
  [ "$(grep -c 'idle-sweep-audit:local-mate' "$dir/home/state/.wake-queue")" = 1 ] \
    || fail "one stalled episode was escalated more than once"

  printf '{"generated_epoch":%s,"workers":[]}\n' "$(date +%s)" > "$mate_home/state/idle-sweep.json"
  sweep "$dir" scan --now || fail "third scan failed"
  assert_absent "$dir/home/state/local-mate.idle-audit" "a mate sweeping again did not end its episode"

  rm -f "$dir/home/remote-unreachable"
  printf '{"generated_epoch":%s,"workers":[{"id":"x","action":"unhandled"}]}\n' "$(date +%s)" \
    > "$dir/home/remote-summary"
  sweep "$dir" scan --now || fail "fourth scan failed"
  assert_contains "$(cat "$dir/home/state/.wake-queue")" "idle-sweep-audit:far-mate:" \
    "a remote mate that left a worker unhandled should be escalated"
  pass "fm-idle-sweep: a second mate whose sweep is missing, stale or stuck is escalated once per episode"
}

test_local_mates_with_missing_homes_are_escalated() {
  local dir mate
  dir=$(new_case missing-homes)
  mkdir -p "$dir/no-state"
  fm_write_meta "$dir/home/state/no-home.meta" "kind=secondmate" "home=$dir/missing"
  fm_write_meta "$dir/home/state/no-state.meta" "kind=secondmate" "home=$dir/no-state"
  fm_write_meta "$dir/home/state/no-path.meta" "kind=secondmate"

  sweep "$dir" scan --now || fail "scan failed"
  sweep "$dir" scan --now || fail "second scan failed"

  for mate in no-home no-state no-path; do
    [ "$(grep -c "idle-sweep-audit:$mate:" "$dir/home/state/.wake-queue")" = 1 ] \
      || fail "a mate with no summary location was not escalated once: $mate"
    assert_present "$dir/home/state/$mate.idle-audit" "the missing-summary episode was not recorded"
  done
  pass "fm-idle-sweep: local mates with missing homes or state directories escalate once"
}

test_scan_uses_fixed_quiet_and_audit_bounds() {
  local dir rc=0
  dir=$(new_case fixed-bounds)
  add_worker "$dir" 'done' 'state: done · source: run-step · run passed' 1200
  add_worker "$dir" recent 'state: blocked · source: status-log · needs a token' 1200
  mkdir -p "$dir/mate/state"
  fm_write_meta "$dir/home/state/mate.meta" "kind=secondmate" "home=$dir/mate"
  printf '{"generated_epoch":%s,"workers":[]}\n' "$(( $(date +%s) - 25200 ))" > "$dir/mate/state/idle-sweep.json"

  FM_IDLE_SWEEP_DONE_SECS=999999 FM_IDLE_SWEEP_IDLE_SECS=0 FM_IDLE_SWEEP_AUDIT_SECS=999999 \
    sweep "$dir" scan --now || fail "scan failed"

  assert_absent "$dir/home/state/done.meta" "done quiet time was not fixed at 15 minutes"
  assert_present "$dir/home/state/recent.meta" "an idle worker was cleaned up"
  [ ! -s "$dir/home/hold-calls" ] || fail "idle quiet time was not fixed at 6 hours"
  assert_contains "$(cat "$dir/home/state/.wake-queue")" 'idle-sweep-audit:mate:' "audit age was not fixed at 6 hours"
  sweep "$dir" list > "$dir/list.out" 2> "$dir/list.err" || rc=$?
  [ "$rc" = 2 ] || fail "the unsupported list command was accepted"
  pass "fm-idle-sweep: scans use fixed quiet and audit bounds, with no list mode"
}

run_watcher_until() {  # <dir> <file> <pattern>
  local dir=$1 file=$2 pattern=$3 watcher i=0
  FM_HOME="$dir/home" FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=999999 FM_SECONDMATE_REVIVE_INTERVAL=999999 \
    "$dir/bin/fm-watch.sh" > "$dir/watch.out" 2> "$dir/watch.err" &
  watcher=$!
  while ! grep -q "$pattern" "$file" 2>/dev/null && [ "$i" -lt 400 ]; do
    sleep 0.05; i=$((i + 1))
  done
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
}

test_watcher_runs_the_sweep_and_surfaces_its_decision() {
  local dir
  dir=$(new_case watcher)
  add_worker "$dir" broke 'state: failed · source: run-step · run failed' 90000
  run_watcher_until "$dir" "$dir/home/hold-calls" broke
  assert_contains "$(calls "$dir" hold-calls)" broke "the watcher did not run the sweep on its own"

  dir=$(new_case watcher-wake)
  mkdir -p "$dir/mate/state"
  fm_write_meta "$dir/home/state/sm.meta" "kind=secondmate" "home=$dir/mate"
  FM_HOME="$dir/home" "$dir/bin/fm-idle-sweep.sh" scan --now || fail "scan failed"
  run_watcher_until "$dir" "$dir/watch.out" 'not cleaning up'
  grep -q 'check: second mate not cleaning up idle workers: sm' "$dir/watch.out" \
    || fail "the watcher did not wake the first mate for the sweep's escalation: $(cat "$dir/watch.out") $(cat "$dir/watch.err")"
  pass "fm-idle-sweep: the watcher runs the sweep with no model turn and surfaces what it queues"
}

test_done_workers_are_cleaned_up_without_force
test_refusals_and_idle_workers_become_one_decision_each
test_a_raised_worker_is_raised_again_only_after_its_ledger_changes
test_reassigned_slots_cannot_supply_completion
test_closed_worker_gets_a_linked_followup_hold
test_record_less_endpoints_are_closed_as_orphans
test_refused_orphans_are_published_even_when_holding_fails
test_orphan_decisions_gate_closure_and_repeated_escalation
test_unreadable_holds_prevent_worker_and_orphan_actions
test_second_mates_that_do_not_sweep_are_escalated_once
test_local_mates_with_missing_homes_are_escalated
test_scan_uses_fixed_quiet_and_audit_bounds
test_watcher_runs_the_sweep_and_surfaces_its_decision
