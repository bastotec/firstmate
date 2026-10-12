#!/usr/bin/env bash
# tests/fm-approval.test.sh - per-machine approval gates: the Deck pre_tool_use
# gate, one-time exact-match grants, denial, policy editing and hook install.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

APPROVAL="$ROOT/bin/fm-approval.sh"
TMP_ROOT=$(fm_test_tmproot fm-approval-tests)
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# world <name>: a machine dir (policy + hooks) and a home with state/, plus a
# fake fm-send that records what it was asked to deliver.
world() {
  local w="$TMP_ROOT/$1"
  mkdir -p "$w/agents" "$w/home/state" "$w/bin"
  cat > "$w/bin/fm-send.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$FM_HOME" "$1" "$2" >> "$(dirname "$0")/sent.log"
EOF
  chmod +x "$w/bin/fm-send.sh"
  printf '%s\n' "$w"
}

ap() {  # <world> <args...>
  local w=$1
  shift
  FM_APPROVAL_POLICY="${FM_APPROVAL_POLICY:-$w/agents/approvals.json}" FM_DECK_HOOKS="${FM_DECK_HOOKS:-$w/agents/deck.hooks.json}" \
    FM_APPROVAL_SEND="$w/bin/fm-send.sh" FM_MACHINE=testbox FM_HOME="$w/home" \
    FM_APPROVAL_NOW="${NOW:-1760000000}" "$APPROVAL" "$@"
}

# gate <world> <agent> <tool> <args-json>: run the hook as Deck does; prints stderr, returns its exit.
gate() {
  local w=$1 agent=$2 tool=$3 args=$4
  (cd "$w/home" && printf '{"hook_event_name":"pre_tool_use","session_id":"s-1","tool_name":"%s","tool_call_id":"c1","args":%s}' \
      "$tool" "$args" | FM_APPROVAL_AGENT="$agent" FM_APPROVAL_HOME="$w/home" ap "$w" gate 2>&1)
}

SLACK='{"command":"agent-slack message send C123 \"hello team\""}'

pending_ids() { find "$1/home/state/approvals" -maxdepth 1 -name 'ap-*.json' 2>/dev/null | sed 's#.*/##; s#\.json$##' | sort; }

test_no_policy_or_no_gates_lets_everything_through() {
  local w out
  w=$(world none)
  out=$(gate "$w" t1 run_command "$SLACK") || fail "no policy must allow: $out"
  printf '{"version":1,"gates":[]}' > "$w/agents/approvals.json"
  out=$(gate "$w" t1 run_command "$SLACK") || fail "empty gates must allow: $out"
  assert_equals '' "$(pending_ids "$w")" "nothing filed without gates"
  pass "no policy or no gates gates nothing"
}

test_policy_without_gates_supports_all_policy_commands() {
  local w out
  w=$(world defaultgates)
  printf '{"version":1,"machine":"work-mac"}' > "$w/agents/approvals.json"
  gate "$w" t1 run_command "$SLACK" >/dev/null || fail "omitted gates must allow"
  assert_equals '[]' "$(ap "$w" policy --json | jq -c .gates)" "policy normalizes omitted gates"
  assert_equals '[]' "$(ap "$w" status --json | jq -c .gates)" "status reports no gates"
  ap "$w" disable slack-send >/dev/null || fail "disable with omitted gates"
  assert_equals '[]' "$(jq -c .gates "$w/agents/approvals.json")" "disable saves empty gates"
  printf '{"version":1,"machine":"work-mac"}' > "$w/agents/approvals.json"
  out=$(ap "$w" enable slack-send) || fail "enable with omitted gates: $out"
  assert_equals work-mac "$(jq -r .machine "$w/agents/approvals.json")" "machine identity preserved"
  assert_equals 2 "$(jq '.gates | length' "$w/agents/approvals.json")" "both Slack gates enabled"
  ap "$w" disable slack-send >/dev/null || fail "disable enabled gates"
  gate "$w" t1 run_command "$SLACK" >/dev/null || fail "disabled gates must allow"
  pass "omitted gates have the same default across policy commands"
}

