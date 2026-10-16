#!/usr/bin/env bash
# tests/fm-gate-record.test.sh - state/<id>.gate (bin/fm_gate_record.py): the gate a
# parked validation run waits at, read from one `no-mistakes axi status` (TOON):
# its findings parsed as written (quoted cells, commas and escapes inside them),
# parked_since kept across rewrites and restarted for a new run or step, the
# repair-budget exhaustion seen from a marker finding or the help line, a mate's
# advice in its own <id>.gate-advice carrying what it was given for, the record
# and its advice removed when no gate shows, and nothing rewritten when nothing
# changed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm_gate_record.py"
TMP_ROOT=$(fm_test_tmproot fm-gate-record-tests)

status() {  # <run> <step> <findings rows...> -> one axi status on stdout
  local run=$1 step=$2
  shift 2
  printf 'run:\n  id: "%s"\n  branch: fm/x\n  status: running\n' "$run"
  printf 'gate:\n  step: %s\n  status: awaiting_approval\n  risk: high\n  findings[%d]{id,severity,file,action,description}:\n' "$step" "$#"
  local r
  for r in "$@"; do printf '    %s\n' "$r"; done
  # shellcheck disable=SC2016
  printf 'help[1]: Run `no-mistakes axi respond --action approve` to accept\n'
}

field() {  # <file> <python expression over d>
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}

R1='R1,error,src/a.ts,ask-user,"[CONFIRMED] The new path drops enforcement, so a reply \"done\" passes."'
R2='R2,warning,"",auto-fix,"A typo, nothing more."'

test_a_parked_gate_is_written_with_its_findings_as_written() {
  local f="$TMP_ROOT/a.gate"
  status 01RA review "$R1" "$R2" | python3 "$GATE" "$f" || fail "writer exited non-zero"
  [ "$(field "$f" 'd["run"], d["step"], d["risk"], len(d["findings"])')" = "('01RA', 'review', 'high', 2)" ] || fail "gate fields: $(cat "$f")"
  [ "$(field "$f" 'd["findings"][0]["description"]')" = '[CONFIRMED] The new path drops enforcement, so a reply "done" passes.' ] || fail "quoted cell: $(cat "$f")"
  [ "$(field "$f" 'd["findings"][1]["file"], d["findings"][1]["action"]')" = "('', 'auto-fix')" ] || fail "empty cell"
  [ "$(field "$f" 'd["repair_budget_exhausted"], "recommendation" in d')" = "(False, False)" ] || fail "defaults"
  [ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$f")" = 0o600 ] || fail "owner-only mode"
  pass "a parked gate is written with its findings as written"
}

test_parked_since_holds_and_restarts_for_a_new_run_or_step() {
  local f="$TMP_ROOT/b.gate" first
  status 01RB review "$R1" | python3 "$GATE" "$f"
  python3 - "$f" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d['parked_since'] = 1000
json.dump(d, open(sys.argv[1], 'w'))
PY
  status 01RB review "$R1" | python3 "$GATE" "$f"
  [ "$(field "$f" 'd["parked_since"]')" = 1000 ] || fail "kept across rewrites: $(cat "$f")"
  status 01RB review "$R1" "$R2" | python3 "$GATE" "$f"
  [ "$(field "$f" 'd["parked_since"]')" = 1000 ] || fail "new findings keep the wait"
  status 01RB test "$R1" | python3 "$GATE" "$f"
  first=$(field "$f" 'd["parked_since"]')
  [ "$first" != 1000 ] || fail "a new step starts the wait again"
  status 01RC test "$R1" | python3 "$GATE" "$f"
  [ "$(field "$f" 'd["run"]')" = 01RC ] || fail "a new run is a new gate"
  pass "parked_since holds across rewrites and restarts for a new run or step"
}

test_an_exhausted_repair_budget_is_seen_from_the_marker_or_the_help() {
  local f="$TMP_ROOT/c.gate"
  status 01RD review "$R1" 'repair-budget-review,warning,"",ask-user,"Automatic repair budget exhausted for review."' | python3 "$GATE" "$f"
  [ "$(field "$f" 'd["repair_budget_exhausted"]')" = True ] || fail "marker finding"
  { status 01RE review "$R1"; printf 'help[2]: "The automatic repair budget is exhausted; explicit authority remains available"\n'; } | python3 "$GATE" "$TMP_ROOT/d.gate"
  [ "$(field "$TMP_ROOT/d.gate" 'd["repair_budget_exhausted"]')" = True ] || fail "help line"
  pass "an exhausted repair budget is seen from the marker or the help line"
}

