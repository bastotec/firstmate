#!/usr/bin/env bash
# tests/fixtures.sh - shared fake-toolchain and spawn-world builders.
#
# Source this from a test file:
#   # shellcheck source=tests/fixtures.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
#
# Generic reporters, temp roots, git fixtures, and fail/pass/fm_test_cleanup
# come from tests/lib.sh, pulled in below. This file owns the shared fake
# no-mistakes, gh, gh-axi, ssh, stream hub, and spawn-world helpers. Wake-queue mocks
# stay in wake-helpers.sh; secondmate-lifecycle mocks stay in
# secondmate-helpers.sh.
#
# FM_TEST_NO_MISTAKES_VERSION is the single default version for the shared fake
# no-mistakes banner. Override a single case with FM_FAKE_NO_MISTAKES_VERSION
# rather than editing a stub body.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ -n "${FM_TEST_FIXTURES_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_FIXTURES_SOURCED=1

# Production floor lives in bin/fm-bootstrap.sh (NO_MISTAKES_MIN). Keep this
# equal to that floor so a bump is one constant here plus that production pin.
export FM_TEST_NO_MISTAKES_VERSION=1.46.0
export FM_TEST_NO_MISTAKES_FAKE_VERSION="no-mistakes version v${FM_TEST_NO_MISTAKES_VERSION} (fake)"
export FM_TEST_NO_MISTAKES_FAKE_VERSION_TS="${FM_TEST_NO_MISTAKES_FAKE_VERSION} 2026-06-27T00:02:18Z"
export FM_TEST_GH_AXI_VERSION=0.1.29

# --- fake no-mistakes -------------------------------------------------------

# fm_test_fake_no_mistakes <fakebin>
# Drops a no-mistakes stub that answers --version with
# FM_TEST_NO_MISTAKES_FAKE_VERSION (or FM_FAKE_NO_MISTAKES_VERSION when set)
# and exits 0 for every other invocation.
fm_test_fake_no_mistakes() {
  local fakebin=$1
  cat > "$fakebin/no-mistakes" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --version ]; then
  printf '%s\\n' "\${FM_FAKE_NO_MISTAKES_VERSION:-$FM_TEST_NO_MISTAKES_FAKE_VERSION}"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
}

# fm_test_fake_no_mistakes_init_doctor <fakebin>
# Secondmate-lifecycle stub: init/doctor touch marker files; other verbs exit 2.
# Does not answer --version (those suites never probe the floor).
fm_test_fake_no_mistakes_init_doctor() {
  local fakebin=$1
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  init) touch .no-mistakes-init ;;
  doctor) touch .no-mistakes-doctor ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes"
}

# --- fake gh / gh-axi -------------------------------------------------------

# fm_test_fake_gh <fakebin>
# Authenticates (`gh auth status` exits 0) and otherwise exits 0.
fm_test_fake_gh() {
  local fakebin=$1
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = auth ] && [ "${2:-}" = status ]; then
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh"
}

# fm_test_fake_gh_axi <fakebin>
# Answers --version with FM_FAKE_GH_AXI_VERSION or FM_TEST_GH_AXI_VERSION.
fm_test_fake_gh_axi() {
  local fakebin=$1
  fm_fake_version_tool "$fakebin" gh-axi FM_FAKE_GH_AXI_VERSION "$FM_TEST_GH_AXI_VERSION"
}

# --- fake ssh / sleep ------------------------------------------------------

# fm_test_fake_ssh <fakebin> [name]
# Records argv to FM_SSH_LOG, consumes stdin, exits FM_FAKE_SSH_RC (default 0).
# Default name is fake-ssh so tests can point FM_SSH_BIN at it without
# shadowing a real ssh on PATH.
fm_test_fake_ssh() {
  local fakebin=$1 name=${2:-fake-ssh}
  cat > "$fakebin/$name" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "$*" >> "${FM_SSH_LOG:-/dev/null}"
exit "${FM_FAKE_SSH_RC:-0}"
SH
  chmod +x "$fakebin/$name"
}

# fm_test_fake_sleep_noop <fakebin>
fm_test_fake_sleep_noop() {
  local fakebin=$1
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
}

# fm_test_fake_sleep_log <fakebin>
# Records each requested duration to FM_SLEEP_LOG instead of sleeping.
fm_test_fake_sleep_log() {
  local fakebin=$1
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "${FM_SLEEP_LOG:-/dev/null}"
exit 0
SH
  chmod +x "$fakebin/sleep"
}

# --- spawn-world ------------------------------------------------------------

