#!/usr/bin/env bash
# tests/wake-helpers.sh - shared fixtures and mocks for the wake-queue,
# watcher/lock, and supervise-daemon suites: case dirs, the fake crew-state
# verdict, wake-queue helpers, and the wedge-alarm recorder. Task and
# supervisor endpoints are fake stream endpoints (tests/fixtures.sh), so they
# live there rather than here. Generic reporters/assertions come from lib.sh,
# pulled in below.

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# The shared fake stream hub and its task-endpoint helpers (fm_test_stream_task).
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# stream_window <state-dir> <task-id>: register task <task-id>'s fake stream
# endpoint (its record still needs `backend=stream`) and print its target.
stream_window() {  # <state-dir> <task-id>
  fm_test_stream_task "$1" "$2" | sed -n 's/^window=//p'
}

# stream_capture <target> <file>: the fake endpoint's capture and screen read
# <file>, so a case drives the rendered terminal by rewriting it.
stream_capture() {  # <target> <file>
  fm_test_fake_stream_set "$1" "$(jq -nc --arg f "$2" '{capture_file: $f}')"
}

# stream_foreground <target> <name>: the fake endpoint's foreground process.
stream_foreground() {  # <target> <name>
  fm_test_fake_stream_foreground "$1" "$2"
}

# fm-wake-drain.sh now calls fm-guard.sh to assert watcher liveness on every
# drain. fm-guard.sh's first check warns when the firstmate PRIMARY checkout
# (FM_ROOT) sits on a feature branch; with no override FM_ROOT resolves to the
# test runner's own checkout, which during validation is on a feature branch, so
# each drain would emit a spurious worktree-tangle banner. Point the tangle check
# at a fresh non-git dir to keep it inert across these suites - the same trick the
# direct fm-guard.sh tests use. A per-call FM_ROOT_OVERRIDE still wins where a
# suite sets its own (e.g. the watcher-lock guard-banner cases).
if [ -z "${FM_ROOT_OVERRIDE:-}" ]; then
  FM_ROOT_OVERRIDE="$(fm_test_tmproot fm-wake-tangle-root)"
  export FM_ROOT_OVERRIDE
fi

# A suite run from inside a stream endpoint (a worker on the stream backend)
# inherits FM_STREAM_ENDPOINT_ID, which selects the stream supervisor backend in
# bin/fm-supervisor-target-lib.sh. Clear it so discovery sees only what a test sets.
unset FM_STREAM_ENDPOINT_ID

# Wedge-alarm notifier recorder (safety seam). The away-mode wedge alarm fires a
# real OS-level desktop notification by default. Point its FM_WEDGE_ALARM_EXEC
# seam at a recorder for every
# daemon/wake suite, so no test - present or future - can post a real macOS
# or command: notification: it is impossible to forget, because sourcing this harness
# installs it. The recorder is an on-disk script (a real daemon a test spawns
# inherits the path and records too). It logs "<channel>\t<summary>" to
# $FM_WEDGE_ALARM_LOG, which a test sets to its own file to assert on; unset means
# /dev/null. FM_WEDGE_ALARM_FAIL=<channel> makes the recorder exit non-zero for
# that channel, to exercise graceful degradation. Suites that do not source this
# harness still cannot fire a real notification: the daemon defaults the seam to
# "discard" whenever it is sourced (its library-mode guard).
_fm_wedge_rec_dir=$(fm_test_tmproot fm-wedge-rec)
cat > "$_fm_wedge_rec_dir/rec" <<'REC'
#!/usr/bin/env bash
printf '%s\t%s\n' "${1:-}" "${2:-}" >> "${FM_WEDGE_ALARM_LOG:-/dev/null}"
case " ${FM_WEDGE_ALARM_FAIL:-} " in *" ${1:-} "*) exit 1 ;; esac
exit 0
REC
chmod +x "$_fm_wedge_rec_dir/rec"
export FM_WEDGE_ALARM_EXEC="$_fm_wedge_rec_dir/rec"

