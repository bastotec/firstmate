<h1 align="center">firstmate</h1>
<p align="center">
  <a
    href="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
    ><img
      alt="Platform"
      src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-blue?style=flat-square"
  /></a>
  <a href="https://x.com/kunchenguid"
    ><img
      alt="X"
      src="https://img.shields.io/badge/X-@kunchenguid-black?style=flat-square"
  /></a>
  <a href="https://discord.gg/Wsy2NpnZDu"
    ><img
      alt="Discord"
      src="https://img.shields.io/discord/1439901831038763092?style=flat-square&label=discord"
  /></a>
</p>

<h3 align="center">Talk to one agent. Ship with a crew.</h3>

<p align="center">
  <img alt="firstmate - talk to one agent, ship with a crew" src="assets/banner.png" width="100%" />
</p>

## What it is

You can run one coding agent easily.
But the moment you want three project tasks done in parallel - fixes, investigations, plans, audits - you become a tab-juggler: babysitting sessions, copy-pasting context between repos, forgetting which terminal had the failing test.

firstmate flips the model.
You talk to a single agent - the first mate - and it runs the crew for you: spawning autonomous agents in a visible session backend, giving each a clean git worktree, supervising them to completion, and handing you finished PRs, approved local merges, or standalone investigation reports.
For larger fleets, you can opt in to persistent secondmates: second mates that are still ordinary direct reports, but run from their own isolated firstmate homes on this machine or another SSH-reachable host.

firstmate is not a model, not a harness, not a skill, not an MCP server, and not a CLI.
firstmate is an agent distro for running a crew of agents.
An agent distro is a portable directory of instructions, skills, tooling, policies, and state conventions that turns a general-purpose agent into a specialized one.
There is no app to install: the cloned repo is the distro - `AGENTS.md`, bundled firstmate skills, and helper scripts that any terminal coding agent can follow.
Launching a supported harness inside it for your primary session instantiates your first mate - and makes you the captain.

## Features