# fm_test_spawn_home <home> [harness]
# Minimal firstmate home layout plus watcher-liveness beat. Optional harness
# pin is written to config/crew-harness.
fm_test_spawn_home() {
  local home=$1 harness=${2-}
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  touch "$home/state/.last-watcher-beat"
  if [ -n "$harness" ]; then
    printf '%s\n' "$harness" > "$home/config/crew-harness"
  fi
}

# fm_test_spawn_brief <home> <id> [captain-intent]
fm_test_spawn_brief() {
  local home=$1 id=$2 intent=${3:-brief for $2}
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
$intent

## Firstmate spec
Exercise the spawn behavior under test.
EOF
}

# fm_test_make_spawn_fakebin <dir> [extra-exit0-tool...]
# Creates <dir>/fakebin with a no-op treehouse and any extra exit-0 tools.
# Echoes the fakebin path. It also starts the suite's shared fake stream hub
# (fm_test_fake_stream_ensure), which the spawn's endpoint comes from: a spawn
# reaches it through the FM_STREAM_* variables this file exports.
fm_test_make_spawn_fakebin() {
  local dir=$1 fakebin
  shift
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" treehouse "$@"
  fm_test_fake_stream_ensure >/dev/null || return 1
  printf '%s\n' "$fakebin"
}

# Drop-in name used by the spawn suites. Extra args are additional exit-0 tools
# (gh, gh-axi, pi, ...).
make_spawn_fakebin() {
  fm_test_make_spawn_fakebin "$@"
}

# fm_test_fake_deck <fakebin>
# Shared Deck stub: an exit-0 `deck` executable, which is all fm-spawn needs to
# resolve the deck harness (bin/fm-deck-worker.sh, not deck itself, is what the
# launch command runs). jq and python3 come from the real PATH. Suites that
# drive a real Deck turn write their own NDJSON-emitting stub instead.
fm_test_fake_deck() {
  local fakebin=$1
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/deck"
  chmod +x "$fakebin/deck"
}

# fm_test_run_spawn <home> <pane-path> <fakebin> [fm-spawn args...]
# Common spawn env on the shared fake stream hub (fm_test_fake_stream_ensure):
# <pane-path> is where the endpoint's `treehouse get` lands, and every text the
# launch types is appended to FM_FAKE_LAUNCH_LOG when the caller sets it. Extra
# variables in the caller are inherited. Does not add --mode/--yolo; ship tests
# that need a delivery contract pass those flags themselves.
fm_test_run_spawn() {
  local home=$1 pane=$2 fakebin=$3
  shift 3
  fm_test_fake_stream_ensure || return 1
  # Every spawn here runs against a throwaway HOME, so nothing a launch writes
  # under the user's home can reach the developer's real one.
  local spawn_home=$home/user-home
  mkdir -p "$spawn_home"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$spawn_home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}

# --- send-world stubs -------------------------------------------------------

# make_stubs <dir>
# Send-world fakebin: a no-op sleep. Echoes the fakebin path. Endpoints come
# from fm_test_stream_task. Suites that need recording sleep or ssh add those on
# top of this fakebin (or replace sleep via fm_test_fake_sleep_log).
make_stubs() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_sleep_noop "$fakebin"
  printf '%s\n' "$fakebin"
}

# --- fake stream hub ----------------------------------------------------------

