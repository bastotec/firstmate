# Process-event sources

A process-event source is a registered long-polling external process whose completed result reaches firstmate as a durable wake, without holding the blocking process in a conversational turn.
`bin/fm-procevent.sh` is the generic runner, and this page owns its operating contract and its unproved-process-group limits.
The [`process-event-sources` skill](../.agents/skills/process-event-sources/SKILL.md) owns the handling procedure, `bin/fm-procevent.sh --help` and each adapter's header own exact commands and flags, and [`verification/process-event-sources.md`](verification/process-event-sources.md) holds the measurements.
Never run a registered blocking source command directly in a conversational turn.

## Trusted external process-event adapters (config/extensions.d)

A home can explicitly enable a trusted external `process-event-adapter/1` package without adding package code to Firstmate.
This is one narrow extension type, not a general plugin or hook system.
[`extension-bindings.md`](extension-bindings.md) owns the manifest, binding, trust, handshake, invocation-envelope, capability, version-compatibility, and authority-boundary contracts, and `bin/fm-extension.sh --help` owns its commands.

Discovery reads only mode-`0600` bindings under this home's mode-`0700` `config/extensions.d/` directory.
The current directory, projects, task copies, worker text, and environment payloads are never searched for extensions.
When the directory is absent, process-event commands perform only a bounded absence check, create no package or extension state, and keep every built-in adapter path unchanged.

Binding separates the package's own manifest from this home's explicit enablement.
`bind` validates the source package, computes every digest, copies the complete tree into the read-only content-addressed `data/extensions/packages/` store, performs the live handshake, and atomically publishes the enabled adapter-name subset.
The operator supplies trust and required consent facts, not hashes.
Binding creates `state/extensions/<extension-id>/` as the package's home-local working namespace, and `state/extension-invocations/` holds private process-group cleanup records only while an invocation is starting or running.
This integrity boundary does not sandbox trusted same-user code, so bind only a package trusted to run with the operator's operating-system access.

The shipped `file-signal` package is a complete neutral example.
Copy it to a persistent directory outside every Git project or task copy, using an absent destination so the source identity stays inspectable, then bind and verify it:

```sh
mkdir -p "$HOME/.local/share/firstmate-packages"
cp -R docs/examples/process-event-extension \
  "$HOME/.local/share/firstmate-packages/file-signal"
bin/fm-extension.sh bind \
  "$HOME/.local/share/firstmate-packages/file-signal" \
  --adapter file-signal \
  --trust-same-user-code \
  --consent artifact-references
bin/fm-extension.sh list
bin/fm-extension.sh inspect org.firstmate.example.file-signal
bin/fm-extension.sh verify org.firstmate.example.file-signal
```

For a non-default home, set `FM_HOME=<that-home>` on every command; local and remote secondmate homes bind packages independently, and bindings are not inherited.
For a configured remote secondmate, keep the package at the controller and transfer it through the authenticated `fm-on` route:

```sh
bin/fm-extension.sh remote-bind <secondmate-id> \
  /absolute/controller/path/to/file-signal \
  --adapter file-signal \
  --trust-same-user-code \
  --consent artifact-references
```

That command serializes only the validated package, stages it below the remote home's fixed extension staging root, binds it there, and prints transfer and binding digests.
Remote registration uses `bin/fm-on.sh <secondmate-id> fm-procevent.sh ...`.
To remove a binding, first retire every registration with its printed owner token and handle every captured result.
Then retire a remote binding and its staged transfer together with `bin/fm-on.sh <secondmate-id> fm-extension.sh retire-transfer <extension-id> --if-transfer-digest <transfer-digest> --if-binding-digest <binding-digest>`, or a local one with `bin/fm-extension.sh retire-binding <extension-id> --if-binding-digest <binding-digest>`.
Both keep the retired identity reversibly and leave unrelated bindings and installed packages unchanged.

Register a source with a path-safe source id and an explicit non-secret configuration reference; credential values never belong in that reference, in command argv, or in a result:

```sh
bin/fm-procevent.sh register-extension file-signal build-complete \
  --config-ref "file:/absolute/path/to/build-result.txt"
bin/fm-procevent.sh reconcile
```

