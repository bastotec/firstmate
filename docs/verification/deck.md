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

`tests/fm-deck-harness.test.sh` drives the real driver against a fake `deck` that logs its arguments, honours `--session`, and runs `pre_complete` plus `pre_tool_use` / `post_tool_use` with the tool event on stdin:

```sh
bin/fm-test-run.sh tests/fm-deck-harness.test.sh
```

The suite prints one `ok - ...` line per case; its case names are the current coverage list.
Its validation-record case exercises a run starting during a blocking tool call after the pre-tool hook fired.
[`tests/fm-crew-state.test.sh`](../../tests/fm-crew-state.test.sh) covers publication, serialized observations, follower ownership, grace expiry and re-arming, and detached publication with polling disabled; [`bin/fm-crew-state.sh`'s header](../../bin/fm-crew-state.sh) owns those contracts.

The spawn-side effort restrictions owned by [Harness support](../configuration.md#harness-support) are pinned by `tests/fm-bootstrap.test.sh`, `tests/fm-deck-harness.test.sh`, and `tests/fm-control-relaunch.test.sh`.
The host regression forces actionable watcher exits across long handling turns, accepts verified successors across recovery acknowledgement races, and proves Deck turns remain serialized with accumulated wakes delivered by the next turn.
It also exercises an exact queued `/quit` ahead of pending watcher work after composer clears and a stale own doorbell, with the clears delivered 1.5 seconds before `/quit`; ordinary steers retain watcher priority.
The driver header owns the bounded grace that admits the delayed exit.
The `test_secondmate_survives_a_refused_handling_confirmation` case in that suite injects a refusal through a fake `fm-watch-arm.sh` while running the real driver.
Its assertions cover stderr-only diagnostics, retirement of the refused watcher, a replacement with no predecessor claim, absence of `failed:` status, delivery of the original and replacement wakes in the same Deck session, and clean `/quit`; the driver header owns the recovery contract.
The driver refuses to run Deck when it cannot record `turn-start`, and a failed closing busy-state write publishes failure evidence and makes the turn fail.
Turn-lifecycle and progress-refresh failures retain `fm-busy-event.sh`'s underlying stderr in both the pane and the appended `failed:` status, including stale-generation diagnostics.
The evidence gate snapshots the status log's byte offset at turn start and searches a bounded appended suffix for a complete `done`, `needs-decision`, `blocked`, `failed`, or `working` line.
Firstmate-owned bookkeeping lines such as `resolved:` and `note:` do not satisfy the gate or the driver's postcondition.
Those reads, the driver's fallback append, and turn-end publication use Python 3 descriptor-bound I/O, reject symlinks and non-regular or multiply linked files, and never touch an unsafe target.
The terminal regression drives two real `fm-send.sh` steers through the Python stream hub and PTY agent, confirming each submit from the cleared composer after the turn finishes while proving no transient rendered working row remains.
The finished-turn row renders its UTC completion time from `run_finished.finished_at` and falls back to the timestamp-less wording when the field is absent, while the idle prompt notes the UTC idle instant beside its bare `❯` row.

## Driver lifecycle

`bin/fm-deck-stop.py` owns the task-bound local driver stop proof used by both control-plane exit and the shared spawn-relaunch boundary; endpoint classification remains required independently.
The portable regression runs the driver, Deck executable, and state beneath paths containing spaces and proves that TERM removes the active Deck process before the stop boundary returns.
Its fake Deck uses the binary's default TERM behavior: an active in-process tool is interrupted rather than allowed to complete, and no later tool starts.
A second fixture ignores TERM and proves the bounded wait escalates the surviving isolated process group to KILL.
Physical-state-alias and stale-generation relaunch regressions, including the valueless `--secondmate` driver flag, are in `tests/fm-deck-harness.test.sh` and `tests/fm-control-relaunch.test.sh`.
This driver-only path does not alter backend transport or endpoint classifiers.

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
The dispatch and relaunch suites exercise the configured Deck secondmate pin, charter preservation, home selection, semantic busy generation, and migration of an existing secondmate through the normal control entry point.
The remote suites exercise Deck readiness, host launch acceptance over the stream host runtime, and replacement-proved relaunch.
The secondmate invariants and driver-specific turn-end postcondition are owned by `bin/fm-deck-worker.sh`'s header; the emitted operating instructions are owned by [`../supervision-protocols/deck.md`](../supervision-protocols/deck.md).
