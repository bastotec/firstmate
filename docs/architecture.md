# Architecture

How firstmate works, for maintainers.

The [README](../README.md) carries the high-level diagram and a short synopsis.
firstmate's supervisor contract and routing index for conditional procedures is [`AGENTS.md`](../AGENTS.md); this is the human-facing companion.
This page owns stable ownership, extension points, mechanism boundaries, and safety rationale.
Exact flags, paths, and record formats live in the named script headers.

## Event-driven supervision

A zero-token bash watcher (`bin/fm-watch.sh`) sleeps on the fleet, classifies each detected wake in bash, and wakes the first mate only when something is actionable.
The watcher header owns the printed reason vocabulary and every absorb and re-surface rule; this section owns why the rules have the shape they do.

### Absorb only on positive evidence

A no-verb wake, such as a `working:` note or a bare turn-ended signal, is benign only when every referenced task independently shows positive evidence that its crew is still working.
That evidence is an attributed active no-mistakes step or an exact busy verdict, both read through `bin/fm-crew-state.sh`.
Everything else surfaces, so a crew that finishes, or stops and waits, is never silently swallowed.
Absorbed wakes advance their suppression markers, log to `state/.watch-triage.log`, and keep the watcher blocking without a queue record or model turn.
Routine polling, supervision no-ops, elapsed waiting time, and absorbed benign wakes stay silent.

A home that creates `config/turnend-churn-absorb` lets an eligible bare turn-ended task without authoritative proof use a third form: pane content that changed since the previous poll, compared against the staleness backbone's own `state/.hash-*` marker.
That form stays opt-in because it infers execution from rendered bytes rather than from a verdict the harness vouches for ([`configuration.md`](configuration.md) "Turn-end pane-churn absorb").
It defers a wake rather than swallowing it and clears prior stale classification, since a crew that has stopped renders nothing further and its static pane surfaces through the staleness backbone within a poll or two.
The deferral is bounded per endpoint by `FM_TURNEND_CHURN_ABSORB_SECS`, after which the turn-end surfaces.
That bound is required: churn and staleness read the same pane, so a pane that renders continuously, such as a clock, a spinner, or a renderer left alive after the agent yields, never reaches the two-identical-hashes staleness test, and an unbounded absorb would leave a stopped worker behind it with no path to surface.
A wake naming any status file, and any batch that references a secondmate, gets only the strict authoritative proof.
Every unreadable or ambiguous input surfaces the wake without clearing prior stale classification; `bin/fm-watch.sh`'s `signal_turnend_panes_churned` owns the exact evidence and fail-closed list.

A `kind=secondmate` task's status signal is its parent-directed reply stream and is never absorbed as provably working.
Its bare turn-ended signal is absorbed only by the authoritative proof, because an active secondmate does not enter the staleness backbone that would resurface deferred churn evidence.

### Stale panes and the wedge ladder

Stale panes take the same current-state read before the status log is trusted, so an active run or a proven busy worker outranks an old captain-relevant log line.
A busy pane is exempt from staleness only until its last completed turn or explicit progress reaches `FM_BUSY_TURN_MAX_SECS`.
Past that bound, and for provably-working stale panes past `FM_STALE_ESCALATE_SECS`, the pane takes the wedge escalation: an escalation count in the reason and, at `FM_WEDGE_DEMAND_INSPECT_COUNT`, a `demand-deep-inspection` marker.
Escalation is for inspection only, never an automatic interrupt, signal, or restart of the worker or its tool process.

A task whose current-state read has reconciled `done` and whose metadata records its PR or MR is already a completed delivery held for merge, not working liveness.
Its expected quiet pane is absorbed instead of entering the wedge ladder in both attended and away supervision.
The daemon also clears stale markers left from earlier work and refuses to turn an enriched-wedge wake queued before reconciliation into a wedge escalation.
A `done` read without a recorded PR or MR keeps the ordinary stale alarm path, while new status events and the eventual merge remain independent actionable wake sources.

A pane whose recorded task worktree holds a file newer than its quiet window is deferred instead of escalated, because a crew writing files behind a static pane is liveness that neither pane quietness nor the run step can show.
That deferral re-surfaces on the `FM_PAUSE_RESURFACE_SECS` cadence and costs one pruned, depth-bounded, wall-clock-bounded walk taken only when about to escalate, never on every poll.
Every absence of write evidence, including a missing worktree, a walk that outlives its bound on a hung mount, and a failed walk, leaves the escalation schedule untouched.
A secondmate's worktree is never probed, because it is a firstmate home whose own supervision keeps writing inside it whether or not the mate produces anything.

