#!/usr/bin/env bash
# Behavior tests for tests/lib.sh's shared fixture-tempdir helper
# (fm_test_tmproot / fm_test_cleanup / fm_test_reap_orphans).
#
# The near-universal call pattern across this suite is
# `TMP_ROOT=$(fm_test_tmproot prefix)`, which forks a subshell to capture the
# function's stdout. These tests spawn real, separate bash processes that use
# that exact pattern and assert the fixture root is actually gone once the
# owning process's guarded teardown has run - on a normal exit and on a
# terminating signal - plus that a stale marked fixture from a killed prior
# run gets reaped on the next source. Nothing here inspects tests/lib.sh's
# source text; it only observes filesystem state around the real helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/tests/lib.sh"

await_cleanup_pid_exit() {
  local pid=$1 waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 100 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  ! kill -0 "$pid" 2>/dev/null
}

test_status_worker_identity_is_checked_before_cleanup() {
  local harness owned pid started
  harness=$(fm_test_tmproot fm-test-worker-identity)
  owned="$harness/owned"
  mkdir -p "$owned/state"
  printf '#!/usr/bin/env bash\nsleep 120\n:\n' > "$harness/fm-startup-network.sh"
  bash "$harness/fm-startup-network.sh" >/dev/null 2>&1 &
  pid=$!
  fm_test_track_helper_pid "$pid"
  started=$(date +%s)
  printf 'pid=%s\nstarted=%s\n' "$pid" "$((started - 60))" > "$owned/state/.startup-network.status"
  fm_test_reap_startup_network_workers "$owned"
  kill -0 "$pid" 2>/dev/null || fail "cleanup signalled a worker whose process age did not match the record"
  printf 'pid=%s\nstarted=%s\n' "$pid" "$started" > "$owned/state/.startup-network.status"
  fm_test_reap_startup_network_workers "$owned"
  wait "$pid" 2>/dev/null || true
  await_cleanup_pid_exit "$pid" || fail "cleanup left the worker whose identity matched the record"
  pass "startup worker cleanup requires a matching process start time"
}

test_tree_cleanup_catches_a_child_forked_during_the_snapshot() {
  local dir root child real_ps late waited=0
  dir=$(fm_test_tmproot fm-test-tree-fork)
  real_ps=$FM_TEST_SYSTEM_PS
  cat > "$dir/worker.sh" <<'SH'
#!/usr/bin/env bash
bash -c '
  touch "$1/child-ready"
  while [ ! -f "$1/launch" ]; do sleep 0.01; done
  sleep 120 &
  printf "%s\n" $! > "$1/late-pid"
  wait
' _ "$1" &
printf '%s\n' $! > "$1/child-pid"
wait
SH
  bash "$dir/worker.sh" "$dir" >/dev/null 2>&1 &
  root=$!
  fm_test_track_helper_pid "$root"
  while [ ! -f "$dir/child-ready" ] && [ "$waited" -lt 100 ]; do
    sleep 0.05
    waited=$((waited + 1))
  done
  [ -f "$dir/child-ready" ] || fail "the fork probe never started its child"
  child=$(cat "$dir/child-pid")
  cat > "$dir/ps" <<SH
#!/usr/bin/env bash
if [ "\$*" = '-eo pid=,ppid=' ] && [ ! -f "$dir/launch" ]; then
  "$real_ps" "\$@" > "$dir/snapshot"
  touch "$dir/launch"
  waited=0
  while [ ! -s "$dir/late-pid" ] && [ "\$waited" -lt 100 ]; do
    sleep 0.01
    waited=\$((waited + 1))
  done
  cat "$dir/snapshot"
else
  exec "$real_ps" "\$@"
fi
SH
  chmod +x "$dir/ps"
  FM_TEST_SYSTEM_PS="$dir/ps"
  fm_test_kill_tree "$root"
  FM_TEST_SYSTEM_PS=$real_ps
  wait "$root" 2>/dev/null || true
  [ -s "$dir/late-pid" ] || fail "the snapshot probe did not exercise the fork race"
  late=$(cat "$dir/late-pid")
  fm_test_track_helper_pid "$child"
  fm_test_track_helper_pid "$late"
  if ! await_cleanup_pid_exit "$root" || ! await_cleanup_pid_exit "$child" || ! await_cleanup_pid_exit "$late"; then
    fail "tree cleanup missed a descendant forked during its snapshot"
  fi
  pass "tree cleanup freezes and rescans descendants before killing them"
}

