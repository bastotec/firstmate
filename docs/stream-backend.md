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

`python3`, `curl`, and `jq` must be present, and the hub's protocol and advertised capabilities must match the adapter's requirements.
A missing dependency, an unreachable hub, a refused token, or an incompatible hub is terminal for the selected backend: it refuses and names what is wrong rather than falling back to another backend.

Run `bin/fm-stream.sh --help` for the operator commands; that help and each script's header own their exact flags.

## Watching and steering

`bin/fm-stream.sh web` prints the browser URL for the one central subscriber view, carrying the token as a URL fragment, which a browser never sends - so the navigation to the page carries no credential.
The page's own event stream is the one request that does carry the token in a URL, because an `EventSource` cannot set a header: the hub logs nothing, but a TLS terminator or proxy in front of it logs whatever it is configured to.
`bin/fm-stream.sh tasks` lists every endpoint across every machine, and `attach` streams one endpoint to stdout.

Ordinary supervision does not need any of that.
`fm-peek.sh`, `fm-send.sh`, `fm-crew-state.sh`, and `fm-control.sh` all work against a stream-backed task through the shared dispatcher, exactly as they do for any other backend.

A task records `stream_hub=` and `stream_endpoint_id=` beside the shared `endpoint_task_id=` binding.

## Bridge feed

`bin/fm-stream-bridge.py` translates the hub into the Bridge UI's live wire format: one JSON record per line on stdout, one heartbeat per worker per tick, taken from the execution the hub marks current using the same decision as its order path.
The feed only reads the hub: `serve`, `snapshot`, `translate`, and `compare` hold a `subscribe` credential, open no listening socket, and send nothing to any worker.
Writing is the adapter's other direction, a separate command with its own credential, which [Command path](#command-path) owns.
Its header owns the record mapping and every field the hub cannot supply; the short version is that the hub carries no token counter, so every record is a heartbeat, and only an exit the endpoint's own agent reported becomes `Stopped` or `Failed` while everything else is `Unknown`.
When the hub cannot be read it emits nothing.
The Bridge's clock only moves when a record arrives, so during an outage, or after a hub restart that lists no endpoints, the Bridge keeps showing each worker's last state rather than aging it out as stale.

The Bridge does not consume this feed yet.
The record format follows the ingest contract in the Bridge UI project's `docs/telemetry.md`, which lives in that project, not this one.
How the feed reaches the Mac that runs the Bridge, over an SSH tunnel or as plaintext on the LAN, is an open decision the captain owns, and nothing here wires either one.

Run it on the host that runs the hub:

1. Give it its own read-only credential: add a bare token line to `config/stream-hub-tokens` and put the same token alone in a 0600 file for `bin/fm-stream-bridge.py`.
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

## Tail adapters

The agent owns a pseudoterminal, so it can only publish a worker whose harness firstmate runs through the runtime backend.
A worker a harness runs itself - an opencode session, a Claude Code transcript - owns its own session storage, and to the hub it is invisible: no endpoint, no Bridge feed entry.
A tail adapter closes that gap from the outside: it tails the harness's on-disk session storage and publishes that session's cumulative token usage to the hub as a real endpoint, in the same wire shape the agent publishes.

`bin/fm-stream-opencode-tail.py` is the opencode one; the flags, the storage layout it reads, and the refusal posture for what it cannot measure live in its header.
The shared contract behind every tail adapter - registration, heartbeats, rejoin after a hub restart, the state record's `tail` block, the strictly increasing `seq` - is owned by `bin/fm_stream_tail_lib.py`, so two tail adapters never disagree about the wire.

What a tail adapter publishes is bounded by what the harness itself recorded:

- Counters come only from usage records the harness wrote - a message that carries a `tokens` object, for opencode - and nothing is estimated, extrapolated, or synthesized.
  A session with no usage records publishes zeros and `usage_records` 0, which is a fact about the session.
- Counters are cumulative, so a restarted adapter rescans the session and converges on the same totals with no cursor of its own.
- It owns no terminal, so the input command is refused rather than silently dropped; kill and status work as for any endpoint.

A tail adapter is pointed at one session (`--session`, or `--directory` to resolve the newest main session in a directory) and is a publisher, not a supervisor: watch it with `bin/fm-stream.sh tasks`, stop it through the hub, and expect it to exit on its own when the harness archives the session.

## Command path

