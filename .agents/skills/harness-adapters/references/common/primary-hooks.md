# Primary startup and turn end

Load this before changing session startup, turn-end handling, watcher supervision, or secondmate integration.
`../../../README.md` owns primary harness support; deck is the only primary harness, hosted by `../../../bin/fm-deck-chat.sh`.

## Session start

`../../../AGENTS.md` section 3 remains the behavioral owner.
`../../../bin/fm-deck-chat.sh` runs `../../../bin/fm-session-start.sh` once per host start and hands its digest to the Deck session.
There is no separate primary hook layer: the host itself owns startup, supervision, and cleanup for its whole lifetime.

## Turn end

The home-host headers own Deck's `pre_complete` lock check: [`bin/fm-deck-worker.sh`](../../../../../bin/fm-deck-worker.sh) for secondmates and [`bin/fm-deck-chat.sh`](../../../../../bin/fm-deck-chat.sh) for primaries.
`../../../bin/fm-busy-lib.sh` remains the semantic busy owner; the deck tool reference names only its source and evidence.
Validate any turn-end change against the real harness in a scratch project or throwaway home, and record the evidence in `../../../docs/verification/supervision.md`.

## Watcher supervision

`../../../bin/fm-session-start.sh` prints exactly one block for the detected primary.
Follow only that rendered protocol.
When changing the watcher adapter, update `../../../docs/supervision-protocols/deck.md` and refresh the deck tool reference.
An identity without a dedicated protocol uses its documented unsupported or unknown boundary; never invent one from a similar TUI.
