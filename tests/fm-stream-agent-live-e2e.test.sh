#!/usr/bin/env bash
# tests/fm-stream-agent-live-e2e.test.sh - default-on drift guard proving every
# INSTALLED harness is still classified `alive` through the central stream hub,
# and that a partitioned agent is never classified dead.
#
# Why this file exists separately from
# tests/fm-harness-liveness-drift-live-e2e.test.sh: that guard proves the shared
# classifier against tmux's reading of a pane's foreground processes. The stream
# backend reads a DIFFERENT table by a different route - the owning agent's own
# process table, published to a hub over HTTP, flattened into a command line
# rather than tmux's comm list. A release that changed how a harness names
# itself would surface in both, but a defect in the agent's foreground-group
# reading, in the publish path, or in the freshness gate would surface only
# here, and a stub agent cannot see any of them: it would only confirm the shape
# the stub was written to produce.
#
# The partition assertion belongs here for the same reason. A dead worker and an
# unreachable one are indistinguishable from the hub, only one of them
# authorizes recovery, and no portable test can produce a REAL silenced
# publisher holding a REAL harness. Getting that verdict wrong on a live harness
# is how a healthy worker gets torn down.
#
# Each harness is launched bare, with no prompt, so this consumes no model
# tokens and runs default-on wherever its tools are installed. The launch uses
# whatever credentials the harness already has; an unauthenticated harness still
# starts its process, which is all the classifier reads.
#
# The portable counterparts that pin this logic in CI with no harness at all are
# tests/fm-stream-hub.test.sh and tests/fm-backend-stream.test.sh. Run this
# guard after any harness upgrade and before trusting refreshed evidence in
# docs/verification/runtime-backends.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_STREAM_AGENT_LIVE python3 curl jq

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HUB="$ROOT/bin/fm-stream-hub.py"
TOKEN="stream-live-$$"
LAB=$(fm_test_tmproot fm-stream-agent-live)
# Deliberately short, so the partition case does not have to wait out a
# production-sized window to prove its point.
STATE_MAX_AGE=3

note() { printf '# %s\n' "$1"; }

cleanup_all() {
  fm_test_reap_helper_pids
  fm_test_cleanup
}
trap cleanup_all EXIT INT TERM

mkdir -p "$LAB/wt"
printf 'publish,subscribe:%s\n' "$TOKEN" > "$LAB/tokens"
chmod 600 "$LAB/tokens"
printf '%s\n' "$TOKEN" > "$LAB/token"
chmod 600 "$LAB/token"
python3 "$HUB" serve --bind 127.0.0.1 --port 0 --token-file "$LAB/tokens" \
  --ready-file "$LAB/ready" --state-max-age-secs "$STATE_MAX_AGE" > "$LAB/hub.log" 2>&1 &
HUB_PID=$!
disown "$HUB_PID" 2>/dev/null || true
fm_test_track_helper_pid "$HUB_PID"
waited=0
while [ "$waited" -lt 100 ]; do
  [ -s "$LAB/ready" ] && break
  sleep 0.1
  waited=$((waited + 1))
done
[ -s "$LAB/ready" ] || fail "the hub never reported ready: $(cat "$LAB/hub.log" 2>/dev/null)"
read -r host port < "$LAB/ready"
FM_STREAM_HUB="http://$host:$port"
FM_STREAM_TOKEN="$TOKEN"
FM_STREAM_MACHINE="live-$$"
export FM_STREAM_HUB FM_STREAM_TOKEN FM_STREAM_MACHINE

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=bin/fm-cursor-lib.sh
. "$ROOT/bin/fm-cursor-lib.sh"
fm_backend_source stream || fail "fm_backend_source stream failed"

TAG=$(fm_backend_stream_hub_tag) || fail "could not derive the hub tag"