# fm_test_fake_stream <dir>
# Starts tests/assets/stream-hub-stub.py --fleet on an ephemeral loopback port
# and exports what bin/backends/stream.sh reads, so the real adapter, spawn,
# peek, send, control, and teardown run against fake endpoints instead of a
# real hub, agent, and pty:
#   FM_STREAM_HUB, FM_STREAM_TOKEN, FM_STREAM_MACHINE (fake-box), and
#   FM_STREAM_AGENT_BIN (tests/assets/stream-agent-stub.py).
# Also sets FM_TEST_STREAM_URL and FM_TEST_STREAM_TAG (the hub tag every
# target starts with). Pass --backend stream (or FM_BACKEND=stream) to the
# script under test. The stub is a tracked helper, so fm_test_cleanup and
# fm_test_reap_helper_pids stop it. The stub's docstring owns the fake-shell
# rules (what makes a harness the foreground, and how /quit returns).
fm_test_fake_stream() {
  local dir=$1 ready pid waited=0 host port token
  mkdir -p "$dir"
  ready="$dir/stream-hub.ready"
  rm -f "$ready"
  python3 "$ROOT/tests/assets/stream-hub-stub.py" --fleet --port 0 \
    --ready-file "$ready" --journal "$dir/stream-hub.journal" \
    > "$dir/stream-hub.log" 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true
  fm_test_track_helper_pid "$pid"
  while [ "$waited" -lt 100 ]; do
    [ -s "$ready" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$ready" ] || { echo "fm_test_fake_stream: the stub hub never became ready: $(cat "$dir/stream-hub.log" 2>/dev/null)" >&2; return 1; }
  read -r host port token < "$ready"
  FM_TEST_STREAM_URL="http://$host:$port"
  FM_TEST_STREAM_TAG="$host-$port"
  export FM_STREAM_HUB="$FM_TEST_STREAM_URL" FM_STREAM_TOKEN="$token" \
    FM_STREAM_MACHINE=fake-box FM_STREAM_AGENT_BIN="$ROOT/tests/assets/stream-agent-stub.py" \
    FM_TEST_STREAM_URL FM_TEST_STREAM_TAG
}

# One shared fake hub per suite, started while sourcing so every subshell
# inherits the same startup-generated owner token as the real adapter.
# A suite calling fm_test_fake_stream explicitly gets its own hub instead.
fm_test_fake_stream_reserve() {
  local dir
  command -v python3 >/dev/null 2>&1 || return 0
  dir=$(fm_test_tmproot fm-test-stream) || return 1
  fm_test_fake_stream "$dir"
}

fm_test_fake_stream_ensure() {
  [ -n "${FM_TEST_STREAM_URL:-}" ] || { echo 'fm_test_fake_stream_ensure: no fake hub (python3 missing?)' >&2; return 1; }
  curl -fsS -m 5 -o /dev/null "$FM_TEST_STREAM_URL/v1/health" 2>/dev/null
}

fm_test_fake_stream_reserve

# fm_test_stream_task <state-dir> <task-id> [launch-log] [capture-file]
# Register a fake endpoint labelled fm-<task-id> on the shared hub and print
# the stream identity lines a task record carries for it (window=, backend=,
# stream_hub=, stream_endpoint_id=, endpoint_task_id=), for the caller to add
# to its state/<id>.meta. Every text the endpoint receives is appended to
# [launch-log] when given (empty = none), and the endpoint's capture and
# screen read [capture-file] when given, so a suite drives the rendered
# terminal by rewriting that file. The endpoint's status path is
# <state-dir>/<task-id>.status. The endpoint starts with no reported foreground
# process (agent state `ambiguous`, like a pane whose command cannot be read);
# fm_test_fake_stream_foreground names one. Registering the same task again
# refreshes its test knobs. The target is also left in FM_TEST_STREAM_TARGET when called
# directly (not in a command substitution); fm_test_stream_target_of predicts it.
fm_test_stream_task() {  # <state-dir> <task-id> [launch-log] [capture-file]
  local state=$1 id=$2 log=${3:-} capture=${4:-} eid body
  fm_test_fake_stream_ensure || return 1
  eid=$(printf '%s' "$state/$id" | cksum | awk '{ printf "%08x", $1 }')
  eid=$(printf '%s%s%s%s' "$eid" "$eid" "$eid" "$eid")
  body=$(jq -nc --arg e "$eid" --arg l "fm-$id" --arg c "$state" \
    --arg s "$state/$id.status" --arg log "$log" --arg cap "$capture" \
    '{endpoint_id:$e, machine:"fake-box", label:$l, cwd:$c, status_path:$s, replace_label:true, foreground:[], launch_log:$log, capture_file:$cap}')
  curl -fsS -m 10 -H "Authorization: Bearer $FM_STREAM_TOKEN" -X POST -H 'Content-Type: application/json' --data-binary "$body" \
    "$FM_TEST_STREAM_URL/v1/agent/endpoints" >/dev/null || return 1
  FM_TEST_STREAM_TARGET="$FM_TEST_STREAM_TAG:$eid"
  printf 'window=%s\nbackend=stream\nstream_hub=%s\nstream_endpoint_id=%s\nendpoint_task_id=%s\n' \
    "$FM_TEST_STREAM_TARGET" "$FM_TEST_STREAM_URL" "$eid" "$id"
}

# fm_test_stream_secondmate_meta <file> <home> [projects] [harness] [launch-log]
# fm_write_secondmate_meta's kind=secondmate record, on a fake stream endpoint
# registered for it (fm_test_stream_task) rather than a literal window.
fm_test_stream_secondmate_meta() {  # <file> <home> [projects] [harness] [launch-log]
  local file=$1 home=$2 projects=${3:-alpha} harness=${4:-echo} log=${5:-} id identity
  id=$(basename "$file" .meta)
  identity=$(fm_test_stream_task "$(dirname "$file")" "$id" "$log") || return 1
  {
    printf '%s\n' "$identity"
    printf '%s\n' "worktree=$home" "project=$home" "harness=$harness" "kind=secondmate" \
      "mode=secondmate" "yolo=off" "home=$home" "projects=$projects"
  } > "$file"
}

# --- the lifecycle fake-dir model on a fake stream endpoint -----------------
#
# The control-plane suites model one task endpoint as plain files in a fake dir:
#   command  the endpoint's foreground process name (the agent-state input);
#            a shell name (zsh, bash) means no agent runs.
#   becomes  the harness a typed launch brief ('encode launch-brief') starts.
#   cwd      the endpoint's current directory.
#   pane     optional rendered screen, read by capture and the composer gate.
#   cursor   optional cursor row on that screen.
#   windows  emptied (`: > windows`) to make the hub forget the endpoint.
#   literal  every text typed into the endpoint, one per line.
#   keys     every named key sent, one per line.
# fm_test_fake_dir_task registers the endpoint; fm_test_fake_dir_push copies
# the files (and the FM_FAKE_NEVER_DIES, FM_FAKE_INTERRUPT_STOPS_AGENT,
# FM_FAKE_CLEAR_REPAINTS and FM_FAKE_DEAD_ON_CLEAR switches) onto it before a
# command runs, and fm_test_fake_dir_pull appends what the endpoint received
# to literal and keys and writes its foreground back to command afterwards. The
# stub applies the same transitions a tmux pane model would: a submitted exit
# command stops the agent, a launch brief starts `becomes`.

# fm_test_fake_dir_task <fake-dir> <state-dir> <task-id>
# Register the task's endpoint and print its identity lines (fm_test_stream_task).
fm_test_fake_dir_task() {  # <fake-dir> <state-dir> <task-id>
  local fake=$1 lines
  mkdir -p "$fake"
  : >> "$fake/log"
  lines=$(fm_test_stream_task "$2" "$3" "$fake/log") || return 1
  printf '%s\n' "$lines" | sed -n 's/^window=//p' > "$fake/target"
  : > "$fake/logpos"
  printf 'fm-%s\n' "$3" > "$fake/windows"
  printf '%s\n' "$lines"
}

fm_test_fake_dir_push() {  # <fake-dir>
  local fake=$1 target body cursor=null pane='' forget=false
  [ -s "$fake/target" ] || return 0
  target=$(cat "$fake/target")
  [ -f "$fake/pane" ] && pane="$fake/pane"
  if [ -f "$fake/cursor" ]; then
    cursor=$(tr -dc '0-9' < "$fake/cursor")
    [ -n "$cursor" ] || cursor=null
  fi
  [ -f "$fake/windows" ] && [ ! -s "$fake/windows" ] && forget=true
  if [ "$forget" = true ]; then
    fm_test_fake_stream_set "$target" '{"forget": true}'
    return 0
  fi
  body=$(jq -nc --arg c "$(cat "$fake/command" 2>/dev/null)" \
    --arg b "$(cat "$fake/becomes" 2>/dev/null)" --arg d "$(cat "$fake/cwd" 2>/dev/null)" \
    --arg p "$pane" --argjson cur "$cursor" \
    --argjson nd "$([ -n "${FM_FAKE_NEVER_DIES:-}" ] && echo true || echo false)" \
    --argjson is "$([ -n "${FM_FAKE_INTERRUPT_STOPS_AGENT:-}" ] && echo true || echo false)" \
    --argjson cr "$([ -n "${FM_FAKE_CLEAR_REPAINTS:-}" ] && echo true || echo false)" \
    --argjson dc "$([ -n "${FM_FAKE_DEAD_ON_CLEAR:-}" ] && echo true || echo false)" \
    '{foreground: [{pid: "", name: ($c | if . == "" then "bash" else . end), argv0: $c, args: $c}],
      becomes: $b, capture_file: $p, cursor_row: $cur, screen_rows: null,
      never_dies: $nd, interrupt_stops: $is, clear_repaints: $cr, dead_on_clear: $dc}
     + (if $d == "" then {} else {cwd: $d} end)')
  fm_test_fake_stream_set "$target" "$body"
}

fm_test_fake_dir_pull() {  # <fake-dir>
  local fake=$1 target pos total name
  [ -s "$fake/target" ] || return 0
  target=$(cat "$fake/target")
  pos=$(cat "$fake/logpos" 2>/dev/null); pos=${pos:-0}
  total=$(wc -l < "$fake/log" | tr -d ' ')
  if [ "$total" -gt "$pos" ]; then
    tail -n +"$((pos + 1))" "$fake/log" >> "$fake/literal"
    printf '%s\n' "$total" > "$fake/logpos"
  fi
  pos=$(cat "$fake/keypos" 2>/dev/null); pos=${pos:-0}
  total=$( { cat "$fake/log.keys" 2>/dev/null || true; } | wc -l | tr -d ' ')
  if [ "$total" -gt "$pos" ]; then
    tail -n +"$((pos + 1))" "$fake/log.keys" | sed -n 's/^\[key\] //p' >> "$fake/keys"
    printf '%s\n' "$total" > "$fake/keypos"
  fi
  name=$(fm_test_fake_stream_endpoints | jq -r --arg e "${target##*:}" \
    '.endpoints[] | select(.endpoint_id == $e) | .foreground[0].name // empty')
  [ -z "$name" ] || printf '%s' "$name" > "$fake/command"
}

# fm_test_stream_target_of <state-dir> <task-id>
# The target fm_test_stream_task registers for that task, without registering.
fm_test_stream_target_of() {  # <state-dir> <task-id>
  local eid
  fm_test_fake_stream_ensure || return 1
  eid=$(printf '%s' "$1/$2" | cksum | awk '{ printf "%08x", $1 }')
  printf '%s:%s%s%s%s\n' "$FM_TEST_STREAM_TAG" "$eid" "$eid" "$eid" "$eid"
}

# fm_test_fake_stream_foreground <target-or-endpoint-id> <name>
# Make <name> the fake endpoint's foreground process: a shell name (bash, zsh)
# reads agent-free, a harness name (deck, fm-deck-worker) reads alive.
fm_test_fake_stream_foreground() {  # <target> <name>
  fm_test_fake_stream_set "$1" "$(jq -nc --arg n "$2" '{foreground: [{pid: "", name: $n, argv0: $n, args: $n}]}')"
}

# fm_test_fake_stream_endpoints
# The stub's JSON view of every fake endpoint: endpoint_id, label, machine,
# cwd, foreground, alive, stale, closed_by, composer, and submitted (each line
# the endpoint received with Enter, oldest first).
fm_test_fake_stream_endpoints() {
  curl -fsS -m 10 -H "Authorization: Bearer $FM_STREAM_TOKEN" "$FM_TEST_STREAM_URL/v1/test/endpoints"
}

# fm_test_fake_stream_submitted <target-or-endpoint-id>
# The lines submitted to one fake endpoint, one per line.
fm_test_fake_stream_submitted() {
  local id=${1##*:}
  fm_test_fake_stream_endpoints \
    | jq -r --arg id "$id" '.endpoints[] | select(.endpoint_id == $id) | .submitted[]'
}

# fm_test_fake_stream_set <target-or-endpoint-id> <json-patch>
# Patch one fake endpoint: {"foreground": [...]}, {"alive": false},
# {"stale": true}, {"closed_by": "agent"}, {"composer": "text"}, or
# {"forget": true} (the hub then answers 404 for it).
fm_test_fake_stream_set() {
  local id=${1##*:}
  curl -fsS -m 10 -H "Authorization: Bearer $FM_STREAM_TOKEN" -X POST -H 'Content-Type: application/json' \
    --data-binary "$2" "$FM_TEST_STREAM_URL/v1/test/endpoints/$id" >/dev/null
}

# fm_test_close_task_endpoint <meta-file>
# Mark the task's recorded endpoint closed by its agent (the worker exited),
# which frees its label for a fresh spawn of the same task id.
fm_test_close_task_endpoint() {  # <meta-file>
  fm_test_fake_stream_set "$(sed -n 's/^window=//p' "$1" | tail -1)" '{"closed_by": "agent"}'
}

# fm_test_fake_stream_defaults '<json>'
# Endpoint knobs (fm_test_fake_stream_set's) applied to every endpoint
# registered from now on, such as the one a spawn creates; '{}' clears them.
fm_test_fake_stream_defaults() {
  curl -fsS -m 10 -H "Authorization: Bearer $FM_STREAM_TOKEN" -X POST -H 'Content-Type: application/json' \
    --data-binary "$(jq -nc --argjson d "$1" '{endpoint_defaults: $d}')" \
    "$FM_TEST_STREAM_URL/v1/test/config" >/dev/null
}

# fm_test_fake_stream_treehouse <dir>
# Where a `treehouse get` typed into any fake endpoint moves its cwd - the
# worktree a stream spawn then discovers through the endpoint's cwd.
fm_test_fake_stream_treehouse() {
  curl -fsS -m 10 -H "Authorization: Bearer $FM_STREAM_TOKEN" -X POST -H 'Content-Type: application/json' \
    --data-binary "$(jq -nc --arg d "$1" '{treehouse_cwd: $d}')" \
    "$FM_TEST_STREAM_URL/v1/test/config" >/dev/null
}
