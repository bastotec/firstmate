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
| Platform | macOS (Darwin 25.6.0, arm64), GNU bash 3.2.57, jq 1.7.1, tmux 3.6a |
| Backend | tmux |

## What Firstmate owns here

Deck has no interactive screen, so nearly every supervised behavior is Firstmate's own driver, `bin/fm-deck-worker.sh`, not a vendor surface.
The vendor facts it depends on are Deck's own CLI contract: `run` streams NDJSON (`run_started` carries the session id, `run_finished` / `run_failed` end a run), `--session` resumes a session, and `--hook EVENT=COMMAND` attaches `pre_complete` (exit 2 refuses completion and the stderr is sent back to the model) and `post_tool_use`.
Deck's own tests pin that contract (`cargo test --locked`, 85 tests at `7308f21`).

## Portable regression

`tests/fm-deck-harness.test.sh` drives the real driver against a fake `deck` that logs its arguments, honours `--session`, and runs the `pre_complete` hook the way Deck does:

```
$ bash tests/fm-deck-harness.test.sh
ok - fm-deck-worker: the brief and later prompts are turns of one Deck session with hooks and model
ok - fm-deck-worker: turns open and close the deck-wrapper busy record and touch turn-end
ok - fm-deck-worker: busy-state failures stop turns and publish status evidence
ok - fm-deck-worker: turn-end publication refuses unsafe targets
ok - fm-deck-worker: the evidence gate refuses a silent turn and passes one that reported
ok - fm-deck-worker: Deck stderr cannot break completion-blocked rendering
ok - fm-deck-worker: Firstmate bookkeeping cannot satisfy worker evidence
ok - fm-deck-worker: status evidence never follows symlinked or non-regular paths
ok - fm-deck-worker: silent and failed turns gain status evidence before turn-end
ok - fm-deck-worker: Ctrl+C records evidence and returns the worker to its prompt
ok - fm-deck-worker: each completed turn leaves the next steer an idle baseline
ok - liveness: the deck driver and binary are agents, unrelated names are not
ok - tmux liveness: Deck's Linux comm and argv0 classify alive
ok - control and busy-source tables carry Deck mechanics without rendered delivery evidence
ok - fm-spawn: ordinary Deck dispatch records only default effort
ok - fm-spawn: Deck refuses unsupported effort before launch metadata
fm-deck-harness: all cases passed
```

The dispatch validator rejects Deck profiles with effort, spawn refuses a non-default `--effort` before launch or task metadata, and relaunch refuses it before stopping the current worker because Deck has no effort control.
Those boundaries are pinned by `tests/fm-bootstrap.test.sh`, `tests/fm-deck-harness.test.sh`, and `tests/fm-control-relaunch.test.sh`.
The driver refuses to run Deck when it cannot record `turn-start`, and a failed closing busy-state write publishes failure evidence and makes the turn fail.
The evidence gate snapshots the status log's byte offset at turn start and searches a bounded appended suffix for a complete `done`, `needs-decision`, `blocked`, `failed`, or `working` line.
Firstmate-owned bookkeeping lines such as `resolved:` and `note:` do not satisfy the gate or the driver's postcondition.
Those reads, the driver's fallback append, and turn-end publication use Python 3 descriptor-bound I/O, reject symlinks and non-regular or multiply linked files, and never touch an unsafe target.
The terminal regression drives two real `fm-send.sh` steers through tmux and proves delivery from the next `deck-wrapper` turn start after an idle baseline while each completed turn removes its transient rendered working row.

## Live check

The passing 2026-09-22T08:31Z check ran Firstmate commit `641dc7fe` with `deck 0.1.0` in a real tmux pane on macOS through proxai using route `codex/gpt-5.6-sol`.
The brief completed and appended valid worker evidence.
A steer completed in the same Deck session and retained context from the brief.
The `pre_complete` evidence gate refused completion once, then accepted the retry after the worker appended valid evidence.
`Ctrl+C` returned the driver to its prompt and recorded `interrupted`.
`/quit` exited and recorded `session-end`.
Tmux's `#{pane_current_command}` reported `bash` on macOS, while `ps -o comm=` reported `fm-deck-worker`.
These results verify ordinary Deck crewmate and scout dispatch; the separate host check below owns secondmate evidence.

## Secondmate host verification

Checked 2026-09-22 with `deck 0.1.0`, macOS Darwin 25.6.0 arm64, Bash 3.2.57, and gateway route `codex/gpt-6-astra`.
The live check uses a disposable home with no registered projects or workers and the real Deck binary, session-start digest, watcher, durable task steering inbox, and wake acknowledgement path.
It runs the pane driver over ordinary pipes without tmux injection, so wake delivery does not depend on a terminal backend.
Existing backend capability guards remain authoritative: this change does not enable secondmates on a backend that already refuses them.

```sh
FM_DECK_LIVE=1 FM_DECK_LIVE_MODEL=codex/gpt-6-astra bin/fm-test-run.sh tests/fm-deck-host-live-e2e.test.sh
```

Observed output:

```text
deck 0.1.0
startup completed; stable driver owns home lock
PASS real Deck startup, stable driver lock, watcher wake-as-next-turn, acknowledgement, and clean exit
```

The initial turn received the complete startup digest and wrote the requested readiness marker without rerunning startup.
The watcher wake became a durable steering record; the same Deck conversation read it, handled the isolated note, acknowledged the wake queue and inbox record, and returned to the host.
The home lock still named the persistent driver after both turns, rather than the exited `deck run` process.
The parent received no manufactured worker status for normal supervisor turns.

Portable checks:

```sh
bin/fm-test-run.sh tests/fm-deck-harness.test.sh tests/fm-supervision-instructions.test.sh tests/fm-spawn-dispatch-profile.test.sh tests/fm-control-relaunch.test.sh tests/fm-remote-secondmate-lifecycle-e2e.test.sh tests/fm-remote-secondmate-replacement.test.sh tests/fm-remote-doctor.test.sh
```

`fm-deck-harness` exercises a wake arriving during a running steer, the durable doorbell and handled record, rearming, partial typed input across an idle timeout, stable session identity, interrupt survival, and explicit startup, provider, and watcher failure reporting.
The dispatch and relaunch suites exercise the configured Deck secondmate pin, charter preservation, home selection, semantic busy generation, and migration of an existing secondmate through the normal control entry point.
The remote suites exercise Deck readiness, host launch acceptance, Herdr driver submission, and replacement-proved relaunch.
The four invariants and driver-specific turn-end postcondition are owned by `bin/fm-deck-worker.sh`'s header; the emitted operating instructions are owned by [`../supervision-protocols/deck.md`](../supervision-protocols/deck.md).
