#!/usr/bin/env bash
# tests/fm-bridge.test.sh - bridge gates: seeding today's routes, deny by default
# for a newly connected machine, fm-on refusing a flow before ssh with one audited
# request, an allowed flow passing, and answering the request.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BRIDGE="$ROOT/bin/fm-bridge.sh"
TMP_ROOT=$(fm_test_tmproot fm-bridge-tests)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# home <name>: a primary home with one remote second mate on "workload" and a fake
# ssh that only logs what it was asked to run.
home() {
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/data" "$h/state" "$h/config" "$h/bin"
  printf -- '- helper - helper work (host: workload; root: /r/firstmate; home: /r/homes/helper; scope: help; projects: none; added 2026-10-01)\n' \
    > "$h/data/secondmates.md"
  # shellcheck disable=SC2016 # Variables expand when the generated SSH stub runs.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s\\n" "$*" >> %q\n' "$h/ssh.log"
    printf '%s\n' 'args=(); while IFS= read -r -d "" arg; do args+=("$arg"); done < <(printf "%s" "${!#}" | base64 -d)'
    printf '%s\n' 'case "${args[0]:-}:${args[1]:-}" in fm-machine-skills.sh:discover) printf "test-skill\\tglobal\\tdescription\\t/test/skill\\n" ;; fm-machine-instructions.sh:read-local) printf "absent\\n" ;; esac'
  } > "$h/bin/ssh"
  chmod +x "$h/bin/ssh"
  cat > "$h/bin/fm-send.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\n' "$1" "$2" >> "$(dirname "$0")/sent.log"
EOF
  chmod +x "$h/bin/fm-send.sh"
  printf '%s\n' "$h"
}

br() { local h=$1; shift; FM_HOME="$h" "$BRIDGE" "$@"; }
on() { local h=$1; shift; FM_HOME="$h" FM_SSH_BIN="$h/bin/ssh" "$ROOT/bin/fm-on.sh" "$@"; }
add_route() {  # <home> <id> <host>
  printf -- '- %s - %s work (host: %s; root: /r/firstmate; home: /r/homes/%s; scope: x; projects: none; added 2026-10-12)\n' \
    "$2" "$2" "$3" "$2" >> "$1/data/secondmates.md"
}

test_existing_bridges_are_seeded_and_shown_configured() {
  local h out
  h=$(home seed)
  out=$(br "$h" show --json) || fail "show failed"
  assert_equals 'supervision,reports,messages,placement,files,maintenance' \
    "$(printf '%s' "$out" | jq -r '.bridges[] | select(.machine=="workload") | .allow | join(",")')" "workload seeded with every flow"
  assert_equals true "$(printf '%s' "$out" | jq -r '.bridges[] | select(.machine=="workload") | .seeded')" "marked seeded"
  assert_grep '"event":"seeded"' "$h/state/bridges.log" "seeding audited"
  br "$h" check workload messages >/dev/null || fail "seeded bridge must allow messages"
  br "$h" check local placement >/dev/null || fail "local always allowed"
  pass "today's bridges are seeded with what flows now and show as configured"
}

test_new_machine_denies_everything_by_default() {
  local h rc out
  h=$(home fresh)
  br "$h" show >/dev/null
  add_route "$h" builder buildbox
  for f in supervision reports messages placement files maintenance; do
    rc=0; br "$h" check buildbox "$f" >/dev/null 2>&1 || rc=$?
    assert_equals 1 "$rc" "new machine denies $f"
  done
  out=$(br "$h" show --json)
  assert_equals false "$(printf '%s' "$out" | jq -r '.bridges[] | select(.machine=="buildbox") | .configured')" "shown as not configured"
  pass "a machine connected later allows nothing until the captain allows it"
}

test_register_records_the_flows_chosen_at_connect() {
  local h out
  h=$(home register)
  out=$(FM_HOME="$h" "$ROOT/bin/fm-machine.sh" register newbox /r/firstmate --allow supervision,reports) || fail "register failed: $out"
  assert_contains "$out" "bridge=newbox allow=supervision,reports" "register reports the bridge"
  br "$h" check newbox reports >/dev/null || fail "allowed flow refused"
  ! br "$h" check newbox placement >/dev/null 2>&1 || fail "unchosen flow allowed"
  br "$h" check workload placement >/dev/null || fail "existing bridge kept its flows"
  out=$(FM_HOME="$h" "$ROOT/bin/fm-machine.sh" register otherbox /r/firstmate) || fail "register failed"
  assert_contains "$out" "bridge=otherbox allow=none" "register without --allow allows nothing"
  pass "register records the flows chosen when connecting, none by default"
}

