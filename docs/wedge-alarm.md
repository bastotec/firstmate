# Away-mode injection wedge alarm

The away-mode sub-supervisor (`bin/fm-supervise-daemon.sh`) buffers escalations and delivers them to the primary.
[`Away-mode supervisor backend`](configuration.md#away-mode-supervisor-backend-fm_supervisor_backend--fm_supervisor_target) owns how that delivery reaches a stream primary.
When delivery cannot be confirmed past `FM_MAX_DEFER_SECS`, `inject_wedge_alarm` raises a loud, rate-limited alarm so the stall never stays invisible.
The active alert does not depend on the primary's endpoint, because a stalled endpoint is exactly what it reports and it must reach an unattended captain.
The durable `state/.subsuper-inject-wedged` marker remains as an additional signal.

## Channels

`config/wedge-alarm` is local and gitignored.
It lists channel directives, one per non-empty, non-comment line, and every listed non-`off` channel fires best-effort.
`FM_WEDGE_ALARM_CHANNEL` overrides the file with one directive for focused testing.

- `off` disables every active alert, wherever it appears in the list, while retaining the durable marker.
- `auto` or `default` resolves to `osascript` on macOS.
  Other platforms have no built-in OS channel, so configure `command:` when a durable marker alone is insufficient.
- `osascript` posts a macOS Notification Center banner outside the terminal.
- `command:<cmd>` runs `<cmd>` through `sh -c` with the alarm summary as `$1` and on stdin, allowing delivery to a phone or pager service.

An unrecognized directive logs a warning and fires nothing; the marker is still written.
An absent `config/wedge-alarm` behaves as `auto`, which is default-on on macOS.
Away-mode delivery alarms fire only after a genuine max-defer wedge and are rate-limited to at most once per max-defer window.

Each channel is best-effort.
A missing binary or non-zero exit logs a warning and continues to the next channel without crashing the daemon loop.
Every invocation is process-group bounded by `FM_WEDGE_ALARM_TIMEOUT_SECS`, which defaults to 10 seconds, including `command:`, `osascript`, and the test seam.
On timeout or daemon shutdown, the notifier process group is terminated and the next configured channel may run.
AppleScript receives the summary as an argv item rather than interpolated source, so summary text cannot alter the script.
See [`examples/wedge-alarm`](examples/wedge-alarm) for a copyable config.

## Primary down alert

The `deck chat` primary service also uses these channels, seam and bounds; the [chat host header](../bin/fm-deck-chat.sh) owns service commands and the [keeper's `service` docstring](../bin/fm_primary_chat.py) owns outage detection, alert deduplication and marker recovery.

## Test safety

Every notifier routes through `FM_WEDGE_ALARM_EXEC` in `wedge_alarm_emit`.
When the daemon is sourced as a library, that seam defaults to `discard`, so direct library tests cannot accidentally post a real notification.
The primary's `service-alert` entrypoint restores the caller's seam after sourcing, so tests invoking it must explicitly set `FM_WEDGE_ALARM_EXEC` to a recorder or `discard`.
`tests/wake-helpers.sh` replaces it with a recorder when a suite needs to assert channel selection and summary propagation.
Production leaves the seam unset and uses the configured real channels.

`tests/fm-daemon.test.sh` covers directive parsing, rate limiting, timeout and process-group cleanup, argv-safe dispatch, channel fallback, and safe `command:` summary delivery.
[`verification/supervision.md`](verification/supervision.md#wedge-alarm-channels) records the bounded manual channel proof.
