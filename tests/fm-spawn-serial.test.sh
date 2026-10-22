#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's serialized spawns: spawns in one home run one
# at a time, and a transient refusal ("is not clean", "endpoint superseded") is
# retried a bounded number of times while any other refusal is final.
#
# FM_SPAWN_SERIAL_CHILD replaces the real spawn child with a stub, so these
# cases create no endpoints or worktrees. Case from 2026-10-22: four alert-fix
# spawns launched together in docana-delivery were refused "pooled worktree ...
# is not clean" though every copy was clean on re-check; a sequential relaunch
# worked.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-serial)
export FM_BACKEND=stream

# A home and a child stub. The stub logs start/end per task in $dir/log, fails
# while $dir/fail-<id> holds a positive count (printing $dir/reason), and
# records an overlap when another child is running.
make_home() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/home/data" "$dir/bin"
  printf 'error: pooled worktree '\''/tmp/pool/3/docana'\'' is not clean; refusing to discard uncommitted work while refreshing its base\n' > "$dir/reason"
  cat > "$dir/bin/child" <<EOF
#!/usr/bin/env bash
dir="$dir"
id=\$1
if [ -e "\$dir/running" ]; then echo overlap >> "\$dir/log"; fi
: > "\$dir/running"
echo "start \$id" >> "\$dir/log"
sleep 0.3
rm -f "\$dir/running"
echo "end \$id" >> "\$dir/log"
n=\$(cat "\$dir/fail-\$id" 2>/dev/null || echo 0)
if [ "\$n" -gt 0 ]; then
  echo \$((n - 1)) > "\$dir/fail-\$id"
  cat "\$dir/reason" >&2
  exit 1
fi
echo "spawned \$id"
EOF
  chmod +x "$dir/bin/child"
  printf '%s\n' "$dir"
}

spawn() {  # <dir> <id>
  FM_ROOT_OVERRIDE='' FM_HOME="$1/home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 \
    FM_SPAWN_SERIAL_CHILD="$1/bin/child" FM_SPAWN_TRANSIENT_RETRY_SECS=0 \
    "$SPAWN" "$2" "$1/home" --mode no-mistakes --yolo off
}

test_parallel_spawns_in_one_home_run_one_at_a_time() {
  local dir pids="" i
  dir=$(make_home parallel)
  for i in 1 2 3 4; do
    spawn "$dir" "task$i" >/dev/null 2>&1 &
    pids="$pids $!"
  done
  for i in $pids; do wait "$i" || fail "a parallel spawn failed"; done
  assert_no_grep overlap "$dir/log" "two spawns in one home ran at the same time"
  assert_equals 4 "$(grep -c '^end ' "$dir/log")" "not every spawn ran"
  assert_absent "$dir/home/state/.spawn-serial.lock" "the spawn lock was left behind"
  pass "parallel spawns in one home are serialized"
}

test_transient_refusal_is_retried() {
  local dir out
  dir=$(make_home transient)
  echo 1 > "$dir/fail-t1"
  out=$(spawn "$dir" t1 2>&1) || fail "a spawn refused once as not clean was not retried: $out"
  assert_contains "$out" "is not clean" "the first refusal was hidden"
  assert_contains "$out" "retrying in 0s (retry 1 of 2)" "the retry was not announced"
  assert_contains "$out" "spawned t1" "the retried spawn's output was lost"
  printf 'error: the stream agent refused to start an endpoint for '\''fm-t2'\'': fm-stream-agent: endpoint superseded\n' > "$dir/reason"
  echo 2 > "$dir/fail-t2"
  spawn "$dir" t2 >/dev/null 2>&1 || fail "a spawn refused twice as endpoint superseded was not retried twice"
  pass "a transient spawn refusal is retried"
}

test_retries_are_bounded_and_other_refusals_final() {
  local dir rc=0
  dir=$(make_home bounded)
  echo 5 > "$dir/fail-t1"
  spawn "$dir" t1 >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" "a spawn that keeps failing did not fail"
  assert_equals 3 "$(grep -c '^start t1' "$dir/log")" "a transient refusal was tried more than three times"
  printf 'error: task t2 has a pending authoritative backlog close\n' > "$dir/reason"
  echo 1 > "$dir/fail-t2"
  rc=0
  spawn "$dir" t2 >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" "a final refusal succeeded"
  assert_equals 1 "$(grep -c '^start t2' "$dir/log")" "a non-transient refusal was retried"
  pass "retries are bounded and other refusals are final"
}

test_parallel_spawns_in_one_home_run_one_at_a_time
test_transient_refusal_is_retried
test_retries_are_bounded_and_other_refusals_final
