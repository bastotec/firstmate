#!/usr/bin/env bash
# tests/fm-voice-gate.test.sh - the fail-open fast layer in front of the voice relay.
#
# Every case here runs offline: no live model, no network, no audio device. The
# fan-out call is replaced by a stub helper with the real helper's contract, so
# what gets pinned is what this feature is actually made of: the gate stays
# inert until a config file names the key variable, every failure shape routes
# the turn to the heavy model instead of swallowing it, the dead zone routes up
# by construction, no clarify outcome exists anywhere, each decision writes the
# shared usage row, and the shadow row joins the fast verdict to what the heavy
# model actually did.
#
# The rule's happy paths matter least; the fail-open paths are the contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-voice-gate)

# A stub helper with the real helper's contract: it reads the request JSON on
# stdin, logs one line per run (the bound it was handed and the request), and
# answers per FM_TEST_STUB_MODE.
make_stub() {  # <dir> -> stub path
  local stub="$1/stub-helper"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
set -u
req=$(cat)
printf 'timeout=%s request=%s\n' "${FM_VOICE_GATE_TIMEOUT_MS:-}" "$req" >> "${FM_TEST_STUB_LOG:?}"
case "${FM_TEST_STUB_MODE:-ok}" in
  sleep) sleep "${FM_TEST_STUB_SLEEP:-3}" ;;
  error)
    if [ -n "${FM_TEST_STUB_REASON:-}" ]; then
      printf 'error\t%s\n' "$FM_TEST_STUB_REASON"
    else
      printf 'error\n'
    fi
    exit "${FM_TEST_STUB_CODE:-5}" ;;
  silent) exit 0 ;;
  garbage) printf 'this is not the protocol\n'; exit 0 ;;
  rows) printf '%b\n' "${FM_TEST_STUB_ROWS:-}"; exit 0 ;;
  usage-only) printf 'usage\t1\t713\t112\t360\n'; exit 0 ;;
  answers-only) printf 'answers\tstatus_query\t0.9000\t0.1000\t0.2000\n'; exit 0 ;;
esac
printf 'usage\t1\t%s\t%s\t%s\n' "${FM_TEST_STUB_IN:-713}" "${FM_TEST_STUB_OUT:-112}" "${FM_TEST_STUB_MS:-360}"
printf 'answers\t%s\t%s\t%s\t%s\n' "${FM_TEST_STUB_INTENT:-status_query}" \
  "${FM_TEST_STUB_NR:-0.9000}" "${FM_TEST_STUB_HO:-0.1000}" "${FM_TEST_STUB_AF:-0.2000}"
SH
  chmod +x "$stub"
  printf '%s\n' "$stub"
}

new_case() {  # <name> -> case dir with config/ and a stub helper
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/config" "$dir/state"
  printf 'GATE_TEST_KEY=synthetic-not-a-key\n' > "$dir/secrets"
  # The whole opt-in: this file names the key variable, so the gate runs.
  printf 'GATE_TEST_KEY\n' > "$dir/config/voice-gate-key-var"
  make_stub "$dir" >/dev/null
  : > "$dir/stub.log"
  printf '%s\n' "$dir"
}

# The gate is inert until config/voice-gate-key-var names the key variable:
# no key, no gate, zero behavior change.
python3 - "$ROOT/bin" "$TMP_ROOT" <<'PY' || fail "inert by default"
import pathlib, sys
sys.path.insert(0, sys.argv[1])
import fm_voice_gate as gate

def check(cond, label):
    if not cond:
        sys.exit("inert: " + label)

home = pathlib.Path(sys.argv[2]) / "no-such-home"
check(gate.read_settings(str(home)) is None, "an unconfigured home must read as inert")
unconfigured = gate.VoiceGate(str(home))
check(not unconfigured.enabled, "the gate must report itself disabled")
check(unconfigured.decide("fix the bug", 5.0).route == gate.ROUTE_HEAVY,
      "an inert gate must route up")
check(not (home / "state").exists(), "an inert gate must write no state at all")
PY
pass "no key variable means no gate and no state"

