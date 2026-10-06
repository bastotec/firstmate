# Remote second mates

Remote second mates place a whole persistent Firstmate home on another SSH-reachable host.
The primary still owns routing and supervision, while the remote home owns its own projects, backlog, and workers.
Firstmate does not support placing an individual worker remotely or failing a remote route over to a local replacement.

The remote second-mate agent itself runs on the [stream backend](stream-backend.md) against the hub that home's `config/stream-hub` names, and the primary gates provisioning, launch, and relaunch on the remote doctor's readiness verdict.
A stream agent is started in its own session on the host and publishes to the hub, so it survives the SSH connection too, provided the host's login manager does not kill a user's processes at logout (the doctor's Linux check refuses a reported `KillUserProcesses=yes`, but skips when `busctl` is unavailable or logind does not answer).
The workers a remote second mate supervises inside its own home run on that home's own stream configuration.

## Prerequisites

Configure an SSH alias in the primary account's normal OpenSSH configuration.
Use ordinary public-key authentication, strict host-key verification, and a dedicated remote account where practical.
Do not enable agent forwarding for Firstmate.
`fm-on.sh` also disables agent forwarding, forwarding setup, and configured `SendEnv` patterns on every call, and arms bounded SSH dead-peer detection so a vanished host (a reboot, a dropped link) fails within a bounded window instead of hanging indefinitely; its [script header](../bin/fm-on.sh) owns the keepalive defaults and environment overrides.

Clone Firstmate on the remote host at an absolute code-root path, from the firstmate fork's network URL; provisioning refuses a copy whose `origin` is a local path or `file://` URL (see [Provision a route](#provision-a-route)).
Expose that clone's fixed entrypoint on the account's non-interactive SSH `PATH`, for example:

```sh
mkdir -p ~/.local/bin
ln -s /absolute/path/to/firstmate/bin/fm-remote-entrypoint.sh ~/.local/bin/fm-remote-entrypoint.sh
```

The entrypoint accepts encoded argv for genuine executable `bin/fm-*.sh` files only.
It never accepts a shell command string.
The readiness-owning doctor runs over this plain SSH bootstrap so read-only mode can report worker gaps and `--fix` can install or repair the worker.
The entrypoint authorizes that bootstrap with normal git tracking when git resolves and with its pinned doctor digest when doctor must report that git itself is missing.
After setup, every other command verifies Firstmate's account-owned remote job worker, stages the encoded argv and stdin bytes, waits for its result, and relays stdout, stderr, and the exit status separately.
On macOS the worker is `dev.firstmate.remote-job`, an Aqua-scoped LaunchAgent at `~/Library/LaunchAgents/dev.firstmate.remote-job.plist` with logs under `~/Library/Logs/`.
After that bootstrap every non-doctor `fm-on.sh` target runs through that worker in the remote account's GUI session, never in the SSH process.
The worker serves one lane per staged home, so one home's long job never delays another home's commands, and a reply long-poll is preempted as soon as another command is queued for its home.
A caller that disconnects or times out cancels its job instead of abandoning it, so retries never convoy behind abandoned work.
[`bin/fm-remote-job-lib.sh`](../bin/fm-remote-job-lib.sh) owns the lane ordering, preemption, and cancellation contracts.
Linux uses the same queue and worker protocol without the Aqua-session requirement.
A worker stops itself once its configured code root stops being a Firstmate checkout, so a worker started from a worktree cannot outlive that worktree, and `bin/fm-remote-job-reap-orphans.sh` clears any worker already left behind that way without ever touching one whose checkout still exists.
The remote account must provide the required toolchain listed under [Readiness, repair, and the human steps](#readiness-repair-and-the-human-steps), the stream prerequisites, and credentials that work on that host.
The origin URL named for each project must be reachable from the remote account because projects are cloned on that host rather than copied from the primary.

## Non-interactive tool contract

Remote job execution never runs a login or interactive shell, so `~/.profile`, `~/.bashrc`, and `~/.zshrc` never contribute to the job worker's runtime `PATH`.
`bin/fm-remote-job-lib.sh` is the single owner of the worker `PATH` and builds it by filesystem discovery rather than by evaluating shell startup files.
The authorized child sees `<remote-root>/bin` first, then a genuine account `~/.local/bin`, the nvm default version bin, asdf and mise shims and install bins, Nix directories, Homebrew directories, and the system tail `/usr/bin:/bin:/usr/sbin:/sbin`; that header owns the exact order and version selection.
A symlinked `~/.local/bin` is excluded.
The entrypoint resolves `git` only from the operator portion before prepending `<remote-root>/bin` for the authorized child.
A checkout-local `bin/git` therefore cannot authorize an untracked command, and a host with no operator `git` receives an install-or-wrapper diagnostic before command execution.

The filesystem discovery normally finds tools installed by nvm, asdf, or mise without starting their shell hooks.
When a required tool remains discoverable only through one of those managers, `fm-remote-doctor.sh --fix` may create a Firstmate-owned wrapper in `~/.local/bin` that executes its selected absolute target.
It never overwrites a wrapper or other file it does not own, and it never installs a package.
An operator can use the same wrapper shape when a tool needs a manual selection:

```sh
mkdir -p ~/.local/bin
cat > ~/.local/bin/tasks-axi <<'SH'
#!/usr/bin/env bash
tool_bin="$HOME/.nvm/versions/node/<selected-version>/bin"
PATH="$tool_bin:$PATH"
exec "$tool_bin/tasks-axi" "$@"
SH
chmod +x ~/.local/bin/tasks-axi
```

Replace the placeholder with the remote account's selected nvm version.
For asdf or mise, use the same shape with the selected version's absolute `bin` directory, one wrapper per tool the remote home actually needs.
The wrapper must execute that absolute target rather than resolving its own name again through `~/.local/bin`.

## Readiness, repair, and the human steps

`bin/fm-remote-doctor.sh` is the single owner of what "ready for a remote second mate" means.
Check any host against it directly:

```sh
bin/fm-on.sh <secondmate-id|ssh-alias> fm-remote-doctor.sh
```

That run is read-only; route seeding and existing-home migration run the same check.
It covers stream tools, the stream credential, the hub protocol, Linux logout survival, the GUI login session on macOS, and the remote job worker (including its Aqua scope on macOS).
`--backend stream` is still accepted, and stream is the only backend.
Stream gaps require operator action: `--fix` does not start a hub or mint a credential.
It prints the exact `PATH` its own entrypoint launch produced, executes its required-tool probe through the installed worker when one is available, reports where each required and optional tool resolved, then reports one line per readiness check.
Each gap is tagged `fixable:` when `--fix` can close it or `human:` when only a person at that machine can, and every gap is followed by an `action:` line naming the exact step.
Any remaining gap exits non-zero.
The script's own header owns the full line protocol.

`--fix` repairs only the automatable gaps and is safe to rerun:

```sh
bin/fm-on.sh <secondmate-id|ssh-alias> fm-remote-doctor.sh --fix
```

Over the plain SSH doctor bootstrap it writes and reloads the Firstmate-owned `dev.firstmate.remote-job` launch agent on macOS, scoped with `LimitLoadToSessionType=Aqua` and bootstrapped in `gui/<uid>`.
It starts the same workers directly on Linux, recreates the `~/.local/bin/fm-remote-entrypoint.sh` symlink when it is absent, and creates only Firstmate-owned required-tool wrappers that it can prove resolve to a version-manager target.
It never installs packages or overwrites a non-Firstmate file at a reserved wrapper path.
It re-derives every check from the host afterwards, so what it prints is the state after the repair rather than the intent of one.

These steps are never automated and are always reported rather than silently attempted, because SSH cannot create a GUI session from nothing:

- The first console login on that Mac, and automatic login in System Settings > Users & Groups when the machine runs headless and must come back on its own after a reboot.
- FileVault, which holds a reboot at pre-boot authentication before any login session exists.
- Installing any missing required tool that no safe wrapper can resolve.
- The required remote tool set is `git`, `jq`, compatible `tasks-axi`, `treehouse`, and `deck`; Deck additionally requires `python3`.
- Deck's model endpoint credential on that host (its proxai client key, see [Deck's adapter reference](../.agents/skills/harness-adapters/references/harness/deck.md)), and any keychain password prompt reading it needs.

