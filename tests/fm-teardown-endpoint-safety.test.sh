#!/usr/bin/env bash
# Regression tests for cleanup endpoint and worktree-slot identity validation.
# fm_test_stream_task prints a task record identity one field per word,
# so its unquoted expansion in fm_write_meta argument lists is deliberate.
# shellcheck disable=SC2046
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-endpoint-safety)

make_case() {  # <name>
  local dir=$1
  mkdir -p "$TMP_ROOT/$dir/home/state" "$TMP_ROOT/$dir/home/data" \
    "$TMP_ROOT/$dir/home/config" "$TMP_ROOT/$dir/fakebin" \
    "$TMP_ROOT/$dir/worktree" "$TMP_ROOT/$dir/project"
  git init -q "$TMP_ROOT/$dir/project"
  : > "$TMP_ROOT/$dir/worktree/sentinel"
  : > "$TMP_ROOT/$dir/runtime.log"
  cat > "$TMP_ROOT/$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse' >> "${FM_RUNTIME_LOG:?}"
printf ' <%s>' "$@" >> "${FM_RUNTIME_LOG:?}"
printf '\n' >> "${FM_RUNTIME_LOG:?}"
exit 0
SH
  chmod +x "$TMP_ROOT/$dir/fakebin/treehouse"
  printf '%s\n' "$TMP_ROOT/$dir"
}

mark_case_as_treehouse_pool() {  # <case>
  local dir=$1
  rm -rf "$dir/worktree"
  mkdir -p "$dir/pool/1"
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid \
    commit --allow-empty -qm pool-fixture
  git -C "$dir/project" worktree add -q --detach "$dir/pool/1/project"
  ln -s "pool/1/project" "$dir/worktree"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' \
    "$dir/pool/1/project" > "$dir/pool/treehouse-state.json"
  : > "$dir/worktree/sentinel"
}

claim_pool_slot() {  # <case> <task-id> [home]
  local dir=$1 id=$2 home=${3:-$1/home}
  printf 'task=%s\nhome=%s\n' "$id" "$home" > "$dir/pool/1/.fm-slot-owner"
}

run_case() {  # <case> <id>
  local dir=$1 id=$2
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" --force
}

assert_refused_without_mutation() {  # <case> <id> <description>
  local dir=$1 id=$2 description=$3 rc
  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "$description: teardown unexpectedly succeeded"
  assert_present "$dir/home/state/$id.meta" "$description: metadata changed before refusal"
  assert_present "$dir/worktree/sentinel" "$description: worktree changed before refusal"
  [ ! -s "$dir/runtime.log" ] || fail "$description: runtime command ran before refusal: $(cat "$dir/runtime.log")"
}

test_invalid_endpoint_records_refuse_before_mutation() {
  local dir id=endpoint-a

  dir=$(make_case missing)
  fm_write_meta "$dir/home/state/$id.meta" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "missing endpoint"

  dir=$(make_case empty)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=" "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "empty endpoint"

  dir=$(make_case malformed)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=ambient-current-window" "worktree=$dir/worktree" \
    "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "malformed endpoint"

  dir=$(make_case mismatched)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-other-task" "endpoint_task_id=other-task" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "task-mismatched endpoint"

  dir=$(make_case empty-binding)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "empty task binding"

  dir=$(make_case duplicate-binding)
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=$id" "endpoint_task_id=$id" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  assert_refused_without_mutation "$dir" "$id" "duplicate task binding"

  pass "fm-teardown: missing, empty, malformed, ambiguous, and task-mismatched endpoints refuse before every mutation or runtime call"
}

test_control_lock_contention_refuses_before_mutation() {
  local dir id=locked-task lock holder i=0 rc
  dir=$(make_case control-lock)
  fm_write_meta "$dir/home/state/$id.meta" \
    $(fm_test_stream_task "$dir/home/state" "$id") \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  lock="$dir/home/state/.control-$id.lock"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not stage a held lifecycle lock"
  }
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=isolated:fm-$id" "endpoint_task_id=other-task" \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown unexpectedly succeeded under lifecycle lock contention"
  assert_present "$dir/home/state/$id.meta" "contended teardown removed task metadata"
  assert_present "$dir/worktree/sentinel" "contended teardown changed the worktree"
  assert_present "$lock" "contended teardown removed another action's lock"
  [ ! -s "$dir/runtime.log" ] \
    || fail "contended teardown reached the runtime: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "another lifecycle action is already running" \
    "contended teardown should serialize before reading mutable task metadata"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "fm-teardown: a concurrent lifecycle action refuses before mutation"
}

test_non_pool_teardown_ignores_task_set_lock() {
  local dir id=non-pool-task lock ready holder i=0
  dir=$(make_case non-pool-task-set-lock)
  fm_write_meta "$dir/home/state/$id.meta" \
    $(fm_test_stream_task "$dir/home/state" "$id") \
    "worktree=$dir/missing-worktree" "project=$dir/project" "kind=scout"
  lock="$dir/home/state/.task-set.lock"
  ready="$dir/task-set-lock-ready"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    trap 'fm_lock_release "$lock"' EXIT
    : > "$ready"
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$ready" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not stage an in-progress task publication"
  }

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "non-pool teardown was blocked by an unrelated task publication: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "non-pool teardown left task metadata"
  assert_present "$lock" "non-pool teardown removed the publisher's lock"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "fm-teardown: non-pool cleanup ignores unrelated task publication locks"
}

