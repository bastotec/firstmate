# The bin/ toolbelt

The first mate drives these; interactive entrypoints work by hand too, while `*-lib.sh` files are sourced helpers.
Each row is one purpose clause only: the script's own header comment is the authoritative description of its behavior, flags, and contracts, so read the header before first use.
If you have changed away from the firstmate home in an interactive shell, invoke these scripts by absolute path through the repo's `bin/` directory; the scripts self-locate internally after they start.
The shared no-mistakes gate refusal for fleet lifecycle entrypoints is summarized in [architecture.md](architecture.md#no-mistakes-gate-authority-boundary), and `fm-gate-refuse-lib.sh`'s header owns its exact contract.

| Script                   | Purpose                                                                              |
| ------------------------ | ------------------------------------------------------------------------------------ |
| `fm-session-start.sh`    | Compose lock, bootstrap, and wake drain into the single ordered session-start digest |
| `fm-operational-input.sh` | Construct and parse the canonical cross-language operational-input protocol |
| `fm-bootstrap.sh`        | Detect toolchain and fleet problems, run the locked session-start sweeps, and install named tools |
| `fm-startup-network.sh`  | Run session start's network checks and inactive-outcome scan off its blocking path, retaining reports and durable findings |
| `fm-fleet-sync.sh`       | Refresh project clones with safe fast-forwards, self-heals, `STUCK:` reports, branch pruning, and bounded recovery from an orphaned `.git/packed-refs.lock` |
| `fm-fleet-snapshot.sh`   | Print structured fleet snapshot JSON and refresh only its parent-side remote-ledger cache (schema `fm-fleet-snapshot.v1`) |
| `fm-home-summary-refresh.sh` | Atomically publish this home's structured summary ledger                         |
| `fm-fleet-view.sh`       | Render the fleet snapshot as a human Markdown view                                   |
| `fm-bearings-snapshot.sh` | Project the bounded remote-ledger fleet snapshot to compact TOON; `--include-prs` adds live GitHub enrichment |
| `fm-bearings-board.sh`   | Build and arm the stable interactive `/bearings lavish` fleet board                  |
| `fm-secondmate-reconcile.sh` | Queue Bearings reconcile requests for later supervision delivery and ask each mismatched home through its durable inbox with a per-home cooldown |
| `fm-update.sh`           | Guarded self-update of firstmate and local or remote secondmate homes, reconciling redundant divergence and classifying every live mate left on the target commit for restart or fallback nudge |
| `fm-secondmate-restart.sh` | Persist open conversational work, then restart eligible second mates or report the fallback outcome |
| [`fm-secondmate-revive.sh`](../bin/fm-secondmate-revive.sh) | Run guarded mid-session second-mate recovery under the [secondmate lifecycle](stream-backend.md#secondmate-lifecycle) and the script's LANE HEALTH contract |
| [`fm-parked-run-watch.sh`](../bin/fm-parked-run-watch.sh) | Parked-run watchdog and quiet-worker check-ins; header owns timing and escalation |
| [`fm-idle-sweep.sh`](../bin/fm-idle-sweep.sh) | Watcher-run guarded cleanup, retries, first-mate handoffs, and second-mate sweep audits; header owns eligibility and repeat suppression |
| [`fm-backlog-normalize.sh`](../bin/fm-backlog-normalize.sh) | Repair checked rows misplaced in In flight or Queued; header owns repair and skip rules |
| `fm-secondmate-restart-lib.sh` | Shared second-mate restart capability and persistence-request contract |
| [`fm-machine.sh`](../bin/fm-machine.sh) | Connect and prepare a machine, including optional shared-skills provisioning |
| [`fm-machine-blocker.sh`](../bin/fm-machine-blocker.sh) | Turn a machine check's human steps into a `Blocked on you:` reply, a self-closing needs-you card and a pending-machine record |
| [`fm-machine-skills.sh`](../bin/fm-machine-skills.sh) | Record per-machine skill discovery and check skill-dependent placement |
| [`fm-machine-instructions.sh`](../bin/fm-machine-instructions.sh) | Read and version-safely replace a machine's binding instructions |
| [`fm-machine-rules.sh`](../bin/fm-machine-rules.sh) | Check whether a machine's instructions require captain approval for an action |
| [`fm-on.sh`](../bin/fm-on.sh) | Execute a tracked Firstmate command in a remote home or machine lane after bridge permission checks; the doctor uses the SSH bootstrap |
| `fm-remote-job-lib.sh`   | Shared bounded remote job queue, worker readiness, LaunchAgent contract, and filesystem-composed PATH |
| `fm-remote-job-worker.sh` | Long-lived remote queue worker for tracked `fm-*.sh` commands in the account runtime |
| `fm-remote-job-reap-orphans.sh` | Stop remote job workers left running by a pruned code root, never one whose checkout still exists |
| `fm-remote-doctor.sh`    | Check, and with `--fix` repair, one remote account's second-mate readiness (remote job worker, stream backend, PATH, and required tools) |
| [`fm-backlog-handoff.sh`](../bin/fm-backlog-handoff.sh) | Move queued backlog items into a secondmate home; its header owns route-specific wake outcomes and retries |
| `fm-backlog-receive.sh`  | Idempotently ingest one confined remote handoff outbox through tasks-axi             |
| `fm-captain-hold.sh`     | Own captain holds and answer or evidence-backed resolutions, gate investigation completion, and report status/backlog divergence |
| [`fm-card.sh`](../bin/fm-card.sh) | Own captain-facing decision cards and evidence-backed stale-card clear and restore |
| [`fm-notify.sh`](../bin/fm-notify.sh) | Publish a guarded captain notice for Fleet Town's app and external phone-push feed |
| [`fm-specialist.sh`](../bin/fm-specialist.sh) | Create, hand jobs to, inspect, and retire persistent specialists: one resumed Deck session, own memory, own skills |
| [`fm-group.sh`](../bin/fm-group.sh) | Run an ephemeral task group: N members on one brief with per-member angles, a merged report, and one-step cleanup |
| `fm_crew.py`             | Record layout and run mechanics behind `fm-specialist.sh` and `fm-group.sh` |
| [`fm-order.sh`](../bin/fm-order.sh) | Own order proposals: the first mate's reading of a plain-word order, waiting for launch or cancel |
| [`fm-approval.sh`](../bin/fm-approval.sh) | Per-machine tool-call gates and policy presets; answer tool-call or bridge requests under the [approval contract](../bin/fm-approval.py) |
| [`fm-machine-approvals.sh`](../bin/fm-machine-approvals.sh) | Show, save (sha-guarded, audited) and audit a machine's approval gates, locally or over ssh |
| [`fm-bridge.sh`](../bin/fm-bridge.sh) | Inspect and configure cross-machine permissions; [Bridge gates](configuration.md#bridge-gates-configbridgesjson) owns operator setup |
| `fm-decision-hold.sh`    | One-release compatibility shim mapping the retired decision commands onto fm-captain-hold.sh |
| `fm-brief.sh`            | Scaffold ship (explicit `--mode`), scout, and secondmate-charter briefs, with Captain's intent and Firstmate spec subsections on ship/scout |
| [`fm-dod-lib.sh`](../bin/fm-dod-lib.sh) | Own ship/scout worker role scope, ship definitions of done, the ship-only cross-worker "Other work in flight" section shared by briefs and scout promotion, and the no-mistakes `--intent` contract |
| `fm-test-run.sh`         | Behavior-test runner: selection, portable lanes, bounded concurrency, budgets, coverage guard, timing/JSON; refuses to execute in the repository primary checkout when `FM_TASK_ID` marks a task worker |
| `fm-test-isolation-proof.sh` | Concurrent isolation harness and portable candidate set owner |
| `fm-ensure-agents-md.sh` | Ensure a project's real `AGENTS.md`, its `CLAUDE.md` `@AGENTS.md` pointer, and self-governance guidance (explicit project mark documented in the helper's header and help) |
| `fm-guard.sh`            | Warn on primary-checkout tangles, main-session pending wakes, and unhealthy supervision |
| `fm-session-lock-lib.sh` | Shared session-lock harness identity (ancestry walk and holder liveness) for fm-lock.sh and the Deck driver |
| `fm-supervision-instructions.sh` | Render the session-start primary-harness supervision block or the one-line repair instruction |
| `fm-home-seed.sh`        | Transactionally provision a local secondmate home and maintain `data/secondmates.md` |
| `fm-remote-home-seed.sh` | Register and provision a whole secondmate home on an SSH-reachable host              |
| `fm-remote-readiness-lib.sh` | Shared remote second-mate readiness gate: check and, when needed, repair then re-check through `fm-remote-doctor.sh` |
| [`fm-project-origin-lib.sh`](../bin/fm-project-origin-lib.sh) | Accepted origin-form owner shared by both remote provisioning boundaries |
| `fm-spawn.sh`            | Spawn crewmates, scouts, `id=repo` batches, and secondmates on the resolved harness and runtime backend |
| `fm-backend.sh`          | Runtime-backend selection, meta helpers, selector resolution, and operation dispatch |
| `fm-endpoint-rebind-lib.sh` | Point one task record at a new runtime endpoint, keeping the task's worktree and identity |
| `fm-composer-lib.sh`     | Single fleet-wide owner of composer shapes, capability-aware screen classification, and verdicts |
| `fm-agent-process-lib.sh` | Backend-neutral harness-process identity shared by runtime adapters, chain-top pid reduction, and per-process argument matching |
| `backends/stream.sh`     | Stream session-provider adapter (the only backend), driving the fleet's central hub |
| `fm-stream.sh`           | Operate the stream backend: run or resolve the hub, and watch, attach to, steer, or report on its endpoints |
| `fm-stream-native-lib.sh` | Select the stream implementation (rust or the python rollback) and resolve, build, and install the native hub, agent, and bridge binaries |
| `fm-stream-hub.py`       | Python reference hub for the explicit [stream rollback](stream-backend.md#implementation-and-native-binaries) |
| `fm-stream-agent.py`     | Python reference agent for the stream backend rollback path |
| `fm-stream-bridge.py`    | Adapt stream hub listings and composer orders to the Bridge UI's live wire format   |
| [`fm-ui-host-control.py`](../bin/fm-ui-host-control.py) | Route private UI actions and expose browser-safe `targets` discovery ([stream-backend.md](stream-backend.md#private-host-control-routing)) |
| [`fm-deck-chat.sh`](../bin/fm-deck-chat.sh) | Host primary-home Deck chats and their keepers ([role responsibilities](../bin/fm_primary_chat.py)) |
| [`fm-deck-worker.sh`](../bin/fm-deck-worker.sh) | Endpoint-resident crewmate or secondmate driver (`--secondmate`); its header owns split captain-lane hosting |
| [`fm-reply-log-guard.py`](../bin/fm-reply-log-guard.py) | Best-effort Deck pre-tool guard against rewriting secondmate reply logs |
| `fm-deck-stop.py`        | Stop the local Deck drivers of one exact task at a lifecycle boundary |
| `fm_stream_deck.py`      | Apply stream hub orders to a Deck worker's durable task inbox |
| `fm_model_switch.py`     | Checks and live publication for `fm-control.sh <task> model`, the in-place Deck model switch |
| [`fm-primary-steer.sh`](../bin/fm-primary-steer.sh) | Publish to and read the steering inbox of a `deck chat` primary (`fm_primary_chat.py` owns the layout) |
| [`fm_captain_memory.py`](../bin/fm_captain_memory.py) | Record the captain's standing instructions at delivery, recall them on every turn, and keep them tidy nightly |
| [`fm-captain-note.sh`](../bin/fm-captain-note.sh) | A split agent's supervisor (its inner monologue) posts to its conversation, first mate and second mates alike |
| [`fm-captain-handoff.sh`](../bin/fm-captain-handoff.sh) | A conversation hands an order or question to its own supervisor, naming the sender |
| [`fm-captain-lane.sh`](../bin/fm-captain-lane.sh) | A split second mate's conversation (the captain's, the first mate's and other mates' words), run beside its supervisor by the home host |
| [`fm-effort-policy.sh`](../bin/fm-effort-policy.sh) | Decide from a turn's source whether a Deck supervisor turn may run at a lower reasoning effort ([configuration](configuration.md#turn-effort-configeffort-policyjson)) |
| `fm-config-push.sh`      | Push declared inherited local material to live local or remote secondmates and send the placement-specific config reread when changed |
| `fm-project-mode.sh`     | Resolve a project's registered delivery posture from `data/projects.md` for fleet sync and home seeding |
| `fm-merge-local.sh`      | Fast-forward a `local-only` project's local default branch after approval            |
| `fm-review-diff.sh`      | Review a crewmate branch or resolved PR head against the authoritative base          |
| `fm-marker-lib.sh`       | Compatibility entry point for the from-firstmate carrier owned by `fm-operational-input.sh` |
| `fm-task-inbox-lib.sh`   | Single owner of durable steering-inbox records, acknowledgement, doorbells, and the delivery-attempt ladder |
| `fm-process-tree-lib.sh` | Cancels a Deck turn's tool trees the way the second-mate host stops a turn, shared with the captain lane |
| `fm-captain-direct-lib.sh` | Parent-side captain-direct delivery ledger, FYI wording, and echo matching |
| `fm-pending-reply-lib.sh` | Parent-owned secondmate pending-reply expectations, recovery, and keyed escalation lifecycle |
| `fm-secondmate-report.sh` | Optional helper that resolves the parent channel itself and appends a correlated status or document-pointer report |
| [`fm-mate-send.sh`](../bin/fm-mate-send.sh) | Queue a second mate's message to a peer or the first mate from its own home |
| [`fm-mate-route.sh`](../bin/fm-mate-route.sh) | Deliver queued mate messages on primary watcher polls |
| [`fm-mate-mail-lib.sh`](../bin/fm-mate-mail-lib.sh) | Own the peer-message wire, spool, and oversight-log contract |
| [`fm-report.sh`](../bin/fm-report.sh) | Read or request the fleet's or one mate's report from any home; its header owns usage and routing |
| [`fm_report.py`](../bin/fm_report.py) | Own the report's data sources, `fm-report.v1` JSON shape, crew-time intervals, and text rendering |
| [`fm-dream.sh`](../bin/fm-dream.sh) | Run, show, or schedule the fleet's nightly dreaming pass; its header owns usage and service setup |
| [`fm_dream.py`](../bin/fm_dream.py) | Own dreaming's steps, guards, budgets, run log and the `fm-dream.v1` summary the report shows |
| [`fm-mates.sh`](../bin/fm-mates.sh) | List the fleet's second mates (id, machine, domain) from any home |
| `fm-extension.mjs`       | Bind, inspect, verify, and strictly invoke trusted external process-event adapter packages |
| `fm-extension-launch-barrier.mjs` | Publish one exact static core-owned invocation group before package code runs |
| `fm-extension.sh`        | Expose extension binding commands through the tracked shell and remote-home command boundary |
| `fm-procevent.sh`        | Register, supervise, capture, classify, acknowledge, and safely retire built-in or explicitly bound process-event sources |
| `fm-procevent-remote-reply.sh` | Relay the remote-secondmate status stream through non-destructive process-event deltas |
| `fm-procevent-quota.sh`  | Wake Firstmate when tracked quota drops below a threshold, is exhausted, or cannot be polled |
| `fm-procevent-when.sh`   | Fire a trust-bound deterministic action at most once when its registered condition holds, then wake with the outcome |
| `fm-gate-refuse-lib.sh`  | Shared no-mistakes gate-context refusal for fleet lifecycle entrypoints               |
| `fm-watch-arm.sh`        | Verified home-scoped watcher arm wrapper with loud cycle endings and bounded lifecycle ledger |
| `fm-watch-wake-lib.sh`   | The watcher's one actionable-wake exit, its delivery log, and heartbeat-backstop markers |
| `fm-watch.sh`            | Singleton-safe watcher: absorb benign wakes, detect stalled local-secondmate wake queues, and exit on actionable ones |
| `fm-external-wait.sh`   | Own the supervisor-declared bounded external-wait record: declare, clear, and read a wait (reason, declarer, expected clear time) that parks a stale pane on the pause cadence |
| `fm-inactive-reconcile.sh` | Reconcile long-inactive direct crewmate terminal outcomes without forge access |
| `fm-afk-contract.sh`     | Own the away-posture record: schema, mandate-clause fields and never-set scan, refusal naming the missing part, read-back, entry announcement, archive, and cross-subsystem authority lock |
| `fm-afk-start.sh`        | Run the common sourceable away-mode daemon entry in the foreground                      |
| `fm-afk-launch.sh`       | Own away-mode entry (read-back, confirm, record), exit, rollback, and any backend terminal lifecycle |
| `fm-afk-return.sh`       | Own deterministic return shutdown, the return brief, catch-up evidence, and the firstmate-actionable blocker gate |
| `fm-supervisor-target-lib.sh` | Resolve the shared supervisor target and backend for the daemon and launcher       |
| `fm-supervise-daemon.sh` | Presence-gated away-mode sub-supervisor: self-handle routine wakes, guard injection by the detected primary harness, escalate batched digests, alert on failed delivery |
| `fm-crew-state.sh`       | Read current crew state or publish/watch its validation record ([owned derivation](../bin/fm-task-state-lib.sh)) |
| `fm-task-state-lib.sh`   | Current-task-state derivation, attributed evidence, and declared-wait projection for state readers and monitoring |
| `fm-nm-run-lib.sh`       | Single owner of shared no-mistakes run-attribution primitives and rules             |
| `fm-tangle-lib.sh`       | Shared default-branch resolution and primary-checkout tangle classification          |
| `fm-home-route-lib.sh`   | Single owner of what counts as a firstmate home's pull-request delivery route, shared by seeding, remote provisioning, and the session-start report |
| `fm-timeout-lib.sh`      | Single owner of hard-bounded command execution and its fallback watchdog |
| `fm-timing-lib.sh`       | Single owner of the deferred network stage's per-step elapsed-time records, inert unless a run asks for them |
| `fm-supervision-lib.sh`  | Shared in-flight-work-without-fresh-watcher-beacon predicate                         |
| `fm-ff-lib.sh`           | Shared guarded fast-forward/reconcile helper for origin pulls and secondmate syncs, with durable divergence markers |
| `fm-lock-lib.sh`         | Shared "is this git lock provably abandoned?" proof used by teardown and fleet-sync   |
| `fm-config-inherit-lib.sh` | Shared primary-to-secondmate inherited local-material propagation and config-reread delivery |
| `fm-tasks-axi.sh`        | Run `tasks-axi` against this home's backlog from any working directory               |
| `fm-tasks-axi-lib.sh`    | Shared backlog-backend selector and `tasks-axi` compatibility probe                  |
| `fm-tool-version-lib.sh` | Shared tool-associated semantic-version parser and floor comparison                  |
| `fm-backlog-transition-lib.sh` | Pair task-record changes with their backlog transitions and replay interrupted closes |
| `fm-quota-axi-lib.sh`    | Shared `quota-axi` compatibility floor and quota snapshot schema validation           |
| `fm-wake-drain.sh`       | Present and acknowledge this home's claimed wake rows alongside status, outcome-backstop, decision, divergence, recovery, and supervision checks |
| `fm-wake-lib.sh`         | Shared durable wake queue, recovery generations, portable locks, and watcher identity/health helpers |
| `fm-classify-lib.sh`     | Shared wake classification, durable keyed-decision folds and scans, unread status selection, and bounded latest-event snapshots |
| `fm-send.sh`             | Send task text, keys, or typed harness invocations, or publish captain/supervisor chat input (routing contract: [script header](../bin/fm-send.sh)) |
| `fm-control.sh`          | Agent lifecycle control plane: allowlisted verbs for an exact task id ([local transactions](agent-control.md#verbs), [remote routing](remote-secondmates.md#lifecycle-control)) |
| `fm-control-lib.sh`      | One executable owner of the control-plane verb allowlist, per-harness interrupt/exit mechanics, and per-backend capability |
| `fm-busy-lib.sh`         | Single owner of the semantic busy-state contract: verdicts, source attribution, and per-harness sources |
| `fm-busy-event.sh`       | The only writer of a task's semantic busy-state record and native-harness progress marker; arms an incarnation and applies lifecycle events |
| `fm-peek.sh`             | Print a bounded tail of a crewmate endpoint                                          |
| `fm-check-register.sh`   | Bind an intentional custom watcher check to its current bytes                       |
| `fm-check-unregister.sh` | Retire a custom watcher check and its trust binding by validated task id            |
| `fm-check-lib.sh`        | Validate custom-check registrations and prepare private execution snapshots          |
| `fm-tool-update-check.sh` | Report watched tooling with an update available, and updates installed but left inert by PATH order |
| `fm-pr-lib.sh`           | Own canonical task and PR validation, the live-state completion-claim gate, and private atomic PR-poll publication, merge-notification identity, and retirement |
| `fm-pr-poll.sh`          | Provide the byte-static watcher program for validated PR/MR-poll sidecars           |
| `fm-pr-check.sh`         | Record validated `pr=` and `pr_head=` values, then atomically arm a static merge poll |
| `fm-pr-unbind.sh`        | Clear a wrong `pr=` and `pr_head=` plus their armed poll for a github.com worktree only after GitHub shows no open pull request for the task's own branch, with a pre-removal assertion in `state/pr-unbinds.log` |
| `fm-pr-record-audit.sh`  | Audit of this home's Done rows against recorded PR live state, read-only unless `--migrate` records real outcomes on older rows ([output and exit status](../bin/fm-pr-record-audit.sh)) |
| `fm-pr-merge.sh`         | Record PR metadata, merge a task's canonical full GitHub or GitLab URL, then refuse an outcome it cannot prove landed or queued |
| `fm-merge-outcome-lib.sh` | Publish a confirmed merge's durable, role-routed supervision outcome                 |
| `fm-merge-authority-lib.sh` | Resolve merge authority at the gate, persist it against the accepted canonical PR, and identity-check its later poll consumption |
| `fm-parent-channel-lib.sh` | Resolve a secondmate home's parent channel and append a captain-facing outcome line to it at most once |
| `fm-promote.sh`          | Promote a scout task in place to a protected ship task with an explicit delivery mode, write the ship instructions carrying that mode's definition of done, and supersede the task's brief so a later relaunch cannot revive stale scout delivery text |
| [`fm-teardown.sh`](../bin/fm-teardown.sh) | Guarded task cleanup and committed-work preservation; its header owns the safety checks |
| `fm-retire-endpoint.sh`  | Retire named task records without a backend-confirmed stop, or close record-less stream endpoints |
| `fm-retire-orphan-lib.sh` | Single owner of the `--orphan` checks that close a record-less stream endpoint: ownership bound to the endpoint id, idle or stopped harness, and no unlanded work |
| `fm-harness.sh`          | Detect Deck ancestry and resolve the supported crew or secondmate harness, model, and effort tokens |
| `fm-lock.sh`             | Per-home firstmate session lock                                                      |
| `fm-x-lib.sh`            | Shared Relay config, relay, and reply-threading helpers                              |
| `fm-x-poll.sh`           | One bounded Relay poll: stash newly offered mentions and emit their once-only wake   |
| `fm-x-reply.sh`          | Post or dry-run preview a composed Relay reply or follow-up                          |
| `fm-x-dismiss.sh`        | Dismiss a skipped Relay mention at the relay without replying                        |
| `fm-x-link.sh`           | Link a spawned task to its originating Relay mention in task meta                    |
| `fm-x-followup.sh`       | Detect, post, and cap completion follow-ups for a Relay-linked task                  |
| `fm-public-followup-lib.sh` | Shared Relay gate, open-loop registry state, expiry classification, locking, and private transport paths |
| `fm-public-followup.sh`  | Reconcile and deliver typed public commitments, then rechain or explicitly retire their retained loops |
| `fm-public-followup-emit.sh` | Report one typed terminal work result into the home that owes the public reply, or stage it when that home is on another machine |
| `fm-public-followup-collect.sh` | Read and retire the typed terminal results a remote work home staged for the home that owes the public reply |
| `fm-inbox.sh`            | The captain's out-of-band capture surface: queue a note, dictate one, read status, ask a side question |
| `fm-mail.sh`             | General-purpose mail plane: read unseen IMAP mail, send one SMTP message, or surface new mail as a `check` wake via `poll` (configuration in the home's gitignored `.env`) |
| `fm-mail.py`             | The IMAP/SMTP engine behind `fm-mail.sh` |
| `fm-mail-check.sh`       | Standing received-mail poll: `arm` registers a watcher check that runs `fm-mail.sh poll` on the watcher cadence (new mail still wakes via the poll; the check's own line also wakes unless the poll is a proven no-op), `disarm` removes it |
| `fm-autoland.sh`         | Auto-land watcher check and detached post-merge hook runner ([configuration and hook contract](configuration.md#auto-land-configautolandjson-configpost-merge); commands in the script header and `--help`) |
| [`fm_voice_records.py`](../bin/fm_voice_records.py) | Scope-controlled records view and work handover for Ziggy's firstmate agent |
