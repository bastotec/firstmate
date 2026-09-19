#!/usr/bin/env bash
# tests/fm-stream-claude-tail.test.sh - tests for the Claude Code transcript
# tail shim (bin/fm-stream-claude-tail.py).
#
# The parser is pinned by `summarize` on synthetic transcripts shaped like the
# real thing: streamed blocks that repeat one message id, a resumed session
# that rewrites shared history into a new file, a usage line that grows as it
# is appended, and a line still missing its newline. The serve path runs
# against a REAL hub on an ephemeral loopback port - registered, published to,
# restarted, and closed through the hub's own routes - because what is being
# proven is that the hub accepts the shim exactly as it accepts an agent.
#
# Ambient stream configuration must never reach these cases: every serve call
# passes an explicit hub, token file, and machine, the ambient variables are
# unset for the whole file, and the one case that exercises config resolution
# points FM_HOME at a case-local home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required by the stream backend)"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found (required by the stream backend)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the stream backend)"; exit 0; }

# The live hub on this host may be running; nothing here may reach it, let
# alone publish to it, so its configuration never resolves for any case.
unset FM_STREAM_HUB FM_STREAM_TOKEN FM_STREAM_MACHINE

TMP_ROOT=$(fm_test_tmproot fm-stream-claude-tail-tests)
SHIM="$ROOT/bin/fm-stream-claude-tail.py"
HUB="$ROOT/bin/fm-stream-hub.py"
PUBLISH_TOKEN="pub-$$"
VIEW_TOKEN="view-$$"
CASE_DIR=""
URL=""
HUB_PID=""
SHIM_PID=""

cleanup_helpers() {
  [ -n "$SHIM_PID" ] && kill "$SHIM_PID" 2>/dev/null
  fm_test_reap_helper_pids
}
trap 'cleanup_helpers; fm_test_cleanup' EXIT INT TERM

# start_hub <case-name> [port] -> sets CASE_DIR URL HUB_PID. A passed port is
# how a restarted hub comes back on the exact port the shim still holds.
start_hub() {
  local name=$1 port=${2:-0} ready waited=0 host pid
  [ -n "$SHIM_PID" ] && { kill "$SHIM_PID" 2>/dev/null; SHIM_PID=""; }
  if [ -n "${HUB_PID:-}" ]; then
    kill "$HUB_PID" 2>/dev/null
    waited=0
    while [ "$waited" -lt 50 ] && kill -0 "$HUB_PID" 2>/dev/null; do
      sleep 0.1
      waited=$((waited + 1))
    done
    kill -9 "$HUB_PID" 2>/dev/null
  fi
  CASE_DIR="$TMP_ROOT/$name"
  mkdir -p "$CASE_DIR"
  printf 'publish:%s\nsubscribe,control:%s\n' "$PUBLISH_TOKEN" "$VIEW_TOKEN" > "$CASE_DIR/tokens"
  printf '%s\n' "$PUBLISH_TOKEN" > "$CASE_DIR/publish-token"
  chmod 600 "$CASE_DIR/tokens" "$CASE_DIR/publish-token"
  ready="$CASE_DIR/hub.ready"
  rm -f "$ready"
  python3 "$HUB" serve --bind 127.0.0.1 --port "$port" \
    --token-file "$CASE_DIR/tokens" --ready-file "$ready" > "$CASE_DIR/hub.log" 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true
  fm_test_track_helper_pid "$pid"
  HUB_PID=$pid
  waited=0
  while [ "$waited" -lt 100 ]; do
    [ -s "$ready" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$ready" ] || fail "hub did not report ready for case $name: $(cat "$CASE_DIR/hub.log" 2>/dev/null)"
  read -r host port < "$ready"
  URL="http://$host:$port"
}

# assistant_line <id> <input> <output> <cache-creation> <cache-read>
# The usage shape Claude Code writes per streamed block, one line per call.
assistant_line() {
  jq -nc --arg id "$1" --argjson i "$2" --argjson o "$3" --argjson c "$4" --argjson r "$5" \
    '{type: "assistant", uuid: ("u-" + $id), message: {id: $id, usage: {
       input_tokens: $i, output_tokens: $o,
       cache_creation_input_tokens: $c, cache_read_input_tokens: $r}}}'
}

