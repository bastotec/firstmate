# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

The Deck `run` home driver uses no harness hook: persistent `fm-deck-worker.sh` owns one tracked arm child, replaces it whenever it exits during a Deck turn, and retains its result for a serialized durable-inbox turn.
The driver header owns the exact child and hand-off mechanics; [the separate chat host header](../bin/fm-deck-chat.sh) owns steering-based continuity for `deck chat` primaries.
[`supervision-protocols/deck.md`](supervision-protocols/deck.md) owns the model's handling duty for both hosts.

## Actionable wake ordering

The Deck `run` home driver starts and verifies one singleton successor before handling a wake, through the arm layer's handling-successor handshake.
It accumulates watcher results that arrive while a Deck turn runs and delivers them through the next serialized inbox turn rather than injecting into the active turn.

The recovery-episode contract below owns once-per-generation announcement.
A handling successor does not re-announce; it enters its poll loop immediately and keeps scanning signals, stale panes, and checks.
The model no longer re-arms after ordinary wakes.
No PreToolUse hook denies fleet commands based on watcher status.
Terminal arm-output classification (`started`, `attached`, or `FAILED`) remains defense in depth for the manual recovery path.
No hook adapter starts an untracked replacement with shell `&`.
The Deck driver uses `&` only for an owned child whose PID it monitors and waits during cleanup.

Deck `run` home hosts check the driver-owned postcondition before each turn completes; the chat host's header owns its separate supervision boundary.

## Recovery episode acknowledgement

A recovery episode is one generation of `state/.watcher-down`, and it is retired only by the generation-bound acknowledgement the drain prints as `WAKE_ACK_REQUIRED`.
An unacknowledged downtime generation is announced at most once: the first recovery marks that generation announced, and later arms wait until a new down stretch mints a new generation.
A non-successor watcher start after an announced-but-unacked episode is a new down stretch and mints a fresh generation so buried decisions still resurface once.
Every watcher close and every durable queue append publishes downtime, so a downtime republication of any pending episode reuses its generation instead of minting a new one, and an already-announced generation stays announced.
That reuse keeps a watcher close inside the handling window from orphaning the acknowledgement already presented and trapping later arms in repeated recovery presentation.
An acknowledgement carries two separable facts: queue-row consumption is bound to the monotonic `--ack-through` sequence, while only retiring the episode is bound to `--recovery-generation`.
A generation mismatch therefore does not block consumption of rows through that sequence; it is a non-fatal result that names its own remedy - re-drain, then acknowledge the newer episode.
The acknowledgement retires the marker only when no rows remain after sequence-bound consumption.
A concurrently appended wake has a higher sequence, remains queued, and keeps the episode pending for presentation.
Consequently, an empty-queue downtime publication during handling can be retired by the outstanding acknowledgement without a dedicated recovery turn.
An acknowledged episode does not freeze the generation, because the next downtime after it opens an episode of its own.

## Queue acknowledgement

`bin/fm-wake-drain.sh` claims every presented row under the durable queue lock and presents and acknowledges only that claimed view; it never reclassifies a row itself.
A row that lost the five appended fields or its numeric sequence can never be claimed, presented, or named by an `--ack-through` cutoff, so the drain retires it under the queue lock and reports how many it removed together with those rows verbatim, bounded to the first 20 and a count of the rest, because the queue was their only durable record.
A retirement that cannot be read or written is reported and never fails the drain: the rows that remain usable are still presented with their acknowledgement command, the unusable ones stay queued for a later drain to retire, and failing the whole drain would strand the usable rows too.
The drain's `--ack-through <SEQ>` deletes only claimed rows at or below the cutoff, subject to the unread captain-note exception owned by [`configuration.md`](configuration.md#inbox-and-voice-records-configinbox--configvoice-read-).
An acknowledgement whose cutoff removes none of the claimed rows while a presented row above the cutoff still waits is reported as having acknowledged nothing, together with the exact `--ack-through` and `--recovery-generation` command for that presented row; the presented set is read before any re-claim, so a row that arrived after presentation is never named for unseen acknowledgement.
`bin/fm-guard.sh`'s queued-wake warning counts the same rows the drain can present, through `bin/fm-wake-lib.sh`'s `fm_wake_pending_count`, and `tests/fm-wake-queue.test.sh` drives both scripts together to pin that invariant.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or resolves the close against the watcher's bounded terminal-delivery ledger.
An attached arm follows verified identity-matched successors and resolves the same way when that chain ends without one, because it holds no handle on the watcher's stdout and cannot read the reason line itself.
Before releasing its singleton lock after printing an actionable reason, the watcher records that reason with its PID and process identity in `state/.watch-deliveries.log`.
A matching PID and identity lets an attached arm report the delivered reason and exit zero even after its durable wake was handled and acknowledged, while an unrelated queue producer or a recycled PID cannot satisfy the match.
Only a cycle with no matching delivery record emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.
An arm that dies before loading `bin/fm-wake-lib.sh` still prints a typed line: `out of process capacity` (exit 75) when a refused fork killed startup, or `broken install` (exit 78) when the library is missing, unreadable, or defines no `STATE`; the script header owns the exact wording.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

A running watcher re-execs itself in place when any `bin/*.sh` is newer than its filesystem-clock start reference and the change has settled for `FM_WATCH_CODE_SETTLE` seconds (default 2), because bash keeps the loop it parsed at start and a merge would otherwise leave the old loop supervising until the next wake.
The pid, the singleton lock, and the arm's wait carry over, the reloaded image skips the recovery bookkeeping of a fresh arm, and a changed `fm-watch.sh` that does not parse keeps the running code.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## Regression coverage

`tests/fm-watch-arm.test.sh` covers durable queue replay, real remote parent-replies ingestion into the authoritative status log, decision-only OPEN DECISIONS recovery, interrupted handling replay, generation-bound acknowledgement, a persistent live successor after recovery, a watcher close inside the handling window that must leave the printed acknowledgement valid, the self-healing moved-generation acknowledgement that consumes its handled rows and names its remedy, and a bootstrap that binds to its own home without forking and types a refused fork apart from a broken install.
`tests/fm-watch-recovery-loop.test.sh` covers the once-per-generation announcement bound, a handling successor that must surface a real crew event instead of going blind, and a multi-poll foreign-queue continuity window with an observation clock unrelated to filesystem mtimes.
The continuity-window case preserves singleton ownership and the acknowledged recovery generation through healthy queue progress, then requires exactly one durable stall notification without modifying the foreign row.
`tests/fm-watch-triage-events.test.sh` covers the in-place code reload (same pid and lock, one watcher, startup-overlap detection, full-tree settling, post-reload recovery, and an unparseable change refused) and the main captain-inbox path: an unread note's row survives acknowledgement, is surfaced again at once, and has bounded interval repeats.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, recovery publication before stale-lock removal, the typed self-eviction failure, bounded and successor-linked lifecycle rows, and a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.

## Active limits and verification

The goal is continuity without a Deck home-host model-memory re-arm step.
No zero-latency guarantee is claimed because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.

[`verification/supervision.md`](verification/supervision.md#turn-end-supervision) records the Deck turn-end supervision evidence, and [`verification/deck.md`](verification/deck.md#secondmate-host-verification) records the Deck secondmate host check.
