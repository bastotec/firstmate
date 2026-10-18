#!/usr/bin/env bash
# tests/fm-idle-sweep.test.sh - the watcher-run idle-worker sweep owned by
# bin/fm-idle-sweep.sh.
#
# bin/fm-idle-sweep.sh's header owns the cleanup, retire-or-retry, first-mate
# hand-off, admission, repeat-suppression, and second-mate audit guarantees
# exercised here. The sweep never sends the captain a card.
#
# bin/ is copied into each case with the crew-state, teardown, retirement,
# control, captain-hold, card and fm-on scripts replaced by recording stubs
# driven by files in the case home, so the decisions the sweep makes are
# observed directly.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-idle-sweep)

new_case() {  # <name> -> case dir; its home is <dir>/home
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config"
  cp -R "$ROOT/bin" "$dir/bin"
  cat > "$dir/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_HOME/crew-state-calls"
if [ -d "$FM_HOME/state/.control-$1.lock" ]; then
  printf '%s\n' "$1" >> "$FM_HOME/crew-state-locked"
fi
[ ! -x "$FM_HOME/on-crew-state" ] || "$FM_HOME/on-crew-state" "$1"
cat "$FM_HOME/crew/$1" 2>/dev/null || echo 'state: unknown · source: none · no fixture'
SH
  cat > "$dir/bin/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
id=$1
args=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = --expected-record ]; then
    shift
    [ "$(cat "$FM_HOME/state/$id.meta")" = "$1" ] || exit 3
  elif [ "$1" = --if-still-stopped ]; then
    shift
    printf '%s %s\n' "$id" "$1" >> "$FM_HOME/cleanup-guards"
  else
    args+=("$1")
  fi
  shift
done
set -- "${args[@]}"
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
  cat > "$dir/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "$2" >> "$FM_HOME/control-calls"
if [ "$2" = relaunch ]; then
  if [ "$#" -ne 8 ] || [ "$3" != --expected-record ] || [ "$(cat "$FM_HOME/state/$1.meta")" != "$4" ]; then exit 3; fi
  [ "$5" = --if-still-stopped ] && [ "$6" = "$(wc -c < "$FM_HOME/state/$1.status" | tr -d ' ')" ] || exit 3
  set -- "$1" "$2" "$7" "$8"
  if [ "$3" != --note ] || [ -z "$4" ]; then
    echo 'REFUSED: relaunch requires a nonempty --note' >&2
    exit 1
  fi
  printf '%s\n' "$4" > "$FM_HOME/control-note-$1"
fi
if [ -f "$FM_HOME/control-refuse/$1" ]; then cat "$FM_HOME/control-refuse/$1" >&2; exit 1; fi
exit 0
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
  # Probes answer from fixture files; anything else (a hold, a card) is a
  # captain call the sweep must never make, so it is only recorded.
  cat > "$dir/bin/fm-captain-hold.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  open|deferred) [ -f "$FM_HOME/unreadable/$1-$2" ] && exit 2 ;;
esac
case "$1" in
  open) [ -f "$FM_HOME/held/$2" ] && exit 0; exit 1 ;;
  deferred) [ -f "$FM_HOME/deferred/$2" ] && exit 0; exit 1 ;;
  *) printf 'fm-captain-hold.sh %s\n' "$*" >> "$FM_HOME/hold-attempts" ;;
esac
SH
  cat > "$dir/bin/fm-card.sh" <<'SH'
#!/usr/bin/env bash
printf 'fm-card.sh %s\n' "$*" >> "$FM_HOME/hold-attempts"
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
  if [ "${3:-}" = --full ]; then
    case "$(cat "$FM_HOME/backlog-read-mode" 2>/dev/null)" in
      failed) echo 'backend unavailable' >&2; exit 1 ;;
      timeout) printf 'task:\n  state: queued\n'; sleep 3; exit 0 ;;
      empty) exit 0 ;;
      missing-state) printf 'task:\n  body: "Superseded: replacement"\n'; exit 0 ;;
      malformed-body) printf 'task:\n  state: queued\n  body: "unterminated\n'; exit 0 ;;
    esac
  fi
  cat "$FM_HOME/rows/$2" 2>/dev/null && exit 0
  echo 'code: NOT_FOUND'
fi
exit 1
SH
  cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/forge-calls"
if [ -f "$FM_HOME/replace-on-forge" ]; then
  id=$(cat "$FM_HOME/replace-on-forge")
  cp "$FM_HOME/replacement/$id" "$FM_HOME/state/$id.meta"
fi
[ ! -x "$FM_HOME/on-forge" ] || "$FM_HOME/on-forge"
cat "$FM_HOME/pr-states/${3##*/}" 2>/dev/null || exit 1
SH
  cat > "$dir/bin/glab" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/forge-calls"
state=$(cat "$FM_HOME/pr-states/$3" 2>/dev/null) || exit 1
printf 'state: %s\n' "$state"
SH
  chmod +x "$dir"/bin/fm-crew-state.sh "$dir"/bin/fm-teardown.sh "$dir"/bin/fm-control.sh \
    "$dir"/bin/fm-retire-endpoint.sh "$dir"/bin/fm-captain-hold.sh "$dir"/bin/fm-card.sh "$dir"/bin/fm-on.sh \
    "$dir"/bin/tasks-axi "$dir"/bin/gh "$dir"/bin/glab
  mkdir -p "$dir/home/crew" "$dir/home/refuse" "$dir/home/held" "$dir/home/deferred" "$dir/home/unreadable" \
    "$dir/home/rows" "$dir/home/pr-states" "$dir/home/concurrent-cleanup" "$dir/home/replacement" "$dir/home/pending-close" \
    "$dir/home/control-refuse"
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
  printf -- '- %s: Open work\n  state: in_flight\n' "$id" > "$dir/home/rows/$id"
  # a run whose PR merged carries that PR, as a delivered ship's record does
  case "$line" in
    *'PR merged/closed'*)
      n=$(printf '%s' "$id" | cksum | cut -d' ' -f1)
      printf 'pr=https://github.com/owner/repo/pull/9%s\n' "$n" >> "$dir/home/state/$id.meta"
      printf 'MERGED\n' > "$dir/home/pr-states/9$n"
      ;;
  esac
}

# make_secondmate_home <dir> <mate-id>: bind the case home to a local parent
# home at <dir>/parent, whose state/<mate-id>.status is its parent channel.
make_secondmate_home() {
  local dir=$1 mate=$2
  mkdir -p "$dir/parent/state"
  printf '%s\n' "$mate" > "$dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$dir/parent" \
    > "$dir/home/.fm-secondmate-parent"
}

sweep() {  # <dir> [args...]
  local dir=$1
  shift
  PATH="$dir/bin:$PATH" TASKS_AXI_BACKEND=markdown FM_HOME="$dir/home" "$dir/bin/fm-idle-sweep.sh" "$@"
}

calls() {  # <dir> <file>
  cat "$dir/home/$2" 2>/dev/null || true
}

summary_of() {  # <dir> <id> -> "class action"
  jq -r --arg id "$2" '.workers[] | select(.id==$id) | [.class,.action] | join(" ")' "$1/home/state/idle-sweep.json"
}

assert_no_captain_call() {  # <dir> <context>
  [ ! -s "$1/home/hold-attempts" ] || fail "$2: the sweep made a captain call: $(cat "$1/home/hold-attempts")"
  [ "$(jq '[.workers[] | select(.hold_id != null)] | length' "$1/home/state/idle-sweep.json")" = 0 ] \
    || fail "$2: the summary names a captain hold"
  [ "$(jq '[.workers[] | select(.action=="carded")] | length' "$1/home/state/idle-sweep.json")" = 0 ] \
    || fail "$2: the summary reports a card"
}

wake_count() {  # <dir> <fixed-pattern>
  grep -cF -- "$2" "$1/home/state/.wake-queue" 2>/dev/null || true
}

test_unreadable_backlog_items_are_handed_to_the_first_mate() {
  local dir mode home
  for home in main second-mate; do
    for mode in failed timeout missing empty missing-state malformed-body; do
      dir=$(new_case "unreadable-backlog-$home-$mode")
      [ "$home" != second-mate ] || make_secondmate_home "$dir" mate
      add_worker "$dir" stopped 'state: paused · source: status-log · waiting' 90000
      printf -- '- stopped: Old work\n  state: queued\n  body: "Superseded: replacement"\n' > "$dir/home/rows/stopped"
      printf '%s\n' "$mode" > "$dir/home/backlog-read-mode"
      [ "$mode" != missing ] || rm "$dir/home/rows/stopped"
      cp "$dir/home/state/stopped.meta" "$dir/before.meta"
      FM_BACKLOG_ROW_TIMEOUT_SECS=1 sweep "$dir" scan --now || fail "unreadable backlog scan failed"
      assert_equals 'stalled asked' "$(summary_of "$dir" stopped)" "$mode backlog reads need the first mate's decision"
      assert_absent "$dir/home/control-calls" "$mode backlog reads must never authorize a retry"
      assert_absent "$dir/home/teardown-calls" "$mode backlog reads must never authorize retirement"
      assert_absent "$dir/home/state/idle-sweep/stopped.retried" "$mode backlog reads must not consume retry authority"
      cmp -s "$dir/before.meta" "$dir/home/state/stopped.meta" || fail "an unreadable backlog read changed the worker"
      assert_present "$dir/home/state/idle-sweep/stopped.raised" "the backlog handoff must be recorded"
      if [ "$home" = main ]; then
        assert_contains "$(cat "$dir/home/state/.wake-queue")" 'decide yourself whether to retire or retry stopped' "the first mate was not asked"
      else
        assert_contains "$(cat "$dir/parent/state/mate.status")" 'needs-decision [key=idle-stopped]' "the parent mate was not asked"
        assert_contains "$(cat "$dir/parent/state/mate.status")" 'the full backlog item could not be read' "the parent needs the uncertainty reason"
      fi
      assert_no_captain_call "$dir" "an unreadable backlog item"
    done
  done
  pass "fm-idle-sweep: failed, timed-out and incomplete backlog reads go to the first mate, never retry"
}