# resolve_harness_binary mirrors bin/fm-spawn.sh's own resolution order, so this
# guard covers the same binary firstmate would actually launch.
resolve_harness_binary() {  # <harness>
  local harness=$1 candidate
  # cursor never installs as `cursor`; the editor CLI of that name would exit
  # immediately and leave a bare shell this guard would then misreport as drift.
  if [ "$harness" = cursor ]; then
    fm_cursor_resolve_binary 2>/dev/null && return 0
    return 1
  fi
  candidate=$(command -v "$harness" 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [ "$harness" = kimi ] && [ -n "${HOME:-}" ] && [ -x "$HOME/.kimi-code/bin/kimi" ]; then
    printf '%s\n' "$HOME/.kimi-code/bin/kimi"
    return 0
  fi
  return 1
}

# agent_pid_for: the publisher for one label in THIS run. Labels carry the pid
# of this run precisely so a leftover agent from an earlier one is never the
# process a partition case silences.
agent_pid_for() {  # <label>
  ps -eo pid,args 2>/dev/null \
    | awk -v l="--label $1" 'index($0, "fm-stream-agent.py") && index($0, l) && !index($0, "awk") {print $1; exit}'
}

start_endpoint() {  # <label> -> target
  local label=$1 pair
  pair=$(fm_backend_stream_create_task "$label" "$LAB/wt") \
    || fail "$label: the agent could not register an endpoint"
  fm_test_track_helper_pid "$(agent_pid_for "$label")"
  printf '%s:%s' "$TAG" "${pair##* }"
}

CHECKED=0
SKIPPED=

for harness in claude codex opencode pi pi-signed grok kimi cursor muse; do
  if ! bin_path=$(resolve_harness_binary "$harness"); then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its stream classification is unverified here"
    continue
  fi

  version=$("$bin_path" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version="unknown"

  label="fm-live-$harness-$$"
  target=$(start_endpoint "$label")

  # An endpoint sitting at its own shell must classify dead FIRST, so a later
  # `alive` proves the harness was seen rather than that this guard says alive
  # about anything with a pulse.
  state=$(fm_backend_agent_state stream "$target")
  [ "$state" = dead ] || fail \
    "$harness ($version): a bare endpoint shell classified '$state', not 'dead'; this guard cannot tell a real agent from a vacuous verdict."

  # cursor blocks on a workspace-trust prompt in a directory it has never seen,
  # which would hang this probe rather than classify anything; --trust is the
  # same flag fm-spawn passes for the same reason.
  launch="$bin_path"
  [ "$harness" = cursor ] && launch="$bin_path --trust"
  fm_backend_stream_send_text_line "$target" "exec $launch" >/dev/null \
    || fail "$harness ($version): could not launch the harness in its endpoint"

  state=
  for _ in $(seq 1 300); do
    state=$(fm_backend_agent_state stream "$target")
    [ "$state" = alive ] && break
    sleep 0.2
  done

  processes=$(fm_backend_stream_api GET "/v1/tasks/${target#*:}/processes" 2>/dev/null) || processes=
  observed=$(printf '%s' "$processes" | jq -r '[.foreground[]? | "\(.name) \(.argv0) \(.args)"] | join(" | ")' 2>/dev/null) || observed=

  [ "$state" = alive ] || fail \
    "STREAM LIVENESS DRIFT: $harness $version is running in a hub-published endpoint but classifies '$state', not 'alive'. Supervision and lifecycle control treat this endpoint as unattributable. The agent published foreground processes [$observed]. Teach bin/fm-agent-process-lib.sh's fm_agent_process_classify_name the identity this release actually reports, or fix the agent's foreground-group reading if that list is wrong."

  note "$harness $version: published foreground=[$observed]"
  pass "stream liveness: $harness $version classifies alive through the hub"

  # The partition case, against a REAL running harness. Silence the publisher
  # only - the harness process is untouched and perfectly healthy - and the
  # verdict must become unreadable, never dead. A `dead` here would authorize
  # tearing down a live worker that was merely unreachable.
  agent_pid=$(agent_pid_for "$label")
  if [ -n "$agent_pid" ]; then
    fm_test_kill_foreign_pid "$agent_pid" "silencing $harness's publisher"
    state=
    for _ in $(seq 1 100); do
      state=$(fm_backend_agent_state stream "$target")
      [ "$state" = unreadable ] && break
      sleep 0.2
    done
    [ "$state" = unreadable ] || fail \
      "STREAM PARTITION DRIFT: with $harness $version still running and only its publisher silenced, the endpoint classifies '$state' rather than 'unreadable'. A partitioned worker that reads dead can be torn down while it is healthy."
    note "$harness $version: a silenced publisher reads unreadable, not dead"
  else
    note "$harness $version: publisher pid not found, partition case unverified for this harness"
  fi

  fm_backend_kill stream "$target" || true
  CHECKED=$((CHECKED + 1))
done

note "checked $CHECKED installed harness(es)"
[ -n "$SKIPPED" ] && note "unverified here:$SKIPPED"
[ "$CHECKED" -gt 0 ] || fail \
  "this guard checked no harness at all, so it proves nothing; install at least one verified harness or disable it explicitly."
pass "stream liveness: every installed harness is attributable through the hub, and a partition is never read as death"
