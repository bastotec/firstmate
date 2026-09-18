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

The hub groups endpoints by the machine that owns them, and this home's name in that view comes from `FM_STREAM_MACHINE`, then `config/stream-machine`, then the hostname; it is a readable identity rather than an opaque id, so set it on any home whose hostname says nothing useful.

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

## Bridge feed

`bin/fm-stream-bridge.py` translates the hub into the Bridge UI's live wire format: one JSON record per line on stdout, one heartbeat per endpoint per tick.
It only reads the hub, holds a `subscribe` credential, opens no listening socket, and sends nothing to any worker.
Its header owns the record mapping and every field the hub cannot supply; the short version is that the hub carries no token counter, so every record is a heartbeat, and only an exit the endpoint's own agent reported becomes `Stopped` or `Failed` while everything else is `Unknown`.
When the hub cannot be read it emits nothing, so the Bridge ages every worker out as stale rather than holding a last state.

Run it on the host that runs the hub:

1. Give it its own read-only credential: add a bare token line to `config/stream-hub-tokens` and put the same token alone in a 0600 file for the adapter.
   A home still on the single `config/stream-token` has no such file, and creating one replaces that token's every-class grant, so write the home's own `publish,subscribe,control:<token>` line into it as well.
   The hub reads its token file only at start, and a hub restart strands every running worker, so make this change while no stream work is running.
2. Start it against the local hub:

   ```
   bin/fm-stream-bridge.py serve --hub http://127.0.0.1:7717 --token-file <file> --fleet-id <name>
   ```

3. To read the feed from another machine, run that same command over SSH from the reading machine and consume its stdout, which keeps the feed inside the SSH session and needs nothing listening on the hub host.
   There is no network listener for the feed.

`bin/fm-stream-bridge.py snapshot` prints one tick and exits, and `translate` replays recorded hub listings, which is how its tests drive it.
`bin/fm-stream-bridge.py compare` sets the feed's rendered state for each of this home's stream-backed tasks against `bin/fm-crew-state.sh`, and flags a worker the feed calls stopped while the pane read says it is working.
Nothing runs it automatically.

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

## Closing an endpoint whose agent does not answer

`DELETE /v1/tasks/<id>` hands the kill to the endpoint's own agent and waits for it to acknowledge.
The answer carries `delivered`: true when that agent took the kill, and false when it never answered and the hub closed only its own record.
A `delivered: false` close is not proof the worker stopped - its process lives on the worker's machine, which the hub cannot reach.
The adapter refuses such a close: `fm_backend_stream_kill` exits nonzero and says the worker may still be running.
It answers the same way to every other refusal, including `no_such_endpoint`: a hub that has forgotten an endpoint it stopped hearing from says nothing about whether that worker is still running, so a kill it cannot confirm is never reported as one it made.

One answer is a confirmed stop, and only one.
An endpoint carries `closed_by`: `agent` when its own agent reported the worker gone and brought its exit code back, and `hub` when the hub closed a record it could no longer steer.
A kill against an endpoint already closed by its agent reports success without asking again - that agent watched the worker exit, which is the best evidence there will ever be - while every other outcome, `closed_by: hub` included, reports an unconfirmed stop.
A close record moves from presumption to fact and never the reverse: a `hub` close is what the hub assumed about a worker it could not reach, so when that agent comes back and reports its own worker's exit, its report takes the record over - attribution and exit code together - and the endpoint then reads as one the agent closed.
A hub close can never take over an agent's, and it never overwrites the exit code an agent recorded, which is what keeps an unacknowledged kill from ever claiming confirmation.
Today that is where the distinction stops, because every caller of the shared `fm_backend_kill` discards its status and its stderr, so firstmate's teardown proceeds as it would after any other kill.
Making those call sites honour a refused kill is a cross-backend change and is follow-up work.

## When the hub has not heard from an agent

After ten seconds of silence - several missed heartbeats, and less than the budget an agent gives its own startup - the hub presumes that endpoint's agent is gone.
Agents are heard from on every frame, every state heartbeat, and every command poll.