test_unreadable_prs_are_handed_to_the_first_mate() {
  local dir state
  for state in missing empty unknown; do
    dir=$(new_case "unreadable-pr-$state")
    add_worker "$dir" stopped 'state: failed · source: run-step · run failed' 90000
    printf -- '- stopped: Open work\n  state: in_flight\n' > "$dir/home/rows/stopped"
    printf 'pr=https://github.com/owner/repo/pull/71\n' >> "$dir/home/state/stopped.meta"
    case "$state" in
      empty) : > "$dir/home/pr-states/71" ;;
      unknown) printf 'UNKNOWN\n' > "$dir/home/pr-states/71" ;;
    esac
    sweep "$dir" scan --now || fail "unreadable PR scan failed"
    assert_equals 'failed asked' "$(summary_of "$dir" stopped)" "an unreadable PR needs the first mate's decision"
    assert_absent "$dir/home/control-calls" "an unreadable PR must never authorize a retry"
    assert_absent "$dir/home/teardown-calls" "an unreadable PR must never authorize retirement"
    assert_contains "$(cat "$dir/home/state/.wake-queue")" 'decide yourself whether to retire or retry stopped' "the first mate was not asked"
    assert_no_captain_call "$dir" "an unreadable PR"
  done
  pass "fm-idle-sweep: unreadable PR states go to the first mate, never retry"
}

test_replacements_during_forge_reads_are_left_for_a_fresh_scan() {
  local dir verdict outcome line
  for verdict in failed dead finished; do
    for outcome in OPEN MERGED; do
      dir=$(new_case "replace-$verdict-$outcome")
      case "$verdict" in
        failed) line='state: failed · source: run-step · run failed' ;;
        dead) line='state: unknown · source: none · backend target gone' ;;
        finished) line='state: done · source: run-step · run passed' ;;
      esac
      add_worker "$dir" stopped "$line" 90000
      printf 'pr=https://github.com/owner/repo/pull/71\nspawn_gen=old\n' >> "$dir/home/state/stopped.meta"
      printf '%s\n' "$outcome" > "$dir/home/pr-states/71"
      fm_write_meta "$dir/home/replacement/stopped" "kind=ship" "spawn_gen=new" "worktree=$dir/new-worker"
      printf 'stopped\n' > "$dir/home/replace-on-forge"
      cp "$ROOT/bin/fm-control.sh" "$ROOT/bin/fm-teardown.sh" "$dir/bin/"
      sweep "$dir" scan --now || fail "replacement scan failed"
      if [ "$verdict-$outcome" = finished-OPEN ]; then
        assert_equals 'awaiting-merge none' "$(summary_of "$dir" stopped)" "an open PR should still wait for merge"
      else
        assert_equals 'unknown none' "$(summary_of "$dir" stopped)" "a replacement must wait for a fresh scan"
      fi
      cmp -s "$dir/home/replacement/stopped" "$dir/home/state/stopped.meta" || fail "a replacement was changed"
      assert_absent "$dir/home/state/idle-sweep/stopped.raised" "a stale decision must not be suppressed"
      assert_absent "$dir/home/state/idle-sweep/stopped.retried" "a replacement must not count as a retry"
      [ ! -s "$dir/home/state/.wake-queue" ] || fail "a replacement got a stale decision wake"
      assert_no_captain_call "$dir" "a replacement"
    done
  done
  pass "fm-idle-sweep: lifecycle owners refuse stale retry and retirement snapshots"
}

test_recovered_workers_are_not_retried_with_unchanged_metadata() {
  local dir recovery before target
  for recovery in working parked 'done' unknown busy newer-status during-refresh still-blocked still-failed still-paused no-ledger; do
    dir=$(new_case "recovered-$recovery")
    add_worker "$dir" stopped 'state: blocked · source: status-log · waiting for an unblock' 90000
    fm_git_init_commit "$dir/pool/1/firstmate"
    fm_test_stream_task "$dir/home/state" stopped "$dir/endpoint-input" >> "$dir/home/state/stopped.meta"
    printf 'harness=deck\nproject=%s\npr=https://github.com/owner/repo/pull/71\n' "$dir/pool/1/firstmate" \
      >> "$dir/home/state/stopped.meta"
    target=$(sed -n 's/^window=//p' "$dir/home/state/stopped.meta")
    fm_test_fake_stream_foreground "$target" fm-deck-worker
    case "$recovery" in
      still-*|no-ledger)
        printf 'state: %s · source: status-log · stopped\n' "${recovery#still-}" > "$dir/home/crew/stopped"
        fm_test_fake_stream_foreground "$target" zsh
        ;;
    esac
    if [ "$recovery" = no-ledger ]; then
      printf 'state: failed · source: run-step · run failed\n' > "$dir/home/crew/stopped"
      rm "$dir/home/state/stopped.status"
      age_file "$dir/home/state/stopped.meta" 90000
    fi
    "$dir/bin/fm-busy-event.sh" arm "$dir/home/state" stopped --state idle >/dev/null
    mkdir -p "$dir/home/data/stopped"
    printf '# Continue the task\n' > "$dir/home/data/stopped/brief.md"
    printf 'OPEN\n' > "$dir/home/pr-states/71"
    printf '%s\n' "$recovery" > "$dir/home/recovery"
    cp "$ROOT/bin/fm-control.sh" "$dir/bin/"
    cat > "$dir/bin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
id=$(sed -n 's/^stream_endpoint_id=//p' "$FM_HOME/state/$1.meta")
curl -fsS -m 10 --config <(printf 'header = "Authorization: Bearer %s"\n' "$FM_STREAM_TOKEN") \
  -X POST -H 'Content-Type: application/json' \
  --data-binary '{"foreground":[{"pid":"","name":"fm-deck-worker","argv0":"fm-deck-worker","args":"fm-deck-worker"}]}' \
  "$FM_TEST_STREAM_URL/v1/test/endpoints/$id" >/dev/null || exit 1
printf '%s\n' "$1" >> "$FM_HOME/spawn-calls"
SH
    chmod +x "$dir/bin/fm-spawn.sh"
    cat > "$dir/home/on-forge" <<'SH'
#!/usr/bin/env bash
case "$(cat "$FM_HOME/recovery")" in
  working|parked|done|unknown)
    printf 'state: %s · source: run-step · fresh activity\n' "$(cat "$FM_HOME/recovery")" > "$FM_HOME/crew/stopped"
    ;;
  busy)
    "$FM_HOME/../bin/fm-busy-event.sh" apply "$FM_HOME/state" stopped busy --current-gen --source deck-wrapper --event turn-start
    ;;
  newer-status) printf 'blocked: a newer concern\n' >> "$FM_HOME/state/stopped.status" ;;
esac
SH
    cat > "$dir/home/on-crew-state" <<'SH'
#!/usr/bin/env bash
if [ "$(cat "$FM_HOME/recovery")" = during-refresh ] && [ -d "$FM_HOME/state/.control-$1.lock" ]; then
  printf 'blocked: a newer concern during the state read\n' >> "$FM_HOME/state/$1.status"
