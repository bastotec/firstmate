#!/usr/bin/env bash
# Behavior tests for the read-only fleet snapshot and its human renderer.
# snap_identity prints a task's record identity one field per word, so its
# unquoted expansion in fm_write_meta's argument list is deliberate.
# shellcheck disable=SC2046
set -u

# shellcheck source=tests/fixtures.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SNAPSHOT="$ROOT/bin/fm-fleet-snapshot.sh"
VIEW="$ROOT/bin/fm-fleet-view.sh"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/no-mistakes"
  printf '%s\n' "$fb"
}

# snap_identity <home> <task-id> <label>: register the task's fake stream
# endpoint and print its record identity lines, one per word. The endpoint's
# screen reads busy for the ship-task and active-secondmate labels and quiet
# otherwise, and its foreground is a dead shell for dead-secondmate and a live
# codex agent otherwise.
snap_identity() {  # <home> <task-id> <label>
  local home=$1 id=$2 label=$3 capture target lines
  mkdir -p "$home/captures"
  capture="$home/captures/$id"
  case "$label" in
    *ship-task*|*active-secondmate*) printf 'work in progress\nesc to interrupt\n' > "$capture" ;;
    *) printf 'all quiet\n> \n' > "$capture" ;;
  esac
  lines=$(fm_test_stream_task "$home/state" "$id" "" "$capture") || return 1
  target=$(fm_test_stream_target_of "$home/state" "$id")
  case "$label" in
    *dead-secondmate*) fm_test_fake_stream_foreground "$target" zsh ;;
    *) fm_test_fake_stream_foreground "$target" codex ;;
  esac
  printf '%s\n' "$lines"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

record_deck_idle() {  # <state-dir> <id>
  local state=$1 id=$2 gen
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" \
    --source deck-wrapper --event turn-end
}

write_fixture() {  # <home>
  local home=$1 fixture_gen
  mkdir -p "$home/projects/alpha-worktree" "$home/projects/scout-worktree" "$home/secondmate-home"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] scout-task - Scout Task data/scout-task/report.md (repo: alpha) (kind: scout) (since 2026-07-07)
- [ ] ship-task - Ship Task https://github.com/kunchenguid/firstmate/pull/9 (repo: alpha) (kind: ship) (priority: 2) (since 2026-07-07)
  Preserve this detail for bearings.

## Queued
- [ ] queued-task - Queued Task blocked-by: ship-task (repo: alpha) (kind: ship) (since 2026-07-08)
handoff note without canonical syntax

## Done
- [x] done-task - Done Task https://github.com/kunchenguid/firstmate/pull/7 (repo: alpha) (kind: ship) (merged 2026-07-06)
  Outcome: merged https://github.com/kunchenguid/firstmate/pull/7
EOF
  mkdir -p "$home/data/scout-task"
  printf '# Scout\n' > "$home/data/scout-task/report.md"
  fm_write_meta "$home/state/ship-task.meta" \
    $(snap_identity "$home" ship-task ship-task) \
    "worktree=$home/projects/alpha-worktree" \
    "project=alpha" \
    "harness=deck" \
    "kind=ship" \
    "mode=ship" \
    "yolo=off" \
    "pr=https://github.com/kunchenguid/firstmate/pull/9"
  printf 'needs-decision: choose an API shape\n' > "$home/state/ship-task.status"
  # A working ship task proves it through its own semantic busy-state record
  # (bin/fm-busy-lib.sh), which is what the snapshot's current-state read
  # consults; rendered pane text is no longer a state source.
  fixture_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" ship-task)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" ship-task busy --gen "$fixture_gen" \
    --source deck-wrapper --event turn-start
  fm_write_meta "$home/state/scout-task.meta" \
    $(snap_identity "$home" scout-task scout-task) \
    "worktree=$home/projects/scout-worktree" \
    "project=alpha" \
    "harness=deck" \
    "kind=scout" \
    "mode=scout" \
    "yolo=off"
  printf 'done: report ready\n' > "$home/state/scout-task.status"
  fm_write_meta "$home/state/secondmate-task.meta" \
    $(snap_identity "$home" secondmate-task secondmate-task) \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=deck" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha, beta, gamma, "
  printf 'working: watching delegated scope\n' > "$home/state/secondmate-task.status"
  fm_write_meta "$home/state/stream-task.meta" \
    "backend=stream" \
    "window=tag:0123abcd" \
    "worktree=$home/projects/missing-stream" \
    "project=alpha" \
    "harness=deck" \
    "kind=ship" \
    "mode=ship"
}

# The home summary reads its own records whole: a remote secondmate is described
# by its own published summary, not as an unknown child; a worker record kept
# after its item is Done is retained, not unowned; and a local-only ship never asks no-mistakes about a run its repository cannot have.
test_home_summary_reads_remote_mates_retained_records_and_local_only_ships() {
  local home fakebin out wt
  home=$(make_home summary-whole-records)
  wt="$home/projects/local-only"
  git init -q "$wt" && git -C "$wt" commit -q --allow-empty -m init && git -C "$wt" checkout -q -b fm/local-ship
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] local-ship - A local-only ship (repo: alpha) (kind: ship) (since 2026-10-15)
  An ordinary indented note.

## Queued

## Done
- [x] kept-ship - A finished worker kept by a captain hold (repo: alpha) (kind: ship) (done 2026-10-15)
EOF
  fm_write_meta "$home/state/far-mate.meta" \
    $(snap_identity "$home" far-mate far-mate) \
    "worktree=/remote/home" "project=/remote/home" "harness=deck" "kind=secondmate" "mode=secondmate" \
    "home=/remote/home" "projects=" "remote_host=workload"
  fm_write_meta "$home/state/kept-ship.meta" \
    $(snap_identity "$home" kept-ship kept-ship) \
    "worktree=$home/projects/gone" "project=alpha" "harness=deck" "kind=ship" "mode=no-mistakes"
  record_deck_idle "$home/state" kept-ship
  printf 'done: finished\n' > "$home/state/kept-ship.status"
  fm_write_meta "$home/state/local-ship.meta" \
    $(snap_identity "$home" local-ship local-ship) \
    "worktree=$wt" "project=alpha" "harness=deck" "kind=ship" "mode=local-only"
  record_deck_idle "$home/state" local-ship
  printf 'working: assessing\n' > "$home/state/local-ship.status"
  fakebin=$(make_fakebin "$home")
  # A repository that was never initialized for no-mistakes answers like this.
  printf '#!/usr/bin/env bash\necho "error: repo not initialized" >&2\nexit 1\n' > "$fakebin/no-mistakes"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '
    .valid == true and .reason == null
      and ([.endpoints[] | select(.id == "local-ship") | .state] != ["unknown"])
  ' >/dev/null || fail "remote mate, retained record or local-only ship invalidated the summary: $out"
  # A leftover record no current item owns, whose worktree is gone, is unowned,
  # not an unread child.
  fm_write_meta "$home/state/leftover.meta" \
    $(snap_identity "$home" leftover leftover) \
    "worktree=" "project=alpha" "harness=deck" "kind=ship" "mode=no-mistakes"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '
    .invalidity.kind == "unowned_current" and .unknown_children == []
  ' >/dev/null || fail "a leftover record was reported as an unread child: $out"
  # A stray non-canonical line is a disagreement the summary still reports, but
  # the home keeps the state it computed from everything it read.
  awk '/^## Queued/{print; print "stray line written by hand"; next} {print}' "$home/data/backlog.md" > "$home/data/backlog.md.tmp" \
    && mv "$home/data/backlog.md.tmp" "$home/data/backlog.md"
  rm -f "$home/state/leftover.meta"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '
    .invalidity.kind == "unstructured_current" and .state != "unknown"
  ' >/dev/null || fail "a stray backlog line blanked the home state: $out"
  # A worker read as idle with nothing claimed (its blocker was just resolved)
  # was read, so it is not an unread child.
  awk '/^## In flight/{print; print "- [ ] idle-ship - An answered worker (repo: alpha) (kind: ship) (since 2026-10-17)"; next} {print}' \
    "$home/data/backlog.md" > "$home/data/backlog.md.tmp" && mv "$home/data/backlog.md.tmp" "$home/data/backlog.md"
  mkdir -p "$home/projects/idle"
  fm_write_meta "$home/state/idle-ship.meta" \
    $(snap_identity "$home" idle-ship idle-ship) \
    "worktree=$home/projects/idle" "project=alpha" "harness=deck" "kind=ship" "mode=local-only"
  record_deck_idle "$home/state" idle-ship
  printf 'blocked: waiting on a choice\nresolved: answered: go ahead\n' > "$home/state/idle-ship.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '
    (.unknown_children | index("idle-ship") | not)
      and any(.endpoints[]; .id == "idle-ship" and .state == "unknown")
  ' >/dev/null || fail "an idle worker with nothing claimed was reported as unread: $out"
  pass "home summary reads remote mates, retained records and local-only ships"
}