test_blocked_flow_is_refused_before_ssh_with_one_request() {
  local h rc err id
  h=$(home block)
  br "$h" show >/dev/null
  add_route "$h" builder buildbox
  rc=0; err=$(on "$h" builder fm-remote-secondmate-control.sh send builder "hello" 2>&1 >/dev/null) || rc=$?
  assert_equals 1 "$rc" "blocked flow exits 1"
  assert_contains "$err" "bridge-blocked:" "says it was blocked"
  assert_contains "$err" "messages" "names the flow"
  assert_absent "$h/ssh.log" "nothing crossed the bridge"
  id=$(find "$h/state/approvals" -name 'ap-*.json' | sed 's#.*/##; s#\.json$##')
  [ -n "$id" ] || fail "no request filed"
  assert_contains "$err" "$id" "message names the request"
  assert_equals bridge "$(jq -r .kind "$h/state/approvals/$id.json")" "a bridge request"
  assert_equals "bridge:messages" "$(jq -r .gate "$h/state/approvals/$id.json")" "gate names the flow"
  assert_equals buildbox "$(jq -r .args.machine "$h/state/approvals/$id.json")" "names the bridge"
  rc=0; on "$h" builder fm-remote-secondmate-control.sh send builder "again" >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" "still blocked"
  assert_equals 1 "$(find "$h/state/approvals" -name 'ap-*.json' | wc -l | tr -d ' ')" "one request per bridge and flow"
  assert_equals 2 "$(grep -c '"event":"blocked"' "$h/state/bridges.log")" "every refusal audited"
  pass "a blocked flow is refused before ssh, audited, with a single request"
}

test_allowed_flow_passes_and_others_stay_blocked() {
  local h rc
  h=$(home pass)
  br "$h" show >/dev/null
  add_route "$h" builder buildbox
  br "$h" allow buildbox supervision --by tester >/dev/null || fail "allow failed"
  on "$h" builder fm-remote-secondmate-control.sh state builder >/dev/null 2>&1 || fail "allowed supervision did not pass"
  assert_grep "buildbox fm-remote-entrypoint.sh" "$h/ssh.log" "the allowed call went over ssh"
  rc=0; on "$h" builder fm-backlog-receive.sh x >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" "placement still blocked"
  on "$h" helper fm-remote-doctor.sh >/dev/null 2>&1 || true
  assert_equals 2 "$(wc -l < "$h/ssh.log" | tr -d ' ')" "the doctor is never gated"
  assert_equals tester "$(br "$h" audit --json | jq -r '[.[] | select(.event=="changed")][0].by')" "change audited with who"
  pass "an allowed flow passes; other flows on the same bridge stay blocked"
}

test_approving_the_request_opens_the_flow_and_tells_the_first_mate() {
  local h id out
  h=$(home answer)
  br "$h" show >/dev/null
  add_route "$h" builder buildbox
  on "$h" builder fm-remote-file.sh put x >/dev/null 2>&1 || true
  id=$(find "$h/state/approvals" -name 'ap-*.json' | sed 's#.*/##; s#\.json$##')
  out=$(FM_HOME="$h" FM_APPROVAL_SEND="$h/bin/fm-send.sh" "$ROOT/bin/fm-approval.sh" answer "$id" --approve) || fail "approve failed: $out"
  br "$h" check buildbox files >/dev/null || fail "approval did not open the flow"
  assert_contains "$(cat "$h/bin/sent.log")" "now allows files" "first mate told"
  assert_equals "captain (approved $id)" "$(br "$h" audit --json | jq -r '[.[] | select(.event=="changed")][0].by')" "audited as the captain's approval"
  on "$h" builder fm-remote-file.sh put x >/dev/null 2>&1 || fail "files still blocked after approval"
  pass "approving a bridge request allows that flow on that bridge"
}

test_unreadable_record_closes_every_bridge() {
  local h rc
  h=$(home broken)
  printf '{"bridges": ' > "$h/config/bridges.json"
  rc=0; br "$h" check workload supervision >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" "unreadable record denies"
  rc=0; on "$h" helper fm-remote-secondmate-control.sh state helper >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" "fm-on refuses"
  assert_absent "$h/ssh.log" "nothing crossed"
  pass "an unreadable bridge record closes every bridge"
}

test_skill_placement_only_considers_allowed_bridges() {
  local h out rc
  h=$(home placement)
  br "$h" show >/dev/null
  add_route "$h" builder buildbox
  mkdir -p "$h/state/machine-skills"
  printf 'some-skill\tuser\n' > "$h/state/machine-skills/buildbox.tsv"
  rc=0; out=$(FM_HOME="$h" "$ROOT/bin/fm-machine-skills.sh" check buildbox some-skill) || rc=$?
  assert_equals 1 "$rc" "placement on a closed bridge refused"
  assert_contains "$out" "does not allow placement" "says why"
  pass "skill routing refuses machines whose bridge does not allow placement"
}