Firstmate never writes an auto-login password, never changes FileVault, and never stores an account password.
A file at `~/.local/bin/fm-remote-entrypoint.sh` that is not Firstmate's own symlink is reported for the operator to inspect and is never overwritten.

## Provision a route

Create and fill the normal secondmate charter first, then run:

```sh
bin/fm-remote-home-seed.sh <id> <ssh-alias> <remote-root> <remote-home> {<project>[=<origin-url>]...|--no-projects}
```

`<remote-root>` is the remote Firstmate code clone that supplies tracked scripts.
`<remote-home>` is a separate absolute path for the persistent secondmate home and must not overlap the code root.

Name each project's origin as `<project>=<origin-url>`.
Resolve the concrete origin from the captain, the project registry, an existing clone anywhere, the forge, or an explicit paste rather than imposing one URL template.
Seeding a project this machine has never cloned needs no clone under `projects/`, no `no-mistakes` initialization here, and no fleet sync first.
A bare `<project>` is still accepted when this machine happens to have `projects/<project>`, whose configured origin is then read instead of being retyped.
[`bin/fm-project-origin-lib.sh`](../bin/fm-project-origin-lib.sh) owns which URLs are accepted; it decides on structure and safety alone, so no forge, domain, or host is privileged and a self-hosted server works exactly as a hosted one does.
The primary validates every resolved origin before transport, and the receiving host validates it again before cloning.
The project's registered delivery mode still comes from this machine's `data/projects.md`, so an unregistered or `local-only` project is refused rather than provisioned.

