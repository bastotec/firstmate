# Verification: the Deck crewmate/scout adapter

Active empirical facts for firstmate's Deck adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/SKILL.md) owns the operating facts through [`references/harness/deck.md`](../../.agents/skills/harness-adapters/references/harness/deck.md); this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `deck 0.1.0` built from `bastotec/deck` main at `7308f21` (includes `run --hook` and the `pre_complete` hook) |
| Verified | 2026-09-21 |
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
ok - fm-deck-worker: Ctrl+C cancels the running turn and keeps the worker at its prompt
ok - liveness: the deck driver and binary are agents, unrelated names are not
ok - control, busy-source, and delivery tables carry deck's verified mechanics
ok - fm-spawn: deck launches the driver with the binary, busy gen, and model; effort recorded only
ok - fm-spawn: a secondmate on deck is refused
fm-deck-harness: all cases passed
```

The evidence gate compares the status log's size with its size at turn start rather than modification times: bash 3.2's `-nt` compares whole seconds, and a gate built on it refused a status line written in the same second the turn began.

## Live check

Pending: every model route was out of quota when the adapter landed (the proxai Codex accounts reset 2026-09-21 15:25Z and 2026-09-26 08:24Z).
The live check runs the driver in a real tmux pane against the real `deck` binary and a live gateway route and must show: the brief turn refused once by the evidence gate and then finishing after the worker appends a status line; a typed steer answered in the same Deck session; `tmux display -p '#{pane_current_command}'` naming `fm-deck-worker`; `Ctrl+C` through `tmux send-keys` returning to the prompt with an `interrupted` busy event; and `/quit` recording `session-end`.
Until that lands, treat the adapter as unverified live and dispatch real work on it only after this section records the result.