fi
SH
    chmod +x "$dir/home/on-forge" "$dir/home/on-crew-state"
    before=$(cat "$dir/home/state/stopped.meta")

    sweep "$dir" scan --now || fail "recovery scan failed for $recovery"

    assert_equals "$before" "$(cat "$dir/home/state/stopped.meta")" "$recovery changed the worker incarnation"
    assert_equals 2 "$(wc -l < "$dir/home/crew-state-calls" | tr -d ' ')" "$recovery must refresh the current state"
    assert_equals stopped "$(cat "$dir/home/crew-state-locked")" "$recovery must be revalidated under the lifecycle lock"
    case "$recovery" in
      still-*|no-ledger)
        assert_contains "$(summary_of "$dir" stopped)" ' retried' "$recovery must remain eligible for retry"
        assert_equals stopped "$(cat "$dir/home/spawn-calls")" "$recovery did not reach the launch owner"
        assert_present "$dir/home/state/idle-sweep/stopped.retried" "$recovery did not record the retry"
        if [ "$recovery" = no-ledger ]; then
          assert_equals '0 1' "$(cat "$dir/home/state/idle-sweep/stopped.retried")" "a missing ledger must consume exactly one retry at size zero"
          sweep "$dir" scan --now || fail "repeat missing-ledger scan failed"
          assert_equals 'failed asked' "$(summary_of "$dir" stopped)" "an unchanged missing ledger must not authorize another retry"
          assert_equals stopped "$(cat "$dir/home/spawn-calls")" "the missing-ledger worker was relaunched twice"
        fi
        assert_no_captain_call "$dir" "$recovery"
        continue
        ;;
    esac
    assert_equals 'unknown none' "$(summary_of "$dir" stopped)" "$recovery should wait for a fresh scan"
    assert_absent "$dir/home/state/stopped.control-relaunch" "$recovery opened a relaunch transaction"
    [ ! -s "$dir/endpoint-input" ] || fail "$recovery sent lifecycle input to the recovered worker"
    assert_absent "$dir/home/state/idle-sweep/stopped.retried" "$recovery consumed a retry"
    assert_absent "$dir/home/state/idle-sweep/stopped.raised" "$recovery was handed off"
    [ ! -s "$dir/home/state/.wake-queue" ] || fail "$recovery queued a stale decision wake"
    assert_no_captain_call "$dir" "$recovery"
  done
  pass "fm-idle-sweep: recovered workers and newer status are skipped under the control lock"
}

test_resumed_workers_are_not_retired_after_a_merged_pr_read() {
  local dir recovery before target
  for recovery in working parked done unknown busy newer-status during-refresh teardown-busy teardown-newer-status; do
    dir=$(new_case "retirement-recovery-$recovery")
    add_worker "$dir" stopped 'state: paused · source: status-log · waiting' 90000
    fm_git_init_commit "$dir/pool/1/firstmate"
    fm_test_stream_task "$dir/home/state" stopped "$dir/endpoint-input" >> "$dir/home/state/stopped.meta"
    printf 'harness=deck\nproject=%s\npr=https://github.com/owner/repo/pull/71\n' "$dir/pool/1/firstmate" \
      >> "$dir/home/state/stopped.meta"
    target=$(sed -n 's/^window=//p' "$dir/home/state/stopped.meta")
    fm_test_fake_stream_foreground "$target" fm-deck-worker
    "$dir/bin/fm-busy-event.sh" arm "$dir/home/state" stopped --state idle >/dev/null
    printf 'MERGED\n' > "$dir/home/pr-states/71"
    printf '%s\n' "$recovery" > "$dir/home/recovery"
    cp "$ROOT/bin/fm-teardown.sh" "$dir/bin/"
    cat > "$dir/home/on-forge" <<'SH'
#!/usr/bin/env bash
case "$(cat "$FM_HOME/recovery")" in
  working|parked|done|unknown)
    printf 'state: %s · source: run-step · fresh activity\n' "$(cat "$FM_HOME/recovery")" > "$FM_HOME/crew/stopped"
    ;;
  busy)
    "$FM_HOME/../bin/fm-busy-event.sh" apply "$FM_HOME/state" stopped busy --current-gen --source deck-wrapper --event turn-start
    ;;
  newer-status) printf 'working: resumed\n' >> "$FM_HOME/state/stopped.status" ;;
  teardown-*)
    [ -d "$FM_HOME/state/.control-stopped.lock" ] || exit 0
    printf '%s\n' 'resumed during teardown PR lookup' > "$FM_HOME/resumed-at-teardown"
    case "$(cat "$FM_HOME/recovery")" in
      teardown-busy)
        "$FM_HOME/../bin/fm-busy-event.sh" apply "$FM_HOME/state" stopped busy --current-gen --source deck-wrapper --event turn-start
        ;;
      teardown-newer-status) printf 'working: resumed\n' >> "$FM_HOME/state/stopped.status" ;;
    esac
    ;;
esac
SH
    cat > "$dir/home/on-crew-state" <<'SH'
#!/usr/bin/env bash
if [ "$(cat "$FM_HOME/recovery")" = during-refresh ] && [ -d "$FM_HOME/state/.control-$1.lock" ]; then
  printf 'working: resumed during the state read\n' >> "$FM_HOME/state/$1.status"
fi
SH
    chmod +x "$dir/home/on-forge" "$dir/home/on-crew-state"
    before=$(cat "$dir/home/state/stopped.meta")

    sweep "$dir" scan --now || fail "retirement recovery scan failed for $recovery"

    assert_equals 'unknown none' "$(summary_of "$dir" stopped)" "$recovery must skip retirement this scan"
    assert_equals "$before" "$(cat "$dir/home/state/stopped.meta")" "$recovery changed the worker incarnation"
    case "$recovery" in
      teardown-*)
        assert_present "$dir/home/resumed-at-teardown" "$recovery did not reach teardown's PR lookup"
        [ "$(wc -l < "$dir/home/crew-state-calls" | tr -d ' ')" -ge 3 ] \
          || fail "$recovery must refresh activity after teardown's PR lookup"
        ;;
      *)
        assert_equals 2 "$(wc -l < "$dir/home/crew-state-calls" | tr -d ' ')" "$recovery must refresh state before retirement"
        ;;
    esac
    assert_equals stopped "$(tail -1 "$dir/home/crew-state-locked")" "$recovery must be checked under the lifecycle lock"
    fm_test_fake_stream_endpoints | jq -e --arg endpoint "${target##*:}" \
      '.endpoints | any(.endpoint_id == $endpoint)' >/dev/null \
      || fail "$recovery killed the resumed endpoint"
    assert_absent "$dir/home/state/stopped.backlog-close" "$recovery staged a backlog close"
    assert_absent "$dir/home/control-calls" "$recovery was retried instead of preserved"
    assert_absent "$dir/home/state/idle-sweep/stopped.raised" "$recovery was handed off"
    [ ! -s "$dir/endpoint-input" ] || fail "$recovery sent input to the resumed endpoint"
    [ ! -s "$dir/home/state/.wake-queue" ] || fail "$recovery queued a stale decision"
    assert_no_captain_call "$dir" "$recovery retirement"
    case "$recovery" in
      teardown-*)
        rm "$dir/home/on-forge" "$dir/home/pr-states/71"
        age_file "$dir/home/state/stopped.status" 90000
        sweep "$dir" scan --now || fail "$recovery follow-up scan failed"
        assert_equals 'stalled asked' "$(summary_of "$dir" stopped)" "$recovery must remain eligible for a later hand-off"
        ;;
    esac
  done
  pass "fm-idle-sweep: merged PRs never retire workers that resumed or wrote newer status"
}

test_retired_backend_cleanup_preserves_the_expected_record_guard() {
  local dir expected rc mode size
  for mode in stale matching replaced-at-teardown working busy newer-status during-refresh recovered-at-teardown; do
    dir=$(new_case "retire-guard-$mode")
    cp "$ROOT/bin/fm-retire-endpoint.sh" "$dir/bin/"
    cp "$ROOT/bin/fm-teardown.sh" "$dir/bin/fm-teardown-real.sh"
    fm_write_meta "$dir/home/state/stopped.meta" "kind=scout" "harness=deck" "backend=herdr" "window=fixture:stopped" "spawn_gen=old"
    printf 'paused: waiting\n' > "$dir/home/state/stopped.status"
    printf 'state: paused · source: status-log · waiting\n' > "$dir/home/crew/stopped"
    size=$(wc -c < "$dir/home/state/stopped.status" | tr -d ' ')
    expected=$(cat "$dir/home/state/stopped.meta")
    fm_write_meta "$dir/home/replacement/stopped" "kind=scout" "backend=herdr" "window=fixture:stopped" "spawn_gen=new"
    case "$mode" in
      matching) rm "$dir/home/replacement/stopped" ;;
      stale) cp "$dir/home/replacement/stopped" "$dir/home/state/stopped.meta" ;;
      replaced-at-teardown)
        cat > "$dir/bin/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
cp "$FM_HOME/replacement/$1" "$FM_HOME/state/$1.meta"
exec "$REAL_TEARDOWN" "$@"
SH
        ;;
      working) printf 'state: working · source: run-step · resumed\n' > "$dir/home/crew/stopped" ;;
      busy)
        "$dir/bin/fm-busy-event.sh" arm "$dir/home/state" stopped --state busy >/dev/null
        ;;
      newer-status) printf 'working: resumed\n' >> "$dir/home/state/stopped.status" ;;
      during-refresh)
        cat > "$dir/home/on-crew-state" <<'SH'
#!/usr/bin/env bash
printf 'working: resumed during the state read\n' >> "$FM_HOME/state/$1.status"
SH
        chmod +x "$dir/home/on-crew-state"
        ;;
      recovered-at-teardown)
        cat > "$dir/bin/fm-teardown.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: working · source: run-step · resumed\n' > "$FM_HOME/crew/$1"
