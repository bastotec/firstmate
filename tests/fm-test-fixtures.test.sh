#!/usr/bin/env bash
# Behavior tests for tests/lib.sh primitives and tests/fixtures.sh builders.
#
# Cases call shared primitives directly or write stubs into a fakebin and exec
# them as a test would. Assertions are on observable output, exit status, and
# filesystem effects - never on helper source text. Migrated spawn suites cover
# fm_test_run_spawn through the real fm-spawn.sh; this file pins the shared
# primitives and stubs those suites use.
#
# It is also the fixture Git-config isolation regression, with host signing
# armed on a scratch config file: it drives every entry point that must reach
# tests/git-config-helpers.sh - the shared helpers, bin/fm-test-run.sh's
# per-suite wrapper, and the standalone scripts runnable without a live vendor.
# That helper's header owns the contract and the layers it leaves in force.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-test-fixtures)

test_git_maintenance_is_owned_through_local_clone() (
  local dir="$TMP_ROOT/maintenance" repo real_git owner head
  repo="$dir/source"
  real_git=$(command -v git)
  owner=$$
  mkdir -p "$repo" "$dir/exec"
  git -C "$repo" init -q -b main --object-format=sha1
  fm_git_foreground_maintenance "$repo" || fail 'could not own automatic maintenance'
  git -C "$repo" config maintenance.strategy gc
  git -C "$repo" config gc.auto 1
  fm_git_identity

  # Two real SHA-1 blobs in Git's sampled loose-object bucket (17) force
  # automatic GC even on older Git, whose normal threshold masks the race.
  printf 'fixture maintenance 216\n' > "$repo/one"
  printf 'fixture maintenance 234\n' > "$repo/two"
  git -C "$repo" add one two

  # Observe the real repack's process ancestry, not Git's config or a delay.
  # Detachment severs the fixture owner's ancestry even when housekeeping
  # happens to finish before clone, so that masking condition cannot pass.
  cat > "$dir/exec/git" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = repack ] && [ "$PWD" = "$FM_FIXTURE_REPO" ]; then
  cursor=$PPID
  owned=detached
  while [ "$cursor" -gt 1 ]; do
    if [ "$cursor" = "$FM_FIXTURE_OWNER" ]; then owned=owned; break; fi
    cursor=$(ps -p "$cursor" -o ppid= | tr -d '[:space:]')
    [ -n "$cursor" ] || break
  done
  printf '%s\n' "$owned" > "$FM_FIXTURE_PROBE/owner"
  "$FM_FIXTURE_GIT" "$@"
  printf 'completed\n' > "$FM_FIXTURE_PROBE/repack"
  exit 0
fi
exec "$FM_FIXTURE_GIT" "$@"
SH
  chmod +x "$dir/exec/git"
  export GIT_EXEC_PATH="$dir/exec" FM_FIXTURE_REPO="$repo" FM_FIXTURE_OWNER="$owner"
  export FM_FIXTURE_GIT="$real_git" FM_FIXTURE_PROBE="$dir"
  git -C "$repo" commit -qm 'maintenance fixture' || fail 'fixture commit failed'
  assert_grep owned "$dir/owner" 'automatic repack escaped the fixture owner'
  assert_grep completed "$dir/repack" 'commit returned before its automatic repack completed'
  head=$(git -C "$repo" rev-parse HEAD)
  git clone -q "$repo" "$dir/clone" || fail 'owned source clone failed'
  assert_equals "$head" "$(git -C "$dir/clone" rev-parse HEAD)" 'clone lost the source commit'
  git -C "$dir/clone" fsck --full > "$dir/fsck" 2>&1 || fail 'clone has missing objects'
  assert_absent "$dir/clone/.git/objects/info/alternates" 'clone borrowed unowned objects'
  pass 'automatic Git repack stays owned and finishes before a complete local clone'
)

