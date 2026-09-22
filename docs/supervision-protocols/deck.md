Mode: Deck secondmate driver-owned wake turns.

`bin/fm-deck-worker.sh --secondmate` owns startup, the session lock lifetime, and watcher continuity; its header owns the mechanism and invariants.
The complete session-start digest is already in the first turn: read it once and do not run session start again.
On every watcher turn, drain `bin/fm-wake-drain.sh` before investigating or steering.
Handle every emitted wake, open decision, and unread status, then run the exact `WAKE_ACK_REQUIRED` command the drain printed.
Never acknowledge unhandled work.
Return after handling: the driver publishes watcher results through the task steering inbox and submits its ordinary doorbell as the next turn of the same conversation.
Do not arm a watcher manually or keep a tool call open to wait; the persistent driver owns the child process, including cleanup.
A startup, lock, watcher, or Deck failure is reported to the parent and stops this driver; recovery belongs to the parent's guarded relaunch path.
This protocol is for persistent secondmates, not an authorization to migrate the main primary session.
