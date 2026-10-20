# Runtime backend verification

Audience: maintainer verification.

This record contains reusable version-scoped evidence for active runtime guarantees.
Stream is the only runtime backend and Deck the only harness, so every section below is Deck or stream evidence.
[`stream-backend.md`](../stream-backend.md) owns current setup, safety boundaries, and limitations.
Exact task chronology, branch names, temporary homes, local paths, process ids, thread ids, and delivery transcripts remain in private reports or PR evidence.

## Harness detection

Deck is the only harness, and `bin/fm-harness.sh` reads it from process ancestry alone: a deck host (`fm-deck-chat`, `fm-deck-worker`) or `deck` itself in the parent chain resolves `deck`, and anything else resolves `unknown`.
Environment markers left by removed harnesses are ignored.
The portable regression builds every case from real renamed processes and no installed harness:

```sh
bin/fm-test-run.sh tests/fm-harness-precedence.test.sh
```

## Specialist first-failure barrier

The [`fm-specialist.sh` header](../../bin/fm-specialist.sh) owns the opt-in failure contract; [`fm_crew.py`](../../bin/fm_crew.py) owns classification and latching.
On 2026-10-20, the loopback scripted-provider guard ran the real Deck executable on macOS without remote model calls, live jobs, or runtime installation.
Tested identity: `deck 0.1.0`, SHA-256 `841b3027311747130fc12e4c0a1929874a5e3f051612fd909120fc0aa6176363`.
The guard refuses a different fingerprint unless `FM_SPECIALIST_DECK_SHA256` explicitly pins the replacement; changing the pin requires refreshed evidence here.
The source behavior corresponds to Deck source `1408131827804535268d5621c217453f234ea7f2` (stored-output envelopes and rendered command status), but this is not a verified source-to-binary build receipt or historical executable attribution.
The hook receives presentation text rather than authoritative raw truncation metadata; exact synthetic copies of producer envelopes remain indistinguishable from real envelopes.

Refresh with:

```sh
FM_SPECIALIST_DECK_LIVE=1 bin/fm-test-run.sh tests/fm-specialist-deck-live-e2e.test.sh
FM_LIVE=0 bin/fm-test-run.sh tests/fm-specialist.test.sh
```

The real guard emitted the following for each of `stored-read`, `hard-read`, and `large-nonzero`:

```text
first cause retained; one tool executed; queued/later calls refused; input/memory unchanged; no completion injection; failed owner result
ok - pinned Deck stops queued and later calls after actual incomplete output
```

It exercises a second same-batch command at concurrency one and a later memory-write request, verifies refusal results and unchanged fixture bytes, and checks failed record/history plus the owner-generated stopped result.
The hard-read case also checks that the retained stored output contains the read tool's own hard-cut marker, independently of the outer preview.
Portable positive/negative fixtures cover clean reads and commands, native errors, JSON and rendered nonzero/null/timeout statuses, saved status as read content, literal historical markers, malformed envelope geometry, UTF-8 cuts, stored previews and hard truncation.
These checks establish the tested presentation boundary, not arbitrary semantic API failure detection or permission to resume monitoring.

## Composer classification

The shared composer classifier (`bin/fm-composer-lib.sh`, `fm_composer_classify_screen`) owns every composer shape; the stream adapter contributes only a capture and a capability descriptor.
`tests/fm-composer-lib.test.sh` pins the retained shapes portably from captured samples, including Grok's three-column titled-bottom-border overhang and Codex 0.154's idle braille starfield.
Those samples were captured live from harnesses that are no longer supported, so they establish only the measured renderings, and no live composer run against a Deck worker over stream is recorded here.

## stream

### Watcher publication and startup refusal boundaries

Verified on 2026-10-19 on Linux with Bash 5.3.9 and Python 3.14.4 using the real home-host driver, synthetic startup/watcher/Deck executables, and a separate process owning the real sequence-lock primitive, without model calls.
The current regression entry point is:

```sh
FM_LIVE=0 FM_TEST_DECK_CASES='test_secondmate_host_refuses_an_incomplete_startup_digest test_secondmate_host_retries_watcher_publication' bin/fm-test-run.sh tests/fm-deck-harness.test.sh tests/fm-task-inbox.test.sh
```

Recorded output:

```text
ok - Deck host refuses a zero-exit incomplete digest without consuming wakes or starting turns
ok - Deck host replays accepted publications once, separates equal wakes, preserves lock custody, and honors queued exits
```

