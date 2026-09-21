# Deck

Deck (`bastotec/deck`) is a headless Rust coding agent: `deck run "<prompt>"` streams NDJSON events on stdout and exits when the model finishes.
Firstmate runs it through its own pane driver, `../../../../../bin/fm-deck-worker.sh`, whose header owns the driver's behavior.
Verified as a CREWMATE and SCOUT adapter only; `../../../../../bin/fm-spawn.sh` refuses a secondmate launch on it because the driver supervises one task, not a home.
`../../../../../docs/verification/deck.md` owns how every fact below was established and what is still unproven.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute `deck` from `PATH`, refused if absent; built from `bastotec/deck` with `cargo build --release --locked`. The spawn also refuses when `jq` is missing, because the driver renders Deck's events with it. |
| Launch | `bash -c 'exec -a fm-deck-worker bash "$@"' fm-deck-worker bin/fm-deck-worker.sh --id <task> --state <state> --gen <busy-gen> --turnend <file> --deck <binary> [--model <route>] -- <brief>`. The brief is the first turn. |
| Turns | Every line typed at the driver's `❯` prompt is the next turn of the SAME Deck session (`--session`), so a steer or the steering-inbox doorbell keeps the conversation's context. |
| Endpoint | Deck's own settings (`PROXAI_BASE_URL`, `PROXAI_MODEL`, `PROXAI_API_KEY_FILE`); with no key variable set the driver uses `~/.config/proxai/client.key`. The default base URL is the local proxai gateway. |
| Model | `--model <route>` with a gateway route such as `codex/gpt-5.6-luna`, passed to every turn. No local catalog check: the gateway answers an unknown route with an error on the first turn. |
| Effort | Deck has no effort control, so effort is recorded in task metadata and omitted. |
| Per-turn bounds | `--max-turns` 200 and `--deadline-secs` 3600 by default (`FM_DECK_MAX_TURNS`, `FM_DECK_DEADLINE_SECS`); Deck's own defaults are sized for one question. |
| Busy state | Semantic source `deck-wrapper`: the driver writes busy at turn start and idle at turn end, failure, interrupt, and `/quit` through `bin/fm-busy-event.sh`; the spawn arms the task's busy gen and passes it in. |
| Progress | Deck's `post_tool_use` hook refreshes the task's progress marker on every tool call. |
| Turn end | The driver touches the task's turn-end notification after every turn. |
| Evidence gate | Deck's `pre_complete` hook refuses a turn that did not grow the task's status log, feeding the reason back to the model; after Deck's bounded refusals the turn fails instead of finishing. |
| Rendered tail | The driver prints `⛵ deck working - ctrl+c to stop` when a submitted line starts a turn (the delivery acknowledgement token), the turn's text and tool calls, then `── turn finished` or `✗ turn failed`, and the `❯` prompt. |
| Interrupt | `Ctrl+C`: the whole pane group gets SIGINT, Deck stops, the driver prints `Interrupted.`, records idle, and returns to its prompt. No clear key. |
| Exit | `/quit`, one Enter; the driver records session-end and exits, leaving the pane's shell. |
| Skill | No slash-skill form; use natural language. Deck reads the worktree's `AGENTS.md` chain and `.agents/skills` itself. |
| Autonomy | Deck runs tools without approval prompts; guards are `pre_tool_use` hooks, none of which Firstmate adds. |
| Marker | None; detection is by ancestry (`deck`, or the driver's argv[0] `fm-deck-worker`). |
| Resume | Deterministic relaunch; the driver starts a new Deck session from the brief on disk. |

## Detection and liveness

`../../../../../bin/fm-harness.sh` names `deck` from the anchored process names `deck` and `fm-deck-worker`.
Pane liveness (`../../../../../bin/fm-agent-process-lib.sh`) reads both as an agent: the driver is a bash script, so it is launched with argv[0] `fm-deck-worker`, which is also its macOS process name, and would otherwise read as an idle shell.

## Credential precondition

Deck needs a key its gateway accepts, and the route must have quota.
A missing key fails the first turn with Deck's own error in the pane; a quota refusal fails the turn with the gateway's error.
Treat either as a credential or quota blocker under `../../../../../AGENTS.md` section 9 rather than steering the pane.

## Primary integration

Unsupported: no supervision protocol exists for Deck, and the driver has no watcher arming.
`references/common/primary-hooks.md`'s unsupported-boundary rule applies.
