#!/usr/bin/env bash
# tests/fm-stream-native.test.sh - stream implementation selection and the
# native (Rust) binary build/install owner (bin/fm-stream-native-lib.sh,
# `bin/fm-stream.sh native`, `bin/fm-stream.sh hub start|unit`).
#
# No real cargo build runs here: a fake cargo writes stand-in binaries, and the
# "native" hub and agent are shims that record their argv and exec the Python
# reference, so selection is proven by which executable actually ran while the
# endpoint still registers with a real (disposable, loopback) hub.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required by the stream backend)"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found (required by the stream backend)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the stream backend)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-stream-native-tests)
TOKEN="native-token-$$"
CASE_DIR=""
URL=""
trap 'fm_test_reap_helper_pids; fm_test_cleanup' EXIT INT TERM
# tests/lib.sh pins the Python reference for other suites; this one tests the
# unpinned default, so every case states its own selection.
unset FM_STREAM_IMPL FM_STREAM_NATIVE_DIR FM_STREAM_NATIVE_CACHE CARGO_TARGET_DIR

new_case() {  # <name>
  fm_test_reap_helper_pids
  CASE_DIR="$TMP_ROOT/$1"
  mkdir -p "$CASE_DIR/home/config" "$CASE_DIR/home/state" "$CASE_DIR/cwd" "$CASE_DIR/native"
}

start_python_hub() {
  local ready="$CASE_DIR/hub.ready" waited=0 host port pid
  printf 'publish,subscribe,control:%s\n' "$TOKEN" > "$CASE_DIR/tokens"
  chmod 600 "$CASE_DIR/tokens"
  python3 "$ROOT/bin/fm-stream-hub.py" serve --bind 127.0.0.1 --port 0 \
    --token-file "$CASE_DIR/tokens" --ready-file "$ready" > "$CASE_DIR/hub.log" 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true
  fm_test_track_helper_pid "$pid"
  while [ ! -s "$ready" ] && [ "$waited" -lt 100 ]; do sleep 0.1; waited=$((waited + 1)); done
  [ -s "$ready" ] || fail "hub did not start: $(cat "$CASE_DIR/hub.log")"
  read -r host port < "$ready"
  URL="http://$host:$port"
}

# write_shim <name> <python-script>: a stand-in native binary that records its
# argv and then runs the Python reference with the same arguments.
write_shim() {
  cat > "$CASE_DIR/native/$1" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CASE_DIR/native/$1.calls"
exec python3 "$ROOT/bin/$2" "\$@"
SH
  chmod +x "$CASE_DIR/native/$1"
}

with_home() {  # <command...>: run in a subshell with this case's home and the stream adapter sourced
  (
    export FM_HOME="$CASE_DIR/home" FM_ROOT="$ROOT" FM_CONFIG_OVERRIDE="$CASE_DIR/home/config"
    export FM_STREAM_HUB="$URL" FM_STREAM_TOKEN="$TOKEN" FM_STREAM_MACHINE=native-test
    # shellcheck source=bin/fm-backend.sh
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_source stream || exit 90
    "$@"
  )
}

agent_pid_for() {  # <label>
  ps -eo pid,args 2>/dev/null \
    | awk -v l="--label $1" 'index($0, "fm-stream-agent") && index($0, l) && !index($0, "awk") {print $1; exit}'
}

create() {  # <label>: create an endpoint and track its agent
  local out pid
  out=$(with_home fm_backend_stream_create_task "$1" "$CASE_DIR/cwd" 2>&1) || { printf '%s' "$out"; return 1; }
  pid=$(agent_pid_for "$1")
  [ -z "$pid" ] || fm_test_track_helper_pid "$pid"
  printf '%s' "$out"
}

test_rust_is_the_default_and_launches_the_native_agent() {
  new_case default-rust
  start_python_hub
  write_shim fm-stream-agent fm-stream-agent.py
  local out
  out=$(FM_STREAM_NATIVE_DIR="$CASE_DIR/native" create "native-default-$$") \
    || fail "create with the default implementation failed: $out"
  assert_present "$CASE_DIR/native/fm-stream-agent.calls" "the default implementation did not run the native agent"
  assert_grep "serve --hub $URL" "$CASE_DIR/native/fm-stream-agent.calls" "the native agent did not get the adapter's serve arguments"
  assert_grep "--label native-default-$$" "$CASE_DIR/native/fm-stream-agent.calls" "the native agent did not get the label"
  case "$out" in
    *' '[0-9a-f]*) ;;
    *) fail "the native launch did not return '<tag> <endpoint-id>': $out" ;;
  esac
  pass "stream: unset FM_STREAM_IMPL selects rust and launches the native agent with the adapter's arguments"
}

