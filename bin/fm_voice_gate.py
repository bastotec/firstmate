#!/usr/bin/env python3
"""fm_voice_gate.py - the fail-open fast layer in front of the voice relay's heavy model.

PURPOSE
  One narrow-model fan-out call asks every routing question about one spoken
  transcript at once, and code - not the model - applies a fixed rule to the
  answers. The rule routes records reads, handovers and scripted lines away
  from the heavy model. Everything uncertain, missing, errored or below gate
  reaches the heavy model exactly as it does today. Measured through the same
  gateway path: about 0.36 s and $0.00003 per decision warm.

FAIL-OPEN IS THE CONTRACT, NOT A DEFAULT
  The verdict is `heavy` unless a narrow, positive rule returns one of the
  three fast routes. Any error, timeout, missing key, missing runtime,
  unparseable row, or answer no question explains routes up. The fast layer has
  no refuse, no clarify and no give-up outcome anywhere. Swallowing a real
  command is the only unacceptable failure.

THIS BUILD SHIPS SHADOW ONLY
  Every route decision is logged beside what the heavy model actually did, and
  acted on by nothing: the turn path never waits on this layer and never
  changes because of it. Flipping to act mode - where the relay routes before
  the heavy model and speaks the pre-rendered lines - is follow-up work gated
  on the shadow measurement (route-decision agreement against the heavy model
  and per-decision cost inside the approved ceiling).

THE ROUTING RULE (deterministic, dead zone routes up by construction)
  - hand_over >= GATE and intent == real_work   -> fast-handover
  - intent == status_query and needs_records >= GATE -> fast-records
  - answerable_fast >= GATE and intent == smalltalk  -> fast-script
  - everything else -> heavy
  The first match wins. Every probability a rule reads must clear GATE; any
  dead-zone probability, missing answer or unknown intent class leaves every
  rule unfired and falls to the heavy model.

STATE (all under state/voice-gate/, private runtime state)
  usage.log   "<epoch>\t<calls>\t<in-tok>\t<out-tok>\t<ms>\t<outcome>" - one
              row per fast decision, the row format shared with the other Jev
              passes. USD is derived from the row's tokens at the published
              input-only rate (0.042 per million), which is how this home
              prices every pass; `cost` prints it against the ceiling.
  shadow.log  "<epoch>\t<turn>\t<mode>\t<route>\t<why>\t<intent>\t<needs_records>\t<hand_over>\t<answerable_fast>\t<gate-ms>\t<in-tok>\t<line>\t<heavy>"
              one row per turn, written when the fast verdict and the heavy
              model's actual behavior are both known. `line` is the exact
              pre-rendered line the fast route would speak, or `records-template`
              for the records route. `heavy` is what the heavy model did:
              its tool names joined by commas, `answered`, `failed` or `timeout`.

CONFIGURATION (one file per value, environment overrides, no tracked default)
  config/voice-gate-key-var  FM_VOICE_GATE_KEY_VAR  first line names the
      secrets variable holding the gateway key. This file is the whole opt-in:
      absent, the gate is inert and the relay behaves exactly as before.
  config/voice-gate-mode     FM_VOICE_GATE_MODE     `shadow` (the default when
      absent) selects shadow mode. `act` refuses in this build by name, because
      act mode is follow-up work behind the shadow measurement. Any other value
      refuses too. A misconfigured value fails loud with the path to write.

The key value itself is never read here: the helper reads it at call time from
the secrets file (FM_VOICE_GATE_SECRETS, default ~/.secrets) under the named
variable, the file is parsed and never executed, and nothing here prints,
logs or passes the key.

THE DEADLINE COMES FROM THE TURN BUDGET, NEVER FROM HERE
  The caller passes the seconds this decision may take, taken as a share of the
  relay's one turn budget (bin/fm-voice-relay.py's TurnBudget). This module
  states no timeout of its own and the helper refuses to run without the
  caller's bound (FM_VOICE_GATE_TIMEOUT_MS). On expiry the route is `heavy`.

COLD START (P6): the first decision of a VoiceGate routes up as `cold-start`
  without a call. The measured first-call penalty (838-1903 ms versus 336-463
  ms warm) is paid on the first call of a run, and "first" is the only idle
  definition that costs the gate no number of its own. The shadow rows carry
  every later call's latency, so any in-process idle penalty surfaces in the
  measurement rather than being assumed away.

USAGE
  fm_voice_gate.py report [--home DIR]  per-class route counts and the route by
      heavy-behavior cross-tab the shadow measurement reads.
  fm_voice_gate.py cost [--home DIR]    measured Jev usage priced per decision
      against the approved ceiling.

  The relay calls this module in process (VoiceGate.decide and TurnRecord);
  the commands above are the operator's view of the same records.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fm_voice_records as records          # noqa: E402

# The threshold every fast route's probability must clear. Below it is the dead
# zone, and the dead zone routes up (the measured "can you look at it?" row sits
# at hand_over 0.36 and must reach the heavy model).
GATE = 0.60

ROUTE_HANDOVER = "fast-handover"
ROUTE_RECORDS = "fast-records"
ROUTE_SCRIPT = "fast-script"
ROUTE_HEAVY = "heavy"
ROUTES = (ROUTE_HANDOVER, ROUTE_RECORDS, ROUTE_SCRIPT, ROUTE_HEAVY)

# The intent classes the fan-out asks for, and the answers row order: intent,
# needs_records, hand_over, answerable_fast. The question set and this order
# are the measured relay-shaped set, kept byte-comparable with the measurement
# so each decision's cost can be checked against it.
INTENTS = ("status_query", "real_work", "smalltalk", "question", "unclear")

# Pre-rendered spoken lines (P4). Fixed text, never model text: act mode
# synthesizes each once into a cache so a fast route costs no live generation.
# The shadow row records the exact line so wording is reviewable before it is
# ever spoken.
LINES = {
    "handover-confirm": "Handing that to the first mate. It is queued.",
    "smalltalk": "All good here. Ask me anything about the fleet.",
}
# The records route answers from the records with a template rather than a
# fixed line; its fill is a records read at act time.
RECORDS_LINE = "records-template"

MODE_SHADOW = "shadow"
MODE_ACT = "act"

# Helper refusals that prove no vendor call was made, so their usage rows count
# zero calls. Everything else counts one: the vendor may have been reached.
PRE_CALL_ERRORS = frozenset(
    {"no-key", "no-runtime", "bad-input", "no-evidence", "no-timeout"})

# The published input-only rate the report and every pass price at; output is
# free. Override for one command with FM_VOICE_GATE_PRICE_PER_MTOK.
PRICE_PER_MTOK = 0.042
# The approved ceiling per fast decision.
CEILING_USD = 0.0001


class Decision:
    """One fast verdict and what it cost. Always a route, never a refusal."""

    def __init__(self, route, why, intent="-", needs_records="-", hand_over="-",
                 answerable_fast="-", gate_ms=0, in_tok=0, out_tok=0,
                 calls=0, outcome="skipped", line="-"):
        self.route = route
        self.why = why
        self.intent = intent
        self.needs_records = needs_records
        self.hand_over = hand_over
        self.answerable_fast = answerable_fast
        self.gate_ms = gate_ms
        self.in_tok = in_tok
        self.out_tok = out_tok
        self.calls = calls
        self.outcome = outcome
        self.line = line


def read_settings(home):
    """Return the gate's (key variable, mode), or None when the gate is inert.

    Inert means no config file names the key variable: no key, no gate, zero
    behavior change. Only a configured gate validates its mode, so a home that
    opted in out of a copied file never refuses to start over it. A configured
    but malformed value refuses loudly naming the file to write.
    """
    key_var = records.read_setting(home, "voice-gate-key-var", "FM_VOICE_GATE_KEY_VAR")
    if not key_var:
        return None
    path = os.path.join(records.config_dir(home), "voice-gate-key-var")
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key_var) is None:
        raise records.RecordError(
            "config/voice-gate-key-var must name one environment variable, "
            "for example GATEWAY_KEY; write it into {} or set "
            "FM_VOICE_GATE_KEY_VAR".format(path))
    mode = records.read_setting(home, "voice-gate-mode", "FM_VOICE_GATE_MODE") or MODE_SHADOW
    if mode not in (MODE_SHADOW, MODE_ACT):
        raise records.RecordError(
            "config/voice-gate-mode says {!r}; it must be {} or {}; write it "
            "into {} or set FM_VOICE_GATE_MODE".format(
                mode, MODE_SHADOW, MODE_ACT,
                os.path.join(records.config_dir(home), "voice-gate-mode")))
    if mode == MODE_ACT:
        raise records.RecordError(
            "config/voice-gate-mode says act, but this build ships shadow only: "
            "act mode is follow-up work behind the shadow measurement; write {} "
            "into {} or set FM_VOICE_GATE_MODE".format(
                MODE_SHADOW, os.path.join(records.config_dir(home), "voice-gate-mode")))
    return (key_var, mode)


def _log(home, name, record):
    directory = os.path.join(records.state_dir(home), "voice-gate")
    try:
        os.makedirs(directory, exist_ok=True)
        with open(os.path.join(directory, name), "a", encoding="utf-8") as handle:
            handle.write(record + "\n")
    except OSError:
        # A missing row is survivable; a broken turn is not. The gate never
        # takes the turn down with its own bookkeeping.
        pass


def _usage_row(decision):
    return "\t".join((
        str(int(time.time())), str(decision.calls), str(decision.in_tok),
        str(decision.out_tok), str(decision.gate_ms), decision.outcome))


def _shadow_row(turn, decision, heavy):
    return "\t".join((
        str(int(time.time())), turn, MODE_SHADOW, decision.route, decision.why,
        decision.intent, str(decision.needs_records), str(decision.hand_over),
        str(decision.answerable_fast), str(decision.gate_ms),
        str(decision.in_tok), decision.line, heavy))


class VoiceGate:
    """The caller-side gate: one fail-open fan-out call, then the fixed rule.

    One instance spans the relay process, because the cold-start policy is a
    property of the process that would pay the first-call penalty.
    """

    def __init__(self, home, settings=None):
        self.home = home
        self.settings = read_settings(home) if settings is None else settings
        self.cold = True
        # The live helper processes, under the lock their spawner and the
        # relay's teardown share. A stop latches: nothing later spawns, and
        # every live child is cut, so a detached shadow call can never hold
        # the relay's exit for the length of its turn-budget share.
        self.children = set()
        self.stopped = False
        self.child_lock = threading.Lock()

    @property
    def enabled(self):
        return self.settings is not None

    def turn(self, turn):
        """Open one turn's shadow record."""
        return TurnRecord(self, turn)

    def decide(self, utterance, seconds):
        """Return the route for one transcript. Never raises; always a route."""
        if not self.enabled:
            return Decision(ROUTE_HEAVY, "not-configured")
        if self.cold:
            self.cold = False
            return Decision(ROUTE_HEAVY, "cold-start")
        if seconds is None or seconds <= 0:
            return Decision(ROUTE_HEAVY, "budget-spent")
        try:
            return self._call(utterance, seconds)
        except Exception:                        # noqa: BLE001
            # Fail-open IS the contract: an unexpected shape is a route up,
            # never a dead turn and never a swallowed command.
            return Decision(ROUTE_HEAVY, "error")

    def stop(self):
        """End the gate for this process: nothing later runs, live helpers die."""
        with self.child_lock:
            self.stopped = True
            children = list(self.children)
        for child in children:
            try:
                child.kill()
            except OSError:
                pass

    def _call(self, utterance, seconds):
        override = os.environ.get("FM_VOICE_GATE_HELPER")
        if override:
            # Tests replace the helper command outright; it receives the same
            # input on stdin and prints the same rows.
            run = [override]
        else:
            helper = os.path.join(
                os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                "bin", "voice-gate", "jev-route.mjs")
            if not os.path.isfile(helper):
                return Decision(ROUTE_HEAVY, "no-helper")
            if not shutil.which("node"):
                return Decision(ROUTE_HEAVY, "no-node")
            run = ["node", helper]
        env = os.environ.copy()
        key_var, _ = self.settings
        env["FM_VOICE_GATE_KEY_VAR"] = key_var
        env["FM_VOICE_GATE_SECRETS"] = os.environ.get(
            "FM_VOICE_GATE_SECRETS") or os.path.join(os.path.expanduser("~"), ".secrets")
        # The one budget-derived bound, used twice and owned by nobody here: it
        # aborts the vendor call inside the helper and cuts its process. The
        # gate states no timeout of its own.
        env["FM_VOICE_GATE_TIMEOUT_MS"] = str(int(seconds * 1000))
        started = time.monotonic()
        try:
            with self.child_lock:
                if self.stopped:
                    return Decision(ROUTE_HEAVY, "stopped")
                child = subprocess.Popen(
                    run, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE, text=True, env=env)
                self.children.add(child)
        except OSError:
            return Decision(ROUTE_HEAVY, "no-helper")
        try:
            try:
                stdout, _ = child.communicate(
                    input=json.dumps({"utterance": utterance}), timeout=seconds)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
                return self._spent(Decision(
                    ROUTE_HEAVY, "helper-timeout", calls=1,
                    gate_ms=int((time.monotonic() - started) * 1000),
                    outcome="error-timeout"))
        finally:
            with self.child_lock:
                self.children.discard(child)
        elapsed = int((time.monotonic() - started) * 1000)
        rows = [line for line in stdout.splitlines() if line.strip()]
        error = None
        for line in rows:
            fields = line.split("\t")
            if fields and fields[0] == "error":
                error = fields[1] if len(fields) > 1 else "unknown"
        if child.returncode != 0 or error is not None:
            reason = error or "unknown"
            calls = 0 if reason in PRE_CALL_ERRORS else 1
            return self._spent(Decision(
                ROUTE_HEAVY, "error-{}".format(reason), calls=calls,
                gate_ms=elapsed, outcome="error-{}".format(reason)))
        answers = usage = None
        for line in rows:
            fields = line.split("\t")
            if fields[0] == "answers" and answers is None:
                answers = fields[1:]
            elif fields[0] == "usage" and usage is None:
                usage = fields[1:]
        return self._spent(self._rule(answers, self._usage(usage, elapsed)))

    def _spent(self, decision):
        """Record the cost of one decision: a usage row per helper run.

        The row format is the one every Jev pass in this home writes, so cost
        accounting stays one shape; the derived USD is printed by `cost`, which
        is where the approved ceiling is checked.
        """
        _log(self.home, "usage.log", _usage_row(decision))
        return decision

    @staticmethod
    def _usage(usage, elapsed):
        """Return (calls, in, out, ms, outcome) from a usage row, or None."""
        if usage is None or len(usage) != 4:
            return None
        try:
            calls, in_tok, out_tok, ms = (int(x) for x in usage)
        except ValueError:
            return None
        if calls < 0 or in_tok < 0 or out_tok < 0 or ms < 0:
            return None
        return (calls, in_tok, out_tok, ms, "ok")

    def _rule(self, answers, usage):
        """Apply the fixed routing rule to one fan-out answer row."""
        if usage is None:
            return Decision(ROUTE_HEAVY, "bad-rows", calls=1, outcome="error")
        calls, in_tok, out_tok, ms, outcome = usage
        if answers is None or len(answers) != 4:
            return Decision(ROUTE_HEAVY, "bad-rows", calls=calls, in_tok=in_tok,
                            out_tok=out_tok, gate_ms=ms, outcome="error")
        intent, needs_records, hand_over, answerable_fast = answers
        if intent not in INTENTS:
            return Decision(ROUTE_HEAVY, "bad-rows", calls=calls, in_tok=in_tok,
                            out_tok=out_tok, gate_ms=ms, outcome="error")

        def prob(text):
            try:
                value = float(text)
            except ValueError:
                return None
            return value if 0.0 <= value <= 1.0 else None

        numbers = [prob(x) for x in (needs_records, hand_over, answerable_fast)]
        if any(x is None for x in numbers):
            return Decision(ROUTE_HEAVY, "bad-rows", calls=calls, in_tok=in_tok,
                            out_tok=out_tok, gate_ms=ms, outcome="error")
        needs_records, hand_over, answerable_fast = numbers
        common = dict(intent=intent, needs_records="{:.4f}".format(needs_records),
                      hand_over="{:.4f}".format(hand_over),
                      answerable_fast="{:.4f}".format(answerable_fast),
                      gate_ms=ms, in_tok=in_tok, out_tok=out_tok,
                      calls=calls, outcome=outcome)
        # The rule, in order. Every probability a rule reads clears GATE or the
        # rule does not fire, so the dead zone reaches the heavy model by
        # construction and there is no outcome but these four.
        if intent == "real_work" and hand_over >= GATE:
            return Decision(ROUTE_HANDOVER, "hand-over",
                            line=LINES["handover-confirm"], **common)
        if intent == "status_query" and needs_records >= GATE:
            return Decision(ROUTE_RECORDS, "records",
                            line=RECORDS_LINE, **common)
        if intent == "smalltalk" and answerable_fast >= GATE:
            return Decision(ROUTE_SCRIPT, "script",
                            line=LINES["smalltalk"], **common)
        return Decision(ROUTE_HEAVY, "default", **common)


