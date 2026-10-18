#!/usr/bin/env bash
# tests/fm-idle-sweep.test.sh - the watcher-run idle-worker sweep owned by
# bin/fm-idle-sweep.sh.
#
# bin/fm-idle-sweep.sh's header owns the cleanup, decision-card, admission,
# repeat-suppression, and second-mate audit guarantees exercised here.
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
printf '%s\n' "$1" >> "$FM_HOME/teardown-calls"
printf '%s\n' "$*" >> "$FM_HOME/teardown-args"
if [ -f "$FM_HOME/pending-close/$1" ]; then
  printf 'id=%s\ndata=%s/data\nspawn_gen=fixture\ncleanup_incomplete=0\n' "$1" "$FM_HOME" > "$FM_HOME/state/$1.backlog-close"
  rm -f "$FM_HOME/state/$1.meta"
  echo 'error: backlog close failed' >&2
  exit 1
fi
if [ -f "$FM_HOME/concurrent-cleanup/$1" ]; then
  rm -f "$FM_HOME/state/$1.meta"
  echo 'error: teardown refused: task record is absent' >&2
  exit 1
fi
if [ -f "$FM_HOME/replacement/$1" ]; then
  cp "$FM_HOME/replacement/$1" "$FM_HOME/state/$1.meta"
  echo 'REFUSED: another lifecycle action is already running' >&2
  exit 1
fi
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
      if [ -s "$FM_HOME/orphan-refused" ]; then
        cat "$FM_HOME/orphan-refused" >&2
      else
        echo 'REFUSED: unlanded work remains (open PR)' >&2
      fi
      exit 1
    fi
    exit 0 ;;
esac
SH
  cat > "$dir/bin/fm-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  open|deferred|withdrawn-parked) [ -f "$FM_HOME/unreadable/$1-$2" ] && exit 2 ;;
esac
case "$1" in
  open) [ -f "$FM_HOME/held/$2" ] && exit 0; exit 1 ;;
  deferred) [ -f "$FM_HOME/deferred/$2" ] && exit 0; exit 1 ;;
  withdrawn-parked) [ -f "$FM_HOME/parked/$2" ] && { cat "$FM_HOME/parked/$2"; exit 0; }; exit 1 ;;
  hold)
    id=$2; shift 2
    card= reason= title= origin= expected= guarded=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --card-file) card=$2; shift ;;
        --reason) reason=$2; shift ;;
        --title) title=$2; shift ;;
        --origin) origin=$2; shift ;;
        --repo) shift ;;
        --expected-record) expected=$2; guarded=1; shift ;;
      esac
      shift
    done
    printf '%s\n' "$id" >> "$FM_HOME/hold-attempts"
    # a concurrent cleanup that held the control lock finished meanwhile
    if [ -f "$FM_HOME/cleaned-during-hold/$id" ]; then
      rm -f "$FM_HOME/state/$id.meta"
      echo 'task is already closed' >&2
      [ "$guarded" = 0 ] || exit 3
      exit 1
    fi
    worker=${origin:-$id}
    if [ "$guarded" = 1 ] && { [ ! -f "$FM_HOME/state/$worker.meta" ] || [ "$(cat "$FM_HOME/state/$worker.meta")" != "$expected" ]; }; then
      exit 3
    fi
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
  cat > "$dir/bin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "$1" = show ]; then
  cat "$FM_HOME/rows/$2" 2>/dev/null && exit 0
  echo 'code: NOT_FOUND'
fi
exit 1
SH
  cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/forge-calls"
cat "$FM_HOME/pr-states/${3##*/}" 2>/dev/null || exit 1
SH
  cat > "$dir/bin/glab" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/forge-calls"
state=$(cat "$FM_HOME/pr-states/$3" 2>/dev/null) || exit 1
printf 'state: %s\n' "$state"
SH
  chmod +x "$dir"/bin/fm-crew-state.sh "$dir"/bin/fm-teardown.sh \
    "$dir"/bin/fm-retire-endpoint.sh "$dir"/bin/fm-captain-hold.sh "$dir"/bin/fm-on.sh \
    "$dir"/bin/tasks-axi "$dir"/bin/gh "$dir"/bin/glab
  mkdir -p "$dir/home/crew" "$dir/home/refuse" "$dir/home/held" "$dir/home/deferred" "$dir/home/closed" "$dir/home/unreadable" \
    "$dir/home/rows" "$dir/home/cleaned-during-hold" "$dir/home/pr-states" "$dir/home/concurrent-cleanup" "$dir/home/replacement" "$dir/home/pending-close"
  printf '%s\n' "$dir"
}

age_file() {  # <path> <seconds-ago>
  python3 -c 'import os,sys,time; t=time.time()-int(sys.argv[2]); os.utime(sys.argv[1],(t,t))' "$1" "$2"
}

# add_worker <dir> <id> <crew-state-line> <seconds-quiet>
add_worker() {
  local dir=$1 id=$2 line=$3 quiet=$4 n
  fm_write_meta "$dir/home/state/$id.meta" "kind=ship" "worktree=$dir/pool/1/firstmate"
  printf 'working: started\n' > "$dir/home/state/$id.status"
  age_file "$dir/home/state/$id.status" "$quiet"
  printf '%s\n' "$line" > "$dir/home/crew/$id"
  # a run whose PR merged carries that PR, as a delivered ship's record does
  case "$line" in
    *'PR merged/closed'*)
      n=$(printf '%s' "$id" | cksum | cut -d' ' -f1)
      printf 'pr=https://github.com/owner/repo/pull/9%s\n' "$n" >> "$dir/home/state/$id.meta"
      printf 'MERGED\n' > "$dir/home/pr-states/9$n"
      ;;
  esac
}

sweep() {  # <dir> [args...]
  local dir=$1
  shift
  PATH="$dir/bin:$PATH" TASKS_AXI_BACKEND=markdown FM_HOME="$dir/home" "$dir/bin/fm-idle-sweep.sh" "$@"
}

calls() {  # <dir> <file>
  cat "$dir/home/$2" 2>/dev/null || true
}

test_a_cleanup_finishing_during_the_hold_mints_no_followup_call() {
  local dir
  dir=$(new_case cleaned-during-hold)
  add_worker "$dir" racy 'state: done · source: status-log · landing evidence unresolved' 90000
  printf 'pr=https://github.com/owner/repo/pull/29\n' >> "$dir/home/state/racy.meta"
  printf 'CLOSED\n' > "$dir/home/pr-states/29"
  : > "$dir/home/cleaned-during-hold/racy"

  sweep "$dir" scan --now || fail "scan failed"

  if grep -qx idle-racy "$dir/home/hold-attempts"; then
    fail "a follow-up call was minted for a worker another cleanup had just removed"
  fi
  [ ! -s "$dir/home/hold-calls" ] || fail "a decision was held for a cleaned-up worker: $(calls "$dir" hold-calls)"
  [ "$(jq -r '.workers[] | select(.id=="racy") | [.class,.action] | join(" ")' "$dir/home/state/idle-sweep.json")" = 'unknown none' ] \
    || fail "the raced worker was not left for a fresh scan: $(cat "$dir/home/state/idle-sweep.json")"
  if grep -q 'idle-sweep-unhandled:' "$dir/home/state/.wake-queue" 2>/dev/null; then
    fail "a raced cleanup was reported as a failure"
  fi
  pass "fm-idle-sweep: a cleanup that finishes while the decision is held mints no follow-up call"
}

test_real_holds_check_worker_records_inside_the_lifecycle_lock() {
  local real_tasks dir path mode target expected worker_record
  real_tasks=$(command -v tasks-axi || true)
  [ -n "$real_tasks" ] || { echo 'skip: tasks-axi not found for real hold races'; return; }
  for path in direct linked; do
    for mode in unchanged removed replaced; do
      dir=$(new_case "real-hold-$path-$mode")
      cp "$ROOT/bin/fm-captain-hold.sh" "$dir/bin/fm-captain-hold-real.sh"
      cp "$ROOT/.tasks.toml" "$dir/home/.tasks.toml"
      printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/home/data/backlog.md"
      add_worker "$dir" worker 'state: done · source: status-log · landing evidence unresolved' 90000
      printf 'pr=https://github.com/owner/repo/pull/29\n' >> "$dir/home/state/worker.meta"
      printf 'CLOSED\n' > "$dir/home/pr-states/29"
      worker_record=$(cat "$dir/home/state/worker.meta")
      (cd "$dir/home" && "$real_tasks" add worker 'Worker task' --repo firstmate >/dev/null) || fail 'could not seed backlog'
      target=worker
      if [ "$path" = linked ]; then
        (cd "$dir/home" && "$real_tasks" 'done' worker >/dev/null) || fail 'could not close worker row'
        target=idle-worker
      fi
      printf '%s\n' "$target" > "$dir/home/race-target"
      printf '%s\n' "$mode" > "$dir/home/race-mode"
      printf '%s\n' "$real_tasks" > "$dir/home/real-tasks"
      cat > "$dir/bin/fm-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
script_dir=$(cd "$(dirname "$0")" && pwd)
if [ "$1" = hold ]; then
  printf '%s\n' "$2" >> "$FM_HOME/hold-attempts"
  if [ "$2" = "$(cat "$FM_HOME/race-target")" ]; then
    STATE="$FM_HOME/state"
    . "$script_dir/fm-wake-lib.sh"
    lock="$STATE/.control-worker.lock"
    fm_lock_acquire_wait "$lock" || exit 1
    case "$(cat "$FM_HOME/race-mode")" in
      removed) rm -f "$STATE/worker.meta" ;;
      replaced) printf 'spawn_gen=relaunched\nkind=ship\n' > "$STATE/worker.meta" ;;
    esac
    fm_lock_release "$lock" || exit 1
  fi
