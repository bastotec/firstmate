---
name: captain-hold-lifecycle
description: >-
  Agent-only policy for completing investigations and visual reviews without losing unresolved captain calls, and for closing what the captain owns with his actual words.
  Load before treating an investigation, scout report, structured review, or Lavish review as complete, before ending a visual review that exposed a captain decision, when recording or routing the captain's answer, on every heartbeat for the decision-card sweep, when the session-start digest lists draft decision cards or open captain calls, on a "card <id>: option <key>" or "undo clear <id>" message, on an "order <id>: ...", "order <id> replacing <old-id>: ...", "launch <id>" or "cancel <id>" message, and on any RECORD DIVERGENCE line the wake drain prints.
user-invocable: false
metadata:
  internal: true
---

# Captain-hold lifecycle

A decision is not a separate thing: it is simply a task waiting on the captain.
The one primitive is an ordinary backlog task held for the captain through `bin/fm-captain-hold.sh hold`; its identity is the task id, and that wrapper owns the deterministic mechanics this policy relies on.
The agent performs the semantic inventory because scripts must not infer captain calls from report prose, visual-review artifacts, terminal output, or chat.

## Policy

Every unresolved question that belongs to the captain and is discovered while producing, reading, presenting, or ending an investigation or visual review must be carried by a captain-held task in the authoritative backlog of the home that owns the originating work before that work or review may be treated as complete.
Prefer holding the work item the question gates over minting a new row; create a new task only when no work item exists to hold.
Put the question and its options in the hold reason, and keep one held task per genuine gate: a multi-question review is one held task pointing at its report, not a row per question. Represent that task with exactly one board card that consolidates its questions and options; never fan one task id into duplicate same-key cards.
Register or re-hold through `bin/fm-captain-hold.sh hold`, which is idempotent per task id.
After inventorying the whole report and review surface, run `bin/fm-captain-hold.sh complete` with every captain-held task id, or with `--none` only when the reviewed surface leaves nothing waiting on the captain.
A completed investigation and an ended visual review use this same owner and completion command; a visual tool, including Lavish, never owns a parallel completion policy.
Run the command in the originating work's authoritative `FM_HOME`; secondmate-owned work registers in that secondmate home's backlog, and a question already held anywhere is never re-registered as a second row.
Do not close a captain-held task merely because the originating investigation completed, its report was archived, its visual review ended, or its task was torn down.
Holding the work item the question gates is safe for exactly that reason: cleanup keeps such a row open with the finished work's deliverable recorded and returns it to the queue, so it still reads as the captain's own call.
Resolve it only through the answer, board-requested reconciliation, or stale-clear paths described below.