test_git_config_isolation() (
  local dir="$TMP_ROOT/git-config" helper jobs timeout
  mkdir -p "$dir/runner/bin" "$dir/runner/tests"
  git init -q "$dir/caller"
  git -C "$dir/caller" config commit.gpgsign false
  cd "$dir/caller" || exit 1
  cp "$ROOT/bin/fm-test-run.sh" "$ROOT/bin/fm-timeout-lib.sh" "$dir/runner/bin/"
  cp "$ROOT/tests/git-config-helpers.sh" "$dir/runner/tests/"
  cat > "$dir/runner/tests/fm-test-run.test.sh" <<'SH'
#!/usr/bin/env bash
set -eu
repo=$(mktemp -d "${TMPDIR:-/tmp}/fm-git-runner.XXXXXX")
trap 'rm -rf "$repo"' EXIT
git init -q "$repo"
git -C "$repo" config user.name 'Runner Fixture'
git -C "$repo" config user.email runner@example.invalid
git -C "$repo" commit -q --allow-empty -m initial
[ "$(git -C "$repo" log -1 --format='%s:%an:%ae')" = 'initial:Runner Fixture:runner@example.invalid' ]
[ "$(git -C "$repo" config --get fixture.input)" = preserved ]
[ "$(GIT_CONFIG_GLOBAL="$FM_TEST_GIT_CONFIG" git config --global --get commit.gpgsign)" = true ]
SH
  chmod +x "$dir/runner/tests/fm-test-run.test.sh"
  export GIT_CONFIG_GLOBAL="$dir/global" GIT_CONFIG_SYSTEM="$dir/system"
  export GIT_CONFIG_NOSYSTEM=0
  unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS

  # A failing signer exposes inherited config without requiring GPG or keys.
  arm_host_signing() {  # <scope>: only this layer carries the failing signer
    : > "$dir/global"
    : > "$dir/system"
    git config --file "$dir/$1" commit.gpgsign true
    git config --file "$dir/$1" gpg.format openpgp
    git config --file "$dir/$1" gpg.program /usr/bin/false
    cp "$dir/$1" "$dir/expected"
  }

  assert_helper_isolates() {  # <helper> <scope>
    bash -eus -- "$ROOT/tests/$1.sh" "$dir/$2-$1" "$dir/$2" <<'SH' || exit 1
. "$1"
fm_git_init_commit "$2"
[ "$(git -C "$2" log -1 --format=%s)" = initial ] || fail "fixture has no initial commit"
fm_git_identity
# Child Git processes and direct commits inherit the same isolation.
bash -eu -c 'git -C "$1" commit -q --allow-empty -m child' _ "$2"
# Repository-local config and explicit command inputs remain authoritative.
git -C "$2" config commit.gpgsign true
git -C "$2" config gpg.program /usr/bin/false
if git -C "$2" commit -q --allow-empty -m signed > "$2/signing.log" 2>&1; then
  fail "repository-local signing config was ignored"
fi
assert_grep 'gpg failed to sign' "$2/signing.log" "local signing was not attempted"
git -C "$2" -c commit.gpgsign=false commit -q --allow-empty -m explicit
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false \
  git -C "$2" commit -q --allow-empty -m environment
# A config test can deliberately supply its own global file after sourcing.
[ "$(GIT_CONFIG_GLOBAL="$3" git config --global --get commit.gpgsign)" = true ] || fail "explicit global config was ignored"
SH
  }

  assert_host_config_still_governs() {  # <scope>
    # Sourcing in test subprocesses cannot change the caller or its config files.
    [ "$(git config --"$1" --get commit.gpgsign)" = true ] || fail "caller lost signing preference"
    cmp -s "$dir/$1" "$dir/expected" || fail "host config file was changed"
    git init -q "$dir/$1-outside"
    if git -C "$dir/$1-outside" -c user.name=test -c user.email=test@example.invalid \
      commit -q --allow-empty -m outside > "$dir/outside.log" 2>&1; then
      fail "commit outside fixtures bypassed signing"
    fi
    assert_grep 'gpg failed to sign' "$dir/outside.log" "outside commit did not attempt signing"
  }

  # Every fixture entry point, once. Each only has to reach the shared helper;
  # which layers that helper neutralizes is the helper's own property, settled
  # by the system-layer case below.
  arm_host_signing global
  for helper in lib fixtures secondmate-helpers wake-helpers; do
    assert_helper_isolates "$helper" global
  done
  for jobs in 1 2; do
    for timeout in 0 30; do
      GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=fixture.input GIT_CONFIG_VALUE_0=preserved \
        FM_TEST_GIT_CONFIG="$dir/global" \
        "$dir/runner/bin/fm-test-run.sh" --jobs "$jobs" --per-script-timeout-secs "$timeout" \
        tests/fm-test-run.test.sh > "$dir/runner.log" 2>&1 \
        || fail "runner inherited global config (jobs=$jobs, timeout=$timeout): $(cat "$dir/runner.log")"
      assert_grep 'FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0' "$dir/runner.log" \
        "runner did not execute the Git fixture"
    done
  done
  bash "$ROOT/tests/fm-gitignore-config.test.sh" > "$dir/gitignore.log" 2>&1 \
    || fail "standalone gitignore fixture inherited global config: $(cat "$dir/gitignore.log")"
  assert_host_config_still_governs global

  # The system layer is the shared helper's other half: one entry point settles
  # it, and the caller still signing proves the layer was genuinely armed.
  arm_host_signing system
  assert_helper_isolates lib system
  assert_host_config_still_governs system

  pass "runner and shared helpers isolate host Git config and preserve explicit config and outside commits"
)