The seed records `host:`, `root:`, and `home:` in `data/secondmates.md`, gates the host on readiness, sends a bounded manifest, and lets the remote host clone its own Firstmate home and project origins.
In the primary home, its durable registration effects are limited to that route and the charter brief under `data/<id>`; launch records are created only when the secondmate is launched.
That home is cloned from the host's own Firstmate copy, so provisioning repoints it at the route that copy delivers to; otherwise a validated change to the firstmate repo made from that home would be pushed into a directory on its own host and never open a pull request.
The parent's sync still imports a commit into the home from that copy by path, before trying `origin`, so nothing about handing it a commit changes.
Readiness starts with a read-only check; when that check reports a gap, it runs `--fix` and then a second read-only check whose verdict decides, so the operator never has to run the repair by hand and a repair is never trusted on its own word.
A host that stays red prints the doctor's remaining gaps and their operator steps, restores the registry, and creates nothing on the remote host.
It does not copy project trees or the primary process environment.
A known provisioning failure rolls back the new route, while SSH exit 255 preserves it because remote completion is unknown and must be reconciled on the same host.

Seeding also writes a durable `.fm-secondmate-parent` record next to the home's `.fm-secondmate-home` identity marker, naming this home's route to its parent as `local` or `remote`.
The promised-public-reply subsystem is same-filesystem by construction, so a remote route can never carry a delegated public-reply promise; `bin/fm-teardown.sh`'s cleanup gate reads this record to treat a remote parent as out of scope rather than an unresolved binding.

Local secondmates keep the existing route form, and a route that stays local needs no registry rewrite.
A fleet may contain local and remote routes together.
Use `bin/fm-home-seed.sh validate` to validate either form.

## Move an existing local home to a host

Seeding creates an empty home, so it cannot take over a registered local second mate that already holds a charter, a backlog, memory, reports, and routing correlations.
Moving that home is a separate explicitly selected command:

```sh
bin/fm-remote-home-seed.sh --migrate <id> <local-home> <ssh-alias> <remote-root> <remote-home>
```