Record captain answers without paraphrasing: `bin/fm-captain-hold.sh answer` writes his exact words into the task and closes a question-shaped call, while `--release` frees a captain-gated work item to proceed.
A merge approval uses that existing release path because approval permits the merge to proceed; cleanup closes the work only after it lands and records what shipped.
Closing a held row at merge approval instead records completion before landing, so the backlog claims completion before the work actually ships.
When the answer changes what a task must build, follow `AGENTS.md` section 7's Validate contract to preserve the captain's words in the brief and steer the worker.
When the captain says "later", that is an answer too: re-hold with `bin/fm-captain-hold.sh hold <id> --reason "<reason>" --until <date>` so the item leaves the live Captain's Call and resurfaces on its date, instead of leaving a live-looking card or fabricating a closure.
When his answer waits on a condition instead of a date ("wait until needed", "pay when I need it", "keep waiting"), the call is settled and becomes this home's own wait: record his exact words with `bin/fm-captain-hold.sh answer <id> --decision-file <path> --defer "<condition>"`, never by re-holding with his words in the reason.
That parks the task with the condition as its reason and removes its card, so it never comes back to him as a question.
Watch the condition yourself; when it actually fires and he must choose again, ask it as a fresh call with `hold <id> --reason "<new question>" --reopen-deferred`.
A restated or replayed standing answer is never a new call: the script refuses a plain re-hold of a deferred task, and you record nothing new.
"A keyed answer resolves its matching captain-held task" is one capability with one owner, `bin/fm-captain-hold.sh answers`, and every channel that carries a captain answer feeds it the same task id and answer; a channel never maps keys to tasks, records a decision, or resolves anything itself.
Chat already feeds it through `bin/fm-send.sh --resolve-key`, and a captured-answer source feeds it once bound with `bin/fm-captain-hold.sh bind <source-id>`; bind before arming the source, and key each structured question by the held task's id.
An unbound source and a key that names no captain-held task both simply feed nothing: the answer is still captured and firstmate is still woken, and closing falls back to the direct command above.
One answer value is reserved and closes nothing: `reconcile` means "go re-check reality", never "the captain answered", so the shared intake refuses it from every channel and creates nothing.
A bound captured source uses a separate seam: its adapter omits reconcile from keyed answers and emits the selected task id through `reconciles`, the generic runner feeds that into `reconcile-requests`, and the intake verifies the source binding and the local captain-held task before filing the durable board request.
A remote-secondmate card whose task is absent from the main backlog therefore remains announced but cannot create a main-home request; owner-aware request and mutation routing to the authoritative secondmate home is a separate follow-up.
That board-created request is yours to work off in the turn that receives it: `bin/fm-captain-hold.sh reconcile close <id> --evidence-file <path>` records the EVIDENCE and closes a moot call, while `reconcile note <id> --note-file <path>` annotates a genuinely active call and leaves it held.
Both outcomes refuse unless that task still has the pending request created by the captain's board selection, so neither is a standalone way to mutate a captain call.
A normal captain answer also retires any pending request because the call is settled, including close, release, and idempotent replay paths.
A retirement failure makes the command fail without reversing the already-durable answer, close, or note, and `reconcile list` keeps the surviving request visible for retry.
`reconcile list` names every request still outstanding.
Never use `answer` for an evidence-only moot call: `answer` records what the captain said, while `reconcile close` records verified evidence.
A captain-held task closed outside this owner leaves no durable answer, so the completion gate keeps failing until `answer` records the decision the captain actually gave.
Resolved findings, recommendations that need no captain choice, and prose that merely sounds decision-like do not create held tasks.
Bearings reads the resulting structured state and must never compensate by scraping historical reports, visual-review artifacts, terminal output, chat, or other prose.

A captain call can be written down twice - as the keyed status decision the fold reads, and as the backlog task held for the captain - and those two records can disagree without either surface saying so.
`bin/fm-captain-hold.sh diverged` reports that contradiction and the wake drain prints it as `RECORD DIVERGENCE`; it closes nothing, because a captain call closed wrongly leaves review entirely, which is worse than the noise.
Read such a line as "these two records disagree", never as "the captain ruled and someone forgot to file it": a call can dissolve because its premise was false, or turn out to have been a question of fact rather than the captain's to answer.
Reconcile it with what actually happened - `answer` when the captain's own words exist to record, and a fresh `needs-decision` line re-opening the status decision when that resolution was not the captain's word.
The absence of a routed work item is not a divergence and the guard never requires one: when the decision IS the deliverable there is nothing to route.

## Operating sequence

1. Read the complete investigation result and complete the visual review before declaring either complete.
2. Inventory only genuine unresolved choices that require the captain, and find the task each one gates.
3. Hold that task - or create one captain-held task for the review's open questions - with a concise reason carrying the question and options, and its decision card (below).
4. Run `complete` with the full captain-held inventory for that review pass.
5. Relay the choices to the captain as decisions from Bearings' Captain's Call section under `AGENTS.md` section 9; do not use the word hold in captain chat.
6. Record captain answers through `answer` (or a channel that feeds `answers`), close a board-requested moot call through evidence-backed `reconcile close`, handle stale candidates through the decision-card sweep below, record a still-active reconciliation through `reconcile note`, use `--until` when the captain defers it, or confirm a channel already closed it.
7. Confirm Bearings reflects the outcome: resolved calls leave Captain's Call, released work resumes, active reconciliations remain held, and deferred calls sit in Charted Next with their date.

