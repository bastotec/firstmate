#!/usr/bin/env bash
# tests/fm-backend.test.sh - bin/fm-backend.sh, the runtime-backend dispatcher.
# stream is the only backend; tmux and herdr are retired. This suite covers:
#
#   1. Selection: FM_BACKEND env, then config/backend, then stream; a retired or
#      unknown name is refused loudly, never silently replaced.
#   2. Records: fm_meta_get, fm_backend_of_meta (an absent backend= field is a
#      pre-stream tmux record), and selector resolution through task metadata.
#   3. Retired records: every dispatcher answers "cannot drive" for a tmux or
#      herdr record (kill unconfirmed, agent state unverified, no target)
#      without touching a backend.
#   4. fm-spawn.sh: backend refusals, and a default spawn onto the fake stream
#      hub (tests/fixtures.sh) that records the hub-assigned endpoint.
#
# The stream adapter itself (bin/backends/stream.sh) is covered against a real
# hub and agent by tests/fm-backend-stream.test.sh.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_git_identity fmtest fmtest@example.invalid

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-tests)
# Spawns run against a throwaway HOME so nothing a launch writes under the
# user's home can reach the developer's real one.
SPAWN_HOME="$TMP_ROOT/user-home"
mkdir -p "$SPAWN_HOME"
# Spawns rooted at this checkout also run under a throwaway firstmate home: a
# ship spawn takes the shared Treehouse project lock in the root home's state
# directory, which must be this suite's own rather than the checkout's.
SPAWN_FM_HOME="$TMP_ROOT/fm-home"
mkdir -p "$SPAWN_FM_HOME/state"

write_spawn_brief() {  # <file> <id>
  cat > "$1" <<EOF
# Task
## Captain's intent
Exercise backend dispatch for $2.

## Firstmate spec
Verify backend selection without changing task intent.
EOF
}

make_spawn_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  fm_fake_exit0 "$fb" treehouse deck
  printf '%s\n' "$fb"
}

# --- fm-backend.sh unit tests ------------------------------------------------

# fm_backend_name reads FM_BACKEND_CONFIG_DIR (bound once, at fm-backend.sh
# source time, from FM_CONFIG_OVERRIDE); a later FM_CONFIG_OVERRIDE=... prefix
# on the function call itself does not re-bind it, so these calls set
# FM_BACKEND_CONFIG_DIR directly.
test_backend_name_precedence() {
  local cfg=$TMP_ROOT/name-precedence/config
  mkdir -p "$cfg"
  [ "$(FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name)" = stream ] \
    || fail "fm_backend_name should default to stream with no env or config"
  # Old runtime markers select nothing any more.
  [ "$(TMUX='fake,1,0' HERDR_ENV=1 FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name)" = stream ] \
    || fail "a tmux or herdr runtime marker must not select a backend"
  printf '\n  stream  \n' > "$cfg/backend"
  [ "$(FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name)" = stream ] \
    || fail "fm_backend_name should read the first non-empty word of config/backend"
  printf 'tmux\n' > "$cfg/backend"
  [ "$(FM_BACKEND='' FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name)" = tmux ] \
    || fail "fm_backend_name should report a leftover config/backend for the caller to refuse"
  [ "$(FM_BACKEND=stream FM_BACKEND_CONFIG_DIR="$cfg" fm_backend_name)" = stream ] \
    || fail "FM_BACKEND env should win over config/backend"
  pass "fm_backend_name: FM_BACKEND env > config/backend > default stream; runtime markers select nothing"
}

test_backend_validate_refuses_retired_and_unknown() {
  local out name
  fm_backend_validate stream 2>/dev/null || fail "fm_backend_validate should accept stream"
  fm_backend_validate_spawn stream 2>/dev/null || fail "fm_backend_validate_spawn should accept stream"
  for name in tmux herdr; do
    fm_backend_is_retired "$name" || fail "$name should be a retired backend"
    out=$(fm_backend_validate "$name" 2>&1) && fail "fm_backend_validate should refuse retired $name"
    assert_contains "$out" "the '$name' backend was removed; stream is the only backend" \
      "fm_backend_validate did not explain the retired $name backend"
    out=$(fm_backend_validate_spawn "$name" 2>&1) && fail "fm_backend_validate_spawn should refuse retired $name"
  done
  fm_backend_is_retired stream && fail "stream must not read as retired"
  for name in zellij orca cmux bogus codex-app 'stream tmux'; do
    out=$(fm_backend_validate "$name" 2>&1) && fail "fm_backend_validate should refuse '$name'"
    assert_contains "$out" "unknown backend '$name'" "fm_backend_validate did not name rejected backend '$name'"
  done
  pass "fm_backend_validate: stream accepted, retired tmux/herdr and unknown names refused loudly"
}

