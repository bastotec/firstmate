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

test_policy_show_save_and_audit() {
  local w out sha rc
  w=$(world policy)
  out=$(ap "$w" policy-show --json) || fail "policy-show failed"
  assert_equals none "$(printf '%s' "$out" | jq -r .sha)" "absent policy has sha none"
  assert_equals false "$(printf '%s' "$out" | jq -r '.presets[] | select(.id=="slack-send") | .enabled')" "preset off"
  ap "$w" enable slack-send --by "tester" >/dev/null || fail "enable failed"
  out=$(ap "$w" policy-show --json)
  assert_equals true "$(printf '%s' "$out" | jq -r '.presets[] | select(.id=="slack-send") | .enabled')" "preset on"
  assert_equals true "$(printf '%s' "$out" | jq -r .hook_installed)" "enabling a gate installs the hook"
  sha=$(printf '%s' "$out" | jq -r .sha)
  # Add a custom gate and drop the MCP half of slack-send in one save.
  printf '%s' "$out" | jq '.policy | .gates = ([.gates[] | select(.id != "slack-send-2") | .description = "edited"] + [{id:"jira-write", tool:"run_command", pattern:"\\bjira\\b.*\\b(create|comment)\\b", description:"Jira writes"}])' \
    | ap "$w" policy-save --expect "$sha" --by "captain (Fleet Town)" --json > "$w/save.json" || fail "save refused: $(cat "$w/save.json")"
  assert_equals '["jira-write"]' "$(jq -c .added "$w/save.json")" "added reported"
  assert_equals '["slack-send-2"]' "$(jq -c .removed "$w/save.json")" "removed reported"
  assert_equals '["slack-send"]' "$(jq -c .changed "$w/save.json")" "edited gate reported"
  out=$(ap "$w" policy-show --json)
  assert_equals jira-write "$(printf '%s' "$out" | jq -r '.custom[0].id')" "custom gate listed"
  assert_equals false "$(printf '%s' "$out" | jq -r '.presets[] | select(.id=="slack-send") | .enabled')" "partial preset reads off"
  rc=0; gate "$w" t1 run_command '{"command":"jira issue create x"}' >/dev/null || rc=$?
  assert_equals 2 "$rc" "custom gate blocks"
  rc=0; printf '{"gates":[]}' | ap "$w" policy-save --expect "$sha" >/dev/null 2>&1 || rc=$?
  assert_equals 3 "$rc" "a stale --expect is refused"
  assert_equals jira-write "$(ap "$w" policy-show --json | jq -r '.custom[0].id')" "a refused save changes nothing"
  out=$(ap "$w" policy-audit --json)
  assert_equals 2 "$(printf '%s' "$out" | jq length)" "two audited changes"
  assert_equals "captain (Fleet Town)" "$(printf '%s' "$out" | jq -r '.[0].by')" "newest first, with who"
  assert_equals tester "$(printf '%s' "$out" | jq -r '.[1].by')" "cli --by recorded"
  assert_equals true "$(printf '%s' "$out" | jq -r '.[1].hook_installed')" "hook install audited"
  rc=0; printf '{"gates":[{"id":"bad","tool":"run_command","pattern":"("}]}' \
    | ap "$w" policy-save --expect "$(ap "$w" policy-show --json | jq -r .sha)" >/dev/null 2>&1 || rc=$?
  assert_not_equals 0 "$rc" "an invalid policy is refused"
  assert_equals jira-write "$(ap "$w" policy-show --json | jq -r '.custom[0].id')" "an invalid save changes nothing"
  pass "policy-show, locked policy-save with --expect, and the audit trail"
}