user_line() {
  jq -nc '{type: "user", message: {role: "user", content: "hello"}}'
}

# start_shim <args...> - the shim under test, on this case's hub. The pid is
# reaped by the trap; individual cases end it deliberately.
start_shim() {
  python3 "$SHIM" serve --hub "$URL" --token-file "$CASE_DIR/publish-token" \
    --machine tailmachine --heartbeat-secs 0.5 --poll-secs 0.1 "$@" \
    > "$CASE_DIR/shim.log" 2>&1 &
  SHIM_PID=$!
  disown "$SHIM_PID" 2>/dev/null || true
  fm_test_track_helper_pid "$SHIM_PID"
}

wait_for() {  # <description> <timeout-secs> <test-command...>
  # The command is re-run per iteration, so a condition that reads live
  # state must be passed as a command (tokens_reached, shim_exited), not
  # pre-expanded through a command substitution at the call site.
  local what=$1 timeout=$2 waited=0
  shift 2
  while [ "$waited" -lt $((timeout * 10)) ]; do
    "$@" && return 0
    sleep 0.1
    waited=$((waited + 1))
  done
  fail "$what (waited ${timeout}s)"
}

# tokens_reached <state-file> <expected-tokens-json> - true once the shim's
# last published frame carries these cumulative counters.
tokens_reached() {
  [ "$(tokens_of "$1")" = "$2" ]
}

# shim_exited <pid> - true once the process is gone.
shim_exited() {
  ! kill -0 "$1" 2>/dev/null
}

wait_for_shim_ready() {
  wait_for "the shim never registered" 15 test -s "$CASE_DIR/shim.ready"
}

state_field() {  # <file> <jq-expression>
  jq -r "$2" "$1" 2>/dev/null
}

tokens_of() {  # <state-file>
  jq -cS .tokens "$1" 2>/dev/null
}

hub_json() {  # <path>
  curl -sS -m 10 -H "Authorization: Bearer $VIEW_TOKEN" "$URL$1"
}

endpoint_of() {
  cut -d' ' -f2 "$CASE_DIR/shim.ready"
}

test_summarize_counts_each_message_once_at_its_largest_usage() {
  local dir="$TMP_ROOT/summarize-one"
  mkdir -p "$dir"
  {
    user_line
    assistant_line msg-a 10 100 5 1000
    assistant_line msg-a 10 100 5 1000   # a second streamed block, same message
    assistant_line msg-b 20 200 6 2000
    assistant_line msg-b 20 350 6 2000   # the completed usage, larger
  } > "$dir/session.jsonl"
  # A line still being written: no newline yet, so it is nobody's record.
  printf '%s' "$(assistant_line msg-c 1 1 1 1)" >> "$dir/session.jsonl"
  local out
  out=$(python3 "$SHIM" summarize --transcript "$dir/session.jsonl")
  assert_equals 2 "$(printf '%s' "$out" | jq -r .messages)" \
    "each unique message id counts once, whatever its blocks"
  assert_equals 450 "$(printf '%s' "$out" | jq -r .tokens.output)" \
    "one id's usage counts at its largest seen value, once"
  assert_equals 30 "$(printf '%s' "$out" | jq -r .tokens.input)" "input totals"
  assert_equals 3000 "$(printf '%s' "$out" | jq -r .tokens.cache_read)" "cache read totals"
  # Completing the line makes it a record.
  printf '\n' >> "$dir/session.jsonl"
  out=$(python3 "$SHIM" summarize --transcript "$dir/session.jsonl")
  assert_equals 3 "$(printf '%s' "$out" | jq -r .messages)" \
    "a line counts once its newline has arrived"
}

