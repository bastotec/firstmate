# Deck

Deck (`bastotec/deck`) is a headless Rust coding agent: `deck run "<prompt>"` streams NDJSON events on stdout and exits when the model finishes.
Firstmate runs it through its own pane driver, `../../../../../bin/fm-deck-worker.sh`, whose header owns the driver's behavior.
Deck is verified for crewmates and scouts; `../../../../../bin/fm-spawn.sh` still refuses a secondmate because the driver supervises one task rather than a home.
`../../../../../docs/verification/deck.md` owns how every fact below was established.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute `deck` from `PATH`, refused if absent; built from `bastotec/deck` with `cargo build --release --locked`. The spawn also refuses when `jq` or Python 3 is missing, because the driver renders Deck's events with `jq` and performs descriptor-bound status I/O with Python. |
| Launch | `bash -c 'exec -a fm-deck-worker bash "$@"' fm-deck-worker bin/fm-deck-worker.sh --id <task> --state <state> --gen <busy-gen> --deck <binary> [--model <route>] -- <brief>`. The brief is the first turn, and the driver derives the turn-end signal as `<state>/<task>.turn-ended`. |
| Turns | Every line typed at the driver's `❯` prompt is the next turn of the SAME Deck session (`--session`), so a steer or the steering-inbox doorbell keeps the conversation's context. |
| Endpoint | Deck's own settings (`PROXAI_BASE_URL`, `PROXAI_MODEL`, `PROXAI_API_KEY_FILE`); with no key variable set the driver uses `~/.config/proxai/client.key`. The default base URL is the local proxai gateway. |
| Model | `--model <route>` with a gateway route such as `codex/gpt-5.6-luna`, passed to every turn. No local catalog check: the gateway answers an unknown route with an error on the first turn. |
| Effort | Deck has no effort control. Dispatch validation rejects Deck profiles with effort, spawn refuses a non-default `--effort` before launch and task metadata, and relaunch refuses it before stopping the current worker. |
| Per-turn bounds | `--max-turns` 200 and `--deadline-secs` 3600 by default (`FM_DECK_MAX_TURNS`, `FM_DECK_DEADLINE_SECS`); Deck's own defaults are sized for one question. |
| Busy state | Semantic source `deck-wrapper`: the driver writes busy at turn start and idle at turn end, failure, interrupt, and `/quit` through `bin/fm-busy-event.sh`; the spawn arms the task's busy gen and passes it in. A refused write emits the helper's underlying diagnostic in the pane and appends it to a `failed:` status line before the driver exits. |
| Progress | Deck's `post_tool_use` hook refreshes the task's progress marker on every tool call. A refused refresh emits the helper's underlying diagnostic in the pane, appends it to a `failed:` status line, and fails the turn. |
| Turn end | Before publishing the task's turn-end notification, the driver requires a new `done`, `needs-decision`, `blocked`, `failed`, or `working` status line and safely appends `failed: deck turn ended without a status line (<event>)` when one is absent; status I/O and turn-end publication reject symlinks, non-regular files, and hard links. |
| Evidence gate | Deck's `pre_complete` hook requires the same worker-status line after the turn-start byte offset, so Firstmate-owned bookkeeping such as `resolved:` and `note:` does not count; the driver's postcondition also covers provider failure, exhausted refusal, and interrupt paths that end outside that hook. |
| Delivery | The submit path requires a pre-Enter `state=idle source=deck-wrapper` baseline and confirms Deck only when exactly the next sequence is `state=busy source=deck-wrapper event=turn-start`; rendered model output is never delivery evidence. The driver still renders a transient `⛵ deck working - ctrl+c to stop` row, then replaces it with the final turn output and the `❯` prompt. |
| Interrupt | `Ctrl+C`: the whole pane group gets SIGINT, Deck stops, the driver prints `Interrupted.`, records idle, and returns to its prompt. No clear key. |
| Exit | `/quit`, one Enter; the driver records session-end and exits, leaving the pane's shell. Control-plane exit and either relaunch path also prove task-bound residual drivers stopped by matching the physical state path, signaling the driver and Deck itself, waiting boundedly for the isolated process group to exit, and escalating survivors to KILL before replacement. Deck 0.1.0 exits immediately on TERM, so this cleanup can interrupt an active in-process tool. |
| Skill | No slash-skill form; use natural language. Deck reads the worktree's `AGENTS.md` chain and `.agents/skills` itself. |
| Autonomy | Deck runs tools without approval prompts; guards are `pre_tool_use` hooks, none of which Firstmate adds. |
| Marker | None; detection is by ancestry (`deck`, or the driver's argv[0] `fm-deck-worker`). |
| Resume | Deterministic relaunch; the driver starts a new Deck session from the brief on disk. |

## Detection and liveness

`../../../../../bin/fm-harness.sh` names `deck` from the anchored process names `deck` and `fm-deck-worker`.
Pane liveness (`../../../../../bin/fm-agent-process-lib.sh`) reads both as an agent: the driver is a bash script, so it is launched with argv[0] `fm-deck-worker`, which is also its macOS process name, and would otherwise read as an idle shell.

## Credential precondition

A Deck worker needs a key its gateway accepts, and the route must have quota.
A missing key fails the first turn with Deck's own error in the pane; a quota refusal fails the turn with the gateway's error.

## Primary integration

Unsupported: no supervision protocol exists for Deck, and the driver has no watcher arming.
`references/common/primary-hooks.md`'s unsupported-boundary rule applies.