class TurnRecord:
    """One turn's shadow row: the fast verdict beside the heavy model's action.

    Both halves are required, so the row is written by whichever lands second
    and exactly once. A turn the relay tears down mid-flight may keep no row;
    that loses evidence, never behavior.
    """

    def __init__(self, gate, turn):
        self.gate = gate
        self.turn = turn
        self.decision = None
        self.heavy = None
        self.written = False
        self.lock = threading.Lock()

    def decide(self, utterance, seconds):
        """Run the fast layer for this turn and settle its half of the row."""
        decision = self.gate.decide(utterance, seconds)
        self.record_decision(decision)
        return decision

    def record_decision(self, decision):
        with self.lock:
            if self.decision is None:
                self.decision = decision
            self._settle()

    def record_heavy(self, heavy):
        """Record what the heavy model did: tools, answered, failed, timeout."""
        with self.lock:
            if self.heavy is None:
                self.heavy = heavy
            self._settle()

    def _settle(self):
        if (not self.written and self.decision is not None
                and self.heavy is not None):
            self.written = True
            _log(self.gate.home, "shadow.log",
                 _shadow_row(self.turn, self.decision, self.heavy))


def _read_rows(home, name):
    path = os.path.join(records.state_dir(home), "voice-gate", name)
    try:
        with open(path, encoding="utf-8") as handle:
            return [line.split("\t") for line in handle.read().splitlines() if line.strip()]
    except FileNotFoundError:
        return []