fi
exec "$script_dir/fm-captain-hold-real.sh" "$@"
SH
      cat > "$dir/bin/tasks-axi" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  [ "$arg" != --help ] || exec "$(cat "$FM_HOME/real-tasks")" "$@"
done
case "$1" in
  add|update|hold)
    STATE="$FM_HOME/state"
    . "$(dirname "$0")/fm-wake-lib.sh"
    for id in worker "$2"; do
      lock="$STATE/.control-$id.lock"
      if fm_lock_try_acquire "$lock"; then
        fm_lock_release "$lock"
        printf '%s\n' "$id" >> "$FM_HOME/unprotected-mutations"
        exit 1
      fi
    done
    printf '%s\n' "$1 $2" >> "$FM_HOME/protected-mutations"
    ;;
esac
exec "$(cat "$FM_HOME/real-tasks")" "$@"
SH
      chmod +x "$dir/bin/fm-captain-hold.sh" "$dir/bin/tasks-axi"

      sweep "$dir" scan --now || fail "real hold scan failed: $path/$mode"

      [ ! -s "$dir/home/unprotected-mutations" ] || fail 'a backlog mutation ran without the original or target lock'
      if [ "$mode" = unchanged ]; then
        expected='finished carded'
        [ -s "$dir/home/protected-mutations" ] || fail 'unchanged worker did not exercise hold mutations'
        assert_present "$dir/home/state/cards/$target.json" 'unchanged worker lost its decision card'
        cmp -s "$dir/home/race-target" <(jq -r '.workers[0].hold_id' "$dir/home/state/idle-sweep.json") || fail 'wrong task held'
        [ "$(cat "$dir/home/state/worker.meta")" = "$worker_record" ] || fail 'holding changed the worker record'
        if [ "$path" = linked ]; then
          (cd "$dir/home" && "$real_tasks" show idle-worker --full) > "$dir/followup-row"
          assert_contains "$(cat "$dir/followup-row")" 'Origin: worker' 'follow-up lost its origin'
        fi
      else
        expected='unknown none'
        [ ! -s "$dir/home/protected-mutations" ] || fail 'stale decision mutated the backlog'
        assert_absent "$dir/home/state/cards/$target.json" 'stale worker received a card'
        assert_absent "$dir/home/state/idle-sweep/worker.raised" 'stale worker was marked raised'
        [ ! -s "$dir/home/state/.wake-queue" ] || fail 'stale worker queued a wake'
        if [ "$mode" = removed ]; then
          assert_absent "$dir/home/state/worker.meta" 'hold recreated a removed worker'
        else
          [ "$(cat "$dir/home/state/worker.meta")" = $'spawn_gen=relaunched\nkind=ship' ] || fail 'hold changed the replacement record'
        fi
        if [ "$path" = direct ]; then
          [ "$(calls "$dir" hold-attempts)" = worker ] || fail 'stale direct hold attempted a follow-up'
        else
          [ "$(calls "$dir" hold-attempts)" = $'worker\nidle-worker' ] || fail 'linked race was not exercised'
        fi
        if (cd "$dir/home" && "$real_tasks" show idle-worker >/dev/null 2>&1); then
          fail 'a stale linked task was created'
        fi
      fi
      [ "$(jq -r '.workers[0] | [.class,.action] | join(" ")' "$dir/home/state/idle-sweep.json")" = "$expected" ] \
        || fail "wrong hold outcome for $path/$mode: $(cat "$dir/home/state/idle-sweep.json")"
      [ ! -e "$dir/home/state/.control-worker.lock" ] && [ ! -L "$dir/home/state/.control-worker.lock" ] || fail 'worker lock leaked'
      [ ! -e "$dir/home/state/.control-idle-worker.lock" ] && [ ! -L "$dir/home/state/.control-idle-worker.lock" ] || fail 'follow-up lock leaked'
    done
  done
  pass 'fm-idle-sweep: real direct and linked holds skip removed or replaced records and retain both locks through mutation'
}

test_a_main_home_is_woken_once_for_what_the_sweep_could_not_handle() {
  local dir
  dir=$(new_case unhandled-wake)
  add_worker "$dir" stuck 'state: done · source: status-log · landing evidence unresolved' 90000
  printf 'pr=https://github.com/owner/repo/pull/29\n' >> "$dir/home/state/stuck.meta"
  printf 'CLOSED\n' > "$dir/home/pr-states/29"
  : > "$dir/home/hold-unavailable"

  sweep "$dir" scan --now || fail "scan failed"
  sweep "$dir" scan --now || fail "second scan failed"

  [ "$(jq -r '.workers[] | select(.id=="stuck") | .action' "$dir/home/state/idle-sweep.json")" = unhandled ] \
    || fail "a worker the sweep could not raise was not published as unhandled"
  [ "$(grep -c 'idle-sweep-unhandled:' "$dir/home/state/.wake-queue")" = 1 ] \
    || fail "an unchanged unhandled set did not wake the main home exactly once"
  assert_contains "$(cat "$dir/home/state/.wake-queue")" "could neither clean up nor raise: stuck" \
    "the wake should name what was left"

  rm -f "$dir/home/hold-unavailable"
  sweep "$dir" scan --now || fail "third scan failed"
  [ "$(grep -c 'idle-sweep-unhandled:' "$dir/home/state/.wake-queue")" = 1 ] \
    || fail "a handled worker woke the main home again"
  pass "fm-idle-sweep: a main home is woken once for what the sweep could neither clean up nor raise"
}

test_a_worker_named_like_an_orphan_call_still_gets_the_record_check() {
  local dir
  dir=$(new_case orphan-named-worker)
  add_worker "$dir" idle-orphan-race 'state: done · source: status-log · landing evidence unresolved' 90000
  printf 'pr=https://github.com/owner/repo/pull/29\n' >> "$dir/home/state/idle-orphan-race.meta"
  printf 'CLOSED\n' > "$dir/home/pr-states/29"
  : > "$dir/home/cleaned-during-hold/idle-orphan-race"

  sweep "$dir" scan --now || fail "scan failed"

  [ ! -s "$dir/home/hold-calls" ] || fail "a removed worker named like an orphan call got a decision: $(calls "$dir" hold-calls)"
  [ "$(jq -r '.workers[] | select(.id=="idle-orphan-race") | [.class,.action] | join(" ")' "$dir/home/state/idle-sweep.json")" = 'unknown none' ] \
    || fail "a worker named like an orphan call skipped the record check: $(cat "$dir/home/state/idle-sweep.json")"
  pass "fm-idle-sweep: a real worker whose id starts with idle-orphan- still gets the locked record check"
}

