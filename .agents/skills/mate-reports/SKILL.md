---
name: mate-reports
description: >-
  Agent-only guide for reading another mate's report, or the whole fleet's, read-only.
  Use before asking a peer what it is doing, before starting work that may overlap another domain, or when the captain or first mate asks what another mate shipped, is waiting on, or has running.
  Covers bin/fm-report.sh, what each section means, and its limits.
user-invocable: false
metadata:
  internal: true
---

# mate-reports

Every mate can read every other mate's report, the same one Fleet Town's Report button shows, computed from firstmate's own records.
Reading costs the reported mate nothing: no message, no turn, no tokens.

## Read

```sh
bin/fm-report.sh <mate-id>            # today
bin/fm-report.sh <mate-id> --days 7   # the last seven days
bin/fm-report.sh fleet                # every mate, plus the fleet's power left per provider
bin/fm-report.sh primary              # the first mate's own crew
bin/fm-report.sh <mate-id> --json     # the stable fm-report.v1 shape (bin/fm_report.py owns it)
```

Ids come from `bin/fm-mates.sh list` (`mate-messaging` skill).
On the first mate's machine the report prints now.
On another machine the request rides your parent channel and the report arrives in your inbox as a first-mate message, usually within a minute.

## What it says

- Headline: shipped, working now, crew time, and waiting, for the period.
- What's waiting: open decisions on the captain, holds and what they wait on, and crew stuck on their mate.
- The crew right now: each worker, its task, and its current state.
- What shipped: landed work with its PR, by completion date.
- Time worked: busy time per worker from the busy-state records, counted only since those records began (the footer says since when).
- Power (fleet only): each provider's share left and when its tightest window refills.

## Limits

- A remote mate's report is as fresh as its last published summary; the footer and `gaps` name anything stale or unreadable.
- It is read-only: to ask the mate something, message it (`mate-messaging`); to change its work, go through the first mate.
- Do not paste whole reports onto your parent channel: point at what matters.