The contention fixture holds the lock through an initial enqueue refusal, verifies the same live owner remains, then releases through that owner and observes one handled record and one wake turn.
The exhaustion control keeps the owner alive, observes no publication or wake turn, and retains the unacknowledged durable wake.
The current publication case also asserts no duplicate record or turn after a real numeric inbox rename followed by an error return, separate delivery for distinct watcher events with equal output, and no re-enqueue after post-acceptance doorbell failure.
It checks queued exit during backoff and after acceptance, preserving any accepted record unhandled, and the first-line identity of the serialized publication body.
The startup control returns an incomplete report with exit zero and a stale completion marker; no model turn or watcher starts.
[`fm-deck-worker.sh`](../../bin/fm-deck-worker.sh)'s header owns retry behavior and startup safety; [`tests/fm-control-relaunch.test.sh`](../../tests/fm-control-relaunch.test.sh) separately exercises five readable child records, empty state, invalid child entries, read failure, and traversal failure diagnostics before any stop.
These are portable driver and subprocess-boundary fixtures, not a live Deck or macOS incident reproduction.
The original traversal failure and sequence-lock owner remain unknown.
They do not establish the cause of any particular refusal or startup timeout.

### Secondmate home-local tool selection

#### Portable plumbing evidence

Verified on 2026-10-19 on macOS with Bash 3.2 and Python 3.9.6 using the real Deck home-host driver, a shimmed session-start script, and synthetic Node and quota-axi executables, without model calls:

```sh
FM_LIVE=0 FM_TEST_DECK_CASES=test_secondmate_tool_path_reaches_startup_without_changing_siblings bin/fm-test-run.sh tests/fm-deck-harness.test.sh
```

```text
PASS fresh host startup executes selected Node/npm CLI and compatibility helper; sibling, empty/absent, invalid and ship scopes preserved
ok - Deck home-local tool path reaches startup without changing sibling/default launches
```

The startup fixture executes `node`, an env-node `quota-axi`, and the real bootstrap compatibility helper before the first model turn.
The same regression fails against the unchanged driver because startup resolves the default tools instead of the explicit home selection.
[`tests/fm-backend-stream.test.sh`](../../tests/fm-backend-stream.test.sh) additionally exercises tool execution during startup through `fm-spawn.sh`, a real loopback hub, and a real PTY agent.
Both supported stream implementations invoke the same home-host driver; these portable checks do not establish activation or tool selection in any existing remote home.
[`fm-deck-worker.sh`](../../bin/fm-deck-worker.sh)'s header owns the explicit grant and activation contract.

#### Remaining destination authority decision

The launch blocker remains open.
The supplied tool-owner evidence establishes command-scoped compatibility/bootstrap for the validated candidate; the destination-home report still shows the old tools on a fresh launch.
Neither is proof that this repair selects the candidate in that home, and no fresh actual destination launch/bootstrap was performed here.

Does the destination owner authorize configuring **only the selected home's** `config/secondmate-tool-path` with the existing validated tool directories and coordinating a fresh launch through the supported route?
The decision must cover both the home-local grant and the relaunch window.
Until that authority is explicit, leave the destination configuration and running home untouched.
Code delivery and passing plumbing tests aren't activation authority.

After approval, the destination owner must retain fresh-launch evidence showing the actual Node and quota-axi versions and successful startup/bootstrap, with the corporate proxy unchanged and sibling homes unaffected.
Reuse the existing tool-owner validation rather than repeating it; a one-command PATH override doesn't close this gap.
No global/default Node, shellwide PATH, service, registry, or credential changes are authorized.
Keep destination identifiers, tool-directory paths, and raw launch evidence in private owner reports; publish only sanitized results.

### Deck native mid-turn steering over stream

The initial same-turn correction check was verified on 2026-09-29 on macOS with Python 3.9.6 and Deck 0.1.0 built from the merged native-steering interface in `bastotec/deck`.
The isolated live guard exercised the real Bridge command adapter, authenticated loopback hub, PTY agent, Deck driver, and model turn; `bin/fm_stream_deck.py` owns the receiver mechanics.
Run the guard with a Deck build whose `run --help` advertises `--steer-dir`:

```sh
FM_DECK_LIVE=1 bin/fm-test-run.sh tests/fm-stream-deck-live-e2e.test.sh
```