test_empty_fleet_json() {
  local home out view
  home=$(make_home empty)
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .schema == "fm-fleet-snapshot.v1"
      and .backlog.present == false
      and (.tasks|length == 0)
      and .main_inventory.valid == true
      and .main_inventory.reason == null
      and (.main_inventory.orphan_in_flight | length) == 0
      and .main_inventory.unstructured_current_count == 0
  ' >/dev/null \
    || fail "empty snapshot schema or absence markers wrong: $out"
  view=$(FM_HOME="$home" "$VIEW")
  assert_contains "$view" "No live task metadata found." "empty fleet view should say no live metadata"
  pass "empty fleet snapshot and view use explicit absence markers"
}

test_reopened_task_keeps_its_current_pr_identity() {
  local home fakebin out view old=https://github.com/example/repo/pull/7 new=https://github.com/example/repo/pull/8
  command -v tasks-axi >/dev/null 2>&1 || { pass "reopened PR identity skipped without tasks-axi"; return; }
  home=$(make_home reopened-pr)
  fakebin=$(make_fakebin "$home")
  printf 'backend = "markdown"\n' > "$home/.tasks.toml"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '#!/usr/bin/env bash\necho CLOSED\n' > "$fakebin/gh"
  chmod +x "$fakebin/gh"
  FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-tasks-axi.sh" add replacement \
    'Fix account deletion' --kind ship --pr "$old" --body 'Superseded: replacement required' >/dev/null \
    || fail "could not create superseded task"
  FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-tasks-axi.sh" "done" replacement >/dev/null \
    || fail "could not close superseded task"
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg old "$old" '
    .backlog.records | any(.id == "replacement" and .state == "done" and .pr_url == $old and .outcome == "superseded")
  ' >/dev/null || fail "completed task lost its outcome-owned PR"
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" reopen replacement >/dev/null || fail "could not reopen task"
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg old "$old" '
    .backlog.records | any(.id == "replacement" and .state == "queued" and .pr_url == $old)
  ' >/dev/null || fail "reopened task without a title PR lost its outcome fallback"
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" update replacement --pr "$new" >/dev/null || fail "could not record replacement PR"
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg new "$new" '
    .backlog.records | any(.id == "replacement" and .state == "queued" and .pr_url == $new and .outcome == "superseded")
  ' >/dev/null || fail "historical outcome replaced the current title PR"
  view=$(FM_HOME="$home" "$VIEW")
  assert_contains "$view" "$new" "fleet view lost the active replacement PR"
  assert_not_contains "$view" "$old" "fleet view displays the historical superseded PR"
  FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" start replacement >/dev/null || fail "could not start replacement"
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg new "$new" '
    .backlog.records | any(.id == "replacement" and .state == "in_flight" and .pr_url == $new and .outcome == "superseded")
  ' >/dev/null || fail "in-flight task lost its current PR"
  printf '#!/usr/bin/env bash\necho MERGED\n' > "$fakebin/gh"
  FM_HOME="$home" PATH="$fakebin:$PATH" "$ROOT/bin/fm-tasks-axi.sh" "done" replacement --pr "$new" >/dev/null \
    || fail "could not close merged replacement"
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg new "$new" '
    .backlog.records | any(.id == "replacement" and .state == "done" and .pr_url == $new and .outcome == "merged")
  ' >/dev/null || fail "completed replacement lost its outcome-owned PR"
  pass "reopened tasks prefer current PRs while completed tasks and linkless rows use outcomes"
}

test_fixture_snapshot_json() {
  local home fakebin out ids
  home=$(make_home fixture)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e . >/dev/null || fail "snapshot must be valid JSON"
  ids=$(printf '%s' "$out" | jq -r '.tasks | map(.id) | join(",")')
  [ "$ids" = "scout-task,secondmate-task,ship-task,stream-task" ] \
    || fail "task ordering must be stable by id, got $ids"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "ship-task")
    | .current_state.state == "working"
      and .current_state.source == "pane"
      and .pr.url == "https://github.com/kunchenguid/firstmate/pull/9"
      and .backlog.body_excerpt == "Preserve this detail for bearings."
      and .hints.pending_decision == false
      and .paths.status_log.kind == "event_history"
  ' >/dev/null || fail "ship task state, PR, body, and stale event hints wrong"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "scout-task")
    | .paths.report.present == true
      and .hints.scout_report_present == true
  ' >/dev/null || fail "scout report pointer missing"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "secondmate-task")
    | .secondmate_projects == ["alpha","beta","gamma"]
      and .endpoint.agent_alive == "alive"
      and (.actions.watch | contains("do not routinely fm-peek"))
  ' >/dev/null || fail "secondmate return-channel guidance missing"
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "stream-task")
    | .backend == "stream"
      and .paths.worktree.present == false
      and .current_state.state == "unknown"
  ' >/dev/null || fail "stream missing-file row missing"
  printf '%s' "$out" | jq -e '
    [.backlog.records[] | select(.state == "queued")] | length == 2
  ' >/dev/null || fail "queued canonical and unstructured backlog records missing"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-task")
    | .state == "done" and .pr_url == "https://github.com/kunchenguid/firstmate/pull/7"
  ' >/dev/null || fail "done backlog PR row missing"
  pass "fixture snapshot covers task rows, backlog rows, pointers, and stable ordering"
}

# R1 owner contract: main_inventory discloses orphan in-flight and unstructured
# current rows without inventing task rows.
test_hold_buckets_are_total_and_text_blind() {
  local home fakebin out
  home=$(make_home hold-buckets)
  mkdir -p "$home/data"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] working-held - Held while working (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z

## Queued
- [ ] blocked-hold - Blocked call blocked-by: upstream-work (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z
- [ ] dated-hold - Dated call (repo: sample) (kind: captain) (hold: revisit later) (hold-kind: captain) (hold-until: 2026-12-01)
  Captain hold set: 2026-07-20T00:00:00Z
- [ ] aged-hold - Aged call (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-06-01T00:00:00Z
- [ ] live-hold - Live call (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z
- [ ] opposite-word - Opposite wording (repo: sample) (kind: captain) (hold: non-deferred release choice) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z
- [ ] marker-prose - Marker prose (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z
  SUPERSEDED - kept only to prove prose never classifies.
- [ ] upstream-work - Land the upstream change (repo: sample) (kind: ship)

## Done
EOF
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data"     FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    [.backlog.records[] | select(.structured and .hold_kind == "captain")]
    | length == 7
      and all(.hold_bucket as $bucket
              | ["live", "blocked", "dated", "aged"] | index($bucket) != null)
  ' >/dev/null || fail "every captain hold must land in exactly one structured bucket: $out"
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.id == "blocked-hold")][0].hold_bucket == "blocked")
      and ([.backlog.records[] | select(.id == "dated-hold")][0].hold_bucket == "dated")
      and ([.backlog.records[] | select(.id == "aged-hold")][0].hold_bucket == "aged")
      and ([.backlog.records[] | select(.id == "live-hold")][0].hold_bucket == "live")
  ' >/dev/null || fail "structured fields did not drive the bucket assignment: $out"
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.id == "opposite-word")][0]) as $opposite
    | ([.backlog.records[] | select(.id == "marker-prose")][0]) as $prose
    | $opposite.hold_bucket == "live" and $opposite.captain_actionable == true
      and $prose.hold_bucket == "live" and $prose.captain_actionable == true
  ' >/dev/null || fail "hold reason or body prose must never reclassify a live decision: $out"
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.id == "working-held")][0])
    | .hold_bucket == "live" and .captain_actionable == true
  ' >/dev/null || fail "a captain hold on a working task must still be bucketed: $out"
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.id == "upstream-work")][0].hold_bucket) == null
  ' >/dev/null || fail "a row that is not a captain hold must carry no bucket: $out"
  pass "captain-hold buckets are total, mutually exclusive, and never decided by prose"
}