test_done_workers_are_cleaned_up_without_force() {
  local dir
  dir=$(new_case done-workers)
  add_worker "$dir" shipped 'state: done · source: run-step · run passed: PR merged/closed' 7200
  add_worker "$dir" retired-tmux 'state: done · source: run-step · run passed: PR merged/closed' 7200
  printf "warning: endpoint x is on the retired 'tmux' backend, which firstmate can no longer close\n" \
    > "$dir/home/refuse/retired-tmux"
  add_worker "$dir" fresh-done 'state: done · source: run-step · run passed: PR merged/closed' 60
  printf 'pr=https://github.com/owner/repo/pull/11\n' >> "$dir/home/state/shipped.meta"
  printf 'pr=https://github.com/owner/repo/pull/12\n' >> "$dir/home/state/retired-tmux.meta"
  printf 'MERGED\n' > "$dir/home/pr-states/11"
  printf 'MERGED\n' > "$dir/home/pr-states/12"

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

test_done_ships_without_merge_evidence_are_never_cleaned_automatically() {
  local dir
  dir=$(new_case unproven)
  add_worker "$dir" no-pr 'state: done · source: status-log · branch pushed' 7200
  add_worker "$dir" ledger-pr 'state: done · source: status-log · PR ready' 7200
  printf 'done: PR https://github.com/owner/repo/pull/21 checks green\n' >> "$dir/home/state/ledger-pr.status"
  age_file "$dir/home/state/ledger-pr.status" 7200
  printf 'OPEN\n' > "$dir/home/pr-states/21"
  add_worker "$dir" busy-lock 'state: done · source: run-step · run passed: PR merged/closed' 7200
  printf 'pr=https://github.com/owner/repo/pull/22\n' >> "$dir/home/state/busy-lock.meta"
  printf 'MERGED\n' > "$dir/home/pr-states/22"
  printf 'error: another lifecycle action is already running for task busy-lock\n' > "$dir/home/refuse/busy-lock"

  sweep "$dir" scan --now || fail "scan failed"

  if grep -Eq '^(no-pr|ledger-pr)$' "$dir/home/teardown-calls" 2>/dev/null; then
    fail "a done ship without a merged PR was sent to cleanup: $(calls "$dir" teardown-calls)"
  fi
  [ ! -s "$dir/home/hold-attempts" ] || fail 'a ship without a PR raised a captain decision'
  assert_contains "$(cat "$dir/home/state/.wake-queue")" 'idle-sweep-mate:no-pr:' 'a ship without a PR did not reach its mate'
  if grep -qx ledger-pr "$dir/home/hold-calls" 2>/dev/null; then
    fail "a worker whose ledger PR is still open became a decision"
  fi
  [ "$(jq -r '.workers[] | select(.id=="ledger-pr") | .class' "$dir/home/state/idle-sweep.json")" = awaiting-merge ] \
    || fail "a PR reported only in the ledger was not read as awaiting merge"
  if grep -qx busy-lock "$dir/home/hold-calls" 2>/dev/null; then
    fail "a cleanup refused only by a busy lock became a decision instead of waiting"
  fi
  assert_present "$dir/home/state/busy-lock.meta" "a lock-refused worker record was removed"
  pass "fm-idle-sweep: done ships need a merged PR to be cleaned up, and a busy lock just waits"
}

test_local_only_completion_is_assessed_by_the_mate() {
  local dir wt state round before
  for state in landed unlanded dirty; do
    dir=$(new_case "local-only-$state")
    wt="$dir/pool/1/firstmate"
    add_worker "$dir" local-worker 'state: done · source: status-log · local branch ready' 7200
    printf 'mode=local-only\n' >> "$dir/home/state/local-worker.meta"
    mkdir -p "$wt"
    git init -q -b main "$wt" || fail 'local repository setup failed'
    git -C "$wt" -c user.name=Fixture -c user.email=fixture@example.invalid \
      commit --allow-empty -qm base || fail 'base commit failed'
    git -C "$wt" checkout -qb worker || fail 'worker branch setup failed'
    git -C "$wt" -c user.name=Fixture -c user.email=fixture@example.invalid \
      commit --allow-empty -qm work || fail 'worker commit failed'
    if [ "$state" = landed ]; then
      git -C "$wt" branch -f main worker || fail 'local landing setup failed'
    elif [ "$state" = dirty ]; then
      printf 'leftover work\n' > "$wt/leftover"
    fi
    before=$(git -C "$wt" rev-parse HEAD)
    for round in 1 2 3; do
      sweep "$dir" scan --now || fail 'local-only scan failed'
    done
    assert_equals referred "$(jq -r '.workers[0].action' "$dir/home/state/idle-sweep.json")" 'local-only completion was not referred'
    assert_equals 1 "$(grep -c 'idle-sweep-mate:local-worker:' "$dir/home/state/.wake-queue")" 'unchanged local-only completion did not notify once'
    [ ! -s "$dir/home/hold-attempts" ] || fail 'local-only completion raised a captain question'
    [ ! -s "$dir/home/teardown-calls" ] || fail 'local-only completion bypassed mate landing assessment'
    assert_present "$dir/home/state/local-worker.meta" 'local-only referral removed worker record'
    assert_equals "$before" "$(git -C "$wt" rev-parse HEAD)" 'local-only referral changed branch'
    if [ "$state" = dirty ]; then
      assert_equals 'leftover work' "$(cat "$wt/leftover")" 'local-only referral discarded leftovers'
    fi
    printf 'done: mate should reassess new evidence\n' >> "$dir/home/state/local-worker.status"
    age_file "$dir/home/state/local-worker.status" 7200
    sweep "$dir" scan --now || fail 'local-only changed evidence scan failed'
    assert_equals 2 "$(grep -c 'idle-sweep-mate:local-worker:' "$dir/home/state/.wake-queue")" 'changed local-only evidence did not notify mate'
  done
  pass 'fm-idle-sweep: local-only landing assessment belongs to mate; unlanded and dirty work stays intact'
}

test_open_pr_workers_wait_for_merge_without_a_cleanup_decision() {
  local dir id
  dir=$(new_case awaiting-merge)
  add_worker "$dir" ready 'state: done · source: run-step · checks green: PR ready for review' 7200
  add_worker "$dir" monitoring 'state: done · source: run-step · checks green: PR ready for review (still monitoring for merge/close)' 7200
  add_worker "$dir" ended-monitor 'state: done · source: run-step · checks green: PR held for merge (ci monitor ended)' 7200
  printf 'pr=https://github.com/owner/repo/pull/1\n' >> "$dir/home/state/ready.meta"
  printf '  links: pr:https://github.com/owner/repo/pull/1\n' > "$dir/home/rows/monitoring"
  printf 'pr=https://gitlab.example/group/repo/-/merge_requests/2\n' >> "$dir/home/state/ended-monitor.meta"
  printf 'OPEN\n' > "$dir/home/pr-states/1"
  printf 'opened\n' > "$dir/home/pr-states/2"
  for id in ready monitoring ended-monitor; do
    printf 'REFUSED: task %s is not finished: its PR is still open\n' "$id" > "$dir/home/refuse/$id"
  done

  sweep "$dir" scan --now || fail "scan failed"

  [ ! -s "$dir/home/teardown-calls" ] || fail "open PR workers were sent to cleanup"
  [ ! -s "$dir/home/hold-attempts" ] || fail "normal merge waits became cleanup decisions"
  [ ! -s "$dir/home/state/.wake-queue" ] || fail "normal merge waits queued a decision wake"
  [ "$(jq '[.workers[] | select(.class=="awaiting-merge" and .action=="none")] | length' "$dir/home/state/idle-sweep.json")" = 3 ] \
    || fail "open PR workers were not published as awaiting merge"
  for id in ready monitoring ended-monitor; do
    assert_present "$dir/home/state/$id.meta" "an open PR worker was removed"
  done

  printf 'MERGED\n' > "$dir/home/pr-states/1"
  printf 'merged\n' > "$dir/home/pr-states/2"
  rm -f "$dir/home/refuse/monitoring" "$dir/home/refuse/ended-monitor"
  printf 'REFUSED: task ready has uncommitted changes\n' > "$dir/home/refuse/ready"
  sweep "$dir" scan --now || fail "scan after merge failed"

  assert_absent "$dir/home/state/monitoring.meta" "a merged PR worker was not cleaned up"
  assert_absent "$dir/home/state/ended-monitor.meta" "a merged MR worker was not cleaned up"
  [ ! -s "$dir/home/hold-attempts" ] || fail "a finished worker's cleanup refusal reached the captain"
  assert_contains "$(cat "$dir/home/state/.wake-queue")" 'idle-sweep-mate:ready:' 'cleanup refusal did not reach its mate'
  assert_equals referred "$(jq -r '.workers[] | select(.id=="ready") | .action' "$dir/home/state/idle-sweep.json")" 'cleanup refusal was not referred'
  pass "fm-idle-sweep: open PR workers wait for merge; merged workers retain guarded cleanup"
}

test_merged_mr_in_ledger_is_passed_to_teardown() {
  local dir id
  dir=$(new_case merged-mr-ledger)
  for id in ledger-mr next-worker; do
    add_worker "$dir" "$id" 'state: done · source: status-log · PR ready' 7200
  done
  printf 'done: MR https://gitlab.example/group/repo/-/merge_requests/57\n' >> "$dir/home/state/ledger-mr.status"
  age_file "$dir/home/state/ledger-mr.status" 7200
  printf 'merged\n' > "$dir/home/pr-states/57"
  printf 'pr=https://github.com/owner/repo/pull/58\n' >> "$dir/home/state/next-worker.meta"
  printf 'MERGED\n' > "$dir/home/pr-states/58"

  sweep "$dir" scan --now || fail "scan failed"

  assert_grep 'ledger-mr --keep-commits --merged-pr https://gitlab.example/group/repo/-/merge_requests/57' \
    "$dir/home/teardown-args" "the ledger MR URL must reach teardown"
  assert_grep 'next-worker --keep-commits --merged-pr https://github.com/owner/repo/pull/58' \
    "$dir/home/teardown-args" "each worker must pass its own verified URL"
  assert_absent "$dir/home/state/ledger-mr.meta" "the ledger-only merged worker is cleaned up"
  assert_absent "$dir/home/state/next-worker.meta" "the next merged worker is cleaned up"
  [ ! -s "$dir/home/hold-attempts" ] || fail "merged workers became captain cards"
  [ "$(jq '[.workers[] | select(.action=="cleaned")] | length' "$dir/home/state/idle-sweep.json")" = 2 ] \
    || fail "merged ledger cleanup was not reported"
  pass "fm-idle-sweep: verified ledger-only MR URLs reach teardown without becoming cards"
}

test_retired_worker_keeps_ledger_only_merged_mr_without_a_card() {
  local dir later kept
  dir=$(new_case retired-ledger-mr)
  cp "$ROOT/bin/fm-teardown.sh" "$ROOT/bin/fm-retire-endpoint.sh" "$dir/bin/"
  fm_git_identity fmtest fmtest@example.invalid
  printf 'manual\n' > "$dir/home/config/backlog-backend"
  touch "$dir/home/state/.last-watcher-beat"
  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$dir/origin.git" "$dir/home/project" 2>/dev/null
  printf 'landed feature\n' > "$dir/home/project/feature.txt"
  git -C "$dir/home/project" add feature.txt
  git -C "$dir/home/project" commit -qm 'landed feature'
  git -C "$dir/home/project" push -q origin main
  git -C "$dir/home/project" remote set-head origin main
  git -C "$dir/home/project" worktree add -qb fm/ledger-mr "$dir/wt" main
  printf 'unlanded follow-up\n' > "$dir/wt/later.txt"
  git -C "$dir/wt" add later.txt
  git -C "$dir/wt" commit -qm 'local follow-up'
  later=$(git -C "$dir/wt" rev-parse HEAD)
  add_worker "$dir" ledger-mr 'state: done · source: status-log · MR ready' 7200
  fm_write_meta "$dir/home/state/ledger-mr.meta" \
    'backend=tmux' 'window=fm:fm-ledger-mr' 'endpoint_task_id=ledger-mr' \
    "worktree=$dir/wt" "project=$dir/home/project" 'kind=ship' \
    'mode=no-mistakes' 'spawn_gen=ledger-mr-test'
  printf 'done: MR https://gitlab.example/group/repo/-/merge_requests/57\n' >> "$dir/home/state/ledger-mr.status"
  age_file "$dir/home/state/ledger-mr.status" 7200
  printf 'merged\n' > "$dir/home/pr-states/57"
  cat > "$dir/bin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/treehouse-calls"
[ "$1" = return ] && [ "$2" = --force ] || exit 1
git -C "$FM_HOME/project" worktree remove --force "$3"
SH
  cat > "$dir/bin/gh-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat > "$dir/bin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cp "$dir/bin/no-mistakes" "$dir/bin/lsof"
  cp "$dir/bin/no-mistakes" "$dir/bin/tmux"
  cp "$dir/bin/no-mistakes" "$dir/bin/fm-remote-job-reap-orphans.sh"
  chmod +x "$dir/bin/treehouse" "$dir/bin/gh-axi" "$dir/bin/lsof" \
    "$dir/bin/no-mistakes" "$dir/bin/tmux" "$dir/bin/fm-remote-job-reap-orphans.sh"

  sweep "$dir" scan --now || fail 'retired ledger-only MR scan failed'

  assert_absent "$dir/home/state/ledger-mr.meta" "the retired worker record remains: $(cat "$dir/home/state/idle-sweep.json")"
  assert_absent "$dir/wt" 'the retired worktree was not returned'
  assert_absent "$dir/home/state/ledger-mr.endpoint-retired" 'retirement authorization remains'
  kept=$(git -C "$dir/home/project" for-each-ref --format='%(objectname)' 'refs/heads/kept/ledger-mr-*')
  assert_equals "$later" "$kept" 'exactly one kept branch must preserve the extra local commit'
  assert_grep 'basis=finished-work' "$dir/home/state/endpoint-retirements.log" 'finished retirement was not used'
  [ "$(grep -c '^mr view 57 -R https://gitlab.example/group/repo$' "$dir/home/forge-calls")" -ge 3 ] \
    || fail 'the sweep and both teardown attempts did not verify the merged MR'
  [ ! -s "$dir/home/hold-attempts" ] || fail 'ledger-only merged MR housekeeping became a card'
  [ "$(jq -r '.workers[] | select(.id=="ledger-mr") | .action' "$dir/home/state/idle-sweep.json")" = cleaned ] \
    || fail "retired MR cleanup was not reported: $(cat "$dir/home/state/idle-sweep.json")"
  pass 'fm-idle-sweep: retirement preserves ledger-only merged MR commits without a card in manual mode'
}

test_closed_unmerged_prs_require_a_cleanup_decision() {
  local dir id
  dir=$(new_case closed-unmerged)
  for id in closed-recorded closed-ledger closed-mr unreadable merged-ledger; do
    add_worker "$dir" "$id" 'state: done · source: status-log · PR ready' 7200
  done
  printf 'pr=https://github.com/owner/repo/pull/51\n' >> "$dir/home/state/closed-recorded.meta"
  printf 'done: PR https://github.com/owner/repo/pull/52\n' >> "$dir/home/state/closed-ledger.status"
  printf 'done: PR https://gitlab.example/group/repo/-/merge_requests/53\n' >> "$dir/home/state/closed-mr.status"
  printf 'pr=https://github.com/owner/repo/pull/54\n' >> "$dir/home/state/unreadable.meta"
  printf 'done: PR https://github.com/owner/repo/pull/55\n' >> "$dir/home/state/merged-ledger.status"
  printf 'CLOSED\n' > "$dir/home/pr-states/51"
  printf 'CLOSED\n' > "$dir/home/pr-states/52"
  printf 'closed\n' > "$dir/home/pr-states/53"
  printf 'MERGED\n' > "$dir/home/pr-states/55"
  for id in closed-ledger closed-mr merged-ledger; do
    age_file "$dir/home/state/$id.status" 7200
  done

  sweep "$dir" scan --now || fail "scan failed"

  [ "$(calls "$dir" teardown-calls)" = merged-ledger ] || fail "cleanup admitted an unmerged or unreadable PR"
  [ "$(calls "$dir" teardown-args)" = "merged-ledger --keep-commits --merged-pr https://github.com/owner/repo/pull/55" ] \
    || fail "a merged worker's cleanup must keep leftover local commits on a branch instead of raising them: $(calls "$dir" teardown-args)"
  [ "$(sort "$dir/home/hold-calls" | tr '\n' ' ')" = 'closed-ledger closed-mr closed-recorded ' ] \
    || fail "closed-unmerged PRs did not become exactly one decision each"
  for id in closed-recorded closed-ledger closed-mr; do
    assert_present "$dir/home/state/$id.meta" "a closed-unmerged PR worker was removed"
    [ "$(jq -r '.options | map(.label) | join(",")' "$dir/home/cards/$id.json")" = 'Clean it up,Keep it' ] \
      || fail "a closed-unmerged PR did not get cleanup options"
    [ "$(jq -r --arg id "$id" '.workers[] | select(.id==$id) | .action' "$dir/home/state/idle-sweep.json")" = carded ] \
      || fail "a closed-unmerged PR decision was not published"
  done
  assert_present "$dir/home/state/unreadable.meta" "an unreadable PR worker was removed"
  assert_absent "$dir/home/state/merged-ledger.meta" "a merged PR reported in the ledger was not cleaned up"
  pass "fm-idle-sweep: only merged PRs admit cleanup; closed-unmerged PRs become decisions"
}

test_only_lifecycle_contention_defers_cleanup_refusals() {
  local dir id
  dir=$(new_case contention)
  for id in lifecycle treehouse clock unresolved-lock unrelated-progress; do
    add_worker "$dir" "$id" 'state: done · source: run-step · run passed: PR merged/closed' 7200
  done
  printf 'error: another lifecycle action is already running for task lifecycle; nothing was changed\n' > "$dir/home/refuse/lifecycle"
  printf 'REFUSED: another Treehouse slot allocation or return is in progress for repo; nothing was changed\n' > "$dir/home/refuse/treehouse"
  printf 'REFUSED: worktree /pool/clock has uncommitted changes\n' > "$dir/home/refuse/clock"
  printf 'REFUSED: cannot resolve the shared Treehouse project lock for repo; nothing was changed\n' > "$dir/home/refuse/unresolved-lock"
  printf 'REFUSED: worktree /pool/in progress has uncommitted changes\n' > "$dir/home/refuse/unrelated-progress"

  sweep "$dir" scan --now || fail "scan failed"

  [ ! -s "$dir/home/hold-attempts" ] || fail 'a cleanup refusal raised a captain card'
  for id in clock unresolved-lock unrelated-progress; do
    assert_equals referred "$(jq -r --arg id "$id" '.workers[] | select(.id==$id) | .action' "$dir/home/state/idle-sweep.json")" 'a non-contention refusal was not referred'
    assert_contains "$(cat "$dir/home/state/.wake-queue")" "idle-sweep-mate:$id:" 'a non-contention refusal did not reach its mate'
  done
  for id in lifecycle treehouse; do
    [ "$(jq -r --arg id "$id" '.workers[] | select(.id==$id) | [.class,.action] | join(" ")' "$dir/home/state/idle-sweep.json")" = 'settling none' ] \
      || fail "a supported contention refusal did not wait for the next scan"
  done
  [ "$(wc -l < "$dir/home/teardown-calls" | tr -d ' ')" = 5 ] || fail "not all refusal paths were exercised"
  pass "fm-idle-sweep: lifecycle contention waits; other cleanup refusals reach the mate"
}

test_pending_backlog_closes_remain_visible_until_cleared() {
  local dir round
  dir=$(new_case pending-close)
  add_worker "$dir" pending 'state: done · source: run-step · run passed: PR merged/closed' 7200
  : > "$dir/home/pending-close/pending"

  sweep "$dir" scan --now || fail "initial scan failed"

  assert_absent "$dir/home/state/pending.meta" "the failed close did not remove the worker record"
  assert_present "$dir/home/state/pending.backlog-close" "the failed close did not leave its recovery record"
  cp "$dir/home/state/pending.backlog-close" "$dir/marker.saved"
  for round in 1 2 3; do
    [ "$(jq '.workers | length' "$dir/home/state/idle-sweep.json")" = 1 ] || fail "pending close was omitted or duplicated"
    [ "$(jq -r '.workers[0] | [.id,.action] | join(" ")' "$dir/home/state/idle-sweep.json")" = 'pending unhandled' ] \
      || fail "pending close did not remain unhandled on scan $round"
    cmp -s "$dir/marker.saved" "$dir/home/state/pending.backlog-close" || fail "sweep changed the lifecycle owner's pending-close record"
    sweep "$dir" scan --now || fail "repeat scan failed"
  done
  [ "$(calls "$dir" teardown-calls)" = pending ] || fail "sweep retried a metadata-less pending close"
  [ ! -s "$dir/home/hold-attempts" ] || fail "pending-close reporting created a captain call"

  rm "$dir/home/state/pending.backlog-close"
  sweep "$dir" scan --now || fail "scan after lifecycle recovery failed"
  [ "$(jq '.workers | length' "$dir/home/state/idle-sweep.json")" = 0 ] || fail "a cleared pending close stayed in the summary"
  pass "fm-idle-sweep: metadata-less pending closes stay unhandled until their owner clears them"
}

test_concurrent_cleanup_does_not_raise_stale_decisions() {
  local dir
  dir=$(new_case concurrent-cleanup)
  add_worker "$dir" removed 'state: done · source: run-step · run passed: PR merged/closed' 7200
  : > "$dir/home/concurrent-cleanup/removed"
  : > "$dir/home/closed/removed"
  add_worker "$dir" replaced 'state: done · source: run-step · run passed: PR merged/closed' 7200
  printf 'spawn_gen=old\n' >> "$dir/home/state/replaced.meta"
  fm_write_meta "$dir/home/replacement/replaced" "kind=ship" "worktree=$dir/pool/2/firstmate" "spawn_gen=new"
  printf 'pr=https://github.com/owner/repo/pull/31\n' >> "$dir/home/state/removed.meta"
  printf 'pr=https://github.com/owner/repo/pull/32\n' >> "$dir/home/state/replaced.meta"
  printf 'MERGED\n' > "$dir/home/pr-states/31"
  printf 'MERGED\n' > "$dir/home/pr-states/32"

  sweep "$dir" scan --now || fail "scan failed"

  assert_absent "$dir/home/state/removed.meta" "the concurrent cleanup did not remove its record"
  [ "$(calls "$dir" teardown-calls | sort | tr '\n' ' ')" = 'removed replaced ' ] \
    || fail "the race was not exercised through both cleanup attempts"
  [ ! -s "$dir/home/hold-attempts" ] || fail "a stale cleanup refusal became a decision"
  [ ! -s "$dir/home/state/.wake-queue" ] || fail "a stale cleanup refusal queued a decision wake"
  assert_absent "$dir/home/state/idle-sweep/removed.raised" "a removed worker was fingerprinted as raised"
  assert_absent "$dir/home/state/idle-sweep/replaced.raised" "a replacement worker was fingerprinted as raised"
  cmp -s "$dir/home/replacement/replaced" "$dir/home/state/replaced.meta" || fail "the replacement record was changed"
  [ "$(jq -r '.workers[] | select(.id=="removed") | .action' "$dir/home/state/idle-sweep.json")" = cleaned ] \
    || fail "concurrent cleanup was not reconciled"
  [ "$(jq -r '.workers[] | select(.id=="replaced") | [.class,.action] | join(" ")' "$dir/home/state/idle-sweep.json")" = 'unknown none' ] \
    || fail "the replacement worker was not left for a fresh scan"
  pass "fm-idle-sweep: concurrent removal or replacement cannot create stale cleanup decisions"
}

test_refusals_and_idle_workers_are_referred_to_the_mate() {
  local dir id
  dir=$(new_case decisions)
  add_worker "$dir" unlanded 'state: done · source: run-step · run passed: PR merged/closed' 7200
  printf 'REFUSED: task unlanded has uncommitted changes (dirty copy)\n' > "$dir/home/refuse/unlanded"
  printf 'pr=https://github.com/owner/repo/pull/41\n' >> "$dir/home/state/unlanded.meta"
  printf 'MERGED\n' > "$dir/home/pr-states/41"
  add_worker "$dir" broke 'state: failed · source: run-step · run failed (test step)' 90000
  printf 'pr=https://github.com/owner/repo/pull/1806\n' >> "$dir/home/state/broke.meta"
  add_worker "$dir" waiting 'state: blocked · source: status-log · needs a token' 90000
  printf 'pr=https://github.com/owner/repo/pull/1807\n' >> "$dir/home/state/waiting.meta"
  add_worker "$dir" vanished 'state: unknown · source: none · backend target gone: hub:abc' 90000
  add_worker "$dir" just-blocked 'state: blocked · source: status-log · needs a token' 600
  add_worker "$dir" busy 'state: working · source: pane · harness busy' 90000
  add_worker "$dir" unreachable 'state: unknown · source: none · backend unreachable' 90000
  add_worker "$dir" asked 'state: failed · source: run-step · run failed' 90000
  : > "$dir/home/held/asked"
  add_worker "$dir" parked-wait 'state: paused · source: status-log · waiting on CI' 90000
  : > "$dir/home/deferred/parked-wait"

  sweep "$dir" scan --now || fail "scan failed"

  [ ! -s "$dir/home/hold-attempts" ] \
    || fail "routine worker decisions reached the captain: $(calls "$dir" hold-calls)"
  for id in unlanded broke waiting vanished; do
    assert_contains "$(cat "$dir/home/state/.wake-queue")" "idle-sweep-mate:$id:" 'routine case did not reach owning mate'
    assert_equals referred "$(jq -r --arg id "$id" '.workers[] | select(.id==$id) | .action' "$dir/home/state/idle-sweep.json")" 'routine decision was not referred'
    assert_present "$dir/home/state/$id.meta" 'referral removed unfinished work'
  done
  assert_present "$dir/home/state/unlanded.meta" "a refused cleanup removed the record"
  assert_contains "$(jq -r '.workers[] | select(.id=="unlanded") | .detail' "$dir/home/state/idle-sweep.json")" 'uncommitted changes' 'the referral lost the cleanup refusal'
  [ "$(jq -r '.workers[] | select(.id=="unreachable") | .class' "$dir/home/state/idle-sweep.json")" = settling ] \
    || fail "an unavailable backend was classified as a dead worker"
  if grep -qx asked "$dir/home/crew-state-calls"; then
    fail "a worker already held for the captain was re-read"
  fi
  if grep -q 'idle-sweep:' "$dir/home/state/.wake-queue"; then fail 'routine referrals queued a captain-decision wake'; fi
  pass "fm-idle-sweep: routine retry or retirement goes to the mate; existing choices stay held"
}

test_a_raised_worker_is_raised_again_only_after_its_ledger_changes() {
  local dir
  dir=$(new_case raised)
  add_worker "$dir" broke 'state: failed · source: run-step · run failed' 90000

  sweep "$dir" scan --now || fail "first scan failed"
  printf 'state: unknown · source: none · backend target gone\n' > "$dir/home/crew/broke"
  sweep "$dir" scan --now || fail "second scan failed"
  sweep "$dir" scan --now || fail "unchanged scan failed"
  assert_equals 2 "$(grep -c 'idle-sweep-mate:' "$dir/home/state/.wake-queue")" 'a changed crew result must notify once'
  [ ! -s "$dir/home/hold-calls" ] || fail 'routine reassessment raised a captain card'

  printf 'failed: second attempt failed\n' >> "$dir/home/state/broke.status"
  age_file "$dir/home/state/broke.status" 90000
  sweep "$dir" scan --now || fail "third scan failed"
  assert_equals 3 "$(grep -c 'idle-sweep-mate:' "$dir/home/state/.wake-queue")" 'changed ledger did not reach mate'

  touch "$dir/home/state/.last-idle-sweep"
  printf 'failed: third\n' >> "$dir/home/state/broke.status"
  age_file "$dir/home/state/broke.status" 90000
  sweep "$dir" scan || fail "cadence-gated scan failed"
  assert_equals 3 "$(grep -c 'idle-sweep-mate:' "$dir/home/state/.wake-queue")" 'a scan inside its cadence still ran'
  pass "fm-idle-sweep: a raised worker waits for its ledger to change, and scans keep their cadence"
}

test_reassigned_slots_cannot_supply_completion() {
  local dir
  dir=$(new_case reassigned)
  add_worker "$dir" stale 'state: done · source: run-step · new owner completed' 90000
  add_worker "$dir" claimant 'state: done · source: run-step · run passed: PR merged/closed' 7200
  mkdir -p "$dir/pool/1/firstmate"
  printf 'task=claimant\nhome=%s\n' "$dir/home" > "$dir/pool/1/.fm-slot-owner"

  sweep "$dir" scan --now || fail "scan failed"

  assert_present "$dir/home/state/stale.meta" "a reassigned task was closed using the claimant's completion"
  assert_absent "$dir/home/state/claimant.meta" "the actual claimant was not cleaned up"
  [ "$(calls "$dir" teardown-calls)" = claimant ] || fail "cleanup touched the stale task"
  [ ! -s "$dir/home/hold-calls" ] || fail 'reassigned worker raised a captain card'
  assert_contains "$(cat "$dir/home/state/.wake-queue")" 'idle-sweep-mate:stale:' 'stale task did not reach mate'
  [ "$(jq -r '.workers[] | select(.id=="stale") | .class' "$dir/home/state/idle-sweep.json")" = dead ] \
    || fail "the stale task was not classified as dead"
  if grep -qx stale "$dir/home/crew-state-calls"; then fail "the stale task read the claimant's run"; fi
  pass "fm-idle-sweep: a reassigned slot cannot close an unfinished task"
}

test_closed_worker_gets_a_linked_followup_hold() {
  local dir
  dir=$(new_case closed-worker)
  add_worker "$dir" closed-worker 'state: done · source: status-log · landing evidence unresolved' 90000
  printf 'pr=https://github.com/owner/repo/pull/29\n' >> "$dir/home/state/closed-worker.meta"
  printf 'CLOSED\n' > "$dir/home/pr-states/29"
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

test_refused_orphans_are_referred_without_captain_calls() {
  local dir expected why
  for why in 'active turn remains' 'unlanded work remains (open PR)'; do
    for expected in referred unhandled; do
      dir=$(new_case "orphan-$expected-${why%% *}")
      printf 'gone-task\teid123\n' > "$dir/home/orphans"
      printf 'REFUSED: %s\n' "$why" > "$dir/home/orphan-refused"
      if [ "$expected" = unhandled ]; then mkdir "$dir/home/state/.wake-queue"; fi

      sweep "$dir" scan --now 2> "$dir/sweep.err" || fail "scan failed"

      [ "$(jq -r '.workers[0].id' "$dir/home/state/idle-sweep.json")" = idle-orphan-gone-task ] \
        || fail "the refused orphan was omitted from the summary"
      [ "$(jq -r '.workers[0].action' "$dir/home/state/idle-sweep.json")" = "$expected" ] \
        || fail "the orphan's referral outcome was not published"
      [ ! -s "$dir/home/hold-attempts" ] || fail 'an orphan refusal reached the captain'
      assert_contains "$(jq -r '.workers[0].detail' "$dir/home/state/idle-sweep.json")" "$why" 'orphan summary lost refusal evidence'
      [ "$(grep -c '^--orphan ' "$dir/home/retire-calls")" = 1 ] || fail 'orphan refusal bypassed cleanup guards'
      if [ "$expected" = referred ]; then
        assert_contains "$(cat "$dir/home/state/.wake-queue")" 'idle-sweep-mate:idle-orphan-gone-task:' 'orphan did not reach its mate'
      else
        assert_absent "$dir/home/state/idle-sweep/idle-orphan-gone-task.mate-review" 'a failed referral was marked handled'
        rmdir "$dir/home/state/.wake-queue"
        sweep "$dir" scan --now || fail 'referral recovery scan failed'
        assert_equals referred "$(jq -r '.workers[0].action' "$dir/home/state/idle-sweep.json")" 'failed referral was not retried'
      fi
    done
  done
  pass "fm-idle-sweep: orphan refusals go to the mate; failed referrals stay unhandled and retry"
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

  dir=$(new_case orphan-legacy-raised)
  printf 'gone-task\teid123\n' > "$dir/home/orphans"
  printf 'blocked: old unresolved choice\n' > "$dir/home/state/gone-task.status"
  mkdir -p "$dir/home/state/idle-sweep"
  wc -c < "$dir/home/state/gone-task.status" | tr -d ' ' > "$dir/home/state/idle-sweep/idle-orphan-gone-task.raised"
  sweep "$dir" scan --now || fail 'legacy orphan scan failed'
  assert_equals 'raised none' "$(jq -r '.workers[0] | [.class,.action] | join(" ")' "$dir/home/state/idle-sweep.json")" 'legacy unresolved orphan choice was not retained'
  if grep -q '^--orphan ' "$dir/home/retire-calls"; then fail 'legacy orphan choice permitted closure'; fi
  [ ! -s "$dir/home/state/.wake-queue" ] || fail 'legacy orphan choice was surfaced again'

  dir=$(new_case orphan-referred)
  printf 'gone-task\teid123\n' > "$dir/home/orphans"
  printf 'blocked: turn active\n' > "$dir/home/state/gone-task.status"
  : > "$dir/home/orphan-refused"
  sweep "$dir" scan --now || fail "first scan failed"
  assert_equals 1 "$(grep -c 'idle-sweep-mate:' "$dir/home/state/.wake-queue")" 'orphan was not referred'

  rm -f "$dir/home/orphan-refused"
  sweep "$dir" scan --now || fail "second scan failed"
  [ "$(grep -c '^--orphan ' "$dir/home/retire-calls")" = 1 ] || fail "an unchanged referred orphan was closed"
  [ "$(jq -r '.workers[0] | [.class,.action] | join(" ")' "$dir/home/state/idle-sweep.json")" = 'dead referred' ] \
    || fail "the unchanged orphan was not left with its mate"

  : > "$dir/home/orphan-refused"
  sweep "$dir" scan --now || fail "third scan failed"
  assert_equals 1 "$(grep -c 'idle-sweep-mate:' "$dir/home/state/.wake-queue")" 'unchanged orphan woke mate again'
  [ "$(grep -c '^--orphan ' "$dir/home/retire-calls")" = 1 ] || fail "an unchanged orphan's close was retried"

  printf 'blocked: new turn\n' >> "$dir/home/state/gone-task.status"
  sweep "$dir" scan --now || fail "fourth scan failed"
  assert_equals 2 "$(grep -c 'idle-sweep-mate:' "$dir/home/state/.wake-queue")" 'changed orphan evidence did not reach mate'
  [ "$(grep -c '^--orphan ' "$dir/home/retire-calls")" = 2 ] || fail "a changed orphan ledger did not permit closure"
  [ ! -s "$dir/home/hold-attempts" ] || fail 'orphan reassessment raised a captain card'
  pass "fm-idle-sweep: orphan decisions gate closure; unchanged referrals wait for mate assessment"
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
      assert_equals referred "$(jq -r '.workers[0].action' "$dir/home/state/idle-sweep.json")" 'initial orphan was not referred'
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
      [ ! -s "$dir/home/hold-attempts" ] || fail "unreadable holds permitted escalation"
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
  if grep -q 'idle-sweep-audit:local-mate' "$dir/home/state/.wake-queue" 2>/dev/null; then
    fail "a mate that has not swept yet was escalated before its grace bound"
  fi
  age_file "$dir/home/state/local-mate.idle-audit-missing" 25200
  sweep "$dir" scan --now || fail "scan after the grace bound failed"
  assert_contains "$(cat "$dir/home/state/.wake-queue")" "idle-sweep-audit:local-mate:" \
    "a local mate that never swept within its grace bound should be escalated"
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
  for mate in no-home no-state no-path; do
    age_file "$dir/home/state/$mate.idle-audit-missing" 25200
  done
  sweep "$dir" scan --now || fail "scan after the grace bound failed"
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
  add_worker "$dir" 'done' 'state: done · source: run-step · run passed: PR merged/closed' 1200
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
  PATH="$dir/bin:$PATH" TASKS_AXI_BACKEND=markdown \
    FM_WATCH_HANDLING_SUCCESSOR=1 FM_HOME="$dir/home" FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=999999 FM_SECONDMATE_REVIVE_INTERVAL=999999 \
    "$dir/bin/fm-watch.sh" > "$dir/watch.out" 2> "$dir/watch.err" &
  watcher=$!
  fm_test_track_helper_pid "$watcher"
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
  run_watcher_until "$dir" "$dir/home/state/.wake-queue" 'idle-sweep-mate:broke:'
  assert_contains "$(cat "$dir/home/state/.wake-queue")" 'idle-sweep-mate:broke:' 'watcher did not run the sweep on its own'
  run_watcher_until "$dir" "$dir/watch.out" 'mate reassessment'
  assert_contains "$(cat "$dir/watch.out")" 'mate reassessment of retry or guarded retirement: broke' \
    "watcher did not run and surface the mate referral: $(cat "$dir/watch.err"); summary=$(cat "$dir/home/state/idle-sweep.json" 2>/dev/null); queue=$(cat "$dir/home/state/.wake-queue" 2>/dev/null)"
  [ ! -s "$dir/home/hold-calls" ] || fail 'watcher raised a routine captain card'

  dir=$(new_case watcher-wake)
  mkdir -p "$dir/mate/state"
  fm_write_meta "$dir/home/state/sm.meta" "kind=secondmate" "home=$dir/mate"
  FM_HOME="$dir/home" "$dir/bin/fm-idle-sweep.sh" scan --now || fail "scan failed"
  age_file "$dir/home/state/sm.idle-audit-missing" 25200
  FM_HOME="$dir/home" "$dir/bin/fm-idle-sweep.sh" scan --now || fail "scan after the grace bound failed"
  run_watcher_until "$dir" "$dir/watch.out" 'not cleaning up'
  grep -q 'check: second mate not cleaning up idle workers: sm' "$dir/watch.out" \
    || fail "the watcher did not wake the first mate for the sweep's escalation: $(cat "$dir/watch.out") $(cat "$dir/watch.err")"
  pass "fm-idle-sweep: the watcher runs the sweep with no model turn and surfaces what it queues"
}

test_real_parked_withdrawals_survive_later_sweeps() {
  local dir real_tasks path target kind round evidence summary_id
  real_tasks=$(command -v tasks-axi || true)
  [ -n "$real_tasks" ] || { echo 'skip: tasks-axi not found for real parked withdrawals'; return; }
  for path in direct linked orphan orphan-linked; do
    for kind in retry capability-wait; do
      case "$path:$kind" in direct:capability-wait|linked:retry|orphan:retry|orphan-linked:retry) continue ;; esac
      dir=$(new_case "park-$path-$kind")
      cp "$ROOT/bin/fm-captain-hold.sh" "$dir/bin/fm-captain-hold.sh"
      cp "$ROOT/.tasks.toml" "$dir/home/.tasks.toml"
      printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/home/data/backlog.md"
      printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$real_tasks" > "$dir/bin/tasks-axi"
      add_worker "$dir" worker 'state: blocked · source: status-log · awaiting preview capability' 90000
      (cd "$dir/home" && "$real_tasks" add worker 'Synthetic unfinished work' --repo firstmate >/dev/null) || fail 'seed failed'
      summary_id=worker
      target=worker
      if [ "$path" = linked ]; then
        (cd "$dir/home" && "$real_tasks" 'done' worker >/dev/null) || fail 'close failed'
        target=idle-worker
      fi
      case "$path" in
        orphan|orphan-linked)
          rm "$dir/home/state/worker.meta"
          summary_id=idle-orphan-worker
          target=$summary_id
          printf 'worker\teid123\n' > "$dir/home/orphans"
          : > "$dir/home/orphan-refused"
          if [ "$path" = orphan-linked ]; then
            (cd "$dir/home" && "$real_tasks" add "$target" 'Legacy orphan question' --repo firstmate >/dev/null \
              && "$real_tasks" 'done' "$target" >/dev/null) || fail 'orphan linked setup failed'
            target=idle-$target
          fi
          ;;
      esac
      printf '{"project":"firstmate","title":"Resume unfinished work?","situation":"Work is unfinished.","options":[{"key":"1","label":"Retry","instruction":"Retry the work."},{"key":"2","label":"Wait","instruction":"Wait for capability."}],"recommended":"1"}\n' > "$dir/card.json"
      PATH="$dir/bin:$PATH" TASKS_AXI_BACKEND=markdown FM_HOME="$dir/home" \
        "$dir/bin/fm-captain-hold.sh" hold "$target" --reason 'Legacy retry question' \
        --title 'Synthetic unfinished work' --origin worker --repo firstmate --card-file "$dir/card.json" \
        > "$dir/hold.out" || fail 'legacy call setup failed'
      printf 'The mate owns %s for this unfinished task; preserve its local work.\n' "$kind" > "$dir/evidence"
      PATH="$dir/bin:$PATH" TASKS_AXI_BACKEND=markdown FM_HOME="$dir/home" \
        "$dir/bin/fm-captain-hold.sh" withdraw "$target" --evidence-file "$dir/evidence" \
        --park "Mate owns $kind" > "$dir/withdraw.out" || fail 'supported park operation failed'
      assert_absent "$dir/home/state/cards/$target.json" 'withdraw did not retire card'
      # Recording the mate's disposition changes the ledger, not the task's
      # retry evidence, and must not defeat the durable park on the next scan.
      printf 'resolved: retry or wait belongs to the mate\n' >> "$dir/home/state/worker.status"
      age_file "$dir/home/state/worker.status" 90000
      for round in 1 2 3; do
        sweep "$dir" scan --now || fail 'later parked sweep failed'
        assert_absent "$dir/home/state/cards/$target.json" 'unchanged evidence raised another retry card'
        assert_equals mate-wait "$(jq -r '.workers[0].class' "$dir/home/state/idle-sweep.json")" 'durable mate disposition ignored'
      done
      [ ! -s "$dir/home/teardown-calls" ] || fail 'parked work was cleaned up'
      if grep -q 'idle-sweep-mate:' "$dir/home/state/.wake-queue"; then fail 'unchanged evidence woke mate'; fi
      evidence=$(cat "$dir/home/state/idle-sweep/$summary_id.mate-wait")
      printf 'blocked: capability is available; retry now\n' > "$dir/home/state/worker.status"
      age_file "$dir/home/state/worker.status" 90000
      sweep "$dir" scan --now || fail 'changed evidence scan failed'
      [ "$evidence" != "$(cat "$dir/home/state/idle-sweep/$summary_id.mate-wait")" ] || fail 'evidence fingerprint unchanged'
      assert_contains "$(cat "$dir/home/state/.wake-queue")" "idle-sweep-mate:$summary_id:" 'material change did not reach mate'
      assert_absent "$dir/home/state/cards/$target.json" 'changed evidence went to captain instead of mate'
      sweep "$dir" scan --now || fail 'repeat changed scan failed'
      assert_equals 1 "$(grep -c 'idle-sweep-mate:' "$dir/home/state/.wake-queue")" 'unchanged new evidence notified twice'
      if [ "$summary_id" = worker ]; then
        assert_present "$dir/home/state/worker.meta" 'unfinished work was removed'
      else
        if grep -q '^--orphan ' "$dir/home/retire-calls"; then fail 'parked orphan closure was retried'; fi
      fi
    done
  done
  pass 'fm-idle-sweep: real withdraw --park preserves retry and capability waits; changed evidence goes to mate'
}