exec "$REAL_TEARDOWN" "$@"
SH
        ;;
    esac
    rc=0
    REAL_TEARDOWN="$dir/bin/fm-teardown-real.sh" FM_HOME="$dir/home" PATH="$dir/bin:$PATH" \
      "$dir/bin/fm-retire-endpoint.sh" --finished stopped --expected-record "$expected" --if-still-stopped "$size" \
      > "$dir/retire.out" 2>&1 || rc=$?
    if [ "$mode" = matching ]; then
      assert_equals 0 "$rc" "matching retired records should still clean up: $(cat "$dir/retire.out")"
      assert_absent "$dir/home/state/stopped.meta" "a matching record was not cleaned"
    else
      assert_equals 3 "$rc" "$mode retirement evidence must be refused as stale: $(cat "$dir/retire.out")"
      case "$mode" in
        stale|replaced-at-teardown)
          cmp -s "$dir/home/replacement/stopped" "$dir/home/state/stopped.meta" || fail "retirement changed a replacement"
          ;;
        *) assert_equals "$expected" "$(cat "$dir/home/state/stopped.meta")" "$mode retirement changed the worker" ;;
      esac
      assert_absent "$dir/home/state/stopped.backlog-close" "$mode retirement must not close the task"
      case "$mode" in
        replaced-at-teardown|recovered-at-teardown) ;;
        *) assert_absent "$dir/home/state/endpoint-retirements.log" "$mode evidence must not record a retirement assertion" ;;
      esac
    fi
    assert_absent "$dir/home/state/stopped.endpoint-retired" "retirement must release its temporary assertion"
    assert_absent "$dir/home/state/.control-stopped.lock" "retirement must release its lifecycle lock"
  done
  pass "fm-idle-sweep: retired-backend cleanup revalidates records and activity before and inside teardown"
}

test_a_failed_main_home_delivery_is_retried_next_scan() {
  local dir
  dir=$(new_case failed-wake)
  add_worker "$dir" stopped 'state: failed · source: run-step · run failed' 90000
  printf 'REFUSED: recovery could not start\n' > "$dir/home/control-refuse/stopped"
  mkdir "$dir/home/state/.wake-queue"
  sweep "$dir" scan --now || fail "failed delivery scan failed"
  assert_absent "$dir/home/state/idle-sweep/stopped.raised" "a failed wake must not suppress the next handoff"
  rmdir "$dir/home/state/.wake-queue"
  sweep "$dir" scan --now || fail "redelivery scan failed"
  assert_equals 'failed asked' "$(summary_of "$dir" stopped)" "failed delivery was not retried"
  assert_equals 1 "$(wake_count "$dir" 'decide yourself whether to retire or retry stopped')" "the handoff was not delivered once"
  assert_present "$dir/home/state/idle-sweep/stopped.raised" "successful delivery must commit suppression"
  sweep "$dir" scan --now || fail "suppressed scan failed"
  assert_equals 'raised none' "$(summary_of "$dir" stopped)" "successful redelivery was not suppressed"
  assert_equals 1 "$(wake_count "$dir" 'decide yourself whether to retire or retry stopped')" "successful handoff was repeated"
  pass "fm-idle-sweep: failed main-home delivery remains eligible until a wake is queued"
}

test_a_stopped_worker_with_open_work_is_retried_once_without_a_card() {
  local dir
  dir=$(new_case retry-open)
  add_worker "$dir" open-work 'state: failed · source: run-step · run failed' 90000
  printf -- '- open-work: Open work\n  state: in_flight\n' > "$dir/home/rows/open-work"
  printf 'pr=https://github.com/owner/repo/pull/71\n' >> "$dir/home/state/open-work.meta"
  printf 'OPEN\n' > "$dir/home/pr-states/71"
  add_worker "$dir" no-pr 'state: blocked · source: status-log · needs a token' 90000

  sweep "$dir" scan --now || fail "scan failed"

  [ "$(calls "$dir" control-calls | sort | tr '\n' ',')" = 'no-pr relaunch,open-work relaunch,' ] \
    || fail "stopped workers with unfinished work were not relaunched once each: $(calls "$dir" control-calls)"
  [ ! -s "$dir/home/teardown-calls" ] || fail "a worker with unfinished work was retired: $(calls "$dir" teardown-calls)"
  for id in open-work no-pr; do
    assert_equals 'Restarted by the idle sweep: your task is still open and unfinished. Read your inbox in order and continue it.' \
      "$(cat "$dir/home/control-note-$id")" "retrying $id did not supply the recovery note"
    assert_present "$dir/home/state/$id.meta" "retrying $id removed its record"
    assert_present "$dir/home/state/idle-sweep/$id.retried" "the retry of $id was not recorded"
    assert_absent "$dir/home/state/idle-sweep/$id.raised" "a retried worker was also handed off"
  done
  assert_equals 'failed retried' "$(summary_of "$dir" open-work)" "the retry was not published"
  assert_equals 'stalled retried' "$(summary_of "$dir" no-pr)" "the stalled retry was not published"
  assert_no_captain_call "$dir" "a retried worker"
  assert_equals 1 "$(wake_count "$dir" 'idle-sweep:')" "a main home should get one FYI wake"
  assert_contains "$(cat "$dir/home/state/.wake-queue")" 'retried no-pr open-work' "the FYI should name the retried workers"
  assert_contains "$(cat "$dir/home/state/.wake-queue")" 'never send the captain a card' "the FYI should keep the captain out of it"
  pass "fm-idle-sweep: a stopped worker whose work is still open is retried once through relaunch, never carded"
}

test_a_stopped_worker_whose_work_landed_or_ended_is_retired() {
  local dir
  dir=$(new_case retire-stopped)
  add_worker "$dir" merged 'state: failed · source: run-step · run failed' 90000
  printf 'pr=https://github.com/owner/repo/pull/61\n' >> "$dir/home/state/merged.meta"
  printf 'MERGED\n' > "$dir/home/pr-states/61"
  add_worker "$dir" closed 'state: blocked · source: status-log · needs a token' 90000
  printf 'pr=https://github.com/owner/repo/pull/62\n' >> "$dir/home/state/closed.meta"
  printf 'CLOSED\n' > "$dir/home/pr-states/62"
  add_worker "$dir" done-row 'state: unknown · source: none · backend target gone: hub:abc' 90000
  printf -- '- done-row: Done row\n  state: done\n' > "$dir/home/rows/done-row"
  add_worker "$dir" superseded 'state: paused · source: status-log · waiting' 90000
  printf -- '- superseded: Old take\n  state: queued\n  body: "Earlier investigation.\\nSuperseded: replaced by new-take"\n' > "$dir/home/rows/superseded"
  add_worker "$dir" refused 'state: failed · source: run-step · run failed' 90000
  printf -- '- refused: Refused\n  state: done\n' > "$dir/home/rows/refused"
  printf 'REFUSED: worktree /pool/refused has uncommitted changes\n' > "$dir/home/refuse/refused"

  sweep "$dir" scan --now || fail "scan failed"

  assert_grep 'merged --keep-commits --merged-pr https://github.com/owner/repo/pull/61' "$dir/home/teardown-args" \
    "a merged worker was not retired through teardown with its verified PR"
  assert_equals "merged $(wc -c < "$dir/home/state/merged.status" | tr -d ' ')" \
    "$(grep '^merged ' "$dir/home/cleanup-guards")" "retirement must carry the classified activity snapshot"
  for id in closed done-row superseded refused; do
    grep -qx "$id --keep-commits" "$dir/home/teardown-args" || fail "$id was not retired through teardown --keep-commits: $(calls "$dir" teardown-args)"
  done
  if grep -q -- --force "$dir/home/teardown-args"; then fail "retirement passed --force: $(calls "$dir" teardown-args)"; fi
  [ ! -s "$dir/home/control-calls" ] || fail "a worker whose work ended was relaunched: $(calls "$dir" control-calls)"
  for id in merged closed done-row superseded; do
    assert_absent "$dir/home/state/$id.meta" "$id was not retired"
    [ "$(summary_of "$dir" "$id" | cut -d' ' -f2)" = retired ] || fail "$id retirement was not published: $(summary_of "$dir" "$id")"
  done
  assert_present "$dir/home/state/refused.meta" "a refused retirement removed the record"
  assert_equals 'failed asked' "$(summary_of "$dir" refused)" "a refused retirement should go to the first mate"
  assert_present "$dir/home/state/idle-sweep/refused.raised" "the refused retirement hand-off was not recorded"
  assert_no_captain_call "$dir" "retirement"
  assert_equals 1 "$(wake_count "$dir" 'idle-sweep:')" "a main home should get one wake"
  assert_contains "$(cat "$dir/home/state/.wake-queue")" 'retired closed done-row merged superseded' "the wake should list what was retired"
  assert_contains "$(cat "$dir/home/state/.wake-queue")" 'decide yourself whether to retire or retry refused' \
    "the wake should hand the refused retirement to the first mate"
  pass "fm-idle-sweep: a stopped worker whose PR merged or closed, or whose item is done or superseded, is retired with --keep-commits"
}

