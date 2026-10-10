# Deck

Deck (`bastotec/deck`) is a Rust coding agent with headless `run` and interactive `chat` surfaces.
Firstmate runs workers through its own pane driver, `../../../../../bin/fm-deck-worker.sh`, whose header owns the driver's behavior.
Deck supports crewmates, scouts, persistent secondmates, and the primary.
The stable `run` driver uses `--secondmate` for secondmates; [`bin/fm-deck-chat.sh`](../../../../../bin/fm-deck-chat.sh) owns the primary chat host.
`../../../../../docs/verification/deck.md` owns the worker and secondmate live evidence.

## Pane-driver operating facts

| Fact | Value |
|---|---|
| Binary | Absolute `deck` from `PATH`, refused if absent; built from `bastotec/deck` with `cargo build --release --locked`. The spawn also refuses when `jq` or Python 3 is missing, because the driver renders Deck's events with `jq` and performs descriptor-bound status I/O with Python. |
| Launch | `bash -c 'exec -a fm-deck-worker bash "$@"' fm-deck-worker bin/fm-deck-worker.sh --id <task> --state <state> --gen <busy-gen> --deck <binary> [--model <route>] -- <brief>`. The brief is the first turn, and the ordinary worker driver derives the turn-end signal as `<state>/<task>.turn-ended`. |
| Turns | Every line the driver submits at its `❯` prompt is the next turn of the SAME Deck session (`--session`), so a steer or the steering-inbox doorbell keeps the conversation's context; the control plane's composer-clear line carrying the Ctrl+U clear byte is consumed by the driver instead of submitted (its header owns the composer contract). |
| Endpoint | Deck's own settings (`PROXAI_BASE_URL`, `PROXAI_MODEL`, `PROXAI_API_KEY_FILE`); with no key variable set the driver uses `~/.config/proxai/client.key`. The default base URL is the local proxai gateway. |
| Model | `--model <route>` with a gateway route such as `codex/gpt-5.6-luna`, passed to every turn. No local catalog check: the gateway answers an unknown route with an error on the first turn. |
| Effort | [Harness support](../../../../../docs/configuration.md#harness-support) owns spawn-side effort restrictions; [Turn effort](../../../../../docs/configuration.md#turn-effort-configeffort-policyjson) owns the separate supervisor watcher-turn policy. |
| Per-turn bounds | `--max-turns` 200 and `--deadline-secs` 3600 by default (`FM_DECK_MAX_TURNS`, `FM_DECK_DEADLINE_SECS`); Deck's own defaults are sized for one question. |
| Busy state | Semantic source `deck-wrapper`: the driver writes busy at turn start and idle at turn end, failure, interrupt, and `/quit` through `bin/fm-busy-event.sh`; the spawn arms the task's busy gen and passes it in. A refused write emits the helper's underlying diagnostic in the pane and appends it to a `failed:` status line before the driver exits. |
| Progress | Deck's `post_tool_use` hook refreshes the task's progress marker on every tool call. A refused refresh emits the helper's underlying diagnostic in the pane, appends it to a `failed:` status line, and fails the turn. |
| Turn end | Before publishing an ordinary worker's task turn-end notification, the driver requires a new `done`, `needs-decision`, `blocked`, `failed`, or `working` status line and safely appends `failed: deck turn ended without a status line (<event>)` when one is absent; status I/O and turn-end publication reject symlinks, non-regular files, and hard links. Secondmate turns do not publish parent turn-end notifications; failures use parent status. |
| Pipeline wake | See [the driver header](../../../../../bin/fm-deck-worker.sh) for the ordinary ship-worker idle-prompt wake contract and its polling controls. |
| Evidence gate | Deck's `pre_complete` hook requires the same worker-status line after the turn-start byte offset, so Firstmate-owned bookkeeping such as `resolved:` and `note:` does not count; the driver's postcondition also covers provider failure, exhausted refusal, and interrupt paths that end outside that hook. |
| Delivery | The submit path requires a pre-Enter `state=idle source=deck-wrapper` baseline and confirms Deck only when exactly the next sequence is `state=busy source=deck-wrapper event=turn-start`; rendered model output is never delivery evidence. The driver still renders a transient `⛵ deck working - ctrl+c to stop` row, then replaces it with the final turn output and the `❯` prompt. |
| Interrupt | `Ctrl+C`: the whole pane group gets SIGINT, Deck stops, the driver prints `Interrupted.`, records idle, and returns to its prompt. No clear key. |
| Exit | `/quit`, one Enter; the driver records session-end and exits, leaving the pane's shell. Control-plane exit and either relaunch path also prove task-bound residual drivers stopped by matching the physical state path, signaling the driver and Deck itself, waiting boundedly for the isolated process group to exit, and escalating survivors to KILL before replacement. Deck 0.1.0 exits immediately on TERM, so this cleanup can interrupt an active in-process tool. |
| Skill | No slash-skill form; use natural language. Deck reads the worktree's `AGENTS.md` chain and `.agents/skills` itself. |
| Autonomy | See [Harness support](../../../../../docs/configuration.md#harness-support) for the tool-approval posture; [the state-reader header](../../../../../bin/fm-crew-state.sh) owns the non-guard validation-observation hooks. |
| Marker | None; see Detection and liveness below. |
| Resume | Deterministic relaunch; the driver starts a new Deck session from the brief on disk. |

## Detection and liveness

`../../../../../bin/fm-harness.sh` owns anchored ancestry detection for the Deck binary, pane driver and chat host, including the chat host's exact `fm-deck-chat` argv[0] before Deck starts.
Pane liveness (`../../../../../bin/fm-agent-process-lib.sh`) reads the Deck binary and pane driver as agents: the driver is a bash script, so it is launched with argv[0] `fm-deck-worker`, which is also its macOS process name, and would otherwise read as an idle shell.

## Credential precondition

A Deck worker needs a key its gateway accepts, and the route must have quota.
A missing key fails the first turn with Deck's own error in the pane; a quota refusal fails the turn with the gateway's error.

## Primary integration

Persistent secondmates and Deck chat primaries use `../../../../../docs/supervision-protocols/deck.md`.
A Deck secondmate uses the same persistent driver and durable inbox wake path on every backend that hosts secondmates; [runtime configuration](../../../../../docs/configuration.md#runtime-backend-configbackend--fm_backend) and [remote placement](../../../../../docs/remote-secondmates.md) own the supported backend choices.
The driver header owns startup, lock lifetime, watcher wake turns, and the supervisor-specific completion postcondition.
The `run` driver refuses daemon-owned away/quiet mode (`state/.afk`) rather than competing with a daemon; clear that posture through the owning supervisor before relaunch.
The chat host has a different handoff, owned by [its header](../../../../../bin/fm-deck-chat.sh).