A presumption is not a close, and it does exactly one thing: it frees the endpoint's label, so a spawn abandoned mid-startup does not make its task id unusable.
Everything else stays as it was.
The worker is still listed, its stream still runs, and input, status lines and kills still reach it - because a worker the hub has not heard from lately may be perfectly healthy, and if it really is gone those calls fail on their own and say so.
A state read answers `unreadable` rather than `dead` for the same reason: the hub cannot see the worker's process either way.
Staleness withholds a verdict about a live READING, though, not about a recorded one: an endpoint its own agent closed reported the worker's exit and its exit code, and that answers `dead` however long ago it was recorded.
A record the hub closed by itself is an unacknowledged kill and keeps reading `unreadable`, until and unless its own agent comes back and reports that worker's exit.
The agent's next word to the hub takes the presumption back.
Where two registrations answer to one machine and label, the contest is settled by which agent the hub has heard from, not by which record is newer: an agent that is publishing keeps the name against a record nothing stands behind, and loses it only to one the hub has heard from just as lately.
An agent that loses stands down - it stops publishing state and stops taking commands - but it does NOT stop its worker, and when that worker eventually exits it still closes its own record out.
Two records contesting one name tell the hub nothing about which holds the real work, and a worker left unsupervised can be recovered while a worker killed by mistake cannot.

Standing down protects WORK IN PROGRESS, which is the reason behind the rule rather than the rule itself: a worker mid-task holds something the captain cares about, so when the hub cannot tell which record is real, the agent goes quiet rather than destroy it.
An agent that loses the name during its own startup, before the endpoint is ready, has no work in progress to protect - nothing has been asked of that worker, the spawn has not returned, and firstmate has never learned the task exists - so keeping it alive would preserve nothing and leak a process nobody supervises and nobody can find.
That loser stops its worker and closes its own record out.
A close is a statement about the record an agent already holds rather than a claim on the identity, so nothing refuses it - not the hub's contest, not the agent's own stand-down, and not a spent startup budget: no ordering of supersession and close leaves an open endpoint with no agent behind it.
A record nothing has been heard from for the full retention period is dropped; a kill against an endpoint the hub has forgotten reports an unconfirmed stop, because by then the hub knows nothing about that worker at all.

There is one case with no way back: the agent speaks again to find another endpoint already answering to its machine and label, because the next attempt at that task claimed the name while it was out of touch.
The hub refuses that agent, and it stops rather than let two workers answer to one identity.

A hub RESTART is a different matter, and a harsher one.
Endpoints live in the hub's memory only, so a restarted hub has never heard of any of them: a running agent's next publish is refused with `no_such_endpoint`, and an agent registers exactly once and has no path back.
Every worker on every machine keeps running, invisible to the fleet listing and unsteerable, until it is dealt with on its own machine.
Re-registering a returning agent is follow-up work, not something this backend does today.

## When the hub is down

One hub means one blast radius, and it is worth being exact about its edges.

The hub owns no pseudoterminal, so it cannot take a worker with it.
While it is down, unreachable, or restarting:

- Every worker keeps running, and keeps producing output into the pty its own agent holds.
- Nothing can be watched, steered, captured, or killed through this backend, because every one of those routes is the hub.
- Every endpoint reads stale, which is `unreadable`, never `dead`.
  Supervision must not treat that as evidence a worker died, because it is evidence of nothing at all.
- Status lines are the exception, and deliberately so: they are written by each agent on its own machine, so the durable record a task reports into keeps working while the hub is gone.

A hub that was merely unreachable comes back to the same endpoints, and agents pick up where they left off.
A hub that RESTARTED comes back to none: its endpoints were in memory, so every running agent is stranded - refused with `no_such_endpoint` on its next publish, with no way to register again - and its worker goes on running unlisted and unsteerable until someone deals with it on its own machine.
Either way the terminal output produced in the meantime is gone, because the ring buffer is in memory too.

The operational shape of that is worth saying plainly.
Losing the hub costs observation across the whole fleet at once, and costs no work; restarting it costs every running worker its place in the fleet until it is restarted too.

## Limits

- Experimental, with no dedicated real-backend CI lane.
  [`tests/fm-stream-agent-live-e2e.test.sh`](../tests/fm-stream-agent-live-e2e.test.sh) is the live guard that proves each installed harness is still classified through the hub, and the command that refreshes the dated per-harness evidence in [`docs/verification/runtime-backends.md`](verification/runtime-backends.md).
  The portable regressions are `tests/fm-stream-hub.test.sh`, `tests/fm-backend-stream.test.sh`, `tests/fm-stream-agent-kill-safety.test.sh`, and `tests/fm-stream-bridge.test.sh`.
- No secondmate support.
- Scrollback is bounded by the ring buffer, so it is a live window, not a transcript.
- An unreachable agent and a dead worker are indistinguishable from the hub, so a stale read carries no liveness verdict at all.
  Only one of those two states authorizes recovery, and reporting silence as death is how a healthy worker gets torn down.
- The hub is a single point of observation, not of execution; [When the hub is down](#when-the-hub-is-down) owns that contract.