test_matching_call_is_blocked_and_filed_other_calls_pass() {
  local w out rc id mode
  w=$(world block)
  ap "$w" enable slack-send >/dev/null || fail "enable slack-send"
  out=$(gate "$w" t1 run_command '{"command":"ls -la"}') || fail "non-matching command blocked: $out"
  out=$(gate "$w" t1 run_command '{"command":"agent-slack message list C123"}') || fail "slack read blocked: $out"
  rc=0; out=$(gate "$w" t1 run_command "$SLACK") || rc=$?
  assert_equals 2 "$rc" "slack send exits 2"
  id=$(pending_ids "$w")
  [ -n "$id" ] || fail "no request filed"
  assert_contains "$out" "$id" "message names the request"
  assert_contains "$out" "Do not retry it" "message forbids retrying"
  mode=$(python3 -c 'import os, stat, sys; print(format(stat.S_IMODE(os.stat(sys.argv[1]).st_mode), "o"))' "$w/home/state/approvals/$id.json")
  assert_equals 600 "$mode" "request file is private"
  assert_equals t1 "$(jq -r .agent "$w/home/state/approvals/$id.json")" "agent recorded"
  assert_equals testbox "$(jq -r .machine "$w/home/state/approvals/$id.json")" "machine recorded"
  assert_equals "$(cd "$w/home" && pwd -P)" "$(jq -r .cwd "$w/home/state/approvals/$id.json")" "cwd recorded"
  assert_equals 'agent-slack message send C123 "hello team"' "$(jq -r .args.command "$w/home/state/approvals/$id.json")" "exact command recorded"
  assert_equals requested "$(jq -r .event "$w/home/state/approvals.log")" "audited"
  rc=0; out=$(gate "$w" t1 run_command "$SLACK") || rc=$?
  assert_equals 2 "$rc" "retry still blocked"
  assert_contains "$out" "Still blocked" "retry says still blocked"
  assert_equals "$id" "$(pending_ids "$w")" "retry reuses the pending request"
  pass "a gated call is blocked and filed once; other calls pass"
}

test_approval_lets_exactly_that_call_through_once() {
  local w id rc out args replay
  w=$(world approve)
  args=$(printf '%s' "$SLACK" | jq -c '. + {cwd:"subdir",timeout_secs:30}')
  ap "$w" enable slack-send >/dev/null
  gate "$w" t1 run_command "$args" >/dev/null
  id=$(pending_ids "$w")
  out=$(ap "$w" answer "$id" --approve) || fail "approve failed: $out"
  assert_contains "$(cat "$w/bin/sent.log")" "approved: run request $id now" "agent steered"
  replay=$(awk '/^run_command / { sub(/^run_command /, ""); print }' "$w/bin/sent.log")
  assert_equals "$(printf '%s' "$args" | jq -Sc .)" "$(printf '%s' "$replay" | jq -Sc .)" "steer carries all original arguments"
  assert_contains "$(cat "$w/bin/sent.log")" "effective working directory $(cd "$w/home" && pwd -P)/subdir" "effective cwd shown separately"
  assert_equals '' "$(pending_ids "$w")" "no longer pending"
  rc=0; gate "$w" t2 run_command "$args" >/dev/null || rc=$?
  assert_equals 2 "$rc" "another agent cannot use the grant"
  rc=0; gate "$w" t1 run_command "$(printf '%s' "$args" | jq -c '.command = "agent-slack message send C123 \"hello all\""')" >/dev/null || rc=$?
  assert_equals 2 "$rc" "different text is not approved"
  rc=0; (cd "$w" && printf '{"tool_name":"run_command","args":%s}' "$args" | FM_APPROVAL_AGENT=t1 FM_APPROVAL_HOME="$w/home" ap "$w" gate >/dev/null 2>&1) || rc=$?
  assert_equals 2 "$rc" "different working directory is not approved"
  rc=0; gate "$w" t1 run_command "$SLACK" >/dev/null || rc=$?
  assert_equals 2 "$rc" "omitting execution options is not approved"
  gate "$w" t1 run_command "$replay" >/dev/null || fail "replayed approved call was blocked"
  rc=0; gate "$w" t1 run_command "$replay" >/dev/null || rc=$?
  assert_equals 2 "$rc" "grant is single use"
  assert_grep '"event":"used"' "$w/home/state/approvals.log" "use audited"
  pass "approve lets exactly that call through once"
}