test_parked_evidence_ignores_observation_time_but_tracks_git_changes() {
  local dir id
  dir=$(new_case parked-evidence)
  id=waiting
  add_worker "$dir" "$id" 'state: blocked · source: status-log · awaiting preview; observed=old' 90000
  mkdir -p "$dir/home/parked" "$dir/pool/1/firstmate"
  printf 'synthetic-disposition\n' > "$dir/home/parked/$id"
  git init -q "$dir/pool/1/firstmate"
  git -C "$dir/pool/1/firstmate" -c user.name=Fixture -c user.email=fixture@example.invalid \
    commit --allow-empty -qm seed
  sweep "$dir" scan --now || fail 'initial parked evidence scan failed'
  printf 'state: blocked · source: status-log · awaiting preview; observed=new\n' > "$dir/home/crew/$id"
  sweep "$dir" scan --now || fail 'later observation scan failed'
  [ ! -s "$dir/home/state/.wake-queue" ] || fail 'observation time alone notified mate'
  git -C "$dir/pool/1/firstmate" -c user.name=Fixture -c user.email=fixture@example.invalid \
    commit --allow-empty -qm follow-up
  sweep "$dir" scan --now || fail 'changed head scan failed'
  assert_equals 1 "$(grep -c 'idle-sweep-mate:' "$dir/home/state/.wake-queue")" 'new head did not reach mate'
  printf 'unlanded local work\n' > "$dir/pool/1/firstmate/leftover"
  sweep "$dir" scan --now || fail 'dirty local copy scan failed'
  assert_equals 2 "$(grep -c 'idle-sweep-mate:' "$dir/home/state/.wake-queue")" 'dirty local copy did not reach mate'
  [ ! -s "$dir/home/hold-attempts" ] || fail 'changed parked evidence raised a captain card'
  [ ! -s "$dir/home/teardown-calls" ] || fail 'changed parked evidence triggered cleanup'
  assert_present "$dir/pool/1/firstmate/leftover" 'local work was removed'
  run_watcher_until "$dir" "$dir/watch.out" 'mate reassessment'
  assert_contains "$(cat "$dir/watch.out")" 'mate reassessment of retry or guarded retirement: waiting' 'handling successor ignored changed Git evidence'
  if grep -q 'process-event result captured\|idle workers need a decision\|rearm-resurface' "$dir/watch.out"; then
    fail 'mate reassessment was misclassified or depended on generic recovery'
  fi
  : > "$dir/home/held/$id"
  sweep "$dir" scan --now || fail 'fresh unresolved choice scan failed'
  assert_equals held "$(jq -r '.workers[0].class' "$dir/home/state/idle-sweep.json")" 'new unresolved captain choice was suppressed'
  pass 'fm-idle-sweep: parked evidence ignores read timestamps, reports Git changes to mate and preserves unresolved choices and local work'
}

