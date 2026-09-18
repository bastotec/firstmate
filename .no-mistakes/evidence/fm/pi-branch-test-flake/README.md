# Live validation: supervision-branch settlement flake

Suite: `tests/fm-pi-branch-extension.test.sh`, case
`test_captain_outcome_processing_turn_is_sequence_keyed_and_re_presented`.

## How the flake was reproduced deterministically

A stall was injected into the suite's own Pi SDK stub, immediately after the
branch session is pushed into `globalThis.__fmSessions` and before
`createAgentSession` returns - i.e. exactly the window between "the session is
built" and "the extension takes its durable-outcome baseline and calls
session.prompt()". This is the gap the commit message names. The probe was a
throwaway copy of the suite running only the affected case; both probe copies
were deleted afterwards and the worktree is clean.

Two probe variants, identical except for one line:
* prechange: `await settle(() => __fmSessions.length === 2, ...)`  (pre-fix)
* fixed:     `await settle(() => __fmPrompts.length === 2, ...)`   (HEAD)

## Results

| injected stall | variant   | runs | pass | fail |
|---------------:|-----------|-----:|-----:|-----:|
| 60 ms          | prechange |   10 |    0 |   10 |
| 60 ms          | fixed     |   10 |   10 |    0 |
| 400 ms         | prechange |   10 |    0 |   10 |
| 400 ms         | fixed     |   10 |   10 |    0 |
| none           | fixed     |   25 |   25 |    0 |

Every pre-change failure is the exact CI error, at the exact reported site:

    not ok - captain outcomes must be processed through a sequence-bound
    acknowledgement and re-presented until then:
    .../.pi/extensions/fm-branch-supervision.ts:1466
    Error: supervision branch prompt settled but produced no durable outcome
    for its claimed wake rows

See `flake-repro.log`.

## Adversarial check: the assertion is still load-bearing

A third probe kept the fix's prompt-wait but removed the `fm_branch_report`
call, so the branch really does produce no durable outcome for its wake. The
case failed with the same settlement error (exit 1), proving the fix restored
the correct ordering rather than disabling or weakening the guard.
See `adversarial-guard-still-live.log`.

## Whole-suite runs

`FM_LIVE=0 bin/fm-test-run.sh tests/fm-pi-branch-extension.test.sh` run 4x:
all exit=0, ~92-96 s each. See `suite-repeat.log`.