test_grant_expires() {
  local w id rc
  w=$(world expire)
  ap "$w" enable slack-send >/dev/null
  gate "$w" t1 run_command "$SLACK" >/dev/null
  id=$(pending_ids "$w")
  ap "$w" answer "$id" --approve --no-steer >/dev/null
  rc=0; NOW=1760000901 gate "$w" t1 run_command "$SLACK" >/dev/null || rc=$?
  assert_equals 2 "$rc" "expired grant does not allow"
  assert_grep '"event":"expired-grant"' "$w/home/state/approvals.log" "expiry audited"
  pass "an unused grant expires"
}

test_deny_steers_and_keeps_blocking() {
  local w id rc out
  w=$(world deny)
  ap "$w" enable slack-send >/dev/null
  gate "$w" t1 run_command "$SLACK" >/dev/null
  id=$(pending_ids "$w")
  rc=0; ap "$w" answer "$id" --deny --note text >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "unrequested note option is rejected"
  assert_equals "$id" "$(pending_ids "$w")" "invalid option leaves request pending"
  out=$(ap "$w" answer "$id" --deny --json) || fail "deny failed"
  assert_equals denied "$(printf '%s' "$out" | jq -r .status)" "json status"
  assert_equals false "$(jq 'has("note")' "$w/home/state/approvals/answered/$id.json")" "answer has no annotation field"
  assert_equals false "$(jq -s 'any(.[]; has("note"))' "$w/home/state/approvals.log")" "audit has no annotation field"
  assert_contains "$(cat "$w/bin/sent.log")" "denied: request $id" "agent told denied"
  rc=0; gate "$w" t1 run_command "$SLACK" >/dev/null || rc=$?
  assert_equals 2 "$rc" "denied call stays blocked"
  rc=0; ap "$w" answer "$id" --approve >/dev/null 2>&1 || rc=$?
  assert_equals 3 "$rc" "an answered request cannot be answered again"
  assert_grep '"event":"denied"' "$w/home/state/approvals.log" "denial audited"
  pass "deny steers the agent and the call stays blocked"
}

test_no_steer_json_hands_back_the_steer_text() {
  local w id out args text replay
  w=$(world nosteer)
  args=$(printf '%s' "$SLACK" | jq -c '. + {cwd:"subdir",timeout_secs:30}')
  ap "$w" enable slack-send >/dev/null
  gate "$w" t1 run_command "$args" >/dev/null
  id=$(pending_ids "$w")
  out=$(ap "$w" answer "$id" --approve --no-steer --json) || fail "answer failed"
  assert_equals false "$(printf '%s' "$out" | jq -r .steered)" "not steered"
  text=$(printf '%s' "$out" | jq -r .steer)
  assert_contains "$text" "approved: run request $id now" "steer text returned"
  replay=$(printf '%s\n' "$text" | awk '/^run_command / { sub(/^run_command /, ""); print }')
  assert_equals "$(printf '%s' "$args" | jq -Sc .)" "$(printf '%s' "$replay" | jq -Sc .)" "returned steer preserves all arguments"
  assert_contains "$text" "effective working directory $(cd "$w/home" && pwd -P)/subdir" "effective cwd returned separately"
  gate "$w" t1 run_command "$replay" >/dev/null || fail "returned exact call was blocked"
  assert_absent "$w/bin/sent.log" "nothing sent"
  pass "--no-steer --json returns the steer for another route"
}

test_bad_policy_fails_closed() {
  local w rc out
  w=$(world bad)
  printf '{"gates": [' > "$w/agents/approvals.json"
  rc=0; out=$(gate "$w" t1 run_command '{"command":"ls"}') || rc=$?
  assert_equals 2 "$rc" "unreadable policy blocks"
  assert_contains "$out" "cannot be read" "says why"
  printf '{"gates":[{"id":"x","tool":"run_command","pattern":"("}]}' > "$w/agents/approvals.json"
  rc=0; gate "$w" t1 run_command '{"command":"ls"}' >/dev/null || rc=$?
  assert_equals 2 "$rc" "bad regex blocks"
  pass "a broken policy fails closed"
}