test_backend_source_shell_portable() {
  local out
  # zsh does not word-split unquoted expansions; sourcing fm-backend.sh from
  # an interactive zsh session must still recognize the backend name.
  if command -v zsh >/dev/null 2>&1; then
    zsh -c "cd '$ROOT' && source bin/fm-backend.sh && fm_backend_source stream && whence -w fm_backend_stream_capture >/dev/null" 2>/dev/null \
      || fail "zsh: fm_backend_source stream should load the adapter when sourced"
    out=$(zsh -c "cd '$ROOT' && source bin/fm-backend.sh && fm_backend_source bogus" 2>&1) \
      && fail "zsh: fm_backend_source bogus should fail"
    assert_contains "$out" "unknown backend 'bogus'" "zsh: fm_backend_source did not reject bogus"
  fi
  bash -c "cd '$ROOT' && source bin/fm-backend.sh && fm_backend_source stream && declare -F fm_backend_stream_capture >/dev/null" 2>/dev/null \
    || fail "bash: fm_backend_source stream should load the adapter when sourced"
  out=$(bash -c "cd '$ROOT' && source bin/fm-backend.sh && fm_backend_source herdr" 2>&1) \
    && fail "bash: fm_backend_source herdr should fail"
  assert_contains "$out" "the 'herdr' backend was removed" "bash: fm_backend_source did not refuse the retired herdr adapter"
  pass "fm_backend_source loads the stream adapter from bash and zsh and refuses unknown or retired names"
}

test_meta_get_and_backend_of_meta() {
  local meta=$TMP_ROOT/meta-get.meta edge=$TMP_ROOT/meta-get-edge.meta
  fm_write_meta "$meta" "window=firstmate:fm-x1" "harness=deck"
  [ "$(fm_meta_get "$meta" window)" = "firstmate:fm-x1" ] || fail "fm_meta_get did not read window="
  [ "$(fm_meta_get "$meta" missing)" = "" ] || fail "fm_meta_get should print nothing for an absent key"
  [ "$(fm_backend_of_meta "$meta")" = tmux ] \
    || fail "a record with no backend= predates explicit fields and must read as the retired tmux backend"
  printf 'backend=stream\n' >> "$meta"
  [ "$(fm_backend_of_meta "$meta")" = stream ] || fail "fm_backend_of_meta should read backend=stream"
  printf 'token=first\ntoken=last=value' > "$edge"
  [ "$(fm_meta_get "$edge" token)" = "last=value" ] \
    || fail "fm_meta_get did not preserve last-value or no-final-newline semantics"
  pass "fm_meta_get / fm_backend_of_meta: last key=value wins; an absent backend= is a retired tmux record"
}

test_resolve_selector_forms() {
  local state=$TMP_ROOT/resolve-state out
  mkdir -p "$state"
  fm_write_meta "$state/task1.meta" "window=hub-a1b2:00000001" "backend=stream"
  fm_write_meta "$state/fm-exact-v9.meta" "window=hub-a1b2:00000002" "backend=stream"
  fm_write_meta "$state/old-tmux.meta" "window=firstmate:fm-old-tmux"

  [ "$(fm_backend_resolve_selector 'hub-zz:0000abcd' "$state")" = "hub-zz:0000abcd" ] \
    || fail "an explicit <hub-tag>:<endpoint-id> target should be used as-is"
  [ "$(fm_backend_resolve_selector 'task1' "$state")" = "hub-a1b2:00000001" ] \
    || fail "a task id should resolve through its metadata"
  [ "$(fm_backend_resolve_selector 'fm-exact-v9' "$state")" = "hub-a1b2:00000002" ] \
    || fail "an exact fm-* task id should resolve through its own metadata before legacy stripping"
  [ "$(fm_backend_expected_label_of_selector 'fm-exact-v9' "$state")" = "fm-fm-exact-v9" ] \
    || fail "an exact fm-* task id should report the spawned fm-<id> label"
  [ "$(fm_backend_resolve_selector 'fm-task1' "$state")" = "hub-a1b2:00000001" ] \
    || fail "a legacy fm-<id> label should resolve through <id>.meta"
  [ "$(fm_backend_expected_label_of_selector 'fm-task1' "$state")" = "fm-task1" ] \
    || fail "a legacy fm-<id> label should keep its label"

  out=$(fm_backend_resolve_selector 'fm-missing' "$state" 2>&1) && fail "fm-<id> with no meta should fail"
  assert_contains "$out" "no metadata for fm-missing" "missing-meta error text changed"
  out=$(fm_backend_resolve_selector 'adhoc' "$state" 2>&1) && fail "a bare name with no record should fail"
  assert_contains "$out" "no task or endpoint named adhoc" "a bare unknown name was not refused by name"
  pass "fm_backend_resolve_selector: literal target, exact task id, legacy fm-<id> label; unrecorded names refused"
}

