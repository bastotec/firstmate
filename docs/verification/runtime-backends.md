# Runtime backend verification

Audience: maintainer verification.

This record contains reusable version-scoped evidence for active runtime guarantees.
The backend guides own current setup, safety boundaries, and limitations.
Exact task chronology, branch names, temporary homes, local paths, process ids, thread ids, and delivery transcripts remain in private reports or PR evidence.

## Harness detection

Deck is the only harness, and `bin/fm-harness.sh` reads it from process ancestry alone: a deck host (`fm-deck-chat`, `fm-deck-worker`) or `deck` itself in the parent chain resolves `deck`, and anything else resolves `unknown`.
Environment markers left by removed harnesses are ignored.
The portable regression builds every case from real renamed processes and no installed harness:

```sh
bin/fm-test-run.sh tests/fm-harness-precedence.test.sh
```

## Composer classification matrix

The shared composer classifier (`bin/fm-composer-lib.sh`, `fm_composer_classify_screen`) owns every composer shape fleet-wide; each backend contributes only a capture and a capability descriptor.
The live half of that guarantee was verified on 2026-08-10 from an already-trusted checkout at the branch's final validated head, against every installed harness then covered by the empty-composer matrix on tmux 3.6a, macOS arm64, on an isolated private socket, with no prompt submitted to any harness.
An earlier untrusted-worktree run left Claude, Grok, and Muse unverified because the guard treats first-launch trust dialogs as an unreadable-composer state and never confirms them; this trusted-checkout rerun supersedes those missing results.

```sh
FM_COMPOSER_MATRIX_LIVE=1 tests/fm-composer-matrix-live-e2e.test.sh
```

Observed output:

```text
ok - claude (2.1.227 (Claude Code)): real idle composer classifies empty
ok - codex (codex-cli 0.146.0): real idle composer classifies empty
ok - opencode (1.14.46): real idle composer classifies empty
ok - grok (grok 1.0.0 (3cd0d0cbcebe)): real idle composer classifies empty
# harness absent, not verified here: kimi
ok - muse (Muse Code 0.1.0 (0.1.0-R708.1)): real idle composer classifies empty
ok - strict posture live: a blank shell row classifies unknown and injection defers
ok - zellij (zellij 0.44.0): unrelated pane change never confirms delivery (verdict: unknown)
ok - live composer-matrix guard verified 8 live surface(s)
```

The retained real idle-composer samples reached a proven `empty` (Claude auto-updated to 2.1.227 between the audit and this rerun), including Grok through the titled-bottom-border tolerance and OpenCode through the left-bar shape; Codex and OpenCode first parked on vendor update-available modals that the strict classifier correctly refused until the guard's single non-submitting Escape dismissed them.
The strict blank-row posture held live (a blank shell row deferred injection), and a zellij pane changing for reasons unrelated to submission never confirmed a delivery, replacing the retired content-diff heuristic's false positive.
Kimi was not installed on the verification machine; its bordered shape was covered by the then-current portable byte-capture regressions, which were removed with the Kimi worker adapter.
The live matrix guard was also removed, so this table and its command are dated evidence, not refresh instructions; `tests/fm-composer-lib.test.sh` still pins the retained shapes portably.
The 2026-08-23 steering-inbox doorbell run observed grok 1.0.5's idle composer classifying `unknown` (and sometimes pending-family), never `empty`.
Issue #3436's recorded idle capture reproduced the cause on 2026-09-14: Grok 1.0.5 renders the titled bottom border three columns wider than its aligned top and content rows, so the cursorless Herdr profile rejected the otherwise complete box as ambiguous.
The classifier now accepts only that exact three-column overhang (`FM_COMPOSER_GROK_TITLE_OVERHANG` in `bin/fm-composer-lib.sh`) carrying a typed `Grok <model> (<effort>)` title; `tests/fm-composer-lib.test.sh` feeds the retained capture through the shared styled, cursorless capability profile and proves idle is `empty`, typed content is `pending`, and an unrecognized oversized title remains `unknown`.
The 2026-09-14 change was not live-verified against Grok; the retired matrix command cannot refresh it, so the retained capture establishes only the measured rendering, not later releases.
This closes only #3436's idle-composer-misclassification symptom (Grok/Herdr composer read `unknown` instead of `empty`, blocking away-mode injection). The issue's second symptom - a leftover watcher never yielding and never being taken over or refused at AFK start - is unrelated to composer classification and is tracked separately in #2270, where #3436's reproduction serves as corroborating evidence.