test_gated_call_without_a_home_is_blocked() {
  local w rc out
  w=$(world nohome)
  ap "$w" enable whatsapp-send >/dev/null
  rc=0; out=$(cd "$w" && printf '{"tool_name":"run_command","args":{"command":"wacli send text --to 1 hi"}}' | ap "$w" gate 2>&1) || rc=$?
  assert_equals 2 "$rc" "blocked without a home"
  assert_contains "$out" "no Firstmate home" "says why"
  pass "a gated call with nowhere to file is still blocked"
}

test_mcp_tool_glob_and_presets() {
  local w rc
  w=$(world presets)
  ap "$w" enable slack-send gh-pr-write gh-issue-comment gmail-send git-push-protected >/dev/null
  for c in 'gh pr comment 5 --body hi' 'gh-axi pr merge 7' 'gh issue comment 3 -b x' \
           'gog gmail send --to a@b.c' 'git push origin main' 'git push origin HEAD:master'; do
    rc=0; gate "$w" t1 run_command "{\"command\":\"$c\"}" >/dev/null || rc=$?
    assert_equals 2 "$rc" "gated: $c"
  done
  for c in 'gh pr view 5' 'gh pr list' 'git push origin fm/feature' 'gog gmail search x'; do
    gate "$w" t1 run_command "{\"command\":\"$c\"}" >/dev/null || fail "wrongly gated: $c"
  done
  rc=0; gate "$w" t1 mcp__slack__slack_send_message '{"channel":"C1","text":"hi"}' >/dev/null || rc=$?
  assert_equals 2 "$rc" "slack MCP send gated by tool glob"
  gate "$w" t1 mcp__slack__slack_read_channel '{"channel":"C1"}' >/dev/null || fail "slack MCP read gated"
  ap "$w" disable slack-send >/dev/null
  gate "$w" t1 mcp__slack__slack_send_message '{"channel":"C1","text":"hi"}' >/dev/null || fail "disable left the MCP gate"
  pass "presets and MCP tool globs gate what they name and nothing else"
}

test_install_hook_merges_and_is_idempotent() {
  local w
  w=$(world hook)
  printf '{"hooks":{"pre_tool_use":[{"matcher":"run_command","command":"./guard.sh"}],"session_end":[{"command":"x"}]}}' \
    > "$w/agents/deck.hooks.json"
  ap "$w" install-hook >/dev/null || fail "install-hook failed"
  ap "$w" install-hook >/dev/null || fail "second install-hook failed"
  assert_equals 2 "$(jq '.hooks.pre_tool_use | length' "$w/agents/deck.hooks.json")" "one gate plus the existing guard"
  assert_contains "$(jq -r '.hooks.pre_tool_use[0].command' "$w/agents/deck.hooks.json")" "fm-approval.sh\" gate" "gate first"
  assert_equals x "$(jq -r '.hooks.session_end[0].command' "$w/agents/deck.hooks.json")" "other events kept"
  assert_equals true "$(ap "$w" status --json | jq -r .hook_installed)" "status sees the hook"
  pass "install-hook merges into deck.hooks.json once"
}

test_installed_hook_command_runs_the_gate() {
  local w cmd rc
  w=$(world hookrun)
  ap "$w" install-hook >/dev/null
  ap "$w" enable slack-send >/dev/null
  cmd=$(jq -r '.hooks.pre_tool_use[0].command' "$w/agents/deck.hooks.json")
  rc=0
  (cd "$w/home" && printf '{"tool_name":"run_command","args":%s}' "$SLACK" \
    | FM_APPROVAL_POLICY="$w/agents/approvals.json" FM_APPROVAL_AGENT=t1 FM_APPROVAL_HOME="$w/home" \
      bash -lc "$cmd" >/dev/null 2>&1) || rc=$?
  assert_equals 2 "$rc" "the installed command blocks like the gate"
  pass "the installed hook command is the gate"
}

