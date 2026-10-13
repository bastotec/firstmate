#!/usr/bin/env bash
# fm-control.sh <task> model <route>: the in-place model switch.
#
# Hermetic: a fake gateway serves /models, the task's Deck driver is
# represented by its state/<id>.deck-caps (this shell's pid) and a live turn by
# the stream receiver's descriptor and projection (bin/fm_stream_deck.py), so
# every assertion reads the files a real driver and Deck would consume.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

CONTROL="$ROOT/bin/fm-control.sh"
FAILED=0
fail() { printf 'not ok - %s\n' "$1" >&2; FAILED=1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3 (got '$1', want '$2')"; }
assert_contains() { case "$1" in *"$2"*) ;; *) fail "$3 (no '$2' in: $1)" ;; esac; }
TMP_ROOT=$(fm_test_tmproot fm-control-model)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
GATEWAY_PID=
trap '[ -z "$GATEWAY_PID" ] || kill "$GATEWAY_PID" 2>/dev/null; rm -rf "$TMP_ROOT"' EXIT

# A gateway that lists two routes.
PORT_FILE="$TMP_ROOT/port"
python3 - "$PORT_FILE" <<'EOF' &
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"data": [{"id": "zai/glm-5.3-flash"}, {"id": "codex/gpt-6.1-sol"},
                                    {"id": "claude/opus-5-5"}]}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(s.server_port))
s.serve_forever()
EOF
GATEWAY_PID=$!
for _ in $(seq 1 50); do [ -s "$PORT_FILE" ] && break; sleep 0.1; done
PORT=$(cat "$PORT_FILE")

new_case() {  # <name> -> case dir with home/state/t1.meta
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config"
  printf '%s\n' 'window=fm-t1' 'endpoint_task_id=t1' 'harness=deck' 'kind=ship' \
    'model=zai/glm-5.3-flash' 'effort=default' 'backend=stream' > "$dir/home/state/t1.meta"
  printf '{"blocked":["claude/*"],"allowed":[]}\n' > "$dir/home/config/model-policy.json"
  printf '%s\n' "$dir"
}

driver_caps() {  # <case-dir>: a live driver that switches in place
  printf 'pid=%s\nmodel_switch=1\n' "$$" > "$1/home/state/t1.deck-caps"
}

live_turn() {  # <case-dir> <set_model 0|1>: an active Deck turn on endpoint e1
  python3 "$ROOT/bin/fm_stream_deck.py" start "$1/home/state" t1 e1 turn1 1 "$2" > /dev/null
}

run_model() {  # <case-dir> <route>
  env FM_HOME="$1/home" FM_CONFIG_OVERRIDE="$1/home/config" \
    PROXAI_BASE_URL="http://127.0.0.1:$PORT/v1" PROXAI_API_KEY=test-key \
    "$CONTROL" t1 model "$2" 2>&1
}

meta_model() { sed -n 's/^model=//p' "$1/home/state/t1.meta"; }

test_live_turn_gets_the_control_after_pending_captain_records() {
  local dir out rc projection
  dir=$(new_case live)
  driver_caps "$dir"
  live_turn "$dir" 1
  # a captain record waiting in the ordinary inbox is published first
  mkdir -p "$dir/home/state/t1.inbox/handled"
  printf 'schema=1\nat=2026-10-12T00:00:00Z\n--\n[fm-captain-direct]\xe2\x81\xa3check the build' \
    > "$dir/home/state/t1.inbox/001.msg"
  out=$(run_model "$dir" codex/gpt-6.1-sol); rc=$?
  assert_eq "$rc" 0 "a live switch succeeds: $out"
  assert_contains "$out" "model t1 -> codex/gpt-6.1-sol (live)" "it says the turn takes it"
  projection="$dir/home/state/t1.inbox/deck-e1/turn1"
  assert_eq "$(cat "$projection/2.msg")" "deck-control: set_model codex/gpt-6.1-sol" "the control rides the next inbox sequence"
  assert_contains "$(cat "$projection/1.msg")" "check the build" "the earlier captain record is not overtaken"
  assert_eq "$(meta_model "$dir")" codex/gpt-6.1-sol "a later relaunch uses the choice"
  assert_eq "$(cat "$dir/home/state/t1.model")" codex/gpt-6.1-sol "the driver's next turn uses it"
  assert_contains "$(cat "$dir/home/state/t1.inbox/handled/002.msg")" \
    "[fm-control] model switch: zai/glm-5.3-flash -> codex/gpt-6.1-sol" "the switch is marked in the thread"
  assert_eq "$(find "$dir/home/state/t1.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" 1 "nothing new waits for the agent to read"
}

test_a_turn_whose_deck_cannot_take_it_switches_from_the_next_turn() {
  local dir out rc
  dir=$(new_case older-deck)
  driver_caps "$dir"
  live_turn "$dir" 0
  out=$(run_model "$dir" codex/gpt-6.1-sol); rc=$?
  assert_eq "$rc" 0 "$out"
  assert_contains "$out" "(next-turn)" "no live control for an older Deck"
  assert_eq "$(find "$dir/home/state/t1.inbox/deck-e1/turn1" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" 0 "nothing is published into that turn"
  assert_eq "$(cat "$dir/home/state/t1.model")" codex/gpt-6.1-sol "the next turn still switches"
}

test_an_older_driver_exits_3_and_changes_nothing() {
  local dir out rc
  dir=$(new_case older-driver)
  out=$(run_model "$dir" codex/gpt-6.1-sol); rc=$?
  assert_eq "$rc" 3 "an agent without in-place support asks for a relaunch: $out"
  assert_contains "$out" "relaunch it with --model codex/gpt-6.1-sol" "it names the fallback"
  assert_eq "$(meta_model "$dir")" zai/glm-5.3-flash "the record is unchanged"
  [ ! -e "$dir/home/state/t1.model" ] || fail "no switch file is written"
  # a stale capability file (its driver gone) is no better
  printf 'pid=999999\nmodel_switch=1\n' > "$dir/home/state/t1.deck-caps"
  run_model "$dir" codex/gpt-6.1-sol > /dev/null; rc=$?
  assert_eq "$rc" 3 "a dead driver's capability does not count"
}

test_policy_and_gateway_refuse_before_anything_is_written() {
  local dir out rc
  dir=$(new_case refused)
  driver_caps "$dir"
  out=$(run_model "$dir" claude/opus-5-5); rc=$?
  assert_eq "$rc" 1 "a blocked route is refused"
  assert_contains "$out" "blocked by the model policy" "with the policy as the reason"
  out=$(run_model "$dir" zai/not-served); rc=$?
  assert_eq "$rc" 1 "an unlisted route is refused"
  assert_contains "$out" "does not serve zai/not-served" "with the gateway as the reason"
  out=$(run_model "$dir" 'zai/glm;rm'); rc=$?
  assert_eq "$rc" 1 "a malformed route is refused"
  assert_eq "$(meta_model "$dir")" zai/glm-5.3-flash "the record is unchanged"
  [ ! -e "$dir/home/state/t1.model" ] || fail "no switch file is written"
}

test_usage_needs_exactly_one_route() {
  local dir rc
  dir=$(new_case usage)
  env FM_HOME="$dir/home" "$CONTROL" t1 model > /dev/null 2>&1; rc=$?
  assert_eq "$rc" 2 "a missing route is a usage error"
  env FM_HOME="$dir/home" "$CONTROL" t1 model a/b c/d > /dev/null 2>&1; rc=$?
  assert_eq "$rc" 2 "two routes are a usage error"
}

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  "$t"
done
[ "$FAILED" = 0 ] && echo "ok - fm-control model" || exit 1
