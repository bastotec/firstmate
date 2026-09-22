# Verification: the Deck crewmate/scout adapter

Active empirical facts for firstmate's Deck adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/deck.md`](../../.agents/skills/harness-adapters/references/harness/deck.md); this record owns how they were established.

## Subject

| Field | Value |
|---|---|
| Version | `deck 0.1.0` built from `bastotec/deck` main at `7308f21` (includes `run --hook` and the `pre_complete` hook) |
| Checked | 2026-09-22T08:31Z |
| Firstmate commit | `641dc7fe` |
| Status | Verified for crewmate and scout dispatch; secondmates unsupported |
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
ok - fm-spawn: ordinary Deck dispatch launches the driver and records effort only
ok - fm-spawn: a secondmate on deck is refused
fm-deck-harness: all cases passed
```

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
These results verify ordinary Deck crewmate and scout dispatch; Deck secondmates remain unsupported.
