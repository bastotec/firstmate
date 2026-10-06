Mode: Deck home-host-owned wake input.

`bin/fm-deck-worker.sh --secondmate` and the `deck chat` primary host `bin/fm-deck-chat.sh` own startup, the session lock lifetime, and watcher continuity; each script's header owns the mechanism and invariants.
Startup input is already in the first turn: read the complete session-start digest once, following any supplied file pointer before acting, and do not run session start again.
Under `bin/fm-deck-worker.sh`, when a turn dies before Deck opens a session, that digest reaches no conversation, so the driver repeats the same launch brief once underneath the next wake; it is still the one digest, and running session start yourself is still wrong.
On every watcher turn, drain `bin/fm-wake-drain.sh` before investigating or steering.
Handle every emitted wake, open decision, and unread status, then run the exact `WAKE_ACK_REQUIRED` command the drain printed.
Never acknowledge unhandled work.
Return after handling: under `bin/fm-deck-worker.sh`, the driver publishes watcher results through the execution steering inbox and submits its ordinary doorbell as the next turn of the same conversation.
Under `bin/fm-deck-chat.sh` the host publishes each watcher result into the chat's steering inbox, and it arrives as a `[Supervisor steering, seq N]` message.
Do not arm a watcher manually or keep a tool call open to wait; the persistent host owns the child process, including cleanup.
Each host's header owns its failure handling and watcher handoffs.
After `bin/fm-deck-worker.sh` stops, recovery belongs to its lifecycle owner, the parent firstmate.
For primary recovery with or without the optional launchd service, follow the [chat host header](../../bin/fm-deck-chat.sh).
This protocol applies to persistent secondmates and Deck chat primaries.