# Misconfigured values fail loud naming the file to write, while an inert home
# never refuses to start over a mode file it will not read.
python3 - "$ROOT/bin" "$TMP_ROOT" <<'PY' || fail "config fail-loud"
import pathlib, sys
sys.path.insert(0, sys.argv[1])
import fm_voice_gate as gate
import fm_voice_records as records

def check(cond, label):
    if not cond:
        sys.exit("config: " + label)

def expect_error(config, text, label):
    home = pathlib.Path(config).parent
    try:
        gate.read_settings(str(home))
    except records.RecordError as exc:
        message = str(exc)
        check(all(x in message for x in text),
              "%s: %r must name %r" % (label, message, text))
        return
    sys.exit("config: %s was accepted" % label)

root = pathlib.Path(sys.argv[2])
case = root / "config-case"
(case / "config").mkdir(parents=True, exist_ok=True)
config = case / "config"

for name in ("GATE-KEY", "9KEY", "two words", ""):
    if name:
        (config / "voice-gate-key-var").write_text(name + "\n")
    else:
        (config / "voice-gate-key-var").write_text("\n# nothing but a comment\n")
    if not name:
        continue
    expect_error(config, ("voice-gate-key-var", str(config / "voice-gate-key-var")),
                 "malformed key variable %r" % name)

(config / "voice-gate-key-var").write_text("GATE_TEST_KEY\n")
for mode, text in (("act", ("act", "shadow", "measurement")),
                   ("enforce", ("voice-gate-mode", "shadow", "act"))):
    (config / "voice-gate-mode").write_text(mode + "\n")
    expect_error(config, text, "mode %r" % mode)

(config / "voice-gate-mode").write_text("shadow\n")
settings = gate.read_settings(str(case))
check(settings == ("GATE_TEST_KEY", "shadow"), "shadow mode must configure: %r" % (settings,))

# A mode file alone names no key variable, so the gate stays inert rather than
# refusing a home that never opted in.
(config / "voice-gate-key-var").unlink()
(config / "voice-gate-mode").write_text("act\n")
check(gate.read_settings(str(case)) is None,
      "a mode file with no key variable must stay inert")

# The environment overrides each config file for a single run. The mode file
# says `act` - a value this build refuses - so the override is proven by the
# refusal not firing.
import os
(config / "voice-gate-key-var").write_text("GATE_TEST_KEY\n")
(config / "voice-gate-mode").write_text("act\n")
os.environ["FM_VOICE_GATE_KEY_VAR"] = "ENV_TEST_KEY"
os.environ["FM_VOICE_GATE_MODE"] = "shadow"
check(gate.read_settings(str(case)) == ("ENV_TEST_KEY", "shadow"),
      "the environment must override both config files")
os.environ.pop("FM_VOICE_GATE_KEY_VAR")
os.environ.pop("FM_VOICE_GATE_MODE")
PY
pass "misconfigured gate values refuse loudly with the path to write"

# The routing rule. The three fast routes fire on their exact conditions; every
# dead-zone probability, unknown intent and high-confidence non-match reaches
# the heavy model. There is no fourth outcome: no clarify, no refusal.
run_rule() {  # <dir> <intent> <nr> <ho> <af> -> prints "route why line"
  local dir=$1 intent=$2 nr=$3 ho=$4 af=$5
  FM_VOICE_GATE_HELPER="$dir/stub-helper" FM_VOICE_GATE_SECRETS="$dir/secrets" \
    FM_TEST_STUB_LOG="$dir/stub.log" FM_TEST_STUB_MODE=ok \
    FM_TEST_STUB_INTENT="$intent" FM_TEST_STUB_NR="$nr" FM_TEST_STUB_HO="$ho" \
    FM_TEST_STUB_AF="$af" python3 - "$ROOT/bin" "$dir" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import fm_voice_gate as gate
gate_home = sys.argv[2]
fast = gate.VoiceGate(gate_home)
fast.cold = False
decision = fast.decide("fixture utterance", 5.0)
print("{} {} {}".format(decision.route, decision.why, decision.line))
PY
}

rule_case=$(new_case rule)
assert_equals "fast-handover hand-over Handing that to the first mate. It is queued." \
  "$(run_rule "$rule_case" real_work 0.1000 0.9000 0.1000)" \
  "explicit work at 0.90 must hand over with the pre-rendered line"