test_enable_disable_audit_real_deltas() {
  local w out sha
  w=$(world audit-deltas)
  FM_APPROVAL_AUDIT="$w/elsewhere.log" ap "$w" enable slack-send >/dev/null || fail "initial enable"
  assert_present "$w/agents/approvals-audit.log" "audit is beside the machine policy"
  assert_absent "$w/elsewhere.log" "no independent audit destination"
  sha=$(ap "$w" policy-show --json | jq -r .sha)
  ap "$w" enable gmail-send >/dev/null || fail "enable another preset"
  out=$(ap "$w" policy-audit --limit 1 --json)
  assert_equals '["gmail-send"]' "$(printf '%s' "$out" | jq -c '.[0].added')" "enable on an existing policy records additions"
  assert_equals "$sha" "$(printf '%s' "$out" | jq -r '.[0].before')" "before is the previous policy sha"
  assert_equals "$(ap "$w" policy-show --json | jq -r .sha)" "$(printf '%s' "$out" | jq -r '.[0].after')" "after is the saved policy sha"
  ap "$w" disable slack-send >/dev/null || fail "disable preset"
  out=$(ap "$w" policy-audit --limit 1 --json)
  assert_equals '["slack-send","slack-send-2"]' "$(printf '%s' "$out" | jq -c '.[0].removed')" "disable records both removed gates"
  assert_equals '[]' "$(printf '%s' "$out" | jq -c '.[0].changed')" "unchanged Gmail gate is not reported changed"
  pass "enable and disable audit the original gate snapshot"
}

test_failed_policy_save_preserves_policy() {
  local w out sha rc config audit_before
  w=$(world save-failures)
  printf '{"version":1,"gates":[]}' > "$w/agents/approvals.json"
  sha=$(ap "$w" policy-show --json | jq -r .sha)
  for config in '{bad json' '{"hooks":[]}' '{"hooks":{"pre_tool_use":{}}}'; do
    printf '%s' "$config" > "$w/agents/deck.hooks.json"
    out=$(ap "$w" policy-show --json) || fail "show with malformed hooks"
    assert_equals false "$(printf '%s' "$out" | jq -r .hook_installed)" "malformed hooks reported missing"
    rc=0
    printf '%s' "$out" | jq '.policy | .gates = [{id:"custom",tool:"run_command"}]' \
      | ap "$w" policy-save --expect "$sha" >/dev/null 2>&1 || rc=$?
    assert_equals 1 "$rc" "save refuses malformed hooks"
    assert_equals "$sha" "$(ap "$w" policy-show --json | jq -r .sha)" "failed hook installation does not stale the editor"
    assert_equals '[]' "$(ap "$w" policy-audit --json)" "no mutation audited"
    assert_equals "$config" "$(cat "$w/agents/deck.hooks.json")" "invalid hooks not overwritten"
  done
  printf '{"hooks":{}}' > "$w/agents/deck.hooks.json"
  rm "$w/agents/approvals-audit.log" || fail "remove empty audit fixture"
  mkdir "$w/agents/approvals-audit.log" || fail "audit failure setup"
  rc=0
  ap "$w" enable slack-send >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" "unopenable audit refuses enable"
  assert_equals "$sha" "$(ap "$w" policy-show --json | jq -r .sha)" "audit open failure preserves policy"
  assert_equals false "$(ap "$w" status --json | jq -r .hook_installed)" "audit open failure happens before hook installation"
  rmdir "$w/agents/approvals-audit.log"
  printf '{"gates":[{"id":"custom","tool":"run_command"}]}' \
    | ap "$w" policy-save --expect "$sha" >/dev/null || fail "same editor sha can retry successfully"
  sha=$(ap "$w" policy-show --json | jq -r .sha)
  audit_before=$(cat "$w/agents/approvals-audit.log")
  chmod 400 "$w/agents/approvals-audit.log"
  if [ ! -w "$w/agents/approvals-audit.log" ]; then
    rc=0
    ap "$w" disable custom >/dev/null 2>&1 || rc=$?
    assert_equals 1 "$rc" "non-writable existing audit refuses disable"
    assert_equals "$sha" "$(ap "$w" policy-show --json | jq -r .sha)" "non-writable audit preserves policy"
    assert_equals "$audit_before" "$(cat "$w/agents/approvals-audit.log")" "previous audit entries preserved"
  fi
  chmod 600 "$w/agents/approvals-audit.log"
  pass "hook and audit preparation failures leave policy and editor sha unchanged"
}