test_orphan_mate_waits_cover_original_and_linked_calls() {
  local dir target mode round
  for target in gone-task idle-gone-task idle-orphan-gone-task idle-idle-orphan-gone-task; do
    for mode in parked unreadable; do
      dir=$(new_case "orphan-wait-$target-$mode")
      mkdir -p "$dir/home/parked"
      printf 'gone-task\teid123\n' > "$dir/home/orphans"
      printf 'blocked: legacy endpoint wait\n' > "$dir/home/state/gone-task.status"
      : > "$dir/home/orphan-refused"
      if [ "$mode" = parked ]; then
        printf 'mate capability wait\n' > "$dir/home/parked/$target"
      else
        : > "$dir/home/unreadable/withdrawn-parked-$target"
      fi
      for round in 1 2; do
        sweep "$dir" scan --now || fail 'orphan wait scan failed'
        [ ! -s "$dir/home/hold-attempts" ] || fail 'parked orphan was raised'
        if grep -q '^--orphan ' "$dir/home/retire-calls"; then fail 'parked orphan closure was retried'; fi
      done
      [ ! -s "$dir/home/state/.wake-queue" ] || fail 'unchanged orphan wait woke mate'
      printf 'blocked: capability changed\n' >> "$dir/home/state/gone-task.status"
      sweep "$dir" scan --now || fail 'changed orphan scan failed'
      sweep "$dir" scan --now || fail 'unchanged new orphan scan failed'
      [ ! -s "$dir/home/hold-attempts" ] || fail 'changed orphan wait raised a card'
      if grep -q '^--orphan ' "$dir/home/retire-calls"; then fail 'changed parked orphan was closed'; fi
      if [ "$mode" = parked ]; then
        assert_equals mate-wait "$(jq -r '.workers[0].class' "$dir/home/state/idle-sweep.json")" 'orphan lost mate wait'
        assert_equals 1 "$(grep -c 'idle-sweep-mate:idle-orphan-gone-task:' "$dir/home/state/.wake-queue")" 'changed orphan evidence did not notify exactly once'
      else
        assert_equals unknown "$(jq -r '.workers[0].class' "$dir/home/state/idle-sweep.json")" 'unreadable mate wait did not stop safely'
      fi
    done
  done
  pass 'fm-idle-sweep: orphan and linked waits prevent closure and repeated captain cards'
}

