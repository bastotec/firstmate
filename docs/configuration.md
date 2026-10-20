# Configuration

The files and environment variables you set to operate firstmate.

## Orchestrator behavior (AGENTS.md)

The shared orchestrator behavior lives in [`AGENTS.md`](../AGENTS.md) - edit it like any prompt when the fleet is empty, or dispatch shared-repo edits to a crewmate while tasks are in flight.

## Operational home layout and state

This section is the single owner of the operational-home layout; producer script headers and `--help` own exact child-file fields and mutation contracts.
The tracked code root holds the shared instructions, skills, documentation, workflows, and `bin/`, while each effective `FM_HOME` holds private operational directories.
`data/` holds durable private fleet records, `state/` holds runtime records and append-only status events, `config/` holds local operating choices, and `projects/` holds clones that firstmate changes only under the narrow captain-approved exceptions in `AGENTS.md`.
All four are gitignored, as are untracked names beginning with `scratchpad`, so temporary scratch never makes porcelain-based secondmate sync guards treat a home as dirty.
Only entries marked `inherited` below, plus `data/captain-shared.md`, propagate into secondmate homes ([`fm_config_inherit_items`](../bin/fm-config-inherit-lib.sh) declares the set); everything else is per home.
Entries marked "never touch" are watcher or sub-supervisor internals.

```
.env                      Relay pairing token (docs/relay.md) and mail-plane credentials ("Mail plane")
.tasks.toml               tracked tasks-axi backend config ("Backlog backend")
config/
  crew-harness            crewmate harness; absent or default = deck; inherited ("Harness support")
  secondmate-harness      secondmate launch profile "<harness> [<model>] [<effort>]" ("Harness support")
  crew-dispatch.json      optional dispatch profiles; inherited ("Crew dispatch profiles")
  backlog-backend         absent or tasks-axi, or manual; inherited ("Backlog backend")
  backend                 absent or stream; inherited ("Runtime backend")
  stream-hub stream-token stream-hub-tokens stream-machine stream-impl stream-native-dir  stream hub, credentials, fleet name, implementation; never committed (docs/stream-backend.md)
  launch-env-allowlist    optional worker environment allowlist; inherited ("Worker launch environment")
  secondmate-tool-path    explicit home-host tool directories; home-local, not inherited (bin/fm-deck-worker.sh header)
  startup-memory-budget   per-home startup-memory allowance; inherited ("Startup memory budget")
  trace-context           optional presence flag; inherited at launch ("Trace context propagation")
  stow-pass-horizon       optional presence flag ("Stow pass horizon")
  turnend-churn-absorb    optional presence flag ("Turn-end pane-churn absorb")
  wedge-alarm             optional away-mode alarm channels (docs/wedge-alarm.md)
  autoland.json post-merge/  optional auto-land repos and deploy hooks; primary home only ("Auto-land")
  watched-tools.json      optional tool update watch list ("Watched tool updates")
  ask-triage-key-var      optional possible-ask opt-in ("Possible-ask ranking")
  wake-gate-key-var wake-gate-mode  optional wake-gate opt-in and mode ("Wake gate")
  dream.json              optional fleet-dreaming configuration ("Fleet dreaming")
  effort-policy.json      optional per-turn reasoning effort switch and level ("Turn effort")
  deck-mcp.json           optional Deck MCP servers ("Harness support")
  primary-split           optional presence flag: conversation (captain thread) and inner monologue (supervisor); inherited (bin/fm-config-inherit-lib.sh); first mate: bin/fm_primary_chat.py header; second mate: bin/fm-captain-lane.sh header
  model-policy.json       home-local route policy for in-place switches (bin/fm_model_switch.py owns validation and policy semantics)
  merge-policy.json       the captain's per-repository merge policy (auto, ask, never); inherited; bin/fm-merge-policy.sh header owns shape and semantics
  power-host              optional ssh alias for fleet quota reads (bin/fm_report.py owns default and bridge flow)
  shared-skills           optional skills repo shipped to connected machines; primary home only (bin/fm-machine.sh header)
  vnc/<machine>.password  mode-600 VNC password per machine; primary home only (bin/fm-machine-vnc.sh header)
  ntfy/url ntfy/topic ntfy/token  firstmate's ntfy server for phone pushes (mode 600 token); primary home only, read by Fleet Town's feed
  notify-quiet            optional home-local notice quiet hours (bin/fm-notify.sh header owns syntax and defaults)
  machine-tunnels         optional gateway host whose model gateway and stream hub machine setup forwards (bin/fm-machine.sh header)
  bridges.json            home-local cross-machine permissions ("Bridge gates"; bin/fm-bridge.py owns schema)
  inbox-* voice-read-*    inbox model and voice-read settings ("Inbox and voice records")
  extensions.d/           mode-0700 explicit extension bindings (docs/process-event-sources.md)
  x-mode.env              generated Relay watcher cadence; written only by bootstrap (docs/relay.md)
data/
  backlog.md done-archive.md  task queue and archive ("Backlog backend")
  captain.md              domain-local captain preferences ("Captain Preferences")
  captain-shared.md       primary-owned shared preferences, read-only in secondmate homes
  learnings.md            curated fleet-local learnings, created lazily ("Operational learnings")
  projects.md             project registry and delivery posture (bin/fm-project-mode.sh)
  secondmates.md          secondmate routes ("Secondmate routes")
  machines.md             home-local machine registry (bin/fm-machine.sh header owns format and registration)
  charter.md              a secondmate home's seeded charter (bin/fm-home-seed.sh)
  <id>/brief.md           task brief, or secondmate charter brief
  <id>/report.md          scout deliverable; survives teardown
  specialists/<name>/     a specialist's memory.md and own skills/ (bin/fm_crew.py owns the layout)
  groups/<gid>/           a task group's merged report.md and kept member results (bin/fm_crew.py)
  extensions/packages/    read-only content-addressed extension packages (bin/fm-extension.sh)
state/
  <id>.meta               task metadata; bin/fm-spawn.sh owns base fields, "Runtime backend" the backend fields
  <id>.status             crewmate "<state>: <note>" wake events, not current state (bin/fm-task-state-lib.sh owns derivation)
  <id>.agent-diagnostics{,.1,.2}  stream-agent diagnostic records (`primary-chat.agent-diagnostics` for the statusless primary); format and limits are owned by docs/stream-backend.md; task-owned files are removed by teardown
  <id>.turn-ended         touched by bin/fm-deck-worker.sh at turn end
  <id>.deck-session       secondmate conversation binding; bin/fm-deck-worker.sh header owns format, resume eligibility, and retirement
  <id>.supervisor-session <id>.captain-lane  split secondmate supervisor binding and lane marker (bin/fm-deck-worker.sh "CAPTAIN LANE")
  <id>.captain-lane.log <id>.captain-lane.answered <id>.captain-lane.turn  captain-lane log, turn journal and running-turn marker (bin/fm-captain-lane.sh header)
  <id>.captain-lane.stale-noted  overdue hand-off delivery journal (bin/fm-captain-lane.sh "OVERDUE HAND-OFFS" owns format, reporting and resolution)
  <id>.supervisor-failing <id>.conversation-failing  secondmate lane-health episodes (bin/fm-deck-worker.sh "SUPERVISOR HEALTH", bin/fm-captain-lane.sh lane-health comment own escalation and recovery)
  <id>.supervisor-notes   owed supervisor conversation notes, one note text per line, oldest first; failed delivery is queued independently of health episodes and retried in order at every turn start and recovery; teardown removes it
  <id>.lane-heal-<lane>  the first mate's automatic relaunch and escalation of a second mate whose lane keeps failing, one record per lane (bin/fm-secondmate-revive.sh "LANE HEALTH")
  <id>.approval-wait approval-waits/  parent approval exclusion and release archive (bin/fm-approval-wait.sh owns schema, declaration and release)
  <id>.parked-run <id>.quiet-noted  parked validation episode and quiet-worker check-in marker (bin/fm-parked-run-watch.sh header)
  <id>.model <id>.deck-caps  in-place model choice and live driver capability (bin/fm-control.sh owns public behavior; bin/fm_model_switch.py owns capability checks)
  <id>.progress           in-turn native activity, read for the busy-age bound only (bin/fm-busy-event.sh)
  <id>.crew-state         local ship task's validation record for file watchers; bin/fm-task-state-lib.sh "PUBLISHED RECORD" owns fields, refreshes, and cleanup
  <id>.gate               validation gate JSON; bin/fm_gate_record.py's header owns fields, preservation, and cleanup
  <id>.gate-advice        a mate's recommendation for that gate; bin/fm_gate_record.py's header owns writing, freshness, and cleanup
  cards/<task-id>.json    captain-facing decision card; bin/fm-card.sh owns schema and storage, bin/fm-captain-hold.sh owns hold and resolution hooks
  cards-cleared.log       stale-card clear and restore log; bin/fm-card.sh owns fields and undo guards
  orders/<id>.json        order proposal waiting for the captain's launch or cancel; bin/fm-order.sh owns schema and storage
  approvals/<id>.json     tool-call or bridge-flow request awaiting approve or deny; bin/fm-approval.py owns answers, answered/ and grants/; bin/fm-bridge.py owns bridge requests
  approvals.log           approval gate audit log; bin/fm-approval.py owns events and fields
  bridges.log             bridge gate audit log (seeded, changed, blocked); bin/fm-bridge.py owns fields
  <id>.inbox/             durable steering inbox; written by fm-send, removed by teardown (bin/fm-task-inbox-lib.sh)
  <id>.backlog-close      pending backlog transition for an interrupted cleanup (bin/fm-backlog-transition-lib.sh)
  <id>.external-wait      declared bounded external wait; written only by bin/fm-external-wait.sh, archived in external-waits/
  <id>.reconcile-nudged   last inventory-reconcile nudge time (bin/fm-secondmate-reconcile.sh)
  <id>.revive secondmate-revive.log  mid-session second-mate revival record and log (bin/fm-secondmate-revive.sh)
  <id>.held-stopped       deliberate secondmate stop marker (bin/fm-control.sh)
  idle-sweep.json idle-sweep.log idle-sweep/<id>.raised idle-sweep/<id>.retried <mate>.idle-audit <mate>.idle-audit-missing  idle-worker sweep summary, log, handoff and retry markers, second-mate audit episodes and missing-summary grace marks (bin/fm-idle-sweep.sh)
  idle-sweep/.unhandled   main-home unhandled-set wake suppression marker; bin/fm-idle-sweep.sh owns its contents and reset contract
  <id>.check.sh <id>.check-trust  authenticated slow poll and custom-check binding (bin/fm-check-register.sh)
  <id>.pr-poll <id>.pr-poll-registration <id>.pr-poll-retirement <id>.pr-poll-merge-notified  PR merge poll records (bin/fm-pr-lib.sh)
  <id>.merge-authority    accepted merge authority (bin/fm-merge-authority-lib.sh)
  endpoint-retirements.log  endpoint retirement and leftover-close assertions (operator or owning mate); written only by bin/fm-retire-endpoint.sh
  pr-unbinds.log          wrong-PR metadata clear assertions; written only by bin/fm-pr-unbind.sh
  terminal-outcomes/      inactive terminal-outcome receipts (bin/fm-inactive-reconcile.sh)
  slot-quarantine/       preserved untracked leftovers from pooled worktree slots (bin/fm-spawn.sh header owns eligibility and destination layout)
  model-chain/            per-lane model cooldowns ("Model fallback chains")
  pending-replies/        parent-owned secondmate pending replies (bin/fm-pending-reply-lib.sh)
  captain-direct/ captain-direct.log  parent-side captain-direct delivery ledger and echo-guard log (bin/fm-captain-direct-lib.sh)
  captain-memory-* .captain-memory-*  captain-memory records and bookkeeping (bin/fm_captain_memory.py header owns files and mutation contracts)
  mate-mail/             primary-home peer-message spool and routing bookkeeping (bin/fm-mate-mail-lib.sh owns layout)
  mate-messages.log      primary-home peer-message oversight log (bin/fm-mate-mail-lib.sh owns fields)
  crew-time.log           per-home busy-state history for crew time; append-only; bin/fm-busy-event.sh appends, bin/fm_report.py reads
  home-summary.json       this home's ledger (bin/fm-home-summary-refresh.sh)
  machine-pending/<m>.json  a machine being connected: its checklist and planned second mates; bin/fm-machine-blocker.sh owns format and lifecycle
  machine-skills/<m>.tsv  each machine's `deck skills` inventory; bin/fm-machine-skills.sh owns format and refresh
  notices/<id>.json       notices for the captain's phone and Fleet app; bin/fm-notify.sh owns the record and its guards
  secondmate-summary-cache/  parent-side copies of remote ledgers (bin/fm-fleet-snapshot.sh)
  reconcile-notify/       one-shot Bearings reconcile requests (bin/fm-secondmate-reconcile.sh)
  primary-chat.json       live deck-chat primary record (bin/fm_primary_chat.py owns fields)
  primary-chat/           primary session, steering, keeper, model choice and switch records (bin/fm_primary_chat.py owns layout)
  supervisor-chat.json supervisor-chat/  the same records for a split home's supervisor (bin/fm_primary_chat.py owns layout)
  specialists/<name>.json specialists/<name>/  persistent specialist record, job history and job files; idle is intended, not a leak (bin/fm_crew.py)
  groups/<gid>.json groups/<gid>/  task group record and its run files until cleanup (bin/fm_crew.py)
  procevent/ procevent-inbox/ when/  process-event sources and results (docs/process-event-sources.md)
  extensions/ extension-invocations/  extension working state (docs/process-event-sources.md)
  decision-bindings/ reconcile-requests/  captain-answer bindings and reconcile obligations; written only by bin/fm-captain-hold.sh
  ask-triage/             possible-ask state; written only by bin/fm-ask-triage.sh
  wake-gate/              wake-gate decisions; written only by bin/fm-wake-gate.sh
  dream/                  private fleet-dreaming digest, run records and summary (bin/fm_dream.py header owns files)
  effort-policy/          turn-effort escalation and heartbeat fingerprint; written only by bin/fm-effort-policy.sh
  inbox/                  captain notes ("Inbox and voice records")
  x-watch.check.sh x-inbox/ x-context/ x-outbox/ x-poll.error x-poll.claim-error  generated Relay state (docs/relay.md)
  public-followup/        promised public replies (docs/relay.md)
  tool-updates.check.sh .tool-updates  watched-tool check ("Watched tool updates")
  autoland.check.sh autoland/  auto-land check, deploy records, hook logs ("Auto-land")
  mail.check.sh .mail-check .mail-*  mail check and poll records; written only by bin/fm-mail.sh and bin/fm-mail-check.sh
  .startup-network.*      deferred startup stage records (bin/fm-startup-network.sh)
  .wake-queue .main-eligible-rows  durable wakes and row claims (docs/watcher-continuity.md)
  .watcher-down           watcher recovery state; never touch
  .<id>.open-decisions-cursor .status-presentation-*  status scan cursors (bin/fm-classify-lib.sh); the first is safe to delete
  .afk-contract afk-contracts/  away-posture record and archive; written only by bin/fm-afk-contract.sh
  .afk                    away or quiet mode flag (fm_afk_mode in bin/fm-wake-lib.sh)
  .afk-daemon.out .afk-launch.lock .afk-daemon-terminal  away daemon launch records (bin/fm-afk-launch.sh)
  .<id>.crew-state.lock .<id>.crew-state-follow .<id>.crew-state-follow.rearm  validation publication, follower ownership, and re-arm internals (bin/fm-task-state-lib.sh); never touch
  .watch.lock .wake-queue.lock  watcher singleton and queue locks
  .hash-* .count-* .stale-* .stale-since-* .churn-since-* .paused-* .ext-wait-resurfaced-* .wedge-escalations-* .writing-* .seen-* .hb-surfaced-* .last-* .heartbeat-streak  watcher internals; never touch
  .watch-triage.log       absorbed-wake debug log; safe to delete
  .last-watcher-beat      watcher liveness beacon read by guards
  .subsuper-* .supervise-daemon.*  sub-supervisor internals; never touch
```