test_supersession_requires_a_decoded_body_marker() {
  local dir id
  dir=$(new_case supersession-marker)
  for id in title-only body-only note-only empty-marker; do
    add_worker "$dir" "$id" 'state: failed · source: run-step · run failed' 90000
  done
  printf -- '- title-only: Fix superseded request handling\n  state: in_flight\n' > "$dir/home/rows/title-only"
  printf -- '- body-only: Fix request handling\n  state: in_flight\n  body: "This work is not superseded."\n' > "$dir/home/rows/body-only"
  printf -- '- note-only: Fix request handling\n  state: in_flight\n  note: Investigate superseded requests\n' > "$dir/home/rows/note-only"
  printf -- '- empty-marker: Fix request handling\n  state: in_flight\n  body: "Superseded: "\n' > "$dir/home/rows/empty-marker"

  sweep "$dir" scan --now || fail "scan failed"

  assert_equals 4 "$(wc -l < "$dir/home/control-calls" | tr -d ' ')" "all unfinished tasks should be retried"
  assert_absent "$dir/home/teardown-calls" "ordinary task prose must not authorize retirement"
  for id in title-only body-only note-only empty-marker; do
    assert_equals 'failed retried' "$(summary_of "$dir" "$id")" "$id was mistaken for superseded work"
    assert_present "$dir/home/state/$id.meta" "$id was retired while unfinished"
  done
  assert_no_captain_call "$dir" "supersession markers"
  pass "fm-idle-sweep: supersession comes from the decoded body marker, not task prose"
}

test_a_worker_that_stops_again_after_its_retry_goes_to_the_first_mate() {
  local dir
  dir=$(new_case stops-again)
  add_worker "$dir" again 'state: failed · source: run-step · run failed' 90000
  add_worker "$dir" no-relaunch 'state: failed · source: run-step · run failed' 90000
  printf 'REFUSED: relaunch needs a live harness\n' > "$dir/home/control-refuse/no-relaunch"

  sweep "$dir" scan --now || fail "first scan failed"
  assert_equals 'failed retried' "$(summary_of "$dir" again)" "the first stop should be retried"
  assert_equals 'failed asked' "$(summary_of "$dir" no-relaunch)" "a failed relaunch should go to the first mate"
  assert_contains "$(jq -r '.workers[] | select(.id=="no-relaunch") | .detail' "$dir/home/state/idle-sweep.json")" 'run failed' \
    "the hand-off should keep the worker's own detail"

  sweep "$dir" scan --now || fail "second scan failed"
  [ "$(grep -c '^again relaunch$' "$dir/home/control-calls")" = 1 ] || fail "a worker that stopped again was retried twice"
  assert_equals 'failed asked' "$(summary_of "$dir" again)" "a worker that stopped again was not handed to the first mate"
  assert_present "$dir/home/state/idle-sweep/again.raised" "the hand-off was not recorded"
  assert_equals 1 "$(wake_count "$dir" 'decide yourself whether to retire or retry again')" \
    "the first mate should be asked once about the worker that stopped again"

  sweep "$dir" scan --now || fail "third scan failed"
  assert_equals 'raised none' "$(summary_of "$dir" again)" "an unchanged handed-off worker was acted on again"
  assert_equals 'raised none' "$(summary_of "$dir" no-relaunch)" "an unchanged failed relaunch was retried"
  [ "$(grep -c '^again relaunch$' "$dir/home/control-calls")" = 1 ] || fail "an unchanged handed-off worker was relaunched"
  [ "$(grep -c '^no-relaunch relaunch$' "$dir/home/control-calls")" = 1 ] || fail "an unchanged failed relaunch was retried"
  assert_equals 1 "$(wake_count "$dir" 'decide yourself whether to retire or retry again')" "the first mate was asked twice"
  [ ! -s "$dir/home/teardown-calls" ] || fail "a worker with unfinished work was torn down"
  assert_no_captain_call "$dir" "a worker that stopped again"
  pass "fm-idle-sweep: a worker that stops again after its retry, or whose relaunch fails, goes to the first mate once"
}

test_a_second_mate_hands_its_stopped_worker_to_the_parent_channel() {
  local dir channel
  dir=$(new_case secondmate-handoff)
  make_secondmate_home "$dir" mate-a
  channel="$dir/parent/state/mate-a.status"
  add_worker "$dir" stuck 'state: failed · source: run-step · run failed' 90000
  printf 'REFUSED: relaunch needs a live harness\n' > "$dir/home/control-refuse/stuck"
  add_worker "$dir" unlanded 'state: done · source: run-step · run passed: PR merged/closed' 7200
  printf 'REFUSED: task unlanded has uncommitted changes\n' > "$dir/home/refuse/unlanded"

  sweep "$dir" scan --now || fail "scan failed"

  assert_equals 'failed asked' "$(summary_of "$dir" stuck)" "the stopped worker was not handed off"
  assert_equals 'finished asked' "$(summary_of "$dir" unlanded)" "the refused cleanup was not handed off"
  [ "$(grep -c '^needs-decision \[key=idle-stuck\]: ' "$channel")" = 1 ] \
    || fail "the parent channel did not get one needs-decision line for the stopped worker: $(cat "$channel" 2>/dev/null)"
  assert_contains "$(cat "$channel")" 'worker stuck stopped' "the parent line should name the stopped worker"
  assert_contains "$(cat "$channel")" 'decide whether to retire or retry it' "the parent line should ask retire or retry"
  [ "$(grep -c '^needs-decision \[key=idle-unlanded\]: ' "$channel")" = 1 ] \
    || fail "the parent channel did not get one needs-decision line for the refused cleanup"
  assert_contains "$(cat "$channel")" 'decide whether to clean it up or keep it' "the cleanup hand-off should ask clean up or keep"
  if grep -q 'idle-sweep:' "$dir/home/state/.wake-queue" 2>/dev/null; then
    fail "a second mate queued its own decision wake instead of using the parent channel"
  fi
  assert_no_captain_call "$dir" "a second mate's hand-off"

  sweep "$dir" scan --now || fail "second scan failed"
  [ "$(grep -c '^needs-decision \[key=idle-stuck\]: ' "$channel")" = 1 ] || fail "an unchanged worker was handed off twice"
  pass "fm-idle-sweep: a second mate hands what it cannot settle to its parent channel as needs-decision, never the captain"
}

test_resolved_parent_handoffs_reopen_for_a_new_stopped_stretch() {
  local dir channel open
  dir=$(new_case secondmate-recurrent-handoff)
  make_secondmate_home "$dir" mate-a
  channel="$dir/parent/state/mate-a.status"
  add_worker "$dir" stuck 'state: paused · source: status-log · waiting' 90000
  printf 'pr=https://github.com/owner/repo/pull/71\n' >> "$dir/home/state/stuck.meta"

  sweep "$dir" scan --now || fail "first hand-off scan failed"
  sweep "$dir" scan --now || fail "unchanged hand-off scan failed"
  assert_equals 1 "$(grep -c '^needs-decision \[key=idle-stuck\]:' "$channel")" "an unchanged episode was published twice"
  printf 'resolved [key=idle-stuck]: Continue the task\n' >> "$channel"
  open=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$channel")
  assert_equals '' "$open" "the parent's answer did not close the first episode"

  printf 'working: continued after the answer\npaused: waiting again\n' >> "$dir/home/state/stuck.status"
  age_file "$dir/home/state/stuck.status" 90000
  sweep "$dir" scan --now || fail "recurrent hand-off scan failed"
  assert_equals 'stalled asked' "$(summary_of "$dir" stuck)" "a new stopped stretch was not handed off"
  assert_equals 2 "$(grep -c '^needs-decision \[key=idle-stuck\]:' "$channel")" "the resolved hand-off swallowed a new episode"
  open=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$channel")
  assert_contains "$open" 'idle-stuck' "the new episode did not reopen the parent's decision"

  sweep "$dir" scan --now || fail "unchanged recurrent scan failed"
  assert_equals 2 "$(grep -c '^needs-decision \[key=idle-stuck\]:' "$channel")" "the new episode was published more than once"
  assert_no_captain_call "$dir" "a recurrent parent hand-off"
  pass "fm-idle-sweep: resolved parent hand-offs reopen once for each new stopped stretch"
}

test_a_main_home_is_woken_once_for_what_the_sweep_could_not_handle() {
  local dir
  dir=$(new_case unhandled-wake)
  add_worker "$dir" stuck 'state: done · source: run-step · run passed: PR merged/closed' 7200
  : > "$dir/home/pending-close/stuck"

  sweep "$dir" scan --now || fail "scan failed"
  sweep "$dir" scan --now || fail "second scan failed"

  assert_equals 'unknown unhandled' "$(summary_of "$dir" stuck)" "a pending close was not published as unhandled"
  assert_equals 1 "$(wake_count "$dir" 'idle-sweep-unhandled:')" "an unchanged unhandled set did not wake the main home exactly once"
  assert_contains "$(cat "$dir/home/state/.wake-queue")" "could neither clean up nor raise: stuck" \
    "the wake should name what was left"

  rm -f "$dir/home/state/stuck.backlog-close"
  sweep "$dir" scan --now || fail "third scan failed"
  assert_equals 1 "$(wake_count "$dir" 'idle-sweep-unhandled:')" "a cleared set woke the main home again"

  add_worker "$dir" stuck 'state: done · source: run-step · run passed: PR merged/closed' 7200
  sweep "$dir" scan --now || fail "fourth scan failed"
  assert_equals 2 "$(wake_count "$dir" 'idle-sweep-unhandled:')" "a recurring unhandled worker did not wake the main home again"
  assert_no_captain_call "$dir" "unhandled reporting"
  pass "fm-idle-sweep: a main home is woken once per distinct set the sweep could neither clean up nor raise"
}

