Mode: Deck home-driver-owned wake turns.

`bin/fm-deck-worker.sh --secondmate`, the managed-primary entry point `--primary`, and the `deck chat` primary host `bin/fm-deck-chat.sh` own startup, the session lock lifetime, and watcher continuity; each script's header owns the mechanism and invariants.
The complete session-start digest is already in the first turn: read it once and do not run session start again.
When a turn dies before Deck opens a session, that digest reaches no conversation, so the host repeats the same launch brief once underneath the next wake; it is still the one digest, and running session start yourself is still wrong.
On every watcher turn, drain `bin/fm-wake-drain.sh` before investigating or steering.
Handle every emitted wake, open decision, and unread status, then run the exact `WAKE_ACK_REQUIRED` command the drain printed.
Never acknowledge unhandled work.
Return after handling: the driver publishes watcher results through the execution steering inbox and submits its ordinary doorbell as the next turn of the same conversation.
Under `bin/fm-deck-chat.sh` the host publishes each watcher result into the chat's steering inbox, and it arrives as a `[Supervisor steering, seq N]` message.
Do not arm a watcher manually or keep a tool call open to wait; the persistent driver owns the child process, including cleanup.
The driver's header owns terminal host failures, recoverable turn failures and watcher handoffs; recovery after the driver stops belongs to its lifecycle owner, the parent for a secondmate or the managed owner for a primary.
This protocol applies to persistent secondmates and explicitly managed primaries; [`docs/managed-primary.md`](../managed-primary.md) owns the opt-in setup and never authorizes adoption of an existing primary.