assert_equals "fast-records records records-template" \
  "$(run_rule "$rule_case" status_query 0.9000 0.1000 0.1000)" \
  "a status question needing the records must take the records route"
assert_equals "fast-script script All good here. Ask me anything about the fleet." \
  "$(run_rule "$rule_case" smalltalk 0.1000 0.1000 0.9000)" \
  "smalltalk answerable fast must take the scripted line"
assert_equals "fast-handover hand-over Handing that to the first mate. It is queued." \
  "$(run_rule "$rule_case" real_work 0.1000 0.6000 0.1000)" \
  "the gate must be inclusive at exactly 0.60"
assert_equals "heavy default -" "$(run_rule "$rule_case" real_work 0.1000 0.3600 0.1000)" \
  "the dead zone on hand_over must reach the heavy model"
assert_equals "heavy default -" "$(run_rule "$rule_case" status_query 0.5900 0.1000 0.1000)" \
  "needs_records just under gate must reach the heavy model"
assert_equals "heavy default -" "$(run_rule "$rule_case" smalltalk 0.1000 0.1000 0.5000)" \
  "answerable_fast under gate must reach the heavy model"
assert_equals "heavy default -" "$(run_rule "$rule_case" question 0.1000 0.9500 0.9500)" \
  "a general question must never hand over on one high probability"
assert_equals "heavy default -" "$(run_rule "$rule_case" unclear 0.1000 0.1000 0.9500)" \
  "garbled speech must never become a scripted line"
assert_equals "heavy default -" "$(run_rule "$rule_case" real_work 0.9000 0.3600 0.1000)" \
  "a mixed request in the dead zone must reach the heavy model, never be swallowed"
pass "the rule routes three fast classes and everything uncertain stays heavy"

# FAIL-OPEN ON EVERY ERROR SHAPE. Each helper failure is a route to the heavy
# model and a usage row, never an exception and never a swallowed command.
run_shape() {  # <dir> <label> <env...> -> prints "route why calls outcome"
  local dir=$1 label=$2
  shift 2
  env FM_VOICE_GATE_HELPER="$dir/stub-helper" FM_VOICE_GATE_SECRETS="$dir/secrets" \
    FM_TEST_STUB_LOG="$dir/stub.log" "$@" python3 - "$ROOT/bin" "$dir" "$label" <<'PY'
import pathlib, sys
sys.path.insert(0, sys.argv[1])
import fm_voice_gate as gate
gate_home, label = sys.argv[2], sys.argv[3]
fast = gate.VoiceGate(gate_home)
fast.cold = False
decision = fast.decide("fixture utterance", 5.0)
rows = []
path = pathlib.Path(gate_home) / "state" / "voice-gate" / "usage.log"
if path.exists():
    rows = [line.split("\t") for line in path.read_text().splitlines() if line.strip()]
check = sys.exit
if decision.route != gate.ROUTE_HEAVY:
    check("fail-open: %s must route up, got %r" % (label, decision.route))
for fields in rows:
    if len(fields) != 6:
        check("fail-open: %s wrote a malformed usage row: %r" % (label, fields))
last = rows[-1] if rows else ["0", "0", "0", "0", "0", "missing"]
print("{} {} {} {}".format(decision.route, decision.why, last[1], last[5]))
PY
}

shape_case=$(new_case shapes)
assert_equals "heavy error-no-key 0 error-no-key" \
  "$(run_shape "$shape_case" no-key FM_TEST_STUB_MODE=error FM_TEST_STUB_REASON=no-key FM_TEST_STUB_CODE=3)" \
  "no key must route up and count zero calls"
assert_equals "heavy error-no-runtime 0 error-no-runtime" \
  "$(run_shape "$shape_case" no-runtime FM_TEST_STUB_MODE=error FM_TEST_STUB_REASON=no-runtime FM_TEST_STUB_CODE=4)" \
  "no runtime must route up and count zero calls"