`zellij action dump-screen --pane-id <id> --ansi` was verified at zellij 0.44.0 to preserve ANSI styling (real Claude Code rendered inside a zellij pane dumped `ESC[m` `❯` U+00A0 for its idle composer row), which was the capability the former zellij composer classifier read.

### 2026-09-15 codex-cli 0.154.0 idle starfield and status footer through Herdr

Verified on 2026-09-15 on macOS arm64 (Darwin 25.5.0) against codex-cli 0.154.0 (model gpt-6-astra, fast mode) running as a Codex second mate inside a Herdr pane, read through Herdr's ANSI capture with its exact capability descriptor (`styled=1`, `cursor=0`, `identity=1`, `rows=20`).
Idle, codex 0.154 animates a braille starfield on the row above its bold `›` prompt row, on the `›` row behind the SGR-2 dim `Ask Codex to do anything` placeholder, and on the row below it, then draws a status footer reading `gpt-6-astra high fast · ~/Projects/purser · Launch Purser desk brief`.
The starfield cells are truecolor greys whose luminance runs from roughly 66 to 165, so the cells above the 128 ghost ceiling survive ghost stripping, and the footer is bright, non-blank, and carries no structural edge.

The capture is a read-only `herdr pane read <pane> --format ansi` of the live pane; its 20-row tail is fed to the shared classifier with the descriptor above:

```sh
herdr pane read w4Z:p2 --format ansi > codex-0.154-idle-herdr.ansi
bash -c '. bin/fm-composer-lib.sh
  caps=$(printf "styled=1\ncursor=0\nidentity=1\nrows=20")
  fm_composer_classify_screen "$caps" "$(tail -n 20 codex-0.154-idle-herdr.ansi)"'
```

Observed output on the same capture before the fix (`bin/fm-composer-lib.sh` at b85e28b5) and then after it:

```text
pending
empty
```

Before the fix the bare `›` shape extended its wrap region over the two rows beneath the glyph (`kind=bare first=17 last=19` within the 20-row tail), read the surviving starfield cells and the footer as wrapped typed input, and answered `pending`.
The steering doorbell (`fm_task_inbox_ring` in `bin/fm-task-inbox-lib.sh`) defers on exactly that verdict, so every ring for the pane was recorded as skipped and the marked request was reported as a missed delivery.
After the fix, braille-only rows bound the wrap region (the status footer sits beneath the starfield row, so the region never reaches it), starfield cells behind the placeholder are stripped from the glyph row, and the same capture reads `empty` under the Herdr and Zellij styled profiles and with a tmux cursor on the glyph row, while a plain (`styled=0`) capture still reads `unknown`, never `pending`.
A second read-only capture of the same pane, taken during the fix with a bright starfield cell drawn between the `›` and the placeholder, read `pending` before and `empty` after as well.
`test_matrix_codex_idle_starfield_furniture` in `tests/fm-composer-lib.test.sh` carries both samples byte-for-byte, the divergence (the same screen with letters in place of the starfield reads `pending`), and the over-stripping negatives (wrapped typed input, braille mixed with text, a typed row with a middle dot, and the footer or a starfield row alone).

The live guard that refreshed this entry, `tests/fm-composer-codex-idle-live-e2e.test.sh`, was removed with the Codex worker adapter; the Herdr capture above is this entry's live evidence.

## Steering-inbox doorbell

The steering channel's one behavioral assumption - a real worker agent follows the constant self-describing doorbell line (list the inbox, read and act on its records in numeric order, then `mv` each into `handled/`) - was verified on 2026-08-23 against every installed verified harness, on tmux 3.6a, macOS arm64, on an isolated private socket, driving the REAL `bin/fm-send.sh` end to end (durable record plus doorbell, with one mid-wait re-ring playing the watcher's role).

Observed output (combined across the full run and the grok rerun after the advisory-skip narrowing landed):

```text
ok - claude (2.1.241 (Claude Code)): the doorbell reached a real worker, which acted and acked with the mv
ok - codex (codex-cli 0.147.0): the doorbell reached a real worker, which acted and acked with the mv
ok - opencode (1.18.21): the doorbell reached a real worker, which acted and acked with the mv
# grok (grok 1.0.5 (5115b46bc909) [stable]): idle composer never classified empty; proceeding as production does (advisory check skips only on pending)
ok - grok (grok 1.0.5 (5115b46bc909) [stable]): the doorbell reached a real worker, which acted and acked with the mv
# harness absent, not verified here: kimi
ok - muse (Muse Code 0.2.1 (0.2.1-R1215.1)): the doorbell reached a real worker, which acted and acked with the mv
```

