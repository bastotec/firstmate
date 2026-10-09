# Supervision integration verification

Audience: maintainer verification.

This record supports current busy-state, turn-end, secondmate-revival, and wedge-alarm guarantees.
Operator behavior and active limits remain in the linked current guides.
Task-specific chronology, temporary paths, run identifiers, and delivery transcripts remain in private reports or PR evidence.

## Semantic busy state

The semantic source behind [`bin/fm-busy-lib.sh`](../../bin/fm-busy-lib.sh) is Deck's `deck-wrapper` record, verified in [`deck.md`](deck.md) against firstmate-launched workers wired exactly as `fm-spawn` writes them.

Deterministic entry points:

```sh
tests/fm-busy-state.test.sh
tests/fm-busy-adapter-wiring.test.sh
tests/fm-crew-state.test.sh
```

## Turn-end supervision

Deck secondmate startup, stable lock ownership, and driver-owned turn-end supervision were checked on 2026-09-22 with `deck 0.1.0`; [Deck host verification](deck.md#secondmate-host-verification) owns the refresh command and exact output.

## Secondmate revival

[Secondmate lifecycle](../stream-backend.md#secondmate-lifecycle) owns operator behavior and limits; [`bin/fm-secondmate-revive.sh`](../../bin/fm-secondmate-revive.sh) owns the scan contract.
Portable regression entry points:

```sh
bin/fm-test-run.sh tests/fm-secondmate-revive.test.sh tests/fm-secondmate-liveness.test.sh tests/fm-control.test.sh tests/fm-remote-secondmate-stream.test.sh tests/fm-secondmate-restart.test.sh
```

The revival suite exercises confirmed local and remote down readings, local missing-endpoint recovery, remote missing-endpoint escalation without claimed attempts, exclusion of non-secondmate records, per-mate concurrency across overlapping scans, retry exhaustion, escalation publication retries, and watcher-driven recovery without a model turn.
It also exercises deliberate-stop marker withdrawal under the lifecycle lock and recovery between probing and automatic admission without consuming a failure.
The liveness suite covers startup's held-stop and live-lock skips and the fresh liveness recheck after taking that lock.
The control and remote stream suites cover secondmate exit protection, locked alive-admission refusal, and the primary stop marker after a lost remote exit response.
The restart suite covers selection of the deciding failure instead of a preceding warning; [Deck portable regression](deck.md#portable-regression) owns queued-exit ordering coverage.
These are regression entry points, not a new dated live-harness result.

## Wedge-alarm channels

The real `osascript` notification channel was bounded manually on 2026-07-10 on macOS 26.5.2.
It is the only built-in channel; other platforms use a `command:` directive.
Automated suites never execute the real notification command.

Argv-safe Notification Center command:

```sh
/usr/bin/osascript \
  -e 'on run argv' \
  -e 'display notification (item 1 of argv) with title "FIRSTMATE TEST - IGNORE" sound name "Basso"' \
  -e 'end run' \
  'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)'
```

Observed output: no stdout, exit 0, and one banner with the supplied body.

The safe command-channel contract is covered without a notification by `tests/fm-daemon.test.sh`: the summary reaches both `$1` and stdin, every channel is process-group bounded, and a failed channel falls through.