It names exactly one registered local route, never a wildcard or a batch, and `<local-home>` must be the canonical path that route already records.
[`bin/fm-remote-home-migrate.sh`](../bin/fm-remote-home-migrate.sh) owns the command; its header owns the exact refusals, journal fields, and recovery mechanics.

The second mate must have persisted its work and exited through the ordinary [control plane](agent-control.md) first.
The command refuses while the home still holds any child work record, a registered state check, in-flight backlog work, a nested secondmate route, an armed process-event source or condition watch, an away or quiet posture, or a live session.
Its stream endpoint must read positively dead (a missing hub registry entry is not proof), so a home whose agent cannot be proved stopped is refused rather than assumed idle.
The host is gated on the same read-only [`bin/fm-remote-doctor.sh`](../bin/fm-remote-doctor.sh) readiness the seed uses, and migration never runs `--fix`: an account-level gap is reported with the doctor's own text and no route is switched.
An unclassified file under `config/` is named and refused during the preconditions, before anything is frozen; widening that set is a separate decision because the cost of guessing wrong is a credential on another machine.
Any refusal that lands before the host has staged anything - an unready host, an unmigratable project, a record the snapshot cannot carry - unwinds the freeze marker and the journal that run created, so a home the command declined to move stays startable.
Once staging has begun nothing local is unwound: the journal and the archive are retained for reconciliation.

What crosses is durable records only.
[`bin/fm-home-migration-lib.sh`](../bin/fm-home-migration-lib.sh) owns that transfer boundary: it carries bounded regular files, verifies every record against its own digest at the receiving host, and refuses traversal, links, special files, oversized payloads, and unclassified `config/` files.
Credentials, including the home-bound stream token, stay on the original machine, and host-local stream routing and implementation settings are excluded rather than copied; the classifier in [`bin/fm-home-migration-lib.sh`](../bin/fm-home-migration-lib.sh) owns the exact exclusions.
Provision the destination's own stream configuration before launch as described under [Stream on the remote host](#stream-on-the-remote-host).
The operator still has to read the home's own durable records before authorizing the move, because a secret pasted into ordinary prose is not detectable.
Projects are cloned on the host from each project's registered origin, exactly as a seed does, and no project tree, Git object, or working copy is copied.
`data/` and the classified configuration land live, the captain inbox and pending-reply records keep their operational locations, and the rest of `state/` is retained byte-exact as inert evidence under `.fm-migration/state/` rather than as executable runtime state on a machine it was never written for.
The original charter and parent binding are retained there too; only the active charter's reply address and steering-inbox path are rewritten for the new placement, so charter prose that names the old path as history stays as written.

The remote home is staged at an absent path, provisioned, verified byte-for-byte, and only then published atomically, and the source snapshot is re-taken and compared before the registry changes at all.
That snapshot is re-taken on every run before cutover, so a steer the parent queues for the stopped mate between attempts crosses with the next run rather than failing the comparison against the first attempt's snapshot.
An unchanged source packs to the same bytes, so a rerun that changes nothing re-sends the same payload and the host recognizes what it already staged.
A rerun whose snapshot adds records or changes the bytes of records already there re-lands them, but one that has stopped carrying a record the host already holds is refused and names it: the receiver adds and replaces, and never deletes a record on the host.
The route switch itself happens under the ordinary registry lock, after which the normal [`bin/fm-spawn.sh`](../bin/fm-spawn.sh) launch owner starts the same identity on that host's stream endpoint.
A launch failure the command can prove - a remote endpoint that reads back dead or missing - restores the original route and endpoint record, and both copies are kept.
Rerunning after that rollback retries the launch against the home already on the host: once a placement has been published the remote copy is the newer one, so the frozen source's records are never re-sent over it, and steering queued since the rollback reaches the mate through the ordinary steering path after it starts.
SSH exit 255 or an unreadable probe is unknown rather than failed: the remote placement is preserved, nothing is launched locally, and rerunning the identical command converges through the normal launch owner instead of creating a second endpoint.

