# Verification: the Deck crewmate/scout adapter

Active empirical facts for firstmate's Deck adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/deck.md`](../../.agents/skills/harness-adapters/references/harness/deck.md); this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `deck 0.1.0` built from `bastotec/deck` main at `7308f21` (includes `run --hook` and the `pre_complete` hook) |
| Checked | 2026-09-22 |
| Status | Portable fixes pass; a passing live rerun is still required |
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
ok - control, busy-source, and delivery tables carry deck's implemented mechanics
ok - fm-spawn: Deck refuses ordinary dispatch until live verification
ok - fm-spawn: the Deck verification opt-in launches the driver and records effort only
ok - fm-spawn: a secondmate on deck is refused
fm-deck-harness: all cases passed
```

The evidence gate snapshots the status log's byte offset at turn start and searches a bounded appended suffix for a complete `done`, `needs-decision`, `blocked`, `failed`, or `working` line.
Firstmate-owned bookkeeping lines such as `resolved:` and `note:` do not satisfy the gate or the driver's postcondition.
Those reads, the driver's fallback append, and turn-end publication use Python 3 descriptor-bound I/O, reject symlinks and non-regular or multiply linked files, and never touch an unsafe target.
The terminal regression drives two real `fm-send.sh` steers through tmux and proves each completed turn removes its transient busy acknowledgement before the next delivery baseline.

## Live check

The 2026-09-22 live check ran `deck 0.1.0` at `7308f21` in a real tmux pane on macOS through proxai with route `codex/gpt-5.6-sol`.
The brief turn answered and appended its worker-status line.
A steer typed at the prompt was answered from the same Deck session and recalled the earlier word.
The `pre_complete` gate refused completion once with `completion_blocked` attempt 1, after which the worker appended its status line and Deck finished.
Deck wrote a stderr line immediately before that event, and the driver merged it into the NDJSON pipe, so the refusal did not render and the wrapper recorded `turn-failed` despite Deck finishing.
`Ctrl+C` sent through tmux returned the driver to its prompt with busy event `interrupted`, and `/quit` recorded `session-end`.
Tmux's `#{pane_current_command}` reported `bash` on macOS because it reads the kernel executable name, while `ps -o comm=` carried argv[0] `fm-deck-worker`.
The liveness check therefore uses the foreground process identity from `ps`, not `#{pane_current_command}` alone.
This round keeps Deck stderr outside the NDJSON event pipe and classifies a bare `fm-deck-worker` argv0 directly, with portable regressions for stderr before `completion_blocked` and Linux's `comm=bash` plus argv0 pair.
Those driver defects are fixed, but the adapter remains unverified until a live rerun passes on the fixed driver.
Normal `fm-spawn.sh --harness deck` dispatch and dispatch-profile selection remain refused; `FM_DECK_ALLOW_UNVERIFIED=1` exists only for that rerun.
The follow-up round that records the passing rerun will lift the crewmate/scout dispatch gate; Deck secondmates remain unsupported.