### Declared waits

Four records declare that a crew waits on something outside the fleet: a worker's `paused:` status line, a supervisor-declared external wait recorded by `bin/fm-external-wait.sh` for a worker that cannot write its own line, a verified `captain-held` status transfer, and the backlog captain call `bin/fm-captain-hold.sh` records.
A declared wait re-surfaces on the long `FM_PAUSE_RESURFACE_SECS` cadence instead of being treated as a wedge, busy or idle, and the re-surface names which human or declarer the wait is on.
For a stopped ordinary crew the first sight still surfaces one stale wake, with inconclusive liveness fail-open, so a worker genuinely waiting on a decision is never silenced.
A supervisor declaration's expiry alone restores ordinary escalation, and no declaration suppresses a genuinely new status line, check result, terminal outcome, or PR merge.
A backlog captain call's first sight alarms and later alarms in its window are throttled, scoped to the call's lifecycle so a release and re-hold starts fresh; an unreadable backlog or incompatible `tasks-axi` leaves the ordinary alarm path unchanged.
Within this pause guard, a secondmate's endpoint liveness is never read, and it reaches the pause cadence only through a status-line declaration, so a forgotten `paused:` cannot rot invisibly; a backlog-only secondmate hold is outside this guard to keep backlog reads off the poll hot path.
While the away-posture record exists, captain-held work is not rechecked and waits for the return brief.
`tests/fm-watch-triage*.test.sh` and `tests/fm-external-wait.test.sh` pin these boundaries.

### Durable wake queue and drain

Actionable wakes are written to `state/.wake-queue` only after generation-bound recovery evidence is published, and stay until the exact acknowledgement `bin/fm-wake-drain.sh` prints succeeds after handling.
[`watcher-continuity.md`](watcher-continuity.md) owns the arm layer, recovery episodes, and queue acknowledgement.

Crew status files are append-only wake-event logs, not current-state fields.
Reading only the latest line would bury an earlier open `needs-decision` or `blocked`, so every drain prints a fleet-wide OPEN DECISIONS section through the `status_open_decisions` fold in `bin/fm-classify-lib.sh` until the decision is explicitly resolved.
The drain header owns its other sections (UNREAD STATUS, STATUS OUTCOME BACKSTOP, RECORD DIVERGENCE) and the cursor, which never advances across uncertain bytes; [`captain-hold-lifecycle.md`](captain-hold-lifecycle.md) owns record divergence.
The resolution is written by the actor that answers, not the busy worker: `fm-send.sh --resolve-key` appends the closing line to this home's ledger copy, which covers crewmates and local and remote secondmates alike.
Answerer closes use the provenance-guarded append in `bin/fm-wake-lib.sh`, which advances the watcher marker only across its own bytes and fails toward an ordinary wake when foreign bytes are pending.

Every drain also runs the supervision liveness guard, so a lapsed watcher chain surfaces even on a turn that only handles queued wakes.
`bin/fm-guard.sh` warns, and never blocks, when the primary checkout is tangled, when supervised sources have an unhealthy verdict, or when queued wakes wait for main.

### Other wake sources

A validated PR poll that reads exactly `merged` goes through the shared emitter in [`bin/fm-merge-outcome-lib.sh`](../bin/fm-merge-outcome-lib.sh), whose header owns routing and the at-least-once ordering that prefers a rare duplicate over silence.
The poll then retires through a receipt bound to its identity; a concurrent replacement stays armed, and retirement never performs task or secondmate cleanup.

The primary watcher reads, without locking or rewriting, the oldest actionable row in each endpoint-recorded local secondmate's wake queue.
Endpoint liveness and queue consumption are separate, so a queue position that has not moved for `FM_SECONDMATE_WAKE_STALL_SECS` while the mate is not provably in a turn gets one keyed `check` wake per episode, while draining, declared-wait, and empty queues stay silent (`tests/fm-wake-queue.test.sh`).