# append_wake <state> <kind> <key> <payload>: append a wake record to the durable
# queue in a subshell scoped to <state>, using the production wake library.
append_wake() {
  local state=$1 kind=$2 key=$3 payload=$4 lib="$ROOT/bin/fm-wake-lib.sh"
  FM_STATE_OVERRIDE="$state" bash -c '
    # shellcheck disable=SC1090,SC1091
    . "$1"
    fm_wake_append "$2" "$3" "$4"
  ' _ "$lib" "$kind" "$key" "$payload"
}

# make_case <name>: a case dir under TMP_ROOT with state/ and a fakebin/
# holding the hermetic fake fm-crew-state.sh (make_fake_crew_state). Echoes the
# dir. Task endpoints come from the fake stream hub (stream_window).
make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/state" "$fakebin"
  make_fake_crew_state "$fakebin" >/dev/null
  printf '%s\n' "$dir"
}

# Install a hermetic fake fm-crew-state.sh into <fakebin> and echo its path. The
# watcher's absorb-only-when-provably-working triage calls this (via
# FM_CREW_STATE_BIN) to read a crew's current state on no-verb signal and stale
# paths; the fake returns a canned "state: <s> · source: <src> · <detail>"
# verdict line so a test can fix the provably-working decision without a real
# worktree or no-mistakes.
# A per-id override FM_FAKE_CREW_STATE_<sanitized-id> wins; otherwise the shared
# FM_FAKE_CREW_STATE; otherwise an unknown verdict (NOT provably working), the
# safe default so a test that forgets to set one surfaces rather than absorbs.
make_fake_crew_state() {  # <fakebin>
  local fakebin=$1
  cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
id=${1:-}
key=$(printf '%s' "$id" | tr -c 'A-Za-z0-9' '_')
var="FM_FAKE_CREW_STATE_$key"
val=${!var:-${FM_FAKE_CREW_STATE:-}}
printf '%s\n' "${val:-state: unknown · source: none · fake default}"
exit 0
SH
  chmod +x "$fakebin/fm-crew-state.sh"
  printf '%s\n' "$fakebin/fm-crew-state.sh"
}

# Prime <file>'s .seen-* marker to its CURRENT signature through the production
# signature owner (bin/fm-wake-lib.sh), so a test can declare "everything in
# this file was already surfaced or deliberately absorbed" before exercising
# the next wake, self-announced append, or annotation decision.
prime_status_seen() {  # <state> <file>
  FM_STATE_OVERRIDE="$1" bash -c '
    . "$1"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$1" "$2"
}

# Print the generation from a recovery marker token of any status/kind.
recovery_marker_generation() {  # <marker-file>
  sed -n 's/^[^:]*:[^:]*:\(.*\)$/\1/p' "$1"
}

# Acknowledge a drain from its captured stderr (the WAKE_ACK_REQUIRED line).
ack_drain_err() {  # <state> <stderr-file>
  local state=$1 err=$2 sequence generation
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" \
    --ack-through "$sequence" --recovery-generation "$generation"
}

# make_supercase <name>: a case dir under TMP_ROOT with state/ and an empty
# fakebin/ for a case's own stubs. Echoes the dir. The supervisor endpoint and
# task endpoints come from the fake stream hub.
make_supercase() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/fakebin"
  printf '%s\n' "$dir"
}

wait_for_exit() {
  local pid=$1 limit=${2:-50} i=0
  while [ "$i" -lt "$limit" ]; do
    if ! is_live_non_zombie "$pid"; then
      wait "$pid"
      return "$?"
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 124
}

is_live_non_zombie() {
  local pid=$1 stat
  kill -0 "$pid" 2>/dev/null || return 1
  stat=$(ps -p "$pid" -o stat= 2>/dev/null || true)
  case "$stat" in
    Z*) return 1 ;;
  esac
  return 0
}

hash_text() {
  if command -v md5 >/dev/null 2>&1; then
    printf '%s' "$1" | md5 -q
  else
    printf '%s' "$1" | md5sum | cut -d' ' -f1
  fi
}

dead_pid() {
  local p=999999
  while kill -0 "$p" 2>/dev/null; do
    p=$((p + 1))
  done
  printf '%s\n' "$p"
}
