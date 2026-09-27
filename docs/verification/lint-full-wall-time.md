# Full-lint wall time: wave scheduler vs two-shard baseline

Measured 2026-09-25 on the branch before the reservation-table rebind, at a
commit whose lint-owner files are byte-identical to `4d27cdfe`
(Darwin arm64, 8 detected CPUs, pinned ShellCheck 0.11.0), full 424-root
canonical set, back-to-back waves with the host 1-minute load average sampled
every 30 s beside each run.

| Variant | Wall | rc | Mean 1-min load |
|---|---|---|---|
| Baseline (pre-change two-shard, CI mode) | 3968 s | 0 | 28.4 |
| Branch, detected CPUs (8) | 2601 s | 0 | 128.5 |
| Branch, FM_LINT_JOBS=1 | 2387 s | 0 | 84.3 |
| Branch, FM_LINT_JOBS=4 | 1443 s | 0 | 24.0 |
| Branch, 7 pre-rebind over-budget roots alone | 873 s | 0 | 132.6 |

Reading the numbers honestly:

- Every branch shape beat the baseline. `FM_LINT_JOBS=4`, run at load 24.0
  against the baseline's 28.4, is the closest to a fair same-load pair and
  finished in 1443 s - 2.7x faster than the 3968 s baseline.
- The detected-CPU run finished 34 percent faster than baseline while the
  host carried 4.5x the load, so 2601 s is a floor for what an idle host
  would show, not a prediction of it.
- The matrix above was measured against the pre-rebind reservation table,
  whose seven over-budget roots (padded reservation above the 6144 MiB
  admission budget) cost 873 s alone - 60 percent of the jobs=4 full run and
  22 percent of the baseline. The shipped table (rebind `f35f9732`) carries
  eight: `bin/fm-send.sh` (padded 6800 MiB) and `bin/fm-spawn.sh` (7241 MiB)
  joined the set and `tests/fm-backend-herdr.test.sh` now fits, so one more
  giant than that 873 s figure covers serializes one per wave at the front
  of every `--full` run; the shipped table computes to 120 waves at jobs=4
  and 78 at the detected 8 CPUs. Whether to spend a larger budget on
  runners that can carry it, or accept a slower push-mode full lint while
  pull-request mode carries the speed win, is a caller decision this
  measurement informs.
- A CI runner is a different machine: these numbers bound the change on this
  host rather than predicting runner wall time. CI prints its own telemetry
  snapshot (`FM_LINT_TELEMETRY`) when the Lint job runs.

Raw logs, per-run telemetry TSVs and load samples:
`.no-mistakes/evidence/01M3AQXEWQY492J7WEV0CMDSE9/` (private task evidence).