test_metadata_lock_serializes_destructive_cleanup() {
  local dir id=metadata-locked-task lock ready release holder teardown_pid i=0 rc
  dir=$(make_case metadata-lock)
  fm_write_meta "$dir/home/state/$id.meta" \
    $(fm_test_stream_task "$dir/home/state" "$id") \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  lock="$dir/home/state/.meta-$id.lock"
  ready="$dir/meta-lock-ready"
  release="$dir/meta-lock-release"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    trap 'fm_lock_release "$lock"' EXIT
    : > "$ready"
    while [ ! -e "$release" ]; do
      sleep 0.01
    done
  ) &
  holder=$!
  while [ ! -e "$ready" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$ready" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    fail "could not stage a held metadata lock"
  }

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" &
  teardown_pid=$!
  sleep 0.2
  if ! kill -0 "$teardown_pid" 2>/dev/null; then
    : > "$release"
    wait "$holder" 2>/dev/null || true
    wait "$teardown_pid" 2>/dev/null || true
    fail "teardown did not wait for the shared metadata writer lock"
  fi
  assert_present "$dir/home/state/$id.meta" "metadata-lock contention removed task metadata"
  assert_present "$dir/worktree/sentinel" "metadata-lock contention changed the worktree"
  [ ! -s "$dir/runtime.log" ] \
    || fail "metadata-lock contention reached the runtime: $(cat "$dir/runtime.log")"

  : > "$release"
  wait "$holder" || fail "metadata lock holder failed"
  wait "$teardown_pid"; rc=$?
  expect_code 0 "$rc" "teardown should complete after the metadata writer releases"
  assert_absent "$dir/home/state/$id.meta" \
    "serialized teardown left a task record that a completed writer could resurrect"
  pass "fm-teardown: destructive cleanup serializes with metadata writers"
}

test_supported_backend_endpoint_records_validate() {
  local dir id backend target
  dir=$(make_case valid-backends)
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"

  id=tmux-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$dir/worktree" "project=$dir/project"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid tmux endpoint refused"
  [ "$FM_BACKEND_VALIDATED_BACKEND:$FM_BACKEND_VALIDATED_TARGET" = "tmux:firstmate:fm-$id" ] || fail "tmux endpoint validation returned wrong identity"

  id=tmux-spaced-session
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=team work:fm-$id" "worktree=$dir/worktree" "project=$dir/project"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid tmux endpoint with a spaced session name refused"
  [ "$FM_BACKEND_VALIDATED_TARGET" = "team work:fm-$id" ] || fail "tmux validation changed the spaced session identity"

  id=herdr-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:w1:p2" "endpoint_task_id=$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=herdr" "herdr_session=lab" "herdr_workspace_id=w1" "herdr_tab_id=w1:t2" "herdr_pane_id=w1:p2"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" || fail "valid Herdr endpoint refused"

  id=zellij-task
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=lab:7" "endpoint_task_id=$id" "worktree=$dir/worktree" "project=$dir/project" \
    "backend=zellij" "zellij_session=lab" "zellij_tab_id=3" "zellij_pane_id=7"
  fm_backend_validate_task_endpoint "$dir/home/state/$id.meta" "$id" 2>/dev/null \
    && fail "a record on the removed zellij backend must refuse cleanup validation"

  for backend in tmux herdr stream; do
    set +e
    fm_backend_kill "$backend" "" >/dev/null 2>&1
    target=$?
    set -e
    [ "$target" -ne 0 ] || fail "$backend generic kill accepted an empty target"
  done
  pass "cleanup identity: valid tmux and Herdr records validate, a removed backend refuses, and every empty backend target refuses"
}

test_recorded_process_identity_cleanup_is_exact() {
  local dir target_pid control_pid target_record control_record live_command
  dir=$(make_case recorded-process)
  sleep 30 &
  control_pid=$!
  sleep 30 &
  target_pid=$!
  printf '%s\n' "$control_pid" > "$dir/control.pid"
  printf '%s\n' "$target_pid" > "$dir/target.pid"
  target_record=$(cat "$dir/target.pid")
  control_record=$(cat "$dir/control.pid")
  [ "$target_record" = "$target_pid" ] && [ "$control_record" = "$control_pid" ] \
    || fail "recorded process identity changed before cleanup"
  live_command=$(ps -p "$target_record" -o comm= 2>/dev/null | tr -d '[:space:]')
  case "$live_command" in sleep) ;; *) fail "recorded target pid no longer belongs to the expected child" ;; esac
  kill -TERM "$target_record"
  wait "$target_record" 2>/dev/null || true
  kill -0 "$target_record" 2>/dev/null && fail "exact target pid survived cleanup"
  kill -0 "$control_record" 2>/dev/null || fail "independent control process was disturbed"
  kill -TERM "$control_record"
  wait "$control_record" 2>/dev/null || true
  pass "process cleanup: creation-time PID identity removes only the exact child and preserves the control child"
}