test_no_gate_or_clear_removes_the_record_and_unchanged_leaves_it() {
  local f="$TMP_ROOT/e.gate" before
  status 01RF review "$R1" | python3 "$GATE" "$f"
  before=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$f")
  sleep 1
  status 01RF review "$R1" | python3 "$GATE" "$f"
  [ "$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns)' "$f")" = "$before" ] || fail "unchanged gate rewritten"
  printf 'run:\n  id: "01RF"\n  status: running\n' | python3 "$GATE" "$f"
  [ ! -e "$f" ] || fail "no gate in the read leaves the record"
  status 01RF review "$R1" | python3 "$GATE" "$f"
  python3 "$GATE" "$f" --advise accept --why ok
  python3 "$GATE" "$f" --clear </dev/null
  [ ! -e "$f" ] && [ ! -e "$f-advice" ] || fail "--clear leaves the record or its advice"
  status 01RF review "$R1" | python3 "$GATE" "$f"
  python3 "$GATE" "$f" --advise accept --why ok
  printf 'run:\n  id: "01RF"\n  status: running\n' | python3 "$GATE" "$f"
  [ ! -e "$f-advice" ] || fail "a gate that went away leaves its advice"
  pass "no gate (or --clear) removes the record and its advice; an unchanged one is left alone"
}

test_the_other_response_shapes_are_read_too() {
  local f="$TMP_ROOT/s.gate"
  # findings under run:, a gate block with its status, and the steps table at the top level
  printf 'run:\n  id: "01RS"\n  status: running\n  findings[1]{id,severity,file,line,action,description}:\n    r1,error,b.go,,ask-user,changes product behavior\ngate:\n  step: review\n  status: fix_review\nsteps[2]{step,status,findings,duration_ms}:\n  intent,completed,0,0\n  review,fix_review,1,0\n' | python3 "$GATE" "$f"
  [ "$(field "$f" 'd["status"], d["findings"][0]["id"], d["findings"][0]["description"]')" = "('fix_review', 'r1', 'changes product behavior')" ] || fail "findings under run: $(cat "$f")"
  # a scalar gate: its step's status from the run
  printf 'run:\n  id: "01RT"\n  status: awaiting_approval\n  findings[1]{id,severity,file,line,action,description}:\n    r2,error,b.go,,ask-user,changes product behavior\ngate: review\n' | python3 "$GATE" "$f"
  [ "$(field "$f" 'd["run"], d["step"], d["status"], d["findings"][0]["id"]')" = "('01RT', 'review', 'awaiting_approval', 'r2')" ] || fail "scalar gate: $(cat "$f")"
  # a scalar gate whose steps table sits under run:
  printf 'run:\n  id: "01RU"\n  status: running\n  steps[2]{step,status,findings,duration_ms}:\n    intent,completed,0,0\n    review,fix_review,1,0\ngate: review\n' | python3 "$GATE" "$f"
  [ "$(field "$f" 'd["status"]')" = fix_review ] || fail "nested steps: $(cat "$f")"
  pass "a scalar gate and findings under run: are read too"
}

test_a_symlink_in_its_place_is_left_alone() {
  local f="$TMP_ROOT/l.gate"
  printf 'keep\n' > "$TMP_ROOT/target"
  ln -s "$TMP_ROOT/target" "$f"
  status 01RL review "$R1" | python3 "$GATE" "$f"
  python3 "$GATE" "$f" --clear </dev/null
  [ -L "$f" ] && [ "$(cat "$TMP_ROOT/target")" = keep ] || fail "symlink touched"
  pass "a symlink in its place is left alone"
}