test_touch_epoch_preserves_repeated_dst_hour() {
  local TZ=Europe/Paris epoch path actual
  export TZ
  for epoch in 1761438600 1761442200; do
    fm_touch_epoch "$epoch" "$TMP_ROOT/epoch-one" "$TMP_ROOT/epoch two"
    for path in "$TMP_ROOT/epoch-one" "$TMP_ROOT/epoch two"; do
      actual=$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null) \
        || fail "could not read fixture mtime for $path"
      [ "$actual" = "$epoch" ] \
        || fail "fm_touch_epoch should preserve epoch $epoch, got $actual"
    done
  done
  pass "fm_touch_epoch preserves both epochs in the repeated DST hour"
}

test_no_mistakes_version_constant() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/nm")
  fm_test_fake_no_mistakes "$fakebin"
  out=$("$fakebin/no-mistakes" --version)
  [ "$out" = "$FM_TEST_NO_MISTAKES_FAKE_VERSION" ] || \
    fail "fake no-mistakes --version should be the shared constant, got '$out'"
  out=$(FM_FAKE_NO_MISTAKES_VERSION="$FM_TEST_NO_MISTAKES_FAKE_VERSION_TS" \
    "$fakebin/no-mistakes" --version)
  [ "$out" = "$FM_TEST_NO_MISTAKES_FAKE_VERSION_TS" ] || \
    fail "timestamped banner override should round-trip, got '$out'"
  case "$out" in
    "$FM_TEST_NO_MISTAKES_FAKE_VERSION "*) ;;
    *) fail "timestamped banner '$out' is not the shared constant plus a suffix" ;;
  esac
  out=$(FM_FAKE_NO_MISTAKES_VERSION='no-mistakes version v9.9.9 (fake)' \
    "$fakebin/no-mistakes" --version)
  [ "$out" = 'no-mistakes version v9.9.9 (fake)' ] || \
    fail "FM_FAKE_NO_MISTAKES_VERSION should override the default banner, got '$out'"
  "$fakebin/no-mistakes" doctor
  expect_code 0 $? "fake no-mistakes non-version verbs should exit 0"
  pass "fake no-mistakes --version is the shared constant and overridable"
}