test_register_refusal_leaves_permissions_unchanged() {
  local h before audit rc=0 out
  h=$(home register-refusal)
  FM_HOME="$h" "$ROOT/bin/fm-machine.sh" register workload /r/firstmate --allow messages >/dev/null
  before=$(br "$h" show --json)
  audit=$(br "$h" audit --json)
  out=$(FM_HOME="$h" "$ROOT/bin/fm-machine.sh" register workload /wrong/root --allow files) || rc=$?
  assert_equals 1 "$rc" "wrong-root registration refuses"
  assert_contains "$out" 'different root' "refusal reason"
  assert_equals "$before" "$(br "$h" show --json)" "refusal preserves bridge record"
  assert_equals "$audit" "$(br "$h" audit --json)" "refusal does not audit a permission change"
  pass "registration validates the existing route before changing permissions"
}

test_seed_uses_home_inventory_not_scratch_routes() {
  local h rc=0 out
  h=$(home scratch-inventory)
  mkdir -p "$h/scratch"
  add_route "$h" builder buildbox
  mv "$h/data/secondmates.md" "$h/scratch/secondmates.md"
  printf -- '- helper - helper work (host: workload; root: /r/firstmate; home: /r/homes/helper; scope: help; projects: none; added 2026-10-01)\n' > "$h/data/secondmates.md"
  out=$(FM_HOME="$h" FM_DATA_OVERRIDE="$h/scratch" "$BRIDGE" show --json)
  assert_equals workload "$(printf '%s' "$out" | jq -r '.bridges[].machine')" "only actual home inventory seeded"
  br "$h" check buildbox maintenance >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" "scratch destination remains denied"
  pass "scratch routes cannot confer grandfathered permissions"
}

test_create_seeds_before_publishing_a_new_host() {
  local h out rc=0
  h=$(home create)
  out=$(FM_HOME="$h" FM_SSH_BIN="$h/bin/ssh" "$ROOT/bin/fm-secondmate-create.sh" apply builder \
    --charter 'Builder work' --scope build --host buildbox --root /r/firstmate --home /r/homes/builder --no-projects 2>&1) || rc=$?
  assert_equals 1 "$rc" "new host provisioning requires consent"
  assert_contains "$out" 'bridge-blocked:' "new host is refused"
  assert_equals workload "$(br "$h" show --json | jq -r '.bridges[].machine')" "only existing host was seeded"
  br "$h" check workload maintenance >/dev/null || fail "existing bridge lost permissions"
  ! br "$h" check buildbox maintenance >/dev/null 2>&1 || fail "new host was seeded"
  assert_equals 1 "$(wc -l < "$h/ssh.log" | tr -d ' ')" "only exempt doctor crossed"
  assert_equals buildbox "$(jq -r .args.machine "$h"/state/approvals/ap-*.json)" "new bridge has an approval request"
  pass "secondmate creation seeds the pre-add inventory and denies the new host"
}

test_summary_read_requires_reports_and_files() {
  local h rc=0 err
  h=$(home report)
  br "$h" set workload --allow files >/dev/null
  err=$(on "$h" helper fm-remote-file.sh get state/home-summary.json 2>&1) || rc=$?
  assert_equals 1 "$rc" "files alone cannot collect a report"
  assert_contains "$err" reports "report permission is requested"
  assert_absent "$h/ssh.log" "report never crossed"
  on "$h" helper fm-remote-file.sh get data/attachment.txt >/dev/null || fail "ordinary file needs only files"
  br "$h" allow workload reports >/dev/null
  on "$h" helper fm-remote-file.sh get state/home-summary.json >/dev/null || fail "both permissions should pass"
  br "$h" deny workload files >/dev/null
  rc=0
  err=$(on "$h" helper fm-remote-file.sh get state/home-summary.json 2>&1) || rc=$?
  assert_equals 1 "$rc" "reports alone cannot transfer a file"
  assert_contains "$err" files "file permission is still required"
  assert_equals 2 "$(wc -l < "$h/ssh.log" | tr -d ' ')" "only approved reads crossed"
  pass "summary transfer requires both file and report permissions"
}