test_a_worker_named_like_an_orphan_call_is_decided_as_a_worker() {
  local dir
  dir=$(new_case orphan-named-worker)
  add_worker "$dir" idle-orphan-race 'state: failed · source: run-step · run failed' 90000

  sweep "$dir" scan --now || fail "scan failed"

  assert_equals 'idle-orphan-race relaunch' "$(calls "$dir" control-calls)" "a worker named like an orphan call was not decided as a worker"
  if grep -q -- '--orphan' "$dir/home/retire-calls" 2>/dev/null; then
    fail "a real worker named like an orphan call was closed as an orphan"
  fi
  assert_equals 'failed retried' "$(summary_of "$dir" idle-orphan-race)" "the worker's retry was not published"
  assert_no_captain_call "$dir" "an orphan-named worker"
  pass "fm-idle-sweep: a real worker whose id starts with idle-orphan- is decided as a worker"
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
  assert_absent "$dir/home/state/idle-sweep/shipped.raised" "a cleaned-up worker was handed off"
  [ ! -s "$dir/home/control-calls" ] || fail "a done worker was relaunched"
  assert_equals 'finished cleaned' "$(summary_of "$dir" shipped)" "the summary does not record the cleanup"
  assert_no_captain_call "$dir" "done-worker cleanup"
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
  assert_equals 'finished asked' "$(summary_of "$dir" no-pr)" "a done ship with no PR should go to the first mate"
  assert_contains "$(jq -r '.workers[] | select(.id=="no-pr") | .detail' "$dir/home/state/idle-sweep.json")" \
    'nothing proves its work landed' "the hand-off should say why it was not cleaned up"
  assert_present "$dir/home/state/no-pr.meta" "an unproven done ship was removed"
  assert_equals 'awaiting-merge none' "$(summary_of "$dir" ledger-pr)" "a PR reported only in the ledger was not read as awaiting merge"
  assert_absent "$dir/home/state/idle-sweep/ledger-pr.raised" "a worker whose ledger PR is still open was handed off"
  assert_equals 'settling none' "$(summary_of "$dir" busy-lock)" "a cleanup refused only by a busy lock did not wait"
  assert_present "$dir/home/state/busy-lock.meta" "a lock-refused worker record was removed"
  [ ! -s "$dir/home/control-calls" ] || fail "a done worker was relaunched"
  assert_no_captain_call "$dir" "unproven done ships"
  pass "fm-idle-sweep: done ships need a merged PR to be cleaned up, and a busy lock just waits"
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
  [ ! -s "$dir/home/state/.wake-queue" ] || fail "normal merge waits queued a wake"
  [ "$(jq '[.workers[] | select(.class=="awaiting-merge" and .action=="none")] | length' "$dir/home/state/idle-sweep.json")" = 3 ] \
    || fail "open PR workers were not published as awaiting merge"
  for id in ready monitoring ended-monitor; do
    assert_present "$dir/home/state/$id.meta" "an open PR worker was removed"
  done
  assert_no_captain_call "$dir" "merge waits"

  printf 'MERGED\n' > "$dir/home/pr-states/1"
  printf 'merged\n' > "$dir/home/pr-states/2"
  rm -f "$dir/home/refuse/monitoring" "$dir/home/refuse/ended-monitor"
  printf 'REFUSED: task ready has uncommitted changes\n' > "$dir/home/refuse/ready"
  sweep "$dir" scan --now || fail "scan after merge failed"

  assert_absent "$dir/home/state/monitoring.meta" "a merged PR worker was not cleaned up"
  assert_absent "$dir/home/state/ended-monitor.meta" "a merged MR worker was not cleaned up"
  assert_equals 'finished asked' "$(summary_of "$dir" ready)" "a finished worker's cleanup refusal did not go to the first mate"
  assert_present "$dir/home/state/ready.meta" "a refused cleanup removed the record"
  assert_equals 1 "$(wake_count "$dir" 'decide yourself whether to retire or retry ready')" \
    "the refused cleanup should be handed off exactly once"
  assert_no_captain_call "$dir" "a refused cleanup after merge"
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
  assert_no_captain_call "$dir" "merged workers"
  [ "$(jq '[.workers[] | select(.action=="cleaned")] | length' "$dir/home/state/idle-sweep.json")" = 2 ] \
    || fail "merged ledger cleanup was not reported"
  pass "fm-idle-sweep: verified ledger-only MR URLs reach teardown without becoming cards"
}

test_retired_worker_keeps_ledger_only_merged_mr_without_a_card() {
  local dir later kept phase=${1:-finished}
  dir=$(new_case "retired-ledger-mr-$phase")
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
  if [ "$phase" = stopped ]; then
    printf 'state: paused · source: status-log · waiting\n' > "$dir/home/crew/ledger-mr"
    age_file "$dir/home/state/ledger-mr.status" 90000
  fi
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
  assert_no_captain_call "$dir" 'ledger-only merged MR housekeeping'
  if [ "$phase" = stopped ]; then
    assert_equals 'stalled retired' "$(summary_of "$dir" ledger-mr)" "the stopped retired-backend worker must pass guarded retirement"
    assert_equals 4 "$(wc -l < "$dir/home/crew-state-calls" | tr -d ' ')" "both teardown attempts and the fallback must refresh stopped activity"
  else
    assert_equals 'finished cleaned' "$(summary_of "$dir" ledger-mr)" "retired MR cleanup was not reported"
  fi
  pass 'fm-idle-sweep: retirement preserves ledger-only merged MR commits without a card in manual mode'
}

test_closed_unmerged_prs_go_to_the_first_mate_not_cleanup() {
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
  for id in closed-recorded closed-ledger closed-mr; do
    assert_present "$dir/home/state/$id.meta" "a closed-unmerged PR worker was removed"
    assert_equals 'finished asked' "$(summary_of "$dir" "$id")" "a closed-unmerged PR was not handed to the first mate"
    assert_present "$dir/home/state/idle-sweep/$id.raised" "the closed-unmerged hand-off was not recorded"
  done
  assert_contains "$(cat "$dir/home/state/.wake-queue")" 'decide yourself whether to retire or retry closed-ledger closed-mr closed-recorded' \
    "the closed-unmerged PRs should reach the first mate in one wake"
  assert_equals 1 "$(wake_count "$dir" 'idle-sweep:')" "more than one hand-off wake was queued"
  assert_present "$dir/home/state/unreadable.meta" "an unreadable PR worker was removed"
  assert_equals 'settling none' "$(summary_of "$dir" unreadable)" "an unreadable PR was acted on"
  assert_absent "$dir/home/state/merged-ledger.meta" "a merged PR reported in the ledger was not cleaned up"
  assert_no_captain_call "$dir" "closed-unmerged PRs"
  pass "fm-idle-sweep: only merged PRs admit cleanup; closed-unmerged PRs go to the first mate"
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

  [ "$(jq -r '[.workers[] | select(.action=="asked") | .id] | sort | join(" ")' "$dir/home/state/idle-sweep.json")" = 'clock unrelated-progress unresolved-lock' ] \
    || fail "contention matching suppressed an unrelated refusal or handed off a busy task: $(cat "$dir/home/state/idle-sweep.json")"
  for id in lifecycle treehouse; do
    assert_equals 'settling none' "$(summary_of "$dir" "$id")" "a supported contention refusal did not wait for the next scan"
    assert_absent "$dir/home/state/idle-sweep/$id.raised" "a busy task was handed off"
  done
  [ "$(wc -l < "$dir/home/teardown-calls" | tr -d ' ')" = 5 ] || fail "not all refusal paths were exercised"
  assert_no_captain_call "$dir" "cleanup refusals"
  pass "fm-idle-sweep: only supported lifecycle contention defers a cleanup hand-off"
}