test_no_mistakes_init_doctor_markers() {
  local fakebin dir rc
  dir="$TMP_ROOT/nm-init"
  mkdir -p "$dir"
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_no_mistakes_init_doctor "$fakebin"
  ( cd "$dir" && "$fakebin/no-mistakes" init )
  assert_present "$dir/.no-mistakes-init" "init did not touch the marker"
  ( cd "$dir" && "$fakebin/no-mistakes" doctor )
  assert_present "$dir/.no-mistakes-doctor" "doctor did not touch the marker"
  rc=0
  ( cd "$dir" && "$fakebin/no-mistakes" axi ) || rc=$?
  expect_code 2 "$rc" "unknown no-mistakes verb should exit 2"
  pass "init/doctor no-mistakes stub touches markers and refuses other verbs"
}

test_fake_gh_and_gh_axi() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/gh")
  fm_test_fake_gh "$fakebin"
  fm_test_fake_gh_axi "$fakebin"
  "$fakebin/gh" auth status
  expect_code 0 $? "fake gh auth status should succeed"
  "$fakebin/gh" pr list
  expect_code 0 $? "fake gh other verbs should exit 0"
  out=$("$fakebin/gh-axi" --version)
  [ "$out" = "$FM_TEST_GH_AXI_VERSION" ] || \
    fail "fake gh-axi --version should be $FM_TEST_GH_AXI_VERSION, got '$out'"
  out=$(FM_FAKE_GH_AXI_VERSION=0.9.9 "$fakebin/gh-axi" --version)
  [ "$out" = 0.9.9 ] || fail "FM_FAKE_GH_AXI_VERSION should override, got '$out'"
  pass "fake gh authenticates and fake gh-axi reports the shared version"
}

test_spawn_fakebin_and_stream_task() {
  local fakebin log state lines target
  fakebin=$(make_spawn_fakebin "$TMP_ROOT/spawn" gh-axi)
  [ -x "$fakebin/treehouse" ] || fail "spawn fakebin should include treehouse"
  [ -x "$fakebin/gh-axi" ] || fail "extra exit-0 tools should land in the spawn fakebin"
  [ ! -e "$fakebin/tmux" ] || fail "spawn fakebin should no longer carry a tmux stub"
  "$fakebin/treehouse" get
  expect_code 0 $? "fake treehouse should exit 0"
  if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    pass "spawn fakebin installs extra tools (stream task: skipped, jq/curl unavailable)"
    return 0
  fi
  state="$TMP_ROOT/spawn/state"
  log="$TMP_ROOT/spawn/launch.log"
  mkdir -p "$state"
  : > "$log"
  lines=$(fm_test_stream_task "$state" t1 "$log") || fail "fm_test_stream_task could not register"
  target=$(printf '%s\n' "$lines" | sed -n 's/^window=//p')
  assert_equals "$(fm_test_stream_target_of "$state" t1)" "$target" "the predicted target should match the registered one"
  assert_contains "$lines" 'backend=stream' "the identity lines should name the stream backend"
  assert_contains "$lines" 'endpoint_task_id=t1' "the identity lines should bind the task id"
  (
    # shellcheck disable=SC2030 # deliberately scoped to this subshell
    export FM_HOME="$TMP_ROOT/spawn" FM_ROOT="$ROOT"
    # shellcheck source=bin/fm-backend.sh
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_source stream || exit 90
    fm_backend_stream_send_text_line "$target" 'deck run --yolo' fm-t1
  ) || fail "send line to the registered task endpoint failed"
  assert_grep 'deck run --yolo' "$log" "the endpoint's launch log did not record the typed text"
  pass "spawn fakebin installs extra tools and fm_test_stream_task registers a logging stream endpoint"
}

test_send_stubs_and_ssh() {
  local fakebin ssh_log
  fakebin=$(make_stubs "$TMP_ROOT/send")
  ssh_log="$TMP_ROOT/send/ssh.log"
  fm_test_fake_ssh "$fakebin"
  "$fakebin/sleep" 5
  expect_code 0 $? "send stubs should carry a no-op sleep"
  printf 'ignored\n' | FM_SSH_LOG="$ssh_log" "$fakebin/fake-ssh" host -- cmd
  assert_grep 'host -- cmd' "$ssh_log" "fake ssh did not record argv"
  FM_FAKE_SSH_RC=7 "$fakebin/fake-ssh" x < /dev/null
  expect_code 7 $? "fake ssh should honor FM_FAKE_SSH_RC"
  pass "send stubs carry a no-op sleep and fake ssh records argv with a controllable exit"
}