test_backend_of_selector_reads_the_record() {
  local state=$TMP_ROOT/backend-selector-state
  mkdir -p "$state"
  fm_write_meta "$state/live.meta" "window=hub-a1b2:00000003" "backend=stream"
  fm_write_meta "$state/old-tmux.meta" "window=firstmate:fm-old-tmux"
  fm_write_meta "$state/old-herdr.meta" "window=default:w1:p2" "backend=herdr"

  [ "$(fm_backend_of_selector 'live' 'hub-a1b2:00000003' "$state")" = stream ] \
    || fail "a task id selector should use its recorded backend"
  [ "$(fm_backend_of_selector 'old-tmux' 'firstmate:fm-old-tmux' "$state")" = tmux ] \
    || fail "a pre-stream record should keep its retired tmux identity"
  [ "$(fm_backend_of_selector 'default:w1:p2' 'default:w1:p2' "$state")" = herdr ] \
    || fail "an explicit target matching a record should use that record's backend"
  [ "$(fm_backend_of_selector 'hub-zz:0000abcd' 'hub-zz:0000abcd' "$state")" = stream ] \
    || fail "an explicit target with no record should default to stream"
  pass "fm_backend_of_selector: recorded backends win (including retired ones); unrecorded targets are stream"
}

test_retired_records_are_never_driven() {
  local name out rc
  for name in tmux herdr; do
    out=$(fm_backend_kill "$name" 'firstmate:fm-old' 2>&1); rc=$?
    [ "$rc" -eq 2 ] || fail "killing a $name endpoint must be UNCONFIRMED (2), got $rc"
    assert_contains "$out" "retired '$name' backend" "the $name kill did not name the retired backend"
    [ "$(fm_backend_kill_verdict "$rc")" = unconfirmed ] || fail "kill verdict for a $name record should be unconfirmed"
    [ "$(fm_backend_agent_state "$name" 'firstmate:fm-old')" = unverified ] \
      || fail "a $name record's agent state must be unverified"
    [ "$(fm_backend_agent_alive "$name" 'firstmate:fm-old')" = unknown ] \
      || fail "a $name record's agent must read unknown, never dead"
    fm_backend_target_exists "$name" 'firstmate:fm-old' && fail "a $name record's target must not read as existing"
    [ "$(fm_backend_composer_state "$name" 'firstmate:fm-old')" = unknown ] \
      || fail "a $name record's composer must read unknown"
    fm_backend_agent_pids "$name" 'firstmate:fm-old' >/dev/null 2>&1 && fail "a $name record must not report agent pids"
    fm_backend_capture "$name" 'firstmate:fm-old' 5 >/dev/null 2>&1 && fail "a $name record must not be captured"
  done
  [ "$(fm_backend_busy_state stream 'hub-zz:0000abcd')" = unknown ] || fail "stream busy state should be unknown"
  pass "retired tmux/herdr records: kill unconfirmed, agent unverified, no target, no capture"
}