# A close a backend accepts and does not perform is a real, documented shape,
# not a hypothetical: the former cmux adapter's `close-workspace` answered OK
# and left the last workspace in its window standing. The fake stream hub
# reproduces exactly that class with kill_undelivered - the hub answers the
# kill, its agent never acknowledges it, and its worker stays live while the hub
# closes only the endpoint record - so the assertions below are about what
# cleanup does with a worker that is provably still there. That positive answer
# is the kill contract's still-present verdict, so the refusal names it rather
# than the unconfirmed one, and names the override that answers it.
test_unconfirmed_endpoint_kill_refuses_record_removal() {
  local dir id=unconfirmed target rc
  dir=$(make_case unconfirmed-kill)
  fm_write_meta "$dir/home/state/$id.meta" \
    $(fm_test_stream_task "$dir/home/state" "$id") \
    "worktree=$dir/nonexistent-worktree" "project=$dir/nonexistent-project" \
    "kind=scout" "mode=no-mistakes"
  target=$(fm_test_stream_target_of "$dir/home/state" "$id")
  fm_test_fake_stream_set "$target" '{"kill_undelivered": true}'

  set +e
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" --force > "$dir/unconfirmed.out" 2> "$dir/unconfirmed.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "cleanup reported success for a kill nothing proved landed"
  endpoint_closed "$target" \
    || fail "the fake hub did not reproduce the real hub's close after an undelivered kill"
  [ "$(fm_test_fake_stream_endpoints | jq -r --arg e "${target##*:}" \
    '.endpoints[] | select(.endpoint_id == $e) | .closed_by // empty')" = hub ] \
    || fail "the fake hub did not record its own close after an undelivered kill"
  assert_present "$dir/home/state/$id.meta" \
    "cleanup removed the durable endpoint record while its worker was still running"
  assert_contains "$(cat "$dir/unconfirmed.err")" "still present after its kill" \
    "cleanup did not report the still-present answer: $(cat "$dir/unconfirmed.err")"
  assert_contains "$(cat "$dir/unconfirmed.err")" "override-runtime-refusal" \
    "cleanup did not name the override that answers a still-present endpoint: $(cat "$dir/unconfirmed.err")"

  # The endpoint's later authoritative close supersedes the hub's close, after
  # which the same cleanup can remove the record.
  fm_test_fake_stream_set "$target" '{"kill_undelivered": false, "closed_by": "agent", "alive": false}'
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" --force > "$dir/confirmed.out" 2> "$dir/confirmed.err" \
    || fail "cleanup failed after a kill the backend confirmed: $(cat "$dir/confirmed.err")"
  endpoint_closed "$target" || fail "the confirmed case did not actually close the endpoint"
  assert_absent "$dir/home/state/$id.meta" \
    "cleanup kept the durable endpoint record after a confirmed kill"
  pass "fm-teardown: a still-present endpoint keeps every durable record, while a confirmed kill stays successful"
}

# A retirement asserts what no backend could, but the backend answering
# POSITIVELY that the endpoint is still there is a runtime's own refusal, and
# a plain retirement must not remove a record the backend says is alive: only
# the override field clears it. This stages the retirement note exactly as
# bin/fm-retire-endpoint.sh writes it, so the gate is exercised through the
# same record cleanup reads, without driving the interactive command here.
test_a_plain_retirement_stops_on_a_still_present_endpoint() {
  local dir id=retire-present target rc
  dir=$(make_case retire-present)
  fm_write_meta "$dir/home/state/$id.meta" \
    $(fm_test_stream_task "$dir/home/state" "$id") \
    "worktree=$dir/nonexistent-worktree" "project=$dir/nonexistent-project" \
    "kind=scout" "mode=no-mistakes" "spawn_gen=spawn-retire-present"
  target=$(fm_test_stream_target_of "$dir/home/state" "$id")
  fm_test_fake_stream_set "$target" '{"kill_undelivered": true}'
  printf 'id=%s\nspawn_gen=spawn-retire-present\nretired_by=op\nretired_at=2026-01-01T00:00:00Z\nruntime_refusal_override=0\n' \
    "$id" > "$dir/home/state/$id.endpoint-retired"

  set +e
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" --force > "$dir/retire.out" 2> "$dir/retire.err"
  rc=$?
  set -e
  [ "$rc" -eq 71 ] \
    || fail "a plain retirement over a still-present endpoint must exit with the runtime-refusal status, got $rc: $(cat "$dir/retire.err")"
  assert_present "$dir/home/state/$id.meta" \
    "a plain retirement removed a record the backend says is alive"
  assert_contains "$(cat "$dir/retire.err")" "did not override a runtime refusal" \
    "the refusal did not say the retirement lacked the override: $(cat "$dir/retire.err")"
  [ "$(fm_test_fake_stream_endpoints | jq -r --arg e "${target##*:}" \
    '.endpoints[] | select(.endpoint_id == $e) | .closed_by // empty')" = hub ] \
    || fail "the undelivered kill did not leave the fake hub's record closed by the hub"

  # Retrying a plain retirement sees that durable hub-close verdict before it
  # can issue another DELETE, so the same override remains mandatory.
  printf 'id=%s\nspawn_gen=spawn-retire-present\nretired_by=op\nretired_at=2026-01-01T00:00:00Z\nruntime_refusal_override=0\n' \
    "$id" > "$dir/home/state/$id.endpoint-retired"
  set +e
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" --force > "$dir/retry.out" 2> "$dir/retry.err"
  rc=$?
  set -e
  [ "$rc" -eq 71 ] \
    || fail "a retried plain retirement must preserve the runtime-refusal status, got $rc: $(cat "$dir/retry.err")"
  assert_present "$dir/home/state/$id.meta" \
    "a retried plain retirement removed the hub-closed endpoint record"

  # The same retirement with the override field set proceeds past it.
  printf 'id=%s\nspawn_gen=spawn-retire-present\nretired_by=op\nretired_at=2026-01-01T00:00:00Z\nruntime_refusal_override=1\n' \
    "$id" > "$dir/home/state/$id.endpoint-retired"
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" --force > "$dir/override.out" 2> "$dir/override.err" \
    || fail "a retirement with the override should proceed past a still-present endpoint: $(cat "$dir/override.err")"
  assert_absent "$dir/home/state/$id.meta" \
    "an overriding retirement left the record it retired"
  assert_contains "$(cat "$dir/override.err")" "overrode that runtime's refusal" \
    "the overriding retirement did not name the override it rested on: $(cat "$dir/override.err")"
  pass "fm-teardown: a plain retirement stops on a still-present endpoint and only the override proceeds"
}

# endpoint_closed <target>: whether the fake hub holds the endpoint as closed.
endpoint_closed() {  # <target>
  [ -n "$(fm_test_fake_stream_endpoints | jq -r --arg e "${1##*:}" \
    '.endpoints[] | select(.endpoint_id == $e) | .closed_at // empty')" ]
}

test_exact_endpoint_cleanup_spares_its_neighbors() {
  local dir target_id=target control=control target control_target rc
  dir=$(make_case exact-endpoint)
  fm_test_stream_task "$dir/control-home" "$control" >/dev/null || fail "could not register the control endpoint"
  control_target=$(fm_test_stream_target_of "$dir/control-home" "$control")

  fm_write_meta "$dir/home/state/invalid.meta" \
    "window=" "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  set +e
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" invalid --force \
    > "$dir/invalid.out" 2> "$dir/invalid.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an invalid endpoint record unexpectedly tore down"
  [ ! -s "$dir/runtime.log" ] || fail "an invalid endpoint record reached a runtime command"
  endpoint_closed "$control_target" && fail "invalid cleanup closed the control endpoint"

  fm_write_meta "$dir/home/state/$target_id.meta" \
    $(fm_test_stream_task "$dir/home/state" "$target_id") \
    "worktree=$dir/nonexistent-worktree" "project=$dir/nonexistent-project" \
    "kind=scout" "mode=no-mistakes"
  target=$(fm_test_stream_target_of "$dir/home/state" "$target_id")
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_RUNTIME_LOG="$dir/runtime.log" \
    PATH="$dir/fakebin:$PATH" "$TEARDOWN" "$target_id" --force \
    > "$dir/valid.out" 2> "$dir/valid.err" \
    || fail "a valid endpoint teardown failed: $(cat "$dir/valid.err")"
  endpoint_closed "$target" || fail "valid cleanup did not close the exact target endpoint"
  endpoint_closed "$control_target" && fail "valid cleanup closed the independent control endpoint"
  pass "fm-teardown: exact endpoint cleanup refuses an invalid record and closes only the recorded target"
}

test_bare_relative_origin_shares_project_lock_with_clone() {
  local dir second_project primary_lock clone_lock
  dir=$(make_case bare-relative-origin-lock)
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid \
    commit --allow-empty -qm lock-fixture
  mkdir -p "$dir/project/remotes"
  git clone -q --bare "$dir/project" "$dir/project/remotes/origin.git"
  git -C "$dir/project" remote add origin remotes/origin.git
  second_project="$dir/second-project"
  git clone -q "$dir/project/remotes/origin.git" "$second_project"

  primary_lock=$(FM_HOME="$dir/home" bash -c \
    '. "$1"; fm_treehouse_project_lock_path "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$dir/project") \
    || fail "could not resolve the primary project's bare-origin lock"
  clone_lock=$(FM_HOME="$dir/home" bash -c \
    '. "$1"; fm_treehouse_project_lock_path "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$second_project") \
    || fail "could not resolve the clone project's absolute-origin lock"
  [ "$primary_lock" = "$clone_lock" ] \
    || fail "bare and absolute forms of the same local origin resolved different project locks"

  pass "Treehouse locking resolves a bare local origin against its source project, matching the provisioned clone"
}

test_reused_pool_slot_refuses_before_touching_the_other_task() {
  local dir id=stale-task other=live-task worker rc

  dir=$(make_case slot-reuse)
  mark_case_as_treehouse_pool "$dir"
  # The reuse collision: the pool slot recorded for a finished task has already
  # been handed to another task, whose worker is live in it right now.
  fm_write_meta "$dir/home/state/$id.meta" \
    $(fm_test_stream_task "$dir/home/state" "$id") \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  fm_write_meta "$dir/home/state/$other.meta" \
    $(fm_test_stream_task "$dir/home/state" "$other") \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  # Staged in this shell, not a command substitution: a background child of a
  # $(...) subshell does not outlive it, and the point of this worker is to be
  # alive in the slot while teardown runs.
  ( cd "$dir/worktree" && exec sleep 30 ) &
  worker=$!

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  [ "$rc" -ne 0 ] || fail "teardown returned a pool slot a second task record still holds"
  kill -0 "$worker" 2>/dev/null || fail "teardown killed the worker holding the reused pool slot"
  assert_present "$dir/worktree/sentinel" "teardown reset a pool slot a second task record still holds"
  assert_present "$dir/home/state/$other.meta" "teardown removed the live task's record"
  assert_present "$dir/home/state/$id.meta" "teardown removed the stale task's record before refusing"
  [ ! -s "$dir/runtime.log" ] \
    || fail "teardown reached the runtime on a contested pool slot: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "$other" \
    "refusal should name the other task holding the slot"
  kill "$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true

  # The same collision recorded on a secondmate home field rather than a task
  # worktree is the same slot, and refuses the same way.
  dir=$(make_case slot-reuse-home)
  mark_case_as_treehouse_pool "$dir"
  fm_write_meta "$dir/home/state/$id.meta" \
    $(fm_test_stream_task "$dir/home/state" "$id") \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  fm_write_meta "$dir/home/state/$other.meta" \
    $(fm_test_stream_task "$dir/home/state" "$other") \
    "worktree=$dir/worktree" "home=$dir/worktree" \
    "project=$dir/project" "kind=secondmate"
  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown returned a pool slot a secondmate home record still holds"
  assert_present "$dir/worktree/sentinel" "teardown reset a pool slot a secondmate home record still holds"
  assert_present "$dir/home/state/$other.meta" "teardown removed the secondmate record"
  [ ! -s "$dir/runtime.log" ] \
    || fail "teardown reached the runtime on a slot held by a secondmate home: $(cat "$dir/runtime.log")"

  pass "fm-teardown: a pool slot named by a second task record is never returned, killed, or reset"
}

test_cross_home_pool_slot_collision_refuses() {
  local dir id=stale-task other=secondmate-task second_home second_project rc
  dir=$(make_case slot-reuse-cross-home)
  mark_case_as_treehouse_pool "$dir"
  printf 'fixture\n' > "$dir/project/tracked"
  git -C "$dir/project" add tracked
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
  second_home="$dir/secondmate-home"
  second_project="$second_home/projects/project"
  mkdir -p "$second_home/projects" "$second_home/state" "$second_home/data"
  git clone -q "$dir/project" "$second_project"
  printf '%s\n' "- mate - fixture (home: $second_home; scope: test; projects: project; added 2026-01-01)" \
    > "$dir/home/data/secondmates.md"
  fm_write_meta "$dir/home/state/$id.meta" \
    $(fm_test_stream_task "$dir/home/state" "$id") \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  fm_write_meta "$second_home/state/$other.meta" \
    $(fm_test_stream_task "$second_home/state" "$other") \
    "worktree=$dir/worktree" "project=$second_project" "kind=scout"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown returned a pool slot held by another firstmate home"
  assert_present "$dir/home/state/$id.meta" "cross-home collision removed stale metadata"
  assert_present "$second_home/state/$other.meta" "cross-home collision removed live metadata"
  assert_present "$dir/worktree/sentinel" "cross-home collision reset the shared slot"
  [ ! -s "$dir/runtime.log" ] \
    || fail "cross-home collision reached the runtime: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "$other" \
    "cross-home refusal should name the task holding the slot"
  pass "fm-teardown: a pool slot held by another firstmate home is never returned"
}

test_sole_slot_record_still_tears_down() {
  local dir id=sole-task worker

  dir=$(make_case slot-sole)
  mark_case_as_treehouse_pool "$dir"
  fm_write_meta "$dir/home/state/$id.meta" \
    $(fm_test_stream_task "$dir/home/state" "$id") \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  # A neighbouring task on its OWN slot must not look like a collision.
  mkdir -p "$dir/other-worktree"
  fm_write_meta "$dir/home/state/neighbour.meta" \
    $(fm_test_stream_task "$dir/home/state" "neighbour") \
    "worktree=$dir/other-worktree" "project=$dir/project" "kind=scout"
  ( cd "$dir/other-worktree" && exec sleep 30 ) &
  worker=$!

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "teardown of a task that solely holds its slot failed: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "uncontested teardown left the task record"
  assert_present "$dir/home/state/neighbour.meta" "uncontested teardown removed the neighbour's record"
  kill -0 "$worker" 2>/dev/null || fail "uncontested teardown killed a worker in a different slot"
  grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "uncontested teardown did not return its own pool slot: $(cat "$dir/runtime.log")"
  kill "$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true
  pass "fm-teardown: a task that solely holds its slot still returns it"
}

test_recorded_endpoint_that_changed_directory_still_tears_down() {
  local dir id=moved-task

  dir=$(make_case slot-endpoint-moved)
  mark_case_as_treehouse_pool "$dir"
  mkdir -p "$dir/other-directory"
  # The exact recorded worker may legitimately cd outside its worktree. Its
  # endpoint identity still owns the lifecycle; cwd alone must not brick it.
  fm_write_meta "$dir/home/state/$id.meta" \
    $(fm_test_stream_task "$dir/home/state" "$id") \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  fm_test_fake_stream_set "$(fm_test_stream_target_of "$dir/home/state" "$id")" \
    "$(jq -nc --arg d "$dir/other-directory" '{cwd: $d}')"

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "teardown refused its recorded endpoint after it changed directory: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "moved-endpoint teardown left the task record"
  endpoint_closed "$(fm_test_stream_target_of "$dir/home/state" "$id")" \
    || fail "moved-endpoint teardown did not stop the exact recorded worker"
  grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "moved-endpoint teardown did not return its uncontested pool slot: $(cat "$dir/runtime.log")"

  pass "fm-teardown: an exact recorded endpoint still tears down after changing cwd outside its worktree"
}

# --- Treehouse project-lock anchoring across home layouts --------------------
#
# The lock is anchored at the local root home, so every home on this machine
# that can reach the same pool must derive the identical file. A remote parent
# binding terminates that walk at the home holding it: its parent is on another
# machine and can neither hold nor observe a lock taken here.

write_local_parent_record() {  # <home> <parent-home>
  cat > "$1/.fm-secondmate-parent" <<REC
schema=fm-secondmate-parent.v1
route=local
parent_home=$2
REC
}

write_remote_parent_record() {  # <home>
  cat > "$1/.fm-secondmate-parent" <<'REC'
schema=fm-secondmate-parent.v1
route=remote
parent_host=machine-a
REC
}

make_home() {  # <path>
  mkdir -p "$1/state" "$1/data" "$1/config" "$1/projects"
}

resolve_project_lock() {  # <home> <project>
  FM_HOME="$1" bash -c '. "$1"; fm_treehouse_project_lock_path "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$2"
}

test_project_lock_anchors_at_the_local_root_across_home_layouts() {
  local dir main_home main_project local_mate remote_mate remote_child
  local main_lock mate_lock remote_lock child_lock orphan_lock rc
  dir=$(make_case project-lock-anchoring)
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid \
    commit --allow-empty -qm anchor-fixture

  # Main-home layout: a root home and a local secondmate beneath it.
  main_home="$dir/home"
  main_project="$main_home/projects/project"
  make_home "$main_home"
  git clone -q "$dir/project" "$main_project"
  local_mate="$dir/local-mate"
  make_home "$local_mate"
  write_local_parent_record "$local_mate" "$main_home"
  git clone -q "$dir/project" "$local_mate/projects/project"

  # Remote layout: a home seeded from another machine, plus its own local child.
  remote_mate="$dir/remote-mate"
  make_home "$remote_mate"
  write_remote_parent_record "$remote_mate"
  git clone -q "$dir/project" "$remote_mate/projects/project"
  remote_child="$dir/remote-mate-child"
  make_home "$remote_child"
  write_local_parent_record "$remote_child" "$remote_mate"
  git clone -q "$dir/project" "$remote_child/projects/project"

  main_lock=$(resolve_project_lock "$main_home" "$main_project") \
    || fail "the root home could not resolve its project lock"
  mate_lock=$(resolve_project_lock "$local_mate" "$local_mate/projects/project") \
    || fail "a local secondmate home could not resolve its project lock"
  remote_lock=$(resolve_project_lock "$remote_mate" "$remote_mate/projects/project") \
    || fail "a remote-seeded secondmate home could not resolve its project lock"
  child_lock=$(resolve_project_lock "$remote_child" "$remote_child/projects/project") \
    || fail "a local child of a remote-seeded home could not resolve its project lock"

  [ "$main_lock" = "$mate_lock" ] \
    || fail "the root home and its local secondmate derived different project locks"
  [ "$remote_lock" = "$child_lock" ] \
    || fail "a remote-seeded home and its local child derived different project locks"
  case "$remote_lock" in
    "$remote_mate/state/"*) ;;
    *) fail "a remote-seeded home anchored its project lock outside its own state: $remote_lock" ;;
  esac

  # An origin-less local-only project still resolves, keyed on its worktree top.
  git init -q "$remote_mate/projects/local-only"
  orphan_lock=$(resolve_project_lock "$remote_mate" "$remote_mate/projects/local-only") \
    || fail "an origin-less local-only project could not resolve its lock in a remote-seeded home"
  [ "$orphan_lock" != "$remote_lock" ] \
    || fail "an origin-less project shared the lock identity of an unrelated origin"

  # Everything other than a remote route still fails closed.
  printf 'schema=fm-secondmate-parent.v1\nroute=sideways\n' \
    > "$remote_child/.fm-secondmate-parent"
  set +e
  resolve_project_lock "$remote_child" "$remote_child/projects/project" >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "an unsupported parent route resolved a project lock instead of refusing"

  pass "Treehouse project locking anchors at the local root for main-home, local-secondmate, and remote-seeded layouts"
}

test_remote_seeded_home_returns_its_uncontested_slot() {
  local dir id=remote-task rc
  dir=$(make_case remote-home-teardown)
  mark_case_as_treehouse_pool "$dir"
  write_remote_parent_record "$dir/home"
  fm_write_meta "$dir/home/state/$id.meta" \
    $(fm_test_stream_task "$dir/home/state" "$id") \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] \
    || fail "teardown in a remote-seeded home refused its own uncontested slot: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "remote-seeded teardown left the task record"
  grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "remote-seeded teardown did not return its own pool slot: $(cat "$dir/runtime.log")"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# remote-seeded Treehouse teardown command\n'
    printf '$ FM_HOME=%s bin/fm-teardown.sh %s --force\n' "$dir/home" "$id"
    printf 'stdout:\n'; cat "$dir/stdout"
    printf 'stderr:\n'; cat "$dir/stderr"
    printf 'exit=%s\nruntime calls:\n' "$rc"; cat "$dir/runtime.log"
    printf 'task metadata=%s\nslot sentinel=%s\n' \
      "$([ -e "$dir/home/state/$id.meta" ] && printf present || printf removed)" \
      "$([ -e "$dir/worktree/sentinel" ] && printf present || printf removed)"
  fi

  pass "fm-teardown: a remote-seeded secondmate home returns its own uncontested pool slot"
}

test_remote_seeded_home_still_refuses_a_slot_its_child_holds() {
  local dir id=remote-stale other=child-task child_home child_project rc
  dir=$(make_case remote-home-collision)
  mark_case_as_treehouse_pool "$dir"
  write_remote_parent_record "$dir/home"
  printf 'fixture\n' > "$dir/project/tracked"
  git -C "$dir/project" add tracked
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
  child_home="$dir/child-home"
  child_project="$child_home/projects/project"
  make_home "$child_home"
  write_local_parent_record "$child_home" "$dir/home"
  git clone -q "$dir/project" "$child_project"
  printf '%s\n' "- mate - fixture (home: $child_home; scope: test; projects: project; added 2026-01-01)" \
    > "$dir/home/data/secondmates.md"
  fm_write_meta "$dir/home/state/$id.meta" \
    $(fm_test_stream_task "$dir/home/state" "$id") \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  fm_write_meta "$child_home/state/$other.meta" \
    $(fm_test_stream_task "$child_home/state" "$other") \
    "worktree=$dir/worktree" "project=$child_project" "kind=scout"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] \
    || fail "a remote-seeded home returned a pool slot its own local child still holds"
  assert_present "$dir/home/state/$id.meta" "remote-layout collision removed stale metadata"
  assert_present "$child_home/state/$other.meta" "remote-layout collision removed live metadata"
  assert_present "$dir/worktree/sentinel" "remote-layout collision reset the shared slot"
  assert_contains "$(cat "$dir/stderr")" "$other" \
    "remote-layout refusal should name the task holding the slot"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# remote-seeded cross-home collision command\n'
    printf '$ FM_HOME=%s bin/fm-teardown.sh %s --force\n' "$dir/home" "$id"
    printf 'stderr:\n'; cat "$dir/stderr"
    printf 'exit=%s\nruntime calls=%s\n' "$rc" \
      "$([ -s "$dir/runtime.log" ] && cat "$dir/runtime.log" || printf none)"
    printf 'remote metadata=%s\nchild metadata=%s\nslot sentinel=%s\n' \
      "$([ -e "$dir/home/state/$id.meta" ] && printf preserved || printf removed)" \
      "$([ -e "$child_home/state/$other.meta" ] && printf preserved || printf removed)" \
      "$([ -e "$dir/worktree/sentinel" ] && printf preserved || printf removed)"
  fi

  pass "fm-teardown: slot ownership across a remote-seeded home and its local child still refuses"
}

test_remote_layout_homes_serialize_on_one_project_lock() {
  local dir id=remote-serialize child_home child_project lock holder rc waited=0
  dir=$(make_case remote-lock-exclusion)
  mark_case_as_treehouse_pool "$dir"
  write_remote_parent_record "$dir/home"
  printf 'fixture\n' > "$dir/project/tracked"
  git -C "$dir/project" add tracked
  git -C "$dir/project" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
  child_home="$dir/child-home"
  child_project="$child_home/projects/project"
  make_home "$child_home"
  write_local_parent_record "$child_home" "$dir/home"
  git clone -q "$dir/project" "$child_project"
  fm_write_meta "$dir/home/state/$id.meta" \
    $(fm_test_stream_task "$dir/home/state" "$id") \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"

  # The local child takes the lock its own home derives and stays alive holding
  # it, standing in for a slot allocation running in that home right now.
  lock=$(resolve_project_lock "$child_home" "$child_project") \
    || fail "the local child could not resolve the shared project lock"
  FM_HOME="$child_home" bash -c \
    '. "$1"; fm_lock_try_acquire "$2" || exit 1; : > "$3"; exec sleep 30' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$lock" "$dir/lock-held" &
  holder=$!
  while [ ! -e "$dir/lock-held" ] && [ "$waited" -lt 100 ]; do
    kill -0 "$holder" 2>/dev/null || break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -e "$dir/lock-held" ] || fail "the local child never took the shared project lock"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  [ "$rc" -ne 0 ] \
    || fail "a remote-seeded home returned a pool slot while its local child held the shared lock"
  assert_present "$dir/home/state/$id.meta" "contended remote-layout teardown removed the task record"
  assert_present "$dir/worktree/sentinel" "contended remote-layout teardown reset the slot"
  [ ! -s "$dir/runtime.log" ] \
    || fail "contended remote-layout teardown reached the runtime: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "another Treehouse slot allocation or return is in progress" \
    "the refusal should name the shared project lock, not some unrelated check"

  pass "Treehouse project locking still serializes two homes across the remote-seeded boundary"
}