test_checked_rows_never_carry_a_hold_bucket() {
  local home fakebin out
  home=$(make_home checked-hold)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [x] checked-in-flight - Finished but left in flight (repo: sample) (kind: ship) (done 2026-07-21) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z

## Queued
- [x] checked-queued - Finished but left queued (repo: sample) (kind: ship) (done 2026-07-21) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z
- [ ] open-call - Still open (repo: sample) (kind: captain) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z

## Done
EOF
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.id == "checked-queued" or .id == "checked-in-flight")]
     | length == 2 and all(.hold_bucket == null and .captain_actionable == false))
    and ([.backlog.records[] | select(.id == "open-call")][0].hold_bucket == "live")
  ' >/dev/null || fail "a row marked done must never carry a hold bucket, wherever it sits: $out"
  pass "a row marked done carries no hold bucket even outside the Done section"
}

test_specialists_are_listed_as_persistent_workers() {
  local home fakebin out primary fixture_root
  home=$(make_home specialists)
  mkdir -p "$home/state/specialists"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  printf '%s\n' '{"version":1,"kind":"specialist","persistent":true,"name":"amigo-tech","subject":"Amigo health","session":"fm-spec-amigo","status":"suspended","suspension":{"since":1792233602,"reason":"stopped after failed calls","by":"firstmate"},"model":"zai/glm-5.3","jobs":3,"current_job":null,"last_job":null}' \
    > "$home/state/specialists/amigo-tech.json"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    (.specialists | length) == 1
    and (.specialists[0] | .id == "spec-amigo-tech" and .name == "amigo-tech" and .kind == "specialist" and .persistent == true
         and .subject == "Amigo health" and .harness == "deck" and .model == "zai/glm-5.3"
         and .current_state.state == "suspended" and (.current_state.detail | test("stopped after failed calls")))
    and ([.tasks[] | select(.kind == "specialist")] | length) == 0
  ' >/dev/null || fail "the fleet view does not list the specialist as a persistent worker: $out"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '.specialists[0].id == "spec-amigo-tech" and .specialists[0].current_state.state == "suspended"' >/dev/null \
    || fail "the home summary does not carry the specialist: $out"
  printf '%s' "$out" > "$home/state/home-summary.json"
  primary=$(make_home specialists-primary)
  fixture_root="$TMP_ROOT/specialists-fixture-root"
  mkdir -p "$fixture_root" "$home/bin"
  printf '# Fixture home\n' > "$home/AGENTS.md"
  printf 'mate\n' > "$home/.fm-secondmate-home"
  printf -- '- mate - specialist fixture (home: %s; scope: fixture; projects: sample; added 2026-07-11)\n' \
    "$home" > "$primary/data/secondmates.md"
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fixture_root" FM_HOME="$primary" FM_DATA_OVERRIDE="$primary/data" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    (.specialists | length) == 0
    and (.secondmate_current.records[] | select(.id == "mate")
         | .registered == true and .provenance.selected == "structured-home"
           and .specialists[0].id == "spec-amigo-tech"
           and .specialists[0].current_state.state == "suspended")
  ' >/dev/null || fail "the primary snapshot dropped the registered mate specialist: $out"
  jq 'del(.specialists)' "$home/state/home-summary.json" > "$home/state/legacy-summary.json"
  mv "$home/state/legacy-summary.json" "$home/state/home-summary.json"
  out=$(PATH="$fakebin:$PATH" FM_ROOT_OVERRIDE="$fixture_root" FM_HOME="$primary" FM_DATA_OVERRIDE="$primary/data" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .secondmate_current.records[] | select(.id == "mate")
    | .provenance.selected == "structured-home" and .specialists == []
  ' >/dev/null || fail "an older mate summary must project an empty specialists array: $out"
  PATH="$fakebin:$PATH" python3 - "$ROOT" "$home" "$primary" "$fixture_root" <<'PY' \
    || fail "a working specialist must count as active home work without endpoint tasks"
import importlib.util
import json
import os
import subprocess
import sys
from pathlib import Path
root, home, primary, fixture_root = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("fm_crew", root / "bin/fm_crew.py")
crew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(crew)
record = home / "state/specialists/amigo-tech.json"
rec = json.loads(record.read_text())
runner = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)
env = dict(os.environ, FM_HOME=str(home), FM_DATA_OVERRIDE=str(home / "data"))
command = [str(root / "bin/fm-fleet-snapshot.sh")]
try:
    rec.update(status="running", current_job={"id": "live-job", "pid": runner.pid,
                                             "identity": crew.process_identity(runner.pid)})
    record.write_text(json.dumps(rec))
    summary = json.loads(subprocess.check_output([*command, "--secondmate-home-summary"], env=env, timeout=20))
    assert summary["valid"] is True and summary["state"] == "active_child_work", summary
    assert summary["active_children"] == [], summary
    assert summary["specialists"][0]["current_state"]["state"] == "working", summary
    fleet = json.loads(subprocess.check_output([*command, "--json"], env=env, timeout=20))
    assert fleet["tasks"] == [], fleet
    (home / "state/home-summary.json").write_text(json.dumps(summary))
    env.update(FM_HOME=str(primary), FM_DATA_OVERRIDE=str(primary / "data"), FM_ROOT_OVERRIDE=str(fixture_root))
    fleet = json.loads(subprocess.check_output([*command, "--json"], env=env, timeout=20))
    mate = next(r for r in fleet["secondmate_current"]["records"] if r["id"] == "mate")
    assert mate["current"]["state"] == "active_child_work" and mate["specialists"][0]["current_state"]["state"] == "working", mate
finally:
    runner.terminate()
    runner.wait(timeout=5)
    rec.update(status="idle", current_job=None)
    record.write_text(json.dumps(rec))
env.update(FM_HOME=str(home), FM_DATA_OVERRIDE=str(home / "data"))
summary = json.loads(subprocess.check_output([*command, "--secondmate-home-summary"], env=env, timeout=20))
assert summary["valid"] is True and summary["state"] == "no_active_work", summary
PY
  pass "working specialists make their home active and idle specialists do not"
}

test_main_inventory_orphan_and_unstructured_disclosure() {
  local home fakebin out
  home=$(make_home main-inventory)
  mkdir -p "$home/projects/visible"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
free-form current note
- [ ] orphan-ship - Structured without meta (repo: alpha) (kind: ship) (since 2026-07-11)
- [ ] visible-ship - Structured with meta (repo: alpha) (kind: ship) (since 2026-07-11)

## Queued
another free-form queued note
- [ ] queued-ship - Structured queued (repo: alpha) (kind: ship)

## Done
EOF
  fm_write_meta "$home/state/visible-ship.meta" \
    $(snap_identity "$home" visible-ship visible-ship) \
    "worktree=$home/projects/visible" \
    "project=alpha" \
    "harness=deck" \
    "kind=ship" \
    "mode=ship"
  printf 'working: visible\n' > "$home/state/visible-ship.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory.valid == false
      and .main_inventory.reason == "unstructured current backlog row"
      and .main_inventory.unstructured_current_count == 2
      and (.main_inventory.orphan_in_flight == ["orphan-ship"])
      and ([.tasks[].id] == ["visible-ship"])
  ' >/dev/null || fail "main_inventory did not disclose orphan/unstructured: $out"
  # Counterfactual: add meta for the orphan and strip free-form current lines.
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] orphan-ship - Structured without meta (repo: alpha) (kind: ship) (since 2026-07-11)
- [ ] visible-ship - Structured with meta (repo: alpha) (kind: ship) (since 2026-07-11)