`FM_DECK_LIVE_BINARY` selects a non-default Deck build for the same guard; the version string alone is insufficient because builds reporting `deck 0.1.0` can lack `--steer-dir`.
The guard inherits gateway configuration by reference and isolates Deck state and all hub, agent, and worker records in its test lab.
The current guard extends that check through eight live receiver scenarios: original-turn reservation and duplicate reconciliation, storage-failure recovery without successor delivery, delayed destructive takes, independent result-post retries, byte-exact CRLF/carriage-return/Unicode persistence, retained-agent compatibility with native-only size limits, Bridge course correction with unchanged turn evidence, and idle captain delivery with an untouched human draft plus both Bridge/captain publication interleavings.
Measured on 2026-10-11 on macOS with Python 3.9.6, the Python agent 2.1.0, and Deck 0.1.0 supporting `--steer-dir`, the command above passed all eight scenarios, including an apostrophe-containing inbox path, ordered F/G/H/I application at safe points, preservation of human composer text, and no extra turn after source acknowledgement.
It emits per-scenario JSON evidence before this success marker:

```text
PASS all eight native live receiver scenarios
```

The guard can select a separately built native agent without installing it:

```sh
FM_STREAM_AGENT_LIVE_BINARY="$PWD/target/debug/fm-stream-agent" FM_DECK_LIVE=1 bin/fm-test-run.sh tests/fm-stream-deck-live-e2e.test.sh
```