A migration that fails on the host after staging began leaves that attempt's staging directory next to the remote home, named `.fm-migration-<id>.XXXXXX`, and a retried attempt creates its own rather than reusing or clearing an earlier one.
Each holds that attempt's bundle and a decoded copy of the same durable records - the charter, backlog, memory, reports, and configuration - so unlanded work is never removed automatically; only an attempt that completes its publication or verification clears its own staging.
Removing a retained one is a manual operator step (`rm -rf <remote-home-parent>/.fm-migration-<id>.XXXXXX`), and it is only safe once that attempt's work is confirmed present in the published remote home or in the local archive.

A rerun killed while refreshing a home already published on the host never leaves that home's migration receipt half-written: each half is renamed over the live file, so the home always holds a bundle that parses, and a kill between the two renames leaves a digest that no longer names the bundle beside it, which the next rerun converges.
That step can leave an inert `bundle.json.tmp.*` or `digest.tmp.*` sidecar in the home's `.fm-migration/`, which nothing reads and no operator step has to clear.

The original home is left behind as a frozen archive, not deleted.
A `.fm-home-migration` marker in it refuses a session lock, a spawn, a local launch, and a reseed, so the same identity cannot end up running in two places while the archive is still around for rollback.
The freeze outlives a route rollback on purpose: a restored local route points at a home that still refuses to start, because the remote copy of the same identity also exists at that moment.
Deciding which copy survives, clearing the marker, and returning the archive's worktree lease are separate later operator steps, and this command deliberately has no unfreeze or cleanup verb.

## Normal operation

Launch or recover the remote second mate with the same command used for a local route:

```sh
bin/fm-spawn.sh <id> --secondmate
```

The primary resolves the verified secondmate harness and optional model and effort, runs the same readiness gate the seed runs, transfers the inherited-material allowlist, and asks the remote host to launch on stream.
An explicit request for any other backend is refused, and the remote host refuses one too.
A parent record that still names a retired backend (tmux or herdr) is refused; stop any agent left on that endpoint by hand, then retire the record with `bin/fm-retire-endpoint.sh`.
A launch after a host has drifted out of readiness fails with the doctor's own gap text instead of leaving a half-created endpoint.
Raw launch commands are not accepted for remote secondmates.

### Stream on the remote host

