# Rust stream PTY agent validation

Target: `95785db44278a8dfa2af04af151bec1bbacec50f`.
Host: macOS, Rust/Cargo 1.96.0, existing Homebrew Python 3.14.5.
Production launchers and tracked source files were not changed.

## Targeted execution

- `PATH="/opt/homebrew/bin:$PATH" TMPDIR="$PWD/.no-mistakes/test-tmp" FM_LIVE=0 bin/fm-test-run.sh --jobs 1 tests/fm-stream-agent-rust.test.sh` passed without skipping the agent suite.
- `cargo test --locked -p fm-stream-agent -- --test-threads=1` passed the reaped-child bystander and own-group/session guards.
- Reused the existing `tests/assets/stream-agent-rust-parity.py` fixture functions `command_values`, `generation_refusal`, `lost_result`, and `redirected_background_exit` against the target Rust executable to collect HTTP responses, persisted status records, and actual received PTY input bytes.
- All endpoint tests used ephemeral loopback hubs and fixture-local credentials, real shells with 40x200 PTYs, and serial execution.

`agent-parity.log` is the existing executable end-to-end suite transcript.
`agent-regression-and-product.jsonl` records actual controller HTTP responses and observed status/input contracts, not implementation-source assertions.
The command-value transcript contains Python-compatible non-finite values, so its JSON-lines records intentionally include `NaN` and `Infinity` in requests, just as the hub accepts them.

## Counterfactuals

Built committed source snapshots inside the assigned worktree using `git archive <commit> Cargo.toml Cargo.lock crates` and `cargo build --locked -p fm-stream-agent --manifest-path <snapshot>/Cargo.toml --target-dir <isolated-target>`.
No additional Git worktree, terminal server, installed harness, or system package was created.

The initial port at `961f1c95` fails the current executable regression scenarios:

- An unsigned note of `9223372036854775809` is persisted as `9.223372036854776e+18` instead of its exact decimal value.
- Concurrent status writers produce broken records such as `workingdone: direct-747` followed by a separate `: agent-3-...` record.
- A status note of `[NaN]` produces HTTP 504 `no_agent_ack`, `taken: true`, with no status file.
- `--state-interval 90000` fails readiness and reports the former one-day restriction.

See `agent-initial-regressions.jsonl` and `agent-before-fix-observations.jsonl` for these actual observations.
All corresponding target scenarios passed.

The pre-CLOEXEC-fix executable at `81af458b` also closes promptly on this macOS host while its fully redirected background child remains alive.
Thus the target's prompt close/exit-code behavior is proven here, but this host did not reproduce the historical descriptor-leak symptom.
The background children self-terminated after 15 seconds; cleanup never signalled a reaped process group.

An initial baseline attempt accidentally reused the target executable through a shared Cargo target directory.
That comparison was discarded after identical binary hashes exposed the setup error.
The baseline was rebuilt in a separate clean target directory and verified to have a different hash before the valid comparison.
The discarded attempt and explicit correction remain in `agent-product-transcript.jsonl`; they are not evidence of a product failure.

## Limits and cleanup

The incompatible-protocol/missing-capability startup checks passed against the suite's synthetic health server, not an actual incompatible deployed hub.
No installed AI harnesses or deployed fleet endpoints were launched or touched, as required by the runbook.
This change is a CLI/PTY backend, not a visual-layout change; HTTP, terminal-byte, and durable-status artifacts are the relevant evidence.
Disposable source snapshots, baseline binaries, baseline build caches, fixture data, and newly created incremental build generations were removed.
Pre-existing prepared Cargo dependencies were preserved.
The tracked worktree remains unchanged.