The reading half of the Bridge chain is the feed above; the writing half is `bin/fm-stream-bridge.py command`.
It reads one `command` record per line on stdin - the composer's order - places it with the hub, and writes one `command_ack` or `command_nack` per line to stdout, in the same NDJSON framing the feed uses.
The adapter's header owns the three record shapes and the rule that decides every answer.

An order addresses a worker by `leaf_worker_id` - `<machine>/<label>`, the same identity the feed emits and `fm-stream.sh tasks` prints - and is bound to one execution.
The composer must name that execution in the identity block it shares with the feed.
An order aimed at an execution the leaf has moved on from is refused rather than typed into its replacement, because a "yes, go ahead" composed for one run landing in its fresh replacement is exactly the accident the binding exists to prevent.

An acknowledgement means the worker's own agent applied the order to its pseudoterminal and said so.
A hub that queued an order, or an agent that took it without answering, has not acknowledged it and may not say it did.
An order whose delivery the hub can neither confirm nor rule out produces no record at all: the command id stays visibly pending, which is the honest answer, and re-sending that command id reconciles it without placing a second order.

A `command_nack` is an authoritative membership answer, and nothing else produces one.
`no_such_worker` is the owning agent's own report that its worker ended.
`worker_not_registered` is the hub still holding no registration for the leaf after waiting out the fixed six-second window a rejoining agent needs, which is the same rejoin window the state classifier waits before it will say `missing`.
`fleet_unknown` means `fleet_id` is missing or disagrees with the adapter's own fleet id.
A refusal the hub reached no membership verdict on is a `command_ack` with `state: refused`, which says the order did not arrive without claiming anything about the worker.

Reconciliation state lives in the hub's memory, not on disk.
Recent orders are kept in a bounded journal of 512, and one an agent took but never answered stays answerable for 15 minutes, so a caller that resends its own command id gets that order's fate rather than a second delivery.
A resend arriving while the first send is still being placed - a dropped SSH transport, a reconnecting adapter - is waited out and answered from that same order, so even concurrent sends of one id type the text once.
A hub restart empties the journal along with the registry, so a resend after restart is a new order and cannot reconcile delivery from before the restart.

The credentials are separate on purpose: `command` needs a `control`-class token, the class that can type into workers, while the feed holds `subscribe` alone, so a host running only the feed cannot order anything with the credential the feed uses.
Run `command` on the host that runs the hub, reading its stdin from wherever the composer's records come from over SSH or an equivalent encrypted transport - the same open exposure decision the feed names, with a sharper edge, because this direction carries the credential that steers the fleet.

## Security

The hub binds `127.0.0.1` by default and every data route requires a bearer token; the static viewer page is the one exception.

Tokens are class-scoped, and there are three classes:

- `publish` registers endpoints and publishes frames. Agents and tail adapters hold it; nobody else needs it.
- `subscribe` reads only: list, stream, capture, screen, and state.
- `control` steers: sending input to a worker, appending a status line, closing an endpoint, and placing a leaf-addressed order.

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
That distinction now reaches every caller: an unacknowledged kill is the shared kill contract's unconfirmed result, `fm_backend_kill` in `bin/fm-backend.sh` owns it, and cleanup keeps the task's durable records rather than recording a worker as gone that nothing has stopped.

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

## When the hub restarts

Endpoints live in the hub's memory only, so a restarted hub has never heard of any of them and refuses a running agent's next publish with `no_such_endpoint`.
That refusal is what an agent registers itself again on, under the endpoint id it already held, so a worker returns to the fleet listing and to steering without anyone touching the machine it runs on.
Listed and steerable arrive together rather than one after the other, because the thread that receives steers is told the endpoint is back at the moment it comes back rather than finding out on its own schedule.
The residual is small and worth stating: the two are separate calls, so a steer aimed at the instant between a worker being listed again and its next command poll reaching the hub can still be reported undelivered, and is delivered on the retry.

This is why a kill against an endpoint the hub does not have reports an unconfirmed stop rather than a gone endpoint.
Absence from the task table is a statement about the hub's own memory, never about a process on another machine, and every worker behind those answers while a hub is restarting is still running.

The identity is the point.
The endpoint id an agent re-registers is the one the task's own records name, so its metadata binding, its steering and its status channel all keep meaning what they meant; an agent that came back under a fresh id would be listed while every record pointing at it was stranded, which is a worse outcome than staying away.
The history does not come back with it.
The ring buffer was in memory too, so the terminal output produced while the hub was gone is lost and that endpoint's scrollback starts again from the reconnect.

