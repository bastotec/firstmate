# Full-lint wall time: wave scheduler vs two-shard baseline

Measured 2026-09-25 at commit `884f7468541b7c1f4553f54b40c4e86962b90ea2`
(Darwin arm64, 8 detected CPUs, pinned ShellCheck 0.11.0), full 424-root
canonical set, back-to-back waves with the host 1-minute load average sampled
every 30 s beside each run.

| Variant | Wall | rc | Mean 1-min load |
|---|---|---|---|
| Baseline (pre-change two-shard, CI mode) | 3968 s | 0 | 28.4 |
| Branch, detected CPUs (8) | 2601 s | 0 | 128.5 |
| Branch, FM_LINT_JOBS=1 | 2387 s | 0 | 84.3 |
| Branch, FM_LINT_JOBS=4 | 1443 s | 0 | 24.0 |
| Branch, 7 over-budget roots alone | 873 s | 0 | 132.6 |

Reading the numbers honestly:

- Every branch shape beat the baseline. `FM_LINT_JOBS=4`, run at load 24.0
  against the baseline's 28.4, is the closest to a fair same-load pair and
  finished in 1443 s - 2.7x faster than the 3968 s baseline.
- The detected-CPU run finished 34 percent faster than baseline while the
  host carried 4.5x the load, so 2601 s is a floor for what an idle host
  would show, not a prediction of it.
- The seven over-budget roots (padded reservation above the 6144 MiB
  admission budget) cost 873 s alone - 60 percent of the jobs=4 full run and
  22 percent of the baseline. They serialize one per wave at the front of
  every `--full` run; whether to spend a larger budget on runners that can
  carry it, or accept a slower push-mode full lint while pull-request mode
  carries the speed win, is a caller decision this measurement informs.
- A CI runner is a different machine: these numbers bound the change on this
  host rather than predicting runner wall time. CI prints its own telemetry
  snapshot (`FM_LINT_TELEMETRY`) when the Lint job runs.

Raw logs, per-run telemetry TSVs and load samples:
`.no-mistakes/evidence/01M3AQXEWQY492J7WEV0CMDSE9/` (private task evidence).