assert_equals "heavy error-no-timeout 0 error-no-timeout" \
  "$(run_shape "$shape_case" no-timeout FM_TEST_STUB_MODE=error FM_TEST_STUB_REASON=no-timeout FM_TEST_STUB_CODE=2)" \
  "a helper without the caller's bound must route up and count zero calls"
assert_equals "heavy error-call-failed 1 error-call-failed" \
  "$(run_shape "$shape_case" call-failed FM_TEST_STUB_MODE=error FM_TEST_STUB_REASON=call-failed FM_TEST_STUB_CODE=5)" \
  "a failed vendor call must route up and count one call"
assert_equals "heavy error-bad-answer 1 error-bad-answer" \
  "$(run_shape "$shape_case" bad-answer FM_TEST_STUB_MODE=error FM_TEST_STUB_REASON=bad-answer FM_TEST_STUB_CODE=6)" \
  "an unparseable answer must route up and count one call"
assert_equals "heavy error-unknown 1 error-unknown" \
  "$(run_shape "$shape_case" unknown FM_TEST_STUB_MODE=error FM_TEST_STUB_REASON= FM_TEST_STUB_CODE=1)" \
  "a failure that names no reason must still route up"
assert_equals "heavy bad-rows 1 error" \
  "$(run_shape "$shape_case" garbage FM_TEST_STUB_MODE=garbage)" \
  "garbage rows must route up"
assert_equals "heavy bad-rows 1 error" \
  "$(run_shape "$shape_case" silent FM_TEST_STUB_MODE=silent)" \
  "a helper that says nothing must route up"
assert_equals "heavy bad-rows 1 error" \
  "$(run_shape "$shape_case" usage-only FM_TEST_STUB_MODE=usage-only)" \
  "usage with no answers must route up"
assert_equals "heavy bad-rows 1 error" \
  "$(run_shape "$shape_case" answers-only FM_TEST_STUB_MODE=answers-only)" \
  "answers with no usage must route up"
assert_equals "heavy bad-rows 1 error" \
  "$(run_shape "$shape_case" short-answers FM_TEST_STUB_MODE=rows \
      FM_TEST_STUB_ROWS='usage\\t1\\t713\\t112\\t360\\nanswers\\tstatus_query\\t0.9000')" \
  "an answer row of the wrong width must route up"
assert_equals "heavy bad-rows 1 error" \
  "$(run_shape "$shape_case" nonnumeric FM_TEST_STUB_MODE=rows \
      FM_TEST_STUB_ROWS='usage\\t1\\t713\\t112\\t360\\nanswers\\tstatus_query\\t0.9000\\tnope\\t0.2000')" \
  "a non-numeric probability must route up"
assert_equals "heavy bad-rows 1 error" \
  "$(run_shape "$shape_case" out-of-range FM_TEST_STUB_MODE=rows \
      FM_TEST_STUB_ROWS='usage\\t1\\t713\\t112\\t360\\nanswers\\tstatus_query\\t1.5000\\t0.1000\\t0.2000')" \
  "a probability outside [0,1] must route up"
assert_equals "heavy bad-rows 1 error" \
  "$(run_shape "$shape_case" unknown-intent FM_TEST_STUB_MODE=rows \
      FM_TEST_STUB_ROWS='usage\\t1\\t713\\t112\\t360\\nanswers\\tshout\\t0.9000\\t0.9000\\t0.9000')" \
  "an unknown intent class must route up"
assert_equals "heavy error-error 1 error-error" \
  "$(run_shape "$shape_case" helper-error FM_TEST_STUB_MODE=error FM_TEST_STUB_REASON=error FM_TEST_STUB_CODE=1)" \
  "a bare helper error must route up"
pass "every helper failure shape routes up and keeps its usage row"

# THE DEADLINE COMES FROM THE TURN BUDGET. The caller's seconds are the only
# bound: the helper is handed them, and a helper that outlives them is cut.
python3 - "$ROOT/bin" "$TMP_ROOT" <<'PY' || fail "deadline from the budget"
import os, pathlib, sys, time
sys.path.insert(0, sys.argv[1])
import fm_voice_gate as gate

def check(cond, label):
    if not cond:
        sys.exit("deadline: " + label)