test_finished_cleanup_refusals_are_assessed_by_the_mate() {
  local dir expected why
  for why in 'cannot inspect worktree users: lsof failed' 'stream endpoint did not confirm its stop'; do
    for expected in referred unhandled; do
      dir=$(new_case "finished-$expected-${why%% *}")
      add_worker "$dir" shipped 'state: done · source: run-step · run passed: PR merged/closed' 7200
      printf 'REFUSED: %s\n' "$why" > "$dir/home/refuse/shipped"
      if [ "$expected" = unhandled ]; then mkdir "$dir/home/state/.wake-queue"; fi

      sweep "$dir" scan --now 2> "$dir/sweep.err" || fail 'refused cleanup scan failed'
      assert_equals "$expected" "$(jq -r '.workers[0].action' "$dir/home/state/idle-sweep.json")" 'cleanup referral outcome was not published'
      assert_contains "$(jq -r '.workers[0].detail' "$dir/home/state/idle-sweep.json")" "$why" 'cleanup referral lost refusal evidence'
      assert_present "$dir/home/state/shipped.meta" 'a cleanup refusal removed the worker'
      [ "$(calls "$dir" teardown-calls)" = shipped ] || fail 'the guarded cleanup was not attempted'
      [ ! -s "$dir/home/hold-attempts" ] || fail 'a routine cleanup refusal reached the captain'
      if [ "$expected" = unhandled ]; then
        assert_absent "$dir/home/state/idle-sweep/shipped.mate-review" 'failed referral was marked handled'
        rmdir "$dir/home/state/.wake-queue"
      fi
      sweep "$dir" scan --now || fail 'repeated cleanup refusal scan failed'
      sweep "$dir" scan --now || fail 'unchanged cleanup refusal scan failed'
      assert_equals 1 "$(grep -c 'idle-sweep-mate:shipped:' "$dir/home/state/.wake-queue")" 'unchanged cleanup evidence did not refer exactly once'
      printf 'REFUSED: %s; capability changed\n' "$why" > "$dir/home/refuse/shipped"
      sweep "$dir" scan --now || fail 'changed cleanup refusal scan failed'
      assert_equals 2 "$(grep -c 'idle-sweep-mate:shipped:' "$dir/home/state/.wake-queue")" 'changed cleanup refusal did not reach the mate'
      : > "$dir/home/held/shipped"
      rm "$dir/home/teardown-calls"
      sweep "$dir" scan --now || fail 'held cleanup scan failed'
      assert_equals held "$(jq -r '.workers[0].class' "$dir/home/state/idle-sweep.json")" 'a genuine unresolved choice was not honored'
      [ ! -s "$dir/home/teardown-calls" ] || fail 'held cleanup was retried'
      [ ! -s "$dir/home/hold-attempts" ] || fail 'cleanup reassessment raised a captain card'
      if grep -q -- --force "$dir/home/teardown-args"; then fail 'cleanup guards were bypassed'; fi
    done
  done
  pass 'fm-idle-sweep: finished cleanup refusals reach the mate once per change; failed referrals retry and real choices remain held'
}

