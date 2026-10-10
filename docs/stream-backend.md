# Stream backend

The stream backend puts every task's live terminal output on one central hub, so a single place can watch workers on any machine and talk to them.
It is firstmate's only runtime backend; [`Away-mode supervisor backend`](configuration.md#away-mode-supervisor-backend-fm_supervisor_backend--fm_supervisor_target) owns the separate primary-supervisor discovery.

[`docs/configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns backend selection, task-selector resolution, and the task metadata contract.
This document owns setup, security, and the limits specific to stream.

## What it is

Three pieces, and the split matters:

- **The hub** (`fm-stream-hub`, built from `crates/fm-stream-hub`) is one service for the whole fleet, and it owns no pseudoterminal.
  It holds a bounded ring buffer per endpoint, relays commands, and answers state reads.
- **The agent** (`fm-stream-agent`, built from `crates/fm-stream-agent`) runs on the machine that runs the task and owns that task's pseudoterminal.
  One agent owns one endpoint.
- **The adapter** (`bin/backends/stream.sh`) is the runtime backend firstmate drives through the shared dispatcher.

The hub and agent are the Rust binaries by default; [Implementation and native binaries](#implementation-and-native-binaries) owns how they are built, where they live, and the Python rollback.

Because the hub owns no pseudoterminal, it can fail without taking a worker with it.
[When the hub is down](#when-the-hub-is-down) owns what that does and does not cost you.

## Setup

The fleet runs one hub.
Build the native binaries, then start it on whichever host the fleet can reach:

```
bin/fm-stream.sh native ensure
bin/fm-stream.sh hub start
bin/fm-stream.sh status
```

Every other home points at that hub rather than starting its own, by writing its base URL to `config/stream-hub` or exporting `FM_STREAM_HUB`.
Resolution order is `FM_STREAM_HUB`, then `config/stream-hub`, then a hub this home started itself, then `http://127.0.0.1:7717`.
The locally started hub ranks below both configured sources, so a home pointed at the fleet's hub keeps using it even while running a hub of its own; it ranks above the default so that starting a hub on a non-default port does not leave every other command resolving a port nothing bound.

The hub groups endpoints by the machine that owns them, and this home's name in that view comes from `FM_STREAM_MACHINE`, then `config/stream-machine`, then the hostname.
It is a readable identity rather than an opaque id, so set it on any home whose hostname says nothing useful.

An absent `config/backend` means stream, and a leftover `tmux` or `herdr` value is refused rather than ignored.
Secondmate spawns use the isolated-home launch path through Deck's persistent home-host driver (`bin/fm-deck-worker.sh`).

## Secondmate lifecycle

`bin/fm-spawn.sh` selects the home and harness, and `bin/fm-task-inbox-lib.sh` with `bin/fm-send.sh` owns durable steering and the doorbell.
Deck's host invariants are documented in `bin/fm-deck-worker.sh`: a watcher wake is never lost between turns, turns never overlap, and failures are reported rather than swallowed.
`tests/fm-deck-harness.test.sh` exercises those invariants, and `tests/fm-backend-stream.test.sh` exercises a Deck home through the real stream transport, including launch, steering, liveness, interrupt, exit, same-endpoint relaunch, and recovery.

Recovery classification is `fm_backend_agent_state` in `bin/fm-backend.sh`.
At session start, `bin/fm-bootstrap.sh` respawns a confirmed-dead secondmate only after endpoint closure is confirmed, rechecking liveness and deliberate-stop protection under the mate's lifecycle lock.
For a stream mate, `missing` means the hub's in-memory registry does not know that endpoint, which an agent still pacing its rejoin after a hub restart also produces, so the startup sweep skips it with an `absence from the hub registry` diagnostic.
A stream mate whose own agent is gone reads `unreadable` while the hub still holds its record, then `missing` once the hub reaps that record after an hour of agent silence; an unreadable state never licenses automatic recovery.

Between session starts, the owning home's watcher runs [`bin/fm-secondmate-revive.sh`](../bin/fm-secondmate-revive.sh) without waiting for a model turn; its header owns confirmation, per-mate concurrency, retry limits, escalation, and the environment knobs, with the scan cadence owned by [`bin/fm-watch.sh`](../bin/fm-watch.sh).
With the watcher running and default settings, a consistently dead mate normally reaches a recovery attempt within a couple of minutes; completion depends on the control-plane postconditions, and unknown readings or a competing lifecycle action defer recovery.
The scan uses control-plane relaunch for a dead endpoint and guarded missing-endpoint recovery below for a local registry gap; [remote lifecycle control](remote-secondmates.md#lifecycle-control) owns remote limits.
Successful revivals are silent and logged; a spent revival budget produces one failure notification rather than repeated restarts.
A secondmate deliberately stopped through control-plane exit stays down across scans and session start until explicitly relaunched or freshly observed alive; [`bin/fm-control.sh`'s header](../bin/fm-control.sh) owns the stop marker and automatic-admission guard.
[`verification/supervision.md`](verification/supervision.md#secondmate-revival) lists the portable regression entry points.

A new stream agent generates a fresh endpoint id, so `recover-missing` starts a new endpoint on this home's configured hub (same `fm-<id>` label, the recorded worktree as its cwd) and rebinds the task's endpoint identity through [`bin/fm-endpoint-rebind-lib.sh`](../bin/fm-endpoint-rebind-lib.sh), keeping its worktree and non-endpoint fields.
Because a stream `missing` alone does not prove the worker gone, recovery first looks for a local stream agent matching both the task label and this home's task status path.
A matching agent blocks recovery even when the hub has forgotten it; wait for its re-registration or stop that exact agent before retrying.
[Agent control](agent-control.md#failure-and-rollback) owns failed-rebind cleanup, retained new-endpoint bindings, and retry handling.

[Remote placement](remote-secondmates.md#stream-on-the-remote-host) owns stream-hosted remote mates and their supported lifecycle routes.

A locally seeded stream-hosted second mate launches, is steered, and reports its own lifecycle, but it cannot itself spawn or supervise on stream until the hub has restarted since its seeding wrote the home a credential.
Both PTY agents hand the hosted process the hub address and deliberately withhold the token, and `FM_INHERITABLE_CONFIG` in `bin/fm-config-inherit-lib.sh` mirrors `backend` into that home without `stream-hub` or `stream-token`, so the launch path carries no credential.
The credential arrives through seeding instead, and until the hub restarts the seeded token is one the running hub has not loaded, so the home's first stream call is refused by the hub.
A home that seeding left without a credential (see [Security](#security)) dies in `fm_backend_stream_token` (`bin/backends/stream.sh`) on its first stream call, before any endpoint exists.
The remedy that refusal names does not work there: `bin/fm-stream.sh token --ensure` mints a fresh random token, which the fleet hub refuses.

## Implementation and native binaries

`FM_STREAM_IMPL`, then `config/stream-impl`, then `rust` selects which implementation `hub start` and endpoint launches run.
`rust` runs the `fm-stream-hub` and `fm-stream-agent` binaries; `python` runs `bin/fm-stream-hub.py` and `bin/fm-stream-agent.py` and is the explicit rollback.
Nothing falls back from one to the other: a rust home without built binaries refuses with the build command and the rollback.

The binaries are built from `crates/`, not tracked in git, and [`bin/fm-stream-native-lib.sh`](../bin/fm-stream-native-lib.sh)'s header owns the build and location mechanics:

- `bin/fm-stream.sh native build` builds the hub, agent and bridge with `cargo build --release --locked` for the host triple (Rust 1.96 or newer) and installs them, with a `stamp` naming the source key and commit, into `~/.local/share/firstmate/stream-native/<source-key>/` (`FM_STREAM_NATIVE_CACHE` or `XDG_DATA_HOME` move it).
  The source key hashes the working-tree content of `crates/`, `Cargo.toml` and `Cargo.lock`, so a primary and its local secondmate worktrees on the same sources share one build, and a checkout whose crate inputs changed resolves a new, unbuilt directory instead of running stale binaries.
- `native ensure` reuses a complete stamped install for the current key and builds otherwise.
  `bin/fm-update.sh` runs it for a rust primary left updated or already current, and for each settled local secondmate with a recorded window whose own selection is rust; skipped homes, registry-only homes without a window, and remote homes are not prepared by this path.
  Native preparation is best-effort and never fails the update; the script's header owns summary labels and build-log locations.
- `native status` prints the selection, the resolved directory and its stamp; `native path` prints the directory.
- Cargo is found on `PATH` or at `~/.cargo/bin/cargo`.
  Without it the build refuses and names the rustup install (`curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal`, which installs into `~/.cargo`); the host also needs a C linker (`cc`).
- A host that should not build can be fed binaries built elsewhere for the same OS and CPU: put the directory in `config/stream-native-dir` (or `FM_STREAM_NATIVE_DIR`).
  It is used as is, with no source-key check.

Running hubs and agents keep the binary they started with; a rebuild changes only what the next `hub start` or spawn runs.
The Bridge order path (`command`, `reconcile`) is still Python-only; [Rust bridge](#rust-bridge) owns what the native bridge covers.

### Running the hub as a systemd user service

`bin/fm-stream.sh hub unit [--bind ADDR] [--port N]` prints a unit that runs `fm-stream.sh hub start --foreground` in this home; it installs nothing and refuses paths or arguments it cannot quote safely.
The unit does not pin the implementation, so it follows `config/stream-impl`, and a rollback is a config edit plus a restart.
Install it with `bin/fm-stream.sh hub unit --bind 127.0.0.1 > ~/.config/systemd/user/fm-stream-hub.service`, remove any drop-in under `fm-stream-hub.service.d/` that overrides `ExecStart` with a hand-built binary, then `systemctl --user daemon-reload`.
Restarting the hub is a quiet-window operation: [Rust hub](#rust-hub) lists what to drain first.

## Prerequisites

`python3`, `curl`, and `jq` must be present, and the hub's protocol must match the adapter's.
A rust home also needs the native binaries for its checkout ([Implementation and native binaries](#implementation-and-native-binaries)).
Launching a local endpoint or a background hub also requires either `setsid` on `PATH` or, when it is absent (as on stock macOS), `perl` with `POSIX::setsid` support.
A missing dependency, an unreachable hub, a refused token, or a protocol mismatch is terminal: the adapter refuses and names what is wrong.

Run `bin/fm-stream.sh --help` for the operator commands; that help and each script's header own their exact flags.

## Away mode on a stream primary

[`Away-mode supervisor backend`](configuration.md#away-mode-supervisor-backend-fm_supervisor_backend--fm_supervisor_target) owns primary discovery, stream digest delivery, and detached daemon launch.

## Watching and steering

`bin/fm-stream.sh web` prints the browser URL for the one central subscriber view, carrying the token as a URL fragment, which a browser never sends, so the navigation to the page carries no credential.
The page's own event stream is the one request that does carry the token in a URL, because an `EventSource` cannot set a header: the hub logs nothing, but a TLS terminator or proxy in front of it logs whatever it is configured to.
`bin/fm-stream.sh tasks` lists every endpoint across every machine, and `attach` streams one endpoint to stdout.

Ordinary supervision does not need any of that: `fm-peek.sh`, `fm-send.sh`, `fm-crew-state.sh`, and `fm-control.sh` all work against stream-backed tasks through the shared dispatcher.
[`fm-send.sh`'s header](../bin/fm-send.sh) owns unrecorded explicit-target inference, including stream targets on this home's configured hub.
[`fm_backend_agent_pids`](../bin/fm-backend.sh) owns the process-identity read contract, including stream's local-machine restriction.
[Portable stream-parity regressions](verification/runtime-backends.md#portable-stream-parity-regressions) distinguish fake-fleet integration coverage from real agent process reporting.

### Task events

A client that would otherwise poll `GET /v1/tasks` subscribes to `GET /v1/tasks/events` instead, with the same `subscribe` token in the `Authorization` header (never a query token).
It is a `text/event-stream`: an `event: snapshot` record carries `ok: true`, `seq: 1`, the hub `generation`, `machines`, and a `tasks` array containing exactly the records `/v1/tasks` would list, then each `event: delta` record carries the next `seq`, the same `generation`, the changed `tasks` records, and the `removed` endpoint ids, with a `: keepalive` comment after 15 idle seconds.
Sequence numbers are local to each connection and advance only for snapshots and deltas, not keepalive comments.
An endpoint's record is pushed again when any listed fact other than its measured ages and output offset changes, including whether it is its leaf's current execution, whether its agent has been silent past the 10-second presumption window, and whether a state frame has arrived.
The silence crossing uses the listed `agent_silent_for_secs`, rounded to three decimals: a value at or below `10.000` is within the window and a value above it is outside.
Output-only growth is pushed at once after a quiet spell and then at most once every 2 seconds per endpoint, so a busy worker costs a subscriber one small record per 2 seconds rather than one per frame.
A snapshot or first sighting does not start that output throttle, and a change to another listed fact can push the latest output offset before the throttle expires.
Ages in a pushed record are as measured when it was sent and are not refreshed in between, and `machines` arrives only in the snapshot.
The hub advertises the route as the `task_events` capability in `/v1/health`; an older hub answers 404, so a client keeps reading `/v1/tasks` there, and a reconnect after a hub restart starts again from a new snapshot with a new `generation`.
The Rust hub wakes a subscriber on its registry change signal, spacing registry evaluations at least 25 ms apart so a busy worker causes at most 40 evaluations per second per subscriber and structural or liveness updates wait at most 25 ms for this bound; the Python rollback has no change signal and re-reads its own memory every quarter second, which changes cost on the hub only, not what is sent.
Each task-events stream also reaps retained endpoints at most once a second, so their removal does not depend on a client continuing to poll `/v1/tasks`.

### Interactive attach

`bin/fm-stream.sh attach --interactive <endpoint-or-target> [--detach-key C-]]` takes over the local terminal, which is how a TUI hosted on an endpoint (a `deck chat` primary, for one) is used by hand.
Over the hub it paints the endpoint's current screen and cursor, then streams output from an exact offset and forwards every keystroke, paste and local resize to the endpoint's pseudoterminal.
Paint restores cells and cursor only, so a full-screen TUI should repaint on its own, as most do on `SIGWINCH` or their next frame.
If output overruns the ring buffer during the session, the client reports a continuity error and exits non-zero rather than rendering discontinuous bytes; read-only `--replay` remains best-effort from the oldest retained byte.
Any failed input or resize delivery ends the session with an explicit failed or uncertain delivery message, without retrying input.
The native agent publishes its buffered output and drains at most 64 KiB of immediately readable PTY output before resizing, then queues the new geometry ahead of subsequent output.
After the first resize transition, each output POST repeats the geometry applicable at the start of that batch before its bytes and any later transitions, so losing a geometry publication cannot leave subsequent delivered output parsed at the old size.
Failed output batches are not replayed; repeating geometry restores size, not missing terminal content.
A hub or endpoint that does not support resize (an older hub, or a Python-backed endpoint) disables further resizes and keeps the session open.
Ctrl-] (or `--detach-key`, written `C-<key>`) detaches and leaves the endpoint running after draining preceding input for at most two seconds; external `SIGINT`, `SIGTERM`, and `SIGHUP` detach the same way, while typed Ctrl-C is forwarded to the endpoint.
A failed or timed-out drain reports unsuccessful or uncertain delivery instead of a clean detach.
Endpoint exit status is propagated, and every session exit restores the local terminal before printing the final message.

When the endpoint's native agent runs on the same machine as the client, the interactive session uses that agent's private unix socket, `<dir>/<endpoint-id>.sock`, instead of the hub transport:

- `<dir>` is a nonempty `FM_STREAM_LOCAL_DIR`, else `/tmp/fm-stream-<uid>`.
  Set an override identically for the agent and client; the fixed default lets a launchd agent and a terminal client find each other.
  It must be a directory this user owns with no group or other permissions (the agent creates it 0700), the socket is 0600, and both sides check the peer uid.
  An unsafe directory or a failed peer check disables the fast path rather than trusting it.
- The agent keeps its own screen model fed with the same bytes it queues for the hub: resize first, then a snapshot and the output that continues exactly after it, with resizes forwarded and the endpoint's exit status propagated.
  Local input is admitted to a bounded queue of 256 chunks of up to 4096 bytes; a full or closed queue ends attach with an uncertain-delivery message, without retrying input.
  Detach closes admission without waiting on the socket writer, which drains admitted chunks in order before shutting down its write half; the detach deadline above remains independent of that writer, and a clean local detach requires the agent's explicit input-drain acknowledgement.
  The native agent serializes each complete local or hub PTY input write so their bytes cannot interleave; concurrent writes have no promised ordering between transports.
  A client that falls far enough behind to queue 4096 output chunks is disconnected rather than stalling the endpoint.
- Output is still queued for hub watchers, with local resizes ordered as described above.
- No socket, a stale one, a Python agent, or an endpoint on another machine falls back to the hub path above.
  A connected agent that does not answer the hello within three seconds also falls back; an explicit closed or refused response ends attach instead.
  `FM_STREAM_ATTACH_LOCAL=0` forces the hub path.
- A long `FM_STREAM_LOCAL_DIR` can push the socket path past the 104-byte limit macOS puts on it, which also just disables the fast path.

The native agent coalesces PTY reads with a 1 ms continuation wait, publishing when the burst reaches 64 KiB or 8 ms instead of waiting for an HTTP round trip after each kernel read.
Output enters a bounded 1 MiB hub outbox before local delivery; the reader waits outside the output lock when less than a 64 KiB publication budget remains, preserving endpoint backpressure without making local resize wait for hub progress.
Both local and hub resize paths refuse a size change with `resize refused: hub output backlog full` when the outbox cannot fit the buffered output plus a 64 KiB drain budget, leaving buffered output and geometry unchanged rather than waiting or exceeding the bound.
A resize to the existing size needs no publication budget, and size changes can succeed again once the outbox drains.
A separate publisher drains queued output over a dedicated kept-alive client, limiting each POST to 64 KiB of output across all geometry boundaries to stay inside the hub's 256 KiB replay ring.
Other agent calls deliberately retain their unpooled client.
The command loop wakes as soon as a take or result post completes, while empty polls retain a 100 ms start-to-start floor even with `--poll-secs 0`, and the native hub sends with `TCP_NODELAY`.
[Interactive attach verification](verification/runtime-backends.md#interactive-attach-latency) owns the reproducible echo and redraw benchmark and recorded observations.

The wrapper passes the token to the native `fm-stream-agent attach` client through the environment, never argv.
Hub-path interactive attach needs both `subscribe` and `control` grants; [Security](#security) owns token classes and configuration.
The wrapper and native client still require a configured hub URL and nonempty token before trying the local socket, but local transport does not authenticate that token against the hub.
The client requires [native binaries](#implementation-and-native-binaries) whatever `config/stream-impl` says, including in a Python home.
Against the Python rollback hub it starts from the screen without exact offset continuity and cannot resize or send non-UTF-8 bytes; a Python-backed endpoint on the native hub supports exact-offset output but refuses resize and raw-byte input.
`tests/fm-stream-attach-rust.test.sh` drives it from a real PTY against a disposable native hub and agent, over both the hub path and the same-machine socket (the latter with the hub address pointing nowhere).

## Bridge feed

`bin/fm-stream-bridge.py` translates the hub into the Bridge UI's live wire format: one JSON record per line on stdout, one heartbeat per worker per tick, taken from the execution the hub marks current.
The feed direction only reads the hub: `serve`, `snapshot`, and `compare` in live mode hold a `subscribe` credential, open no listening socket, and send nothing to any worker.
`translate` is offline and needs no hub credential.
Writing is a separate command with its own credential, which [Command path](#command-path) owns.
Before any live subcommand does work, the adapter negotiates the hub protocol and the advertised `current_execution` capability, and rejects an older running hub with a restart-or-upgrade diagnostic rather than guessing which execution is current.
Its header owns the record mapping and every field the hub cannot supply.
The short version: the hub listing carries no token counters, so every record is a heartbeat, and only an exit the endpoint's own agent reported becomes `Stopped` or `Failed` while everything else is `Unknown`.
When the hub cannot be read it emits nothing, so during an outage, or after a hub restart that lists no endpoints, the Bridge keeps showing each worker's last state.

The Bridge does not consume this feed yet.
The record format follows the ingest contract in the Bridge UI project's `docs/telemetry.md`, which lives in that project, not this one.
How the feed reaches the Mac that runs the Bridge, over an SSH tunnel or as plaintext on the LAN, is an open decision the captain owns, and nothing here wires either one.

Run it on the host that runs the hub:

1. Give it its own read-only credential: add a bare token line to `config/stream-hub-tokens` and put the same token alone in a 0600 file for `bin/fm-stream-bridge.py`.
   A home still on the single `config/stream-token` has no such file, and creating one replaces that token's every-class grant, so write the home's own `publish,subscribe,control:<token>` line into it as well.
   The hub reads its token file only at start, and [a restart](#when-the-hub-restarts) clears terminal scrollback and Bridge-order reconciliation, so make this change only when no order is pending or may need a resend.
2. Start it against the local hub:

   ```
   bin/fm-stream-bridge.py serve --hub http://127.0.0.1:7717 --token-file <file> --fleet-id <name>
   ```

3. To read the feed from another machine, run that same command over SSH from the reading machine and consume its stdout.
   There is no network listener for the feed.

`snapshot` prints one tick and exits, and `translate` replays recorded hub listings, which is how its tests drive it.
`compare` sets the feed's rendered state for each of this home's stream-backed tasks against `bin/fm-crew-state.sh`, and flags a worker the feed calls stopped while the pane read says it is working.
Nothing runs it automatically.

### Rust bridge

The Rust bridge is built with the other [native binaries](#implementation-and-native-binaries), but the Python bridge remains the deployed reference until the port's parity is proven.
`fm-stream-bridge` from `bin/fm-stream.sh native path` can replace `bin/fm-stream-bridge.py` for the read-only `serve`, `snapshot`, `translate`, and `compare` subcommands with explicit hub, token-file, and fleet-id flags; switching does not replace or restart any deployed Python process.
Order placement and passive reconciliation remain Python-only.
For `compare`'s executable-relative home default, install it beside the existing scripts in `bin/`, or pass `--home` and `--crew-state` explicitly.
It follows HTTP redirects, limits epochs to signed 64-bit integers, and bounds JSON nesting at 128 containers.
`tests/fm-stream-bridge-rust.test.sh` owns the parity comparison against disposable Python hubs.

### Rust PTY agent

`bin/backends/stream.sh` launches the native `fm-stream-agent serve` for every endpoint when the implementation is `rust`, with the same arguments, ready-file format (`machine endpoint_id`) and status-path contract as the Python agent; its `--help` owns the option surface.
It needs no Python interpreter at runtime.
The adapter binds `FM_STREAM_CODE_ROOT` to its checkout so cached native binaries can invoke `bin/fm-task-inbox-lib.sh`; when launching the agent directly outside the repository, set that variable to the repository root.
`crates/fm-stream-agent/src/local.rs` owns the same-machine attach socket and its wire format ([Interactive attach](#interactive-attach)).
`crates/fm-stream-agent/src/receiver.rs` implements the native Deck receiver described under [Command path](#command-path), and `crates/fm-stream-agent/src/commands.rs` owns the Rust scheduler and durable result reconciliation.
The receiver leaves ordinary steering and unparseable stream-order sources in the task inbox untouched rather than letting them block other orders or recovery.
HTTP redirects are refused rather than forwarding endpoint credentials to a redirect target, so point it directly at the final HTTP or HTTPS hub URL.
Option names must be given in full, geometry is bounded to the kernel's unsigned 16-bit values, and heartbeat and poll intervals must be finite and nonnegative.

`tests/fm-stream-agent-rust.test.sh` compares both agents against disposable Python hubs, and `cargo test -p fm-stream-agent` covers durable reservation and result recovery and the process-group signal boundary.
`tests/fm-backend-stream.test.sh` runs the whole adapter suite against the native agent in the Rust CI job (`FM_TEST_STREAM_IMPL=rust`); other suites pin the Python reference because their runners have no native build.

## Rust hub

`bin/fm-stream.sh hub start` runs the `fm-stream-hub` binary when the implementation is `rust`, with the same bind, port, token file, ready file and pid file as the Python hub.
Building or rebuilding the binaries does not stop, replace, or restart a running hub.
The binary's `--help` owns its CLI flags, which must be given in full with a separate value.
[Security](#security) applies to both hubs, including the plain-HTTP transport boundary.
Forwarded input and status values keep Python JSON semantics, so a Python agent behind the native hub receives the original values.
`tests/fm-stream-hub-rust.test.sh` drives isolated Rust and Python hubs from equivalent state and compares their records and lifecycle outcomes.
[Runtime verification](verification/runtime-backends.md#stream) records current evidence and host-specific gaps.

Switching the central hub between implementations, in either direction, is a separate, explicitly approved quiet-window operation.
Before replacement, require green compatibility checks, the same protocol and token-class configuration, an unchanged external URL and TLS termination, and an available rollback command.
Drain or resolve every queued, taken-but-unacknowledged, or otherwise unconfirmed command or order before stopping either hub; [Command path](#command-path) and [When the hub restarts](#when-the-hub-restarts) own the in-memory reconciliation and rejoin contracts.
Verify agent re-registration after replacement under those contracts.
Never redirect live agents at a trial hub, reuse the fleet's ready or pid files for one, or mirror production control requests to it: an order is an action on a worker, not passive shadow traffic.

## Command path

The writing half of the Bridge chain is `bin/fm-stream-bridge.py command`.
It reads one `command` record per line on stdin (the composer's order), places valid orders with the hub, and writes each resulting `command_ack` or `command_nack` to stdout in the feed's NDJSON framing.
The [adapter's header and help](../bin/fm-stream-bridge.py) own the record shapes, acknowledgement rules, hub capability negotiation, and process lifetime options, including the opt-in stdin idle bound, which does not wait for or reconcile a late result.

Every order names both a worker by `leaf_worker_id` (`<machine>/<label>`, as the feed emits and `fm-stream.sh tasks` lists) and the exact execution the feed showed.
That binding prevents an order composed for one run from being typed into its replacement.
For Deck, a Bridge order corrects the already-running turn without ending, displacing, or restarting it; ordinary firstmate steers through `fm-send` still use the next-turn doorbell path.
Native Deck acceptance is execution-bound through the durable receiver, never a PTY write (non-Deck endpoints keep PTY typing), and requires a Deck build supporting `deck run --steer-dir`; an unavailable interface is refused without changing the running turn or falling back to PTY input.
Native text must be nonblank and fit below Deck's 64 KiB projection ceiling, with space reserved for source paths and acknowledgement guidance.
`bin/fm_stream_deck.py` owns Deck's durable source, original-turn binding, idempotency, reconciliation, and refusal mechanics.
In `command` mode, the owning agent's report that its worker ended produces an authoritative membership nack, while unresolved membership or application produces no record and remains pending.

Captain-direct messages (`fm-send --from-captain`) use the durable task inbox rather than the Bridge order journal.
With a stream-hosted driver and a Deck build supporting `--steer-dir`, ringing attempts native publication into a live turn, and each new turn also attempts publication of pending captain messages before its first model call.
Published messages reach the model at its next safe point without interrupting or restarting the turn; [`project_captain`](../bin/fm_stream_deck.py) owns publication eligibility, sequencing limits, and acknowledgement rules.
Native publication is best-effort: unsupported builds, skipped records, and publication failures retain the ordinary inbox path rather than refusing the durable send.
An idle driver starts a turn on the doorbell when its composer is safe to submit; pending human text is never overwritten or submitted by that ring.
The [`fm-send.sh` header](../bin/fm-send.sh) owns delivery status and reply tracking, and the [driver header](../bin/fm-deck-worker.sh) owns suppression of redundant empty-inbox doorbells.

The hub places Bridge orders only to endpoints whose agent advertises reliable result acknowledgement and the native steering receiver.
An agent requires the hub's `idempotent_command_results` capability before registering, so an older running hub is rejected with a restart-or-upgrade diagnostic.
Protocol-2 agents cannot register; retained protocol-3 agents without the receiver capability keep input, status, and kill support, but Bridge orders to them are refused before routing, so upgrade them only at a safe worker boundary.
Each order carries the hub generation, so a replacement hub rejects a stale order before placement and the adapter renegotiates before retrying.

The Bridge order journal lives in the hub's memory, not on disk, and retains bindings for the most recent 512 orders.
While an id remains there, an identical resend is answered from the original order; reuse with a different leaf, execution, or text is refused as an idempotency conflict.
A retry after more than 512 newer orders is not guaranteed to be deduplicated.
After an unconfirmed placement, `bin/fm-stream-bridge.py reconcile` reads the original order's current fate with a `subscribe` credential, once per invocation, so a UI can poll for late acceptance or refusal without resubmitting.
Pending and missing-journal answers are lookup diagnostics, not worker-membership verdicts.
Both hubs keep taken commands pending for 15 minutes and completed results answerable for 15 minutes after completion; a journal-referenced command that times out stays completable by its original authenticated result for a further 15 minutes rather than being requeued.
Loss of completion eligibility leaves the order honestly unconfirmed rather than synthesizing a result or replaying the command.
An agent retries a result post after a lost response without reapplying the command, and a worker that exits meanwhile keeps its publisher alive while the result can still settle.
A hub restart empties the journal along with the registry, so a resend has no hub-side delivery history; after the same endpoint re-registers, retained Deck receiver records can still reconcile the same order id against its original turn.
`tests/fm-stream-bridge.test.sh` and `tests/fm-stream-hub-retention.test.sh` pin reconciliation and retention.

The credentials are separate on purpose: `command` needs a `control`-class token, the class that can type into workers, while the feed holds `subscribe` alone, so a host running only the feed cannot order anything with the credential the feed uses.
Run `command` on the host that runs the hub, reading its stdin over SSH or an equivalent encrypted transport - the same open exposure decision the feed names, with a sharper edge, because this direction carries the credential that steers the fleet.

### Private host control routing

The same-origin, local-only UI adapter may call `bin/fm-ui-host-control.py` only after checking its per-launch browser-session authorization and authority for that exact action.
This executable is a host-side routing surface, not an HTTP endpoint or an authentication substitute.
The [host executable's header and help](../bin/fm-ui-host-control.py) own the operator-maintained 0600 binding registry, target resolution, supported verbs, payload fields, the read-only `targets` discovery schema, and retry limits.
The host resolves `(machine, label)` to an explicit `FM_HOME` and exact task or captain-call binding; neither the registry's home paths nor control-class credentials are supplied by or returned to the browser.
Invalid registry bindings refuse before dispatch.
Task lifecycle requests delegate to `bin/fm-control.sh` under the resolved home without bypassing its backlog eligibility, endpoint identity, or [remote lifecycle routing boundaries](remote-secondmates.md#lifecycle-control), and existing owner refusals such as endpoint retirement and stand-down stay authoritative.
The host adapter must keep backend credentials in host-only 0600 files and must never send them in page content, browser environment, or browser storage.
The browser never writes state directly, supplies an owner-home path, or invokes an owner command itself.

Decision actions carry the captain's exact answer to the existing send or captain-hold owner.
Owner success does not prove that a worker acted on its inbox answer, and owner errors remain pending rather than being misreported as proof that nothing changed.
`note` is only the supervisor-note path through `bin/fm-inbox.sh`, not a decision action, and a crew-owned `no-mistakes axi respond` is never invoked by this route.
A `deck chat` primary can run inside a stream endpoint through `bin/fm-deck-chat.sh --stream`; primary decision control needs an explicit captain-call binding under the primary owner's `FM_HOME`, and unregistered primaries are not adopted.
Task-key decisions use an exact task binding in their owning home, and notes-only, worker-only or unregistered primary bindings do not constitute primary lifecycle control.
[Primary sessions](agent-control.md#primary-sessions) own their own lifecycle; discovery alone does not implement primary controls.

The Bridge command plane is `steer` only.
The hub's separate endpoint-addressed commands (`input`, `kill`, `status`, and the native hub's `resize`) have no leaf binding, command-id replay, or late-result lookup, so this route does not expose them as composer kinds or claim the journal's guarantees for them.
Use guarded host lifecycle verbs for process control and supervisor notes for intent.

## Security

The hub binds `127.0.0.1` by default and every data route requires a bearer token; the static viewer page is the one exception.

Tokens are class-scoped, and there are three classes:

- `publish` registers endpoints and publishes frames; agents hold it, and nobody else needs it.
- `subscribe` reads only: list, stream, capture, screen, the native hub's snapshot, state, and the order journal.
- `control` steers: sending input to a worker, resizing its terminal on the native hub, appending a status line, closing an endpoint, and placing a leaf-addressed order.

A line of `<classes>:<token>` in `config/stream-hub-tokens` grants exactly the named classes, so an operator credential is written `subscribe,control:<token>` and a home's own client credential, which both publishes and steers, is `publish,subscribe,control:<token>`.
A bare token line grants `subscribe` alone, so the unqualified line is the read-only one.
A viewing token cannot register an endpoint, publish, or steer a worker: input, native resize, status, and close are all refused with 403.

Seeding a secondmate home mints that home its own token rather than copying the primary's, but only when the seeding home hosts the hub, which it signals by owning `config/stream-hub-tokens`.
`bin/fm-home-seed.sh` then appends one `publish,subscribe,control:<token>` line to that file and writes the fresh token into the mate home's own `config/stream-token` ([`bin/fm-stream-secondmate-credential-lib.sh`](../bin/fm-stream-secondmate-credential-lib.sh)).
A home seeded from a client home, whose `config/stream-hub` names a remote hub that seeding must not touch, gets no credential.
A seeded token is INACTIVE until the hub restarts: the hub reads its token file once at serve start, so the credential the mate presents is refused until then.
That restart is a planned quiet-boundary operation, not part of seeding, because it clears terminal scrollback and empties Bridge-order reconciliation ([When the hub restarts](#when-the-hub-restarts)), so it must not happen while an order is pending or may need a resend.
A supported token reload is separate queued work.
`tests/fm-secondmate-safety.test.sh` covers credential seeding.

Command retrieval and result submission additionally require the endpoint's private `command_capability`, established by registration and carried in the `X-Endpoint-Capability` request header.
A poll must name that endpoint; machine-wide command retrieval is refused.
A recovering agent presents its current capability when registering, and the hub adopts or retains that same value so retrying after a lost registration response is idempotent; closing the endpoint revokes it.
Agents retain the capability only in memory, and listings, state reads, logs, and status lines never expose it.
The Rust bridge is a read-only feed, not a command adapter.
The bundled viewer page is served without a credential, because it is static and the token it reads out of the URL fragment is what its own requests carry; every data route behind it is authenticated, and opening it with a viewing token gives a read-only view whose send box is refused.
The same-machine attach socket authenticates by filesystem isolation and peer uid rather than a token; [Interactive attach](#interactive-attach) owns its permission checks.
That uid already holds the agent's credentials and could drive its pseudoterminal directly.

### The hub speaks plain HTTP

The hub itself serves only plain HTTP, and nothing in it will warn you about that.

On any untunneled connection to the hub, every byte is in the clear: the bearer token on each request, every keystroke sent to a worker, and every byte of terminal output that worker produces.
Anyone who can read the path can read all of it; anyone who can read a `publish` token can register endpoints and publish forged frames for any of them, impersonating your workers, and anyone who can read a `control` token can type into those workers and close them.

Loopback is the only setting where that is safe on its own.
Cross-machine use means an SSH tunnel or an equivalent encrypted transport, which firstmate does not create, manage, or check for; a configured `https://` hub URL means only that something in front of the hub terminates TLS, not that the hub does.
Nothing binds a public interface on your behalf, so changing `--bind` is a deliberate act, and doing it without a tunnel publishes your fleet's terminals and their control channel to that network.

Terminal content is never written to disk.
Hub replay lives in each endpoint's bounded in-memory ring buffer, which exists so a late subscriber can catch up, and it is lost when the hub restarts.
The native agent also keeps a visible-screen model without scrollback and a bounded parser tail for local snapshots; neither is written to disk.

The status return channel writes on the machine that owns the endpoint.
A status line travels as a command to that endpoint's own agent, which appends it to the local `state/<id>.status`, so the record is written where it belongs and never crosses the network as a path.

## Closing an endpoint whose agent does not answer

Both PTY agents close an endpoint by signalling its terminal's foreground job before the shell's own process group, so a job-control worker that ignores SIGHUP is not left running with the PTY open.
After a bounded three-second grace period, close re-reads the foreground job before signalling it and the shell with SIGKILL, including a job that started during the grace period.
The signal ownership boundary is documented beside `foreground_group_locked` in [`crates/fm-stream-agent/src/pty.rs`](../crates/fm-stream-agent/src/pty.rs); it does not authorize signalling arbitrary background jobs or descendants after the shell has been reaped.
[Portable stream-parity regressions](verification/runtime-backends.md#portable-stream-parity-regressions) lists the foreground-job cleanup cases for both implementations.

`DELETE /v1/tasks/<id>` hands the kill to the endpoint's own agent and waits for it to acknowledge.
The answer carries `delivered`: true when that agent took the kill, and false when it never answered and the hub closed only its own record.
A `delivered: false` close is not proof the worker stopped, because its process lives on the worker's machine, which the hub cannot reach.
`fm_backend_stream_kill` refuses such a close, exits nonzero, and says the worker may still be running.
It answers the same way to every other refusal, including `no_such_endpoint`: a hub that has forgotten an endpoint says nothing about whether that worker is still running.

An endpoint carries `closed_by`: `agent` when its own agent reported the worker gone and brought its exit code back, and `hub` when the hub closed a record it could no longer steer.
Only `closed_by: agent` is a confirmed stop; a kill against such an endpoint reports success without asking again, while every other outcome, `closed_by: hub` included, reports an unconfirmed stop.
When an agent comes back and reports its own worker's exit, its report takes over a `hub` close, attribution and exit code together; a hub close never takes over an agent's and never overwrites the exit code an agent recorded.
`fm_backend_kill` in `bin/fm-backend.sh` owns that unconfirmed result, and cleanup keeps the task's durable records rather than recording a worker as gone that nothing has stopped.

## When the hub has not heard from an agent

After ten seconds of silence the hub presumes that endpoint's agent is gone; agents are heard from on every frame, every state heartbeat, and every command poll.
A presumption is not a close, and it does exactly one thing: it frees the endpoint's label, so a spawn abandoned mid-startup does not make its task id unusable.
The worker is still listed, its stream still runs, and input, status lines and kills still reach it, because a worker the hub has not heard from lately may be perfectly healthy.
A state read answers `unreadable` rather than `dead` for the same reason.
An endpoint its own agent closed still answers `dead`, however long ago it was recorded, while a record the hub closed by itself keeps reading `unreadable` until its own agent reports that worker's exit.
The agent's next word to the hub takes the presumption back.

Where two registrations answer to one machine and label, the hub settles the contest by which agent it has heard from, not by which record is newer.
An agent that loses stands down: it stops publishing state and taking commands, but it does NOT stop its worker, and when that worker exits it still closes its own record out.
Standing down protects work in progress, since a worker left unsupervised can be recovered while a worker killed by mistake cannot.
An agent that loses the name during its own startup, before the endpoint is ready, has no work to protect, so it stops its worker and closes its own record rather than leak a process nobody can find.
A close is always accepted, so no ordering of supersession and close leaves an open endpoint with no agent behind it.
A record nothing has been heard from for the full retention period (an hour) is dropped.
An agent that speaks again to find another endpoint already answering to its machine and label is refused, and it stands down rather than let two workers answer to one identity.

## When the hub restarts

Endpoints live in the hub's memory only, so a restarted hub refuses a running agent's next publish with `no_such_endpoint`.
For an ordinary same-protocol restart, the agent registers itself again on that refusal under the endpoint id it already held, so its metadata binding, steering and status channel keep meaning what they meant, and the worker returns to the listing and to steering without anyone touching its machine.
Every registration names protocol 3; an older running endpoint is refused with `protocol_mismatch`, so a wire-protocol upgrade requires restarting every endpoint with matching software.
The scrollback does not come back: output produced while the hub was gone is lost and the endpoint's buffer starts again from the reconnect.
A steer aimed at the instant between a worker being listed again and its next command poll can still be reported undelivered, and is delivered on the retry.

Absence from a restarted hub's task table is a statement about the hub's own memory, never about a process on another machine, which is why a kill against an endpoint the hub does not have reports an unconfirmed stop.
Inside the restart window something may start a fresh worker for the same task under the same name; a record the hub has never heard from takes no name from the agent that is publishing under it.
That protection covers only the gap between a replacement's registration and its first state frame; past it the recovering agent is refused, because two workers then really do answer to one name.

Readers wait one ordinary rejoin window before answering an unresolved Bridge order; if no endpoint appears, the order remains pending without a membership nack, and an identical resend can try placement again.
The cheap presence probe behind capture, current-path and endpoint-addressed input answers from the first reply and pays no rejoin wait.

The recovery-grade worker classifier waits its own bounded six-second window (`FM_BACKEND_STREAM_MISSING_GRACE_SECS` in `bin/backends/stream.sh`), after which it can report `missing` while a live agent remains in a longer backoff; that verdict produces no Bridge membership nack.
That window is derived from both ends, and both matter.
The lower bound is what it has to outlast, which is three terms, not one.
An agent discovers the hub forgot it only by publishing, and an idle worker publishes nothing but its state heartbeat, so the wait comes first: at shipped defaults every 5s (both agents' `--state-interval` default, capped by the hub's `state_max_age_secs`/3).
Then the frame build, which is not free - the agent inspects foreground processes and cwd before it posts anything, so a tenth of a second when the box is idle and appreciably more when it is not.
Then the 404 and the registration round trip it answers with.
The upper bound is what it has to fit inside.
Callers bound this classifier: `fm-fleet-snapshot.sh` gives 10s to a whole crew-state read (`FM_SNAPSHOT_CREW_STATE_TIMEOUT`), of which this probe is one part, so a torn-down endpoint has to reach `missing` well within that rather than timing the caller out and folding to `unknown`.
6s therefore clears the lower bound by well under a second at shipped defaults, and a box loaded enough to make the ps/lsof pair or the registration POST take that second over spends the window: the classifier then says `missing` about a worker that is healthy and rejoining, with the consequences spelled out below.
Widening is not available - the 10s caller bound leaves no room - so the constant stands at 6 and the thin margin is part of what it costs.

So what the window covers is precisely one case: a rejoin that succeeds on the first attempt the agent makes after a restart.
It does not cover a rejoin delayed behind a failed attempt.
An attempt that times out or meets a hub still coming up doubles that agent's re-registration backoff and pushes the next attempt out by it (both agents back off from 2s to 60s with jitter), which can be far longer than this window; the endpoint is then reported `missing` while its worker is healthy and still coming back.
That verdict is not retried into harmlessness later: `fm-watch.sh` treats `missing` like `dead` and escalates the pending steer, and `fm_task_inbox_due_action` stays quiet for an escalated record, so the steer leaves the delivery ladder rather than being rung again.
Widening the window to cover the backoff ladder is not available here - it would blow the 10s caller bound above - so that cost is real and stands.

Only `no_such_endpoint` from the hub triggers re-registration; a failed connection never does, because a hub on its way back up may still hold the record.
An idle endpoint finds out on its state heartbeat rather than waiting for its worker to print something.
Attempts are paced, backed off, and jittered so the fleet does not return in one burst, and a successful registration resets the pacing.
A worker whose process ended while the hub was down is recovered the same way, so its closing frame and exit code land under the id that names them; the closing frame gets one unpaced attempt, and an agent whose hub is still down then exits.
A refusal other than a lost name, including a refused credential after a hub came back with the wrong token file, is waited out on the same backoff as an unreachable hub rather than treated as settled.
In every case the worker itself is left running and untouched.

## Retiring a record no backend can answer for

Cleanup removes a task's durable records only once a backend has proved the worker stopped, and `--force` does not lift that: it authorizes discarding unlanded WORK, never asserting a stop nobody observed.
A hub restart can leave records in exactly that state, where the hub has never heard of the endpoint and no later read can change the unconfirmed answer, so cleanup refuses every time.

`bin/fm-retire-endpoint.sh <task-id> [<task-id>...]` is the one way such a record is retired.
No daemon invokes it; in operator mode it names each id exactly, refuses wildcards and all-records forms, and asks you to type those ids back before anything is written.
By naming a record you assert, from your own inspection of the machine that ran it, that no worker is still running behind it.
Every record-retirement attempt first appends one line to `state/endpoint-retirements.log` with your username, the time, and the id; an attempt whose line cannot be appended retires nothing, and the line records the assertion, not an outcome.

What operator mode touches, and what it does not:

- It retires RECORDS: the durable task record and, where firstmate owns the transition, the task's backlog row.
  A manually kept backlog, or a home with no backlog file, is left exactly as the operator keeps it.
- Cleanup runs first and finishes the job properly whenever its own gates allow.
  When cleanup's work-protection gate refuses, the worktree, any uncommitted work in it, the task branch and the task's data are left byte-untouched and named in the output, for you to deal with under your own authority.
  It never discards work and never passes `--force` to anything.
- When cleanup's unconfirmed-kill gate refuses, the records are retired anyway on your assertion alone, even for an endpoint the backend still reports present after its kill.
  Cleanup cannot tell which case you are in, so a worker may still be running behind a record retired that way, and stopping it is yours to do.
- Every other cleanup refusal stands and nothing is retired, such as an outcome that has not reached the parent channel or a backlog transition that cannot be replayed.
  A cleanup that fails only after it has already removed the durable task record reports that partial state instead of claiming nothing was retired.

Records left on the removed tmux and herdr backends, including any record with no `backend=` field, read as `unverified` to recovery and as gone to presence checks, cannot be relaunched, and reach cleanup as an unconfirmed kill.
Stop any process still behind one by hand, then retire it with this command.

The owning mate retires its own finished work on those backends under the captain's standing instruction through [`task-delivery`'s finished-work sweep](../.agents/skills/task-delivery/SKILL.md#finished-work-sweep); [`fm-retire-endpoint.sh`'s header and `--help`](../bin/fm-retire-endpoint.sh) own the narrower `--finished` checks and assertion basis.
When tmux is installed, that mode accepts a tmux record only when a local tmux server can be read and does not list its window, or tmux definitively reports that no server is running; any other inventory failure goes to the captain rather than authorizing cleanup.

The opposite leftover is a stream endpoint the hub still lists live after its task record is gone, for example when a captain decision removed the record.
`FM_HOME=<home> bin/fm-retire-endpoint.sh --orphan <task-id> [--endpoint <endpoint-id>]` closes it, and `--list-orphans` lists that home's candidates read-only; for a remote home, run it through `bin/fm-on.sh <secondmate> fm-retire-endpoint.sh --orphan <task-id>`.
[`fm-retire-orphan-lib.sh`'s header](../bin/fm-retire-orphan-lib.sh) owns the endpoint-bound ownership proof, stopped-or-idle and work-protection checks, assertion logging, and the remaining check-to-kill race; [`fm-retire-endpoint.sh --help`](../bin/fm-retire-endpoint.sh) owns invocation mechanics and the read-only listing's limits.
Closing leaves task files, worktrees, branches and backlog rows untouched; only the assertion log and locking records are written.

## When the hub is down

One hub means one blast radius.
The hub owns no pseudoterminal, so it cannot take a worker with it.
While it is down, unreachable, or restarting:

- Every worker keeps running, and keeps producing output into the pty its own agent holds.
- Hub-backed watching, new steering, capture, and kill requests are unavailable.
  Same-machine interactive attach has its own local transport ([Interactive attach](#interactive-attach)), but it does not restore fleet-wide supervision.
  Already-reserved native Deck orders continue local reconciliation under the [Command path](#command-path) contract.
- Every endpoint reads stale, which is `unreadable`, never `dead`.
  Supervision must not treat that as evidence a worker died, because it is evidence of nothing at all.
- Status lines keep working, because each agent writes them on its own machine.

A hub that was merely unreachable comes back to the same endpoints, and agents pick up where they left off.
A hub that RESTARTED comes back to none, and each agent registers its own endpoint again; [When the hub restarts](#when-the-hub-restarts) owns what that recovers.
Either way the terminal output produced in the meantime is gone.
Losing the hub costs centralized observation across the whole fleet at once, but does not stop the worker processes.

## Limits

- Scrollback is bounded by the ring buffer, so it is a live window, not a transcript.
- An unreachable agent and a dead worker are indistinguishable from the hub, so a stale read carries no liveness verdict at all.
  Only one of those two states authorizes recovery, and reporting silence as death is how a healthy worker gets torn down.
- The hub is a single point of observation, not of execution; [When the hub is down](#when-the-hub-is-down) owns that contract.
- The hub token file is read only at start, so adding or revoking a credential costs a hub restart.
- Experimental; CI's Rust agent parity step exercises disposable Python hubs and real PTYs, not installed harnesses.
  Native Deck steering has its own live guard, recorded in the [Deck native mid-turn verification record](verification/runtime-backends.md#deck-native-mid-turn-steering-over-stream).
  The portable regressions are `tests/fm-stream-hub.test.sh`, `tests/fm-backend-stream.test.sh`, `tests/fm-stream-agent-kill-safety.test.sh`, and `tests/fm-stream-bridge.test.sh`; `tests/fm-ui-host-control.test.sh` and `tests/fm-control.test.sh` cover the private host route.
