# Verification: the Deck crewmate/scout adapter

Active empirical facts for firstmate's Deck adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/deck.md`](../../.agents/skills/harness-adapters/references/harness/deck.md); this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `deck 0.1.0` built from `bastotec/deck` main at `7308f21` (includes `run --hook` and the `pre_complete` hook) |
| Checked | 2026-09-21 |
| Status | Portable driver checks pass; live adapter verification failed |
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
ok - fm-deck-worker: the evidence gate refuses a silent turn and passes one that reported
ok - fm-deck-worker: status evidence never follows symlinked or non-regular paths
ok - fm-deck-worker: silent and failed turns gain status evidence before turn-end
ok - fm-deck-worker: Ctrl+C records evidence and returns the worker to its prompt
ok - fm-deck-worker: each completed turn leaves the next steer an idle baseline
ok - liveness: the deck driver and binary are agents, unrelated names are not
ok - control, busy-source, and delivery tables carry deck's implemented mechanics
ok - fm-spawn: Deck refuses ordinary dispatch until live verification
ok - fm-spawn: the Deck verification opt-in launches the driver and records effort only
ok - fm-spawn: a secondmate on deck is refused
fm-deck-harness: all cases passed
```

The evidence gate compares the status log's size with its size at turn start rather than modification times: bash 3.2's `-nt` compares whole seconds, and a gate built on it refused a status line written in the same second the turn began.
Those size checks and the driver's fallback append use Python 3 descriptor-bound I/O, reject symlinks and non-regular or multiply linked files, and never touch an unsafe target.
The terminal regression drives two real `fm-send.sh` steers through tmux and proves each completed turn removes its transient busy acknowledgement before the next delivery baseline.

## Live check

The 2026-09-21 live attempt ran the real `deck` binary in a real tmux pane on macOS through proxai with route `codex/gpt-5.6-luna`.
The first turn's second model request failed immediately, with no idle gap, when proxai returned HTTP 409 `conversation_conflict`: `assistant/tool history must belong to a live conversation owned by this caller`.
The driver recorded `turn-failed` and touched the task's turn-end notification.
Tmux's `#{pane_current_command}` reported `bash`, while `ps` reported the pane's foreground process as `fm-deck-worker`, so pane liveness through the real backend remains unproven.
The attempt did not complete a first turn, same-session steer, interrupt, or clean exit, and therefore did not verify the adapter end to end.
Normal `fm-spawn.sh --harness deck` dispatch is refused; `FM_DECK_ALLOW_UNVERIFIED=1` exists only to rerun adapter verification.
A passing live check must show the brief turn completing after status evidence, a typed steer answered in the same Deck session, proven pane liveness, `Ctrl+C` returning to the prompt with an `interrupted` busy event, and `/quit` recording `session-end` before Deck may become dispatchable.