test_python_rollback_never_touches_the_native_agent() {
  new_case python-rollback
  start_python_hub
  write_shim fm-stream-agent fm-stream-agent.py
  printf 'python\n' > "$CASE_DIR/home/config/stream-impl"
  local out
  out=$(FM_STREAM_NATIVE_DIR="$CASE_DIR/native" create "native-python-$$") \
    || fail "create on the python rollback failed: $out"
  assert_absent "$CASE_DIR/native/fm-stream-agent.calls" "config/stream-impl=python still ran the native agent"
  pgrep -f "fm-stream-agent.py serve .*--label native-python-$$" >/dev/null \
    || fail "config/stream-impl=python did not run bin/fm-stream-agent.py"
  pass "stream: config/stream-impl=python launches the Python reference agent"
}

test_missing_native_binaries_refuse_with_the_fix() {
  new_case missing
  start_python_hub
  local out
  if out=$(FM_STREAM_NATIVE_CACHE="$CASE_DIR/empty-cache" create "native-missing-$$" 2>&1); then
    fail "a rust home without built binaries still created an endpoint: $out"
  fi
  assert_contains "$out" "native build" "the refusal should name the build command"
  assert_contains "$out" "echo python > config/stream-impl" "the refusal should name the rollback"
  [ -z "$(agent_pid_for "native-missing-$$")" ] || fail "a refused launch still started an agent"
  out=$(FM_STREAM_IMPL=ruby create "native-bad-$$" 2>&1) && fail "an unknown implementation was accepted"
  assert_contains "$out" "unknown stream implementation 'ruby'" "an unknown implementation should be named"
  pass "stream: missing native binaries and unknown implementations refuse without starting an agent"
}

test_hub_start_runs_the_selected_hub() {
  new_case hub-start
  write_shim fm-stream-hub fm-stream-hub.py
  write_shim fm-stream-agent fm-stream-agent.py
  printf '%s\n' "$TOKEN" > "$CASE_DIR/home/config/stream-token"
  local out health
  out=$(FM_HOME="$CASE_DIR/home" FM_STREAM_NATIVE_DIR="$CASE_DIR/native" \
    FM_STREAM_NATIVE_CACHE="$CASE_DIR/unused" "$ROOT/bin/fm-stream.sh" hub start --port 0 2>&1) \
    || fail "hub start with the native hub failed: $out"
  fm_test_track_helper_pid "$(cat "$CASE_DIR/home/state/.stream-hub.pid")"
  assert_grep "serve --bind 127.0.0.1 --port 0" "$CASE_DIR/native/fm-stream-hub.calls" "hub start did not run the native hub"
  assert_grep "--ready-file $CASE_DIR/home/state/.stream-hub.ready --pid-file $CASE_DIR/home/state/.stream-hub.pid" \
    "$CASE_DIR/native/fm-stream-hub.calls" "the native hub did not get the home's ready and pid files"
  health=$(FM_HOME="$CASE_DIR/home" FM_STREAM_NATIVE_DIR="$CASE_DIR/native" "$ROOT/bin/fm-stream.sh" status 2>&1) \
    || fail "status could not reach the native-started hub: $health"
  assert_contains "$health" "protocol 3" "the started hub should answer health"
  FM_HOME="$CASE_DIR/home" "$ROOT/bin/fm-stream.sh" hub stop >/dev/null || fail "hub stop failed"

  out=$(FM_HOME="$CASE_DIR/home" FM_STREAM_NATIVE_CACHE="$CASE_DIR/empty-cache" \
    "$ROOT/bin/fm-stream.sh" hub start --port 0 2>&1) && fail "hub start ran without native binaries: $out"
  assert_contains "$out" "native build" "a hub start without binaries should name the build command"
  assert_absent "$CASE_DIR/home/state/.stream-hub.pid" "a refused hub start left a pid file"
  pass "stream: hub start runs the native hub with the home's files, and refuses when it is not built"
}

test_hub_unit_prints_a_foreground_unit() {
  new_case unit
  local out exec_line
  out=$(FM_HOME="$CASE_DIR/home" "$ROOT/bin/fm-stream.sh" hub unit --bind 127.0.0.1 --port 7717) \
    || fail "hub unit failed"
  exec_line=$(printf '%s\n' "$out" | sed -n 's/^ExecStart=//p')
  assert_equals "$ROOT/bin/fm-stream.sh hub start --foreground --bind 127.0.0.1 --port 7717" "$exec_line" \
    "the unit should run the home's own hub start in the foreground"
  assert_contains "$out" "WorkingDirectory=$CASE_DIR/home" "the unit should run in the home"
  assert_contains "$out" "Restart=always" "the unit should restart the hub"
  pass "stream: hub unit prints a systemd user unit for hub start --foreground"
}

