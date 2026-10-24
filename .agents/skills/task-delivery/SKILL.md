---
name: task-delivery
description: >-
  Agent-only procedures for the dispatch, validation, ready, landing, and scout-outcome steps of a task's delivery.
  Use before every spawn, when judging an active no-mistakes validation run's state, when the captain adds or changes the ask of a task under validation, when a worker hand-edits, commits, aborts, or restarts during its run, when a worker reports a PR or a ready local-only branch, before writing a custom watcher check, after a teardown, when a worker reports blocked, when a scout completes, and on every heartbeat for the finished-work sweep.
user-invocable: false
metadata:
  internal: true
---

# task-delivery

`AGENTS.md` section 7 owns intake, dispatch, delivery modes, merge authority, and the safety rules for each step below, and keeps them inline.
This skill owns the step procedures and does not restate those rules.

## Before spawning

For ship tasks, treat file or subsystem overlap as a risk signal rather than an automatic reason to wait, and dispatch isolated work immediately with no concurrency cap when each change can be independently implemented and validated and the selected delivery path can reconcile ordinary rebases or conflicts.
Serialize only for a true semantic dependency, shared mutable external state, incompatible concurrent migration, or another concrete condition that makes independent progress or reconciliation unsafe; same-file editing alone is insufficient, and genuine blockers remain durable.
Before spawning, check the work already in flight for the same problem, not just the same area: when the request is the same change a running task is already making, fold it into that task or stop, rather than dispatching a second worker to solve it again and notifying both.
Whenever work you dispatch touches an area another task is already working, say so in both directions before the new worker starts, and again whenever a new overlap appears mid-flight: name the other work and the files or subsystem it touches, both to the new worker and to every running worker it overlaps.
That notice is awareness rather than a hold, because the ship brief carries the worker's own half of the contract - rebase rather than design around the other change, and report a genuine semantic conflict instead of resolving it.
A worker rebases only while its branch is still its own to rewrite, and the branch-custody rules in the supersession and run-state sections below decide when that is, so a change that lands while the pipeline still owns the branch is never a steer into it.
Once custody is settled, getting the branch current is yours to own by steering or relaunching the worker.
A semantic conflict a worker reports is yours to decide or escalate, never to hand back.

## When a worker reports blocked

Follow `fm_act_within_scope_section` in `bin/fm-dod-lib.sh`, referenced by `AGENTS.md` section 7's "Acting within scope", when judging a reported blocker.
If the report does not satisfy that contract, steer the worker to follow it.
Once it does, solve what is in its way yourself - start or install the tool, free or replace the slot, grant the authority the captain already gave - and steer it to continue.
Raise the blocker with the captain only when it is his call: a hard stop, a product decision, or a credential only he can supply.

## Scope once validation starts

Once validation starts, prefer routing new requirements to follow-up work rather than expanding the current task, unless a new requirement completely invalidates the work being validated.
The smallest downstream changes needed to keep already accepted product or engineering behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within the current task even when they touch files not named at intake, and corrections required to satisfy already accepted intent are not new requirements.

## Supersession

Only a current, explicit captain instruction that completely invalidates the work being validated keeps the task with the same worker instead of routing it to follow-up work or handing it to a replacement.
That worker cancels the active run through no-mistakes axi's supported abort command and confirms through axi status that the run has stopped before changing any code.
The worker then follows `branch_sync.next_action` from structured axi status: use axi sync's supported guarded recovery only when its code is `recover_custody`, and otherwise proceed only when structured status confirms that branch ownership is already returned and no recovery is required.
Custody recovery settles branch ownership, not content: the worker must replace the obsolete work from the correct pre-invalidation base rather than building on top of the recovered-but-obsolete head, keeping the obsolete run's own pipeline-fix commits out of what gets validated and shipped.
Apart from that single supported abort, do not hand-edit, commit, restart, or start a second validation run while the obsolete run still owns the branch.
Once ownership is settled, validate exactly once against that final head so no obsolete or intermediate head is ever treated as authoritative.

## Reading the run state