test_machine_operations_use_the_shared_gate() {
  local h out rc
  h=$(home machine-operations)
  br "$h" set workload --allow none >/dev/null
  add_route "$h" other workload
  rc=0
  out=$(FM_HOME="$h" FM_SSH_BIN="$h/bin/ssh" "$ROOT/bin/fm-machine-skills.sh" refresh workload 2>&1) || rc=$?
  assert_equals 1 "$rc" "maintenance-denied skill discovery refuses"
  assert_contains "$out" bridge-blocked: "discovery reports bridge refusal"
  for operation in show save; do
    rc=0
    if [ "$operation" = show ]; then
      out=$(FM_HOME="$h" FM_SSH_BIN="$h/bin/ssh" "$ROOT/bin/fm-machine-instructions.sh" show workload 2>&1) || rc=$?
    else
      out=$(printf rules | FM_HOME="$h" FM_SSH_BIN="$h/bin/ssh" "$ROOT/bin/fm-machine-instructions.sh" save workload --expect none 2>&1) || rc=$?
    fi
    assert_equals 1 "$rc" "instruction $operation refuses denied maintenance"
    assert_contains "$out" bridge-blocked: "$operation reports bridge refusal"
  done
  assert_absent "$h/ssh.log" "no denied machine operation crossed"
  br "$h" allow workload maintenance >/dev/null
  out=$(FM_HOME="$h" FM_SSH_BIN="$h/bin/ssh" "$ROOT/bin/fm-machine-skills.sh" refresh workload) || fail "allowed discovery refused: $out"
  assert_contains "$out" 'refresh workload=done: 1 skills' "machine discovery ignores secondmate ambiguity"
  out=$(FM_HOME="$h" FM_SSH_BIN="$h/bin/ssh" "$ROOT/bin/fm-machine-instructions.sh" show workload) || fail "allowed instruction read refused: $out"
  assert_contains "$out" present=no "allowed machine read returned protocol"
  assert_equals 2 "$(wc -l < "$h/ssh.log" | tr -d ' ')" "allowed operations use SSH"
  printf 'broken' > "$h/config/bridges.json"
  rc=0
  out=$(FM_HOME="$h" FM_SSH_BIN="$h/bin/ssh" "$ROOT/bin/fm-machine-skills.sh" refresh workload 2>&1) || rc=$?
  assert_equals 1 "$rc" "broken policy refuses maintenance"
  assert_equals 2 "$(wc -l < "$h/ssh.log" | tr -d ' ')" "broken policy sent nothing"
  pass "machine-level maintenance crosses only through the bridge gate"
}

test_concurrent_mutations_and_requests_are_serialized() {
  local h
  h=$(home concurrent)
  br "$h" set workload --allow messages >/dev/null
  python3 - "$h" "$BRIDGE" <<'PY' || fail "concurrency regression"
import json
import os
from pathlib import Path
import subprocess
import sys
import time
h, bridge = sys.argv[1:]
env = dict(os.environ, FM_HOME=h)
lock = Path(h) / 'config/.bridges.lock'
lock.mkdir()
commands = [('allow', 'workload', 'files'), ('deny', 'workload', 'messages')]
processes = [subprocess.Popen([bridge, *args], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE) for args in commands]
time.sleep(1)
lock.rmdir()
for p in processes:
    out, err = p.communicate(timeout=15)
    assert p.returncode == 0, (out, err)
record = json.loads((Path(h) / 'config/bridges.json').read_text())
assert record['bridges']['workload']['allow'] == ['files'], record
processes = [subprocess.Popen([bridge, 'block', 'workload', 'reports', '--what', 'summary'], env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE) for _ in range(16)]
ids = []
for p in processes:
    out, err = p.communicate(timeout=20)
    assert p.returncode == 0, (out, err)
    ids.append(out.strip())
assert len(set(ids)) == 1, ids
requests = list((Path(h) / 'state/approvals').glob('ap-*.json'))
assert len(requests) == 1, requests
assert json.loads(requests[0].read_text())['gate'] == 'bridge:reports'
PY
  pass "concurrent permission updates and blocked requests preserve policy invariants"
}

test_existing_bridges_are_seeded_and_shown_configured
test_register_refusal_leaves_permissions_unchanged
test_seed_uses_home_inventory_not_scratch_routes
test_create_seeds_before_publishing_a_new_host
test_summary_read_requires_reports_and_files
test_machine_operations_use_the_shared_gate
test_concurrent_mutations_and_requests_are_serialized
test_new_machine_denies_everything_by_default
test_register_records_the_flows_chosen_at_connect
test_blocked_flow_is_refused_before_ssh_with_one_request
test_allowed_flow_passes_and_others_stay_blocked
test_approving_the_request_opens_the_flow_and_tells_the_first_mate
test_unreadable_record_closes_every_bridge
test_skill_placement_only_considers_allowed_bridges