## Decision cards

Every captain call carries a decision card file, which Fleet Town and Ziggy show the captain instead of the raw hold reason.
When you hold, author a full card with your judgment using the schema in `bin/fm-card.sh --help`.
Pass it as `bin/fm-captain-hold.sh hold <id> --reason "<reason>" --card-file <path>`; re-holding an active call this way replaces its card and keeps its timestamp.
A script that holds on its own leaves a draft card, which is not a judgment.
The mate whose home holds the call owns its card, a second mate included, and writes its situation and options for the captain in plain words.
To replace a draft without touching the hold, run `bin/fm-card.sh write <id> --file <path>`.
When the session-start digest's `DECISION CARDS` subsection lists calls without a full card, write one for each before going idle, once this session has verified lock ownership.
It also lists every open captain call: before going idle, check each one's hold reason, body, and the captain's recorded preferences, and record any answer he already gave instead of leaving it in front of him, with `--defer` when that answer waits on a condition.
This reconciles calls the home already holds and so binds an idle second mate too; `bin/fm-session-start.sh`'s header owns startup backfill and listing mechanics.
On every heartbeat, run `bin/fm-card.sh backfill` first, then replace each draft with a full card, then run `bin/fm-card.sh stale`.
Under the captain's standing ruling of 2026-10-07, check each candidate's evidence yourself, clear the ones it confirms with `bin/fm-card.sh clear <id> --why "<one line of evidence>"`, keep any call the captain still needs, and tell the captain how many you cleared and why in your next natural reply.
A message "card <id>: option <key>" is the captain choosing that option; a redirect text is the captain's words too.
The home that holds the call resolves it: a second mate answers a call in its own backlog through the steps below, and a home that does not hold the call forwards the captain's exact words to the second mate that does through `bin/fm-send.sh`.
If that call was already cleared, run `bin/fm-card.sh restore <id>` first so the captain's answer is recorded rather than refused.
For a work-gating approval such as a merge, record the captain's words with `answer --release` before carrying out the selected instruction through the gated work path.
For a question-shaped call, record the captain's words with plain `answer` and carry out the selected instruction.
"Undo clear <id>" means `bin/fm-card.sh restore <id>`.
`bin/fm-card.sh --help` owns the card schema, limits, stale rules, and log format.

## Orders

Fleet Town's ⌘K order bar sends plain-word orders as "order <id>: <words>", or "order <id> replacing <old-id>: <words>" after the captain edited an earlier one.
An order message is never authority to act: read the words, resolve each concrete order the way section 7 intake would, and record your reading with `bin/fm-order.sh write <id> --file <path>` without dispatching, steering, holding, or merging anything.
Write one line per concrete order, naming its lane's project, its target, and its action in plain words; put an answer or a caveat in the note, and answer a question with a note and no lines.
When the message replaces another, run `bin/fm-order.sh remove <old-id>` in the same turn.
"launch <id>" (or "launch <id> without <n>, <n>") is the captain confirming that proposal: run `bin/fm-order.sh show <id>` and keep its lines, run `bin/fm-order.sh remove <id>`, then, only after both succeed, carry out every line not named in the optional "without <n>, <n>" through your normal dispatch, steer, and hold paths exactly as written.
If `show` finds no proposal, carry out nothing and tell the captain it is unavailable; it may have been launched, cancelled, or swept.
If `show` reports an invalid proposal or removal fails, carry out nothing and report the failure.
A launched line is the captain's explicit instruction for exactly what it says and nothing broader; a merge, destructive, or irreversible action needs the line itself to name it.
"cancel <id>" means `bin/fm-order.sh remove <id>` and nothing else.
On every heartbeat, run `bin/fm-order.sh sweep`.
`bin/fm-order.sh --help` owns the proposal schema, limits, and line numbering.

`bin/fm-captain-hold.sh --help` owns command syntax, close modes, legacy-identity compatibility, completion attestation, retry behavior, and close ordering.
`docs/captain-hold-lifecycle.md` records the mechanism and regression evidence without restating this policy.