test_spawn_home_layout() {
  local home="$TMP_ROOT/home"
  fm_test_spawn_home "$home" claude
  fm_test_spawn_brief "$home" t1 'do the thing'
  assert_present "$home/data" "spawn home missing data/"
  assert_present "$home/state/.last-watcher-beat" "spawn home missing watcher beat"
  assert_grep claude "$home/config/crew-harness" "crew-harness was not pinned"
  assert_grep 'do the thing' "$home/data/t1/brief.md" "brief text was not written"
  pass "spawn-home layout writes harness pin, beat, and brief"
}

test_fake_stream_round_trip() {
  local dir="$TMP_ROOT/fake-stream" pair target out
  if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    pass "fake stream: skipped (jq/curl unavailable)"
    return 0
  fi
  fm_test_fake_stream "$dir" || fail "the fake stream hub did not start"
  mkdir -p "$dir/home/state" "$dir/cwd"
  stream() (
    # shellcheck disable=SC2031 # each subshell sets its own home
    export FM_HOME="$dir/home" FM_ROOT="$ROOT"
    # shellcheck source=bin/fm-backend.sh
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_source stream || exit 90
    "$@"
  )
  pair=$(stream fm_backend_stream_create_task fm-t1 "$dir/cwd" "$dir/home/state/t1.status") \
    || fail "the real adapter could not create a fake endpoint"
  target="${pair%% *}:${pair##* }"
  assert_equals "$FM_TEST_STREAM_TAG" "${target%%:*}" "the target should carry the fake hub's tag"
  assert_equals dead "$(stream fm_backend_agent_state stream "$target")" "a fresh fake endpoint is a bare shell"
  assert_equals "$dir/cwd" "$(stream fm_backend_stream_current_path "$target" fm-t1)" "cwd should be the registered one"
  stream fm_backend_stream_send_text_line "$target" "deck run --model x" fm-t1 || fail "send line failed"
  assert_equals alive "$(stream fm_backend_agent_state stream "$target")" "a submitted harness launch should read alive"
  assert_equals "deck run --model x" "$(fm_test_fake_stream_submitted "$target")" "the submitted line was not recorded"
  out=$(stream fm_backend_capture stream "$target" 20 fm-t1)
  assert_contains "$out" '$ deck run --model x' "capture should echo the submitted line"
  assert_equals empty "$(stream fm_backend_composer_state stream "$target" fm-t1)" "an idle composer should read empty"
  stream fm_backend_stream_send_literal "$target" "half typed" fm-t1 || fail "send literal failed"
  assert_equals pending "$(stream fm_backend_composer_state stream "$target" fm-t1)" "typed text should read pending"
  stream fm_backend_send_key stream "$target" C-u fm-t1 || fail "C-u failed"
  assert_equals empty "$(stream fm_backend_composer_state stream "$target" fm-t1)" "C-u should clear the composer"
  stream fm_backend_stream_send_text_line "$target" "/quit" fm-t1 || fail "quit failed"
  assert_equals dead "$(stream fm_backend_agent_state stream "$target")" "/quit should return to the shell"
  stream fm_backend_stream_report_status "$target" working "fake note" || fail "status report failed"
  assert_grep 'working: fake note' "$dir/home/state/t1.status" "status should land in the registered status path"
  fm_test_fake_stream_set "$target" '{"stale": true}'
  assert_equals unreadable "$(stream fm_backend_agent_state stream "$target")" "a stale reading must be unreadable"
  fm_test_fake_stream_set "$target" '{"stale": false}'
  stream fm_backend_kill stream "$target" "" fm-t1 || fail "kill should be confirmed by the fake agent"
  assert_equals dead "$(stream fm_backend_agent_state stream "$target")" "a killed endpoint reads dead"
  pass "fake stream: the real adapter creates, sends, captures, classifies, reports and kills fake endpoints"
}