# The slot-reuse sequence with only ONE discoverable record: the finished task's
# worker exited, its slot was granted to another task, and that task leaves no
# record this home can enumerate. Nothing in the record scan contradicts the
# stale worktree= line, so the slot's own owner claim is the only evidence that
# it was reassigned. The slot is no longer this task's, so teardown finishes the
# task's own cleanup and leaves the slot - its worker, its copy, its claim -
# exactly as it found it.
assert_reassigned_slot_left_alone() {  # <case> <id> <other> <description>
  local dir=$1 id=$2 other=$3 description=$4
  assert_absent "$dir/home/state/$id.meta" "$description: the stale task's own record was not removed"
  assert_present "$dir/pool/1/.fm-slot-owner" "$description: another task's slot claim was removed"
  assert_contains "$(cat "$dir/pool/1/.fm-slot-owner")" "task=$other" \
    "$description: another task's slot claim was rewritten"
  assert_present "$dir/pool/1/project/.git" "$description: the reassigned slot's checkout was removed"
  ! grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "$description: the reassigned slot was returned to the pool: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "$other" \
    "$description: the warning should name the task the slot was reassigned to"
  assert_contains "$(cat "$dir/stderr")" "reassigned" \
    "$description: the warning should name the reassignment as the cause"
}

test_reassigned_pool_slot_finishes_own_cleanup_without_touching_the_slot() {
  local dir id=stale-task other=reassigned-task worker rc

  # Dirty slot, --force, and a live worker inside it: --force authorizes
  # discarding this task's unlanded work, which is already gone with the slot,
  # never the other task's live work.
  dir=$(make_case slot-reassigned)
  mark_case_as_treehouse_pool "$dir"
  fm_write_meta "$dir/home/state/$id.meta" \
    $(fm_test_stream_task "$dir/home/state" "$id") \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  claim_pool_slot "$dir" "$other" "$dir/other-home"
  # Staged in this shell, not a command substitution: a background child of a
  # $(...) subshell does not outlive it, and the point of this worker is to be
  # alive in the slot while teardown runs.
  ( cd "$dir/worktree" && exec sleep 30 ) &
  worker=$!

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "teardown of a task whose slot was reassigned failed: $(cat "$dir/stderr")"
  kill -0 "$worker" 2>/dev/null || fail "teardown killed the worker holding the reassigned pool slot"
  assert_present "$dir/worktree/sentinel" "teardown reset a pool slot another task had claimed"
  assert_reassigned_slot_left_alone "$dir" "$id" "$other" "dirty reassigned slot with --force"
  assert_contains "$(cat "$dir/stderr")" "$dir/other-home" \
    "the warning should name the claimant's home"
  kill "$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true

  # The same reassignment on a CLEAN slot: a landed ship task torn down without
  # --force, which is the shape of the real incident. A clean, fully landed copy
  # passes every unlanded-work check, so only the ownership determination can
  # keep this slot out of the pool; a guard keyed off dirtiness would return it
  # and destroy the live task's copy.
  dir=$(make_case slot-reassigned-clean)
  mark_case_as_treehouse_pool "$dir"
  rm -f "$dir/worktree/sentinel"
  [ -z "$(git -C "$dir/worktree" status --porcelain)" ] \
    || fail "clean-slot fixture is not clean: $(git -C "$dir/worktree" status --porcelain)"
  fm_write_meta "$dir/home/state/$id.meta" \
    $(fm_test_stream_task "$dir/home/state" "$id") \
    "worktree=$dir/worktree" "project=$dir/project" "kind=ship"
  claim_pool_slot "$dir" "$other" "$dir/other-home"
  ( cd "$dir/worktree" && exec sleep 30 ) &
  worker=$!

  set +e
  FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
  FM_RUNTIME_LOG="$dir/runtime.log" PATH="$dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "teardown of a clean ship task whose slot was reassigned failed: $(cat "$dir/stderr")"
  kill -0 "$worker" 2>/dev/null || fail "teardown killed the worker holding the clean reassigned pool slot"
  assert_reassigned_slot_left_alone "$dir" "$id" "$other" "clean reassigned slot without --force"
  kill "$worker" 2>/dev/null || true
  wait "$worker" 2>/dev/null || true

  # A claim that exists but cannot be read as a claim proves nothing either way,
  # so it refuses rather than guessing the slot is still this task's.
  dir=$(make_case slot-claim-unreadable)
  mark_case_as_treehouse_pool "$dir"
  fm_write_meta "$dir/home/state/$id.meta" \
    $(fm_test_stream_task "$dir/home/state" "$id") \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  printf 'not-a-claim\n' > "$dir/pool/1/.fm-slot-owner"

  set +e
  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "teardown returned a pool slot whose claim could not be read"
  assert_present "$dir/worktree/sentinel" "teardown reset a pool slot whose claim could not be read"
  assert_present "$dir/pool/1/.fm-slot-owner" "teardown removed an unreadable slot claim"
  assert_present "$dir/home/state/$id.meta" "teardown removed the task record on an unreadable claim"
  [ ! -s "$dir/runtime.log" ] \
    || fail "teardown reached the runtime on an unreadable slot claim: $(cat "$dir/runtime.log")"
  assert_contains "$(cat "$dir/stderr")" "$dir/pool/1/.fm-slot-owner" \
    "unreadable-claim refusal should name the claim file to inspect"

  pass "fm-teardown: a pool slot claimed by another task is left alone while the task's own cleanup finishes"
}