test_summarize_across_sessions_dedupes_shared_history() {
  local dir="$TMP_ROOT/summarize-dir"
  mkdir -p "$dir"
  {
    assistant_line msg-a 10 100 5 1000
  } > "$dir/first-session.jsonl"
  sleep 0.05
  # A resume: the prior message rewritten under its own id, plus new work.
  {
    assistant_line msg-a 10 100 5 1000
    assistant_line msg-b 20 200 6 2000
  } > "$dir/second-session.jsonl"
  local out
  out=$(python3 "$SHIM" summarize --project-dir "$dir")
  assert_equals 2 "$(printf '%s' "$out" | jq -r .messages)" \
    "history a resume rewrites is not counted again"
  assert_equals 300 "$(printf '%s' "$out" | jq -r .tokens.output)" \
    "totals are the union of both sessions' messages"
}

test_serve_publishes_cumulative_counters_from_real_records_only() {
  start_hub counters
  mkdir -p "$CASE_DIR/proj"
  {
    assistant_line msg-a 10 100 5 1000
    assistant_line msg-a 10 100 5 1000
  } > "$CASE_DIR/proj/session.jsonl"
  start_shim --project-dir "$CASE_DIR/proj" --label task-counters \
    --ready-file "$CASE_DIR/shim.ready" --state-file "$CASE_DIR/shim.state"
  wait_for_shim_ready
  assert_equals '{"cache_creation":5,"cache_read":1000,"input":10,"output":100}' \
    "$(tokens_of "$CASE_DIR/shim.state")" \
    "the baseline is the transcript's cumulative usage, deduplicated"
  local seq_before
  seq_before=$(state_field "$CASE_DIR/shim.state" .seq)
  # Records that are not usage: a user turn, and an assistant line with no
  # newline yet. Neither may move a counter.
  user_line >> "$CASE_DIR/proj/session.jsonl"
  printf '%s' "$(assistant_line msg-b 20 200 6 2000)" >> "$CASE_DIR/proj/session.jsonl"
  sleep 1.5
  assert_equals '{"cache_creation":5,"cache_read":1000,"input":10,"output":100}' \
    "$(tokens_of "$CASE_DIR/shim.state")" \
    "heartbeats during idle never count as usage"
  local seq_during
  seq_during=$(state_field "$CASE_DIR/shim.state" .seq)
  [ "$seq_during" -gt "$seq_before" ] \
    || fail "the idle heartbeats never republished (seq stuck at $seq_before)"
  # Completing the partial line makes it real.
  printf '\n' >> "$CASE_DIR/proj/session.jsonl"
  wait_for "the completed record was never counted" 10 \
    tokens_reached "$CASE_DIR/shim.state" '{"cache_creation":11,"cache_read":3000,"input":30,"output":300}'
  assert_equals 2 "$(state_field "$CASE_DIR/shim.state" .messages)" \
    "the published message count follows unique messages"
}

test_serve_lists_on_the_hub_and_closes_as_its_own_agent() {
  start_hub listing
  mkdir -p "$CASE_DIR/proj"
  assistant_line msg-a 1 2 3 4 > "$CASE_DIR/proj/session.jsonl"
  start_shim --project-dir "$CASE_DIR/proj" --label task-listed \
    --ready-file "$CASE_DIR/shim.ready" --state-file "$CASE_DIR/shim.state"
  wait_for_shim_ready
  local listed
  listed=$(hub_json /v1/tasks | jq -r '.tasks[] | select(.machine == "tailmachine" and .label == "task-listed") | .endpoint_id')
  assert_equals "$(endpoint_of)" "$listed" \
    "the shim's endpoint is listed under its machine and label, like any worker"
  kill -TERM "$SHIM_PID"
  wait_for "the shim never exited" 15 shim_exited "$SHIM_PID"
  wait "$SHIM_PID" 2>/dev/null
  SHIM_PID=""
  local closed
  closed=$(hub_json "/v1/tasks/$(endpoint_of)" | jq -r '.task.closed_by')
  assert_equals agent "$closed" \
    "a signalled shim closes its own record, so the Bridge renders it Stopped"
}

