# fm-supervisor-declared-external-wait - live validation evidence

Branch fm/fm-supervisor-declared-external-wait, target aa2f8131, base 6ae82ccc.
All commands run from the worktree root.

## 1. Focused suite at target (all 9 tests pass)

Command: `FM_LIVE=0 bin/fm-test-run.sh tests/fm-external-wait.test.sh`

```
ok - declare records who and why, with a bound, and never touches the worker's status log
ok - declare refuses a missing or malformed field and any expected clear time that is not in the future
ok - clear and replace archive the record with who ended it and why, and clear is idempotent
ok - two archives that would share one name keep both audit records
ok - an expired declaration reads as expired (ordinary escalation restored) while the attribution stays readable
ok - a live supervisor declaration absorbs the wedge ladder and clears its escalation counter
ok - an expired declaration restores ordinary wedge escalation
ok - the bounded recheck names the declarer, reason, and expected clear time, distinct from a worker pause
ok - a genuinely new status event still wakes immediately while a declaration is in force
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=34271
```

## 2. Regression proof without the change

(a) Both source files reverted to base (script absent, watcher at base):

```
not ok - declare failed:  (bin/fm-external-wait.sh: No such file or directory)
FM_TEST_SUMMARY total=1 failed=1
```

(b) Sharper: record script kept at target, ONLY bin/fm-watch.sh reverted to base.
The record-lifecycle tests pass, and the watcher absorb test fails with exactly
the failure mode the intent names - a healthy parked pane under a live
supervisor declaration is escalated as a possible wedge instead of absorbed:

```
ok - declare records who and why, with a bound, and never touches the worker's status log
ok - declare refuses a missing or malformed field and any expected clear time that is not in the future
ok - clear and replace archive the record with who ended it and why, and clear is idempotent
ok - two archives that would share one name keep both audit records
ok - an expired declaration reads as expired (ordinary escalation restored) while the attribution stays readable
not ok - the watcher died instead of absorbing: stale: test:fm-parked (idle 503s, possible wedge, escalation 3, demand-deep-inspection: same pane has wedge-escalated 3 times in a row - do not re-absorb on the run-step/pane state alone)
FM_TEST_SUMMARY total=1 failed=1
```

After restoring the target watcher, the suite is green again (section 1 rerun).

## 3. Manual end-to-end drive of the real CLI (isolated home under /tmp)

```
$ FM_HOME=$H FM_STATE_OVERRIDE=$H/state bin/fm-external-wait.sh declare tk1 \
    --reason "provider outage, generation stopped" \
    --until 2026-09-25T10:04:20Z --by "firstmate (supervisor)"
$H/state/tk1.external-wait                      # rc=0

$ ... show tk1
version: 1
task: tk1
declared: 2026-09-25T08:04:20Z
declared_epoch: 1790323460
declared_by: firstmate (supervisor)
reason: provider outage, generation stopped
until: 2026-09-25T10:04:20Z
until_epoch: 1790330660
verdict: active

$ ... list
tk1 active until=2026-09-25T10:04:20Z provider outage, generation stopped

$ ... active tk1                                 # rc=0

Refusals (each exit 2, nothing written):
  declare tk2 --until <future>            -> "a non-empty single-line --reason is required"
  declare tk2 --reason x --until not-a-time -> "--until must be a UTC ISO 8601 time ..."
  declare tk2 --reason x --until <10m past> -> "--until must be in the future (a declaration is bounded by its expected clear time) ..."

Worker's status log untouched by declare: still exactly "working: parked on the provider".

$ ... clear tk1 --by "the captain"
cleared: tk1                                     # rc=0
$ ... show tk1
verdict: absent
$ cat $H/state/external-waits/*-tk1.external-wait
version: 1
task: tk1
declared: 2026-09-25T08:04:20Z
declared_epoch: 1790323460
declared_by: firstmate (supervisor)
reason: provider outage, generation stopped
until: 2026-09-25T10:04:20Z
until_epoch: 1790330660
ended: 2026-09-25T08:04:28Z
ended_epoch: 1790323468
ended_by: the captain
outcome: cleared
```

The archived audit record keeps who declared it, why, and the bound, and records
who ended it and how - distinct from a worker-authored `paused:` status line
(which never appears anywhere in this flow; the status log is never written by
the supervisor record).