`bin/fm-classify-lib.sh` owns status-event vocabulary, and the producing PR and Relay helpers own the meta fields they append.
`bin/fm-session-start.sh`'s header owns session-start ordering, blocking reads, and the digest; `bin/fm-startup-network.sh`'s header owns the deferred checks and inactive-outcome scan.
`AGENTS.md` keeps the run-once and read-once rules, lock-refusal safety, installation consent, and direct-report recovery boundaries; `stuck-crewmate-recovery` owns dead-direct-report recovery and `secondmate-provisioning` owns persistent-secondmate recovery.

## Model fallback chains (spawn-side)

Every spawn-side model surface accepts a fallback chain: a `config/crew-dispatch.json` profile's `model`, the model token in `config/secondmate-harness`, and `fm-spawn.sh --model`.
One `<provider>/<model-id>` label is an exact pin: it never consults cooldowns, never falls through, and never resolves through a lane, so an explicit captain pin launches exactly that model or refuses.
A comma-separated list such as `codex/gpt-6-luna,zai/glm-5.3,vercel/xiaomi/mimo-v2.6-flash` resolves in preference order at spawn or relaunch, and a malformed or duplicate label refuses loudly by name.
The captain-approved chains are: workers `codex/gpt-6-luna,zai/glm-5.3,vercel/xiaomi/mimo-v2.6-flash`, second mates `codex/gpt-6-luna,zai/glm-5.3-flash,vercel/xiaomi/mimo-v2.6-flash`, and hard tasks `codex/gpt-5.6-sol,vercel/xiaomi/mimo-v2.6-pro,zai/glm-5.3`.
A model refused at launch (quota, cooldown, or a repeated provider error) is recorded in its lane's `state/model-chain/<lane>.state` and sits out five minutes, doubling up to an hour on repeated failures.
`bin/fm-record-model-refusal.sh <task-id> <provider/model>` records a refusal read from a worker's status or transcript, and clears the lane when the launch ultimately succeeded.
Secondmate defaults share the `secondmate` lane, while every crew-side chain (explicit, dispatch-profile, or relaunch) uses its own task lane, so one task's refusals never cool another task's chain head.
Each launch discloses the selected label and skipped entries, and a chain whose every label is cooling refuses rather than substituting an out-of-chain model.

## Backlog backend (.tasks.toml / config/backlog-backend)

