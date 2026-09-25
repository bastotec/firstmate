# Voice turn-budget live validation - fm/voice-turn-budget

Every drive below ran the real product binaries in this session:
`bin/fm-voice-relay.py` (target commit ddc5513c) and the laptop copy of
`bin/fm-voice-client.py`, over the rig shapes `tests/fm-voice-relay.test.sh`
uses: a scripted Bedrock SDK at the exact import boundary, and - for the
hybrid engine - a real local WebSocket server speaking the Realtime wire.
Base contrasts ran the same drives against ee23a2da (the base commit); the
reuse contrast ran against 3ae93764 (the branch's first commit, before the
review fixes).

## 1. A spoken lead-in before a tool call is no longer the turn's answer

Bedrock self-test, real relay binary, scripted model that speaks 0.3 s of
audio, calls hand_over_to_firstmate, then ends the turn with no audio after
the tool:

- target: exit 1, `answered: false`, `response_audio_seconds: 0.0`,
  `reply_audio_seconds: 0.3` (the lead-in kept as evidence), relay_error
  "the model ended the turn without speaking after its last tool call"
  (bk-leadin-target.json)
- base: exit 0, `answered: true`, no error - the lead-in stood in for the
  answer (bk-leadin-base.json)

Hybrid engine, same shape over a real local WebSocket:

- target: exit 1, `answered: false`, `response_audio_seconds: 0.0`,
  relay_error "hybrid engine ended the turn without speaking after its last
  tool call" (hy-leadin-target.json)
- base: exit 0, `answered: true` (hy-leadin-base.json)
- guard does not overfire: a tool turn that DOES speak after the tool
  succeeds, `response_audio_seconds > 0` (hy-healthy-target.json)

Reused Bedrock session (turn 1 interrupted mid-answer, replies stays 0, the
relay reuses the session; turn 2 calls the tool and goes silent):

- target: turn 2 named in the client record - relay_error "the model ended
  the turn without speaking after its last tool call", interrupted: true
  (reuse-target.jsonl)
- branch-first-commit and base: turn 2 recorded unanswered with no reason at
  all - the stale response flag reported a silent success (reuse-prefix.jsonl,
  reuse-base.jsonl)

## 2. The wire stamp names the answer, not the lead-in

Real client (laptop copy) over the ssh stand-in to the real relay, hybrid
engine, scripted lead-in then tool then answer:

- target client record: `first_audio_wire: 0.857` s after talk end - the
  answer's hand-off (cl-wire-target.jsonl)
- base client record: `first_audio_wire: 0.206` s - the lead-in's hand-off
  (cl-wire-base.jsonl)

## 3. The handover grace is a deadline grant that reaches armed waits

Both legs finish the same answer at the same moment, past the turn budget;
only the tool leg receives the grant:

- Bedrock, --turn-timeout 3.0, answer completes ~3.2 s after talk start:
  tool leg answered, not timed out, exit 0 (bk-grant-tool.json, reply_end
  2.686 s after talk end); no-tool leg timed out, exit 1
  (bk-grant-silent.json). The self-test wait is the deadline that the grant
  moved - it expired at the pre-grant budget without the tool call.
- Hybrid, --turn-timeout 4.0, answer completes ~4.25 s after talk start:
  tool leg answered, exit 0 (hy-grant-tool.json, reply_end 3.732 s after
  talk end); no-tool leg timed out, exit 1 (hy-grant-silent.json). The
  production _deadline task and the self-test wait both read the same
  granted budget.

## 4. The client's one turn budget

- `--timeout 0`: refused at parse ("--timeout must be greater than zero",
  exit 2) on the target; the base accepted it silently
  (cl-timeout0-target.log / cl-timeout0-base.log).
- Speech that spends the budget: a 2 s clip inside a 1.5 s budget reports
  unanswered at once ("client: no reply within 0.0s"), prints a well-formed
  turn record, no traceback (cl-spent-target.log); the base answered the
  same turn on its own fresh post-speech clock (cl-spent-base.jsonl,
  answered: true).

## 5. The reconnect reads the budget's connect share

Two runs where turn 1 ends cleanly and the second session's open hangs
forever, --turn-timeout 4 (connect share 1 s), client --timeout 6:

- target: turn 2 carries relay_error "TimeoutError", the run finishes in 7 s,
  and the relay process exits (cl-renew-target.jsonl/.seconds)
- base: the reconnect hangs unbounded - turn 2 waits out the whole client
  timeout with no reason in the record, run takes 29 s
  (cl-renew-base.jsonl/.seconds, "no reply within 6.0s")

## Repository suite

`FM_LIVE=0 bin/fm-test-run.sh tests/fm-voice-relay.test.sh` passes on the
target commit (all voice relay cases). Two transient failures of the
pre-existing "hybrid engine" case were observed while the host was heavily
loaded by the live drives; the case's --turn-timeout 0.15 fixtures are
unchanged from the base commit and the case passed on every quiet rerun
(5 further runs).