surface_mate_queue() {
  local dir=$1
  PATH="$dir/bin:$PATH" TASKS_AXI_BACKEND=markdown FM_HOME="$dir/home" \
    bash -c '. "$1/fm-watch.sh"; procevent_surface_queued; printf "no new notifications\n"' _ "$dir/bin"
}

test_long_mate_wake_keys_are_marked_once_per_evidence_change() {
  local dir short_id long_id id expected_markers round
  dir=$(new_case long-mate-wake)
  short_id=$(printf 'worker-%021d' 1)
  long_id=$(printf 'worker-%057d' 1)
  for id in "$short_id" "$long_id"; do
    add_worker "$dir" "$id" 'state: failed · source: run-step · failed check' 90000
  done
  for round in 1 2; do
    sweep "$dir" scan --now || fail 'long-id referral scan failed'
    surface_mate_queue "$dir" > "$dir/watch.out" 2> "$dir/watch.err" || fail 'long-id queue consumer failed'
    for id in "$short_id" "$long_id"; do
      assert_contains "$(cat "$dir/watch.out")" "$id" 'a long-id referral was not surfaced'
    done
    assert_contains "$(cat "$dir/watch.out")" 'mate reassessment of retry or guarded retirement:' 'long-id referral lost its meaning'
    [ ! -s "$dir/watch.err" ] || fail "long-id surfacing failed: $(cat "$dir/watch.err")"
    expected_markers=$((round * 2))
    assert_equals "$expected_markers" "$(find "$dir/home/state" -name '.seen-procevent-*' -type f | wc -l | tr -d ' ')" 'distinct long-id wakes were not durably marked'
    surface_mate_queue "$dir" > "$dir/replay.out" 2> "$dir/replay.err" || fail 'long-id successor consumer failed'
    assert_equals 'no new notifications' "$(cat "$dir/replay.out")" 'an unacknowledged long-id wake surfaced again during handling'
    [ ! -s "$dir/replay.err" ] || fail 'the successor could not read long-id markers'
    for id in "$short_id" "$long_id"; do
      printf 'failed: new check result\n' >> "$dir/home/state/$id.status"
      age_file "$dir/home/state/$id.status" 90000
    done
  done
  [ ! -s "$dir/home/hold-attempts" ] || fail 'long-id referrals reached the captain'
  pass 'fm-idle-sweep: long mate wake keys surface once per evidence change, not once per successor'
}

