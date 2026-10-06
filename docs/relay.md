# Relay

Relay lets a firstmate home answer public mentions and act on normal reversible mention requests through firstmate's normal lifecycle.
It covers `@myfirstmate` mentions on X and mentions of the myfirstmate bot in a Discord server where it is installed.
Both surfaces share one opt-in, one pairing token, one relay poll, and one reply path, so everything below applies to both unless a line names a platform.

## Opt-in and safety

Relay is off unless the home's gitignored `.env` contains a non-empty `FMX_PAIRING_TOKEN`.
The pairing token both identifies the relay tenant and records opt-in consent for autonomous public replies and eligible lifecycle actions.
Destructive, irreversible, or security-sensitive asks are flagged for trusted-channel confirmation instead of being executed from a public mention.
The relay uses owner-only routing: a mention delivered to a home is from that home's owner/captain, while its surrounding conversation context may still include other public accounts.
`FMX_RELAY_URL` is optional and defaults to `https://myfirstmate.io`, mainly for developers pointing at a local relay.
For direct client invocations, environment values override `.env`, and `FMX_ENV_FILE` can point them at another `.env`-style file.
Bootstrap activation still keys off the home's own `.env`, so watcher artifacts stay explicit local opt-in state.

To turn it on:

1. Sign in at [myfirstmate.io](https://myfirstmate.io) with X or Discord.
2. For Discord, use the dashboard's install link to add the myfirstmate bot to a server you administer; X needs no install step.
3. Copy the pairing token from the dashboard into this home's gitignored `.env` as `FMX_PAIRING_TOKEN=<token>`.
4. Start a new firstmate session so bootstrap picks the token up, then mention `@myfirstmate` on X or mention the bot in a server where it is installed.

The dashboard owns account creation, identity linking, bot installation, and token issuance; this document owns only what the local home does with the token.

## Poll cadence and generated state

The locked session-start bootstrap step turns the token into local generated state: `state/x-watch.check.sh`, a byte-static identity shim for `bin/fm-x-poll.sh`, and `config/x-mode.env`, which exports `FM_CHECK_INTERVAL=30` for watcher processes in that home.
The watcher accepts the shim only when its bytes match the expected generated content, then invokes the trusted repository poll script directly instead of executing state-file source.
This section is the single owner of the Relay cadence contract: a Relay home polls every 30 seconds instead of the default 300, only a Relay home speeds up because a non-Relay home has no `config/x-mode.env`, and the session-start supervision block includes the cadence instruction when that file exists.
The deck supervision protocol owns how that sourced cadence reaches the watcher process.
Because `bin/fm-watch.sh` reads `FM_CHECK_INTERVAL` only at process start, a cadence change (opt-in while a watcher runs, or opt-out) is applied by restarting the home-scoped watcher through the emitted protocol; bootstrap never restarts the watcher itself.
While the away-mode daemon owns the watcher, the default cadence applies.
When the token is removed or empty, the next locked bootstrap removes those artifacts; steady-state off is silent and writes nothing.
Homes without the generated artifacts keep the default watcher cadence and never run the Relay poll.
Request handling stays in the Relay `bin/fm-x-*.sh` scripts and the `fmx-respond` skill.

## Mention payload

`bin/fm-x-poll.sh` calls `GET /connector/poll` with `Authorization: Bearer <FMX_PAIRING_TOKEN>`; its header owns the per-response behavior.
A newly offered mention with non-empty `text` is stored at `state/x-inbox/<request_id>.json` and wakes firstmate exactly once with `x-mention <request_id>`.
The poll atomically claims `state/x-context/<request_id>.offered.json` before that wake, so later offers of the same request stay silent even after the inbox is drained.
Offer markers share the context registry's bounded seven-day retention, so a lost or expired marker lets a relay offer wake firstmate again.
Auth or config problems, and a failed offer claim, are each reported once as an `x-mode-error ...` line until recovery.

This section owns the payload wire contract.
The full relay object is preserved, including `in_reply_to: {author_handle, text}` for a reply in a conversation or `null` for a fresh mention.
It may also carry `in_reply_to_chain`, an optional oldest-first transcript of entries shaped `{author_handle, text, unavailable, images, attachments}` plus an optional `kind` of `reply`, `thread_starter`, or `history`; an absent `kind` means a legacy reply-ancestor or thread-starter entry.
The chain is untrusted third-party public input and often absent (the relay currently sends it only for Discord reply chains and thread starters), so consumers treat it as optional, tolerate unknown or missing fields, and read `unavailable: true` as a gap rather than content.
The mention and its chain entries may carry media URLs in fields such as `images` and `attachments`, as bare strings or objects with a `url`; a mention with no media of its own can still have screenshots on its `thread_starter` entry.
The poll never downloads media; the responding agent fetches it with its own tools, and the `fmx-respond` skill owns allowed hosts, untrusted-content handling, and referent resolution.

## Reply context

The poll also records a durable per-request reply context at `state/x-context/<request_id>.json` (`{request_id, platform, reply_max_chars, recorded_at}`), best-effort and keyed by `request_id`.
It survives the inbox cleanup that follows an answer, so a delayed follow-up recovers the original platform and split budget even with no task link.
`recorded_at` starts as the first-seen time and is refreshed only when a live initial answer establishes the relay's follow-up binding.
Polls prune records beyond the local follow-up window, capped at the relay's seven-day window; legacy or malformed records age by file modification time.
The record is written only when a platform or explicit budget is known.
Platform and budget resolve per axis: a `FMX_REPLY_PLATFORM` / `FMX_REPLY_MAX_CHARS` override wins, then `fmx_resolve_reply_context` in `bin/fm-x-lib.sh` owns the order (registry, inbox payload, then a live-follow-up-only relay lookup through `POST /connector/request-context`).
The answer path and every dry-run stay network-free.
When a follow-up's platform or explicit budget cannot be resolved from any source, `bin/fm-x-reply.sh` refuses with exit 8 rather than posting with a local default, and firstmate retries once both values are recoverable.

## Answering, follow-ups, and dismissal

The `fmx-respond` skill decides whether a stashed mention is an actionable request, a question, or a pure acknowledgment.
Actionable reversible requests run through intake, backlog, dispatch, investigation, or ship flow as appropriate, and a request finished in that turn gets its outcome in the public reply.
A longer-running task gets an acknowledgement through the answer endpoint, a link to the mention with `bin/fm-x-link.sh`, and up to three completion follow-ups on genuine milestones through `bin/fm-x-followup.sh`, ending with `--final`.
When a typed promised-final commitment is registered, `bin/fm-public-followup.sh` owns the terminal reply instead (see [Promised public replies](#promised-public-replies-statepublic-followup)).
The link lives in this home's `state/<task-id>.meta`, so it can only bind work this home owns; for work routed to a secondmate `bin/fm-x-link.sh` refuses and points at `bin/fm-public-followup.sh register ... --work-home secondmate:<id>`, the only follow-up path that binds work in another home.
Relinking the same request onto a successor task must carry the prior count, timestamp, and reply context so the successor does not get a fresh budget; `bin/fm-x-link.sh`'s header owns the carry flags.
Pure acknowledgments and mentions with nothing to answer are dismissed with `bin/fm-x-dismiss.sh` before the local inbox file is cleared, so the relay neither re-offers them nor falls back to an offline auto-reply.
Live replies go through `bin/fm-x-reply.sh`, which can attach one local image with `--image <path>`; its header owns endpoints, payload shapes, exit codes, and the relay's follow-up 409 handling.
`bin/fm-x-followup.sh`'s header owns the local window and cap, link clearing, and the retryable exit-8 hold.
The local window and cap are the primary follow-up guard, because a past-window relay rejection is only guaranteed while the relay still holds the expired binding.

Reply splitting is platform-aware: an explicit relay platform field wins, otherwise a legacy `tweet_id` beginning with `discord:` selects Discord and a numeric one selects X, and an explicit relay limit field wins over platform defaults.
An over-budget reply becomes a numbered thread split on fenced-code, paragraph, line, and word boundaries, with any image on the opener.

| Variable | Default | Meaning |
| --- | --- | --- |
| `FMX_X_REPLY_MAX_CHARS` | 280 | X per-message budget; values below 50 clamp to 50. |
| `FMX_DISCORD_REPLY_MAX_CHARS` | 1900 | Discord per-message budget; below 50 clamps to 50, above 2000 resets to 1900. |
| `FMX_X_THREAD_MAX` | 25 | Maximum messages in one split thread on any platform; truncation marks the last kept message with an ellipsis. |
| `FMX_FOLLOWUP_MAX_AGE_SECS` | 604800 | Local completion follow-up window (7 days). |
| `FMX_FOLLOWUP_MAX_COUNT` | 3 | Local follow-up cap per linked mention. |

## Dry run

Set `FMX_DRY_RUN` to preview replies and dismissals without posting.
Truthy means anything except unset, empty, `0`, `false`, `no`, or `off`, and an explicit environment value wins over `.env`.
In dry-run, `fm-x-reply.sh` and `fm-x-dismiss.sh` record the would-be payload to `state/x-outbox/<request_id>.json` (with an `endpoint` marker for follow-ups and dismissals, and compact image metadata instead of base64), print a `DRY RUN` summary to stderr, echo the `request_id`, and exit 0.
These paths need `jq` but run before token and network checks, so they need neither `FMX_PAIRING_TOKEN` nor `curl`.

## Promised public replies (state/public-followup)

A relay request that spawns real work can leave firstmate owing a specific public reply in a specific thread.
That promise is a typed `kind=public-followup` obligation whose state machine is owned by `tasks-axi public-followup`, while the full private conversation context stays only in `state/x-context/`.
`bin/fm-public-followup.sh` is firstmate's side: it registers a commitment, reconciles typed terminal work results into it, posts the final reply through `bin/fm-x-reply.sh --followup`, and explicitly rechains or retires the retained loop; `--help` owns its subcommands.
Registration creates the private mode-0700 `state/public-followup/` transport, whose layout `bin/fm-public-followup-lib.sh`'s header owns, and a registration survives delivery (stamped `state=delivered`) until `retire`.

The home that owns the commitment also owns the outward post, because only it holds the relay consent, the request context, and the opaque thread binding.
Work routed elsewhere reports a typed terminal result with `bin/fm-public-followup-emit.sh` and never looks for the thread; a direct write into the owning home is refused when no registration names the obligation.
A terminal event's id is derived from its identity tuple, so a duplicate report, retry, or replay changes nothing.
Work in a remote secondmate home cannot write to the owning machine, so `bin/fm-public-followup.sh brief` gives that worker the route's code root and home with `--stage-in`, and the owning home's `consume` pulls staged results over the same SSH route it uses for that secondmate (`bin/fm-public-followup-collect.sh --help` owns those commands).
`consume` skips non-open registrations without contacting their routes, and an open registration whose reachable route has nothing staged stays pending without an error.
Collection is non-destructive until the result is durably held, so a dropped connection never loses a terminal result.
An unreachable work home for an open registration is named in `consume`'s output and keeps the promise open; it is never reported as an empty inbox.
For a remote work home, delivery clears its bound legacy link after validating the public receipt, and retirement clears it before closing the loop, both over that route's SSH transport.
A link is cleared only when its Relay request identity matches the registration and the remote state is writable; a mismatch, unreadable or unsafe state, an unavailable write or lock, an older remote copy, or an unconfirmed clear leaves the loop retained for reconciliation.

Activation is the same `.env` `FMX_PAIRING_TOKEN` contract, with no second flag.
A home without the token runs one file test and stops: no `tasks-axi` call, no scan, and no `state/public-followup/` directory.
A relay-enabled home with no registered commitment stops at an O(1) directory presence check.
Unreconciled terminal results ride the existing 30-second relay poll, which wakes firstmate once per new result set.
The session-start digest prints a "Public commitments" subsection only when this home is relay-active and still holds an open public loop, so compaction and restart are non-events.
`bin/fm-teardown.sh` refuses to clean up a task while this home still owes a public reply for exactly that work, unless `--force` carries explicit discard approval.
`FM_PF_RETRY_BACKOFF_SECS` (default 900) sets the next-attempt time recorded with a retryable delivery error.
See [verification/public-followup.md](verification/public-followup.md) for the evidence behind restart recovery, retained-loop disposition, and the relay-disabled zero-overhead guarantee.