`bin/fm-inactive-reconcile.sh` runs on its own bounded poll cadence and in session start's deferred network stage, accepts only `done` or `failed` for long-inactive direct crewmates, and performs no forge check.
A secondmate home's terminal outcomes, PR registrations, holds, and merges reach its parent through the scripts that record them ([`secondmate-parent-channel.md`](secondmate-parent-channel.md)).

### Current-state reads

`bin/fm-crew-state.sh <id>` is the cheap current-state read, and its header owns the precedence.
An attributed no-mistakes run step is authoritative even if the pane has closed, under [`bin/fm-nm-run-lib.sh`](../bin/fm-nm-run-lib.sh)'s attribution rules, and a live run outranks a terminal one so a crashed run never reports a healthy task as failed.
A run whose only failure is the ci monitor after checks read green reports done, because a monitor observing a human merge decision must not turn its absence into failure.
A terminal record whose daemon a probe proves down reports unknown, because an instrument failure must never read as work failure.
Without a matching run, exact busy reports working, exact idle permits the status-log fallback, and unknown or dead stays unknown rather than trusting a stale log.

`bin/fm-fleet-snapshot.sh --json` emits the `fm-fleet-snapshot.v1` contract that `bin/fm-fleet-view.sh` and `bin/fm-bearings-snapshot.sh` render, and its header owns the schema and remote-home collection.

### Registered secondmate current state

A registered secondmate's validated home is the authority for its current state, because it owns the child inventory, child states, endpoint observations, holds, keyed decisions, and recent Done baseline.
Treating the mate as an ordinary parent task would let an idle mate's latest append-only parent event read as current work after its home had moved that work to Done.
Generated charters therefore key only supervisor-actionable phase reports and close them with a same-key later state or `resolved`, while the structured home stays authoritative when that closure is missing.
Cross-home reads validate identity and directory boundaries and classify unavailable or inconsistent structured state as unknown rather than reviving a parent event.
A bounded terminal tail may be shown for diagnosis, but scrollback and agent prose are not durable state, so it is stripped of control sequences and never overrides a valid structured classification.
Live GitHub enrichment exists only behind the bearings `--include-prs` opt-in.
Optional Relay integrates with the watcher only after explicit opt-in; [`relay.md`](relay.md) owns its mechanics.

### Session start and watcher arming

At session start, `bin/fm-session-start.sh` emits one supervision block rendered by `bin/fm-supervision-instructions.sh` from [`supervision-protocols/deck.md`](supervision-protocols/deck.md), which owns the handling duty for the [Deck chat host](../bin/fm-deck-chat.sh) primary and Deck-hosted secondmate homes.
The chat host's supervisor child owns the primary's watcher and a secondmate's `bin/fm-deck-worker.sh` driver owns its own, so neither depends on the model remembering to re-arm.
`bin/fm-watch-arm.sh` forks the watcher as a tracked child, verifies a fresh liveness beacon, and prints an honest `started`, `attached`, or nonzero `FAILED`.
Its `--restart` signals only the watcher in the current home's `state/.watch.lock`, so restarting one home cannot kill sibling watchers.

### Away mode

Away mode is a posture of the one supervision session, recorded in `state/.afk-contract` by `bin/fm-afk-contract.sh` after the captain confirms a read-back of their away words and mandate clauses; that header owns the schema.
Clauses are recorded verbatim and checked only structurally, and judgment belongs to the supervision session at execution time.
Forbidden, destructive, irreversible, and security-sensitive actions are never pre-authorizable regardless of clause text, and no recorded clause is authority by itself.
On return, `bin/fm-afk-return.sh` owns ordered shutdown, the archive, the return brief, and the fail-closed gate that keeps ordinary work behind every live blocker the away session could not fix.