test_stopped_worker_pending_closes_wake_the_first_mate_immediately() {
  local dir state
  for state in failed paused; do
    dir=$(new_case "stopped-pending-close-$state")
    add_worker "$dir" pending "state: $state · source: status-log · stopped" 90000
    printf -- '- pending: Finished work\n  state: done\n' > "$dir/home/rows/pending"
    : > "$dir/home/pending-close/pending"

    sweep "$dir" scan --now || fail "stopped pending close scan failed"

    assert_absent "$dir/home/state/pending.meta" "the partial cleanup must remove the worker record"
    assert_present "$dir/home/state/pending.backlog-close" "the partial cleanup must retain its recovery record"
    assert_equals unhandled "$(summary_of "$dir" pending | cut -d' ' -f2)" "the current scan must expose the failed backlog close"
    assert_contains "$(cat "$dir/home/state/.wake-queue")" 'idle sweep could neither clean up nor raise: pending' \
      "the first mate must see the partial cleanup failure immediately"
    assert_absent "$dir/home/state/idle-sweep/pending.raised" "partial cleanup must not be suppressed as a stale decision"
    assert_absent "$dir/home/control-calls" "partial cleanup must not retry the worker"
    assert_no_captain_call "$dir" "stopped pending close"
  done
  pass "fm-idle-sweep: stopped-worker partial cleanup stays unhandled in the same scan"
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
  [ ! -s "$dir/home/control-calls" ] || fail "pending-close reporting relaunched the worker"

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
  [ ! -s "$dir/home/state/.wake-queue" ] || fail "a stale cleanup refusal queued a hand-off wake"
  assert_absent "$dir/home/state/idle-sweep/removed.raised" "a removed worker was fingerprinted as raised"
  assert_absent "$dir/home/state/idle-sweep/replaced.raised" "a replacement worker was fingerprinted as raised"
  cmp -s "$dir/home/replacement/replaced" "$dir/home/state/replaced.meta" || fail "the replacement record was changed"
  [ "$(jq -r '.workers[] | select(.id=="removed") | .action' "$dir/home/state/idle-sweep.json")" = cleaned ] \
    || fail "concurrent cleanup was not reconciled"
  [ "$(jq -r '.workers[] | select(.id=="replaced") | [.class,.action] | join(" ")' "$dir/home/state/idle-sweep.json")" = 'unknown none' ] \
    || fail "the replacement worker was not left for a fresh scan"
  assert_no_captain_call "$dir" "a concurrent cleanup"
  pass "fm-idle-sweep: concurrent removal or replacement cannot create stale cleanup hand-offs"
}

test_refusals_and_idle_workers_are_settled_by_the_sweep() {
  local dir id wake
  dir=$(new_case decisions)
  add_worker "$dir" unlanded 'state: done · source: run-step · run passed: PR merged/closed' 7200
  printf 'REFUSED: task unlanded has uncommitted changes (dirty copy)\n' > "$dir/home/refuse/unlanded"
  printf 'pr=https://github.com/owner/repo/pull/41\n' >> "$dir/home/state/unlanded.meta"
  printf 'MERGED\n' > "$dir/home/pr-states/41"
  add_worker "$dir" broke 'state: failed · source: run-step · run failed (test step)' 90000
  printf 'pr=https://github.com/owner/repo/pull/1806\n' >> "$dir/home/state/broke.meta"
  printf 'OPEN\n' > "$dir/home/pr-states/1806"
  add_worker "$dir" waiting 'state: blocked · source: status-log · needs a token' 90000
  printf 'pr=https://github.com/owner/repo/pull/1807\n' >> "$dir/home/state/waiting.meta"
  printf 'OPEN\n' > "$dir/home/pr-states/1807"
  add_worker "$dir" vanished 'state: unknown · source: none · backend target gone: hub:abc' 90000
  add_worker "$dir" just-blocked 'state: blocked · source: status-log · needs a token' 600
  add_worker "$dir" busy 'state: working · source: pane · harness busy' 90000
  add_worker "$dir" unreachable 'state: unknown · source: none · backend unreachable' 90000
  add_worker "$dir" asked 'state: failed · source: run-step · run failed' 90000
  : > "$dir/home/held/asked"
  add_worker "$dir" parked-wait 'state: paused · source: status-log · waiting on CI' 90000
  : > "$dir/home/deferred/parked-wait"

  sweep "$dir" scan --now || fail "scan failed"

  [ "$(calls "$dir" control-calls | sort | tr '\n' ',')" = 'broke relaunch,vanished relaunch,waiting relaunch,' ] \
    || fail "wrong set of workers retried: $(calls "$dir" control-calls)"
  assert_equals 'finished asked' "$(summary_of "$dir" unlanded)" "a refused cleanup should go to the first mate"
  assert_present "$dir/home/state/unlanded.meta" "a refused cleanup removed the record"
  assert_contains "$(jq -r '.workers[] | select(.id=="unlanded") | .detail' "$dir/home/state/idle-sweep.json")" \
    'uncommitted changes' "the hand-off should carry the refusal"
  assert_equals 'failed retried' "$(summary_of "$dir" broke)" "a failed worker with an open PR should be retried"
  assert_equals 'stalled retried' "$(summary_of "$dir" waiting)" "a stalled worker with an open PR should be retried"
  assert_equals 'dead retried' "$(summary_of "$dir" vanished)" "a gone worker with unfinished work should be retried"
  assert_equals 'settling none' "$(summary_of "$dir" just-blocked)" "a recently blocked worker was acted on"
  assert_equals 'active none' "$(summary_of "$dir" busy)" "a working worker was acted on"
  assert_equals 'settling none' "$(summary_of "$dir" unreachable)" "an unavailable backend was classified as a dead worker"
  assert_equals 'held none' "$(summary_of "$dir" asked)" "a worker held for the captain was acted on"
  assert_equals 'held none' "$(summary_of "$dir" parked-wait)" "a worker on a settled deferral was acted on"
  if grep -qx asked "$dir/home/crew-state-calls"; then
    fail "a worker already held for the captain was re-read"
  fi
  [ ! -s "$dir/home/teardown-args" ] || [ "$(calls "$dir" teardown-calls)" = unlanded ] \
    || fail "an unfinished worker was torn down: $(calls "$dir" teardown-calls)"
  assert_equals 1 "$(wake_count "$dir" 'idle-sweep:')" "a main home should queue exactly one wake"
  wake=$(cat "$dir/home/state/.wake-queue")
  assert_contains "$wake" 'retried broke vanished waiting' "the wake should list what the sweep retried"
  assert_contains "$wake" 'decide yourself whether to retire or retry unlanded' "the wake should hand the refused cleanup to the first mate"
  for id in just-blocked busy unreachable asked parked-wait; do
    assert_not_contains "$wake" " $id" "the wake named a worker the sweep left alone"
  done
  assert_no_captain_call "$dir" "idle workers"
  pass "fm-idle-sweep: the sweep retries or hands off stopped and refused workers itself; active, recent and held ones are left"
}

test_a_handed_off_worker_is_acted_on_again_only_after_its_ledger_changes() {
  local dir
  dir=$(new_case raised)
  add_worker "$dir" broke 'state: failed · source: run-step · run failed' 90000

  sweep "$dir" scan --now || fail "first scan failed"
  assert_equals 'failed retried' "$(summary_of "$dir" broke)" "the first stop was not retried"
  printf 'state: unknown · source: none · backend target gone\n' > "$dir/home/crew/broke"
  sweep "$dir" scan --now || fail "second scan failed"
  assert_equals 'dead asked' "$(summary_of "$dir" broke)" "an unchanged ledger after a retry was not handed off"
  sweep "$dir" scan --now || fail "third scan failed"
  assert_equals 'raised none' "$(summary_of "$dir" broke)" "an unchanged handed-off worker should list as raised"
  [ "$(grep -c . "$dir/home/control-calls")" = 1 ] || fail "an unchanged worker was retried again: $(calls "$dir" control-calls)"
  assert_equals 1 "$(wake_count "$dir" 'decide yourself whether to retire or retry broke')" "an unchanged worker was handed off twice"

  printf 'failed: second attempt failed\n' >> "$dir/home/state/broke.status"
  age_file "$dir/home/state/broke.status" 90000
  sweep "$dir" scan --now || fail "fourth scan failed"
  assert_not_equals 'raised none' "$(summary_of "$dir" broke)" "a worker whose ledger changed was not acted on again"
  [ "$(jq -r '.workers[] | select(.id=="broke") | .action' "$dir/home/state/idle-sweep.json")" != none ] \
    || fail "a worker whose ledger changed was left alone"

  touch "$dir/home/state/.last-idle-sweep"
  cp "$dir/home/control-calls" "$dir/control-calls.before"
  cp "$dir/home/state/.wake-queue" "$dir/wake-queue.before"
  printf 'failed: third\n' >> "$dir/home/state/broke.status"
  age_file "$dir/home/state/broke.status" 90000
  sweep "$dir" scan || fail "cadence-gated scan failed"
  cmp -s "$dir/control-calls.before" "$dir/home/control-calls" || fail "a scan inside its cadence still relaunched"
  cmp -s "$dir/wake-queue.before" "$dir/home/state/.wake-queue" || fail "a scan inside its cadence still queued a wake"
  assert_no_captain_call "$dir" "repeat suppression"
  pass "fm-idle-sweep: a handed-off worker waits for its ledger to change, and scans keep their cadence"
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
  [ "$(jq -r '.workers[] | select(.id=="stale") | .class' "$dir/home/state/idle-sweep.json")" = dead ] \
    || fail "the stale task was not classified as dead"
  [ "$(calls "$dir" control-calls)" = 'stale relaunch' ] || fail "the stale unfinished task was not retried: $(calls "$dir" control-calls)"
  if grep -qx stale "$dir/home/crew-state-calls"; then fail "the stale task read the claimant's run"; fi
  assert_no_captain_call "$dir" "a reassigned slot"
  pass "fm-idle-sweep: a reassigned slot cannot close an unfinished task"
}