## Queued
- [ ] queued-ship - Structured queued (repo: alpha) (kind: ship)

## Done
EOF
  fm_write_meta "$home/state/orphan-ship.meta" \
    $(snap_identity "$home" orphan-ship orphan-ship) \
    "worktree=$home/projects/visible" \
    "project=alpha" \
    "harness=deck" \
    "kind=ship" \
    "mode=ship"
  printf 'working: orphan now live\n' > "$home/state/orphan-ship.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory.valid == true
      and .main_inventory.reason == null
      and .main_inventory.unstructured_current_count == 0
      and (.main_inventory.orphan_in_flight | length) == 0
      and (([.tasks[].id] | sort) == ["orphan-ship", "visible-ship"])
  ' >/dev/null || fail "main_inventory stayed invalid after meta + structured cleanup: $out"
  pass "main_inventory discloses orphan/unstructured and clears when inventory is consistent"
}

test_normalized_roles_and_plural_blocker_readiness() {
  local home fakebin out
  home=$(make_home normalized-records)
  mkdir -p "$home/projects/worker"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: scout) (hold: watch production) (hold-kind: external)
- [ ] worker - Real worker (repo: alpha) (kind: ship)
- [ ] orphan - Ordinary missing worker (repo: alpha) (kind: ship)

## Queued
- [ ] review - Security review (repo: alpha) (kind: ship)
- [ ] captain-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
EOF
  fm_write_meta "$home/state/worker.meta" \
    $(snap_identity "$home" worker worker) "worktree=$home/projects/worker" "project=alpha" \
    "harness=deck" "kind=ship" "mode=ship"
  printf 'working: preparing canary\n' > "$home/state/worker.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .main_inventory.orphan_in_flight == ["orphan"]
      and (.backlog.records[] | select(.id == "program")
        | .current_role == "program" and .requires_child_metadata == false)
      and (.backlog.records[] | select(.id == "observation")
        | .current_role == "held" and .requires_child_metadata == false)
      and (.backlog.records[] | select(.id == "orphan")
        | .current_role == "worker" and .requires_child_metadata == true)
      and (.backlog.records[] | select(.id == "captain-run")
        | .blocked_by == "review"
          and .blocked_by_ids == ["worker", "review"]
          and .unresolved_blocker_ids == ["worker", "review"]
          and .captain_actionable == false)
  ' >/dev/null || fail "normalized role or plural blocker fields were wrong: $out"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: scout) (hold: watch production) (hold-kind: external)

## Queued
- [ ] review - Security review (repo: alpha) (kind: ship)
- [ ] captain-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
- [x] worker - Real worker (repo: alpha) (kind: ship) (done 2026-07-22)
EOF
  rm "$home/state/worker.meta" "$home/state/worker.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-run")
    | .blocked_by == "review"
      and .blocked_by_ids == ["worker", "review"]
      and .unresolved_blocker_ids == ["review"]
      and .captain_actionable == false
  ' >/dev/null || fail "one completed blocker did not leave exactly one unresolved id: $out"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] program - Aggregate program (repo: alpha) (kind: program)
- [ ] observation - Held observation (repo: alpha) (kind: scout) (hold: watch production) (hold-kind: external)

## Queued
- [ ] captain-run - Run canary blocked-by: worker blocked-by: review (repo: alpha) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
- [x] worker - Real worker (repo: alpha) (kind: ship) (done 2026-07-22)
- [x] review - Security review (repo: alpha) (kind: ship) (done 2026-07-22)
EOF
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-run")
    | .blocked_by == "review"
      and .blocked_by_ids == ["worker", "review"]
      and .unresolved_blocker_ids == []
      and .captain_actionable == true
  ' >/dev/null || fail "completed blockers did not make the captain hold actionable: $out"

  sed 's/blocked-by: review/blocked-by: missing/' "$home/data/backlog.md" > "$home/data/backlog.next"
  mv "$home/data/backlog.next" "$home/data/backlog.md"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-run")
    | .blocked_by_ids == ["worker", "missing"]
      and .unresolved_blocker_ids == ["missing"]
      and .captain_actionable == false
  ' >/dev/null || fail "a missing blocker was incorrectly treated as resolved: $out"
  pass "backlog normalization preserves strict roles and resolves every blocker compatibly"
}

test_event_hints_follow_reconciled_current_state() {
  local home fakebin out hint_gen
  home=$(make_home event-hints)
  mkdir -p \
    "$home/projects/active-decision" \
    "$home/projects/active-blocked" \
    "$home/projects/stale-decision" \
    "$home/projects/stale-blocked"
  fm_write_meta "$home/state/active-decision.meta" \
    $(snap_identity "$home" active-decision active-decision) \
    "worktree=$home/projects/active-decision" \
    "project=alpha" \
    "harness=deck" \
    "kind=ship" \
    "mode=ship"
  record_deck_idle "$home/state" active-decision
  printf 'needs-decision: choose an API shape\n' > "$home/state/active-decision.status"
  fm_write_meta "$home/state/active-blocked.meta" \
    $(snap_identity "$home" active-blocked active-blocked) \
    "worktree=$home/projects/active-blocked" \
    "project=alpha" \
    "harness=deck" \
    "kind=ship" \
    "mode=ship"
  record_deck_idle "$home/state" active-blocked
  printf 'blocked: waiting on access\n' > "$home/state/active-blocked.status"
  fm_write_meta "$home/state/stale-decision.meta" \
    $(snap_identity "$home" stale-decision stale-decision-ship-task) \
    "worktree=$home/projects/stale-decision" \
    "project=alpha" \
    "harness=deck" \
    "kind=ship" \
    "mode=ship"
  hint_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" stale-decision)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" stale-decision busy --gen "$hint_gen" \
    --source deck-wrapper --event turn-start
  printf 'needs-decision: already answered\n' > "$home/state/stale-decision.status"
  fm_write_meta "$home/state/stale-blocked.meta" \
    $(snap_identity "$home" stale-blocked stale-blocked-ship-task) \
    "worktree=$home/projects/stale-blocked" \
    "project=alpha" \
    "harness=deck" \
    "kind=ship" \
    "mode=ship"
  hint_gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" stale-blocked)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" stale-blocked busy --gen "$hint_gen" \
    --source deck-wrapper --event turn-start
  printf 'blocked: old failure\n' > "$home/state/stale-blocked.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    def task($id): (.tasks[] | select(.id == $id));
    task("active-decision").current_state.state == "parked"
      and task("active-decision").hints.pending_decision == true
      and task("active-blocked").current_state.state == "blocked"
      and task("active-blocked").hints.blocked_event == true
      and task("stale-decision").current_state.state == "working"
      and task("stale-decision").hints.pending_decision == false
      and task("stale-blocked").current_state.state == "working"
      and task("stale-blocked").hints.blocked_event == false
  ' >/dev/null || fail "event hints must follow reconciled current state"
  pass "snapshot event hints follow reconciled current state"
}