case = pathlib.Path(sys.argv[2]) / "deadline-case"
(case / "config").mkdir(parents=True, exist_ok=True)
(case / "state").mkdir(parents=True, exist_ok=True)
(case / "config" / "voice-gate-key-var").write_text("GATE_TEST_KEY\n")
os.environ["FM_VOICE_GATE_SECRETS"] = str(case / "secrets")
(case / "secrets").write_text("GATE_TEST_KEY=synthetic-not-a-key\n")

stub = str(case / "stub-helper")
stub_text = (pathlib.Path(sys.argv[2]) / "shapes" / "stub-helper").read_text()
(pathlib.Path(stub)).write_text(stub_text)
os.chmod(stub, 0o755)
os.environ["FM_VOICE_GATE_HELPER"] = stub
os.environ["FM_TEST_STUB_LOG"] = str(case / "stub.log")
os.environ["FM_TEST_STUB_MODE"] = "ok"

fast = gate.VoiceGate(str(case))
fast.cold = False
fast.decide("fixture utterance", 5.0)
log = (case / "stub.log").read_text()
check("timeout=5000 " in log,
      "the helper must be handed the caller's bound in milliseconds: %r" % log)

before = len((case / "stub.log").read_text().splitlines())
decision = fast.decide("fixture utterance", 0)
check(decision.route == gate.ROUTE_HEAVY and decision.why == "budget-spent",
      "a turn with no budget left must route up without a call: %r" % (decision.why,))
check(len((case / "stub.log").read_text().splitlines()) == before,
      "a spent budget must not reach the helper at all")

os.environ["FM_TEST_STUB_MODE"] = "sleep"
os.environ["FM_TEST_STUB_SLEEP"] = "3"
started = time.monotonic()
decision = fast.decide("fixture utterance", 0.2)
elapsed = time.monotonic() - started
check(decision.route == gate.ROUTE_HEAVY and decision.why == "helper-timeout",
      "a helper past its bound must route up: %r" % (decision.why,))
check(elapsed < 1.5, "the bound must actually cut the helper: %.2fs" % elapsed)
check(decision.calls == 1, "a cut call was still a call")
PY
pass "the fast layer's only clock is the turn budget's"

# COLD START (P6) AND ONE CALL PER DECISION (P2). The first decision of a gate
# routes up without spending anything; every later one is exactly one fan-out
# call, compound-shaped utterances included, so no multi-call chain can exist.
python3 - "$ROOT/bin" "$TMP_ROOT" <<'PY' || fail "cold start and one call"
import os, pathlib, sys
sys.path.insert(0, sys.argv[1])
import fm_voice_gate as gate

def check(cond, label):
    if not cond:
        sys.exit("calls: " + label)

case = pathlib.Path(sys.argv[2]) / "calls-case"
(case / "config").mkdir(parents=True, exist_ok=True)
(case / "state").mkdir(parents=True, exist_ok=True)
(case / "config" / "voice-gate-key-var").write_text("GATE_TEST_KEY\n")
(case / "secrets").write_text("GATE_TEST_KEY=synthetic-not-a-key\n")
stub = case / "stub-helper"
stub.write_text((pathlib.Path(sys.argv[2]) / "shapes" / "stub-helper").read_text())
os.chmod(str(stub), 0o755)
os.environ.update(FM_VOICE_GATE_HELPER=str(stub),
                  FM_VOICE_GATE_SECRETS=str(case / "secrets"),
                  FM_TEST_STUB_LOG=str(case / "stub.log"), FM_TEST_STUB_MODE="ok")
(case / "stub.log").write_text("")

fast = gate.VoiceGate(str(case))
decision = fast.decide("hello there", 5.0)
check(decision.route == gate.ROUTE_HEAVY and decision.why == "cold-start",
      "the first decision must route up on policy: %r" % (decision.why,))
check((case / "stub.log").read_text() == "",
      "the cold decision must spend no call")

fast.decide("what is in flight and also fix the login bug", 5.0)
lines = (case / "stub.log").read_text().splitlines()
check(len(lines) == 1,
      "a compound utterance must still cost exactly one call: %d" % len(lines))
PY
pass "one cold skip per gate and one fan-out call per decision"