# The two states that must never become a false refusal: the task's own claim,
# and no claim at all (a slot taken before claims existed, or already returned).
test_own_and_absent_slot_claims_still_tear_down() {
  local dir id=owned-task

  dir=$(make_case slot-claim-own)
  mark_case_as_treehouse_pool "$dir"
  fm_write_meta "$dir/home/state/$id.meta" \
    $(fm_test_stream_task "$dir/home/state" "$id") \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"
  claim_pool_slot "$dir" "$id"

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "teardown of a task holding its own slot claim failed: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "own-claim teardown left the task record"
  assert_absent "$dir/pool/1/.fm-slot-owner" "own-claim teardown left its spent slot claim behind"
  grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "own-claim teardown did not return its own pool slot: $(cat "$dir/runtime.log")"

  dir=$(make_case slot-claim-absent)
  mark_case_as_treehouse_pool "$dir"
  fm_write_meta "$dir/home/state/$id.meta" \
    $(fm_test_stream_task "$dir/home/state" "$id") \
    "worktree=$dir/worktree" "project=$dir/project" "kind=scout"

  run_case "$dir" "$id" > "$dir/stdout" 2> "$dir/stderr" \
    || fail "teardown of an unclaimed slot failed: $(cat "$dir/stderr")"
  assert_absent "$dir/home/state/$id.meta" "unclaimed-slot teardown left the task record"
  grep -Fq "treehouse <return>" "$dir/runtime.log" \
    || fail "unclaimed-slot teardown did not return its pool slot: $(cat "$dir/runtime.log")"

  pass "fm-teardown: a task's own slot claim, and an unclaimed slot, both still tear down"
}

test_invalid_endpoint_records_refuse_before_mutation
test_control_lock_contention_refuses_before_mutation
test_non_pool_teardown_ignores_task_set_lock
test_metadata_lock_serializes_destructive_cleanup
test_supported_backend_endpoint_records_validate
test_recorded_process_identity_cleanup_is_exact
test_exact_endpoint_cleanup_spares_its_neighbors
test_unconfirmed_endpoint_kill_refuses_record_removal
test_a_plain_retirement_stops_on_a_still_present_endpoint
test_bare_relative_origin_shares_project_lock_with_clone
test_reused_pool_slot_refuses_before_touching_the_other_task
test_cross_home_pool_slot_collision_refuses
test_sole_slot_record_still_tears_down
test_reassigned_pool_slot_finishes_own_cleanup_without_touching_the_slot
test_own_and_absent_slot_claims_still_tear_down
test_recorded_endpoint_that_changed_directory_still_tears_down
test_project_lock_anchors_at_the_local_root_across_home_layouts
test_remote_seeded_home_returns_its_uncontested_slot
test_remote_seeded_home_still_refuses_a_slot_its_child_holds
test_remote_layout_homes_serialize_on_one_project_lock
