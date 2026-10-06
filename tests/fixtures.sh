#!/usr/bin/env bash
# tests/fixtures.sh - shared fake-toolchain and spawn-world builders.
#
# Source this from a test file:
#   # shellcheck source=tests/fixtures.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
#
# Generic reporters, temp roots, git fixtures, and fail/pass/fm_test_cleanup
# come from tests/lib.sh, pulled in below. This file owns the shared fake
# no-mistakes, gh, gh-axi, tmux, ssh, and spawn-world helpers. Wake-queue mocks
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

# --- fake tmux / ssh / sleep ------------------------------------------------

# fm_test_fake_tmux_spawn <fakebin>
# Spawn-world tmux: pane_current_path from FM_FAKE_PANE_PATH, session named
# firstmate, window ops succeed, send-keys succeed. When FM_FAKE_LAUNCH_LOG is
# set, each send-keys -l payload is appended one per line. Optional
# FM_FAKE_DUPLICATE_WINDOW is printed from list-windows.
#
# The pane path defaults to empty when FM_FAKE_PANE_PATH is unset. Window
# cleanup and option operations are no-ops. Launch logging is env-gated, so
# suites that do not set FM_FAKE_LAUNCH_LOG keep a silent send-keys.
fm_test_fake_tmux_spawn() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows)
    if [ -n "${FM_FAKE_DUPLICATE_WINDOW:-}" ]; then
      printf '%s\n' "$FM_FAKE_DUPLICATE_WINDOW"
    fi
    exit 0
    ;;
  has-session|new-session|new-window|kill-window|set-window-option) exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      prev=
      for a in "$@"; do
        if [ "$prev" = "-l" ]; then
          printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG"
        fi
        prev=$a
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

# fm_test_fake_tmux_send <fakebin>
# Send-world tmux: logs send-keys -l payloads to FM_SEND_LOG, reports a numeric
# cursor_y, and renders an empty bordered composer so the submit path reads
# empty. Env knobs:
#   FM_FAKE_TMUX_SEND_FAIL=1  send-keys exits 1
#   FM_FAKE_TMUX_COMPOSER=pending  capture-pane shows leftover composer text
fm_test_fake_tmux_send() {
  local fakebin=$1
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    [ "${FM_FAKE_TMUX_SEND_FAIL:-0}" = 1 ] && exit 1
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s' "${1:-}" >> "${FM_SEND_LOG:-/dev/null}"
    fi
    exit 0
    ;;
  display-message)
    for a in "$@"; do
      case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac
    done
    printf 'fakepane\n'
    exit 0
    ;;
  capture-pane)
    if [ "${FM_FAKE_TMUX_COMPOSER:-}" = pending ]; then
      printf '╭──────────────╮\n│ leftover txt │\n╰──────────────╯\n'
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0
    ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
}

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
# Creates <dir>/fakebin with the spawn tmux stub, a no-op treehouse, and any
# extra exit-0 tools. Echoes the fakebin path.
fm_test_make_spawn_fakebin() {
  local dir=$1 fakebin
  shift
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_tmux_spawn "$fakebin"
  fm_fake_exit0 "$fakebin" treehouse "$@"
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
# Common spawn env. Extra variables in the caller (FM_FAKE_LAUNCH_LOG, ...) are
# inherited. Does not add --mode/--yolo; ship tests
# that need a delivery contract pass those flags themselves.
fm_test_run_spawn() {
  local home=$1 pane=$2 fakebin=$3
  shift 3
  # Every spawn here runs against a throwaway HOME, so nothing a launch writes
  # under the user's home can reach the developer's real one.
  local spawn_home=$home/user-home
  mkdir -p "$spawn_home"
  FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$spawn_home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$pane" TMUX="${TMUX:-fake,1,0}" \
    PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}

# --- send-world stubs -------------------------------------------------------

# make_stubs <dir>
# Send-world fakebin: send tmux + no-op sleep. Echoes the fakebin path.
# Suites that need recording sleep, herdr, or ssh add those on top of this
# fakebin (or replace sleep via fm_test_fake_sleep_log).
make_stubs() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_test_fake_tmux_send "$fakebin"
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
  local dir=$1 ready pid waited=0 host port
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
  read -r host port < "$ready"
  FM_TEST_STREAM_URL="http://$host:$port"
  FM_TEST_STREAM_TAG="$host-$port"
  export FM_STREAM_HUB="$FM_TEST_STREAM_URL" FM_STREAM_TOKEN=fake-stream-token \
    FM_STREAM_MACHINE=fake-box FM_STREAM_AGENT_BIN="$ROOT/tests/assets/stream-agent-stub.py" \
    FM_TEST_STREAM_URL FM_TEST_STREAM_TAG
}

# fm_test_fake_stream_endpoints
# The stub's JSON view of every fake endpoint: endpoint_id, label, machine,
# cwd, foreground, alive, stale, closed_by, composer, and submitted (each line
# the endpoint received with Enter, oldest first).
fm_test_fake_stream_endpoints() {
  curl -sS -m 10 "$FM_TEST_STREAM_URL/v1/test/endpoints"
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
  curl -sS -m 10 -X POST -H 'Content-Type: application/json' \
    --data-binary "$2" "$FM_TEST_STREAM_URL/v1/test/endpoints/$id" >/dev/null
}

# fm_test_fake_stream_treehouse <dir>
# Where a `treehouse get` typed into any fake endpoint moves its cwd - the
# worktree a stream spawn then discovers through the endpoint's cwd.
fm_test_fake_stream_treehouse() {
  curl -sS -m 10 -X POST -H 'Content-Type: application/json' \
    --data-binary "$(jq -nc --arg d "$1" '{treehouse_cwd: $d}')" \
    "$FM_TEST_STREAM_URL/v1/test/config" >/dev/null
}