test_serve_rotates_to_a_new_session_id() {
  start_hub rotate
  mkdir -p "$CASE_DIR/proj"
  assistant_line msg-a 10 100 5 1000 > "$CASE_DIR/proj/aaaa.jsonl"
  start_shim --project-dir "$CASE_DIR/proj" --label task-rotate \
    --ready-file "$CASE_DIR/shim.ready" --state-file "$CASE_DIR/shim.state"
  wait_for_shim_ready
  # A new session id: the shared history rewritten under its own ids, plus
  # one new message. The leaf's counters accumulate across the rotation.
  sleep 0.1
  {
    assistant_line msg-a 10 100 5 1000
    assistant_line msg-b 50 500 50 5000
  } > "$CASE_DIR/proj/bbbb.jsonl"
  wait_for "the rotated session was never followed" 10 \
    tokens_reached "$CASE_DIR/shim.state" '{"cache_creation":55,"cache_read":6000,"input":60,"output":600}'
  assert_equals 2 "$(state_field "$CASE_DIR/shim.state" .messages)" \
    "history the new session rewrites is not a second message"
}

test_serve_survives_a_truncated_rewrite() {
  start_hub truncate
  mkdir -p "$CASE_DIR/proj"
  {
    assistant_line msg-a 10 100 5 1000
    assistant_line msg-b 20 200 6 2000
  } > "$CASE_DIR/proj/session.jsonl"
  start_shim --project-dir "$CASE_DIR/proj" --label task-truncate \
    --ready-file "$CASE_DIR/shim.ready" --state-file "$CASE_DIR/shim.state"
  wait_for_shim_ready
  local before
  before=$(tokens_of "$CASE_DIR/shim.state")
  # The file rewritten smaller: the shim rereads it from the start, and the
  # id set makes that idempotent - the surviving history is not counted a
  # second time, and cumulative counters never run backwards.
  assistant_line msg-a 10 100 5 1000 > "$CASE_DIR/proj/session.jsonl.tmp"
  mv "$CASE_DIR/proj/session.jsonl.tmp" "$CASE_DIR/proj/session.jsonl"
  sleep 1
  assert_equals "$before" "$(tokens_of "$CASE_DIR/shim.state")" \
    "a truncated rewrite counts the surviving history once, never twice"
  assistant_line msg-c 1 1 1 1 >> "$CASE_DIR/proj/session.jsonl"
  wait_for "the shim stopped following after truncation" 10 \
    tokens_reached "$CASE_DIR/shim.state" '{"cache_creation":12,"cache_read":3001,"input":31,"output":301}'
}

test_serve_rejoins_after_the_hub_restarts() {
  start_hub rejoin
  local transcript="$CASE_DIR/proj/session.jsonl"
  mkdir -p "$CASE_DIR/proj"
  assistant_line msg-a 10 100 5 1000 > "$transcript"
  start_shim --project-dir "$CASE_DIR/proj" --label task-rejoin \
    --ready-file "$CASE_DIR/shim.ready" --state-file "$CASE_DIR/shim.state"
  wait_for_shim_ready
  local port state_file="$CASE_DIR/shim.state" ready="$CASE_DIR/shim.ready"
  port=$(printf '%s' "$URL" | sed 's|.*:||')
  kill "$HUB_PID"
  wait_for "the hub never went down" 15 shim_exited "$HUB_PID"
  HUB_PID=""
  # The shim must survive this restart, and start_hub ends the previous
  # case's shim as a matter of hygiene, so it is taken out of that path
  # here; the cleanup trap still holds its pid.
  SHIM_PID=""
  # Same port, same tokens: the hub every running shim still holds.
  start_hub rejoin-back "$port"
  sleep 1
  assistant_line msg-b 20 200 6 2000 >> "$transcript"
  wait_for "the shim never rejoined the restarted hub" 20 \
    tokens_reached "$state_file" '{"cache_creation":11,"cache_read":3000,"input":30,"output":300}'
  local listed
  listed=$(hub_json /v1/tasks | jq -r '.tasks[] | select(.label == "task-rejoin") | .endpoint_id')
  assert_equals "$(cut -d' ' -f2 "$ready")" "$listed" \
    "the shim rejoined under its original endpoint id, not as a stranger"
}