`register-extension` prints the registration's owner token and its exact owner-matched retirement command.
The completed result arrives through the ordinary process-event `check` path.
Classify it with `bin/fm-procevent.sh classify <result-file>`, acknowledge it with `handled` only after it is handled, and use the printed `retire --if-owner` command when explicit retirement is needed.

## Built-in adapters

Built-in adapters keep their tracked `bin/fm-procevent-<adapter>.sh` commands, while a bound external adapter routes through the trusted host contract above.
`bin/fm-procevent-lavish.sh` wraps only the published `lavish-axi poll` interface.
It alone quietly retries the one exact transient response a cut-short listener returns, within a bound its header owns, so an internal retry never reaches the runner as a result; everything else, including that response once the bound is spent, is captured and announced normally.
An already-armed Lavish source keeps its registered command until it is retired and armed again, so re-arm a live board once to adopt a changed retry policy.

The `when` adapter (`bin/fm-procevent-when.sh`) is a condition->action primitive: it registers a deterministic condition and action once, polls the condition without waking firstmate, and on a stable true fires the action at most once before one terminal outcome is captured and published.
The spec lives privately under `state/when/` and is hash-bound like a custom check, and the binding also covers the resolved action executable's bytes; a mutated spec or changed action executable is refused before the action runs, and the binding is reloaded from disk immediately before each fire.
After a repo update changes an in-repo action's bytes, `bin/fm-procevent-when.sh rebind-all` republishes the binding for every registered watch whose action lives under `FM_ROOT`, so armed watches keep firing.
Every failure path ends in a terminal captured outcome that wakes firstmate, never a silent retry, and a durable single-fire marker claimed before the action prevents a second fire across restarts.
The adapter automates only the deterministic subset: anything needing judgment, and anything destructive, irreversible, or security-sensitive, keeps the ordinary check-fires-then-firstmate-decides flow.

## Runner operating contract

Process-event commands resolve the state root to its physical directory before validating it, so a home reached through a symlinked ancestor behaves like its physical spelling while an unsafe target stays refused.
Registration writes one private record under `state/procevent/`, and a completed result plus its immutable adapter identity are captured under `state/procevent-inbox/` before any announcement references it.
By default results are published as ordinary `check` wakes carrying the source id and committed sequence through the durable wake queue, so the runner adds no second notification control plane.
The watcher reports a queued result as an actionable `check` wake on its ordinary cycle, at most once per captured source and sequence while records for that key remain queued.
A handled acknowledgement stops future re-announcement, while a row already queued stays under the wake queue's authority until the ordinary drain acknowledges it.

Discovery is never a timer.
Each registered source has its own child process blocking on that source, and the watcher's per-cycle `reconcile` republishes every captured result that has no durable handled acknowledgement, restarts a source whose owner is gone, and stops this home's runner when its registration disappeared.
A home with no registered source runs nothing, generates no state, and keeps its ordinary cadence.

Adapters own every judgment about a result through optional seams, and the runner names no adapter-specific condition; `bin/fm-procevent.sh`'s header owns the order and exit rules of each seam:

