# Supervision integration verification

Audience: maintainer verification.

This record supports current busy-state, held-for-merge stale-suppression, turn-end, secondmate-revival, lane-health, parked-run, and wedge-alarm guarantees.
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

## Held-for-merge stale suppression

[`Architecture`](../architecture.md#stale-panes-and-the-wedge-ladder) owns the completed-delivery boundary and its safety rationale.
Portable regression entry points:

```sh
bin/fm-test-run.sh tests/fm-watch-triage.test.sh tests/fm-watch-triage-stale.test.sh tests/fm-daemon.test.sh
```

The suites cover the recorded GitHub and GitLab delivery gate, the positively attributed run-PR gate, the no-evidence alarm path, first-sight and due-ladder suppression with one authoritative state read, away-housekeeping marker retirement, and preservation of a newly actionable completion when an enriched wedge is already queued.

## Turn-end supervision

Deck secondmate startup, stable lock ownership, and driver-owned turn-end supervision were checked on 2026-09-22 with `deck 0.1.0`; [Deck host verification](deck.md#secondmate-host-verification) owns the refresh command and exact output.

## Secondmate revival

[Secondmate lifecycle](../stream-backend.md#secondmate-lifecycle) owns operator behavior and limits; [`bin/fm-secondmate-revive.sh`](../../bin/fm-secondmate-revive.sh) owns the scan contract.
Portable regression entry points:

```sh
bin/fm-test-run.sh tests/fm-secondmate-revive.test.sh tests/fm-secondmate-liveness.test.sh tests/fm-control.test.sh tests/fm-remote-secondmate-stream.test.sh tests/fm-secondmate-restart.test.sh
```

The revival suite exercises confirmed local and remote down readings, local and remote missing-endpoint recovery, escalation of a remote endpoint that will not come back after its attempt budget, exclusion of non-secondmate records, per-mate concurrency across overlapping scans, retry exhaustion, escalation publication retries, and watcher-driven recovery without a model turn.
It also exercises deliberate-stop marker withdrawal under the lifecycle lock, recovery between probing and automatic admission without consuming a failure, and fresh confirmation of legacy unattempted remote-missing escalations while held and spent-budget episodes remain untouched.
The liveness suite covers startup's held-stop and live-lock skips and the fresh liveness recheck after taking that lock.
The control and remote stream suites cover secondmate exit protection, locked alive-admission refusal, and the primary stop marker after a lost remote exit response.
The control suite also covers the lane-health live-replacement exception while preserving the deliberate-stop refusal.
The revival suite covers per-lane recovery and escalation, shared relaunches, failed or deferred relaunches, and incremental status reads that preserve episode identity.
Its model-switch cases exercise raw and gateway HTTP 5xx classification, majority selection among eligible local or remote siblings, exclusion of unset/default and unhealthy candidates, shared switch grace and escalation context, and busy, deliberate-stop and failure outcomes.
It also feeds real two-lane heal logs into the dream collector to check that shared relaunches count once; [`tests/fm-dream.test.sh`](../../tests/fm-dream.test.sh) separately covers mixed revival-log lines.
The remote stream suite also covers refusal of explicit recovery-profile flags before contacting the host, restarts its real hub to make a remote mate's endpoint missing, proves recovery refuses while the forgotten agent still runs on the host, and proves the revive scan alone brings the mate back on a new endpoint once that agent is gone.
The restart suite covers selection of the deciding failure instead of a preceding warning and preservation of a remote mate's recorded model over the home default; [Deck portable regression](deck.md#portable-regression) owns queued-exit ordering coverage.
These are regression entry points, not a new dated live-harness result.

## Parked validation runs

[`fm-parked-run-watch.sh`'s header](../../bin/fm-parked-run-watch.sh) owns the watchdog contract.
The portable regression entry point is `bin/fm-test-run.sh tests/fm-parked-run-watch.test.sh`.
It covers first-mate and second-mate delivery, observed re-parking and gate changes, unavailable queries and identity-free readings, serialized scan and close, and retryable close-publication failure.
These are fixture assertions, not live no-mistakes timing evidence.

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