A worker coming back this way must not lose its identity to the replacement its own absence provoked.
Inside the restart window every stream endpoint reads unknown to the hub, so something may well start a fresh worker for the same task under the same name; registering it is not what decides the contest.
A record the hub has never heard from stands for no worker, so it takes no name from the agent that is publishing under it - the rule the hub already applied to publishing, applied to registering too, so the contest is decided by which agent speaks rather than by which one registered first.
That is a narrow protection, and worth being exact about: a replacement publishes its own first state frame immediately after registering, so the interval in which it stands for nothing at all is the gap between those two calls.
Past it, the recovering agent is the one refused - correctly, because by then two workers really do answer to one name and the one the hub has heard from is the one it can account for.
Readers on this side wait that window out rather than call the worker gone: a hub 404 has to keep being the answer for longer than a re-registration takes before it is reported as `missing`, because inside it the endpoint is about to exist again and a steer dropped there is a steer dropped on a healthy worker.
The cheap presence probe behind capture, current-path and input answers from the first reply and keeps paying nothing for the window, so it is the steering paths that ask again; the fleet listing, which an operator reads once, takes its endpoint verdict from the classifier instead, and reports a rejoin in flight as unknown rather than absent.
What that window covers is one rejoin attempt, not the whole recovery: it is sized against the first attempt an agent makes after a restart, because the read is itself bounded by the caller that asks for it and there is no room to sit through the backoff ladder as well.
An agent whose first attempt met a hub that was not ready yet waits out its own backoff, and for that stretch a healthy worker on its way back is reported `missing` - supervision treats that like a dead worker and escalates the pending steer, which takes that steer off the delivery ladder rather than ringing it again.

`no_such_endpoint` is the only thing an agent acts on here, and only the hub states it.
A failed connection is not that, and is never treated as it: a hub on its way back up passes through exactly that state, and a returning hub that still holds the record must not be re-registered against.
An agent finds out through its own publishing, so an endpoint with nothing to say comes back on its state heartbeat rather than waiting for its worker to print something.

Attempts are paced rather than repeated.
One restart strands every agent in the fleet at once, so an agent leaves at least a couple of seconds between attempts, backs further off while the hub cannot take it back, and spreads the wait by a random margin so the fleet does not return in one burst against a hub that has only just come up.
A registration the hub takes ends the widening and the wait behind it together, so a hub that forgets the same endpoint again a moment later - a second restart, or a hub taking registrations while it still refuses frames - is met at that couple of seconds rather than at the wait the outage before it had grown.
A worker whose own process ended while the hub was down is recovered the same way and on the same terms: if the hub is back by the time its agent posts the closing frame, the agent takes the identity back in order to deliver it, so the task's end and its exit code land under the id that names them rather than being lost with the record that was meant to hold them.
Its closing frame is the one thing the pace does not apply to: pacing exists to stop an agent asking again and again, and a closing frame is the last call that agent will ever make, so it takes its one attempt whether or not the wait from an earlier attempt has run out.
That is the whole of the licence. It is one attempt on ordinary timeouts, and an agent whose hub is still down exits rather than holding its teardown open.
The single thing it does wait for is a recovery already in flight on another of the agent's own threads, and only for a few seconds: a heartbeat that met the same forgotten endpoint holds the agent's registration to itself for one round trip, and a closing frame that gave up there would be dropped for good rather than retried.

One answer ends the attempts instead of continuing them, and only one.
An agent that comes back to find another endpoint already answering to its machine and label stands down exactly as it would have anywhere else, because two workers behind one identity is the outcome worse than any lost endpoint.
Everything else the hub can say is kept, including a credential it will not take: the hub reads its tokens once at startup, so a hub that came back with the wrong token file refuses the whole fleet at once, and an agent that treated that as settled would strand every worker permanently over a condition that ends the moment the hub is restarted correctly.
So a refusal that is not a lost name is waited out on the same backoff as an unreachable hub, and the worker is there when the hub is right again.
In either case the worker itself is left running and untouched, because a refused agent says nothing at all about the work its worker is in the middle of.

## Retiring a record no backend can answer for