test_record_less_endpoints_are_closed_as_orphans() {
  local dir
  dir=$(new_case orphans)
  printf 'gone-task\teid123\n' > "$dir/home/orphans"
  sweep "$dir" scan --now || fail "scan failed"
  assert_contains "$(calls "$dir" retire-calls)" "--orphan gone-task --endpoint eid123" \
    "a record-less endpoint should be closed through the orphan close"
  assert_equals 'dead cleaned' "$(summary_of "$dir" idle-orphan-gone-task)" "the orphan close was not published"
  pass "fm-idle-sweep: record-less live endpoints are closed through the orphan close"
}

test_refused_orphans_are_published_with_their_hand_off_result() {
  local dir expected
  for expected in asked unhandled; do
    dir=$(new_case "orphan-$expected")
    printf 'gone-task\teid123\n' > "$dir/home/orphans"
    : > "$dir/home/orphan-refused"
    if [ "$expected" = unhandled ]; then
      # a second mate whose parent binding is missing cannot hand anything off
      printf 'mate-a\n' > "$dir/home/.fm-secondmate-home"
    fi

    sweep "$dir" scan --now || fail "scan failed"

    [ "$(jq -r '.workers[0].id' "$dir/home/state/idle-sweep.json")" = idle-orphan-gone-task ] \
      || fail "the refused orphan was omitted from the summary"
    [ "$(jq -r '.workers[0].action' "$dir/home/state/idle-sweep.json")" = "$expected" ] \
      || fail "the orphan's hand-off outcome was not published: $(cat "$dir/home/state/idle-sweep.json")"
    if [ "$expected" = asked ]; then
      assert_present "$dir/home/state/idle-sweep/idle-orphan-gone-task.raised" "the orphan hand-off was not recorded"
      assert_contains "$(cat "$dir/home/state/.wake-queue")" 'decide yourself whether to retire or retry idle-orphan-gone-task' \
        "the refused orphan was not handed to the first mate"
    else
      assert_absent "$dir/home/state/idle-sweep/idle-orphan-gone-task.raised" "a failed hand-off was recorded as made"
    fi
    assert_no_captain_call "$dir" "a refused orphan"
  done
  pass "fm-idle-sweep: refused orphan summaries reflect the actual hand-off result"
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
    assert_absent "$dir/home/state/idle-sweep/idle-orphan-gone-task.raised" "an orphan with a $mode decision was handed off"
    [ "$(jq -r '.workers[0] | [.class,.action] | join(" ")' "$dir/home/state/idle-sweep.json")" = 'held none' ] \
      || fail "the $mode orphan was not published as held"
    assert_no_captain_call "$dir" "a $mode orphan"
  done

  dir=$(new_case orphan-raised)
  printf 'gone-task\teid123\n' > "$dir/home/orphans"
  printf 'blocked: turn active\n' > "$dir/home/state/gone-task.status"
  : > "$dir/home/orphan-refused"
  sweep "$dir" scan --now || fail "first scan failed"
  assert_equals 'dead asked' "$(summary_of "$dir" idle-orphan-gone-task)" "the orphan was not handed off"

  rm -f "$dir/home/orphan-refused"
  sweep "$dir" scan --now || fail "second scan failed"
  [ "$(grep -c '^--orphan ' "$dir/home/retire-calls")" = 1 ] || fail "an unchanged handed-off orphan was closed"
  [ "$(jq -r '.workers[0] | [.class,.action] | join(" ")' "$dir/home/state/idle-sweep.json")" = 'raised none' ] \
    || fail "the unchanged orphan was not published as raised"

  : > "$dir/home/orphan-refused"
  sweep "$dir" scan --now || fail "third scan failed"
  assert_equals 1 "$(wake_count "$dir" 'retry idle-orphan-gone-task')" "an unchanged orphan was handed off again"
  [ "$(grep -c '^--orphan ' "$dir/home/retire-calls")" = 1 ] || fail "an unchanged orphan's close was retried"

  printf 'blocked: new turn\n' >> "$dir/home/state/gone-task.status"
  sweep "$dir" scan --now || fail "fourth scan failed"
  assert_equals 2 "$(wake_count "$dir" 'retry idle-orphan-gone-task')" "a changed orphan ledger did not permit a new hand-off"
  [ "$(grep -c '^--orphan ' "$dir/home/retire-calls")" = 2 ] || fail "a changed orphan ledger did not permit closure"
  assert_no_captain_call "$dir" "orphan repeat suppression"
  pass "fm-idle-sweep: orphan hand-offs gate closure until the actual task ledger changes"
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
      assert_equals 'dead asked' "$(summary_of "$dir" idle-orphan-gone-task)" "the initial orphan hand-off was not made"
      printf 'working: turn ended\n' >> "$dir/home/state/gone-task.status"
      rm -f "$dir/home/orphan-refused"
      cp "$dir/home/state/.wake-queue" "$dir/wake-queue.before"

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
      [ ! -s "$dir/home/control-calls" ] || fail "unreadable holds permitted a relaunch"
      [ ! -s "$dir/home/crew-state-calls" ] || fail "unreadable holds permitted worker classification"
      [ "$(grep -c '^--orphan ' "$dir/home/retire-calls")" = 1 ] || fail "an orphan with an unreadable call was closed"
      cmp -s "$dir/wake-queue.before" "$dir/home/state/.wake-queue" || fail "unreadable holds permitted a hand-off"
      assert_no_captain_call "$dir" "unreadable holds"
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
  [ ! -s "$dir/home/control-calls" ] || fail "idle quiet time was not fixed at 6 hours"
  assert_equals 'settling none' "$(summary_of "$dir" recent)" "a recently blocked worker was acted on"
  assert_contains "$(cat "$dir/home/state/.wake-queue")" 'idle-sweep-audit:mate:' "audit age was not fixed at 6 hours"
  sweep "$dir" list > "$dir/list.out" 2> "$dir/list.err" || rc=$?
  [ "$rc" = 2 ] || fail "the unsupported list command was accepted"
  pass "fm-idle-sweep: scans use fixed quiet and audit bounds, with no list mode"
}

run_watcher_until() {  # <dir> <file> <pattern>
  local dir=$1 file=$2 pattern=$3 watcher i=0
  PATH="$dir/bin:$PATH" TASKS_AXI_BACKEND=markdown FM_HOME="$dir/home" FM_POLL=1 FM_HOME_SUMMARY_INTERVAL=999999 FM_SECONDMATE_REVIVE_INTERVAL=999999 \
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
  run_watcher_until "$dir" "$dir/home/control-calls" 'broke relaunch'
  assert_contains "$(calls "$dir" control-calls)" 'broke relaunch' "the watcher did not run the sweep on its own"
  [ ! -s "$dir/home/hold-attempts" ] || fail "the watcher-run sweep made a captain call"

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

test_unreadable_backlog_items_are_handed_to_the_first_mate
test_unreadable_prs_are_handed_to_the_first_mate
test_replacements_during_forge_reads_are_left_for_a_fresh_scan
test_recovered_workers_are_not_retried_with_unchanged_metadata
test_resumed_workers_are_not_retired_after_a_merged_pr_read
test_retired_backend_cleanup_preserves_the_expected_record_guard
test_a_failed_main_home_delivery_is_retried_next_scan
test_a_stopped_worker_with_open_work_is_retried_once_without_a_card
test_a_stopped_worker_whose_work_landed_or_ended_is_retired
test_supersession_requires_a_decoded_body_marker
test_a_worker_that_stops_again_after_its_retry_goes_to_the_first_mate
test_a_second_mate_hands_its_stopped_worker_to_the_parent_channel
test_resolved_parent_handoffs_reopen_for_a_new_stopped_stretch
test_done_workers_are_cleaned_up_without_force
test_closed_unmerged_prs_go_to_the_first_mate_not_cleanup
test_merged_mr_in_ledger_is_passed_to_teardown
test_retired_worker_keeps_ledger_only_merged_mr_without_a_card
test_retired_worker_keeps_ledger_only_merged_mr_without_a_card stopped
test_only_lifecycle_contention_defers_cleanup_refusals
test_stopped_worker_pending_closes_wake_the_first_mate_immediately
test_pending_backlog_closes_remain_visible_until_cleared
test_open_pr_workers_wait_for_merge_without_a_cleanup_decision
test_concurrent_cleanup_does_not_raise_stale_decisions
test_refusals_and_idle_workers_are_settled_by_the_sweep
test_a_handed_off_worker_is_acted_on_again_only_after_its_ledger_changes
test_reassigned_slots_cannot_supply_completion
test_record_less_endpoints_are_closed_as_orphans
test_refused_orphans_are_published_with_their_hand_off_result
test_orphan_decisions_gate_closure_and_repeated_escalation
test_unreadable_holds_prevent_worker_and_orphan_actions
test_second_mates_that_do_not_sweep_are_escalated_once
test_local_mates_with_missing_homes_are_escalated
test_scan_uses_fixed_quiet_and_audit_bounds
test_watcher_runs_the_sweep_and_surfaces_its_decision
test_done_ships_without_merge_evidence_are_never_cleaned_automatically
test_a_main_home_is_woken_once_for_what_the_sweep_could_not_handle
test_a_worker_named_like_an_orphan_call_is_decided_as_a_worker
