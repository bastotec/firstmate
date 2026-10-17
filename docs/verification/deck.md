# Verification: the Deck adapter

Active empirical facts for firstmate's Deck adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/deck.md`](../../.agents/skills/harness-adapters/references/harness/deck.md); this record owns how they were established.

## Subject

| Field | Value |
|---|---|
| Version | `deck 0.1.0` built from `bastotec/deck` main at `7308f21` (includes `run --hook` and the `pre_complete` hook) |
| Checked | 2026-09-22T08:31Z |
| Firstmate commit | `641dc7fe` |
| Status | Verified for crewmate, scout, and secondmate dispatch; dated host evidence below |
| Binary | `~/.local/bin/deck`, copied from `target/release/deck` after `cargo build --release --locked` |
| Platform | macOS (Darwin 25.6.0, arm64), GNU bash 3.2.57, jq 1.7.1 |
| Backend | The 2026-09-22 [live check](#live-check) ran on a since-removed terminal backend; no run over stream is recorded yet |

## What Firstmate owns here

The `deck run` surface has no interactive screen, so nearly every supervised worker behavior is Firstmate's own driver, `bin/fm-deck-worker.sh`, not a vendor surface.
The separate `deck chat` primary host (`bin/fm-deck-chat.sh`) is outside the live evidence recorded here.
The vendor facts it depends on are Deck's own CLI contract: `run` streams NDJSON (`run_started` carries the session id, `run_finished` / `run_failed` end a run), `--session` resumes a session, and `--hook EVENT=COMMAND` attaches `pre_complete` (exit 2 refuses completion and the stderr is sent back to the model) and `pre_tool_use` / `post_tool_use`.
Deck's own tests pin the original hook contract (`cargo test --locked`, 85 tests at `7308f21`).

## Portable regression

`tests/fm-deck-harness.test.sh` drives the real driver against a fake `deck` that logs its arguments, honours `--session`, and runs `pre_complete` plus `pre_tool_use` / `post_tool_use` with the tool event on stdin.
The focused portable regression set is:

```sh
bin/fm-test-run.sh tests/fm-brief.test.sh tests/fm-deck-harness.test.sh tests/fm-deck-turn-failure-supersession.test.sh tests/fm-wake-drain-outcome-backstop.test.sh
```

These suites print one `ok - ...` line per case; their case names are the current coverage list.
The Deck harness's validation-record case exercises a run starting during a blocking tool call after the pre-tool hook fired.
[`tests/fm-crew-state.test.sh`](../../tests/fm-crew-state.test.sh) covers publication, serialized observations, follower ownership, grace expiry and re-arming, and detached publication with polling disabled; [`bin/fm-task-state-lib.sh`'s header](../../bin/fm-task-state-lib.sh) owns those contracts.

The spawn-side effort restrictions owned by [Harness support](../configuration.md#harness-support) are pinned by `tests/fm-bootstrap.test.sh`, `tests/fm-deck-harness.test.sh`, and `tests/fm-control-relaunch.test.sh`.
The host regression forces actionable watcher exits across long handling turns, accepts verified successors across recovery acknowledgement races, and proves Deck turns remain serialized with accumulated wakes delivered by the next turn.
It also exercises an exact queued `/quit` ahead of pending watcher work after composer clears and a stale own doorbell, with the clears delivered 1.5 seconds before `/quit`; ordinary steers retain watcher priority.
The driver header owns the bounded grace that admits the delayed exit.
The `test_secondmate_survives_a_refused_handling_confirmation` case in that suite injects a refusal through a fake `fm-watch-arm.sh` while running the real driver with unrelated inherited handoff claims.
Its assertions cover stderr-only diagnostics, retirement of the refused watcher, a replacement with no predecessor claim, absence of `failed:` status, delivery of the original and replacement wakes in the same Deck session, and clean `/quit`; the driver header owns the recovery contract.
The `test_secondmate_fast_successor_keeps_its_notification` case runs the real arm and driver with a deterministic watcher fixture that appends a durable wake and exits successfully before confirming successor startup.
It asserts the notification reaches a later serialized turn after a healthy turn, the session is resumed, the durable queue row remains unacknowledged by the driver, no duplicate turn follows during the observation window, and `/quit` exits cleanly.
This pins a lost-result mechanism in a repository fixture, not the cause of every reported live stall; [the driver header](../../bin/fm-deck-worker.sh) owns result retention and handoff claims.
The `test_secondmate_host_survives_an_unconfirmed_successor_watcher` case injects both a silent successor and one that exits before confirmation, then asserts a stderr replacement warning, no corresponding failure status, two subsequent wake turns, and clean `/quit`.
The `test_secondmate_host_survives_a_failed_watcher_and_resumes_its_session` case fails a running watcher as it consumes its trigger, asserts the replacement has no predecessor claim, serves a later wake without failure status, and verifies the session binding stays absent until the fixture writes Deck's session file mid-startup, then appears while the turn is still active.
It exercises relaunch with a retained Deck session file, missing-file fallback, explicit fresh-session opt-out, preservation of the previous saved binding through an unsaved fresh run and its subsequent relaunch, an unbound legacy record, and a reassigned home; these are fixture assertions, not live Deck persistence evidence.
`tests/fm-secondmate-safety.test.sh` verifies successful retirement removes the binding and refused retirement preserves it.
The `test_secondmate_host_retains_failed_successor_start_evidence` case runs the real arm and driver with a deterministic watcher fixture that exits before startup confirmation, remains unconfirmed past the host deadline, or reaches the arm deadline before the host deadline.
It asserts startup stderr appears exactly once in the host output, termination stderr appears exactly once for both deadline cases, the unconfirmed child is gone, a replacement serves a later wake without `failed:` status, and `/quit` exits cleanly.
`tests/fm-watch-arm.test.sh`'s `test_handling_child_stderr_is_retained` separately asserts stderr capture on failed and interrupted handling-child starts, propagated exit codes, lifecycle recording, and temporary-capture removal; [the arm header](../../bin/fm-watch-arm.sh) owns the capture contract.
The same suite's `test_handling_inspection_failure_retains_completed_capture` forces recovery-marker inspection to fail and asserts startup and delayed termination stderr appear exactly once, no startup confirmation is printed, the child is stopped, the lifecycle failure is recorded, and the temporary capture is removed.
The driver refuses to run Deck when it cannot record `turn-start`, and a failed closing busy-state write publishes failure evidence and makes the turn fail.
Turn-lifecycle and progress-refresh failures retain `fm-busy-event.sh`'s underlying stderr in both the pane and the appended `failed:` status, including stale-generation diagnostics.
The evidence gate snapshots the status log's byte offset at turn start and searches a bounded appended suffix for a complete `done`, `needs-decision`, `blocked`, `failed`, or `working` line.
Firstmate-owned bookkeeping lines such as `resolved:` and `note:` do not satisfy the gate or the driver's postcondition.
Those reads, the driver's fallback append, and turn-end publication use Python 3 descriptor-bound I/O, reject symlinks and non-regular or multiply linked files, and never touch an unsafe target.
`tests/fm-deck-turn-failure-supersession.test.sh` pins ordered, captured-endpoint classification for exact task-local recovery-generation and record-id stamped `turn-failed` records, including mismatched generations, terminal-separated repeated failures, and durable exact-record supersession.
`tests/fm-brief.test.sh` executes the generated status command in Deck and non-Deck environments, proving that Deck selects the locked append boundary without changing the fallback protocol.
The Deck harness proves that Firstmate bookkeeping does not satisfy the worker-evidence gate, a silent failed turn creates no watcher-downtime marker, a later turn in the same driver incarnation binds worker-authored `working:` evidence to that driver's recovery generation through the locked status append, and a fresh driver incarnation cannot bind an older failure.
The focused supersession suite sends a working-plus-terminal burst through that executable append boundary and proves its single write orders the generated binding before the terminal record.
It also proves that a stale same-turn working append after a terminal leaves the terminal bytes unchanged, while the next turn's working append is retained without a stale recovery marker.
`tests/fm-wake-drain-outcome-backstop.test.sh` proves that a captured span whose only captain-relevant event is a superseded turn failure advances its outcome receipt without captain-facing output.
The terminal regression drives two real `fm-send.sh` steers through the Python stream hub and PTY agent, confirming each submit from the cleared composer after the turn finishes while proving no transient rendered working row remains.
The finished-turn row renders its UTC completion time from `run_finished.finished_at` and falls back to the timestamp-less wording when the field is absent, while the idle prompt notes the UTC idle instant beside its bare `❯` row.

## Driver lifecycle

`bin/fm-deck-stop.py` owns the task-bound local driver stop proof used by both control-plane exit and the shared spawn-relaunch boundary; endpoint classification remains required independently.
The portable regression runs the driver, Deck executable, and state beneath paths containing spaces and proves that TERM removes the active Deck process before the stop boundary returns.
Its fake Deck uses Python's default TERM behavior, not Deck's cooperative-stop behavior: the fixture's active in-process tool is interrupted rather than allowed to complete, and no later tool starts.
The TERM-resistant fixture exercises both helper modes: the default mode escalates the surviving isolated process group to KILL, while cooperative mode refuses and leaves survivors alive.
`test_cooperative_stop_accounts_for_inherited_driver_argv` runs an actual Bash command-substitution descendant with inherited launch arguments, checks that stop waits for it inside the owned group, preserves it on timeout, and refuses an unisolated driver before signalling.
`tests/fm-control-relaunch.test.sh` keeps the recorded endpoint alive after interrupt and `/quit` delivery until the exact old driver group, including a late-forked child, has stopped; replacement must wait for both proofs.
Its separate live-endpoint refusal case closes another task's endpoint and checks that replacement still refuses while preserving the instructions, metadata, and staged work.
Physical-state-alias and stale-generation relaunch regressions, including the valueless `--secondmate` driver flag, are in `tests/fm-deck-harness.test.sh` and `tests/fm-control-relaunch.test.sh`.
This driver-only path does not alter backend transport or endpoint classifiers.

The separate `test_secondmate_stops_a_turn_inside_a_long_tool` fixture models Deck's cooperative SIGTERM while running real child processes under the secondmate driver.
It asserts bounded exit for Ctrl+C and mid-turn `/quit`, cancellation after shell exec replacement, freeze-and-rescan handling of a late-fork race, and the hard fallback for a TERM-resistant model call even when the tool grace exceeds the kill bound.
Its MCP-like child leads a separate process group and must remain alive in every case; cooperative cases must acknowledge the stop after the tool returns.
The `test_secondmate_watcher_backoff_keeps_turn_stop_responsive` fixture waits for a four-second watcher retry delay during a long tool, then asserts Ctrl+C and queued `/quit` remain responsive without another watcher start.
These are portable fixture assertions, not additional live Deck evidence; the [driver header](../../bin/fm-deck-worker.sh) owns the stop contract.

## Live check

The passing 2026-09-22T08:31Z check ran Firstmate commit `641dc7fe` with `deck 0.1.0` on macOS through proxai using route `codex/gpt-5.6-sol`.
The brief completed and appended valid worker evidence.
A steer completed in the same Deck session and retained context from the brief.
The `pre_complete` evidence gate refused completion once, then accepted the retry after the worker appended valid evidence.
`Ctrl+C` returned the driver to its prompt and recorded `interrupted`.
`/quit` exited and recorded `session-end`.
`ps -o comm=` reported `fm-deck-worker` for the driver.
These results verify ordinary Deck crewmate and scout dispatch; the separate host check below owns secondmate evidence.

## Secondmate host verification

Checked 2026-09-22 with `deck 0.1.0`, macOS Darwin 25.6.0 arm64, Bash 3.2.57, and gateway route `codex/gpt-6-astra`.
The live check uses a disposable home with no registered projects or workers and the real Deck binary, session-start digest, watcher, durable task steering inbox, and wake acknowledgement path.
It runs the driver over ordinary pipes rather than through a terminal backend, so wake delivery does not depend on one.

```sh
FM_DECK_LIVE=1 FM_DECK_LIVE_MODEL=codex/gpt-6-astra bin/fm-test-run.sh tests/fm-deck-host-live-e2e.test.sh
```

Observed output:

```text
deck 0.1.0
startup completed; stable driver owns home lock
PASS real Deck startup, handling-successor continuity, no parent turn-end wake, acknowledgement, and clean exit
```

The initial turn received the complete startup digest and wrote the requested readiness marker without rerunning startup.
The watcher wake became a durable steering record; before its long handling turn began, the driver established and confirmed the generation-bound handling successor, and the same Deck conversation read the record, handled the isolated note, acknowledged the wake queue and inbox record, and returned to the host.
The home lock still named the persistent driver after both turns, rather than the exited `deck run` process.
The parent received neither manufactured worker status nor a turn-end wake for normal supervisor turns.

Portable checks:

```sh
bin/fm-test-run.sh tests/fm-deck-harness.test.sh tests/fm-supervision-instructions.test.sh tests/fm-spawn-dispatch-profile.test.sh tests/fm-control-relaunch.test.sh tests/fm-remote-secondmate-lifecycle-e2e.test.sh tests/fm-remote-secondmate-replacement.test.sh tests/fm-remote-doctor.test.sh
```

`fm-deck-harness` exercises a wake arriving during a running steer, the durable doorbell and handled record, rearming, partial typed input across an idle timeout, stable session identity, interrupt survival, and explicit startup, provider, and watcher failure reporting.
Its `test_secondmate_retries_a_captain_wake_whose_turn_failed` case injects one provider failure, asserts the ordinary captain record remains pending, then checks a retry handles it without another message, logs the configured one-second delay, and does not repeat after acknowledgement.
This is portable fixture coverage, not live gateway-failure evidence; the [driver header](../../bin/fm-deck-worker.sh) owns the retry contract.
Its `test_secondmate_turn_model_follows_the_switch_file` case records the fake Deck's `--model` argument across startup, switch-file creation, and removal, asserting `launch/route`, `switched/route`, then `launch/route`; the [`fm-control.sh` header](../../bin/fm-control.sh) owns turn-route selection and relaunch persistence.
The dispatch and relaunch suites exercise the configured Deck secondmate pin, charter preservation, home selection, semantic busy generation, and migration of an existing secondmate through the normal control entry point.
The remote suites exercise Deck readiness, host launch acceptance over the stream host runtime, and replacement-proved relaunch.
The secondmate invariants and driver-specific turn-end postcondition are owned by `bin/fm-deck-worker.sh`'s header; the emitted operating instructions are owned by [`../supervision-protocols/deck.md`](../supervision-protocols/deck.md).