# THE SHADOW ROW: the fast verdict beside what the heavy model actually did,
# written once however the two halves arrive.
python3 - "$ROOT/bin" "$TMP_ROOT" <<'PY' || fail "shadow rows"
import os, pathlib, sys
sys.path.insert(0, sys.argv[1])
import fm_voice_gate as gate

def check(cond, label):
    if not cond:
        sys.exit("shadow: " + label)

case = pathlib.Path(sys.argv[2]) / "shadow-case"
(case / "config").mkdir(parents=True, exist_ok=True)
(case / "state").mkdir(parents=True, exist_ok=True)
(case / "config" / "voice-gate-key-var").write_text("GATE_TEST_KEY\n")
(case / "secrets").write_text("GATE_TEST_KEY=synthetic-not-a-key\n")
stub = case / "stub-helper"
stub.write_text((pathlib.Path(sys.argv[2]) / "shapes" / "stub-helper").read_text())
os.chmod(str(stub), 0o755)
os.environ.update(FM_VOICE_GATE_HELPER=str(stub),
                  FM_VOICE_GATE_SECRETS=str(case / "secrets"),
                  FM_TEST_STUB_LOG=str(case / "stub.log"), FM_TEST_STUB_MODE="ok",
                  FM_TEST_STUB_INTENT="real_work", FM_TEST_STUB_NR="0.1000",
                  FM_TEST_STUB_HO="0.9000", FM_TEST_STUB_AF="0.1000")

fast = gate.VoiceGate(str(case))
fast.cold = False

# The heavy side lands first on a slow fast call; the row waits for the verdict.
first = fast.turn("turn-1")
first.record_heavy("hand_over_to_firstmate")
path = case / "state" / "voice-gate" / "shadow.log"
check(not path.exists(), "one half must not write a row")
first.decide("fix the bug", 5.0)
first.record_heavy("answered")
rows = [line.split("\t") for line in path.read_text().splitlines() if line.strip()]
check(len(rows) == 1, "the row must be written exactly once: %d" % len(rows))
check(len(rows[0]) == 13, "the shadow row must have its 13 columns: %r" % (rows[0],))
check(rows[0][1:5] == ["turn-1", "shadow", "fast-handover", "hand-over"],
      "the row must name the turn, mode, route and reason: %r" % (rows[0],))
check(rows[0][5] == "real_work", "the row must carry the intent: %r" % (rows[0],))
check(rows[0][6:9] == ["0.1000", "0.9000", "0.1000"],
      "the row must carry every probability: %r" % (rows[0],))
check(rows[0][9].isdigit() and rows[0][10] == "713",
      "the row must carry the gate latency and tokens (P7): %r" % (rows[0],))
check(rows[0][11] == gate.LINES["handover-confirm"],
      "the row must carry the exact pre-rendered line (P4): %r" % (rows[0],))
check(rows[0][12] == "hand_over_to_firstmate",
      "the first heavy answer must win: %r" % (rows[0],))

# The other arrival order writes the same shape. A status question whose
# hand_over sits high still routes up: one high probability never fires a rule
# whose intent it does not reach.
os.environ.update(FM_TEST_STUB_INTENT="status_query", FM_TEST_STUB_NR="0.1000",
                  FM_TEST_STUB_HO="0.9500", FM_TEST_STUB_AF="0.1000")
second = fast.turn("turn-2")
decision = second.decide("how many jobs are in flight", 5.0)
check(decision.route == gate.ROUTE_HEAVY,
      "a status question with hand_over high must wait for the heavy model: %r" % decision.route)
second.record_heavy("get_fleet_status")
rows = [line.split("\t") for line in path.read_text().splitlines() if line.strip()]
check(len(rows) == 2 and rows[-1][3] == "heavy" and rows[-1][12] == "get_fleet_status",
      "the verdict-first order must join the same way: %r" % (rows[-1],))
PY
pass "one shadow row per turn joins the fast verdict to the heavy model's action"

