# Supervision integration verification

Audience: maintainer verification.

This record supports current busy-state, turn-end, and wedge-alarm guarantees.
Operator behavior and active limits remain in the linked current guides.
Task-specific chronology, temporary paths, run identifiers, and delivery transcripts remain in private reports or PR evidence.

## Semantic busy state

The semantic source behind [`bin/fm-busy-lib.sh`](../../bin/fm-busy-lib.sh) is Deck's `deck-wrapper` record, verified in [`deck.md`](deck.md) against firstmate-launched workers wired exactly as `fm-spawn` writes them.

Deterministic entry points:

```sh
tests/fm-busy-state.test.sh
tests/fm-busy-adapter-wiring.test.sh
tests/fm-crew-state.test.sh
```

## Turn-end supervision

Deck secondmate startup, stable lock ownership, and driver-owned turn-end supervision were checked on 2026-09-22 with `deck 0.1.0`; [Deck host verification](deck.md#secondmate-host-verification) owns the refresh command and exact output.

## Wedge-alarm channels

The real `osascript` notification channel was bounded manually on 2026-07-10 on macOS 26.5.2.
It is the only built-in channel; other platforms use a `command:` directive.
Automated suites never execute the real notification command.

Argv-safe Notification Center command:

```sh
/usr/bin/osascript \
  -e 'on run argv' \
  -e 'display notification (item 1 of argv) with title "FIRSTMATE TEST - IGNORE" sound name "Basso"' \
  -e 'end run' \
  'FIRSTMATE TEST - IGNORE (wedge-alarm channel verification)'
```

Observed output: no stdout, exit 0, and one banner with the supplied body.

The safe command-channel contract is covered without a notification by `tests/fm-daemon.test.sh`: the summary reaches both `$1` and stdin, every channel is process-group bounded, and a failed channel falls through.