test_path_reaper_signals_only_fixture_processes() {
  # The reaper finds leftovers by the fixture path in their command line, so it
  # must never select a process of its own: an awk handed the path as an
  # argument, or a reaper shell whose argv carries it. Signalling either one
  # can freeze or kill cleanup while it is still reading its own matches.
  local dir worker record extra
  dir=$(fm_test_tmproot fm-test-reaper-self)
  record="$dir/signalled"
  bash -c 'sleep 120; :' fixture-worker "$dir" >/dev/null 2>&1 &
  worker=$!
  fm_test_track_helper_pid "$worker"
  # The probe shell's own argv holds the path too, as an inherited argv can.
  bash -c '
    . "$1"
    probe_dir=$2
    fm_test_kill_tree() { printf "%s\n" "$1" >> "$probe_dir/signalled"; }
    for _ in 1 2 3 4 5 6 7 8; do fm_test_reap_startup_network_workers "$probe_dir"; done
  ' _ "$LIB" "$dir" || fail "the reaper probe did not run"
  fm_test_kill_tree "$worker"
  wait "$worker" 2>/dev/null || true
  grep -qx "$worker" "$record" 2>/dev/null ||
    fail "the reaper missed a live process carrying the fixture path (pid $worker)"
  extra=$(grep -vx "$worker" "$record" | sort -u | tr '\n' ' ')
  [ -z "$extra" ] || fail "the reaper selected its own processes for signalling: $extra"
  pass "the fixture-path reaper selects fixture processes and never its own"
}

test_helper_pids_registered_in_a_subshell_are_still_reaped() {
  # The whole point of the `$$`-keyed registry. Suites start their helpers from
  # inside a command substitution (`endpoint=$(start_agent box-a worker)`), and
  # a shell-variable append there dies with the subshell, so a suite that
  # tracked helper pids in a plain string tracked nothing and left every
  # process it started running. These helpers do not exit on their own.
  local dir marker pid waited=0
  dir=$(fm_test_tmproot fm-helper-pid)
  marker="$dir/pid"
  bash -c '
    set -u
    . "$1"
    # Register from inside a command substitution, exactly as the real suites do.
    started=$(sleep 120 >/dev/null 2>&1 & echo $!; fm_test_track_helper_pid "$!")
    printf "%s\n" "$started" > "$2"
    trap fm_test_cleanup EXIT
  ' _ "$LIB" "$marker" || fail "the helper-registration probe did not run"
  pid=$(cat "$marker" 2>/dev/null) || pid=
  case $pid in
    '' | *[!0-9]*) fail "the probe did not report a helper pid (got '$pid')" ;;
  esac
  while [ "$waited" -lt 50 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    fail "a helper registered from inside a command substitution outlived its suite (pid $pid), so every publisher a run starts would leak"
  fi
  pass "helpers registered from a command substitution are reaped with the suite"
}

test_a_stub_hub_stops_once_its_killed_suite_is_gone() {
  # SIGKILL - what an agent's command timeout sends - runs no trap, so the
  # helper registry is never read. The stub hub has to notice on its own that
  # the suite that started it is gone, or it keeps listening indefinitely.
  local harness pidfile pid stub tries
  command -v python3 >/dev/null 2>&1 || {
    pass "a stub hub stops once its killed suite is gone (skipped: python3 not found)"
    return 0
  }
  harness=$(fm_test_tmproot fm-test-cleanup-stub-owner)
  pidfile="$harness/stub-pid"
  bash -c '
    . "$1/tests/fixtures.sh"
    fm_test_fake_stream "$2/hub" || exit 1
    cat "$FM_TEST_HELPER_PID_REGISTRY" > "$3"
    while :; do sleep 0.1; done
  ' _ "$ROOT" "$harness" "$pidfile" >/dev/null 2>&1 &
  pid=$!
  tries=0
  while [ "$tries" -lt 200 ] && [ ! -s "$pidfile" ]; do
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$pidfile" ] || { kill -9 "$pid"; fail "the child never started its stub hub"; }
  stub=$(head -1 "$pidfile")
  kill -0 "$stub" 2>/dev/null || { kill -9 "$pid"; fail "the stub hub was not running before its suite was killed"; }
  kill -9 "$pid"
  wait "$pid" 2>/dev/null
  tries=0
  while [ "$tries" -lt 100 ] && kill -0 "$stub" 2>/dev/null; do
    sleep 0.1
    tries=$((tries + 1))
  done
  if kill -0 "$stub" 2>/dev/null; then
    kill -9 "$stub" 2>/dev/null || true
    fail "a stub hub kept running after the suite that started it was killed (pid $stub)"
  fi
  pass "a stub hub stops once its killed suite is gone"
}

test_fixture_root_gone_after_normal_exit() {
  local child_out child_dir
  child_out=$(bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-exit)
    printf "%s\n" "$d"
    if [ -d "$d" ]; then printf "mid:present\n"; else printf "mid:missing\n"; fi
  ')
  child_dir=$(printf '%s\n' "$child_out" | sed -n '1p')
  assert_contains "$child_out" "mid:present" \
    "the fixture root was not present while its owning process was still alive"
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived its owning process's normal exit"
  pass "fm_test_tmproot cleans up its fixture root on normal exit"
}

