# Live validation: a Deck secondmate survives a failed turn

Branch `fm/fm-deck-secondmate-survives-failed-turn`, base `4ad0e8fe`, target `7f27d1a6`.
Product surface: the persistent Deck second-mate driver `bin/fm-deck-worker.sh --secondmate` and the
pane transcript its captain/parent sees, plus the parent status channel it publishes to.
No rendered GUI exists for this change, so the reviewer-visible artifacts are verbatim terminal pane
transcripts, the parent status file, the busy-state record, and the real vendor's NDJSON.

Two independent rigs were driven:

1. The repository's own rig - `bin/fm-test-run.sh` over `tests/fm-deck-harness.test.sh`, which runs the
   real driver, real `fm-busy-event.sh`, real watcher arming, real status/turn-end publication and real
   process supervision against a PATH-shimmed `deck` (the runbook's endorsed shim pattern).
2. The real vendor - the real `bin/fm-deck-worker.sh --secondmate` driving the real `deck 0.1.0` binary
   against the real local proxai gateway on 127.0.0.1:8329, with two genuine failure modes and no model
   spend: a route the gateway refuses (`HTTP 404`) and a missing gateway key file
   (`error: resolve gateway client key: read key file ... No such file or directory`).

## Scenarios

| # | Scenario | Result | Evidence |
|---|---|---|---|
| 1 | Mate launched into an outage: first turn fails at the gateway, mate still reaches its prompt | pass (live, real vendor) | `real-vendor-run-target.txt`, `real-vendor-pane-target.txt` |
| 2 | Later turn fails: failure published, next wake resumes the SAME Deck session | pass (live, real vendor) | `real-vendor-report-target.txt` |
| 3 | Adversarial: six consecutive failing wakes - every failure published, one session, watcher still rings, `/quit` clean | pass (live) | `adversarial-repeated-failures.txt`, `adversarial-pane-transcript.txt`, `adversarial-parent-status.txt` |
| 4 | Missing gateway key: no session at all, mate parks, retained launch brief re-delivered once under the next wake, that session kept, brief not repeated again | pass (live, real vendor) | `real-vendor-nosession-recover.txt` |
| 5 | Missing key that never clears: repeated brief opens no session either, driver stops for the guarded relaunch with a published reason | pass (live, real vendor) | `real-vendor-nosession-stop.txt` |
| 6 | A failure the driver cannot publish still stops it (no blind loop) | pass (live, repo rig) | `deck-harness-target-commit.txt`, `base-worker-test_secondmate_stops_when_a_failed_turn_cannot_be_recorded.txt` |
| 7 | Crewmate failed-turn behavior unchanged, never takes the secondmate survival path | pass (live, repo rig) | `deck-harness-target-commit.txt` |
| 8 | Startup and watcher failures still stop the driver (survival scoped to turns) | pass (live, repo rig) | `deck-harness-target-commit.txt` |
| 9 | Regression: without the change the same real outage kills the mate | reproduced (live, real vendor + repo rig) | `real-vendor-run-base.txt`, `real-vendor-nosession-base.txt`, `deck-harness-base-worker-regression.txt`, `base-worker-*.txt` |
| 10 | A real *successful* model turn on the resumed session after a real failure | untested | needs `FM_DECK_LIVE=1` + `FM_DECK_LIVE_MODEL=<route with quota>` (real spend, real agent run) |

## Headline transcript: real driver + real deck + real gateway refusal (target commit)

```
⛵ deck working - ctrl+c to stop

✗ turn failed: model gateway request failed (HTTP 404)
fm-deck-worker: turn failed (turn-failed, exit 1)

⛵ turn failed; waiting at the prompt for the next wake.

❯
⛵ deck working - ctrl+c to stop

✗ turn failed: model gateway request failed (HTTP 404)
fm-deck-worker: turn failed (turn-failed, exit 1)

⛵ turn failed; waiting at the prompt for the next wake.

❯
```

parent/host.status after the same run (each failure stayed published):

```
failed: Deck secondmate turn failed (turn-failed, exit 1)
failed: Deck secondmate turn failed (turn-failed, exit 1)
```

The same run against the pre-change worker (`4ad0e8fe`) ends after the first failure with no prompt and
exit code 1 - the mate's home loses its supervisor (`real-vendor-pane-base.txt`).

## Headline transcript: real missing-gateway-key outage, launch brief re-delivered (target commit)

```
⛵ deck working - ctrl+c to stop
error: resolve gateway client key: read key file .../proxai-client.key: No such file or directory (os error 2)
fm-deck-worker: turn failed (turn-failed, exit 1)

⛵ turn failed; waiting at the prompt for the next wake.

❯
```

Turn 1 emitted no `run_started` at all (empty NDJSON). After the key file appeared, turn 2 carried the
retained launch brief plus the wake text and opened real session `s-1790197556-fe615b0e`; turn 3 resumed
that same session (real deck echoed `run_started` with the identical id) and did not repeat the brief
again. With the key never appearing, turn 2 repeated the brief, opened no session, and the driver stopped
with `failed: Deck secondmate opened no Deck session even after repeating the launch brief; stopping for a
guarded relaunch` - the parent's relaunch path fires instead of a blind park.

## Adjacent suites

- `FM_LIVE=0 bin/fm-test-run.sh tests/fm-control-relaunch.test.sh` - bounded at 900s; 47 cases passed
  including all six Deck relaunch/stop cases (`adjacent-fm-control-relaunch.txt`).
- `FM_LIVE=0 bin/fm-test-run.sh tests/fm-documentation-audiences.test.sh tests/fm-sessionstart-nudge.test.sh`
  - both pass, so the two doc edits keep the docs registry and session-start nudge contracts
  (`adjacent-docs-and-sessionstart-nudge.txt`).
