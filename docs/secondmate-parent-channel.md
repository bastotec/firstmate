# Secondmate parent channel

This note records why a secondmate home's captain-facing outcomes are delivered by scripts instead of by the mate model, and which script delivers each one.
`bin/fm-parent-channel-lib.sh` owns the channel contract: where the channel lives, how a line is appended, and the return codes every publisher shares.
[`remote-secondmates.md`](remote-secondmates.md) owns the transport that carries the remote form of the channel back to the parent.
[`status_file_is_incoming` in `bin/fm-classify-lib.sh`](../bin/fm-classify-lib.sh) owns the home-scoped outgoing-channel exclusion shared by the watcher's signal and heartbeat scans and the away daemon's catch-all scan.
[`bin/fm-pending-reply-lib.sh`](../bin/fm-pending-reply-lib.sh) owns marked-request turn-completion evidence, recovery, and escalation.

## The problem

A secondmate is a firstmate in its own home, but its ordinary chat is not a delivery channel to the captain or main firstmate; [Captain-direct messages](#captain-direct-messages) points to the exception.
Outcomes have been lost this way: the watcher delivered the parent's request, the mate did the work, and then the mate addressed "captain" in its own chat instead of appending to the channel.
The cause is structural rather than a one-off lapse: the mate can satisfy the [address rule in `AGENTS.md`](../AGENTS.md#firstmate) in local chat while missing the charter's later return-channel instruction.
A PR-ready report, a finding, a decision, a blocker, and a failure all fail the same way when each depends on the mate model remembering to write one line.

The design goal is therefore: the parent channel must not depend on the model remembering to write to it.

## The design

The delivery rule has one sentence: the scripts report facts, the mate reports judgement.
Every captain-facing outcome that leaves durable evidence in the mate home is published on the channel by the script that records that evidence, at record time or on the next supervision poll, and the charter reserves the mate's own appends for judgement.

| Outcome | Durable evidence in the mate home | Published by |
|---|---|---|
| Ship child PR ready | the child's `done: PR <url> ...` line; `pr=` in the child's record once registered | `bin/fm-inactive-reconcile.sh` on the next poll with the child's line; `bin/fm-pr-check.sh` at registration with the canonical URL |
| Scout child findings | the child's `done:` line plus `data/<child>/report.md` | `bin/fm-inactive-reconcile.sh` on the next poll, with the report pointer |
| Child failed | the child's `failed:` line | `bin/fm-inactive-reconcile.sh` on the next poll |
| Child decision escalated to the captain | the task held for the captain in the mate backlog | `bin/fm-captain-hold.sh hold`, and its answer by `answer` |
| PR merged | the merge poll or the mate's own merge | `bin/fm-merge-outcome-lib.sh` |
| Child leaving the home | its final ledger line | `bin/fm-teardown.sh`, which refuses to remove the child while that line is undelivered |
| Child ended silently | terminal current state with a silent ledger | the existing inactive-outcome scan in `bin/fm-inactive-reconcile.sh`, which carries the reader's generic state detail as `detail=` and its separately recorded run cause as `error=` |
| Answer to an ordinary marked request | a correlated line guarded by the pending-reply record | `bin/fm-secondmate-report.sh`, which resolves the parent channel from the mate home; the pending-reply guard repairs a line stranded in the local mate's same-basename status file before recovery or escalation; [captain-direct messages](#captain-direct-messages) follow their own rule |
| An outcome that exists only in the mate's reasoning | none | the charter and the `AGENTS.md` carve-outs only |

The ledger delivery reads files only: it calls no harness, no forge, and no current-state reader, so it does not depend on the harness or the runtime backend.
Each delivery is keyed with the first eight hexadecimal characters of its receipt fingerprint and appended at most once by exact line, and the ledger path reuses the inactive scan's per-fingerprint receipts, so a replayed poll or restart cannot deliver an event twice while a genuinely new terminal event is delivered again.
A duplicate line is harmless and a missed one is not, so the mate may still append its own judgement about a delivered outcome, and the parent reads the script's line as the fact and the mate's line as commentary.
For marked replies, the report helper accepts no caller-selected destination and uses the channel resolver for both local and remote homes; its script header owns the exact invocation contract.
The pending-reply guard may restate only the correlated line from a local mate's `state/<mate-id>.status` onto the parent channel, which repairs the common parent-home versus mate-home mixup without accepting arbitrary mate-home sightings as acknowledgement.
Other correlated mate-home status lines remain wrong-home evidence, while a remote home's routed `state/parent-replies.status` is already the parent channel and is not classified as wrong-home.
A missed-reply escalation includes the complete first sighting path and line number in readable shell-escaped form.

## Captain-direct messages

[`AGENTS.md` section 9](../AGENTS.md#9-escalation-and-captain-etiquette) owns the captain-direct reply rule, the [`fm-send.sh` header](../bin/fm-send.sh) owns its delivery and reply tracking, and [`fm-operational-input.sh`](../bin/fm-operational-input.sh) owns the carrier and its compatibility note.

## Peer messages

[`AGENTS.md` section 9](../AGENTS.md#9-escalation-and-captain-etiquette) and the `mate-messaging` skill own when to message a peer; the [`fm-mate-send.sh` header](../bin/fm-mate-send.sh) owns usage, and [`fm-mate-mail-lib.sh`](../bin/fm-mate-mail-lib.sh) owns the parent-channel diversion, bridge prerequisites, spool, and oversight log.

## What is deliberately not built

- No mirror of the mate's chat: chat can mix outcomes with other conversation, so choosing which sentence is an outcome would itself be model behavior.
- No threshold escalation of a child's open decision or blocker: a decision the mate escalates is a captain hold, which is published; a decision the mate neither answers nor escalates is a supervision-quality question, separable from channel delivery.
- No second watcher or standalone scanner: a lightweight ledger pass runs inside the existing inactive-outcome command on every watcher poll and reuses its receipts and upstream append.
- No orphan lifecycle: teardown refuses instead of removing an undelivered outcome, the same way it refuses on other unlanded conditions.

## Regression coverage

`tests/fm-inactive-reconcile.test.sh` covers the ledger delivery against real ledgers with no harness: immediate done and failed delivery with note, PR, mode, posture, and report pointer, once-only delivery across polls, a line still being appended, the remote route, the yield of the inactive path to a terminal ledger, separate `detail=` and `error=` fields on inactive delivery, and the real watcher poll driving it.
`tests/fm-captain-hold-lifecycle.test.sh` covers a mate home publishing a hold, its answer, and a distinct occurrence on re-hold, and a main home publishing nothing.
`tests/fm-pr-merge.test.sh` covers the PR-ready line at registration and the merge outcome's upward report.
`tests/fm-teardown.test.sh` covers teardown delivering a child's final line and refusing when the channel cannot be written.
`tests/fm-brief.test.sh` pins the charter's channel rule.
`tests/fm-send-secondmate-marker.test.sh` covers the captain-direct tag for secondmate and worker targets, its refusals, and a correlated line resolving a captain message's pending reply.
`tests/fm-captain-direct-echo.test.sh` covers the parent's one FYI note per captain-direct delivery, the echo guard that holds back a parent steer repeating it (and `--correction`), and a captain-direct pending reply that never reposts or escalates.
`tests/fm-pending-reply.test.sh` covers helper-selected local routing, remote-channel classification, same-basename restatement before false escalation, readable wrong-home diagnostics, the rule that arbitrary mate-home sightings never acknowledge a reply, unread local requests not completing a turn, and migrated remote targets ignoring retained local inbox records while still waiting for the reply mirror.
`tests/fm-watch-parent-channel-echo.test.sh` covers outgoing-channel exclusion in signal, heartbeat, and daemon catch-all scans without suppressing child reports, the parent's mirror, or an ordinary same-named file in a home with no parent record.
[`tests/fm-mate-mail.test.sh`](../tests/fm-mate-mail.test.sh) covers peer routing, diversion before document fetch, bridge refusals, and interrupted delivery and terminal bookkeeping.

## Live verification

[`verification/secondmate-parent-channel.md`](verification/secondmate-parent-channel.md) records the dated live run: both real watchers re-armed after each wake and no model, with every delivered parent line and the parent wake it produced.