# The real thing: `deck run` against a fake gateway, with the gate installed in a
# throwaway HOME's ~/.agents/deck.hooks.json and a fake agent-slack that logs sends.
test_real_deck_blocks_then_runs_once_after_approval() {
  local deck w port i id sends
  deck=$(command -v "${FM_DECK_BIN:-deck}" 2>/dev/null) || { pass "skip: no deck binary for the end-to-end case"; return 0; }
  w=$(world e2e)
  mkdir -p "$w/fake/.agents" "$w/fakebin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\n' "$w/slack-sends.log" > "$w/fakebin/agent-slack"
  chmod +x "$w/fakebin/agent-slack"
  python3 "$ROOT/tests/assets/fake-responses-gateway.py" "$w/port" "$w/gateway.log" \
    '{"command":"agent-slack message send C123 hello-from-deck"}' &
  fm_test_track_helper_pid $!
  for ((i=0; i<50; i++)); do [ -s "$w/port" ] && break; sleep 0.1; done
  port=$(cat "$w/port") || fail "gateway did not start"
  deckrun() {
    (cd "$w/home" && HOME="$w/fake" PROXAI_API_KEY=fake-test-key PATH="$w/fakebin:$PATH" DECK_STATE="$w/deck-state" \
      FM_APPROVAL_POLICY="$w/fake/.agents/approvals.json" FM_DECK_HOOKS="$w/fake/.agents/deck.hooks.json" \
      FM_APPROVAL_AGENT=t1 FM_APPROVAL_HOME="$w/home" FM_MACHINE=testbox \
      "$deck" run --ephemeral --base-url "http://127.0.0.1:$port/v1" --model fake --max-turns 3 \
        --deadline-secs 60 "send the message" > "$w/deck.out" 2> "$w/deck.err") || true
  }
  FM_DECK_HOOKS="$w/fake/.agents/deck.hooks.json" ap "$w" install-hook >/dev/null
  FM_APPROVAL_POLICY="$w/fake/.agents/approvals.json" ap "$w" enable slack-send >/dev/null
  w_policy() { NOW=$(date +%s) FM_APPROVAL_POLICY="$w/fake/.agents/approvals.json" ap "$w" "$@"; }

  deckrun
  assert_absent "$w/slack-sends.log" "blocked before approval: $(cat "$w/deck.err")"
  id=$(pending_ids "$w")
  [ -n "$id" ] || fail "deck run filed no request: $(cat "$w/deck.err")"
  assert_grep "Request $id is waiting" "$w/gateway.log" "the model was told it is blocked"

  w_policy answer "$id" --approve >/dev/null || fail "approve failed"
  deckrun
  assert_equals "message send C123 hello-from-deck" "$(cat "$w/slack-sends.log" 2>/dev/null)" "approved call ran"
  deckrun
  sends=$(wc -l < "$w/slack-sends.log" | tr -d ' ')
  assert_equals 1 "$sends" "approved call ran exactly once"

  id=$(pending_ids "$w")
  [ -n "$id" ] || fail "third run filed no new request"
  w_policy answer "$id" --deny >/dev/null || fail "deny failed"
  deckrun
  sends=$(wc -l < "$w/slack-sends.log" | tr -d ' ')
  assert_equals 1 "$sends" "denied call never ran"
  pass "real deck: blocked, approved once runs once, denied never runs"
}

test_no_policy_or_no_gates_lets_everything_through
test_policy_without_gates_supports_all_policy_commands
test_matching_call_is_blocked_and_filed_other_calls_pass
test_approval_lets_exactly_that_call_through_once
test_grant_expires
test_deny_steers_and_keeps_blocking
test_no_steer_json_hands_back_the_steer_text
test_bad_policy_fails_closed
test_gated_call_without_a_home_is_blocked
test_mcp_tool_glob_and_presets
test_install_hook_merges_and_is_idempotent
test_installed_hook_command_runs_the_gate
test_real_deck_blocks_then_runs_once_after_approval