test_audit_append_failure_rolls_back_policy() {
  local w
  w=$(world append-failure)
  python3 - "$ROOT/bin/fm-approval.py" "$w" <<'PY' || fail "audit append rollback"
import contextlib
import importlib.util
import io
import os
import sys
from pathlib import Path
from unittest.mock import patch

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('approval', sys.argv[1])
approval = importlib.util.module_from_spec(spec)
spec.loader.exec_module(approval)
w = Path(sys.argv[2])
policy = w / 'agents' / 'approvals.json'
log = policy.parent / 'approvals-audit.log'
os.environ['FM_APPROVAL_POLICY'] = str(policy)
os.environ['FM_DECK_HOOKS'] = str(policy.parent / 'deck.hooks.json')
fdopen = os.fdopen

class FailedAudit:
    def __init__(self, file):
        self.file = file
    def __enter__(self):
        return self
    def __exit__(self, *args):
        self.file.close()
    def write(self, data):
        raise OSError('injected audit append failure')

def fail_append(fd, mode, **kwargs):
    file = fdopen(fd, mode, **kwargs)
    return FailedAudit(file) if mode == 'a' else file

for initial in (None, b'{"gates":[]}\n', b'{\r\n  "gates": []\r\n}\r\n'):
    if initial is None:
        policy.unlink(missing_ok=True)
    else:
        policy.write_bytes(initial)
    log.write_bytes(b'{"by":"previous"}\n')
    before = approval.policy_sha()
    with patch.object(approval.os, 'fdopen', side_effect=fail_append), \
         patch.object(sys, 'stdin', io.StringIO('{"gates":[]}')), \
         contextlib.redirect_stderr(io.StringIO()) as stderr:
        rc = approval.main(['policy-save', '--expect', before])
    assert rc == 1, rc
    assert 'policy unchanged' in stderr.getvalue(), stderr.getvalue()
    assert (policy.read_bytes() if policy.exists() else None) == initial
    assert log.read_bytes() == b'{"by":"previous"}\n'
    assert not (policy.parent / '.approvals.lock').exists()
    assert not list(policy.parent.glob('.*rollback.*'))
    with patch.object(sys, 'stdin', io.StringIO('{"gates":[]}')), \
         contextlib.redirect_stdout(io.StringIO()):
        assert approval.main(['policy-save', '--expect', before]) == 0
PY
  pass "audit append failure restores existing policy bytes or removes a new policy"
}