test_advice_names_what_it_was_given_for_and_never_races_the_publisher() {
  local f="$TMP_ROOT/r.gate" rows=() n before
  for n in $(seq 1 21); do rows+=("R$n,warning,a.ts,ask-user,\"finding $n\""); done
  status 01RR review "${rows[@]}" | python3 "$GATE" "$f"
  python3 "$GATE" "$f" --advise fix --why "two small fixes" --findings R1,R2 --by docana || fail "advise exited non-zero"
  [ "$(field "$f-advice" 'd["run"], d["step"], len(d["finding_ids"]), d["choice"], d["findings"], d["why"], d["by"]')" = "('01RR', 'review', 21, 'fix', ['R1', 'R2'], 'two small fixes', 'docana')" ] || fail "advice fields: $(cat "$f-advice")"
  [ "$(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$f-advice")" = 0o600 ] || fail "owner-only advice"
  python3 "$GATE" "$f" --advise fix --why "fix every finding" --findings "$(field "$f" '",".join(d["finding_ids"])')" || fail "21-finding advice refused"
  [ "$(field "$f-advice" 'd["findings"] == ["R" + str(n) for n in range(1, 22)]')" = True ] || fail "advice findings truncated: $(cat "$f-advice")"
  before=$(cat "$f-advice")
  # the publisher rewrites the gate (a finding past the clip changed) and never touches the advice
  rows[20]='R99,warning,a.ts,ask-user,"another"'
  status 01RR review "${rows[@]}" | python3 "$GATE" "$f"
  [ "$(cat "$f-advice")" = "$before" ] || fail "the publisher rewrote the advice"
  [ "$(python3 -c 'import json,sys; g=json.load(open(sys.argv[1])); a=json.load(open(sys.argv[2])); print(g["finding_ids"] == a["finding_ids"])' "$f" "$f-advice")" = False ] || fail "a reader cannot tell the advice is stale"
  python3 "$GATE" "$f" --advise maybe --why x 2>/dev/null; [ $? = 2 ] || fail "an unknown choice is refused"
  python3 "$GATE" "$TMP_ROOT/none.gate" --advise accept --why x 2>/dev/null; [ $? = 1 ] && [ ! -e "$TMP_ROOT/none.gate-advice" ] || fail "advice without a gate"
  pass "advice names the run, step and findings it was given for, and the publisher never rewrites it"
}

test_advice_refuses_unknown_findings_and_overlong_text_without_writing() {
  local f="$TMP_ROOT/invalid/record.gate"
  mkdir "$TMP_ROOT/invalid"
  status 01RV review "$R1" | python3 "$GATE" "$f" || fail "gate setup"
  python3 - "$GATE" "$f" <<'PY' || fail "advice validation or no-write contract"
import json
from pathlib import Path
import subprocess
import sys

writer, gate_file = sys.argv[1:]
gate = Path(gate_file)
advice = Path(gate_file + '-advice')
command = [sys.executable, writer, gate_file, '--advise', 'fix']
invalid = [
    ['--why', 'ok', '--findings', 'R1,R99'],
    ['--why', 'w' * 601],
    ['--why', 'ok', '--by', 'b' * 101],
]
for existing in (False, True):
    if existing:
        result = subprocess.run(command + ['--why', 'é' * 600, '--by', '名' * 100],
                                capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
        data = json.loads(advice.read_text())
        assert data['why'] == 'é' * 600 and data['by'] == '名' * 100, data
    for args in invalid:
        before = {p.name: (p.read_bytes(), p.stat().st_mtime_ns)
                  for p in gate.parent.iterdir()}
        result = subprocess.run(command + args, capture_output=True, text=True)
        assert result.returncode == 2, (args, result)
        assert result.stderr.strip(), (args, result)
        assert not result.stdout, (args, result)
        after = {p.name: (p.read_bytes(), p.stat().st_mtime_ns)
                 for p in gate.parent.iterdir()}
        assert after == before, (args, 'refused advice changed files')
PY
  pass "unknown findings and overlong why/by exit 2 without creating or rewriting records"
}

test_a_parked_gate_is_written_with_its_findings_as_written
test_parked_since_holds_and_restarts_for_a_new_run_or_step
test_an_exhausted_repair_budget_is_seen_from_the_marker_or_the_help
test_no_gate_or_clear_removes_the_record_and_unchanged_leaves_it
test_the_other_response_shapes_are_read_too
test_a_symlink_in_its_place_is_left_alone
test_advice_names_what_it_was_given_for_and_never_races_the_publisher
test_advice_refuses_unknown_findings_and_overlong_text_without_writing
