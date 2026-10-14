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
Reading spends no agent turn or model tokens on the reported mate.

## Read

The [`fm-report.sh` header](../../../bin/fm-report.sh) owns usage, scope names, time windows, and local versus remote request routing.
Use it for one mate, the first mate, or the fleet; choose markdown for reading or JSON for a consumer.
Find mate ids through [`mate-messaging`](../mate-messaging/SKILL.md).
[`fm_report.py`](../../../bin/fm_report.py) owns the data sources and stable JSON shape.

## What it says

- Headline: shipped and crew time for the period; working and waiting from the latest records.
- What's waiting: open decisions on the captain, holds and what they wait on, and crew stuck on their mate.
- The crew right now: each worker, its task, and its current state.
- What shipped: landed work with its PR, included by completion date within the period.
- Time worked: busy time per worker from the busy-state records, counted only since those records began (the footer says since when).
- Power (fleet only): each provider's share left and when its tightest window refills.

## Limits

- A remote mate's report is as fresh as its last published summary; the footer and `gaps` name anything stale or unreadable.
- It is read-only: to ask the mate something, message it (`mate-messaging`); to change its work, go through the first mate.
- Do not paste whole reports onto your parent channel: point at what matters.