test_fake_stream_owner_boundary() {
  local dir="$TMP_ROOT/owner-boundary" lines target eid route code auth
  fm_test_fake_stream "$dir" || fail 'owner fixture failed to start'
  mkdir -p "$dir/state"
  printf 'private capture contents\n' > "$dir/capture"
  printf '#!/usr/bin/env bash\nprintf invoked >> "%s"\n' "$dir/invoked" > "$dir/hook"
  chmod +x "$dir/hook"
  lines=$(fm_test_stream_task "$dir/state" owned) || fail 'owner registration failed'
  target=$(printf '%s\n' "$lines" | sed -n 's/^window=//p')
  eid=${target##*:}
  for auth in '' 'Bearer wrong-token'; do
    for route in test/config "test/endpoints/$eid" agent/endpoints; do
      code=$(curl -sS -o "$dir/refused" -w '%{http_code}' -H "Authorization: $auth" \
        -H 'Content-Type: application/json' --data-binary \
        "$(jq -nc --arg f "$dir/capture" --arg h "$dir/hook" \
          '{capture_file:$f, on_text:$h, endpoint_defaults:{capture_file:$f, on_text:$h}}')" \
        "$FM_TEST_STREAM_URL/v1/$route")
      assert_equals 403 "$code" 'non-owner installed privileged knobs'
    done
  done
  fm_test_fake_stream_set "$target" "$(jq -nc --arg f "$dir/capture" --arg h "$dir/hook" \
    '{capture_file:$f, on_text:$h, on_request:$h}')" || fail 'owner patch failed'
  for route in "tasks/$eid/capture" "tasks/$eid/screen" test/endpoints; do
    code=$(curl -sS -o "$dir/refused" -w '%{http_code}' "$FM_TEST_STREAM_URL/v1/$route")
    assert_equals 403 "$code" 'non-owner read privileged capture or configuration'
    assert_no_grep 'private capture contents' "$dir/refused" 'refusal leaked file bytes'
  done
  code=$(curl -sS -o "$dir/refused" -w '%{http_code}' -H 'Content-Type: application/json' \
    --data-binary '{"text":"trigger", "keys":["Enter"]}' "$FM_TEST_STREAM_URL/v1/tasks/$eid/input")
  assert_equals 403 "$code" 'non-owner invoked a configured helper'
  for route in health tasks "tasks/$eid" "tasks/$eid/processes" "tasks/$eid/cwd"; do
    curl -fsS "$FM_TEST_STREAM_URL/v1/$route" >/dev/null || fail 'public liveness route refused'
  done
  assert_absent "$dir/invoked" 'public reads or refused writes invoked helpers'
  curl -fsS -H "Authorization: Bearer $FM_STREAM_TOKEN" \
    "$FM_TEST_STREAM_URL/v1/tasks/$eid/capture" > "$dir/owner-capture" || fail 'owner capture refused'
  assert_grep 'private capture contents' "$dir/owner-capture" 'owner capture lost file contents'
  curl -fsS -H "Authorization: Bearer $FM_STREAM_TOKEN" -H 'Content-Type: application/json' \
    --data-binary '{"text":"trigger", "keys":["Enter"]}' \
    "$FM_TEST_STREAM_URL/v1/tasks/$eid/input" >/dev/null || fail 'owner helper invocation refused'
  assert_present "$dir/invoked" 'owner helper was not invoked'
  pass 'fake hub startup token isolates file and helper controls while public liveness remains available'
}

test_fake_stream_owner_boundary
test_git_maintenance_is_owned_through_local_clone || fail 'Git fixture maintenance ownership'
test_git_config_isolation || fail "Git fixture config isolation"
test_touch_epoch_preserves_repeated_dst_hour
test_no_mistakes_version_constant
test_no_mistakes_init_doctor_markers
test_fake_gh_and_gh_axi
test_spawn_fakebin_and_stream_task
test_send_stubs_and_ssh
test_spawn_home_layout
test_fake_stream_round_trip