- **One liaison** - you talk only to the first mate; it dispatches, supervises, escalates only real decisions, and reports plain outcomes.
- **A visible crew** - every crewmate works in its own container on the active session backend - a tmux window by default, or a Herdr tab or central stream endpoint elsewhere - that you can watch or type into; the first mate reconciles.
- **Disposable worktrees** - each task runs in a clean [treehouse](https://github.com/kunchenguid/treehouse) git worktree, so parallel work on one repo never collides.
- **Two task shapes** - ship tasks deliver authorized changes; scout tasks leave standalone investigation reports when the intake contract warrants separate research.
- **Explicit project modes** - each project ships via `no-mistakes`, `direct-PR`, or `local-only`, with an optional `+yolo` merge-autonomy flag.
- **Optional auto-land** - authorized green PRs land and run private post-merge deployment hooks without waiting for their worker; [Auto-land setup](docs/configuration.md#auto-land-configautolandjson-configpost-merge) owns the opt-in and safety policy.
- **Optional secondmates** - opt in to persistent second mates that run from isolated firstmate homes with their own `FM_HOME`, state, projects, and session lock, either locally or as a whole home on an SSH-reachable host, with guarded updates and recovery that never turns an unavailable remote route into a local replacement.
- **Event-driven, zero-token supervision** - a bash watcher sleeps on the fleet and wakes the first mate only when something needs you.
- **Optional Relay** - opt in with one local `.env` pairing token so firstmate can answer your public mentions on X and Discord alike, act on normal reversible mention requests through the same lifecycle as chat requests, acknowledge spawned work, and post up to three public-safe completion follow-ups within seven days for genuine milestones and the final outcome without changing non-Relay behavior; a final reply promised in a thread becomes durable state that is reconciled from disk, so a restart or a compacted conversation cannot lose it; dry-run preview records would-be replies and dismissals locally before go-live.
- **Strict project boundary** - the first mate is read-only over your projects except for the narrow guarded and captain-approved operations authorized by [hard rule 1](AGENTS.md#1-identity-and-prime-directives), including fleet sync's guarded safe branch pruning; crewmates make every other project change behind the configured merge authority.
- **Restart-proof** - all state lives on disk and in the active session backend (tmux by hard default, with the accepted alternatives and how each is selected owned by [docs/configuration.md](docs/configuration.md) "Runtime backend"); kill the session anytime and the next one reconciles, including confirmed-dead secondmate agents, and carries on.

Full detail on every feature lives in [docs/architecture.md](docs/architecture.md).

## Quick Start

### Requirements

- [Deck](https://github.com/bastotec/deck), the only supported agent harness, with a key its gateway accepts.
- Git and the GitHub CLI, authenticated through `gh auth login`.
- The CLI and dependencies for your selected runtime backend; tmux is the reference default.

The first mate detects and offers to install supported missing tools after you approve.
Backend-specific setup is linked in [Documentation](#documentation).

### Install and launch

```sh
gh auth login
git clone https://github.com/kunchenguid/firstmate
cd firstmate
```

Then launch the Deck chat host; AGENTS.md takes over from there:

```sh
bin/fm-deck-chat.sh
```

The host owns the home's session lock, runs session start once, keeps the watcher armed, and hands every wake to the Deck session; its header owns the details.
On macOS, `bin/fm-deck-chat.sh install-service` adds a launchd agent that restarts the host in a stream endpoint after any exit except `bin/fm-deck-chat.sh stop`; the [host header](bin/fm-deck-chat.sh) owns service setup and restart-following attach.
With Deck's project launcher ([`.agents/deck.chat.json`](.agents/deck.chat.json)), a bare `deck chat` in the home or its subdirectories opens the stream-hosted primary, starting it first when it is down; the [host header](bin/fm-deck-chat.sh) owns startup and recovery details.
Ctrl-] detaches and leaves it running, and `deck chat --local` starts a separate local chat.
Outside the home, or in a checkout without a `state/` directory (such as a worktree or a never-run clone), `deck chat` stays local and does not create a primary.
The plain launch above keeps the primary in its own terminal, so bare `deck chat` refuses to attach to it; for launcher-based access, configure the [stream backend](docs/stream-backend.md) and start with `bin/fm-deck-chat.sh --stream` or the service described above.

### Talk to it

```sh
> ahoy! look at my github project xyz, then fix the flaky login test and add dark mode

# firstmate checks its toolchain (asking your consent before installing anything),
# clones the project under projects/ and spawns two isolated workers in the active backend.
# Minutes later:

  PR ready for review, captain: https://github.com/you/xyz/pull/42
  (fix flaky login test - risk: low - CI green)

> alright merge it
```

### More backends

[docs/configuration.md](docs/configuration.md) ("Runtime backend") lists every accepted backend and its status, and the setup guide for each one is linked in [Documentation](#documentation) below.

## How It Works

```
            you (the captain)
                  │  chat: requests, decisions, "merge it"
                  ▼
 ┌─────────────────────────────────────┐
 │ firstmate            (this repo)    │
 │ reads projects/ + firstmate routes  │
 │ writes guarded backlog/briefs/state │
 └──┬──────────────┬───────────────┬───┘
    │ backend sends / status files │
    ▼              ▼               ▼
 ┌────────┐   ┌────────┐      ┌────────┐
 │fm-task1│   │fm-task2│  ... │fm-taskN│   one container per task on the active session backend
 │crewmate│   │crewmate│      │crewmate│   one autonomous agent each
 └───┬────┘   └───┬────┘      └───┬────┘
     ▼            ▼               ▼
  treehouse worktree or isolated secondmate home
     │
     ├─ ship: project mode ► PR/local merge ► teardown
     │
     └─ scout: report at data/<id>/report.md ► decision inventory ► relay findings ► teardown
```

You chat with the first mate.
It routes each request to a crewmate in its own session endpoint and git worktree, supervises the fleet with a zero-token event-driven watcher, and brings you finished PRs, approved local merges, or investigation reports.
Optional secondmates extend this to persistent local or whole-home remote second mates, dispatch profiles let you steer which harness handles which task, and opt-in Relay lets the same fleet answer public mentions.

Full architecture - the supervision engine, worktree isolation, secondmates, dispatch profiles, project modes, optional Relay, fleet sync, and self-update - is in [docs/architecture.md](docs/architecture.md).

## Built-in skills

Firstmate ships these user-invocable built-in skills.
The slash form is shown here; when a harness's exact command form is uncertain, ask in natural language.

| Skill              | What it does                                                                                                                                  |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `/afk`             | Enter away-mode supervision: the sub-supervisor self-handles routine notifications in bash, escalates captain-relevant events and bounded declared-external-wait rechecks as batched digests, and actively alerts if delivery gets stuck while you step away |
| `/quiet`           | Enter quiet supervision mode: the same token-saving sub-supervisor tradeoff as `/afk`, for a captain who is staying and chatting - ordinary messages do not exit it, only an explicit `/quiet off` does |
| `/ahoy`            | Recap visible session events since the prior real captain message plus visibly unanswered captain decisions, then guide the captain through any open decisions one at a time in agent-judged impact order; fall back to Bearings when invoked as the session's first real captain message |
| `/bearings`        | Generate a concise four-section chat digest from bounded fleet state, including registered remote-home ledgers; use `/bearings file` to also replace today's dated report in `data/`, and add `include PRs` for live GitHub enrichment |
| `/updatefirstmate` | Guardedly update the running firstmate and its secondmates - fast-forward, or reconcile a redundant post-squash-merge divergence - then persist and restart every live mate successfully left on the target commit - including already-current homes - with an honest re-read nudge only when restart cannot be proven |
| `/stow`            | Sweep the session for uncaptured durable knowledge, persist the open work records this session knows are unfiled or now wrong, curate tiered startup memory with decay and cold archival, enforce each home's budget or surface the required decision, cascade to registered second mates, and report what is safe to reset |

Bearings invocation examples:

- `/bearings` returns the fresh four-section digest in chat only.
- `/bearings include PRs` keeps chat-only mode and opts into live PR enrichment.
- `/bearings file` replaces today's `data/status-report-<YYYY-MM-DD>.md` from scratch and links it from the four-section chat digest.
- `/bearings file include PRs` combines the dated report with live PR enrichment.

Agent-only reference skills live under `.agents/skills/` and are loaded by firstmate at the trigger points named in [`AGENTS.md`](AGENTS.md).

### Two-tier skill layout

Firstmate's skills live in two separate places with different audiences:

- `.agents/skills/` - agent-loaded skills (this section's table, plus firstmate's agent-only reference skills). Every one of these assumes a live firstmate home and is meaningless, or actively misleading, installed anywhere else, so each carries `metadata.internal: true` in its frontmatter. That flag hides them from installer discovery (tools like the [skills.sh](https://skills.sh) `npx skills add` installer) without affecting how firstmate itself loads them - frontmatter metadata is inert to the agent's own skill loader.
- `skills/` - public, installer-facing skills meant to be installed standalone into any project, independent of firstmate.
  Each one is a self-contained skill with no dependency on firstmate's paths, tools, or vocabulary.
  Today that is `skills/stow`, a generic session-knowledge-sweep skill that routes findings by explicit instruction first, then existing local conventions, then a private `.stow-notes.md` fallback, and curates tiered entries through decay, local archival, and user-approved on-demand offload proposals.
  It intentionally shares no code with the firstmate-internal `.agents/skills/stow` it is named after, so the two can evolve independently.

## Documentation

- [docs/architecture.md](docs/architecture.md) - maintainer architecture for the crew, supervision, worktrees, secondmates, and project modes.
- [docs/configuration.md](docs/configuration.md) - environment variables, `FM_HOME`, runtime backend selection, optional Relay and its X and Discord setup steps, trusted external process-event adapter setup, the files you set, and harness support.
- [docs/extension-bindings.md](docs/extension-bindings.md) - maintainer architecture for the narrow trusted external `process-event-adapter/1` package, binding, handshake, and evidence boundary.
- [docs/remote-secondmates.md](docs/remote-secondmates.md) - current setup, routing, transfer, recovery, and safety behavior for whole-home remote second mates.
- [docs/wedge-alarm.md](docs/wedge-alarm.md) - configure the active alert for an away-mode escalation delivery that gets stuck.
- [docs/tmux-backend.md](docs/tmux-backend.md) - current setup and limits for the tmux reference backend.
- [docs/herdr-backend.md](docs/herdr-backend.md) - current setup, CI coverage, safety boundaries, and limits for the Herdr backend.
- [docs/stream-backend.md](docs/stream-backend.md) - setup, security model, and limits for the experimental central stream backend, which puts every task's live output on one hub.
- [docs/verification/runtime-backends.md](docs/verification/runtime-backends.md) - active maintainer verification for runtime backend guarantees.
- [docs/gitlab-merge-watch.md](docs/gitlab-merge-watch.md) - maintainer verification for watching and merging GitLab merge requests on arbitrary instances.
- [docs/verification/supervision.md](docs/verification/supervision.md) - active maintainer verification for session-start, guard, continuity, and wedge integrations.
- [docs/supervision-protocols/](docs/supervision-protocols/) - rendered watcher protocols for Deck home hosts and the unknown harness fallback.
- [docs/scripts.md](docs/scripts.md) - the `bin/` toolbelt reference.
- [docs/documentation-audiences.md](docs/documentation-audiences.md) - documentation audiences and the machine-checked placement boundary.
- [`AGENTS.md`](AGENTS.md) - the supervisor contract, role boundary, and routing index for conditional procedures.
- [CONTRIBUTING.md](CONTRIBUTING.md) - how to contribute, including the dev/test commands.

## Contributing

Contributions are welcome - see [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow, repo conventions, and how to run the tests.

## License

MIT - see [LICENSE](LICENSE).