test_scout_reports_include_teardown_reports() {
  local home out
  home=$(make_home teardown-reports)
  mkdir -p "$home/data/reported-scout" "$home/data/untracked-scout"
  cat > "$home/data/backlog.md" <<EOF
## Done
- [x] reported-scout - Reported Scout data/reported-scout/report.md (repo: alpha, reported 2026-07-07) (kind: scout)
EOF
  printf '# Reported Scout\n' > "$home/data/reported-scout/report.md"
  printf '# Untracked Scout\n' > "$home/data/untracked-scout/report.md"
  out=$(FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg home "$home" '
    (.tasks | length) == 0
      and .scout_reports == [
        {id:"reported-scout",path:($home + "/data/reported-scout/report.md"),kind:"scout"},
        {id:"untracked-scout",path:($home + "/data/untracked-scout/report.md"),kind:"scout"}
      ]
  ' >/dev/null || fail "durable scout reports should remain visible after meta teardown"
  pass "snapshot includes durable scout reports after teardown"
}

test_backlog_tasks_axi_forms_and_overrides() {
  local home data projects fakebin out view
  home=$(make_home overrides)
  data=$TMP_ROOT/override-data
  projects=$TMP_ROOT/override-projects
  mkdir -p "$data/bold-task" "$projects/bold-worktree"
  cat > "$data/backlog.md" <<EOF
## In flight
- **bold-task** - Bold Task data/bold-task/report.md (repo: alpha, since 2026-07-07) (kind: scout)
  Bold body survives.

## Queued
- [ ] queued-comma - Queued Comma Task (repo: beta, since 2026-07-08) (kind: ship)
- [ ] parenthetical-title - Refresh sidebar (mobile) (repo: beta) (kind: ship)
- [ ] blocked-reason - Blocked Reason (repo: beta) (kind: ship) blocked-by: queued-comma - waits on queued-comma
- [ ] sample-decision-route - Choose sample route (repo: sample) (kind: captain) (since 2026-07-14) (hold: captain route choice pending) (hold-kind: captain)
- [ ] dated-route - Deferred sample route (repo: sample) (kind: ship) (hold: captain sent this to later) (hold-kind: captain) (hold-until: 2026-09-01)
- [ ] captain-gated-work - Captain-gated ship work (repo: sample) (kind: ship) (hold: captain go pending) (hold-kind: captain)
- [ ] parked-prose - Parked captain call (repo: sample) (kind: ship) (hold: DEFERRED by captain) (hold-kind: captain)

## Done
- [x] done-comma - Done Comma Task https://github.com/kunchenguid/firstmate/pull/42 (repo: gamma, merged 2026-07-09) (kind: ship)
  Outcome: merged https://github.com/kunchenguid/firstmate/pull/42
- [x] done-bracket-pr - Done Bracket PR - <https://github.com/kunchenguid/firstmate/pull/43> (repo: gamma, merged 2026-07-12) (kind: ship)
  Outcome: merged https://github.com/kunchenguid/firstmate/pull/43
- [x] reported-comma - Reported Scout data/reported-comma/report.md (repo: gamma, reported 2026-07-10) (kind: scout)
- [x] done-note - Done Note local main (repo: delta, done 2026-07-11) (kind: ship)
EOF
  printf '# Bold Scout\n' > "$data/bold-task/report.md"
  fm_write_meta "$home/state/bold-task.meta" \
    $(snap_identity "$home" bold-task bold-task) \
    "worktree=$projects/bold-worktree" \
    "project=alpha" \
    "harness=deck" \
    "kind=scout" \
    "mode=scout"
  record_deck_idle "$home/state" bold-task
  printf 'done: report ready\n' > "$home/state/bold-task.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_PROJECTS_OVERRIDE="$projects" \
    FM_SNAPSHOT_NOW=2026-07-14T00:00:00Z "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e --arg data "$data" --arg projects "$projects" '
    .roots.data == $data
      and .roots.projects == $projects
      and .backlog.path == ($data + "/backlog.md")
  ' >/dev/null || fail "snapshot did not respect data/projects overrides"
  printf '%s' "$out" | jq -e --arg data "$data" '
    .backlog.records[] | select(.id == "bold-task")
    | .structured == true
      and .state == "in_flight"
      and .checked == false
      and .repo == "alpha"
      and .since == "2026-07-07"
      and .kind == "scout"
      and .title == "Bold Task"
      and .body_excerpt == "Bold body survives."
      and .report_path == "data/bold-task/report.md"
  ' >/dev/null || fail "bold in-flight backlog row did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "queued-comma")
    | .repo == "beta" and .since == "2026-07-08"
  ' >/dev/null || fail "queued comma metadata did not split"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "parenthetical-title")
    | .title == "Refresh sidebar (mobile)" and .repo == "beta"
  ' >/dev/null || fail "title parenthetical was stripped with metadata"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "blocked-reason")
    | .title == "Blocked Reason"
      and .repo == "beta"
      and .blocked_by == "queued-comma"
      and .blocked_reason == "waits on queued-comma"
  ' >/dev/null || fail "blocked suffix did not parse into title and reason"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "sample-decision-route")
    | .title == "Choose sample route"
      and .repo == "sample"
      and .kind == "captain"
      and .hold_reason == "captain route choice pending"
      and .hold_kind == "captain"
      and .captain_actionable == true
  ' >/dev/null || fail "tasks-axi captain-hold metadata did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "dated-route")
    | .title == "Deferred sample route"
      and .hold_until == "2026-09-01"
      and .captain_actionable == false
      and .hold_bucket == "dated"
  ' >/dev/null || fail "a dated captain hold did not defer or strip its hold-until from the title"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "captain-gated-work")
    | .kind == "ship" and .captain_actionable == true and .hold_bucket == "live"
  ' >/dev/null || fail "captain actionability must not depend on the row kind"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "parked-prose")
    | .captain_actionable == true and .hold_bucket == "live"
  ' >/dev/null || fail "hold prose must never classify a captain hold"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-comma")
    | .repo == "gamma"
      and .merged == "2026-07-09"
      and .completion == {verb:"merged",date:"2026-07-09"}
  ' >/dev/null || fail "done comma metadata did not split"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-bracket-pr")
    | .repo == "gamma"
      and .title == "Done Bracket PR"
      and .pr_url == "https://github.com/kunchenguid/firstmate/pull/43"
      and .links == ["https://github.com/kunchenguid/firstmate/pull/43"]
      and .completion == {verb:"merged",date:"2026-07-12"}
  ' >/dev/null || fail "bracketed PR artifact did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "reported-comma")
    | .repo == "gamma"
      and .title == "Reported Scout"
      and .reported == "2026-07-10"
      and .completion == {verb:"reported",date:"2026-07-10"}
  ' >/dev/null || fail "reported closure metadata did not parse"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "done-note")
    | .repo == "delta"
      and .title == "Done Note"
      and .local_note == "local main"
      and .done == "2026-07-11"
      and .completion == {verb:"done",date:"2026-07-11"}
  ' >/dev/null || fail "done closure metadata did not parse"
  printf '%s' "$out" | jq -e --arg data "$data" '
    .tasks[] | select(.id == "bold-task")
    | .backlog.id == "bold-task"
      and .paths.report.path == ($data + "/bold-task/report.md")
      and .paths.report.present == true
  ' >/dev/null || fail "bold task did not join to override-backed backlog and report"
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$data" FM_PROJECTS_OVERRIDE="$projects" "$VIEW")
  assert_contains "$view" "| bold-task | done / status-log | scout | alpha | stream | present | $data/bold-task/report.md" \
    "view should render bold in-flight row from snapshot"
  assert_contains "$view" "| blocked-reason | Blocked Reason | beta | ship | queued-comma - waits on queued-comma | - |" \
    "view should render blocked reason without title metadata"
  assert_contains "$view" "| done-bracket-pr | Done Bracket PR | gamma | ship | - | https://github.com/kunchenguid/firstmate/pull/43 |" \
    "view should render bracketed PR artifact outside the title"
  assert_contains "$view" "| done-note | Done Note | delta | ship | - | local main |" \
    "view should render local-only done artifact outside the title"
  pass "snapshot parses tasks-axi rows and respects operational overrides"
}

test_undated_captain_hold_phrasing_and_aging() {
  local home fakebin out
  home=$(make_home undated-aging)
  mkdir -p "$home/data"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] parked-hold - Parked style call (repo: sample) (kind: ship) (hold: parked) (hold-kind: captain)
- [ ] awaiting-go - Awaiting go call (repo: sample) (kind: ship) (hold: awaiting captain go) (hold-kind: captain)
- [ ] no-dispatch - No dispatch call (repo: sample) (kind: ship) (hold: do not dispatch) (hold-kind: captain)
- [ ] no-auto - No auto-dispatch call (repo: sample) (kind: ship) (hold: do not auto-dispatch) (hold-kind: captain)
- [ ] not-urgent - Not urgent call (repo: sample) (kind: ship) (hold: not urgent) (hold-kind: captain)
- [ ] deprior - Deprioritized call (repo: sample) (kind: ship) (hold: de-prioritized) (hold-kind: captain)
- [ ] queued-opp - Queued opportunity call (repo: sample) (kind: ship) (hold: queued opportunity) (hold-kind: captain)
- [ ] gated-hold - Captain-gated phrasing (repo: sample) (kind: ship) (hold: captain-gated) (hold-kind: captain)
- [ ] aged-call - Aged genuine call (repo: sample) (kind: captain) (since 2026-07-01) (hold: choose a sample route) (hold-kind: captain)
  Captain hold set: 2026-07-01T00:00:00Z
- [ ] recent-call - Recent genuine call (repo: sample) (kind: captain) (since 2026-06-01) (hold: choose a sample route) (hold-kind: captain)
  Captain hold set: 2026-07-20T00:00:00Z
- [ ] legacy-old-hold - Legacy unstamped hold (repo: sample) (kind: ship) (since 2026-06-01) (hold: choose a sample route) (hold-kind: captain)
  Historical notes remain ordinary task content.
  Captain hold set: 2026-07-24T00:00:00Z
- [ ] boundary-call - Almost aged genuine call (repo: sample) (kind: captain) (since 2026-06-01) (hold: choose a sample route) (hold-kind: captain)
  Captain hold set: 2026-07-11T00:01:00Z
- [ ] live-gated - Live captain-gated work (repo: sample) (kind: ship) (hold: captain go pending) (hold-kind: captain)
- [ ] unparked-call - Newly unparked decision (repo: sample) (kind: captain) (hold: unparked; choose a sample route) (hold-kind: captain)
- [ ] contextual-call - Context is not a deferral (repo: sample) (kind: captain) (hold: choose whether to pursue this queued opportunity) (hold-kind: captain)
  This is not urgent context, but the captain decision is current.
- [ ] contextual-not-urgent - Leading context is not a deferral (repo: sample) (kind: captain) (hold: not urgent but choose the route now) (hold-kind: captain)
- [ ] contextual-comma - Comma context is not a deferral (repo: sample) (kind: captain) (hold: not urgent, choose the launch route now) (hold-kind: captain)
- [ ] metadata-context - Metadata-like context is not a deferral (repo: sample) (kind: captain) (hold: not urgent, priority: decide P1 or P2) (hold-kind: captain)
- [ ] contextual-opportunity - Leading opportunity is not a deferral (repo: sample) (kind: captain) (hold: queued opportunity: choose whether to proceed) (hold-kind: captain)
- [ ] contextual-gated - Leading gate is not a deferral (repo: sample) (kind: captain) (hold: captain-gated decision needs current approval) (hold-kind: captain)

## Done
EOF
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.id == "parked-hold" or .id == "awaiting-go" or .id == "no-dispatch"
        or .id == "no-auto" or .id == "not-urgent" or .id == "deprior" or .id == "queued-opp"
        or .id == "gated-hold")]
     | all(.captain_actionable == true and .hold_bucket == "live"))
  ' >/dev/null || fail "parked-style wording must never classify a fresh undated hold: $out"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "aged-call")
    | .captain_actionable == false
      and .hold_bucket == "aged"
      and .hold_age_days == 24
  ' >/dev/null || fail "an undated captain hold older than the default 14-day threshold must age: $out"
  printf '%s' "$out" | jq -e '
    ([.backlog.records[] | select(.id == "recent-call")][0]) as $recent
    | ([.backlog.records[] | select(.id == "legacy-old-hold")][0]) as $legacy
    | $recent.captain_actionable == true
      and $recent.hold_bucket == "live"
      and $recent.hold_age_days == 5
      and $legacy.captain_actionable == false
      and $legacy.hold_set == null
      and $legacy.hold_bucket == "aged"
      and $legacy.hold_age_days == 54
  ' >/dev/null || fail "recent stamped and legacy unstamped hold ages are wrong: $out"
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "boundary-call")
    | .hold_set == "2026-07-11T00:01:00Z"
      and .hold_age_days == 13 and .hold_bucket == "live"
  ' >/dev/null || fail "a hold one minute short of 14 days must not age early: $out"
  printf '%s' "$out" | jq -e '
    [.backlog.records[] | select(.id == "live-gated" or .id == "unparked-call" or .id == "contextual-call"
        or .id == "contextual-not-urgent" or .id == "contextual-comma" or .id == "metadata-context"
        or .id == "contextual-opportunity" or .id == "contextual-gated")]
    | length == 8
      and all(.captain_actionable == true and .hold_bucket == "live")
      and (map(select(.id == "contextual-comma" and .hold_reason == "not urgent, choose the launch route now")) | length == 1)
      and (map(select(.id == "metadata-context" and .hold_reason == "not urgent, priority: decide P1 or P2")) | length == 1)
  ' >/dev/null || fail "contextual parked-style wording must not hide current decisions: $out"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=30 "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "aged-call")
    | .hold_bucket == "live" and .hold_age_days == 24
  ' >/dev/null || fail "raising the age threshold must leave a 24-day hold unaged: $out"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" \
    FM_SNAPSHOT_NOW=2026-07-25T00:00:00Z FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=5 "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .backlog.records[] | select(.id == "recent-call")
    | .hold_bucket == "aged" and .hold_age_days == 5
  ' >/dev/null || fail "lowering the age threshold to 5 must age a 5-day hold: $out"
  pass "undated captain holds age after a configurable threshold, decided only from structured fields"
}