test_second_shim_on_one_label_stands_down() {
  start_hub superseded
  mkdir -p "$CASE_DIR/proj"
  assistant_line msg-a 10 100 5 1000 > "$CASE_DIR/proj/session.jsonl"
  start_shim --project-dir "$CASE_DIR/proj" --label task-one \
    --ready-file "$CASE_DIR/shim.ready" --state-file "$CASE_DIR/shim.state"
  wait_for_shim_ready
  # The second shim's exit status is the assertion, and a disowned child's
  # status does not survive `wait` in this shell, so the process writes its
  # own exit code to a file on its way out.
  ( python3 "$SHIM" serve --hub "$URL" --token-file "$CASE_DIR/publish-token" \
      --machine tailmachine --label task-one --project-dir "$CASE_DIR/proj" \
      --heartbeat-secs 0.5 --poll-secs 0.1; echo $? > "$CASE_DIR/shim-two.exit" \
      ) > "$CASE_DIR/shim-two.log" 2>&1 &
  local second=$!
  disown "$second" 2>/dev/null || true
  fm_test_track_helper_pid "$second"
  wait_for "the second shim never exited over the held label" 15 \
    test -s "$CASE_DIR/shim-two.exit"
  local status
  status=$(cat "$CASE_DIR/shim-two.exit")
  assert_equals 3 "$status" \
    "a shim that lost its name exits rather than shadowing the holder"
  kill -0 "$SHIM_PID" 2>/dev/null || fail "the first shim stopped when the second was refused"
  assistant_line msg-b 1 1 1 1 >> "$CASE_DIR/proj/session.jsonl"
  wait_for "the first shim stopped publishing after the contest" 10 \
    tokens_reached "$CASE_DIR/shim.state" '{"cache_creation":6,"cache_read":1001,"input":11,"output":101}'
}

test_serve_resolves_the_hub_from_home_config() {
  start_hub config-home
  mkdir -p "$CASE_DIR/proj" "$CASE_DIR/home/config" "$CASE_DIR/home/state"
  assistant_line msg-a 9 90 4 900 > "$CASE_DIR/proj/session.jsonl"
  printf '%s\n' "$URL" > "$CASE_DIR/home/config/stream-hub"
  printf '%s\n' "$PUBLISH_TOKEN" > "$CASE_DIR/home/config/stream-token"
  # No --hub, no --token-file, no ambient variables: the home's config is the
  # only place this call can learn the hub from, and it is case-local.
  FM_HOME="$CASE_DIR/home" \
    python3 "$SHIM" serve --project-dir "$CASE_DIR/proj" --label task-config \
      --machine tailmachine --heartbeat-secs 0.5 --poll-secs 0.1 \
      --ready-file "$CASE_DIR/shim.ready" --state-file "$CASE_DIR/shim.state" \
      > "$CASE_DIR/shim.log" 2>&1 &
  SHIM_PID=$!
  disown "$SHIM_PID" 2>/dev/null || true
  fm_test_track_helper_pid "$SHIM_PID"
  wait_for_shim_ready
  local listed
  listed=$(hub_json /v1/tasks | jq -r '.tasks[] | select(.label == "task-config") | .endpoint_id')
  assert_equals "$(endpoint_of)" "$listed" \
    "with no explicit hub, config/stream-hub and config/stream-token under FM_HOME resolve it"
}

test_summarize_counts_each_message_once_at_its_largest_usage
test_summarize_across_sessions_dedupes_shared_history
test_serve_publishes_cumulative_counters_from_real_records_only
test_serve_lists_on_the_hub_and_closes_as_its_own_agent
test_serve_rotates_to_a_new_session_id
test_serve_survives_a_truncated_rewrite
test_serve_rejoins_after_the_hub_restarts
test_second_shim_on_one_label_stands_down
test_serve_resolves_the_hub_from_home_config
pass "the Claude Code transcript tail shim holds its contracts"