The retained samples honored the doorbell contract with real model turns: each listed the inbox named by the doorbell, read its record, executed the instruction inside it, and acknowledged with the atomic `mv`.
Two findings from the run shaped the shipped behavior: an OpenCode vendor update modal swallowed the first doorbell and the single re-ring recovered it, which is exactly the watcher ladder's job; and grok 1.0.5's idle composer never classifies `empty` (a classifier drift recorded in [Composer classification matrix](#composer-classification-matrix), not verified against later Grok releases), which is why the ring's advisory pre-check skips only on an exact proven `pending` verdict - a doorbell into an ambiguous composer is a recoverable constant line, while skipping on ambiguity would starve steering for any harness the classifier cannot positively identify.
Kimi was not installed on the verification machine, and its worker receive path has since been removed; the portable ladder and enqueue regressions in `tests/fm-task-inbox.test.sh` and `tests/fm-send-inbox.test.sh` still cover the harness-independent contract.
The live doorbell guard was removed with the non-Deck adapters; these observations are dated evidence, not refresh instructions.
[Deck verification](deck.md) owns the Deck worker evidence.

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

### Portable stream-parity regressions

[`tests/fixtures.sh`](../../tests/fixtures.sh)'s `fm_test_fake_stream` supplies fake fleet endpoints to the real adapter; its header owns setup and helper usage, and [`stream-hub-stub.py`](../../tests/assets/stream-hub-stub.py)'s docstring owns fake-shell behavior.
`tests/fm-test-fixtures.test.sh`, `tests/fm-backend.test.sh`, `tests/fm-send-strict.test.sh`, and `tests/fm-crew-state.test.sh` exercise fixture round trips, spawn metadata, unrecorded explicit-target routing, and busy/idle/missing/unreachable crew reads.
`tests/fm-control-recover-missing.test.sh` covers new-endpoint rebinding, refusal for a local agent with the task's label and owning status path, preservation of unrelated agents, and confirmed versus unconfirmed cleanup after a failed rebind.
`tests/fm-endpoint-rebind-lib.test.sh` pins endpoint-only record replacement and identity refusals; `tests/fm-teardown-endpoint-safety.test.sh` pins retired-record cleanup identity, and `tests/fm-backlog-atomicity.test.sh` covers operator retirement.
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

### Live harness identity

The live evidence below was captured with Hub 2.0.0 (protocol 2) on 2026-09-17 on Linux with Python 3.14.4, curl 8.18.0, and jq 1.8.1.
The current hub uses the newer wire protocol documented in [`stream-backend.md`](../stream-backend.md#when-the-hub-restarts), so rerun the guard before treating this as current evidence.
The guard defaults to the Python-reference agent through `tests/lib.sh` and starts a Python hub directly; its publisher-PID lookup is Python-specific, so it does not prove installed-harness liveness or partition behavior through the Rust publisher.
Native adapter CI coverage is described in [the stream guide](../stream-backend.md#rust-pty-agent), and installed-harness verification of that publisher remains unrecorded here.

The owning stream agent reads its own pseudoterminal's foreground process group and publishes it to the hub over HTTP, where the classifier sees a flattened command line.
This guard exercises the real publish path and freshness gate, not only the process-name classifier.

```sh
bash tests/fm-stream-agent-live-e2e.test.sh
```

```
# claude 2.1.273 (Claude Code): published foreground=[claude /home/bruno/.local/bin/claude /home/bruno/.local/bin/claude]
ok - stream liveness: claude 2.1.273 (Claude Code) classifies alive through the hub
# claude 2.1.273 (Claude Code): a silenced publisher reads unreadable, not dead
# pi 0.85.1: published foreground=[pi pi pi]
ok - stream liveness: pi 0.85.1 classifies alive through the hub
# pi 0.85.1: a silenced publisher reads unreadable, not dead
# checked 2 installed harness(es)
# unverified here: codex opencode pi-signed grok kimi cursor muse
ok - stream liveness: every installed harness is attributable through the hub, and a partition is never read as death
```

Each harness is launched bare with no prompt, so the guard spends no model tokens and runs by default wherever its tools are installed.
Every case first asserts that a bare endpoint shell classifies `dead`, so a later `alive` proves the harness was actually seen rather than that the guard says `alive` about anything with a pulse.

The partition assertion runs against the real harness: the publisher alone is silenced while the harness keeps running untouched, and the verdict must become `unreadable`, never `dead`.
A `dead` there would authorize tearing down a healthy worker that was merely unreachable.

`codex`, `opencode`, `pi-signed`, `grok`, `kimi`, `cursor`, and `muse` were not installed on this machine and are unverified by this run.
Re-run the guard after any harness upgrade before trusting this evidence.