def cmd_report(home):
    """Print the per-class records (P7) and the agreement cross-tab."""
    rows = _read_rows(home, "shadow.log")
    if not rows:
        print("no shadow decisions recorded")
        return 0
    counts = {}
    cross = {}
    for fields in rows:
        if len(fields) != 13:
            continue
        route, heavy = fields[3], fields[12]
        counts[route] = counts.get(route, 0) + 1
        cross[(route, heavy)] = cross.get((route, heavy), 0) + 1
    print("turns={}".format(len(rows)))
    for route in ROUTES:
        if route in counts:
            print("  {}: {}".format(route, counts[route]))
    print("route by heavy behavior:")
    for (route, heavy), count in sorted(cross.items()):
        agree = ""
        if route == ROUTE_HANDOVER:
            agree = "agree" if "hand_over_to_firstmate" in heavy else "diverge"
        elif route == ROUTE_RECORDS:
            agree = "agree" if "get_fleet_status" in heavy else "diverge"
        elif route == ROUTE_SCRIPT:
            agree = "agree" if heavy == "answered" else "diverge"
        print("  {} x {}: {} {}".format(route, heavy, count, agree).rstrip())
    return 0


def cmd_cost(home):
    """Print measured usage priced per decision against the approved ceiling."""
    rows = _read_rows(home, "usage.log")
    if not rows:
        print("no fast-layer usage recorded (layer inert)")
        return 0
    price = os.environ.get("FM_VOICE_GATE_PRICE_PER_MTOK")
    try:
        price = float(price) if price else PRICE_PER_MTOK
    except ValueError:
        price = PRICE_PER_MTOK
    calls = in_tok = out_tok = 0
    costs = []
    for fields in rows:
        if len(fields) != 6:
            continue
        try:
            row_calls, row_in, row_out = int(fields[1]), int(fields[2]), int(fields[3])
        except ValueError:
            continue
        calls += row_calls
        in_tok += row_in
        out_tok += row_out
        if row_calls:
            costs.append(row_in * price / 1000000.0)
    print("calls={} input_tokens={} output_tokens={}".format(calls, in_tok, out_tok))
    if costs:
        worst = max(costs)
        mean = sum(costs) / len(costs)
        verdict = "inside" if worst <= CEILING_USD else "OUTSIDE"
        print("per_decision_cost_usd mean={:.9f} max={:.9f}".format(mean, worst))
        print("ceiling_usd={} verdict={}".format(CEILING_USD, verdict))
    return 0


def main(argv):
    parser = argparse.ArgumentParser(
        prog="fm_voice_gate.py", add_help=True,
        description=__doc__.splitlines()[0])
    parser.add_argument("command", choices=("report", "cost"))
    parser.add_argument("--home")
    options = parser.parse_args(argv)
    home = options.home or records.default_home()
    if options.command == "report":
        return cmd_report(home)
    return cmd_cost(home)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