On 2026-10-11, Rust agent 2.1.0 built locally with Rust 1.96.0 passed the portable Rust/Python lifecycle parity guard and all 47 agent unit tests.
The corrected driver and native receiver also passed all eight real Deck scenarios on that date, including idle human-draft preservation, ordered F/G/H/I safe-point application and no extra apostrophe-path acknowledgement turn.
The portable application regressions run with `bin/fm-test-run.sh tests/fm-stream-deck.test.sh`, including oversized captain fallback followed by eligible native sources through both publication paths.
The native receiver's corresponding regression is `newer_bridge_order_skips_native_ineligible_captain_sources` in [`crates/fm-stream-agent/src/receiver.rs`](../../crates/fm-stream-agent/src/receiver.rs).
The same portable suite checks prompt successful handoff under a held lifecycle lock, privacy-safe phase diagnostics, and later driver publication of the intact source without acknowledgement.
Current operator behavior and supported limits are owned by [`../stream-backend.md`](../stream-backend.md#command-path).

### Interactive attach latency

[`stream-attach-bench.py`](../../tests/assets/stream-attach-bench.py) measures keystroke echo and full-redraw delivery through a real attach PTY, using a disposable native endpoint that writes a known colored frame in one write.
Its docstring owns the benchmark options and metric definitions.
Run against each separately built native binary directory to compare the baseline hub path, the updated hub path, and the same-machine path:

```sh
python3 tests/assets/stream-attach-bench.py /path/to/baseline-native --path hub --rtt-ms 10 --rows 200 --cols 120
python3 tests/assets/stream-attach-bench.py /path/to/updated-native --path hub --rtt-ms 10 --rows 200 --cols 120
FM_STREAM_ATTACH_LOCAL=1 python3 tests/assets/stream-attach-bench.py /path/to/updated-native --path auto --rtt-ms 10 --rows 200 --cols 120
```

For the `auto` run, ensure the agent offers its private socket and both processes resolve the same directory; `auto` permits hub fallback and is not by itself proof of local transport.
[The stream guide](../stream-backend.md#interactive-attach) owns that selection and its safety checks.
Redraw spread measures first-to-last byte arrival at the attach PTY, not a terminal emulator's actual display refresh.
Retain the full JSON, run date, host/tool versions, and binary revisions in PR evidence when refreshing the comparison.

Recorded rounded macOS observations with a 10 ms simulated hub round trip and a roughly 26 KB, 200-line frame:

| Path | Median echo | Redraw paint spread | Redraw to last byte |
| --- | --- | --- | --- |
| Baseline hub | 52 ms | 442 ms | 558 ms |
| Updated hub | 35 ms | 1 ms | 46 ms |
| Same-machine socket | 3 ms | Not recorded | 9 ms |

These observations were supplied without a run date, tool versions, binary revisions, or raw JSON, so they are indicative comparisons rather than version-scoped verification or a guaranteed latency budget.
`tests/fm-stream-attach-rust.test.sh` is the functional regression entry point for snapshot, input, resize, detach, and exit-status behavior over both transports; it is not a timing assertion.
`tests/fm-stream-attach-boundaries.test.sh` adds public socket/HTTP/PTY regressions for supported large startup geometry, geometry publication failure, prompt saturated-resize refusal and recovery, local/hub input serialization, and bounded Ctrl-] detach under socket backpressure.
The `fm-stream-agent` unit tests in `crates/fm-stream-agent/src/attach.rs` cover full-queue drain acknowledgement and concurrent input admission versus signal detach; `saturated_resize_refuses_without_publishing_or_changing_geometry` in `crates/fm-stream-agent/src/main.rs` covers saturation refusal through both resize entry points.
These are regression entry points, not a recorded run or production latency guarantee.

### Portable stream-parity regressions

[`tests/fixtures.sh`](../../tests/fixtures.sh)'s `fm_test_fake_stream` supplies fake fleet endpoints to the real adapter; its header owns setup and helper usage, and [`stream-hub-stub.py`](../../tests/assets/stream-hub-stub.py)'s docstring owns fake-shell behavior.
`tests/fm-test-fixtures.test.sh`, `tests/fm-backend.test.sh`, `tests/fm-send-strict.test.sh`, and `tests/fm-crew-state.test.sh` exercise fixture round trips, spawn metadata, unrecorded explicit-target routing, and busy/idle/missing/unreachable crew reads, including busy and idle status preservation when capture fails but the process remains alive.
`test_fake_stream_owner_boundary` in `tests/fm-test-fixtures.test.sh` exercises the stub's authorization boundary and observes executed curl arguments; `test_owner_credential_survives_isolation_without_argv_exposure` in `tests/fm-stow-cascade.test.sh` observes executed env arguments and verifies authenticated access from the isolated child.
`tests/fm-control-recover-missing.test.sh` covers new-endpoint rebinding, refusal for a local agent with the task's label and owning status path, preservation of unrelated agents, and confirmed versus unconfirmed cleanup after a failed rebind.
`tests/fm-backend.test.sh` keeps confirmed-gone, still-present, unconfirmed, and unsupported kill verdicts distinct, while `tests/fm-backend-stream.test.sh` distinguishes a hub-answer its agent never acknowledged from a hub that has no endpoint record.
`tests/fm-endpoint-rebind-lib.test.sh` pins endpoint-only record replacement and identity refusals, and `tests/fm-teardown-endpoint-safety.test.sh` pins retired-record cleanup identity, preservation of the still-present verdict after a hub-only close, and the runtime-refusal override it requires.
`tests/fm-teardown.test.sh` pins validation-run conclusion before ordinary endpoint closure, preservation of that endpoint when a parked run's abort remains unconfirmed, and closure before cwd-based process reaping, so endpoint-owned machinery is not reported as leaked while disowned worktree and tasktmp descendants remain reapable.
`tests/fm-backlog-atomicity.test.sh` covers operator retirement and the owning mate's finished-work retirement, including the same override boundary, refusal for unlanded work, unreadable tmux inventory, retention of finished-work retirement authorization through process cleanup, and preservation of a non-replayable pending close after a later reaper refusal.
These fake-fleet cases prove integration routing, not real PTY behavior or installed-harness identity.
The local-PID regression in `tests/fm-backend-stream.test.sh` instead runs the real Python hub and agent with a harness-named stand-in process, checks that its reported PID exists locally, and refuses other-machine and unknown-endpoint PID reads.
`tests/fm-stream-agent-kill-safety.test.sh` exercises Python foreground-job cleanup, and the Rust PTY tests `foreground_job_dies_with_its_endpoint`, `foreground_pipeline_dies_with_its_endpoint`, and `foreground_job_started_during_close_dies` in `crates/fm-stream-agent/src/pty.rs` cover the corresponding native cases.
Each implementation tests a SIGHUP-ignoring job, a pipeline whose group leader can exit before close, and a TERM-ignoring job started during the grace period, checking that no process remains in the job's group after close.
The cases drain the PTY during close as the production reader does, because an exiting shell can wait on undrained terminal output.

### Rust hub isolated compatibility

Measured 2026-10-01 on macOS with Rust 1.96.0 and Python 3.9.6 against Hub 2.0.0, protocol 3.
The Rust binary was a debug build; these single-run observations describe an isolated loopback pilot, not a production capacity guarantee or target budget.
The driver measures ready-file startup, `ps -o rss=` resident KiB before frame traffic, and 100 sequential 4096-byte published frames through the HTTP and screen-rendering path.

```sh
bash tests/fm-stream-hub-rust.test.sh
cargo +stable fmt --all --check
cargo +stable clippy -p fm-stream-hub --all-targets --no-deps -- -D warnings
cargo +stable test --workspace --locked
```

Observed parity output:

```text
differential: 165 HTTP/stream observations and Python agent/bridge lifecycle match
measurements: {"python": {"frame_mib_per_second": 0.53, "rss_kib": 22464, "startup_ms": 95.88}, "rust": {"frame_mib_per_second": 0.46, "rss_kib": 5856, "startup_ms": 16.87}}
ok - Rust hub: HTTP, stream, order and Python peer compatibility
```

The hub crate's tests cover expiry boundaries, capability revocation, authoritative close preservation, late-result uncertainty, and an active order whose id is evicted from the bounded journal.
`crates/fm-stream-hub/tests/cli.rs` covers executable-level JSON compatibility, allocation refusals, terminal parameters, live SSE output, and request liveness with idle command polls.
Its deep-command regression checks byte-exact payloads through 200,000 nested arrays, overwritten duplicate-key values, malformed nested-body refusal, and subsequent health/task reads.
`tests/assets/stream-hub-differential.py` checks forwarded command bytes for non-finite numbers, lone surrogates, and deeply nested composites against the Python hub, including `POST status` with `note=[NaN, "\ud800"]`; its Python-peer case also compares the resulting durable status bytes.
The HTTP regressions in `crates/fm-stream-hub/src/main.rs` cover deletion across reap/re-registration and SSE endpoint-incarnation binding.
The differential driver's terminal cases compare Unicode width, ANSI rendering, oversized CSI integers, and OSC/DCS boundaries against the Python reference.
Its native-steering cases compare execution/order-bound `steer` command payloads, refusal without a receiver, and refusal when re-registration changes receiver capabilities.
The existing bridge suite also passes with `FM_TEST_STREAM_HUB_BINARY="$PWD/target/debug/fm-stream-hub" bin/fm-test-run.sh tests/fm-stream-bridge.test.sh`.
A complete hub-suite invocation on this host stops at the existing shell-died-at-birth refusal case documented below, after the earlier HTTP/body, stream, capture, registry, and state-read cases pass against Rust.
The backend suite no longer requires a `setsid` executable; see [the stream prerequisites](../stream-backend.md#prerequisites) for the fallback dependency.
This is not a claim that every stream suite passes on macOS: the existing Rust-bridge HTTPS fixture cannot validate its generated certificate with this host's Python trust store.
The replacement prerequisites are owned by [the stream guide](../stream-backend.md#rust-hub).

### Deck home-host lifecycle

Measured 2026-09-24 on macOS with Bash 3.2.57 and Python 3.14.2 using the portable fixtures, not live model calls.
`FM_LIVE=0 bin/fm-test-run.sh tests/fm-deck-harness.test.sh` exercises the real Deck driver against a shimmed Deck binary; its native PTY regression reports:

```text
ok - Deck idle Ctrl+C stays a signal, not fake input, while partial input remains visible
```

`PATH="<setsid-shim-dir>:$PATH" SHELL=/bin/bash FM_LIVE=0 bin/fm-test-run.sh tests/fm-backend-stream.test.sh` exercises the shared driver, lifecycle control, and durable inbox through the real Python hub and agent.
This host lacks a native `setsid` executable, so the shim performs Python `os.setsid()` followed by `os.execvp()`; native `setsid` and live Deck model calls are not proven by this run.
The lifecycle case reports:

```text
ok - stream: idle Deck exits; genuine pending text refuses without stopping the host
ok - stream: Deck launch, alive classification, durable steering, exit, relaunch and recovery
ok - stream: a restarted hub's registry gap licenses no secondmate respawn
ok - stream: Deck interrupt preserves a usable idle composer for exit
```

This is targeted lifecycle evidence, not a claim that the complete stream suite passes: in that run every other case passed except the existing shell-died-at-birth refusal case, which also fails on the unchanged default branch in this environment.
`tests/fm-stream-agent-kill-safety.test.sh` additionally exercises child SIGINT handling under default and ignored parent dispositions, proving that the child normalization leaves the parent unchanged.

### Partition reads unreadable, never dead

The owning agent reads its own pseudoterminal's foreground process group and publishes it to the hub over HTTP, and the liveness classifier reads that published record.
A silenced publisher must read `unreadable`, never `dead`, because a `dead` would authorize tearing down a healthy worker that was merely unreachable.
`test_agent_state_separates_missing_unreachable_and_partitioned` in `tests/fm-backend-stream.test.sh` pins this with the real Python hub and agent: it kills only the publishing agent and requires `unreadable`, and it requires `unreadable` again once the hub itself is gone.
The live guard that checked the same verdict against installed harnesses, `tests/fm-stream-agent-live-e2e.test.sh`, was removed with the Pi harness, and its recorded evidence covered only harnesses that are no longer supported.
No live run of this verdict against a real Deck worker is recorded here.