test_machine_approvals_local_and_remote() {
  local w fmh out rc
  w=$(world machine)
  fmh="$w/fmh"
  mkdir -p "$fmh/data" "$w/remote-home/.agents"
  printf -- '- box (root: %s; added 2026-10-12)\n' "$ROOT" > "$fmh/data/machines.md"
  # Fake ssh: run the remote command here as an account whose HOME is remote-home.
  # shellcheck disable=SC2016 # the fake's own variables expand when it runs.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'while [ "$#" -gt 1 ]; do case "$1" in -o) shift 2 ;; *) break ;; esac; done\n'
    printf 'printf "%%s\\n" "$1" >> %q\n' "$w/ssh.log"
    printf 'shift\n'
    printf 'HOME=%q exec bash -c "$*"\n' "$w/remote-home"
  } > "$w/bin/ssh"
  chmod +x "$w/bin/ssh"
  mm() { FM_HOME="$fmh" FM_SSH_BIN="$w/bin/ssh" FM_APPROVAL_POLICY='' FM_DECK_HOOKS='' "$ROOT/bin/fm-machine-approvals.sh" "$@"; }
  out=$(mm show box) || fail "remote show failed: $out"
  assert_equals none "$(printf '%s' "$out" | jq -r .sha)" "remote starts empty"
  assert_equals null "$(printf '%s' "$out" | jq -c .policy)" "absent stored policy is null"
  jq -n --arg home "$w/remote-home" '{version:1, home:$home, machine:"remote-box", grant_ttl_secs:120, extra:{owner:"kept"}, gates:[]}' \
    > "$w/remote-home/.agents/approvals.json"
  out=$(mm show box) || fail "remote show stored policy"
  assert_equals "$(jq -Sc . "$w/remote-home/.agents/approvals.json")" "$(printf '%s' "$out" | jq -Sc .policy)" "show exposes the complete stored policy"
  printf '%s' "$out" | jq '.policy | .gates = [{id:"whatsapp-send", tool:"run_command", pattern:"\\bwacli\\b[^\\n]*\\bsend\\b", description:"WhatsApp"}]' \
    | mm save box --expect "$(printf '%s' "$out" | jq -r .sha)" > "$w/out" || fail "remote save failed: $(cat "$w/out")"
  assert_equals box "$(head -n1 "$w/ssh.log")" "went over ssh to the alias"
  assert_present "$w/remote-home/.agents/approvals.json" "policy written on the remote account"
  assert_equals "$w/remote-home" "$(jq -r .home "$w/remote-home/.agents/approvals.json")" "editor preserves routing home"
  assert_equals remote-box "$(jq -r .machine "$w/remote-home/.agents/approvals.json")" "editor preserves machine identity"
  assert_equals 120 "$(jq -r .grant_ttl_secs "$w/remote-home/.agents/approvals.json")" "editor preserves TTL"
  assert_equals kept "$(jq -r .extra.owner "$w/remote-home/.agents/approvals.json")" "editor preserves other stored fields"
  mkdir -p "$w/remote-home/state"
  rc=0
  (unset FM_APPROVAL_HOME FM_APPROVAL_AGENT; printf '{"tool_name":"run_command","session_id":"ordinary","args":{"command":"wacli send text hi"}}' \
    | FM_APPROVAL_POLICY="$w/remote-home/.agents/approvals.json" ap "$w" gate >/dev/null 2>&1) || rc=$?
  assert_equals 2 "$rc" "ordinary Deck call is gated after editor save"
  assert_equals 1 "$(find "$w/remote-home/state/approvals" -maxdepth 1 -name 'ap-*.json' | wc -l | tr -d ' ')" "ordinary session files an approvable request using preserved home"
  assert_equals "captain (Fleet Town)" "$(mm audit box | jq -r '.[0].by')" "remote audit has who"
  rc=0; printf '{"gates":[]}' | mm save box --expect none >/dev/null 2>&1 || rc=$?
  assert_equals 3 "$rc" "remote conflict exits 3"
  rc=0; mm show nowhere >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" "unknown machine refused"
  pass "fm-machine-approvals shows, saves and audits a remote machine over ssh"
}

test_policy_save_keeps_keys_it_is_not_given() {
  local w sha
  w=$(world keys)
  printf '{"version":1,"home":"/somewhere/home","grant_ttl_secs":600,"gates":[]}' > "$w/agents/approvals.json"
  sha=$(ap "$w" policy-show --json | jq -r .sha)
  printf '{"gates":[{"id":"x","tool":"run_command","pattern":"wacli"}]}' | ap "$w" policy-save --expect "$sha" >/dev/null || fail "save refused"
  assert_equals /somewhere/home "$(jq -r .home "$w/agents/approvals.json")" "home kept"
  assert_equals 600 "$(jq -r .grant_ttl_secs "$w/agents/approvals.json")" "ttl kept"
  assert_equals x "$(jq -r '.gates[0].id' "$w/agents/approvals.json")" "gates replaced"
  pass "policy-save keeps top-level keys the editor did not send"
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
test_policy_show_save_and_audit
test_enable_disable_audit_real_deltas
test_failed_policy_save_preserves_policy
test_audit_append_failure_rolls_back_policy
test_machine_approvals_local_and_remote
test_policy_save_keeps_keys_it_is_not_given