test_finished_cleanup_refusals_are_assessed_by_the_mate
test_long_mate_wake_keys_are_marked_once_per_evidence_change
test_local_only_completion_is_assessed_by_the_mate
test_orphan_mate_waits_cover_original_and_linked_calls
test_parked_evidence_ignores_observation_time_but_tracks_git_changes
test_real_parked_withdrawals_survive_later_sweeps
test_real_holds_check_worker_records_inside_the_lifecycle_lock
test_done_workers_are_cleaned_up_without_force
test_closed_unmerged_prs_require_a_cleanup_decision
test_merged_mr_in_ledger_is_passed_to_teardown
test_retired_worker_keeps_ledger_only_merged_mr_without_a_card
test_only_lifecycle_contention_defers_cleanup_refusals
test_pending_backlog_closes_remain_visible_until_cleared
test_open_pr_workers_wait_for_merge_without_a_cleanup_decision
test_concurrent_cleanup_does_not_raise_stale_decisions
test_refusals_and_idle_workers_are_referred_to_the_mate
test_a_raised_worker_is_raised_again_only_after_its_ledger_changes
test_reassigned_slots_cannot_supply_completion
test_closed_worker_gets_a_linked_followup_hold
test_record_less_endpoints_are_closed_as_orphans
test_refused_orphans_are_referred_without_captain_calls
test_orphan_decisions_gate_closure_and_repeated_escalation
test_unreadable_holds_prevent_worker_and_orphan_actions
test_second_mates_that_do_not_sweep_are_escalated_once
test_local_mates_with_missing_homes_are_escalated
test_scan_uses_fixed_quiet_and_audit_bounds
test_watcher_runs_the_sweep_and_surfaces_its_decision
test_done_ships_without_merge_evidence_are_never_cleaned_automatically
test_a_cleanup_finishing_during_the_hold_mints_no_followup_call
test_a_main_home_is_woken_once_for_what_the_sweep_could_not_handle
test_a_worker_named_like_an_orphan_call_still_gets_the_record_check