Judge validation by the currently attributed run step through `bin/fm-crew-state.sh`, not by shell liveness or the last status event.
State derivation and uncertainty rules are owned by [`bin/fm-task-state-lib.sh`](../../../bin/fm-task-state-lib.sh); when the adapter reports parked approval or fix-review, steer the worker to follow the active gate help.
A worker hand-editing, committing, aborting, or restarting during an active validation run duplicates pipeline ownership outside the supersession sequence above; steer it back to the gate response flow.
The worker reports the PR when CI first becomes green rather than waiting for merge monitoring to finish.
For a red check, follow the infrastructure triage and repair rule in [`bin/fm-dod-lib.sh`](../../../bin/fm-dod-lib.sh)'s act-within-scope section.

## PR ready

For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` reports `done: PR <url> checks green` after CI is green, while `direct-PR` reports `done: PR <url>` after opening the PR.
Run `bin/fm-pr-check.sh <id> <PR url>` with the URL copied from that ready signal - it records `pr=` and the forge's `pr_head=` when available in the task's meta and arms the watcher's merge poll.
Tell the captain the PR's full `https://...` URL copied from the worker's ready line or the task's `pr=` metadata, a concise outcome summary, and the no-mistakes risk level when applicable.
A captain instruction to merge is explicit authority; otherwise consult the repository's merge policy before asking, following [AGENTS.md section 7's "Selected delivery path and merge authority"](../../../AGENTS.md#selected-delivery-path-and-merge-authority).
After an autonomous merge, give the captain a one-line full-URL or local-main outcome.
An auto-land `check:` wake from `bin/fm-autoland.sh` reports merges, deploy outcomes, and held green PRs with their reasons; a reported PR is yours to decide in the same turn rather than leave waiting on its owner.

## Custom checks

For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file, print one line only when firstmate should wake, print nothing otherwise, finish before `FM_CHECK_TIMEOUT`, then bind its current bytes with `bin/fm-check-register.sh <id>` before the watcher may execute it.
Retire a custom check only through `bin/fm-check-unregister.sh <id>` (or `bin/fm-teardown.sh` for a spawned task); never hand-compose an `rm` with `$STATE`/`$ID`.

## Finished-work sweep

When a parent instruction explicitly prohibits automatic recovery pending its release, record that approval exclusion through [`bin/fm-approval-wait.sh`](../../../bin/fm-approval-wait.sh), whose header owns declaration, exact decision/instruction binding and release.
Do not infer this disposition from an ordinary keyed blocker or substitute a timed external wait for unknown approval timing.
The cleanup and retry instructions below apply only to workers not excluded under that contract.

`AGENTS.md` section 7 records the captain's standing instruction that the mate who created a worker cleans it up once its work is done.
Run this sweep when a ship lands, when a scout completes, and on every heartbeat, over this home's own endpoint-backed direct reports and endpoint-bound leftover records only, never another home's, and never a secondmate, which retires only on an explicit decision.
A specialist is a persistent worker, so this sweep never retires it; the [fleet snapshot header](../../../bin/fm-fleet-snapshot.sh) owns its fleet visibility and the [specialist CLI header](../../../bin/fm-specialist.sh) owns messaging, model switching, and explicit retirement.
The watcher independently runs [`bin/fm-idle-sweep.sh`](../../../bin/fm-idle-sweep.sh), whose header owns automated cleanup and retry eligibility, first-mate handoffs, repeat suppression, cadence, and second-mate audit.
Handle its handoffs under the stopped-worker rule below, never through a captain hold.

Use [`bin/fm-pr-lib.sh`'s completion-claim gate](../../../bin/fm-pr-lib.sh) to judge a worker with a recorded PR, regardless of delivery mode.
Without a recorded PR, ordinary cleanup requires a landed branch, or a scout whose report exists and whose `captain-hold-lifecycle` completion gate passes.
A scout kept alive to host the captain's Lavish loop, or any worker whose work is still under way, is not finished.

For each finished worker:

1. Run `bin/fm-teardown.sh <id> --keep-commits`, never with `--force`; its [header](../../../bin/fm-teardown.sh) owns the preservation limits and output.
   If the verified PR/MR URL is known only from the status ledger, supply it through the header's merged-PR input rather than relying on GitHub branch discovery.
   Handle preserved work yourself under [the housekeeping policy](../captain-hold-lifecycle/SKILL.md#decision-cards), mentioning it as an FYI at most.
2. If cleanup refuses only because the endpoint is on a retired backend and could never be confirmed gone, retire the record with `FM_HOME=<this home> bin/fm-retire-endpoint.sh --finished <id>`, carrying the same verified PR/MR URL when supplied to teardown; its [header](../../../bin/fm-retire-endpoint.sh) owns eligibility and forwarding to guarded cleanup.
3. Treat any other refusal - uncommitted work, unlanded work without a merged PR, a missing report, an open captain decision, a stream endpoint that would not confirm its stop, a window still listed - as not provably finished: never force or retry around it, and decide it yourself under the rule below.

Deciding a stopped or unproven worker is yours, never the captain's (his rule of 2026-10-18: "i dont want to make those decisions"):
- Retire it when its work is done, merged, superseded or abandoned: use step 1's guarded cleanup and preservation path, respecting its documented limits.
  For an explicitly accepted finite diagnosis or superseded ship whose original dirty allocation must remain, use [`fm-retire-endpoint.sh`'s accepted-result path](../../../bin/fm-preserved-result-lib.sh); its header owns acceptance evidence, retained-allocation safeguards and retry, separately from landed-work teardown.
- Retry it when the work is still wanted and unfinished - its task is open, no PR of it landed, and nothing superseded it: use [`fm-control.sh`'s relaunch path](../../../bin/fm-control.sh) with a note that tells the worker why it is restarting and what to continue.
- If you really cannot tell, ask your own first mate (in a second mate home, one `needs-decision` line on the parent channel); the captain sees at most a one-line FYI in your chat or notes, never a card.
[`bin/fm-idle-sweep.sh`'s header](../../../bin/fm-idle-sweep.sh) owns the automatic version of this rule.

Then close this home's record-less leftovers: endpoints the hub still lists live for a task whose record here is already gone.
Use `fm-retire-endpoint.sh`'s read-only orphan listing, then close each listed task/endpoint pair with its orphan mode and endpoint pin; its help owns invocation mechanics and listing limits, and [`fm-retire-orphan-lib.sh`'s header](../../../bin/fm-retire-orphan-lib.sh) owns eligibility and timing limits.
Treat its refusal the same way: never retry around it, and settle it yourself or ask your first mate, never the captain.

See the sweep header for how long handoff suppression lasts and when changed evidence becomes eligible again.

On every heartbeat sweep, also run `bin/fm-pr-record-audit.sh` for this home, plus `FM_HOME=<home> bin/fm-pr-record-audit.sh` for each local secondmate home in the main home.
Its [header](../../../bin/fm-pr-record-audit.sh) owns mismatch selection, diagnostics, and exit status.
Reconcile your own mismatches, and send a secondmate's mismatch line to that mate unchanged through `bin/fm-send.sh`; neither the helper nor the sweep rewrites another home's records.
For a `run with --migrate` diagnostic, follow the audit header's migration contract in the home that owns the row.

## After teardown

After successful teardown, record completion, retain only the configured recent Done history, and re-evaluate queued work whose blockers and time gates have cleared.

## Scout outcome

Read and relay a completed scout's findings, record its report as the Done artifact, and re-evaluate the queue.
When a scout's deliverable is a visual artifact the captain will iterate on, prefer keeping that scout alive to host its own Lavish loop rather than tearing it down and mediating from firstmate, so the scout keeps its investigation context and the captain iterates in one continuous session.
`bin/fm-promote.sh` renders the promoted worker's instructions: inventory scratch state, return to a clean default-branch base, carry over only intended fix changes, create the ship branch, and follow the project's selected delivery path while leaving scratch commits and debug edits behind and turning a reproduced bug into the regression test.