The tracked `.tasks.toml` pins the default `tasks-axi` markdown backend to `data/backlog.md`, with `done_keep = 10` and an archive at `data/done-archive.md`.
A home may select another tasks-axi adapter such as Beads through its own `.tasks.toml` or `TASKS_AXI_BACKEND`; firstmate still uses only tasks-axi verbs, and the adapter maps `start` and evidence-bearing `done` to its native statuses.
Under the automatic transition gate ([`bin/fm-backlog-transition-lib.sh`](../bin/fm-backlog-transition-lib.sh)), dispatch and completion move the work item inside the same run that creates or removes the task record, so the ordinary path cannot leave the backlog and live tasks out of sync.
Fresh dispatch accepts only an unheld, unblocked Queued or In flight item in this home, and refuses a missing, Done, held, or dependency-blocked item before any endpoint or local copy exists.
Relaunch uses the separate recovery eligibility in [`agent-control.md`](agent-control.md#transactional-relaunch).
Completion refuses to report success until the item is closed, and session start reconciles this home's books after an interrupted run.
An interrupted spawn re-reads its task record and backlog row under the per-task lock, repairs a row the commit believed it had moved, and reports only what was verified ([`bin/fm-spawn.sh`](../bin/fm-spawn.sh); [`tests/fm-backlog-atomicity.test.sh`](../tests/fm-backlog-atomicity.test.sh)).
Transitions run from the configured data directory's parent; a markdown backlog is also addressed with an explicit `--file <data>/backlog.md` so the change lands in the owning home, while other adapters are addressed by that root alone.
The gate applies to ship/scout endpoint lifecycle, not persistent secondmates or direct specialist/group runs, and is skipped on manual-backend homes or markdown homes without a backlog file.
On an automatic-backend home, missing or incompatible `tasks-axi`, an unresolvable or control-byte data directory, or an unreadable backend configuration fails lifecycle work before mutation; the [backend resolution contract](../bin/fm-tasks-axi-lib.sh) owns the diagnostics and the compatibility probe.
Migrated-hold resolution on a beads home reads only the root `.tasks.toml` `[beads]` section and refuses (rc=2) when beads is selected elsewhere without one.
Secondmate handoffs use `fm-backlog-handoff.sh`, which validates fleet-level rules and delegates the move to `tasks-axi mv`; its [header](../bin/fm-backlog-handoff.sh) owns route-specific outcomes.
It moves in-scope `## Queued` items only, refuses `## In flight` and `## Done` records, and refuses an item whose body continuation is indented with fewer than two spaces or a tab.
Set `config/backlog-backend` to `manual` for manual lifecycle updates and to suppress the verbose `BOOTSTRAP_INFO: tasks-axi available` fact; absent or `tasks-axi` selects tasks-axi.
A `manual` home skips automatic lifecycle transitions, and teardown prints the hand edit that is owed, but its [PR-resolution preflight](../bin/fm-teardown.sh) still applies.
The knob does not disable the sweep's [markdown normalization](../bin/fm-idle-sweep.sh), whose repair and skip rules are owned by the [`fm-backlog-normalize.sh` header](../bin/fm-backlog-normalize.sh).
The knob does not affect the handoff helper, which works fleet-wide because bootstrap requires compatible `tasks-axi` on every profile.

The tracked `.tasks.toml` paths resolve against the directory tasks-axi runs in, not `FM_HOME`, so a bare `tasks-axi` run from the code root addresses the code root's `data/`.
tasks-axi writes by renaming over its target, so symlinking the code-root copy into a home forks the queue on the first write.
Every routine backlog command therefore runs through [`bin/fm-tasks-axi.sh`](../bin/fm-tasks-axi.sh), which addresses this home's backlog and archive from any working directory.
Markdown access through the wrapper, captain-hold commands, and lifecycle transitions follows the shared [addressing and repair contract](../bin/fm-backlog-transition-lib.sh).
PR-bearing completion follows the [completion-claim gate in `bin/fm-pr-lib.sh`](../bin/fm-pr-lib.sh); the wrapper's header owns PR resolution and hand-close refusals.
[`fm_backlog_record_pr_outcome`](../bin/fm-backlog-transition-lib.sh) owns the recorded PR outcome format and title-link handling, and [`bin/fm-landed-lib.sh`](../bin/fm-landed-lib.sh) owns how those outcomes affect Recently Landed.
For existing Done records, [`bin/fm-pr-record-audit.sh`](../bin/fm-pr-record-audit.sh) owns the read-only audit and opt-in migration, including its limits and reconciliation diagnostics.
For a home whose `FM_HOME` is the code root, bootstrap reports a code-root backlog file that is not this home's own as `BACKLOG_RECONCILE: code-root ...`, and a home elsewhere is never pointed at the code root's data files.

## Runtime backend (config/backend / FM_BACKEND)

Every task endpoint lives on the stream backend: one hub serves the fleet, and each task's pseudoterminal is owned by an agent on the machine that runs it.
The hub URL and token come from `config/stream-hub` and `config/stream-token` (or `config/stream-hub-tokens`); [`stream-backend.md`](stream-backend.md) owns setup, prerequisites, the security model, and limits, and [`architecture.md`](architecture.md#runtime-session-backends) owns the runtime-internal axes.
Treehouse remains the worktree provider, since stream is a session provider only.
New local spawns select an explicitly authorized per-task `--backend` first, then `FM_BACKEND`, then the first non-empty line of `config/backend`, then `stream`.
A per-task override requires a current captain instruction or the task's accepted brief and never establishes precedent for later tasks.
Any selection other than `stream` is refused, and the earlier `zellij`, `orca`, and `cmux` adapters remain unsupported.
A task record on the retired `tmux` or `herdr` backend, including a record with no `backend=` field, stays readable for reconciliation and retirement: the recovery classifier reports `unverified`, presence checks report it gone without proving a stop, its kill is unconfirmed, and ordinary relaunch is refused.
[`reincarnate`](agent-control.md#verbs) is the supported owner continuation for proven-stopped retired ship/scout records; the [`fm-control.sh` header](../bin/fm-control.sh) owns its proof, clean-copy, ownership, and refusal contract.
[Endpoint retirement](stream-backend.md#retiring-an-endpoint-record-without-a-confirmed-stop) owns the operator assertion required to retire such a record with [`bin/fm-retire-endpoint.sh`](../bin/fm-retire-endpoint.sh), and the owning mate's `--finished` path for its own finished work.
A stream endpoint the hub still lists live after its task record is gone is closed only by `bin/fm-retire-endpoint.sh --orphan`, which [the same section](stream-backend.md#retiring-an-endpoint-record-without-a-confirmed-stop) points to.
`fm-spawn.sh` spawns local ship, scout, and `--secondmate` tasks on stream, and [remote placement](remote-secondmates.md#normal-operation) owns remote secondmates.
A spawn refusal from a missing dependency, version gate, or unreachable hub ends that invocation; [AGENTS.md section 4](../AGENTS.md#4-harness-and-runtime-dispatch) owns the repair and retry policy before escalation.
Every spawn records `backend=stream`, `endpoint_task_id=` (the cleanup binding between the metadata filename and the opaque endpoint), `stream_hub=`, and `stream_endpoint_id=` in task meta.
The [`fm-remote-control-lib.sh` header](../bin/fm-remote-control-lib.sh) owns a remote secondmate's parent-record endpoint binding.
The session-start and watcher-run secondmate recovery paths use `fm_backend_agent_state`, whose comment in `bin/fm-backend.sh` owns its state contract; [Secondmate lifecycle](stream-backend.md#secondmate-lifecycle) owns automatic recovery behavior and limits.

This paragraph is the single owner of the ordinary task-selector vocabulary for `fm-peek.sh`, `fm-send.sh`, and `fm-crew-state.sh`.
A selector containing `:` is an explicit `<hub-tag>:<endpoint-id>` escape hatch.
Otherwise an exact task id matching `state/<id>.meta` wins before the legacy `fm-<id>` label fallback, so task ids that start with `fm-` route to their own metadata.
A metadata-routed selector returns the recorded target (`window=`) and carries secondmate-marker and recorded-harness context; explicit escape hatches do not.
For explicit targets no metadata names, [`fm-send.sh`'s header](../bin/fm-send.sh) owns live-endpoint verification on this home's hub, and the constrained host-decision answer mode.
[`fm-backend.sh`'s endpoint-validation contract](../bin/fm-backend.sh) owns the metadata identity checks before teardown can dispatch runtime commands or mutate task state, including retired-backend bindings.
[`fm-teardown.sh`'s record-only reassigned-slot gate](../bin/fm-teardown.sh) owns the narrowly guarded missing-worktree exception; [endpoint retirement](stream-backend.md#retiring-an-endpoint-record-without-a-confirmed-stop) explains its operator-facing limits.
`config/backend` is inherited under the primary-authoritative contract owned by [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md).

## Away-mode supervisor backend (FM_SUPERVISOR_BACKEND / FM_SUPERVISOR_TARGET)

The `/afk` sub-supervisor (`bin/fm-supervise-daemon.sh`) delivers escalation digests to the supervising deck-chat host (`bin/fm-deck-chat.sh`) over the stream backend.
[`bin/fm_primary_chat.py`](../bin/fm_primary_chat.py) owns split-mode role resolution.
`FM_SUPERVISOR_BACKEND` may only name `stream`; any other value refuses at daemon startup.
`FM_SUPERVISOR_TARGET=<hub-tag>:<endpoint-id>` overrides the target.
Otherwise [`bin/fm-supervisor-target-lib.sh`](../bin/fm-supervisor-target-lib.sh) uses the stream endpoint this process runs in (`FM_STREAM_ENDPOINT_ID` with `FM_STREAM_HUB`), else the live supervising deck-chat host's endpoint from `FM_CHAT_ROLE=supervisor bin/fm-primary-steer.sh status` (`state/supervisor-chat.json` in a split home, else the one primary), else `-` so delivery uses steering alone.
Both discovery sources are logged at startup, so a wrong-but-resolving fallback is detectable.

A digest goes to the supervising host through `bin/fm-primary-steer.sh publish --kind away` (`FM_PRIMARY_STEER_BIN` overrides the client), keeping the typed operational-input prefix so the receiving session reads it as internal.
The daemon selects `FM_CHAT_ROLE=supervisor` for all steer calls below, including status and delivery checks.
`fm-primary-steer.sh status` is the busy guard: anything but `idle` defers.
Submit proof is `fm-primary-steer.sh delivered <seq>` within the `FM_INJECT_CONFIRM_RETRIES` x `FM_INJECT_CONFIRM_SLEEP` budget.
An unacknowledged digest stays buffered, a changed or unreadable session drops its pending binding and keeps the buffer for republication, and a growing digest may repeat older events rather than lose them; `inject_msg_stream` in the daemon owns those mechanics.
The steer body is capped at 60,000 UTF-8 bytes, keeping the prefix and the complete events that fit and reporting the omitted count; the full buffer is first appended to `state/.subsuper-escalations.overflow`, which survives buffer clearing.
Max-defer and the wedge alarm fire as for typed delivery.
When the steer client reports no live supervising deck-chat host (exit 3; in a split home, no supervisor even if the captain thread runs), the digest is typed into the recorded stream endpoint with the same composer guard and submit proof as `fm-send.sh`.
`bin/fm-afk-launch.sh start` runs the daemon as a detached process in its own session with output in `state/.afk-daemon.out`, and never signals a recorded process whose identity no longer matches; its header owns the launch record.

## Away-mode wedge alarm channels (config/wedge-alarm)

[`wedge-alarm.md`](wedge-alarm.md) owns `config/wedge-alarm` directives, defaults, overrides, delivery bounds, and safety; [`examples/wedge-alarm`](examples/wedge-alarm) is a copyable config.

## Trace context propagation (config/trace-context / FM_TRACE_CONTEXT)

The optional `config/trace-context` presence flag enables default-off native W3C trace-context propagation.
`FM_TRACE_CONTEXT` overrides it: `1`/`on`/`true`/`yes` enables, any other non-empty value disables, and unset or empty defers to the file.
Each locked home session resolves the decision once, and every `fm-spawn.sh` launch from that home uses it until a new session starts.
A launched secondmate, local or remote, receives the presence flag and the primary's frozen decision as a non-empty `FM_TRACE_CONTEXT=on|off`; live convergence into a running home leaves the flag unchanged.
[`trace-context.md`](trace-context.md) owns carrier semantics, supported routes, the manual fleet-restart requirement, and safety limits, `bin/fm-trace-context-lib.sh`'s header owns the mechanics, and [`verification/trace-context.md`](verification/trace-context.md) holds the evidence.

## Turn-end pane-churn absorb (config/turnend-churn-absorb)

The optional `config/turnend-churn-absorb` presence flag opts this home into a default-off third form of positive work evidence in watcher triage.
With it, an eligible bare turn-ended task without authoritative proof may count as working when its pane content changed since the previous poll.
It stays opt-in because the other two proofs read a verdict the harness vouches for, while this one infers execution from rendered bytes.
`FM_TURNEND_CHURN_ABSORB_SECS` (positive integer, default `900`) bounds how long one endpoint's turn-ends may ride that evidence before surfacing anyway, and an invalid value fails closed and surfaces the wake.
The flag is not inherited.
[`architecture.md`](architecture.md) owns the triage contract, and `signal_turnend_panes_churned` in `bin/fm-watch.sh` owns the exact evidence and fail-closed boundaries.

## Wake gate (config/wake-gate-key-var / config/wake-gate-mode)

The optional wake gate uses Jev (`typesafe-ai/jev`) to decide whether a possible-wedge alarm needs an expensive supervision-model turn; it never replaces that model and does not gate worker-update wakes.
Install its pinned runtime from the code root with `npm ci --prefix bin/wake-gate --omit=dev`; `python3` provides the state-file writes.
Put the gateway key in `~/.secrets`, then put that variable's name, a shell identifier, on the first line of `config/wake-gate-key-var`.
Each enabled decision sends the alarm reason, the worker's current-state output, and up to 40 lines of its pane tail to Jev through the Vercel AI Gateway; the key is read at call time and never logged.
With the key-variable file absent the gate is inert, while a missing key, runtime, evidence read, model response, or log write escalates the alarm instead of absorbing it.
Any `config/wake-gate-mode` other than exactly `enforce` selects shadow mode, which changes no wake; use `enforce` only after reviewing shadow results.
Both files are home-local and not inherited, and environment variables cannot opt in or enable enforcement.
`bin/fm-wake-gate.sh`'s header owns the evidence, thresholds, state files, reporting commands, and fail-open mechanics.

## Turn effort (config/effort-policy.json)

A Deck primary or second mate answers routine operational input at a lower reasoning effort, so those turns finish sooner, and keeps the model's default effort for everything else.
The choice is made in code from the turn's source, never by a model: only a watcher wake whose every reason is provably routine thinks less, meaning a status signal with nothing captain-facing the drain has not shown, a heartbeat with no fleet change since the last one, or an auto-land merge or nothing-to-deploy notice.
The captain's own messages, card answers and orders, decisions, blockers, failures, stuck work, other checks, and launch and startup turns always keep the default.
When a lowered turn's tool output turns up new work, the next classified turn runs at the default once.
Unmarked steering arriving during a lowered turn raises it to the default; marked routine input cannot lower an already-running turn.
The file is optional and per home:

```json
{"classifier": "on", "low": "low"}
```

An absent file or omitted fields mean `classifier: on` and `low: low`.
When present, the file must contain one JSON object; any supplied `classifier` or `low` field must be a string with an accepted value.
`"classifier": "off"` is the kill switch: every turn keeps the default.
`low` may be `none`, `minimal`, `low`, or `medium`; check that the model route accepts the level, because `codex/gpt-6.1-sol` refuses `minimal` and proxai sends `none` to codex as no effort at all, which is the default.
An unreadable or invalid file, including a dangling symlink or a field with the wrong type or value, turns the classifier off with a warning on stderr.
It needs a Deck that takes `--effort`; with an older Deck nothing changes.
Running hosts pick up a change to the code only after a restart, and a change to the file at the next wake.
`bin/fm-effort-policy.sh`'s header owns the exact rules, including checks of outstanding durable wakes and open decisions, escalation triggers, and state files.
[`tests/fm-effort-policy.test.sh`](../tests/fm-effort-policy.test.sh), [`tests/fm-deck-chat.test.sh`](../tests/fm-deck-chat.test.sh), and [`tests/fm-deck-harness.test.sh`](../tests/fm-deck-harness.test.sh) exercise classification and host integration without model calls.

## Fleet dreaming (config/dream.json)

`bin/fm-dream.sh` is the fleet's optional nightly pass over its own day; its [header](../bin/fm-dream.sh) owns running, inspecting, scheduling and uninstalling the service.
Alongside its skill and harness-triage passes, the improve pass measures mate tasks against session branches and acts on evidence-linked changes: shared instruction edits go through a gated firstmate PR, code fixes become priority tasks with immediate dispatch orders to owning mates, and captain-only changes or private charter edits become one decision card.
[Auto-land](#auto-land-configautolandjson-configpost-merge) owns merge authority and deployment; dreaming does not grant either.
The morning summary reports what slowed work down, each change's PR/deploy or dispatch/card state, and last night's changes with their targeted measurements then and now.
[`bin/fm_dream.py`](../bin/fm_dream.py)'s header owns the steps, budgets, guards and private files; [`bin/fm_lifecycle.py`](../bin/fm_lifecycle.py)'s header owns timeline sources and measurement limits.
[`tests/fm-dream.test.sh`](../tests/fm-dream.test.sh) and [`tests/fm-lifecycle.test.sh`](../tests/fm-lifecycle.test.sh) exercise them offline.

This section owns `config/dream.json`, a gitignored, per-home JSON object whose fields are all optional.
An absent file means `{}`; an unreadable, malformed or mistyped configuration stops the run rather than silently dropping privacy exclusions.

- `owners`: an object mapping backlog project names to nonempty mate-id strings, or `primary` for the main home; an unmapped project stays in the main home.
  Use `cli-proxy-native` for proxai's backlog project.
- `repos`: an object mapping those project names to GitHub `owner/name` strings, or `null` when no GitHub repository is configured.
  A nonempty object replaces, rather than extends, the built-in mapping; absent or empty uses `DEFAULT_REPOS` in [`bin/fm_dream.py`](../bin/fm_dream.py).
  It selects the harness proposals and open-PR reads, and the GitHub remotes used to recognize fleet no-mistakes runs outside included homes.
  A null entry has no open-PR read or remote match.
- `exclude_homes`: a list of nonempty mate-id strings, empty by default.
  Excluded homes' sessions and workers stay out of the digest, as do messages, commands, errors, log lines and fleet-report rows naming them by id or registered path, checked before truncation; their paths also exclude no-mistakes runs.
  Their backlogs are omitted from triage's open-work reads.
  An unparsable registry entry stops a run with exclusions because the private homes cannot be reliably identified.
- `model`: a string selecting the deck model; absent or empty uses the primary chat's recorded model, then the runner's `DEFAULT_MODEL`.
- `improve`: an object whose optional `model` string pins the improve step's gateway model; absent or empty uses `IMPROVE_MODEL` in [`bin/fm_dream.py`](../bin/fm_dream.py) (`claude/opus-5-5`).
  An unavailable model is named in the morning summary and never replaced by another; the measurement and the steps that need no model still run.

The fleet and primary reports expose the last published run through `dream` and the markdown "Overnight" section; [`bin/fm_report.py`](../bin/fm_report.py)'s header owns that projection and its time window.

## Possible-ask ranking (config/ask-triage-key-var)

An optional pass ranks `working:` status lines that politely ask firstmate for something, such as a hedged "if you would rather keep it, say so", which neither the status vocabulary nor a keyword rule catches.
It uses Jev on the Vercel AI Gateway and only adds prominence: a flagged line gets one row in a `POSSIBLE ASKS` section of the wake drain, while every line the drain showed before is still shown.
It never reads, sends, or flags any non-`working:` line.
The scorer runs detached at status-signal time and the drain only reads its flags, so no drain, acknowledgement, or wake ever waits on the network.
It is inert until Node, the pinned runtime (`npm ci --prefix bin/ask-triage --omit=dev`), and the opt-in exist: `config/ask-triage-key-var` naming the `~/.secrets` variable that holds the gateway key.
`FM_ASK_TRIAGE_KEY_VAR` overrides that file for one run, and the file is not inherited.
A timeout, error, missing key or runtime, or a probability under the threshold leaves the line unflagged.
Only the status line text and a fixed question are sent, and `bin/fm-ask-triage.sh cost` prices recorded usage at $0.042 per million input tokens, output free.
`bin/fm-ask-triage.sh`'s header owns the scope, thresholds, bounds, state files, and failure behavior.

## Gate defaults (.no-mistakes.yaml)

The tracked `.no-mistakes.yaml` sets `test.skip` with a `skip_reason`, sets `test.evidence.store_in_repo: true`, and pins `commands.lint` to `bin/fm-lint.sh`, the same owner CI invokes.
`test.skip` records the gate's Test step as skipped with that reason; [`bin/fm-nm-trusted-test-skip.sh`](../bin/fm-nm-trusted-test-skip.sh)'s header owns acceptance of that skip by `Require no-mistakes`.
Trusted `test.skip` needs no-mistakes `1.76.0-fork-06ee817`; builds without it still run the Test step.
When the Test step runs, evidence goes to the orphan `no-mistakes/evidence` branch and is linked from the PR body, so it never enters a feature or default branch; the worktree's `.no-mistakes/` stays local and CI rejects tracked entries under it.
`test.instructions` bounds a running Test step to the suites under `tests/`.
`commands.test`, `test.skip`, and `test.instructions` are honored only from the default-branch copy of `.no-mistakes.yaml`, so a pushed branch cannot change its own validation rules, and a PR that first enables `test.skip` still runs the Test step.
The [`firstmate-coding-guidelines` skill](../.agents/skills/firstmate-coding-guidelines/SKILL.md#no-mistakes-test-configuration) owns the Test policy, [CONTRIBUTING.md](../CONTRIBUTING.md) the local test entry points, and [fm-test-portable-shards.md](fm-test-portable-shards.md) the shard evidence and coverage rules.

## Captain Preferences (data/captain.md / data/captain-shared.md)

Domain-local preferences for one captain's fleet live in each home's `data/captain.md`, printed in the session-start digest after `data/projects.md` and optional `data/secondmates.md`.
Before changing it, inspect the file and curate the matching bullet in place under the [`stow` skill's](../.agents/skills/stow/SKILL.md) tiering and archive contract; add a bullet only for a genuinely new durable preference.
Shared preferences across secondmate domains are authoritative in the primary home's optional `data/captain-shared.md`.
[`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md) owns its propagation contract, including the required header, read-only copies, quarantine diagnostics, and the rule that existing homes trim `data/captain.md` by hand after first propagation.
Captain memory automatically records standing instructions at delivery and recalls recorded preferences on turns.
[`bin/fm_captain_memory.py`](../bin/fm_captain_memory.py)'s header owns capture routing and cues, recall limits, repeat accounting, and nightly upkeep; [`tests/fm-captain-memory.test.sh`](../tests/fm-captain-memory.test.sh) covers that contract.

## Operational learnings (data/learnings.md)

Fleet-local operational facts and gotchas live in `data/learnings.md`, printed after the captain-preference files in the session-start digest.
It is created lazily and follows the [`stow` skill's](../.agents/skills/stow/SKILL.md) aging-tier and cold-archive contract: inspect and curate it instead of appending forever.
There is no shared learnings file, by captain decision.

## Startup memory budget (config/startup-memory-budget)

`config/startup-memory-budget` is the primary-authoritative per-home allowance for `data/captain.md`, `data/captain-shared.md`, and `data/learnings.md` together.
A locked primary bootstrap writes the default of `7500` estimated tokens when the file is absent.
To change it, replace the primary's file with one positive base-10 integer followed by exactly one newline; the next locked bootstrap or `bin/fm-config-push.sh` propagates it, and a secondmate never creates its own default.
The file must be a regular, single-linked file beneath a non-symlinked `config/`, and malformed, multi-line, symlinked, hardlinked, or special values are rejected rather than defaulted.
`bin/fm-startup-memory-budget.sh read` validates and prints the value, and `report` accounts for the three files.
The estimate is `ceil(UTF-8 bytes / 3)` per file, a conservative portable approximation, and an inherited `data/captain-shared.md` counts in a secondmate's total.
The [`/stow` skill](../.agents/skills/stow/SKILL.md) owns curation and its secondmate cascade, which accounts each home against its own allowance; the helper's header owns parsing and output.

## Stow pass horizon (config/stow-pass-horizon)

The optional `config/stow-pass-horizon` presence flag opts this home into the pass-count decay horizon in the [`/stow` skill](../.agents/skills/stow/SKILL.md).
Without it, `/stow` decays entries on wall-clock horizons alone: 30 days for `aging`, 7 days for `perishable`.
With it, an entry is also stale after 10 (`aging`) or 3 (`perishable`) passes that evaluated it without reinforcing it, whichever comes first.
Opt in for a home that stows so often that entries never reach a wall-clock horizon; a home that stows rarely gains nothing.
The flag is not inherited, only its presence is read, and the skill owns the marker spelling, tick order, and reinforcement rule.

## Secondmate routes (data/secondmates.md)

Persistent secondmate routes live in `data/secondmates.md`, under the single-line route contract owned by the [`secondmate-provisioning` skill](../.agents/skills/secondmate-provisioning/SKILL.md#routing-table).
A remote route adds `host:` and `root:` and places the whole secondmate home on that SSH host; it does not make ordinary workers remotely placeable, and [`remote-secondmates.md`](remote-secondmates.md) owns remote setup, operation, and safety.
`fm-home-seed.sh validate` checks the complete registry contract, and [AGENTS.md section 7](../AGENTS.md#intake-and-authority) owns task intake routing.
`fm-home-seed.sh <id> - {<project>...|--no-projects}` leases a fresh local firstmate worktree for the home; remote provisioning follows [Remote second mates](remote-secondmates.md#provision-a-route).
Seeding refuses when `FM_ROOT`'s `origin` is a local path or `file://` URL instead of the firstmate fork, because the home would push validated changes into that directory and never open a pull request; bootstrap's `HOME_ROUTE:` line reports a home seeded before this check.
`--no-projects` is only for a firstmate-repo domain that needs no project clones; it cannot be combined with a project list, omitting both fails, and it refuses a home that already has project clones, registry entries, or a project-bearing charter.
The lease is held under the secondmate id until retirement or seed rollback, so restarts never free or recycle the home, and teardown fails closed if `treehouse return` cannot release it.
Secondmate routes cover `no-mistakes` and `direct-PR` projects, while `local-only` projects stay main-firstmate work.
For `no-mistakes` projects, seeding initializes only newly cloned projects and refuses to mutate an uninitialized preexisting clone.
Move selected queued items to a new secondmate with `fm-backlog-handoff.sh <secondmate-id> <item-key>...`.
`FM_SECONDMATE_CHARTER` seeds from inline charter text when no filled charter brief exists, and `FM_SECONDMATE_SCOPE` sets a routing scope distinct from it.
The seeded `data/charter.md` owns the secondmate lifecycle and escalation contract.
Each seed writes `.fm-secondmate-home` and `.fm-secondmate-parent` markers at the home root (see [Provision a route](remote-secondmates.md#provision-a-route)); the root `.gitignore` ignores only those two, so a fresh home does not look dirty.
An older linked-worktree home picks up that rule on its next bootstrap or spawn sync, and a standalone-clone home through `/updatefirstmate`'s origin refresh.

## FM_HOME

`FM_HOME` selects the operational home for one firstmate instance; scripts always run from this repo's `bin/`, but `state/`, `data/`, `config/`, and `projects/` come from `$FM_HOME`, and most scripts default to the repo root when it is unset.
`bin/fm-send.sh`, `bin/fm-specialist.sh`, and `bin/fm-group.sh` require `FM_HOME` to be set explicitly, so their operations cannot silently resolve against the wrong home.
Specialist and group records always use that home's `state/` and `data/`; their configuration and neutral-workdir overrides are owned by the [`bin/fm_crew.py` docstring](../bin/fm_crew.py).
`FM_ROOT_OVERRIDE` overrides the repo root, including the checkout the worktree-tangle guard watches, and also acts as the whole-root override when `FM_HOME` is unset.
`FM_STATE_OVERRIDE`, `FM_DATA_OVERRIDE`, `FM_PROJECTS_OVERRIDE`, and `FM_CONFIG_OVERRIDE` override single directories for tests and specialized setups.
Before `fm-brief.sh`, `fm-spawn.sh`, or `fm-afk-launch.sh` persists or passes on a path, it resolves a relative `FM_HOME`, `FM_STATE_OVERRIDE`, or `FM_DATA_OVERRIDE` against the caller's working directory and rejects an unresolvable one by name; `fm-spawn.sh` also rejects control bytes in them.
Lifecycle access to a backlog, task record, or pending-close record must resolve within its configured root, and a final-component symlink is refused even when its target stays inside.

## Harness support

Deck is the only harness: the primary runs as the chat host [`bin/fm-deck-chat.sh`](../bin/fm-deck-chat.sh), and ship workers, scouts, and secondmates run under the worker driver [`bin/fm-deck-worker.sh`](../bin/fm-deck-worker.sh).
The worker driver header owns secondmate session continuity across relaunches, its fresh-session opt-out, and bounded watcher-cycle retry controls.
Specialists and task groups use direct Deck runs rather than stream endpoints; the [`fm-specialist.sh`](../bin/fm-specialist.sh) and [`fm-group.sh`](../bin/fm-group.sh) headers own their launch contracts.
The harness profiles and driver-specific MCP wiring below apply to `fm-spawn.sh` launches, not those direct runs.
`config/crew-harness` holds the crewmate and scout adapter; absent or `default` means deck, and any other name is refused ([`bin/fm-harness.sh`](../bin/fm-harness.sh)).
`config/secondmate-harness` holds `<harness> [<model>] [<effort>]` on its first non-empty, non-comment line; an absent or `default` harness falls back through `config/crew-harness` to deck and reads no model or effort.
Its model token may be a fallback chain ("Model fallback chains" above), and changing it affects the next secondmate spawn or relaunch under the profile rules in [`agent-control.md`](agent-control.md#transactional-relaunch).
An explicit harness, `--model`, or `--effort` on `fm-spawn.sh` overrides the config for that spawn, and for a local route an explicit harness or raw command starts with clean model and effort defaults.
A raw launch command has no verified adapter contract, so [task control's fail-closed boundaries](agent-control.md#fail-closed-boundaries) apply, and remote secondmate routes reject raw commands.
A task record naming a removed harness (for example `pi` or `claude`) is reported unsupported by task control and never relaunched on it.
Firstmate does not expose a spawn or relaunch effort axis for Deck: a dispatch profile with effort or a relaunch with non-default effort is refused before any worker is created or stopped.
Supervisor watcher turns use the separate [turn-effort policy](#turn-effort-configeffort-policyjson).
A Deck spawn needs `deck`, `jq`, and Python 3 on the worker's `PATH`, plus a worker-readable credential for Deck's proxai endpoint.
Deck runs tools without interactive approval prompts; [Approval gates](#approval-gates-agentsapprovalsjson) owns Firstmate's optional machine-local protection.
Workers load gitignored `deck-mcp.json` from the driver's effective config directory, and the chat host loads `<home>/config/deck-mcp.json`; `FM_DECK_MCP_CONFIG` overrides the path as-is and an empty value disables MCP.
Each home owns its MCP file rather than inheriting OAuth-backed servers, and [Deck's MCP docs](https://github.com/bastotec/deck/blob/main/docs/mcp.md) own its format and OAuth login.
When `config/crew-dispatch.json` exists, crewmate and scout spawns need an explicit resolved harness instead of falling back to `config/crew-harness`.
Secondmates inherit the primary's dispatch profiles and `config/crew-harness` as defaults, but not `config/secondmate-harness`, because secondmates do not launch secondmates.
[The Deck supervision protocol](supervision-protocols/deck.md) owns host handling duties, and `bin/fm-supervision-instructions.sh` renders it at session start (any other primary gets the unknown-harness fallback).
[The Deck adapter reference](../.agents/skills/harness-adapters/references/harness/deck.md) routes operating mechanics and evidence under the [`harness-adapters`](../.agents/skills/harness-adapters/SKILL.md) skill, [`bin/fm-control-lib.sh`](../bin/fm-control-lib.sh) holds interrupt and exit mechanics ([`agent-control.md`](agent-control.md) owns their architecture), and `bin/fm-spawn.sh` holds the launch template.
A new harness joins only after a supervised trial task verifies it.

## Worker launch environment (config/launch-env-allowlist)

The optional, inherited `config/launch-env-allowlist` limits the ambient environment passed to newly launched ship workers, scouts, secondmates, specialist jobs, group members, and mergers, including relaunches; existing processes keep their environment.
With no file, `fm-spawn.sh` clears selected harness markers and the provider, terminal daemon, and shell initialization decide what else reaches the worker, so do not assume an endpoint worker inherits the invoking process's environment.
Direct specialist and group runs instead inherit their launcher environment when the allowlist is absent.

List one environment variable **name** per line, never values, assignments, wildcards, or commands; blank and `#` lines are allowed.
Invalid names, an unreadable or nonregular file, or a path inspection error stop the launch, and an empty file enables filtering with only Firstmate's operational floor.
For example:

```text
# Provider credential already available in the destination pane
OPENAI_API_KEY
# Git over SSH using an existing agent
SSH_AUTH_SOCK
```

The shared basic home, `PATH`, terminal, locale, temporary-directory, and task-marker floor is declared by [`fm-launch-env-lib.sh`](../bin/fm-launch-env-lib.sh).
Endpoint launches also keep their own launch assignments, backend routing, and enabled trace; [`fm-spawn.sh --help`](../bin/fm-spawn.sh) owns those names.
Everything else must be listed, including credential-store locations, proxy settings, and certificate overrides your tools need.
For endpoint launches, values come from the destination pane at execution time and are never copied from the invoking process or written into the launch command.
For direct specialist and group runs, values come from the launcher environment; an automatically discovered `PROXAI_API_KEY_FILE` is also subject to filtering and must be listed when needed.
Listing a name does not provision it on another machine.

For an explicit home-local tool selection before a secondmate's startup/bootstrap, [`fm-deck-worker.sh`](../bin/fm-deck-worker.sh)'s header owns `config/secondmate-tool-path` syntax, activation, and scope.
It does not install tools or authorize a relaunch; a command-scoped bootstrap result is not proof that a fresh home launch used the grant.

| Provider or Git transport | Additional names needed |
| --- | --- |
| Provider login stored under the home directory | None for tools that load the store themselves; launcher-supplied credential locations still need the grants described above. |
| Provider configured through environment variables | The exact credential and endpoint names, such as `OPENAI_API_KEY`, for each provider actually used. |
| Custom provider store | Its location variables, such as `XDG_CONFIG_HOME`. |
| Git over SSH with an agent | `SSH_AUTH_SOCK`, plus `GIT_SSH_COMMAND` only if your transport needs it. |
| Git over SSH with a key file | None when normal SSH configuration selects the key. |
| Git over HTTPS with a credential helper | Whatever the helper requires, such as `GH_TOKEN` or `GITHUB_TOKEN` for a GitHub CLI helper. |

Verify provider login and Git transport after opting in; Firstmate does not infer credentials or install a secret manager.
Raw endpoint launch commands run under noninteractive POSIX `sh` with this option.
The filter applies at the worker command boundary (after the terminal daemon and pane shell start for endpoint launches), and is not a sandbox: it cannot revoke same-user access to credential files or stop tools from loading credentials again.
[`tests/fm-spawn-dispatch-profile.test.sh`](../tests/fm-spawn-dispatch-profile.test.sh) covers emitted endpoint launch commands; [`tests/fm-specialist.test.sh`](../tests/fm-specialist.test.sh) and [`tests/fm-group.test.sh`](../tests/fm-group.test.sh) cover direct-run grants and invalid-policy refusal.

## Crew dispatch profiles (config/crew-dispatch.json)

`config/crew-dispatch.json` is an optional, inherited file of natural-language rules that firstmate reads before dispatching a crewmate or scout.
No script matches the rules: firstmate picks the best matching rule with judgment under `AGENTS.md` section 4, resolves its profile object or array, and passes only concrete `--harness`, `--model`, and `--effort` flags to `fm-spawn.sh`.
While the file exists, `fm-spawn.sh` refuses crewmate and scout spawns without an explicit harness (`--harness`, a positional adapter, or a raw command; batch spawns use a shared `--harness`), and malformed configuration must be fixed rather than selected around.
Secondmate spawns are exempt and resolve through `config/secondmate-harness`.
This section owns the schema; `AGENTS.md` section 4 owns the intake boundary, and [`harness-adapters`](../.agents/skills/harness-adapters/references/common/dispatch.md#configured-profile-selection) owns how firstmate picks from an array.

```json
{
  "rules": [
    {
      "when": "<natural-language condition describing a kind of task>",
      "use": [
        { "harness": "deck", "model": "<optional model or fallback chain>" }
      ],
      "why": "<optional rationale that helps firstmate choose>"
    }
  ],
  "default": [
    { "harness": "deck", "model": "<optional model>" }
  ]
}
```

Each rule needs `when` and `use`; `use` and the optional `default` take one profile object or a non-empty array, and every profile needs `harness`.
`model`, `effort`, and `why` are optional, and an omitted model means the harness default.
[Harness support](#harness-support) owns Deck's dispatch-profile effort restriction.
A `model` may be a fallback chain ("Model fallback chains"), passed through `--model` unchanged, so no dispatch-side judgment substitutes a model outside the captain-approved order.
Choosing among an array is a quota-aware intake decision, and if no rule fits firstmate resolves `default` the same way before falling back to `config/crew-harness`.
Bootstrap validates the file with `jq`: valid files stay silent unless `FM_BOOTSTRAP_VERBOSE_FACTS=1`, problems print `CREW_DISPATCH: invalid config/crew-dispatch.json - ...`, and a missing `jq` goes through the normal `MISSING: jq` consent flow instead.
[`docs/examples/crew-dispatch.json`](examples/crew-dispatch.json) is a starting point.

## Toolchain

On session start firstmate lists each missing or too-old required tool with an exact install command or manual instructions; [AGENTS.md section 3](../AGENTS.md#3-session-start-run-once-at-every-session-start) owns installation authority and [`bootstrap-diagnostics`](../.agents/skills/bootstrap-diagnostics/SKILL.md) owns repair and retry.
[`bin/fm-home-tools-lib.sh`](../bin/fm-home-tools-lib.sh) owns the universal toolchain and install commands shared by bootstrap and remote machine setup; [`bin/fm-bootstrap.sh`](../bin/fm-bootstrap.sh) owns compatibility detection, including the no-mistakes version floor.
no-mistakes runs the validation pipeline, gh-axi and chrome-devtools-axi cover GitHub and browser work, and tasks-axi and quota-axi back backlog mutations and quota-aware dispatch.
[`bin/fm-bootstrap.sh`](../bin/fm-bootstrap.sh) owns the axi floor policy and the gh-axi and lavish-axi floors, while [`bin/fm-tasks-axi-lib.sh`](../bin/fm-tasks-axi-lib.sh) and [`bin/fm-quota-axi-lib.sh`](../bin/fm-quota-axi-lib.sh) hold their own floors.
`fm_backend_required_tools` in [`bin/fm-backend.sh`](../bin/fm-backend.sh) owns the stream backend's additional tool set, and any other resolved backend emits `BACKEND_INVALID` and blocks dispatch.
`config/crew-dispatch.json` adds `jq`, and Relay adds `curl` and `jq` before arming its poll.
A missing tool prints a `MISSING:` line with its install command; without compatible `tasks-axi`, a non-manual home with a backlog refuses lifecycle mutation, and without compatible `quota-axi` firstmate cannot resolve a profile array.
Lavish is presentation-only: a missing `lavish-axi` reports `PRESENTATION_UNAVAILABLE` and work continues in text ([`bootstrap-diagnostics`](../.agents/skills/bootstrap-diagnostics/SKILL.md) owns the response).
A `TANGLE:` line means `FM_ROOT` is on a named non-default branch; follow its checkout remediation, which a read-only session omits.

The deferred session-start network stage refreshes project clones through `fm-fleet-sync.sh`, syncs tracked files into live secondmate homes, and propagates inherited local material; [`fm-bootstrap.sh`'s header](../bin/fm-bootstrap.sh) owns the timing, concurrency, and replay contract.
It prints `FLEET_SYNC:` for skipped refreshes that matter, recoveries, and `STUCK:` alarms, and keeps normal local-only and no-origin skips silent.
`fm-fleet-sync.sh` recovers an orphaned `.git/packed-refs.lock` only when it can prove it stale, and `fm-teardown.sh` does the same for `index.lock`; their headers own the retries, and neither ever removes a live lock.
Local secondmate routes sync through guarded filesystem operations, and remote routes through their configured SSH host.
`SECONDMATE_SYNC:` appears only when a home was skipped for an actionable reason, inheritance failed, or a divergent shared captain-preference copy was quarantined.
When a running home's instruction surface (`AGENTS.md`, `bin/`, or `.agents/skills/`) changed, bootstrap sends the re-read nudge itself, and a failed send leaves a retry marker and a `NUDGE_SECONDMATES:` line.
`SECONDMATE_LIVENESS:` appears only when a registered secondmate is skipped or fails to relaunch.
After a mid-session inherited config edit, run `bin/fm-config-push.sh`, which uses the same discovery (`state/*.meta` with `kind=secondmate`) and propagation, and whose help owns reporting.
A changed item sends a running local home the reread pointer described in [`secondmate-provisioning`](../.agents/skills/secondmate-provisioning/SKILL.md), and a remote home one recorded re-read instruction after transfer.
Skipped items, such as a destination that does not yet gitignore the item, are warnings, not failures.

## Watched tool updates (config/watched-tools.json)

The optional `config/watched-tools.json` lists the tools this home depends on, and [`bin/fm-tool-update-check.sh`](../bin/fm-tool-update-check.sh) reports two distinct conditions:

- `<tool> update available` means a newer version exists at the tool's update source.
- `<tool> update not in effect` means a newer copy is installed, but `PATH` still resolves an older one.

The second is why the check exists: an update can install correctly and stay inert behind an earlier `PATH` entry, so the script asks every copy on `PATH` for its own version.
It only reports; it never installs, updates, or changes `PATH`, a version manager, or a tool.
This section owns the schema, and the script's header owns probes, cadence, and the report record.

```json
{
  "tools": [
    {
      "name": "<label used in the report>",
      "command": "<optional bare executable name to find on PATH>",
      "version_args": ["<optional args that make it print its version, default --version>"],
      "announce_pattern": "<optional extended regex matching the tool's own update announcement>",
      "announce_args": ["<optional args for the command that carries that announcement, default version_args>"],
      "git": {
        "repo": "<optional absolute path to a local clone>",
        "remote": "<optional remote name, default origin>",
        "branch": "<optional branch, default the remote's own default branch>"
      }
    }
  ]
}
```

Each entry needs a `name` and at least one of `command` or `git`.
A `command` entry gives the `PATH` comparison, and `announce_pattern` also reports the tool's own update announcement, searched in `announce_args` output (asked only of the resolved copy) or else the version output.
An unusable `announce_pattern` stops `arm`, and during a sweep fails only that tool.
A `git` entry reports how many commits the clone is behind its remote branch, which defaults to the remote's default branch even in a `--single-branch` clone.
Probes are read-only and bounded, and a probe that cannot answer is reported as a failure rather than assumed current.
[`docs/examples/watched-tools.json`](examples/watched-tools.json) is a starting point.

Arm the check once per home with `bin/fm-tool-update-check.sh arm`, which writes and binds `state/tool-updates.check.sh` so the watcher polls it on its normal cadence; the armed check keeps a watcher alive after the last task, until `disarm`.
It prints nothing when everything is current, reports one pending update once, and reports again on a changed or returning condition.
Editing the file needs no re-arming, and it is not inherited.
`FM_TOOL_UPDATE_INTERVAL` (default 900, `0` probes every run, else 60..86400) sets probe frequency, `FM_TOOL_UPDATE_PROBE_SECS` (default 5, 1..30) bounds one probe, and `FM_TOOL_UPDATE_BUDGET_SECS` (default 20, 1..120) bounds a sweep.
The sweep must finish inside `FM_CHECK_TIMEOUT`, so a larger budget is cut to fit and the cut is reported, and a sweep that runs out of budget names the tools it did not reach.

## Mail plane (.env)

The mail plane (`bin/fm-mail.sh`) reads unseen IMAP messages and sends one SMTP message.
Its `poll` surfaces each new message as a durable `check: mail <uid>` wake, journaled so an interrupted poll is healed and inbound mail is never silently missed; a rare duplicate wake is possible, but no case drops mail.
IMAP and SMTP use implicit TLS on 993 and 465; STARTTLS and port 587 are not supported.
It is off unless the home's `.env` provides the connection values, and environment values override `.env` for direct invocations.
This section is the single owner of the mail-plane configuration schema.

Required, in the home's gitignored `.env`:

```sh
FM_MAIL_USER=   # IMAP/SMTP login
FM_MAIL_PASS=   # IMAP/SMTP password
FM_IMAP_HOST=   # IMAP server hostname
FM_SMTP_HOST=   # SMTP server hostname
```

`FM_IMAP_PORT` (993), `FM_SMTP_PORT` (465), `FM_MAIL_TIMEOUT` (20 seconds; invalid or non-positive uses 20), and `FM_MAIL_POLL_MAX_WAKES` (20, valid 1..200) are optional.
The wake cap bounds one poll while header fetches scan a larger bounded window, so a flood still makes progress without ever dropping mail.
A message whose header cannot be fetched surfaces with a degraded summary rather than being skipped, and a later successful fetch surfaces the real sender and subject.

To poll unattended, arm the standing check with `bin/fm-mail-check.sh arm`, which runs `poll` on the watcher's slow-check cadence (`FM_CHECK_INTERVAL`), and `disarm` to remove it.
The check stays silent only for a proven no-op; a fail-closed poll that already queued a wake, and a timeout, always print so the watcher wakes to drain it.
`FM_MAIL_CHECK_BUDGET` (default 15, valid 5..25) bounds one standing poll and is cut to fit `FM_CHECK_TIMEOUT`.

## Auto-land (config/autoland.json, config/post-merge/)

[`bin/fm-autoland.sh`](../bin/fm-autoland.sh) lands green PRs as soon as they are ready and deploys what landed, without a model turn.
`bin/fm-autoland.sh arm` writes and binds `state/autoland.check.sh` as a standing watcher check, and `disarm` removes it.
The watcher runs it every `FM_AUTOLAND_INTERVAL` seconds (default 90) or during a full `FM_CHECK_INTERVAL` sweep, so polling can delay a tick.
Each tick makes one unpaginated GraphQL discovery call (at most 100 open PRs, 100 check contexts per head, and 20 labels per PR), and the header owns the merge budget, query timeout, and candidate rotation.
`bin/fm-autoland.sh status` prints each repository's authority, deployed commits, hook runs, and recent reports.

This section is the single owner of the `config/autoland.json` schema and the post-merge hook contract; the script's header owns the landing and deploy mechanics.
The file is not inherited; arm it in the primary home only.
See [`docs/examples/autoland.json`](examples/autoland.json) for a starting point.

```json
{
  "repos": [
    {
      "repo": "<owner>/<name>",
      "project": "<data/projects.md name whose +yolo grants merge authority>",
      "authority": "<or: the captain ruling that grants it, cited>",
      "attestation": true,
      "max_risk": "low",
      "method": "squash",
      "hook": "<optional post-merge hook name>"
    }
  ]
}
```

Every entry needs `repo` and at least one of `project` or `authority`, repository names must be unique, and each `hook` name may belong to one entry only.
A repository or owner entry in `config/merge-policy.json` (`bin/fm-merge-policy.sh`) decides first: `auto` is standing authority and `ask` or `never` stop auto-merge; under the policy's bare default the rules below apply, and `never` always stops it.
Without `authority`, the repository merges only while its `project` entry carries `+yolo`, read every tick, so dropping `+yolo` stops auto-merge.
A nonempty `authority` cites a real captain ruling granting standing merge authority, as for the Firstmate repository itself, and removing `+yolo` alone does not revoke it.
The PR body's no-mistakes attestation must name the current head with review and document `completed` and test `completed` or `skipped` when `attestation: true` or the project is registered as `no-mistakes` or `no-mistakes-prod-only`.
A skipped Test step is accepted for repositories whose trusted pipeline skips it, but head CI must still be green.
`attestation: false` relaxes that only for `direct-PR`/`local-only` projects or authority-only entries, never for a registered no-mistakes project.
When attestation is required, a missing Risk Assessment holds the PR; otherwise a missing rating counts as unrated, but a present rating must still pass the cap, so use that posture only where every eligible green PR is safe to merge.
`max_risk` caps the no-mistakes risk rating (`low`, `medium`, or `high`; default `low`), and `method` is `squash` (default), `merge`, or `rebase`.

Only open PRs authored by the authenticated `gh` account into a configured repository's default branch are considered.
A PR merges when it is not a draft, GitHub calls it mergeable and not blocked, behind, or conflicting, at least one check is reported and every check on its head is green, no hold label (`do-not-merge`, `hold`, `on-hold`, `wip`, `blocked`, `security`, `destructive`, `breaking`, `breaking-change`, including space variants) is set, its attestation and risk pass, and this machine's approval check permits the merge ([machine instructions](remote-secondmates.md#machine-instructions)).
[`fm_pr_github_checks_not_green` in `bin/fm-pr-lib.sh`](../bin/fm-pr-lib.sh) owns the green-check rule, and pending or red checks are left to the PR's owner, silently.
A PR owned by a task in this home merges through `bin/fm-pr-merge.sh`, so captain holds, away posture, and merge records still apply, and a merge is reported only after it is confirmed live (a queued merge is reported as queued).
Destructive, irreversible, and security-sensitive work keeps escalating: a PR rated above `max_risk` or carrying a hold label wakes the supervisor with `green PR not landing: <url> because <reason>` instead of merging.
That wake fires once per head and reason and again after `FM_AUTOLAND_RENOTIFY` seconds (default 21600); decide that PR at once rather than leaving it to its owner.

### Post-merge hooks

An entry with `hook` runs its post-merge hook for a default-branch head that differs from the commit the hook last deployed, subject to the outcome and retry rules below, regardless of who merged it or whether the entry has merge authority.
A new head is discovered from the next tick's snapshot; reportable outcomes appear on a later tick.
A detached runner first refreshes `projects/<project>` through `bin/fm-fleet-sync.sh` when the entry names an existing project clone (bounded to 300 seconds; a failure is a logged warning), then runs `config/post-merge/<hook>.sh <commit>`.
The hook must be an executable regular file not writable by group or others, and runs in `state/autoland/` with these variables:

```sh
FM_HOME                 # this home
FM_AUTOLAND_CODE_ROOT   # tracked checkout containing the runner's bin/ scripts
FM_AUTOLAND_REPO        # <owner>/<name>
FM_AUTOLAND_TARGET      # the commit to deploy, also $1
FM_AUTOLAND_DEPLOYED    # the commit this hook last deployed, empty when none is recorded
FM_AUTOLAND_APPROVED    # 1 only for `bin/fm-autoland.sh deploy <hook> --approved`
```

Exit 0 means deployed, exit 78 means skipped (nothing was deployed), exit 75 means "not now" (for example, a shared service with work in flight), and anything else is a failure.
Only exit 0 advances `state/autoland/<hook>.deployed` and can emit a deployed notification; a successful clone refresh alone is not a deployment.
A skipped result preserves any previously deployed revision, emits no notification, and is retried only when the head moves or an operator runs `bin/fm-autoland.sh deploy <hook>`.
The foreground `deploy` command prints the outcome and succeeds for deployed, skipped, or deferred results; failures return nonzero, and later ticks don't repeat its report.
The last nonblank output line, capped at 200 characters, is the wake summary, and the whole output is `state/autoland/<hook>.log` with the previous run in `.log.prev`.
A deferral retries every `FM_AUTOLAND_DEFER_RETRY` seconds (default 300); a failure is reported once and retried only when the head moves or an operator runs `bin/fm-autoland.sh deploy <hook>` in the foreground.
`FM_AUTOLAND_HOOK_TIMEOUT` (default 1800) bounds one run.
A hook must be idempotent, install atomically (stage beside the target and rename, keeping the previous copy), leave the old install in place on any failure, and never restart a shared service while work is in flight; a hook with nothing to deploy prints why and exits 78.
The runner cannot prove those obligations, so after a fleet-sync warning the hook must verify its inputs match the requested commit and fail closed otherwise.
Use `deploy <hook> --approved` only for a captain-approved restart window; it signals approval and waives none of the hook's safety obligations.
[`docs/examples/post-merge/firstmate.sh`](examples/post-merge/firstmate.sh) deploys the Firstmate repository through `bin/fm-update.sh`, leaving second-mate restarts to `/updatefirstmate`.

For an existing no-op hook, land and install the exit-78-capable runner before activating the replacement hook; older runners classify 78 as failure.
Verify the installed runner with an isolated exit-78 hook: the result must be `skipped`, preserve the deployed revision, and emit no deployed notification.
Staging isn't activation: an active exit-0 no-op hook still records deployed until replaced.
This migration doesn't authorize starting or restarting services.
The regression coverage is in [`tests/fm-autoland.test.sh`](../tests/fm-autoland.test.sh).

## Relay (.env)

[`relay.md`](relay.md) owns Relay setup, the poll cadence, the mention payload contract, replies, follow-ups, and dry runs.

### Promised public replies (state/public-followup)

[`relay.md`](relay.md#promised-public-replies-statepublic-followup) owns promised public replies.

## Trusted external process-event adapters (config/extensions.d)

[`process-event-sources.md`](process-event-sources.md#trusted-external-process-event-adapters-configextensionsd) owns external adapter binding and registration.

## Process-to-event sources (state/procevent)

[`process-event-sources.md`](process-event-sources.md) owns the process-event runner's operating contract, ownership limits, and variables.

## Inbox and voice records (config/inbox-*, config/voice-read-*)

The model-backed subcommands of `bin/fm-inbox.sh` reach a paid API in a named account, so no region, speech model id, or AWS profile is shipped as a default.
Each is one line in a local `config/` file with an environment override, and a missing required value refuses with the path to write.
That configuration is the whole opt-in: an unconfigured home cannot run `fm-inbox.sh say` or `ask`, while `note`, `status`, `list`, and `drain` need nothing because they make no model call.
Ziggy's firstmate agent reads this home's records through `bin/fm_voice_records.py` and hands work over through `note`, so it works in a home that configured nothing.
In a live session using the polling fallback, a due captain note cuts the idle wait short and normally arrives within seconds.
A note stays unread until `fm-inbox.sh drain --ack <id>` moves it to `state/inbox/handled/`, and `fm-wake-drain.sh --ack-through` never consumes an unread note's `inbox:<id>` row; it keeps the row and says so.
An unread note resurfaces every `FM_INBOX_RESURFACE_SECS` (default 300), at most `FM_INBOX_RESURFACE_MAX` (default 3) more times.
After `FM_INBOX_OVERDUE_SECS` (default 600) unread, `bin/fm-guard.sh` prints `CAPTAIN INBOX NOT READ` on every guarded command and drain, and `fm-inbox.sh note` prints a `delivery: degraded` line that `bin/fm_voice_records.py` passes on as `delivery_warning`.

| File | Environment | Holds |
| --- | --- | --- |
| `config/voice-read-scope` | none | `counts` (default and absent) or `full`, as the bare word only; the `bin/fm_voice_records.py` header says what each scope may contain. |
| `config/voice-read-deny` | none | One case-insensitive substring per non-blank, non-`#` line; a matching open item is withheld and reduced to a count. |
| `config/inbox-region` | `FM_INBOX_REGION` | AWS region for `say` and `ask`. |
| `config/inbox-stt-model` | `FM_INBOX_STT_MODEL` | Speech-to-text model id, required by `say`. |
| `config/inbox-ask-model` | `FM_INBOX_ASK_MODEL` | Side-question model id, required by `ask`. |
| `config/inbox-profile` | `FM_INBOX_PROFILE` | AWS profile for those calls; absent or explicitly empty means ambient credentials. |

The region, model, and profile files are read as their first non-blank, non-`#` line.

## Approval gates (~/.agents/approvals.json)

Some machines should not rely on `AGENTS.md` alone for actions the captain wants to see first, such as Slack, PR comments or email.
After hook installation, every Deck agent in that machine account passes through [`bin/fm-approval.sh`](../bin/fm-approval.sh); unapproved matching calls become pending requests in their owning home rather than executing.
This repository provides the approval commands, records, and machine-policy editing backend; Fleet Town's Machine panel, removal confirmation, card display, audience filtering, and answer routing require the separate firstmate-ui integration.
The policy stays on the machine, outside home inheritance and dotfiles synchronization; the captain manages presets and custom gates through the CLI or the machine-policy transport.
Nothing is gated until the captain enables a gate:

```sh
bin/fm-approval.sh install-hook            # optional; also offered by bin/fm-machine.sh check/setup
bin/fm-approval.sh presets                 # current presets and their scope
bin/fm-approval.sh enable slack-send gh-pr-write
bin/fm-approval.sh status                  # installed hook, enabled gates, policy errors
FM_HOME=<home> bin/fm-approval.sh list      # pending requests
FM_HOME=<home> bin/fm-approval.sh answer <id> --approve  # or --deny
```

[`bin/fm-machine-approvals.sh`](../bin/fm-machine-approvals.sh)'s header owns local/SSH policy editing commands and machine selection for Fleet Town's integration.
[`bin/fm-approval.py`](../bin/fm-approval.py)'s header owns policy defaults and validation, locked saves, stale-editor refusal, change auditing, automatic hook installation, matching limits, request and grant lifetimes, exact-call replay, mate-first worker routing and escalation, answer bookkeeping (including secondmate `--no-steer --json` answers), and exit codes.
The gate is command-text/tool-name matching, not a sandbox; do not treat it as protection against every way to reach a service.
[`tests/fm-approval.test.sh`](../tests/fm-approval.test.sh) covers the approval contract, and [`tests/fm-machine.test.sh`](../tests/fm-machine.test.sh) covers machine setup and policy-repair reporting.

## Bridge gates (config/bridges.json)

A bridge joins this home's machine to another machine, with separate permissions for cross-machine flows.
[`bin/fm-on.sh`](../bin/fm-on.sh) enforces those permissions before SSH, including machine-level skill discovery, shared-skills installation, and instruction or approval-policy reads and saves.
A refused call reports `bridge-blocked:`, records the refusal, and files a "needs you" request that Fleet Town's existing approval card can show.
Unlike a tool-call approval, approving a bridge request grants standing permission for that flow on that bridge and asks the first mate to retry; denying it leaves the flow closed.
Existing bridges are seeded on first use and shown as configured/seeded; newly connected machines allow nothing until the captain selects permissions.
An unreadable or invalid record refuses gated remote operations rather than restoring seeded permissions.
Select bridge permissions before machine setup's skill steps or remote-home provisioning; setup consent alone does not configure a bridge.
Use the bridge command before setup to inspect or change permissions, or select them when registering a machine:

```sh
bin/fm-bridge.sh show                                  # every bridge and what it allows
bin/fm-bridge.sh allow workload files --by "captain"   # or deny; set <machine> --allow a,b|none
bin/fm-machine.sh register newbox /home/me/firstmate --allow supervision,reports
bin/fm-bridge.sh audit                                 # who changed what, and every blocked flow
```

[`bin/fm-bridge.py`](../bin/fm-bridge.py)'s header owns flow definitions, record schema, seeding, request publication and exit codes; `show --json` returns the current flow list and bridge configuration.
[`bin/fm-on.sh`](../bin/fm-on.sh)'s classification table owns each remote command's required permissions, and [`bin/fm-approval.py`](../bin/fm-approval.py)'s header owns answer handling.
The readiness doctor remains available without bridge permission so a machine can be connected.
Fleet Town's own SSH reads of remote homes are the captain's view and are not gated; this exemption does not apply to Firstmate's remote report collection.
The bridge editing panel and connect-form permission checkboxes belong to a separate firstmate-ui change; use the CLI or existing approval cards here.
[`tests/fm-bridge.test.sh`](../tests/fm-bridge.test.sh) covers seeding, new-machine refusal, permission enforcement, requests, approvals, and skill routing.

## Environment variables

Runtime tuning via environment variables (defaults shown).
Variables documented in a section above are not repeated: mail plane, auto-land hooks, watched tools, inbox, wake gate, possible-ask, turn-end churn, and the away-mode target; Relay variables are in [`relay.md`](relay.md) and process-event variables in [`process-event-sources.md`](process-event-sources.md).
Script headers own the exact parsing and fallback of each value.
[`bin/fm-idle-sweep.sh`](../bin/fm-idle-sweep.sh) owns `FM_IDLE_SWEEP_SECS` and the watcher-run cleanup, decision, and second-mate audit contract.
For lane-failure thresholds, overdue hand-offs, and recovery tuning, see the health comments in [`fm-deck-worker.sh`](../bin/fm-deck-worker.sh), [`fm-captain-lane.sh`](../bin/fm-captain-lane.sh), and [`fm-secondmate-revive.sh`](../bin/fm-secondmate-revive.sh).
[`fm-parked-run-watch.sh`'s header](../bin/fm-parked-run-watch.sh) owns parked-run and quiet-worker check-in timing; [`fm-watch.sh`](../bin/fm-watch.sh) owns detached scan cadences.

```sh
# homes and paths ("FM_HOME")
FM_HOME=                 # operational home; unset usually means this repo root; see "FM_HOME" for stricter entrypoints
FM_ROOT_OVERRIDE=        # firstmate repo root and tangle-guard target
FM_STATE_OVERRIDE=       # alternate state dir, mainly for tests
FM_DATA_OVERRIDE=        # alternate data dir, mainly for tests
FM_PROJECTS_OVERRIDE=    # alternate projects dir, mainly for tests
FM_CONFIG_OVERRIDE=      # alternate config dir, mainly for tests
FM_PROC_ROOT_OVERRIDE=   # alternate /proc root for Linux process-identity reads, mainly for tests
FM_BACKEND=              # runtime backend for new spawns; only stream ("Runtime backend")
FM_TRACE_CONTEXT=        # trace-context override ("Trace context propagation")
FM_DECK_MCP_CONFIG=      # Deck MCP config path override; empty disables ("Harness support")
FM_TASK_ID=              # internal worker marker set by fm-spawn.sh; fm-test-run.sh refuses to run in the primary checkout while set
# stream backend (docs/stream-backend.md)
FM_STREAM_HUB=           # hub base URL, before config/stream-hub
FM_STREAM_TOKEN=         # this home's hub client token, before config/stream-token; never committed
FM_STREAM_MACHINE=       # name this home's endpoints are grouped under, before config/stream-machine; default hostname
FM_STREAM_HTTP_TIMEOUT=30   # seconds per adapter request to the hub
FM_STREAM_IMPL=rust      # rust or python (rollback), before config/stream-impl
FM_STREAM_NATIVE_DIR=    # prebuilt native binary directory, before config/stream-native-dir
FM_STREAM_NATIVE_CACHE=  # native build cache override
# session start and bootstrap
FM_SESSION_START_STATUS_TAIL=5     # status lines per task in the session-start digest
FM_SESSION_START_QUEUED_LIMIT=20   # plain queued rows in the digest; in-flight, held, and blocked rows are never bounded
FM_BACKLOG_ROW_TIMEOUT_SECS=10     # bound on each backlog row read; the first hit latches the sweep
FM_BOOTSTRAP_DETECT_ONLY=0         # internal read-only mode: skip mutating sweeps, advisory TANGLE wording
FM_BOOTSTRAP_NETWORK=all           # internal phase split: all, skip, or only (bin/fm-bootstrap.sh)
FM_BOOTSTRAP_VERBOSE_FACTS=        # 1 prints BOOTSTRAP_INFO facts that are silent by default
FM_STARTUP_NETWORK_TIMEOUT=120     # bound on the deferred inactive-outcome scan plus network checks
FM_TASKS_AXI_COMPATIBLE=           # internal one-hop handoff of a computed tasks-axi verdict
FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=   # bootstrap clone refresh bound; default max(20, 5 + 3 * origin-backed projects)
FM_FLEET_PRUNE=1                   # 0 skips pruning local branches whose upstream is gone
# watcher
FM_POLL=15                 # wait budget between watcher poll cycles
FM_WATCH_CODE_SETTLE=2     # seconds bin/*.sh must stay unchanged before a running watcher re-execs
FM_CHECK_INTERVAL=300      # seconds between slow checks (merge polls, custom checks, Relay)
FM_CHECK_TIMEOUT=30        # seconds allowed per slow check script
FM_HEARTBEAT=600           # base seconds between heartbeat scans
FM_HEARTBEAT_MAX=7200      # heartbeat backoff cap
FM_INACTIVE_RECONCILE_SECS=900        # 60..1800; inactivity scan cadence and threshold
FM_INACTIVE_RECONCILE_BUDGET_SECS=10  # 1..30; scan deadline, with a kill backstop one second later
FM_SIGNAL_GRACE=30         # seconds to coalesce nearby status and turn-end signals into one wake
FM_TASK_INBOX_GRACE_SECS=90   # unhandled steering-inbox age before an idle-pane doorbell, and the spacing between attempts
FM_TASK_INBOX_RING_MAX=3      # doorbell attempts before the task surfaces as a stale wake
FM_CAPTAIN_RE='done:|needs-decision:|blocked:|failed:|PR ready|checks green|ready in branch|merged'   # captain-relevant status regex
FM_CLASSIFY_PAUSED_VERB=paused    # status verb for a declared external wait, distinct from blocked
FM_STALE_ESCALATE_SECS=240        # idle seconds before a provably-working stale pane escalates as a possible wedge
FM_BUSY_TURN_MAX_SECS=3600        # busy age without a completed turn or native progress before wedge escalation; never an automatic interrupt
FM_PAUSE_RESURFACE_SECS=14400     # recheck interval for a declared external wait or captain-held transfer; an until time can shorten but not extend it
FM_SECONDMATE_WAKE_STALL_SECS=180 # no-progress interval of a local secondmate's oldest actionable wake row before one stall notification; never while it is provably busy
FM_WEDGE_DEMAND_INSPECT_COUNT=3   # consecutive stale escalations on an unchanged pane before demanding deep inspection
FM_WORKTREE_WRITE_PRUNE='.git node_modules .venv venv __pycache__ .mypy_cache .pytest_cache .ruff_cache .tox target dist build .next .cache vendor'   # dirs the wedge write probe skips; empty prunes nothing
FM_WORKTREE_WRITE_MAXDEPTH=6      # depth of that probe, run only when a wedge escalation would fire; secondmates are skipped
FM_WORKTREE_WRITE_TIMEOUT=10      # seconds one probe may take; hitting it reads as no write evidence
FM_WATCH_TRIAGE_LOG_MAX_BYTES=262144   # size cap for the absorbed-wake debug log
FM_CREW_STATE_BIN=bin/fm-crew-state.sh # test override for the current-state reader
FM_HOME_SUMMARY_INTERVAL=300      # seconds before a live watcher refreshes state/home-summary.json; /bearings trusts a ledger up to twice this old
FM_HOME_SUMMARY_TIMEOUT=60        # bound on one home-summary refresh
FM_HOME_SUMMARY_ERROR_LOG_MAX_BYTES=65536   # cap for state/.home-summary-refresh.log
FM_HOME_SUMMARY_FAILURE_REPORT=2  # publication failures before session start prints HOME_SUMMARY
# guard and arming
FM_GUARD_GRACE=300          # beacon freshness threshold for guard verdicts and arm health checks
FM_GUARD_READ_ONLY=0        # internal: keep alarms, suppress repair commands
FM_GUARD_CONTINUE_LINE='This is a supervision warning only; the guarded operation WILL still run.'   # banner continuation line
FM_LOCK_STALE_AFTER=2       # grace seconds for missing or nonnumeric lock-owner PIDs (minimum 2)
FM_ARM_CONFIRM_TIMEOUT=10   # seconds fm-watch-arm waits to confirm a fresh watcher; 30 on Git Bash/MSYS
FM_ARM_ATTACH_POLL=0.5      # poll interval while attached to an existing healthy watcher
FM_WATCH_CYCLE_LOG_MAX_BYTES=262144   # cap for the watcher lifecycle ledger
FM_WATCH_CYCLE_LOG_KEEP_LINES=1000    # rows kept when that ledger is capped
FM_WATCHER_STALE_GRACE=     # stale-lock threshold; defaults to FM_GUARD_GRACE if set, else max(300, FM_POLL + 60) seconds
# fleet snapshot and Bearings
FM_SNAPSHOT_CREW_STATE_TIMEOUT=10      # bound on each local current-state read in bin/fm-fleet-snapshot.sh
FM_SNAPSHOT_LOCAL_READ_CONCURRENCY=8   # concurrent local task reads
FM_SNAPSHOT_BUDGET=5                   # total seconds for all remote ledger reads
FM_SNAPSHOT_REMOTE_AGENT_STATE=0       # 1 also probes remote agent state; bin/fm-bearings-snapshot.sh sets it
FM_SNAPSHOT_CACHE_DIR=$FM_HOME/state/secondmate-summary-cache   # parent-side remote ledger cache
FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=14   # age at which an undated captain hold projects as a Charted Next gate
FM_RECONCILE_REQUEST_MAX_BYTES=1048576 # largest snapshot accepted for a reconcile-notify request
# no-mistakes queries and teardown
FM_CREW_STATE_NM_TIMEOUT=10    # per no-mistakes query in the shared bin/fm-task-state-lib.sh reader
FM_CREW_STATE_RUNS_LIMIT=200   # recent no-mistakes runs scanned for attribution
FM_CREW_STATE_FOLLOW_SECS=5         # validation-record follower poll during working state or start grace
FM_CREW_STATE_FOLLOW_FULL_SECS=60   # follower's full re-read even when axi status looks unchanged
FM_CREW_STATE_FOLLOW_GRACE_SECS=60  # keep polling a non-working read during the follower's start grace
FM_CREW_STATE_FOLLOW_MAX_SECS=21600 # bound on one follower's life; 0 disables polling, not detached publication
FM_TEARDOWN_NM_TIMEOUT=10      # per no-mistakes query or abort in fm-teardown.sh
FM_TEARDOWN_NM_RUNS_LIMIT=200  # recent runs scanned to prove a parked run belongs to teardown's task
FM_STALE_WORKTREE_LOCK_AGE_SECS=30            # age before teardown treats a leftover index.lock as stale
FM_TREEHOUSE_RETURN_LOCK_RETRIES=3            # treehouse return retries on the index.lock signature
FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=1    # wait before each retry; FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS is a legacy alias
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRIES=3      # fetch retries on the packed-refs.lock signature
FM_FLEET_SYNC_PACKED_REFS_LOCK_RETRY_WAIT_SECS=1   # wait before each of those retries
FM_FLEET_SYNC_PACKED_REFS_LOCK_AGE_SECS=30    # age before fm-fleet-sync treats packed-refs.lock as stale
# delivery and composer guards
FM_BUSY_REGEX=             # rendered busy-signature override for delivery guards; converted worker state ignores it
FM_COMPOSER_IDLE_RE=       # idle-placeholder regex override; a match never bypasses position and de-emphasis gates
FM_COMPOSER_CAPTURE_LINES=20   # tail rows captured for composer reads
FM_COMPOSER_PI_MAX_LINES=8     # maximum rows between a separator pair still read as a composer
FM_COMPOSER_GHOST_LUMA_MAX=128 # max truecolor luminance (0-255) stripped as ghost text; assumes a dark theme
FM_SEND_RETRIES=3          # fm-send typed-plane Enter retries
FM_SEND_SLEEP=0.4          # seconds between fm-send submit checks
FM_SEND_SETTLE=1           # seconds fm-send waits after a submit; 0 disables
FM_PENDING_REPLY_GRACE_SECS=120   # pending-reply grace; bin/fm-pending-reply-lib.sh owns recovery and captain-direct settlement
FM_ASK_TRIAGE_THRESHOLD=0.60      # possible-ask flag threshold ("Possible-ask ranking")
# auto-land and watched-tool extras ("Auto-land", "Watched tool updates")
FM_AUTOLAND_MERGE_BUDGET=12       # seconds of merge work per auto-land tick before no further merge starts
FM_AUTOLAND_QUERY_TIMEOUT=15      # seconds allowed for an auto-land tick's GraphQL call
FM_TOOL_UPDATE_NOW=               # test override for the watched-tool sweep clock
# away-mode sub-supervisor (bin/fm-supervise-daemon.sh); presence-gated via /afk
FM_INJECT_SKIP=heartbeat      # |-separated kinds force-self-handled; empty disables
FM_ESCALATE_BATCH_SECS=90     # escalation digest batch window; 0 flushes immediately
FM_MAX_DEFER_SECS=300         # max buffered escalation age before retry plus wedge alarm; 0 disables
FM_WEDGE_ALARM_CHANNEL=       # one wedge-alarm directive overriding config/wedge-alarm
FM_WEDGE_ALARM_EXEC=          # notifier seam for tests; "discard" fires nothing; unset in production (docs/wedge-alarm.md)
FM_WEDGE_ALARM_TIMEOUT_SECS=10   # per-notifier watchdog
FM_INJECT_FAIL_SLEEP=30       # back-off when the supervisor endpoint is unavailable
FM_INJECT_CONFIRM_RETRIES=3   # delivery retries or steer polls
FM_INJECT_CONFIRM_SLEEP=0.5   # seconds between daemon submit checks
FM_HEARTBEAT_SCAN_SECS=300    # catch-all status scan cadence
FM_HOUSEKEEPING_TICK=15       # seconds between batch-flush, recheck, and scan passes
FM_CRASH_THRESHOLD=10         # watcher crashes inside FM_CRASH_WINDOW before back-off
FM_CRASH_WINDOW=60            # crash-loop window seconds
FM_CRASH_BACKOFF=60           # back-off after the threshold
FM_CRASH_NORMAL_SLEEP=5       # wait after an isolated crash
FM_LOG_MAX_BYTES=1048576      # daemon log size that triggers trimming
FM_LOG_KEEP_LINES=2000        # daemon log lines kept when trimming
```