test_view_renders_snapshot() {
  local home fakebin view
  home=$(make_home view)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  assert_contains "$view" "| ship-task | working / pane | ship | alpha | stream | present | https://github.com/kunchenguid/firstmate/pull/9" \
    "view should render ship row from snapshot"
  assert_contains "$view" "| queued-task | Queued Task | alpha | ship | ship-task | -" \
    "view should render queued backlog row"
  assert_contains "$view" "| done-task | Done Task | alpha | ship | - | https://github.com/kunchenguid/firstmate/pull/7 |" \
    "view should render done backlog row"
  assert_contains "$view" "bin/fm-send.sh fm-secondmate-task" \
    "view should show secondmate send guidance"
  assert_contains "$view" "| secondmate-task | working / status-log | secondmate | $home/secondmate-home | stream | present / alive |" \
    "view should show secondmate endpoint agent liveness"
  assert_not_contains "$view" "fm-peek.sh fm-secondmate-task" \
    "view must not tell firstmate to routinely peek secondmates"
  pass "fleet view renders the snapshot without secondmate peek guidance"
}

test_view_renders_dead_secondmate_agent_status() {
  local home fakebin view
  home=$(make_home dead-secondmate)
  fm_write_meta "$home/state/dead-secondmate.meta" \
    $(snap_identity "$home" dead-secondmate dead-secondmate) \
    "project=$home/secondmate-home" \
    "harness=deck" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha, beta"
  printf 'working: watching delegated scope\n' > "$home/state/dead-secondmate.status"
  fakebin=$(make_fakebin "$home")
  view=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  assert_contains "$view" "| dead-secondmate | unknown / none | secondmate | $home/secondmate-home | stream | present / dead |" \
    "view should distinguish a present secondmate endpoint from a dead agent"
  assert_contains "$view" "| dead-secondmate | unknown / none | secondmate | $home/secondmate-home | stream | present / dead | - | $home/secondmate-home (absent) |" \
    "view should show a recorded missing secondmate home path"
  pass "fleet view renders secondmate agent liveness"
}