test_fixture_root_gone_after_sigterm() {
  local harness dirfile child_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-sigterm-harness)
  dirfile="$harness/child-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-term)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the child never published its fixture root before the wait timed out"
  child_dir=$(cat "$dirfile")
  assert_present "$child_dir" "the child's fixture root did not exist before it was signaled"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived SIGTERM to its owning process"
  pass "fm_test_tmproot cleans up its fixture root on SIGTERM"
}

test_cleanup_registry_resists_precreation() {
  local harness shared_tmp victim
  harness=$(fm_test_tmproot fm-test-cleanup-registry-harness)
  shared_tmp="$harness/shared-tmp"
  victim="$harness/victim"
  mkdir -p "$shared_tmp" "$victim"

  TMPDIR="$shared_tmp" bash -c '
    printf "%s\n" "$1" > "$TMPDIR/.fm-test-cleanup.$$"
    . "$2"
  ' _ "$victim" "$LIB"

  assert_present "$victim" \
    "a precreated predictable cleanup registry injected an arbitrary deletion target"
  pass "the cleanup registry cannot be injected through path precreation"
}

test_fixture_registration_failure_rolls_back_root() {
  local harness failure_tmp registry_dir output leaked_root
  harness=$(fm_test_tmproot fm-test-cleanup-registration-harness)
  failure_tmp="$harness/tmp"
  registry_dir="$harness/registry-dir"
  mkdir -p "$failure_tmp" "$registry_dir"

  if output=$(TMPDIR="$failure_tmp" FM_TEST_CLEANUP_REGISTRY="$registry_dir" \
    fm_test_tmproot fm-test-cleanup-registration-failure 2>/dev/null); then
    fail "fm_test_tmproot succeeded after its cleanup registry rejected registration"
  fi
  [ -z "$output" ] || fail "fm_test_tmproot published an unregistered fixture root"
  for leaked_root in "$failure_tmp"/fm-test-cleanup-registration-failure.*; do
    [ ! -e "$leaked_root" ] || fail "fm_test_tmproot leaked a root after registration failed"
  done
  pass "failed fixture registration rolls back the new root"
}

test_orphan_sweep_respects_fixture_ownership() {
  local harness dirfile active_dir stale_dir fresh_dir pid tries unrelated
  harness=$(fm_test_tmproot fm-test-cleanup-orphan-harness)
  printf '#!/usr/bin/env bash\nsleep 120\n:\n' > "$harness/fm-startup-network.sh"
  bash "$harness/fm-startup-network.sh" >/dev/null 2>&1 &
  unrelated=$!
  fm_test_track_helper_pid "$unrelated"
  dirfile="$harness/active-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-active)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the active child never published its fixture root before the wait timed out"
  active_dir=$(cat "$dirfile")
  touch -t 202001010000 "$active_dir/.fm-test-fixture"

  stale_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-stale.XXXXXX")
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"
  mkdir -p "$stale_dir/state"
  printf 'pid=%s\nstarted=%s\n' "$unrelated" "$(date +%s)" > "$stale_dir/state/.startup-network.status"
  fresh_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-fresh.XXXXXX")
  : > "$fresh_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
  '

  assert_absent "$stale_dir" \
    "a stale fixture root whose PID was reused by another process was not reaped"
  kill -0 "$unrelated" 2>/dev/null || fail "the orphan sweep signalled a worker recorded in a stale fixture"
  fm_test_kill_tree "$unrelated"
  wait "$unrelated" 2>/dev/null || true
  assert_present "$active_dir" \
    "the orphan reaper removed an old fixture root whose owning process was still alive"
  assert_present "$fresh_dir" \
    "the orphan reaper removed a fresh marked fixture root it does not own yet"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$active_dir" \
    "the active fixture root survived its owning process's teardown"
  rm -rf "$fresh_dir"
  pass "the orphan sweep reaps only old fixtures without a live owner"
}

test_orphan_sweep_reaps_read_only_package_tree() {
  local stale_dir package_dir
  stale_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-read-only.XXXXXX")
  package_dir="$stale_dir/packages/extension"
  mkdir -p "$package_dir"
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  printf 'installed package\n' > "$package_dir/entrypoint.py"
  chmod -R a-w "$stale_dir/packages"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "$1"
  ' _ "$LIB"

  assert_absent "$stale_dir" \
    "the orphan reaper left a stale fixture containing a read-only package tree"
  pass "the orphan sweep reaps read-only package fixtures"
}

test_status_worker_identity_is_checked_before_cleanup
test_tree_cleanup_catches_a_child_forked_during_the_snapshot
test_path_reaper_signals_only_fixture_processes
test_fixture_root_gone_after_normal_exit
test_fixture_root_gone_after_sigterm
test_helper_pids_registered_in_a_subshell_are_still_reaped
test_cleanup_registry_resists_precreation
test_fixture_registration_failure_rolls_back_root
test_orphan_sweep_respects_fixture_ownership
test_orphan_sweep_reaps_read_only_package_tree
test_a_stub_hub_stops_once_its_killed_suite_is_gone