The presence-gated sub-supervisor `bin/fm-supervise-daemon.sh`, started by the `/afk` skill, owns triage while its `state/.afk` flag exists, and the watcher runs one-shot.
Both share `bin/fm-classify-lib.sh` and classify every byte appended since they last read a log, never its last line alone.
The daemon escalates as one batched digest with the canonical `away-supervisor` kind from `bin/fm-operational-input.sh`, so firstmate can tell it from a real message.
For typed-input delivery, it types only into a composer `bin/fm-composer-lib.sh` classifies as affirmatively `empty`, so every other or future verdict defers.
Stalled delivery writes `state/.subsuper-inject-wedged` and attempts an active alert after `FM_MAX_DEFER_SECS` instead of deferring forever.
Away housekeeping has no worktree-write deferral, so a quiet crew that is not a completed delivery held for merge still escalates as a possible wedge.
[`configuration.md`](configuration.md#away-mode-supervisor-backend-fm_supervisor_backend--fm_supervisor_target) owns the supervisor transport, delivery routing, and fallback, and the [`afk` skill](../.agents/skills/afk/SKILL.md#busy-guard-and-composer-guard) owns the typed-injection guards.

### Data plane and control plane

Text for a worker to read and commands that drive a worker's process are separate planes.
`fm-send.sh` is the data plane, and its header owns inbox and typed-plane routing.
It always routing-marks a `kind=secondmate` target, which is right for a message and wrong for a lifecycle command, because a marked exit command arrives as chat the agent reasons about instead of executing.
A task inbox's doorbell is never typed into a dead or missing endpoint; the record surfaces once for recovery instead.
`bin/fm-control.sh` is the control plane, and [`agent-control.md`](agent-control.md) owns its verbs, relaunch transaction, and fail-closed boundaries.

## Busy state is semantic, per adapter

`bin/fm-busy-lib.sh` is the single owner of what "this worker is busy" means, and `bin/fm-busy-event.sh` is the only writer of its records.
Every classification returns busy, idle, unknown, or dead with the source that produced it, so semantic state is never confused with a fallback.
Deck reports its turn lifecycle through the `bin/fm-deck-worker.sh` driver as the `deck-wrapper` source, and a record from a source not trusted for the recorded harness classifies unknown.
Missing, malformed, stale, or unverified state is unknown, never idle, and unknown is never promoted to busy.
Consumers act only on an exact busy verdict, so an unreadable worker surfaces instead of being absorbed as working or written off as finished.
Endpoint death is the only process-level override; child processes, CPU, sleep state, and marker modification times are not state signals.
Each record is bound to an incarnation token minted when the task is armed, so a superseded incarnation's event is rejected.
`state/<id>.turn-ended`, touched by the Deck driver at turn end, is a wake notification, not current state.

## Runtime session backends

The runtime backend is the session-provider layer below firstmate's scripts: endpoint creation, bounded capture, text and key sends, current-path reads, agent-process probes, and teardown.
Teardown carries one contract the layer above depends on: a kill reports whether the endpoint is gone, could not be proved gone, or could never be attempted, and only the first licenses removing the records that assert a worker stopped (`fm_backend_kill` in `bin/fm-backend.sh`).
`bin/fm-backend.sh` centralizes selection, `state/<id>.meta` helpers, endpoint identity validation, and dispatch to the one adapter, `bin/backends/stream.sh`.
Records left on the retired tmux and herdr backends read as undrivable rather than crashing, and `bin/fm-retire-endpoint.sh` retires them.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns selection, the refusal of other names, and legacy-record compatibility.
stream's session host is the fleet's own hub, and each task's pseudoterminal is owned by a thin agent on the machine that runs it.
Relaying that pty adds one state a local terminal lacks: a silent agent reads `unreadable`, never `dead`, because an unreachable worker and a stopped one look the same from the hub.
[`stream-backend.md`](stream-backend.md) owns setup, security model, and limits, and [`verification/runtime-backends.md`](verification/runtime-backends.md#stream) owns live evidence.

## Worktrees, not branches in your checkout

Crewmates never intentionally touch your project clone: [treehouse](https://github.com/kunchenguid/treehouse) pools clean worktrees, and stream only provides the session.
The [`fm-spawn.sh` header](../bin/fm-spawn.sh) owns worktree isolation and fresh-base refusal, pinned by [`tests/fm-spawn-pool-base-freshen.test.sh`](../tests/fm-spawn-pool-base-freshen.test.sh).

The firstmate repo has one extra exposure because it can dispatch crewmates to work on itself.
Its operating checkout (`FM_ROOT`) and crewmate worktrees are linked worktrees of one repository, so the discriminator is branch state: the primary is healthy on its default branch, linked worktrees and secondmate homes at detached HEAD, and only a named non-default branch in `FM_ROOT` is a tangle.
`fm-tangle-lib.sh` owns that classification; `fm-guard.sh` and session start report it, read-only when another live session holds the fleet lock.
Because placement is proven only at launch, `bin/fm-spawn.sh` exports `FM_TASK_ID` into every ship and scout endpoint, and `bin/fm-test-run.sh` refuses to run the suite from the primary checkout while it is set ([`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh)).

## No-mistakes gate authority boundary

Firstmate's own no-mistakes gate runs agents inside a checkout that also contains the fleet-captain identity in `AGENTS.md`, so gate execution needs an authority boundary separate from ordinary crewmate worktree isolation.
The tracked `.no-mistakes.yaml` sets `disable_project_settings: true`; no-mistakes honors that setting only from the trusted default-branch copy, so a pushed branch cannot enable its own project instructions during validation.
Independently, `fm-spawn.sh`, `fm-send.sh`, `fm-control.sh`, and `fm-teardown.sh` source `bin/fm-gate-refuse-lib.sh` and refuse fleet mutation under its gate-context contract.
The [Deck chat host](../bin/fm-deck-chat.sh) and [primary steer CLI](../bin/fm-primary-steer.sh) apply the same boundary to their mutating entrypoints; the steer CLI's status and delivery reads remain available.
A normal primary checkout or crewmate worktree has neither signal and is unaffected.
The helper's header owns the exact signal detection, relocated-home limitation, test-harness bypass, and relationship to no-mistakes' HEAD-continuity guard.

## Two task shapes

Ship tasks change projects and ship by project mode (`no-mistakes`, `direct-PR`, or `local-only`); scout tasks leave standalone investigation reports at `data/<id>/report.md` and never push.
The intake and authority contract in `AGENTS.md` owns when separate scout research is warranted.

## Dispatch profiles

Crewmate and scout dispatch uses either `config/crew-harness` or the natural-language profiles in [`config/crew-dispatch.json`](configuration.md#crew-dispatch-profiles-configcrew-dispatchjson).
The dispatch file is judgment-based: firstmate reads its rules at intake, resolves profile arrays from current quota output under the `AGENTS.md` section 4 boundary, and passes concrete axes to `fm-spawn.sh`.
The scripts validate shape and harness and effort combinations but never parse task intent or select from arrays.
When the file exists, `fm-spawn.sh` refuses crewmate and scout launches without an explicit harness, so the rules cannot be silently skipped.
Deck is the only harness and has no effort control, so validation rejects profiles with effort and spawn or relaunch refuses a non-default effort before creating metadata or stopping a worker.

## Optional secondmates

`data/secondmates.md` records persistent secondmates with natural-language scopes, project clone lists, and home paths.
A remote route keeps the home and all its child work on another host; [`remote-secondmates.md`](remote-secondmates.md) owns remote setup, transport, failure, and retirement.
`fm-home-seed.sh` provisions an isolated home transactionally, rolling back on any failure, and `fm-spawn.sh --secondmate` launches it through the same session-provider and status-file path as any direct report; [configuration.md](configuration.md#secondmate-routes-datasecondmatesmd) owns the seed contract.
A home seeded with `-` is a durable treehouse lease under the secondmate id, and a failed return at retirement leaves the route and home intact rather than hiding a still-held lease.
`local-only` projects stay with the main first mate because they merge into the main local checkout.

Secondmates are idle by default: after startup recovery of their own home, an empty queue waits silently, and they never self-initiate surveys or audits.
[`AGENTS.md` section 9](../AGENTS.md#9-escalation-and-captain-etiquette) owns secondmate reply routing, including captain-direct replies; `bin/fm-pending-reply-lib.sh` guards each reply-bearing request against a missing report.
Direct human typing stays unmarked, so captain intervention in a secondmate remains conversational.
`fm-backlog-handoff.sh` moves already-judged in-scope queued items to a secondmate and wakes it; its header owns delivery outcomes.
An unreachable remote host is unknown rather than dead, keeps its route and durable work, and is never failed over or relaunched locally.
Teardown refuses while the home has in-flight work unless the captain approved discard with `--force`.

`config/secondmate-harness` may carry optional model and effort tokens, an absent or `default` harness defers to `config/crew-harness`, and any harness other than Deck is refused (`bin/fm-harness.sh` header).
Those tokens are re-read on every spawn or respawn, and the `bin/fm-spawn.sh` header owns their override and inheritance rules.
`config/crew-harness` and `config/crew-dispatch.json` are inherited into secondmate homes, and homes converge conservatively to the primary's version at launch and locked session start.
The [`secondmate-provisioning` skill](../.agents/skills/secondmate-provisioning/SKILL.md) owns that sync and the [`data/secondmates.md` line contract](../.agents/skills/secondmate-provisioning/SKILL.md#routing-table).

## Delivery modes are explicit per task

`no-mistakes` tasks run the full validation pipeline, `direct-PR` tasks open PRs without it, and `local-only` tasks stay local until firstmate performs an approved fast-forward merge.
Each task's delivery mode and `yolo` merge posture are firstmate's decision at intake: pass the mode explicitly to `bin/fm-brief.sh` and both values to `bin/fm-spawn.sh` and `bin/fm-promote.sh`, each of which refuses to guess.
A ship brief records its mode as a fixed line and spawn refuses a mismatch, so the worker's instructions and the recorded delivery cannot diverge.
`bin/fm-dod-lib.sh` owns each mode's definition of done and the no-mistakes `--intent` contract for briefed and promoted workers alike, so a promoted worker cannot receive a weaker contract.
`data/projects.md` records each project's standing posture as the captain's default, and `bin/fm-project-mode.sh` parses it for consumers with no task in hand.
No-mistakes evidence goes to an orphan evidence branch that shares no history with code branches ([`configuration.md`](configuration.md) owns the setting).

PR-based merges go through `bin/fm-pr-merge.sh`, whose header owns forge mechanics.
It merges only after one live read confirms the PR or MR is open, mergeable, conflict-free, and green at the current head, and binds the merge to that head, because recorded metadata goes stale on a rebase.
`--auto`, `--admin`, and branch deletion need `--attended-override`, which never skips the live green check, the away grant, or a captain hold.
Only a confirmed landing records a landed outcome; a queued or unconfirmed request leaves its poll armed.

While the away-posture record exists, a merge needs `yolo=on` or an away grant, and the authority read and the synchronous forge command share the record's cross-subsystem lock, closing the common live-owner TOCTOU; a lock that cannot be taken refuses.
Auto-merge, `--allow-red`, and any base whose rules cannot prove the absence of a merge queue are refused while away.
This is confused-agent-grade, not fully atomic: it stops an accidental merge, not a determined bypass.
A queue-rule or PR-base change after the queue-free preflight can still enqueue a merge that lands after its away grant lapses, and killing the lock-owning shell while its forge child survives lets stale-owner recovery admit archive or replacement before that child completes.
These are accepted limitations, not oversights; durable authority, landing re-verification, and child-lock handoff are outside this boundary.
`bin/fm-afk-contract.sh` owns the lock, and `tests/fm-afk-contract.test.sh` and `tests/fm-pr-merge.test.sh` pin it; [`captain-hold-lifecycle.md`](captain-hold-lifecycle.md) owns the separate merge-to-cleanup residual.

A confirmed merge leaves a durable role-routed outcome rather than living in the merging agent's memory.
The merge path persists the resolved yolo, away-grant, or attended authority bound to the PR identity, and a later merged poll consumes only that value or records the landing as external rather than consulting a live away record that may have been replaced ([`bin/fm-merge-authority-lib.sh`](../bin/fm-merge-authority-lib.sh)).

Teardown is fail-closed for ship worktrees: dirty worktrees refuse, and committed work must be landed first.
A pool worktree is returned only after the slot-ownership proof passes, and no discard authority relaxes it; the spawn's own slot claim backs that proof because Treehouse's process lease cannot answer ownership once the worker's exit releases it.
Allocation and return serialize on one project lock per machine-local Firstmate tree, because a lock on one filesystem is not observable from another machine.
Teardown concludes the task's own parked no-mistakes run first, so cleanup never orphans a run the pipeline advanced past the submitted head.
[`bin/fm-teardown.sh`](../bin/fm-teardown.sh)'s header owns these proofs, and [`tests/fm-teardown-endpoint-safety.test.sh`](../tests/fm-teardown-endpoint-safety.test.sh) pins the slot boundary.

## Optional Relay

Relay is opt-in presence for the shared `@myfirstmate` bot on X and Discord, enabled by `FMX_PAIRING_TOKEN` in the home's gitignored `.env`; [`relay.md`](relay.md) owns its artifacts and wire contract.
That token is standing authorization for firstmate to answer public mentions and act autonomously on normal reversible requests.
Destructive, irreversible, or security-sensitive asks are escalated for trusted-channel confirmation instead of being executed from a public mention.
The relay uses owner-only routing: a mention delivered to a home is from that home's owner, while its surrounding conversation context may still include other public accounts.
Without the token, session start removes Relay artifacts and otherwise stays silent, so non-Relay users see no change.
Attached media stays as URLs the responding agent fetches, so the polling path never downloads third-party content.
The `fmx-respond` skill owns the response procedure, and the `bin/fm-x-*.sh` headers own replies, bounded follow-ups, task links, and dismissals.

A promised final public reply is a stronger commitment than a milestone follow-up, because forgetting it is publicly visible.
It is therefore not carried in conversation memory: intake turns it into a typed `kind=public-followup` obligation owned by `tasks-axi public-followup`, and every later step reads it from disk.
The boundary is deliberately narrow: `tasks-axi` is the only validator of a terminal result, `state/x-context/` the only owner of the private request context, and `bin/fm-x-reply.sh` the only thing that posts.
`bin/fm-public-followup.sh` composes those three, and `retire` is its only close.
Work routed to another home reports a typed result through `bin/fm-public-followup-emit.sh`; firstmate never recovers it by parsing a free-form `done:` sentence, and the child never learns the thread.
Event ids derive from their identity tuple, so duplicate reports and restart replay converge without coordination.
Reconciliation rides the existing relay poll and session-start digest, gated on the same `.env` activation, so a home that never opted in runs none of it ([operator contract](relay.md#promised-public-replies-statepublic-followup)).

## Project memory belongs to projects

Durable project-intrinsic agent knowledge lives in each project's committed `AGENTS.md`, with `CLAUDE.md` as a real `@AGENTS.md` import pointer, and `data/projects.md` stays a thin private registry.
[`bin/fm-ensure-agents-md.sh`](../bin/fm-ensure-agents-md.sh) owns the self-governance wording and refuses a case-variant file such as `agents.md` so the import resolves on a case-sensitive filesystem.
[`AGENTS.md`](../AGENTS.md) owns what is project-intrinsic versus fleet-private.

## Operational memory routing

`/stow` sweeps the session for knowledge that exists only in conversation and routes each finding to `data/captain.md`, the primary's `data/captain-shared.md`, home-local `data/learnings.md`, a project's `AGENTS.md` through crewmate delivery, or the backlog.
The internal [`stow` skill](../.agents/skills/stow/SKILL.md) owns tiers, decay, and archival.
It is not a reconciliation against repository or PR reality: its input is volatile context, so it can only preserve what the session still knows.
It never writes a skill, and in a primary home it cascades to every registered secondmate through `bin/fm-stow-cascade.sh` without letting an unreachable home block the primary.

## Local clones stay fresh

Locked session start, PR-based teardown, and merged-PR wakes fast-forward remote-backed project clones only when the clone is safe to move.
Dirty clones, non-default branches, detached HEADs with unique commits, and diverged defaults are reported as `STUCK:` and left untouched.
A stale `.git/packed-refs.lock` is removed only when the shared staleness proof shows it abandoned ([configuration.md](configuration.md#toolchain)).

## Self-updates stay safe

`/updatefirstmate` fast-forwards the firstmate repo and registered secondmate homes without touching project clones.
It restarts every live secondmate whose home ended on the target commit, because a restart is the only thing that re-resolves launch-time wiring.
A clean secondmate divergence may reconcile with `reset --keep` only when a temporary-index proof shows its tree is already present at the target; dirty, diverged, offline, and off-default targets are reported and left untouched.
The [`/updatefirstmate` skill](../.agents/skills/updatefirstmate/SKILL.md) owns the procedure.

## Restart-proof

Fleet state lives in each task's stream endpoint, no-mistakes run records, status event logs, local markdown under `data/`, and persistent secondmate homes.
[Secondmate lifecycle](stream-backend.md#secondmate-lifecycle) owns startup and watcher-run recovery, including deliberate-stop protection and inconclusive liveness handling.
Run `/stow` before an intentional reset when the conversation may hold knowledge not yet on disk.