Cleanup removes a task's durable records only once a backend has proved the worker stopped, and `--force` does not lift that: it authorizes discarding unlanded WORK, never asserting a stop nobody observed.
A hub restart leaves records in exactly that state - the hub has never heard of the endpoint, a kill against it reports an unconfirmed stop, and no later read can change that answer - so cleanup refuses every time and the record would stay forever.

`bin/fm-retire-endpoint.sh <task-id> [<task-id>...]` is the one way such a record is retired, and only a human runs it.
Nothing in firstmate invokes it, and it names each id exactly - wildcards and all-records forms are refused - then asks you to type those ids back before anything is written.

By naming a record you assert, from your own inspection of the machine that ran it, that no worker is still running behind it.
That is the hub-unanswerable condition: the backend that owned the worker can no longer say anything about it, so no read will ever settle the question.
Your username and the time are recorded with the assertion: every run appends one line to `state/endpoint-retirements.log` recording that a named person asserted, at a named time, that a named record should be retired, and whether the runtime-refusal override was used.
That line is written before anything is removed, and a run whose line cannot be appended retires nothing - a record is never removed without a durable author.
Because it is written first, cleanup can still refuse afterwards and retire nothing: each line records the assertion that was made, not an outcome, and no outcome is written back to it.

What it touches, and what it does not:

- It retires RECORDS: the durable task record and, where firstmate owns the transition, the task's backlog row.
  A home whose backlog is kept manually, or which keeps no backlog file, has its row left exactly as the operator keeps it.
- Cleanup runs first and finishes the job properly whenever its own gates allow.
  The first of two refusals the retirement proceeds past is cleanup's work-protection gate, which refuses before anything on disk has been touched.
  In that case the worktree, any uncommitted work in it, the task branch and the task's data are left byte-untouched and named in the output, for you to deal with under your own authority.
  It never discards work and never passes `--force` to anything.
- The second is cleanup's unconfirmed-kill gate, and it is the command's honest cost: the records are retired even for an endpoint the backend still reports present after its kill, with no further flag, on your assertion alone.
  Cleanup cannot tell you which case you are in - a backend answering "still there" and a backend that cannot answer at all reach it as the same unconfirmed verdict, so its warning claims neither and says only that the endpoint was never confirmed gone.
  A worker may still be running behind a record retired that way, and stopping it is yours to do.
- Every other cleanup refusal stands and nothing is retired - an outcome that has not reached the parent channel, a backlog transition that cannot be replayed.
  The one exception is a cleanup that fails only after it has already removed the durable task record: the run reports that partial state, naming the record that is gone and the pending close left behind, instead of claiming nothing was retired.

`--override-runtime-refusal` additionally proceeds past a RUNTIME's own refusal to answer for the endpoint - a herdr server that cannot be reached at all, for instance.
Without the flag that refusal stands and nothing is retired; with it, the override is recorded alongside the retirement with your name and the time.

The command is not stream-specific, but the stream hub's restart behavior above is the condition it exists for.

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
A hub that RESTARTED comes back to none, and each agent registers its own endpoint again; [When the hub restarts](#when-the-hub-restarts) owns what that recovers and what it does not.
Either way the terminal output produced in the meantime is gone, because the ring buffer is in memory too.

The operational shape of that is worth saying plainly.
Losing the hub costs observation across the whole fleet at once, and costs no work.

## Limits

- Experimental, with no dedicated real-backend CI lane.
  [`tests/fm-stream-agent-live-e2e.test.sh`](../tests/fm-stream-agent-live-e2e.test.sh) is the live guard that proves each installed harness is still classified through the hub, and the command that refreshes the dated per-harness evidence in [`docs/verification/runtime-backends.md`](verification/runtime-backends.md).
  The portable regressions are `tests/fm-stream-hub.test.sh`, `tests/fm-backend-stream.test.sh`, `tests/fm-stream-agent-kill-safety.test.sh`, `tests/fm-stream-bridge.test.sh`, and `tests/fm-stream-opencode-tail.test.sh`.
- No secondmate support.
- Scrollback is bounded by the ring buffer, so it is a live window, not a transcript.
- An unreachable agent and a dead worker are indistinguishable from the hub, so a stale read carries no liveness verdict at all.
  Only one of those two states authorizes recovery, and reporting silence as death is how a healthy worker gets torn down.
- The hub is a single point of observation, not of execution; [When the hub is down](#when-the-hub-is-down) owns that contract.