# A still-open decision must survive a LATER, UNRELATED terminal event on the same
# append-only stream. This is the fmdev masking bug: last-event-wins read the trailing
# `done` and reported pending_decision=false while a needs-decision was still open. The
# durable keyed fold (fm-classify-lib.sh) keeps it open until an explicit resolution.
test_open_decision_survives_later_unrelated_event() {
  local home fakebin out
  home=$(make_home masking)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/masked-decision.meta" \
    $(snap_identity "$home" masked-decision masked-decision) \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=deck" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  # needs-decision opened, then two LATER unrelated events (no resolution).
  printf 'needs-decision [key=race]: fix the reconcile-before-subscribe race\n' > "$home/state/masked-decision.status"
  printf 'working: implementing an unrelated subsystem\n' >> "$home/state/masked-decision.status"
  printf 'done: an unrelated subtask finished\n' >> "$home/state/masked-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "masked-decision")
    | .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
      and .hints.open_decisions[0].key == "race"
      and .hints.open_decisions[0].verb == "needs-decision"
  ' >/dev/null || fail "later unrelated done must not mask an open needs-decision: $out"
  pass "durable fold keeps an open decision past a later unrelated event"
}

test_secondmate_open_decision_survives_live_endpoint() {
  local home fakebin out
  home=$(make_home active-secondmate)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/active-secondmate.meta" \
    $(snap_identity "$home" active-secondmate active-secondmate) \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=deck" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  printf 'needs-decision [key=race]: choose ordering\n' > "$home/state/active-secondmate.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "active-secondmate")
    | .endpoint.agent_alive == "alive"
      and .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
  ' >/dev/null || fail "a live secondmate endpoint must not clear an unrelated keyed decision: $out"
  pass "a live secondmate endpoint preserves unrelated open decisions"
}

# An open decision clears ONLY on an explicit resolution referencing its key, never
# on an unrelated terminal line.
test_open_decision_transfers_to_captain_hold() {
  local home fakebin out
  home=$(make_home captain-held-transfer)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/transferred-decision.meta" \
    $(snap_identity "$home" transferred-decision transferred-decision) \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=deck" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=sample"
  printf 'needs-decision [key=route]: choose a sample route\n' > "$home/state/transferred-decision.status"
  printf 'captain-held [key=route]: tracked by transferred-decision-route\n' >> "$home/state/transferred-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "transferred-decision")
    | .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
  ' >/dev/null || fail "captain-held transfer must close only the duplicate status copy: $out"
  pass "durable captain-held transfer closes the duplicate live status decision"
}

test_open_decision_clears_on_keyed_resolution() {
  local home fakebin out
  home=$(make_home resolution)
  mkdir -p "$home/secondmate-home"
  fm_write_meta "$home/state/resolved-decision.meta" \
    $(snap_identity "$home" resolved-decision resolved-decision) \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=deck" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  printf 'needs-decision [key=race]: fix the reconcile-before-subscribe race\n' > "$home/state/resolved-decision.status"
  printf 'done: an unrelated subtask finished\n' >> "$home/state/resolved-decision.status"
  printf 'resolved [key=race]: captain chose subscribe-then-reconcile\n' >> "$home/state/resolved-decision.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "resolved-decision")
    | .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
  ' >/dev/null || fail "keyed resolution must clear the open decision: $out"
  pass "durable fold clears a decision only on a keyed resolution"
}

# A COMPLETED scout report must never be read as a pending decision. A scout that
# raised a needs-decision and then finished (done) - its report delivered, its
# decision either answered or captured in the report for the captain - must surface
# only as a report POINTER, not a reopened pending decision, even when the report
# body and the stale status line contain decision-like prose. This is the Lavish-103
# defect: a terminal single-owner task's stale, never-keyed-resolved needs-decision
# must not linger as pending. Decisions come purely from the keyed fold reconciled
# against the crew lifecycle; report prose never opens or reopens a decision.
test_completed_scout_report_is_pointer_not_pending() {
  local home fakebin out
  home=$(make_home completed-scout)
  mkdir -p "$home/projects/scout-wt" "$home/data/lavish-103"
  fm_write_meta "$home/state/lavish-103.meta" \
    $(snap_identity "$home" lavish-103 lavish-103) \
    "worktree=$home/projects/scout-wt" \
    "project=firstmate" \
    "harness=deck" \
    "kind=scout" \
    "mode=scout"
  record_deck_idle "$home/state" lavish-103
  # Stale needs-decision, then the scout finished (done). No keyed resolution.
  printf 'needs-decision: adopt approach A or B for Lavish issue 103\n' > "$home/state/lavish-103.status"
  printf 'done: report ready at data/lavish-103/report.md\n' >> "$home/state/lavish-103.status"
  # Completed report whose PROSE reads like the decision.
  printf '# Lavish 103\nThe open question is whether to adopt approach A or B.\nThis needs a captain decision. Recommendation: A.\n' > "$home/data/lavish-103/report.md"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "lavish-103")
    | .current_state.state == "done"
      and .hints.pending_decision == false
      and (.hints.open_decisions | length) == 0
      and .hints.scout_report_present == true
  ' >/dev/null || fail "a completed scout report must be a pointer, not a pending decision: $out"
  pass "a completed scout's stale decision surfaces as a report pointer, not pending"
}

# The complementary safety property: a scout still PARKED at a decision (its last
# event is the needs-decision, it has not finished) DOES stay pending. The terminal
# clear must not over-fire on a live, undecided scout.
test_parked_scout_decision_stays_pending() {
  local home fakebin out
  home=$(make_home parked-scout)
  mkdir -p "$home/projects/scout-wt2"
  fm_write_meta "$home/state/parked-scout.meta" \
    $(snap_identity "$home" parked-scout parked-scout) \
    "worktree=$home/projects/scout-wt2" \
    "project=firstmate" \
    "harness=deck" \
    "kind=scout" \
    "mode=scout"
  record_deck_idle "$home/state" parked-scout
  printf 'needs-decision [key=q1]: adopt approach A or B\n' > "$home/state/parked-scout.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "parked-scout")
    | .hints.pending_decision == true
      and (.hints.open_decisions | length) == 1
      and .hints.open_decisions[0].key == "q1"
  ' >/dev/null || fail "a scout still parked at a decision must stay pending: $out"
  pass "a scout still parked at a decision stays pending (terminal clear does not over-fire)"
}

test_unavailable_run_preserves_open_ship_decision() {
  local home fakebin out query head
  home=$(make_home unavailable-run-decision)
  mkdir -p "$home/projects/ship-wt"
  fm_git_identity fmtest fmtest@example.invalid
  git -C "$home/projects/ship-wt" init -q
  git -C "$home/projects/ship-wt" commit -q --allow-empty -m init
  git -C "$home/projects/ship-wt" checkout -q -b fm/unavailable-decision
  head=$(git -C "$home/projects/ship-wt" rev-parse HEAD)
  fm_write_meta "$home/state/ship-decision.meta" \
    $(snap_identity "$home" ship-decision ship-decision) \
    "worktree=$home/projects/ship-wt" "project=firstmate" \
    "harness=deck" "kind=ship" "mode=no-mistakes"
  record_deck_idle "$home/state" ship-decision
  printf 'needs-decision [key=q1]: choose a validation finding response\n' > "$home/state/ship-decision.status"
  fakebin=$(make_fakebin "$home")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${1:-} ${2:-}" = 'axi status' ] || exit 0
case "$FM_FAKE_QUERY" in
  failed) exit 1 ;;
  timed-out) exec sleep 30 ;;
