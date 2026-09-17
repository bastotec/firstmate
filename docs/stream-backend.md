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

The hub owning no pseudoterminal is the load-bearing part of that split: it is what lets the hub fail without taking a worker with it.
[When the hub is down](#when-the-hub-is-down) owns what that does and does not cost you.

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

`bin/fm-stream.sh web` prints the browser URL for the one central subscriber view, carrying the token as a URL fragment, which a browser never sends - so the navigation to the page carries no credential.
The page's own event stream is the one request that does carry the token in a URL, because an `EventSource` cannot set a header: the hub logs nothing, but a TLS terminator or proxy in front of it logs whatever it is configured to.
`bin/fm-stream.sh tasks` lists every endpoint across every machine, and `attach` streams one endpoint to stdout.

Ordinary supervision does not need any of that.
`fm-peek.sh`, `fm-send.sh`, `fm-crew-state.sh`, and `fm-control.sh` all work against a stream-backed task through the shared dispatcher, exactly as they do for any other backend.

A task records `stream_hub=` and `stream_endpoint_id=` beside the shared `endpoint_task_id=` binding.

## Security

The hub binds `127.0.0.1` by default and every data route requires a bearer token; the static viewer page is the one exception.

Tokens are class-scoped, and there are three classes:

- `publish` registers endpoints and publishes frames. Agents hold it; nobody else needs it.
- `subscribe` reads only: list, stream, capture, screen, and state.
- `control` steers: sending input to a worker, appending a status line, and closing an endpoint.

A line of `<classes>:<token>` in `config/stream-hub-tokens` grants exactly the named classes, so an operator credential is written `subscribe,control:<token>` and a home's own client credential, which both publishes and steers, is `publish,subscribe,control:<token>`.
A bare token line grants `subscribe` alone, so the unqualified line is the read-only one.
A viewing token cannot register an endpoint, publish, or steer a worker: input, status, and close are all refused with 403.
The bundled viewer page is served without a credential - it is static, and the token it reads out of the URL fragment is what its own requests carry - but every data route behind it is authenticated, and opening it with a viewing token gives a read-only view whose send box is refused.

### The hub speaks plain HTTP

There is no TLS anywhere in this backend, and nothing in it will warn you about that.

Every byte is in the clear: the bearer token on each request, every keystroke sent to a worker, and every byte of terminal output that worker produces.
Anyone who can read the path can read all of it; anyone who can read a `publish` token can register endpoints and publish forged frames for any of them, impersonating your workers, and anyone who can read a `control` token can type into those workers and close them.

Loopback is the only setting where that is safe on its own.
Cross-machine use means an SSH tunnel or an equivalent encrypted transport, which firstmate does not create, manage, or check for; a configured `https://` hub URL means only that something in front of the hub terminates TLS, not that the hub does.
Nothing binds a public interface on your behalf, so changing `--bind` is a deliberate act - and doing it without a tunnel publishes your fleet's terminals and their control channel to that network.

Terminal content is never written to disk.
It lives only in each endpoint's bounded in-memory ring buffer, which exists so a late subscriber can catch up, and it is lost when the hub restarts.

The status return channel writes on the machine that owns the endpoint.
A status line travels as a command to that endpoint's own agent, which appends it to the local `state/<id>.status`, so the record is written where it belongs and never crosses the network as a path.

## When the hub is down

One hub means one blast radius, and it is worth being exact about its edges.

The hub owns no pseudoterminal, so it cannot take a worker with it.
While it is down, unreachable, or restarting:

- Every worker keeps running, and keeps producing output into the pty its own agent holds.
- Nothing can be watched, steered, captured, or killed through this backend, because every one of those routes is the hub.
- Every endpoint reads stale, which is `unreadable`, never `dead`.
  Supervision must not treat that as evidence a worker died, because it is evidence of nothing at all.
- Status lines are the exception, and deliberately so: they are written by each agent on its own machine, so the durable record a task reports into keeps working while the hub is gone.

When the hub returns, agents reconnect on their own and endpoints become readable again.
What does not come back is the terminal output produced in the meantime: the ring buffer is in memory, so a hub restart starts every endpoint's scrollback from empty even though the workers never stopped.

The operational shape of that is worth saying plainly.
Losing the hub costs observation across the whole fleet at once, and costs no work.

## Limits

- Experimental, with no dedicated real-backend CI lane.
  [`tests/fm-stream-agent-live-e2e.test.sh`](../tests/fm-stream-agent-live-e2e.test.sh) is the live guard that proves each installed harness is still classified through the hub, and the command that refreshes the dated per-harness evidence in [`docs/verification/runtime-backends.md`](verification/runtime-backends.md).
  The portable regressions are `tests/fm-stream-hub.test.sh`, `tests/fm-backend-stream.test.sh`, and `tests/fm-stream-agent-kill-safety.test.sh`.
- No secondmate support.
- Scrollback is bounded by the ring buffer, so it is a live window, not a transcript.
- An unreachable agent and a dead worker are indistinguishable from the hub, so a stale read carries no liveness verdict at all.
  Only one of those two states authorizes recovery, and reporting silence as death is how a healthy worker gets torn down.
- The hub is a single point of observation, not of execution; [When the hub is down](#when-the-hub-is-down) owns that contract.
