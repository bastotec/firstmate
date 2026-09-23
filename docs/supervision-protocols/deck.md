Mode: Deck secondmate driver-owned wake turns.

`bin/fm-deck-worker.sh --secondmate` owns startup, the session lock lifetime, and watcher continuity; its header owns the mechanism and invariants.
The complete session-start digest is already in the first turn: read it once and do not run session start again.
When a turn dies before Deck opens a session, that digest reaches no conversation, so the host repeats the same launch brief once underneath the next wake; it is still the one digest, and running session start yourself is still wrong.
On every watcher turn, drain `bin/fm-wake-drain.sh` before investigating or steering.
Handle every emitted wake, open decision, and unread status, then run the exact `WAKE_ACK_REQUIRED` command the drain printed.
Never acknowledge unhandled work.
Return after handling: the driver publishes watcher results through the task steering inbox and submits its ordinary doorbell as the next turn of the same conversation.
Do not arm a watcher manually or keep a tool call open to wait; the persistent driver owns the child process, including cleanup.
A startup, lock, or watcher failure is reported to the parent and stops this driver; recovery belongs to the parent's guarded relaunch path.
A failed turn is reported to the parent the same way but does not stop this driver: it returns to its prompt keeping its Deck session, so the next wake is simply the next turn, and only a failure it could not report stops it.
A failure that opened no session at all stops this driver after its one repeated launch brief, so the home returns to the parent's guarded relaunch path rather than parking blind.
This protocol is for persistent secondmates, not an authorization to migrate the main primary session.
