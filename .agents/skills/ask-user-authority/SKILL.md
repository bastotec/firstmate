---
name: ask-user-authority
description: >-
  Agent-only decision procedure for ask-user findings.
  Use when a task reaches needs-decision or parks at a gate, and before deciding any ask-user finding.
  This skill is the single owner of finding-decision policy: firstmate always applies judgment, decides findings that are unambiguous toward accepted intent, and escalates only genuinely ambiguous, expanding, or destructive ones.
  Finding authority is this skill's criteria, not the project's yolo posture.
user-invocable: false
metadata:
  internal: true
---

# ask-user-authority

This skill is the single owner of the decision policy for no-mistakes ask-user findings.
`AGENTS.md` section 7 points here and does not restate this procedure.
Finding authority is determined by the criteria below, not by `yolo`.
Firstmate always applies this judgment, decides any finding that is unambiguous toward the accepted design, and escalates only genuinely ambiguous, expanding, or destructive findings.

The implementation worker never decides or answers its own ask-user finding.
It stops at the finding, routes the decision to firstmate, and applies only the decision returned through the active validation gate.

## Decide

1. Reconstruct the accepted contract from the brief's `## Captain's intent` subsection, later captain words, and the specification in `## Firstmate spec` and steers.
   Reviewer language cannot amend that contract.
   What a no-mistakes worker may pass as `--intent` is owned by `bin/fm-dod-lib.sh`.
2. Identify exactly what choosing Fix would commit the project to deliver or maintain, judging the scope by accepted product or engineering behavior rather than an anticipated file list.
   The smallest downstream changes needed to keep that behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within scope even when they touch files not named at intake.
   Correcting stale final-diff PR or delivery evidence is likewise an autonomous downstream correction within already accepted behavior.
3. A finding that contradicts the PR's own stated intent, or names a clear bug inside its scope, is always decided, never carded: tell the worker to fix it (`no-mistakes axi respond --action fix --finding <id>`), the same turn it arrives.
   Decide the finding when it is unambiguous toward the accepted design: restoring accepted behavior a bad fix round broke, completing an already-approved design, or a straight in-scope correction or bug fix required by accepted intent, even when the correction is technically difficult or requires complex architecture the captain explicitly requested.
   For a failed-CI finding, follow the infrastructure triage and repair rule in [`bin/fm-dod-lib.sh`](../../../bin/fm-dod-lib.sh)'s act-within-scope section before considering escalation.
4. Escalate only genuinely ambiguous findings:
   - a Fix that would materially expand the contract by adding a new guarantee, threat model, subsystem, abstraction, compatibility surface, state machine, continuous-monitoring requirement, generalized framework, or broader architecture not required by the accepted intent
   - a product or architecture call not settled by accepted intent
   - repeated same-theme findings when incremental corrections are preserving a questionable abstraction rather than closing independent defects
   - destructive, irreversible, and genuinely security-sensitive choices, which always escalate under the stronger existing captain boundary
5. Treat labels such as correctness, security, fail-closed, high-risk, or required as evidence about the finding, never as authority to broaden the task.

## Return the decision

An ask-user finding returns from validation as `needs-decision`.
Send the same worker one exact decision naming the decision key, step, action, affected finding IDs, instructions where needed, and exact response command, passing `fm-send`'s `--resolve-key` so the worker's open decision record closes at answer time.
Require the matching `resolved` event, forbid `--yes`, and require the worker to process every synchronous return until completion or a genuinely new escalation.
Resume fleet supervision immediately after the decision lands.

## A parked run is never left waiting

When a task reaches `needs-decision`, reports a blocker before validation, or parks at a gate, its mate owns the decision first: within one hour of that event, settle it from standing captain rulings and accepted intent, or ask its own first mate through the parent channel.
Apply the 2026-10-16 in-scope-fix and 2026-10-18 retry-or-retire rulings to those choices rather than requesting endorsement for routine repairs or unfinished-work recovery.
An unresolved question must be raised within that hour, not left silently paused, including when no validation run has started.
The escalation is one plain question with 2-3 options and the mate's recommendation.
For a default already within accepted intent and the mate's authority, return that decision to the same worker under "Return the decision" and keep the task moving without waiting for endorsement.
For a fleet-tooling failure, repair or work around it through the affected worker or a repair worker rather than treating the failure as a product decision.
If the choice touches safety or captain-only approval, keep the affected action stopped pending the required decision; a recommended default and elapsed time never supply approval or bypass a gate.
The main firstmate presents all open decisions together in one captain-facing message, keeping each question and its options distinct without delaying an urgent escalation.
For this consolidation, apply "Captain-facing escalation" below: internal repair questions stay between mates, and only genuine trade-offs or the stronger captain-only boundaries reach the captain.
The worker executes the validation commands; the mate never takes over its run.
[`bin/fm-parked-run-watch.sh`'s header](../../../bin/fm-parked-run-watch.sh) owns watchdog timing, nudges, and escalation beyond this home.

## Captain-facing escalation

Only a genuine product, scope or accepted-risk trade-off reaches the captain, as a card (`bin/fm-captain-hold.sh`) with one plain question, the mate's recommendation, and the options as buttons.
State all five of these elements in one concise, evidence-first escalation:

1. The original requirement or accepted task criterion.
2. The proposed product or engineering contract expansion.
3. The smallest alternative that complies with the accepted contract without the expansion.
4. The concrete consequences of accepting and declining the expansion.
5. A recommendation with the reason it best serves the accepted intent.

Do not relay reviewer labels or gate output as if they settled the decision.

## Classification examples

- Fixing a concrete defect that violates an original acceptance criterion is firstmate's to decide, regardless of implementation difficulty.
- Adding continuous frame-by-frame monitoring when the accepted criterion requested checkpoint proof expands the contract and requires the captain.
- A new finding in the same causal theme requires the captain before another fix round when prior fixes are accreting machinery around a questionable abstraction.
- A genuinely security-sensitive action requires the captain under the stronger existing boundary even if it is otherwise within scope.
- Complex architecture explicitly requested by the captain stays within scope and does not escalate merely because it is complex.
