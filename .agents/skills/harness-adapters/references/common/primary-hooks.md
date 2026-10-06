# Primary startup and turn end

Load this before changing session startup, turn-end handling, watcher supervision, or secondmate integration.
`../../../README.md` owns primary harness support; deck is the only primary harness, hosted by `../../../bin/fm-deck-chat.sh`.

## Session start

`../../../AGENTS.md` section 3 remains the behavioral owner.
`../../../bin/fm-deck-chat.sh` runs `../../../bin/fm-session-start.sh` once per host start and hands its digest to the Deck session.
There are no harness hooks: the host itself owns startup, supervision, and cleanup for its whole lifetime.

## Turn end

`../../../bin/fm-deck-worker.sh` (secondmates) and `../../../bin/fm-deck-chat.sh` (primaries) own turn-end handling through Deck's `pre_complete` hook, which proves the turn still runs inside the session that holds the home lock.
`../../../bin/fm-busy-lib.sh` remains the semantic busy owner; the deck tool reference names only its source and evidence.
Validate any turn-end change against the real harness in a scratch project or throwaway home, and record the evidence in `../../../docs/verification/supervision.md`.

## Watcher supervision

`../../../bin/fm-session-start.sh` prints exactly one block for the detected primary.
Follow only that rendered protocol.
When changing the watcher adapter, update `../../../docs/supervision-protocols/deck.md` and refresh the deck tool reference.
An identity without a dedicated protocol uses its documented unsupported or unknown boundary; never invent one from a similar TUI.
