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

## Composer classification

The shared composer classifier (`bin/fm-composer-lib.sh`, `fm_composer_classify_screen`) owns every composer shape; the stream adapter contributes only a capture and a capability descriptor.
`tests/fm-composer-lib.test.sh` pins the retained shapes portably from captured samples, including Grok's three-column titled-bottom-border overhang and Codex 0.154's idle braille starfield.
Those samples were captured live from harnesses that are no longer supported, so they establish only the measured renderings, and no live composer run against a Deck worker over stream is recorded here.

## stream

### Deck native mid-turn steering over stream

The initial same-turn correction check was verified on 2026-09-29 on macOS with Python 3.9.6 and Deck 0.1.0 built from the merged native-steering interface in `bastotec/deck`.
The isolated live guard exercised the real Bridge command adapter, authenticated loopback hub, PTY agent, Deck driver, and model turn; `bin/fm_stream_deck.py` owns the receiver mechanics.
Run the guard with a Deck build whose `run --help` advertises `--steer-dir`:

```sh
FM_DECK_LIVE=1 bin/fm-test-run.sh tests/fm-stream-deck-live-e2e.test.sh
```

`FM_DECK_LIVE_BINARY` selects a non-default Deck build for the same guard; the version string alone is insufficient because builds reporting `deck 0.1.0` can lack `--steer-dir`.
The guard inherits gateway configuration by reference and isolates Deck state and all hub, agent, and worker records in its test lab.
The current guard extends that check through seven live receiver scenarios: original-turn reservation and duplicate reconciliation, storage-failure recovery without successor delivery, delayed destructive takes, independent result-post retries, byte-exact CRLF/carriage-return/Unicode persistence, retained-agent compatibility with native-only size limits, and Bridge course correction with unchanged turn evidence.
It emits per-scenario JSON evidence before this success marker:

```text
PASS all seven native live receiver scenarios
```

The portable application regressions run with `bin/fm-test-run.sh tests/fm-stream-deck.test.sh`.
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
`tests/fm-endpoint-rebind-lib.test.sh` pins endpoint-only record replacement and identity refusals; `tests/fm-teardown-endpoint-safety.test.sh` pins retired-record cleanup identity, and `tests/fm-backlog-atomicity.test.sh` covers operator retirement and the owning mate's finished-work retirement, including refusal for unlanded work and unreadable tmux inventory.
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