- `silent`: exit 0 records a routine no-op as handled without announcing it; for Lavish that is only an `ended` session with no queued content at all.
- `terminal`: exit 0 retires the registration, so an ended source captures at most one terminal result and is never restarted.
- `autohandle`: exit 0 means a built-in adapter applied and acknowledged its own result; it runs after terminal retirement so a handler that re-arms its source is not dropped.
- `self-announcing`: exit 0 lets a built-in adapter apply first and publish a `check` wake only for what stays unhandled; the remote-secondmate reply adapter uses this so a mirrored status append is the single wake.
- `answers` and `reconciles`: a built-in source bound with `bin/fm-captain-hold.sh bind` feeds the keyed-answer intake or reconcile-request intake, which own what happens next ([`captain-hold-lifecycle.md`](captain-hold-lifecycle.md#reconcile-re-check-reality-never-a-blind-close)).

A missing seam command, an error, or any other exit always falls back to publishing the `check` wake and keeping the source armed, so an unknown or degraded result reaches its handler.
A failed terminal removal stays durably terminal and is completed by ordinary reconciliation without restarting its poll, while a concurrently replaced registration survives as its own generation.
Feeding an intake never acknowledges a result or suppresses its wake, and external binding responses never enter either authority-bearing intake.

The runner proves exactly one durability boundary: output that reached the runner is stored at mode `0600` before any event referencing it is published, and a captured result with no handled acknowledgement stays eligible for bounded re-announcement across any number of drains and restarts.
`bin/fm-procevent.sh handled <source-id> <sequence>` is the only thing that stops re-announcement; it is durable, idempotent, and reports first-time versus repeat, so a paired effect gated on that report is never authorized twice.
`check` publication is best-effort, so the same source and sequence can repeat before any restart, and handlers deduplicate that identity.
The runner proves nothing about the source side, and `handled` proves nothing about a paired external effect performed before it; the published `lavish-axi poll` clears feedback destructively before returning it, so a result lost in that window is unrecoverable.
Never describe this path as at-least-once, no-loss, or lossless; `bin/fm-procevent-lib.sh`'s header owns the exact statement.

## Source ownership and stranded claims

Ownership is machine-wide per canonical source, because separate homes can share one underlying source store.
Claims live under `$XDG_STATE_HOME/firstmate/procevent-claims` (override with `FM_PROCEVENT_CLAIM_ROOT`), each binding the caller's home and runner PID to a process identity, claim generation, registration-file generation, and state-root identity.
Registration, acquisition, replacement, retirement, and release are serialized at one machine-wide boundary per source.
A live identity-matched owner is never displaced, and release removes only the exact generation the caller acquired.
Every stop proves ownership before its first signal: the runner's recorded identity must match and it must still lead its process group, and a live PID whose identity no longer matches is refused.
After a proved TERM, that stop's own escalation to KILL checks only whether the proved group still has members, and that proof cannot authorize any other caller.
A registration refuses to replace an external registration while its prior runner claim is live, uncertain, orphaned, or terminal-pending.
Verification and signalling cannot be atomic in portable shell, so PID and group reuse stay possible in the narrow interval between them; launch pacing is the primary host-wedge protection and watchdog cleanup is a backstop.

A stale claim whose process group still has members is never displaced by `reconcile`, because that group may hold a polling child still attached to the source, and a replacement would add a second destructive poller; `list` reports both such shapes as `orphaned`.
When the recorded PID is alive under a different identity, `bin/fm-procevent.sh start <source-id>` reclaims the claim if the dead generation's reservation records can still be tidied, and otherwise refuses with `cannot claim source`.
That hand-run command is the recovery path, for someone who has checked that nothing still polls the source; the asymmetry with `reconcile` is deliberate and enforced only by `reconcile` itself.
When the leader is gone but its group still has members, `start` reports `already owned` and changes nothing, and `retire`, `reconcile`, `sweep-home`, and the guard all refuse that group, so the source stops listening.
Recovery there is a human checking whether the dead runner's polling child is still attached; once the group is empty the next `reconcile` reclaims the source on its own.
Nothing automatic signals that group, and whether it may ever be signalled is an open decision.
Neither shape is silent: the first `reconcile` that strands a claim generation publishes one durable `check` wake (headline `process-event source stranded`) naming what clears it.
Reclaiming a generation proved gone is never gated on tidying its leftover reservation records, staging file, or recorded registry directory, because those are keyed by claim token and would otherwise leave a dead runner owning its source forever.
Ordinary release and reclamation still attempt that cleanup and require it unless owner staleness and whole-group absence prove the generation gone.
If identity cannot be established before the first signal, or a surviving owned group cannot be proved stopped, the operation keeps the registration and claim for safe retry.

## Home retirement

Supported secondmate retirement preflights the target home's `sweep-home`, snapshots its registrations outside the target, and runs the sweep at the home's final deletion or return boundary.
If deletion or return fails, teardown restores and reconciles those registrations, and if that also fails it returns a distinct status naming the retained backup path.
The sweep retires only registrations and claims whose recorded state-root identity matches that home, and leaves foreign-home claims untouched.
Teardown refuses, keeping the home, lease, routing evidence, registrations, claims, and runners, when identity is uncertain, ownership is unreadable or unreleased, or state exists without a sweep-capable child script.
Raw manual deletion of a Firstmate home is unsupported because it can orphan a blocking child.
To recover, restore that home's tracked `bin/fm-procevent.sh`, run `FM_HOME=<home> <home>/bin/fm-procevent.sh sweep-home`, then rerun the supported teardown.

## Owning-home lease

A runner is bound to the home that owns it, not to the session that armed it, because a persistent source is meant to outlive that session.
A runner whose source is retired in a live home is stopped by `reconcile`; the lease is the backstop for a home that is gone, such as a torn-down test sandbox.
Detaching a runner into its own process group would otherwise let it and its blocking child outlive the whole home, so every runner fails closed unless a small guard starts beside it in a separate process group.
Registration, attached start, reconciliation, acknowledgement, and listing refresh the lease, and the watcher's reconcile cycle keeps it fresh in a live home.
The guard stops the runner's whole group after two consecutive reads, half a check interval apart, cannot prove both the lease's freshness and the state root's recorded device/inode identity.
The nominal detection bound is the lease plus one check interval, followed by a stop grace of at most two seconds for TERM and two for KILL; scheduling delays or failed inspection can extend it.
KNOWN LIMIT: any continuing activity in the home refreshes the lease, so a runner keeps running after its arming session ends until its source is retired or the home goes away.
A runner exports `FM_PROCEVENT_IN_RUNNER` and lease refreshes are skipped under it, so a runner and its ordinary children cannot certify their own owner.
That rule is confused-agent-grade by captain decision: a source that deliberately strips the marker can still refresh the lease, and adversarial-grade unforgeability is out of scope.
Scope is the owning state root and one runner generation, never a script or process name, so a live source in another home is untouched.

## Launch confirmation

Starting a runner is detached, so `reconcile` counts a start only after the source is observed owned or its launch-pacing stamp has advanced, and reports every unconfirmed launch as `failed=` with a non-zero exit.
All of a cycle's launches share one confirmation window, which only bounds a launch that has not yet proved itself.
Because `bin/fm-watch.sh` runs `reconcile` every supervision cycle and discards its output, a source that cannot start makes every cycle wait up to that window, so keep `FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS` well below `FM_POLL`.
An unconfirmed launch is also announced once per failure episode as a durable `check` wake (headline `process-event source failed to start`) naming the source command, the adapter binary, and the attached `bin/fm-procevent.sh start <source-id>` that reproduces the refusal on stderr.
The announcement changes nothing about relaunching, and a later confirmed launch ends the episode without a retraction wake.
An unusable confirmation window is refused by name before anything launches, and `bin/fm-watch.sh` refuses to arm on one, so a mistyped value cannot leave a home disarmed while presenting as supervised.

| Variable | Default | Range and meaning |
| --- | --- | --- |
| `FM_PROCEVENT_MAX_OUTPUT_BYTES` | 1048576 | Bound on one captured result; oversized output is drained and truncated with a stderr notice. |
| `FM_PROCEVENT_CLAIM_ROOT` | `$XDG_STATE_HOME/firstmate/procevent-claims` | Machine-wide claim root. |
| `FM_PROCEVENT_OWNER_LEASE_SECONDS` | 600 | 1..86400; how long a runner keeps going with no activity in its owning home. |
| `FM_PROCEVENT_OWNER_CHECK_SECONDS` | 15 | 1..3600; the guard's detection interval, read twice per interval. |
| `FM_PROCEVENT_LAUNCH_FLOOR_SECONDS` | 1 | 1..3600; minimum time between launches of one registration generation's command, bounding an immediately returning source; the first launch is immediate, a pre-reboot stamp counts as expired, and replacing the registration starts fresh pacing. |
| `FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS` | 3 | 1..600; how long `reconcile` waits for the runners it started; measured on a whole-second clock, so up to one second more. |
| `FM_WHEN_OUTPUT_TAIL_BYTES` | 8192 | Bound on the command-output tail in one `when` outcome document. |
