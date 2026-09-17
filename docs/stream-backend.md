# Stream backend

The stream backend puts every task's live terminal output on one central hub, so a single place can watch workers on any machine and talk to them.
It is experimental, explicit-only, and never auto-detected.

[`docs/configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns backend selection, task-selector resolution, and the metadata contract that every backend shares.
This document owns setup, security, and the limits specific to stream.

## What it is

Three pieces, and the split matters:

- **The hub** (`bin/fm-stream-hub.py`) is one service for the whole fleet, and it owns no pseudoterminal.
  It holds a bounded ring buffer per endpoint, relays commands, and answers state reads.
- **The agent** (`bin/fm-stream-agent.py`) runs on the machine that runs the task and owns that task's pseudoterminal.
  One agent owns one endpoint.
- **The adapter** (`bin/backends/stream.sh`) is the runtime backend firstmate drives through the shared dispatcher.

The hub owning no pseudoterminal is what makes a worker survive it.
Stopping the hub, restarting it, or losing the network to it leaves every worker running, because the pty is held by the agent beside it.
Supervision goes blind until the hub returns; the work does not stop.

## Setup

The fleet runs one hub.
Start it on whichever host the fleet can reach:

```
bin/fm-stream.sh hub start
bin/fm-stream.sh status
```

Every other home points at that hub rather than starting its own, by writing its base URL to `config/stream-hub` or exporting `FM_STREAM_HUB`.
Resolution order is `FM_STREAM_HUB`, then `config/stream-hub`, then a hub this home started itself, then `http://127.0.0.1:7717`.
The locally started hub ranks below both configured sources, so a home pointed at the fleet's hub keeps using it even while running a hub of its own; it ranks above the default so that starting a hub on a non-default port does not leave every other command resolving a port nothing bound.

Select the backend the way any explicit backend is selected: `config/backend`, `FM_BACKEND=stream`, or an explicit per-task request.
It is never auto-detected, and a spawn refuses `--secondmate` until secondmate launch semantics are designed for it.

`python3`, `curl`, and `jq` must be present, and the hub's protocol must match the adapter's.
A missing dependency, an unreachable hub, a refused token, or a protocol mismatch is terminal for the selected backend: it refuses and names what is wrong rather than falling back to another backend.

Run `bin/fm-stream.sh --help` for the operator commands; that help and each script's header own their exact flags.

## Watching and steering

`bin/fm-stream.sh web` prints the browser URL for the one central subscriber view, carrying the token as a URL fragment so it never reaches the server's log.
`bin/fm-stream.sh tasks` lists every endpoint across every machine, and `attach` streams one endpoint to stdout.

Ordinary supervision does not need any of that.
`fm-peek.sh`, `fm-send.sh`, `fm-crew-state.sh`, and `fm-control.sh` all work against a stream-backed task through the shared dispatcher, exactly as they do for any other backend.

A task records `stream_hub=` and `stream_endpoint_id=` beside the shared `endpoint_task_id=` binding.

## Security

The hub binds `127.0.0.1` by default and every route requires a bearer token.

Tokens are class-scoped.
A line of `<classes>:<token>` in `config/stream-hub-tokens` grants exactly the named classes, where `publish` may register endpoints and publish frames and `subscribe` may only watch.
A bare token line grants viewing alone.
A viewing token cannot register an endpoint, publish, or steer a worker.

Cross-machine publishing is expected to ride an SSH tunnel, which firstmate does not create or manage for you.
Nothing binds a public interface on your behalf; changing `--bind` is a deliberate act, and doing so without a tunnel or equivalent puts terminal contents and steering on the network.

Terminal content is never written to disk.
It lives only in each endpoint's bounded in-memory ring buffer, which exists so a late subscriber can catch up, and it is lost when the hub restarts.

The status return channel writes on the machine that owns the endpoint.
A status line travels as a command to that endpoint's own agent, which appends it to the local `state/<id>.status`, so the record is written where it belongs and never crosses the network as a path.

## Limits

- Experimental, with no dedicated real-backend CI lane.
  [`tests/fm-stream-agent-live-e2e.test.sh`](../tests/fm-stream-agent-live-e2e.test.sh) is the live guard that proves each installed harness is still classified through the hub, and the command that refreshes the dated per-harness evidence in [`docs/verification/runtime-backends.md`](verification/runtime-backends.md).
  The portable regressions are `tests/fm-stream-hub.test.sh`, `tests/fm-backend-stream.test.sh`, and `tests/fm-stream-agent-kill-safety.test.sh`.
- No secondmate support.
- Scrollback is bounded by the ring buffer, so it is a live window, not a transcript.
- An unreachable agent and a dead worker are indistinguishable from the hub, so a stale read carries no liveness verdict at all.
  Only one of those two states authorizes recovery, and reporting silence as death is how a healthy worker gets torn down.
- The hub is a single point of observation, not of execution.
  While it is down, workers keep working and nothing can watch or steer them.