esac
printf 'run:\n  id: "DECISION-RUN"\n  branch: fm/unavailable-decision\n  head: "%s"\n' "$FM_FAKE_HEAD"
[ "$FM_FAKE_QUERY" = partial ] || printf '  status: running\n'
SH
  for query in failed timed-out partial; do
    out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_CREW_STATE_NM_TIMEOUT=1 \
      FM_FAKE_QUERY="$query" FM_FAKE_HEAD="$head" "$SNAPSHOT" --json)
    printf '%s' "$out" | jq -e '
      .tasks[] | select(.id == "ship-decision")
      | .current_state.state == "unknown"
        and .current_state.source == "run-step"
        and .hints.pending_decision == true
        and (.hints.open_decisions | length) == 1
        and .hints.open_decisions[0].key == "q1"
        and .hints.open_decisions[0].verb == "needs-decision"
    ' >/dev/null || fail "$query validation observation must preserve the idle ship decision: $out"
  done
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_QUERY=running \
    FM_FAKE_HEAD="$head" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '
    .tasks[] | select(.id == "ship-decision")
    | .current_state.state == "working"
      and .current_state.source == "run-step"
      and .hints.pending_decision == false
      and .hints.open_decisions == []
  ' >/dev/null || fail "positive resumed-run evidence must still clear the stale decision: $out"
  pass "unknown validation preserves open decisions; a positively resumed run clears stale ones"
}

# Home-summary validity treats persistent secondmates as registered homes, not
# in-flight children. They have no backlog rows, so they must not produce
# unowned_current or terminal_in_flight. Ordinary crew/ship metas still do.
test_home_summary_excludes_secondmate_from_child_inventory() {
  local home fakebin out
  home=$(make_home summary-secondmate-only)
  mkdir -p "$home/secondmate-home" "$home/projects/unowned" "$home/projects/terminal"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  fm_write_meta "$home/state/mate.meta" \
    $(snap_identity "$home" mate mate) \
    "worktree=$home/secondmate-home" \
    "project=$home/secondmate-home" \
    "harness=deck" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$home/secondmate-home" \
    "projects=alpha"
  printf 'working: watching delegated scope\n' > "$home/state/mate.status"
  fakebin=$(make_fakebin "$home")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '
    .schema == "fm-secondmate-home-summary.v1"
      and .valid == true
      and .reason == null
      and .invalidity == {kind:null,ids:[]}
      and (.invalidity.kind != "unowned_current")
      and (.invalidity.kind != "terminal_in_flight")
  ' >/dev/null || fail "secondmate-only home with a clean backlog must be VALID: $out"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] mate - Registered secondmate home (repo: alpha) (kind: secondmate) (since 2026-07-11)

## Queued

## Done
EOF
  printf 'done: delegated scope complete\n' > "$home/state/mate.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '
    .valid == true
      and .reason == null
      and .invalidity == {kind:null,ids:[]}
      and (.invalidity.kind != "terminal_in_flight")
  ' >/dev/null || fail "terminal secondmate with a matching in-flight row must not produce terminal_in_flight: $out"

  fm_write_meta "$home/state/unowned-ship.meta" \
    $(snap_identity "$home" unowned-ship unowned-ship) \
    "worktree=$home/projects/unowned" \
    "project=alpha" \
    "harness=deck" \
    "kind=ship" \
    "mode=no-mistakes"
  record_deck_idle "$home/state" unowned-ship
  printf 'needs-decision [key=unowned-ship]: choose a route\n' > "$home/state/unowned-ship.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '
    .valid == false
      and .invalidity == {kind:"unowned_current",ids:["unowned-ship"]}
      and (.reason | contains("unowned-ship=parked"))
      and (.reason | contains("mate=") | not)
  ' >/dev/null || fail "ordinary unowned ship must still produce unowned_current without listing the secondmate: $out"

  rm -f "$home/state/unowned-ship.meta" "$home/state/unowned-ship.status"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] terminal-ship - Done child still in flight (repo: alpha) (kind: ship) (since 2026-07-11)

## Queued

## Done
EOF
  fm_write_meta "$home/state/terminal-ship.meta" \
    $(snap_identity "$home" terminal-ship terminal-ship) \
    "worktree=$home/projects/terminal" \
    "project=alpha" \
    "harness=deck" \
    "kind=ship" \
    "mode=no-mistakes"
  record_deck_idle "$home/state" terminal-ship
  printf 'done: complete\n' > "$home/state/terminal-ship.status"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --secondmate-home-summary)
  printf '%s' "$out" | jq -e '
    .valid == false
      and .invalidity == {kind:"terminal_in_flight",ids:["terminal-ship"]}
      and (.reason | contains("terminal-ship=done"))
      and (.reason | contains("mate=") | not)
  ' >/dev/null || fail "ordinary terminal in-flight ship must still produce terminal_in_flight without listing the secondmate: $out"
  pass "home-summary excludes kind=secondmate from unowned_current and terminal_in_flight"
}

test_recovery_projects_stalled_timing_without_mutating_it() {
  local home wt fakebin gen raw out old before
  home=$(make_home stalled-recovery)
  wt="$home/projects/implementation"
  mkdir -p "$wt"
  fm_git_identity fmtest fmtest@example.invalid
  git -C "$wt" init -q
  git -C "$wt" commit -q --allow-empty -m init
  git -C "$wt" checkout -q -b fm/stalled-recovery
  fm_write_meta "$home/state/implementation.meta" \
    $(snap_identity "$home" implementation ship-task) \
    "worktree=$wt" "harness=deck" "kind=ship" "mode=no-mistakes"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$home/state" implementation)
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" implementation busy --gen "$gen" \
    --source deck-wrapper --event turn-start
  fakebin=$(make_fakebin "$home")
  raw=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-crew-state.sh" implementation)
  old=$(( $(date +%s) - 8000 ))
  python3 "$ROOT/bin/fm_stall_record.py" "$home/state/idle-sweep/implementation.stall.json" \
    "$home/state/implementation.meta" "$raw" '' --observe --now "$old" >/dev/null
  before=$(cat "$home/state/idle-sweep/implementation.stall.json")
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$SNAPSHOT" --json)
  printf '%s' "$out" | jq -e '.tasks[] | select(.id=="implementation") |
    .current_state.state=="working" and .current_state.stall.state=="stalled"
    and .current_state.stall.age_seconds > 7200' >/dev/null || fail "recovery stall projection: $out"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$VIEW")
  assert_contains "$out" 'stalled: implementation' 'human recovery view hides stall'
  assert_equals "$before" "$(cat "$home/state/idle-sweep/implementation.stall.json")" 'recovery mutated timing'
  pass "recovery traversal computes stall age without replacing current state or changing records"
}

test_recovery_projects_stalled_timing_without_mutating_it
test_empty_fleet_json
test_reopened_task_keeps_its_current_pr_identity
test_fixture_snapshot_json
test_home_summary_excludes_secondmate_from_child_inventory
test_home_summary_reads_remote_mates_retained_records_and_local_only_ships
test_undated_captain_hold_phrasing_and_aging
test_hold_buckets_are_total_and_text_blind
test_checked_rows_never_carry_a_hold_bucket
test_specialists_are_listed_as_persistent_workers
test_main_inventory_orphan_and_unstructured_disclosure
test_normalized_roles_and_plural_blocker_readiness
test_event_hints_follow_reconciled_current_state
test_open_decision_survives_later_unrelated_event
test_secondmate_open_decision_survives_live_endpoint
test_open_decision_transfers_to_captain_hold
test_open_decision_clears_on_keyed_resolution
test_completed_scout_report_is_pointer_not_pending
test_parked_scout_decision_stays_pending
test_unavailable_run_preserves_open_ship_decision
test_scout_reports_include_teardown_reports
test_backlog_tasks_axi_forms_and_overrides
test_view_renders_snapshot
test_view_renders_dead_secondmate_agent_status