A stream launch runs the host-local `bin/fm-spawn.sh` with the mate home's `config/`, so the agent publishes to that home's configured hub using its own credential; [stream setup and security](stream-backend.md#setup) own hub URL resolution and encrypted cross-machine access.
Remote route seeding does not mint a stream credential or configure the hub URL: provision that home's `config/stream-hub` and a home-specific `config/stream-token` accepted by the hub before launching; [stream Security](stream-backend.md#security) owns credential isolation and hub restart requirements.
The token never travels on a command line or in the launch environment.
The parent's endpoint binding is read back from the host's route; the [`bin/fm-remote-control-lib.sh` header](../bin/fm-remote-control-lib.sh) owns its exact `remote_*` fields.
Steering, peek, crew-state, the parent channel, and liveness run through host verbs on the configured host.
A stream `missing` read is the hub registry not knowing the endpoint, so the liveness sweep skips it with a diagnostic instead of relaunching, as it does for a local stream mate.

### Lifecycle control

`bin/fm-control.sh <id> interrupt|exit|relaunch` on the primary runs the same control plane on the host (`fm-remote-secondmate-control.sh control|relaunch`), so every postcondition is checked where the agent runs.
Before relaunch reaches host lifecycle control, the primary checks readiness with the same check/repair/recheck sequence as launch; a remaining gap or SSH exit 255 refuses without stopping the mate.
An ordinary primary `fm-control.sh` relaunch keeps the recorded profile unless flags replace it, resets unnamed model and effort axes when the harness changes, and rewrites the parent's binding and resolved harness, model, and effort from the host's route after success.
If that route read or parent publication fails after host success, the primary reports failure with the old parent binding retained; reconcile on the same host rather than assuming no replacement launched.
`recover-missing` remains unavailable through the primary for remote mates.

A remote route's endpoint records live in `state/parent-route`, which the launch creates private (`0700`) even under a permissive remote umask, because Deck's descriptor-bound status I/O refuses a group- or world-writable state root.
The launch and the relaunch each reconcile a root an earlier launch left group-writable to the mode Deck accepts, so no home needs a hand chmod before a Deck mate can start.
The reconcile touches only a real directory this host provably owns; a symlink, a non-directory, or a directory owned by another uid is refused loudly rather than chmod-ed, and the data root beside it is never tightened.

Startup liveness recovery relaunches a positively dead remote second mate through the normal spawn command, so recovery passes the same readiness gate rather than a weaker one; a missing stream endpoint follows the skip rule above.
A dead remote endpoint is removed before that relaunch, and a removal the backend cannot confirm refuses the launch instead of risking a duplicate mate beside a worker that may still be running.
A launch that starts an agent reports success only after the host proves, by process identity, that it replaced the previous one: the new endpoint hosts an agent process that did not exist before, and every previous agent process is gone.
A previous agent still running after its endpoint was removed refuses the launch rather than gaining a twin, and a proof that cannot be made within the bound is reported as a failed launch; [`bin/fm-remote-secondmate-control.sh`](../bin/fm-remote-secondmate-control.sh) owns that contract.
An endpoint that is already alive is reused rather than relaunched.

A persistent remote route's parent metadata intentionally has no local spawn-generation marker and identifies the route by its recorded host instead.
The Bearings inventory-reconcile request path therefore accepts these markerless routes, revalidates the sampled host at delivery, and refuses a route that changed hosts; [`fm-secondmate-reconcile.sh`](../bin/fm-secondmate-reconcile.sh) owns the exact cooldown, identity, and reporting contract.

Send routed requests normally:

```sh
FM_HOME=<primary-home> bin/fm-send.sh fm-<id> '<request>'
```

The [`fm-send.sh` header](../bin/fm-send.sh) owns the exact delivery-status contract.
A routed request is delivered as a durable record in the remote home's steering inbox plus a best-effort doorbell, never by typing the payload into the pane; exit 0 means the record durably exists.
Every remote transport attempt is bounded by `FM_SEND_REMOTE_BUDGET`; that header owns the setting's default and validation contract.
An unconfirmed SSH transport (exit 255) is retried identically once, while a budget expiry is not retried because completion is unknown; either outcome preserves this ordinary reply-bearing request's pending-reply expectation for the record that may have landed.
If delivery remains unconfirmed, only the exact `FM_PENDING_REPLY_EXISTING_CORR=<id>` resend command printed by `fm-send` is safe to run later because it preserves the request body and lets the remote enqueue deduplicate onto the same record; a plain rerun mints a different correlation and is not idempotent.
When deduplication finds that the worker already moved the matching record into `handled/`, the resend exits successfully without ringing the doorbell again.
The remote host runs no doorbell re-ring ladder of its own; a swallowed doorbell for an ordinary reply-bearing request surfaces through the parent's pending-reply recovery and escalation, whose recovery request rings the doorbell again when it is enqueued.
`fm-peek.sh` and `fm-crew-state.sh` route remote-secondmate reads to the endpoint's host instead of consulting local worktree or backend state.
An unreachable or unreadable remote read is unknown, not evidence that the endpoint is dead.

Marked requests keep the existing correlation contract.
The remote charter appends replies to `state/parent-replies.status` in the remote home.
It also names that home's own host-local steering inbox rather than the parent's state path, so the inbox a mate is told to read is the one its steers are delivered into (`bin/fm-remote-secondmate-control.sh` owns that directory).
The remote home's own outcome publishers append there too, through the channel contract in `bin/fm-parent-channel-lib.sh` ([secondmate-parent-channel.md](secondmate-parent-channel.md)).
A process-event source ([`bin/fm-procevent-remote-reply.sh`](../bin/fm-procevent-remote-reply.sh)) reads that log non-destructively from a cursor, fetches only referenced `data/*.md` documents through the confined reader, and mirrors every content-bearing line at most once into the primary status channel as soon as it is captured.
The mirror carries the mate's whole status and decision model: progress lines and newly raised `needs-decision` lines reach the parent's open-decision fold exactly as a correlated answer does.
Correlation settles a pending request and closes its open escalation decision, but it never gates the stream, so no single line can stop the relay or hold the cursor back.
Transport normalization rewrites NUL, every other C0 control except tab and newline, and DEL to `?`, while printable ASCII and all high bytes, including UTF-8, pass through unchanged.
A referenced document the confined reader permanently refuses is mirrored with its original pointer plus one keyed escalation naming the gap, and an SSH exit 255 while fetching one leaves the delta uncommitted for the runner's normal retry.
Because a remote reply reaches the primary only through this asynchronous mirror, the primary treats a missing correlated report as a missed report only once the mirror has been read through the end of the remote log after that turn ended.
A remote mate that did answer is therefore never asked to repost while its answer is still in flight, and a genuinely missing answer still gets exactly one repost once the mirror is known to be current.
The [process-to-event operating contract](process-event-sources.md) owns automatic application, one-announcement replay deduplication, and the unhandled fallback path.
The source log is never truncated or consumed.
A shortened or changed prefix stops the relay and surfaces a continuity failure instead of silently resetting the cursor.

An SSH exit status of 255 always means transport failure or unknown remote completion.
The underlying `fm-on` transport never retries automatically, but `fm-send` retries its correlation-preserving steering-inbox leg exactly once.
Semantic callers preserve the route or pending request; an operation that is not idempotent requires same-host reconciliation rather than a blind resend, while an unconfirmed steer may be retried only through the correlation-preserving command described above.
An unavailable remote home is projected as unknown and is never replaced by a local second mate.

## Backlog handoff

Move already-judged queued work with the normal command:

```sh
bin/fm-backlog-handoff.sh <id> <item-key>...
```

For a remote route, `tasks-axi mv` first moves the dependency-closed set atomically from the primary backlog into `data/handoff/<id>.outbox.md`.
The outbox is then copied to the remote handoff scratch directory and `fm-backlog-receive.sh` atomically ingests every destination-absent key under the remote backlog's own lock.
The [`bin/fm-backlog-handoff.sh`](../bin/fm-backlog-handoff.sh) header owns remote outbox release after receipt and stable wake-correlation retry behavior.
Bootstrap retries pending outboxes and wakes, and emits `SECONDMATE_HANDOFF:` only when an outbox remains.
There is no two-phase journal and no additional tasks-axi release requirement.

## Sync, update, and retirement

Locked startup convergence and `bin/fm-config-push.sh` transfer only the declared inherited-material allowlist.
Changed live routes receive a marked instruction to re-read the transferred files.
The primary records that remote nudge before delivery and retries it during locked startup convergence after a failed send.
Local secondmates retain their generation-specific local pointer contract; remote transfers do not copy those primary-local instruction paths.

During updates, [`bin/fm-secondmate-restart.sh`](../bin/fm-secondmate-restart.sh) restarts live remote mates through the host-local `relaunch` route described under [Lifecycle control](#lifecycle-control).
The host then applies the same replacement proof as a launch before it reports the restart: the old agent process, identified before anything touched it, must be gone and the endpoint must host an agent process that did not exist before.
The primary passes `<harness> <model|default|-> <effort|default|->` explicitly, using `default` when an axis has no parent pin, because `config/secondmate-harness` is not inherited into a second mate's home and the file on that host belongs to a different home; letting the far side re-resolve it would silently change the mate's profile.
SSH exit 255 leaves completion unknown and the route preserved, exactly as every other verb here.

Session start and every remote launch converge the persistent remote home on the primary's own default-branch commit rather than on the Firstmate copy that host keeps.
The [`secondmate-provisioning` skill](../.agents/skills/secondmate-provisioning/SKILL.md) owns the guarded convergence contract, including the distinct `/updatefirstmate` behavior, and [`bin/fm-remote-secondmate-control.sh`](../bin/fm-remote-secondmate-control.sh) owns the commit-import mechanics.
Neither session start nor launch moves the host's own Firstmate copy, and an unsafe or unavailable target is reported and left untouched.
A completed sync reports which watched instruction paths its advance changed, because the primary cannot diff a checkout it cannot read and needs that fact to decide whether the running remote agent must be replaced to actually reload.

Retire a remote second mate with the normal guarded command:

```sh
bin/fm-teardown.sh <id>
```

Retirement is executed on the configured host and refuses while the remote home has child work, while the primary has an unfinished backlog outbox, or while a routed reply remains unresolved.
It closes only the retiring secondmate's stream endpoint and never a sibling secondmate's.
SSH exit 255 preserves both the route and local records because completion is unknown.
`--force` remains the explicit discard path and requires the same captain authority as local secondmate discard.
No generic remote delete or write surface exists: remote writes are confined to inherited allowlist files and backlog handoff scratch files, and remote home removal is reachable only through guarded secondmate retirement.

## Verification

The portable tests use the real entrypoint protocol, real git repositories, a deterministic SSH boundary, real or stub stream hubs, and a controlled account fixture for the readiness gate.
The lifecycle test covers seeding a registered project that this machine has never cloned, asserts that the local project tree is unchanged afterwards, and carries Bitbucket, self-hosted, and scp-like origins through to the remote clone:

```sh
bin/fm-test-run.sh tests/fm-on.test.sh
bin/fm-test-run.sh tests/fm-send-remote-delivery.test.sh
bin/fm-test-run.sh tests/fm-secondmate-reconcile.test.sh
bin/fm-test-run.sh tests/fm-peek-remote.test.sh
bin/fm-test-run.sh tests/fm-crew-state.test.sh
bin/fm-test-run.sh tests/fm-remote-job.test.sh
bin/fm-test-run.sh tests/fm-remote-transport-lanes.test.sh
bin/fm-test-run.sh tests/fm-remote-doctor.test.sh
bin/fm-test-run.sh tests/fm-project-origin.test.sh
bin/fm-test-run.sh tests/fm-secondmate-sync.test.sh
bin/fm-test-run.sh tests/fm-remote-reply.test.sh
bin/fm-test-run.sh tests/fm-remote-backlog-handoff.test.sh
bin/fm-test-run.sh tests/fm-remote-secondmate-lifecycle-e2e.test.sh
bin/fm-test-run.sh tests/fm-remote-home-migration.test.sh
bin/fm-test-run.sh tests/fm-remote-secondmate-trace-context.test.sh
bin/fm-test-run.sh tests/fm-remote-secondmate-replacement.test.sh
bin/fm-test-run.sh tests/fm-remote-secondmate-stream.test.sh
```

The stream route suite uses a real hub, stream agent, pseudoterminal, and Deck host driver with a fake Deck binary and deterministic SSH/readiness boundaries; it covers launch, steering, reads, lifecycle routing, readiness refusal before lifecycle control, profile-axis reset, resolved-model rebinding, and primary route publication.
These fixtures are regression coverage, not real-host readiness or real-model verification.

The migration case reuses that same lifecycle fixture for the refusal, transfer, rerun, rollback, and frozen-archive contracts described under [Move an existing local home to a host](#move-an-existing-local-home-to-a-host).

The account-level checks the doctor performs, a real Aqua login session and a real `launchctl` domain, are only ever exercised against fixtures here, so the readiness gate's behavior on a genuine Mac remains an operator-run smoke test.

For a real-host smoke test, provision a disposable remote account and project, run the doctor and its repair against that account, launch the second mate, send one marked request, verify its correlated reply and structured fleet projection, simulate an unreachable host to confirm unknown-without-failover behavior, then retire only after the remote queue is empty.
Full real-host lifecycle validation remains an operator-run smoke test.
The opt-in real-SSH reply fixture in [`tests/fm-remote-reply-ssh-fixture.sh`](../tests/fm-remote-reply-ssh-fixture.sh), selected through `tests/fm-remote-reply.test.sh`, covers only synthetic reply capture and re-arming; its header owns the required route and explicitly authorized disposable remote tree.
