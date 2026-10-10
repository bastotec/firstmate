---
name: task-delivery
description: >-
  Agent-only procedures for the dispatch, validation, ready, landing, and scout-outcome steps of a task's delivery.
  Use before every spawn, when judging an active no-mistakes validation run's state, when the captain adds or changes the ask of a task under validation, when a worker hand-edits, commits, aborts, or restarts during its run, when a worker reports a PR or a ready local-only branch, before writing a custom watcher check, after a teardown, when a scout completes, and on every heartbeat for the finished-work sweep.
user-invocable: false
metadata:
  internal: true
---

# task-delivery

`AGENTS.md` section 7 owns intake, dispatch, delivery modes, merge authority, and the safety rules for each step below, and keeps them inline.
This skill owns the step procedures and does not restate those rules.

## Before spawning

Treat file or subsystem overlap as a risk signal rather than an automatic reason to wait, and dispatch isolated work immediately with no concurrency cap when each change can be independently implemented and validated and the selected delivery path can reconcile ordinary rebases or conflicts.
Serialize only for a true semantic dependency, shared mutable external state, incompatible concurrent migration, or another concrete condition that makes independent progress or reconciliation unsafe; same-file editing alone is insufficient, and genuine blockers remain durable.
Before spawning, check the work already in flight for the same problem, not just the same area: when the request is the same change a running task is already making, fold it into that task or stop, rather than dispatching a second worker to solve it again and notifying both.
Whenever work you dispatch touches an area another task is already working, say so in both directions before the new worker starts, and again whenever a new overlap appears mid-flight: name the other work and the files or subsystem it touches, both to the new worker and to every running worker it overlaps.
That notice is awareness rather than a hold, because the ship brief carries the worker's own half of the contract - rebase rather than design around the other change, and report a genuine semantic conflict instead of resolving it.
A worker rebases only while its branch is still its own to rewrite, and the branch-custody rules in the supersession and run-state sections below decide when that is, so a change that lands while the pipeline still owns the branch is never a steer into it.
Once custody is settled, getting the branch current is yours to own by steering or relaunching the worker.
A semantic conflict a worker reports is yours to decide or escalate, never to hand back.

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
Running, fixing, or CI states remain working; parked approval or fix-review states require the worker to follow the active gate help; passed or checks-passed is done; failed or cancelled is failed exactly as `bin/fm-crew-state.sh` prints it - only that state line reclassifies an orphaned ci monitor after green checks as held-for-merge done, or a terminal failed record with the daemon unreachable as unknown, never the raw run record.
A worker hand-editing, committing, aborting, or restarting during an active validation run duplicates pipeline ownership outside the supersession sequence above; steer it back to the gate response flow.
The worker reports the PR when CI first becomes green rather than waiting for merge monitoring to finish.

## PR ready

For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` reports `done: PR <url> checks green` after CI is green, while `direct-PR` reports `done: PR <url>` after opening the PR.
Run `bin/fm-pr-check.sh <id> <PR url>` with the URL copied from that ready signal - it records `pr=` and the forge's `pr_head=` when available in the task's meta and arms the watcher's merge poll.
Tell the captain the PR's full `https://...` URL copied from the worker's ready line or the task's `pr=` metadata, a concise outcome summary, and the no-mistakes risk level when applicable.
A captain instruction to merge is explicit authority; the standing-authority paths are owned by `AGENTS.md` section 7's "Selected delivery path and merge authority".
After an autonomous merge, give the captain a one-line full-URL or local-main outcome.
An auto-land `check:` wake from `bin/fm-autoland.sh` reports merges, deploy outcomes, and held green PRs with their reasons; a reported PR is yours to decide in the same turn rather than leave waiting on its owner.

## Custom checks

For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file, print one line only when firstmate should wake, print nothing otherwise, finish before `FM_CHECK_TIMEOUT`, then bind its current bytes with `bin/fm-check-register.sh <id>` before the watcher may execute it.
Retire a custom check only through `bin/fm-check-unregister.sh <id>` (or `bin/fm-teardown.sh` for a spawned task); never hand-compose an `rm` with `$STATE`/`$ID`.

## Finished-work sweep

`AGENTS.md` section 7 records the captain's standing instruction that the mate who created a worker cleans it up once its work is done.
Run this sweep when a ship lands, when a scout completes, and on every heartbeat, over this home's own direct reports and endpoint-bound leftover records only, never another home's, and never a secondmate, which retires only on an explicit decision.

A worker is finished when its PR merged or its local-only branch landed, or when it is a scout whose report exists and whose `captain-hold-lifecycle` completion gate passes.
A scout kept alive to host the captain's Lavish loop, or any worker whose work is still under way, is not finished.

For each finished worker:

1. Run `bin/fm-teardown.sh <id>`, never with `--force`.
2. If cleanup refuses only because the endpoint is on a retired backend and could never be confirmed gone, retire the record with `FM_HOME=<this home> bin/fm-retire-endpoint.sh --finished <id>`; its help owns what it accepts, and it never proceeds past unlanded work.
3. Treat any other refusal - unlanded or uncommitted work, a missing report, an open captain decision, a stream endpoint that would not confirm its stop, a window still listed - as not provably finished: stop, never retry around it, and hold one plain decision for the captain through `bin/fm-captain-hold.sh` naming the worker, the evidence, and the choice between cleaning it up and keeping it.

Then close this home's record-less leftovers: endpoints the hub still lists live for a task whose record here is already gone.
Use `fm-retire-endpoint.sh`'s read-only orphan listing, then close each listed task/endpoint pair with its orphan mode and endpoint pin; its help owns invocation mechanics and listing limits, and [`fm-retire-orphan-lib.sh`'s header](../../../bin/fm-retire-orphan-lib.sh) owns eligibility and timing limits.
Treat its refusal like step 3: never retry around it, and hold one plain decision for the captain naming the endpoint and the reason.

Once a worker's decision is held, later sweeps leave it to that decision rather than raising it again.
In a secondmate home that decision reaches the captain through the parent channel, as every escalation there does.

## After teardown

After successful teardown, record completion, retain only the configured recent Done history, and re-evaluate queued work whose blockers and time gates have cleared.

## Scout outcome

Read and relay a completed scout's findings, record its report as the Done artifact, and re-evaluate the queue.
When a scout's deliverable is a visual artifact the captain will iterate on, prefer keeping that scout alive to host its own Lavish loop rather than tearing it down and mediating from firstmate, so the scout keeps its investigation context and the captain iterates in one continuous session.
`bin/fm-promote.sh` renders the promoted worker's instructions: inventory scratch state, return to a clean default-branch base, carry over only intended fix changes, create the ship branch, and follow the project's selected delivery path while leaving scratch commits and debug edits behind and turning a reproduced bug into the regression test.