# The kill contract's fourth verdict: a backend that POSITIVELY answers that
# the endpoint is still there is a different fact from one that cannot answer,
# and cleanup's retirement gates treat them differently, so the verdict names
# must keep them apart. The empty-target refusal stays unsupported: it names no
# worker at all, so it is never a report that one is present.
test_kill_verdict_distinguishes_present_from_unconfirmed() {
  local out rc
  [ "$(fm_backend_kill_verdict 0)" = gone ] || fail "status 0 must read gone"
  [ "$(fm_backend_kill_verdict 3)" = present ] \
    || fail "status 3 is the still-present verdict and must read present"
  [ "$(fm_backend_kill_verdict 2)" = unconfirmed ] || fail "status 2 must read unconfirmed"
  [ "$(fm_backend_kill_verdict 1)" = unsupported ] || fail "status 1 must read unsupported"
  out=$(fm_backend_kill stream '' 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "an empty target must stay unsupported (1), got $rc"
  [ "$(fm_backend_kill_verdict "$rc")" = unsupported ] \
    || fail "an empty target must never read as a backend that answered"
  pass "fm_backend_kill_verdict: gone, present, unconfirmed, unsupported stay four distinct answers"
}

# --- fm-spawn.sh backend selection --------------------------------------------

test_spawn_refuses_unknown_backend_flag() {
  local out status
  # bogus names a backend with no adapter at all.
  out=$(FM_ROOT_OVERRIDE='' FM_HOME='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" nope-backend-z1 projects/none deck --mode no-mistakes --yolo off --backend bogus 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "fm-spawn --backend bogus should refuse"
  assert_contains "$out" "unknown backend 'bogus'" "fm-spawn did not name the rejected backend"
  pass "fm-spawn.sh --backend bogus is refused loudly"
}

test_spawn_refuses_codex_app_backend_flag() {
  local out status
  out=$(FM_ROOT_OVERRIDE='' FM_HOME='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" nope-codex-app-z1 projects/none deck --mode no-mistakes --yolo off --backend codex-app 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "fm-spawn --backend codex-app should refuse"
  assert_contains "$out" "unknown backend 'codex-app'" "fm-spawn did not preserve the blocked codex-app contract"
  pass "fm-spawn.sh --backend codex-app is refused"
}

test_spawn_refuses_unknown_fm_backend_env() {
  local out status
  out=$(FM_ROOT_OVERRIDE='' FM_HOME='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 FM_BACKEND=bogus \
    "$ROOT/bin/fm-spawn.sh" nope-backend-z2 projects/none deck --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "FM_BACKEND=bogus should refuse"
  assert_contains "$out" "unknown backend 'bogus'" "fm-spawn did not name the rejected FM_BACKEND"
  pass "fm-spawn.sh honors FM_BACKEND and refuses an unimplemented value loudly"
}

test_spawn_refuses_retired_backends() {
  local out status name
  for name in tmux herdr; do
    out=$(FM_ROOT_OVERRIDE='' FM_HOME='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 \
      "$ROOT/bin/fm-spawn.sh" nope-retired-z1 projects/none deck --mode no-mistakes --yolo off --backend "$name" 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "fm-spawn --backend $name should refuse"
    assert_contains "$out" "the '$name' backend was removed" "fm-spawn --backend $name did not explain the removal"
    out=$(FM_ROOT_OVERRIDE='' FM_HOME='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 FM_BACKEND="$name" \
      "$ROOT/bin/fm-spawn.sh" nope-retired-z2 projects/none deck --mode no-mistakes --yolo off 2>&1)
    status=$?
    [ "$status" -ne 0 ] || fail "FM_BACKEND=$name should refuse"
    assert_contains "$out" "the '$name' backend was removed" "FM_BACKEND=$name did not explain the removal"
  done
  pass "fm-spawn.sh refuses the retired tmux and herdr backends by flag or env, naming the removal"
}

# The default spawn lands on stream end to end through the real fm-spawn.sh, against the
# fake hub (tests/fixtures.sh fm_test_fake_stream): the record names the
# hub-assigned endpoint and its hub, the endpoint is labelled for the task, and
# the worktree treehouse hands the endpoint is the one recorded.
test_spawn_on_fake_stream_records_the_endpoint() (
  if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    pass "fm-spawn.sh on stream: skipped (jq/curl unavailable)"
    exit 0
  fi
  local proj wt data id state config out fb window endpoint
  proj="$TMP_ROOT/stream-project"; wt="$TMP_ROOT/stream-wt"; data="$TMP_ROOT/stream-data"
  id="streamdispatchz6"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  fb=$(make_spawn_fakebin "$TMP_ROOT/stream-fake")
  mkdir -p "$data/$id"; write_spawn_brief "$data/$id/brief.md" "$id"
  state="$TMP_ROOT/stream-state"; config="$TMP_ROOT/stream-config"
  mkdir -p "$state" "$config"
  fm_test_fake_stream "$TMP_ROOT/stream-hub" || fail "fake stream hub did not start"
  fm_test_fake_stream_treehouse "$wt"

  out=$(PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$SPAWN_FM_HOME" HOME="$SPAWN_HOME" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 FM_BACKEND='' \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" deck --mode no-mistakes --yolo off 2>&1)
  expect_code 0 $? "fm-spawn.sh with no backend selection should spawn onto the fake hub"$'\n'"$out"
  window=$(fm_meta_get "$state/$id.meta" window)
  endpoint=$(fm_meta_get "$state/$id.meta" stream_endpoint_id)
  assert_equals stream "$(fm_meta_get "$state/$id.meta" backend)" "the record should name the stream backend"
  assert_equals "$FM_TEST_STREAM_TAG:$endpoint" "$window" "window= should be <hub-tag>:<endpoint-id>"
  assert_equals "$FM_TEST_STREAM_URL" "$(fm_meta_get "$state/$id.meta" stream_hub)" "the record should name its hub"
  assert_equals "$wt" "$(fm_meta_get "$state/$id.meta" worktree)" "the worktree treehouse handed the endpoint should be recorded"
  assert_equals "fm-$id" "$(fm_test_fake_stream_endpoints | jq -r --arg e "$endpoint" '.endpoints[] | select(.endpoint_id == $e) | .label')" \
    "the endpoint should carry the task's label"
  fm_test_fake_stream_submitted "$window" | grep -q 'treehouse get' || fail "spawn never asked the endpoint for its worktree"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh defaults to stream and records the hub-assigned endpoint, its hub, and the treehouse worktree"
)

# A project reached through a symlinked prefix (macOS /tmp -> /private/tmp) must
# not trip the isolation guard: the endpoint reports PHYSICAL cwds, while
# fm-spawn.sh's PROJ_ABS is the logical path, so the worktree poll compares
# against PROJ_ABS_REAL.
test_spawn_symlinked_project_prefix_avoids_false_refusal() (
  if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    pass "fm-spawn.sh symlinked prefix: skipped (jq/curl unavailable)"
    exit 0
  fi
  local real_root link_root proj wt id fb data state config out
  real_root="$TMP_ROOT/symlink-real"; link_root="$TMP_ROOT/symlink-link"
  mkdir -p "$real_root"
  ln -s "$real_root" "$link_root"
  proj="$link_root/proj"; wt="$TMP_ROOT/symlink-wt"; id="spawnsymlinkz7"
  fm_git_worktree "$real_root/proj" "$wt" "fm/$id"
  fb=$(make_spawn_fakebin "$TMP_ROOT/symlink-fake")
  data="$TMP_ROOT/symlink-data"; mkdir -p "$data/$id"; write_spawn_brief "$data/$id/brief.md" "$id"
  state="$TMP_ROOT/symlink-state"; config="$TMP_ROOT/symlink-config"
  mkdir -p "$state" "$config"
  fm_test_fake_stream "$TMP_ROOT/symlink-hub" || fail "fake stream hub did not start"
  fm_test_fake_stream_treehouse "$wt"
  out=$(PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$SPAWN_FM_HOME" HOME="$SPAWN_HOME" \
    FM_STATE_OVERRIDE="$state" FM_DATA_OVERRIDE="$data" FM_CONFIG_OVERRIDE="$config" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/unused-projects" FM_SPAWN_NO_GUARD=1 FM_BACKEND='' \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" deck --mode no-mistakes --yolo off 2>&1)
  expect_code 0 $? "fm-spawn.sh should succeed for a project reached through a symlinked prefix"$'\n'"$out"
  assert_contains "$out" "worktree=$wt" "fm-spawn.sh did not resolve a symlinked-prefix project to its real worktree"
  rm -rf "/tmp/fm-$id"
  pass "fm-spawn.sh: a project reached through a symlinked prefix does not trip the isolation guard"
)

test_backend_name_precedence
test_backend_validate_refuses_retired_and_unknown
test_backend_source_shell_portable
test_meta_get_and_backend_of_meta
test_resolve_selector_forms
test_backend_of_selector_reads_the_record
test_kill_verdict_distinguishes_present_from_unconfirmed
test_retired_records_are_never_driven
test_spawn_refuses_unknown_backend_flag
test_spawn_refuses_codex_app_backend_flag
test_spawn_refuses_unknown_fm_backend_env
test_spawn_refuses_retired_backends
test_spawn_on_fake_stream_records_the_endpoint
test_spawn_symlinked_project_prefix_avoids_false_refusal