# A throwaway checkout with tracked crates/, so the source key is real.
new_checkout() {
  local repo="$CASE_DIR/repo"
  mkdir -p "$repo/bin" "$repo/crates/demo/src" "$CASE_DIR/fakebin"
  cp "$ROOT/bin/fm-stream-native-lib.sh" "$repo/bin/"
  printf '[workspace]\n' > "$repo/Cargo.toml"
  printf '# lock\n' > "$repo/Cargo.lock"
  printf 'fn main() {}\n' > "$repo/crates/demo/src/main.rs"
  git -C "$repo" init -q
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid commit -qm init
  cat > "$CASE_DIR/fakebin/cargo" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CASE_DIR/cargo.calls"
mkdir -p target/release
for name in fm-stream-hub fm-stream-agent fm-stream-bridge; do
  printf '#!/bin/sh\necho %s\n' "\$name" > "target/release/\$name"
  chmod +x "target/release/\$name"
done
SH
  chmod +x "$CASE_DIR/fakebin/cargo"
}

native() {  # <path-prefix> <function> [args...]: call the checkout's lib
  local path=$1
  shift
  PATH="$path" HOME="$CASE_DIR/home" FM_STREAM_NATIVE_CACHE="$CASE_DIR/cache" \
    bash -c '. "$1/bin/fm-stream-native-lib.sh"; shift; "$@"' _ "$CASE_DIR/repo" "$@"
}

test_build_installs_once_per_source_key() {
  new_case build
  new_checkout
  local out dir second third
  out=$(native "$CASE_DIR/fakebin:$PATH" fm_stream_native_build --if-stale 2>/dev/null) || fail "ensure failed: $out"
  case "$out" in built\ *) ;; *) fail "the first ensure should build: $out" ;; esac
  dir=${out#built }
  assert_equals "build --release --locked -p fm-stream-hub -p fm-stream-agent -p fm-stream-bridge" \
    "$(cat "$CASE_DIR/cargo.calls")" "cargo should build exactly the three locked release binaries"
  [ -x "$dir/fm-stream-agent" ] && [ -x "$dir/fm-stream-hub" ] && [ -x "$dir/fm-stream-bridge" ] \
    || fail "the binaries were not installed in $dir"
  assert_grep "commit=$(git -C "$CASE_DIR/repo" rev-parse HEAD)" "$dir/stamp" "the install should be stamped with the source commit"
  assert_equals "$dir/fm-stream-agent" "$(native "$PATH" fm_stream_native_bin fm-stream-agent)" \
    "the resolver should find the installed agent"

  second=$(native "$CASE_DIR/fakebin:$PATH" fm_stream_native_build --if-stale 2>/dev/null)
  assert_equals "current $dir" "$second" "an unchanged checkout should not rebuild"
  assert_equals 1 "$(wc -l < "$CASE_DIR/cargo.calls" | tr -d ' ')" "an unchanged checkout invoked cargo again"

  printf 'fn main() { println!("x"); }\n' > "$CASE_DIR/repo/crates/demo/src/main.rs"
  third=$(native "$CASE_DIR/fakebin:$PATH" fm_stream_native_build --if-stale 2>/dev/null)
  case "$third" in built\ *) ;; *) fail "a crate edit should rebuild: $third" ;; esac
  assert_not_equals "built $dir" "$third" "a crate edit should install under a new source key"
  pass "stream native: ensure builds once per crate source key, stamped, and rebuilds when crates change"
}

test_no_cargo_refuses_with_rustup_and_prebuilt_options() {
  new_case no-cargo
  new_checkout
  local out
  out=$(native "$(fm_test_base_path_sans "/usr/bin:/bin:/usr/sbin:/sbin" cargo)" \
    fm_stream_native_build --if-stale 2>&1) && fail "a home without cargo claimed a build: $out"
  assert_contains "$out" "https://sh.rustup.rs" "the refusal should give the rustup install command"
  assert_contains "$out" "config/stream-native-dir" "the refusal should offer prebuilt binaries"

  mkdir -p "$CASE_DIR/prebuilt"
  printf 'prebuilt\n' > "$CASE_DIR/prebuilt/marker"
  printf '%s\n' "$CASE_DIR/prebuilt" > "$CASE_DIR/home/config/stream-native-dir"
  out=$(FM_HOME="$CASE_DIR/home" native "$(fm_test_base_path_sans "/usr/bin:/bin:/usr/sbin:/sbin" cargo)" \
    fm_stream_native_build --if-stale 2>&1) || fail "a prebuilt home should not need cargo: $out"
  assert_equals "prebuilt $CASE_DIR/prebuilt" "$out" "a configured prebuilt directory is used as is"
  pass "stream native: no cargo refuses with the rustup command, and config/stream-native-dir needs no build"
}

test_rust_is_the_default_and_launches_the_native_agent
test_python_rollback_never_touches_the_native_agent
test_missing_native_binaries_refuse_with_the_fix
test_hub_start_runs_the_selected_hub
test_hub_unit_prints_a_foreground_unit
test_build_installs_once_per_source_key
test_no_cargo_refuses_with_rustup_and_prebuilt_options