# The operator's view: the per-class records (P7) and the per-decision cost the
# approved ceiling is checked against (P5).
report_out=$(python3 "$ROOT/bin/fm_voice_gate.py" report --home "$TMP_ROOT/shadow-case" 2>&1)
assert_contains "$report_out" "turns=2" "report must count the turns"
assert_contains "$report_out" "fast-handover: 1" "report must count per route class"
assert_contains "$report_out" "fast-handover x hand_over_to_firstmate: 1 agree" \
  "report must show route by heavy behavior"
assert_contains "$report_out" "heavy x get_fleet_status: 1" \
  "report must show the heavy-route rows too"
cost_out=$(python3 "$ROOT/bin/fm_voice_gate.py" cost --home "$TMP_ROOT/shadow-case" 2>&1)
assert_contains "$cost_out" "calls=2 input_tokens=1426" "cost must total the usage rows"
assert_contains "$cost_out" "ceiling_usd=0.0001 verdict=inside" \
  "cost must check the per-decision ceiling"
pass "report and cost make the shadow window measurable"

# The fan-out helper itself: its refusals happen before any network call, and it
# refuses to run at all without the caller's bound (the gate has no clock of its
# own). These cases need node; they are skipped, loudly, without it.
if command -v node >/dev/null 2>&1; then
  helper_case=$(new_case helper)
  printf 'GATE_TEST_KEY=synthetic-not-a-key\n' > "$helper_case/secrets"
  echo '{"utterance":"hello"}' > "$helper_case/request.json"

  out=$(FM_VOICE_GATE_KEY_VAR=GATE_TEST_KEY FM_VOICE_GATE_SECRETS="$helper_case/missing" \
    FM_VOICE_GATE_TIMEOUT_MS=1000 node "$ROOT/bin/voice-gate/jev-route.mjs" \
    "$helper_case/request.json" 2>&1)
  code=$?
  expect_code 3 "$code" "no key must refuse with exit 3"
  assert_equals $'error\tno-key' "$out" "no key must refuse before any network call"

  out=$(FM_VOICE_GATE_KEY_VAR=GATE_TEST_KEY FM_VOICE_GATE_SECRETS="$helper_case/secrets" \
    node "$ROOT/bin/voice-gate/jev-route.mjs" "$helper_case/request.json" 2>&1)
  code=$?
  expect_code 2 "$code" "no bound must refuse with exit 2"
  assert_equals $'error\tno-timeout' "$out" \
    "the helper must refuse without the caller's deadline"

  # A runtime that cannot load is the same refusal as a missing one. The empty
  # node_modules makes the import failure deterministic and offline, and
  # reaching it at all proves the key was read from the named secrets file.
  mkdir -p "$helper_case/broken/node_modules/ai"
  cp "$ROOT/bin/voice-gate/jev-route.mjs" "$helper_case/broken/jev-route.mjs"
  out=$(FM_VOICE_GATE_KEY_VAR=GATE_TEST_KEY FM_VOICE_GATE_SECRETS="$helper_case/secrets" \
    FM_VOICE_GATE_TIMEOUT_MS=1000 node "$helper_case/broken/jev-route.mjs" \
    "$helper_case/request.json" 2>&1)
  code=$?
  expect_code 4 "$code" "an unloadable runtime must refuse with exit 4"
  assert_equals $'error\tno-runtime' "$out" "an unloadable runtime must refuse by name"

  questions_out=$(node --input-type=module -e "
import { QUESTIONS, INTENTS } from '$ROOT/bin/voice-gate/jev-route.mjs';
console.log(Object.keys(QUESTIONS).join(','));
console.log(QUESTIONS.intent.type + ':' + Object.keys(QUESTIONS.intent.criteria).join(','));
console.log(QUESTIONS.needs_records.type + QUESTIONS.hand_over.type + QUESTIONS.answerable_fast.type);
console.log(INTENTS.join(','));
")
  assert_equals "intent,needs_records,hand_over,answerable_fast
choice:status_query,real_work,smalltalk,question,unclear
booleanbooleanboolean
status_query,real_work,smalltalk,question,unclear" "$questions_out" \
    "the shipped questions must be the measured fan-out set"
  pass "the fan-out helper refuses before any network and keeps its measured questions"
else
  echo "skip - node not found: fan-out helper cases not run"
fi

printf 'all voice gate cases passed\n'
