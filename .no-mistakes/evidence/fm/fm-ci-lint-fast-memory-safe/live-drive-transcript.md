# Live validation drives - fm/fm-ci-lint-fast-memory-safe @ 90810a0
Host: Darwin arm64, 8 CPUs, pinned ShellCheck 0.11.0 resolved, load ~14 during drives.

## Drive A - full-scale scheduler over the real 424-root set (real memory table)
Command: PATH=<recording-stub> CI=true bin/fm-lint.sh --full --jobs 4 --telemetry lint-full-stubbed-jobs4-telemetry.tsv
Analyzer stub records start/end per root; scheduler, planner, selection, memory table all real.
- rc=0, wall 117s, root_count=424, peak_parallel_roots=4, peak_reserved_mib=6144 (== budget, not over)
- stderr: NO "no measured reservation" diagnostic (0 of 424 unknown at shipped tree)
- event log: 424 roots started exactly once, max concurrent = 4, no duplicate/missing roots
- schedule shape recomputed with fm-lint.sh's own weight formula + wave awk over the real table:
  120 waves at jobs=4, 9 single-root waves, 8 over-budget roots (fm-teardown, fm-stat-shadowing.test,
  fm-remote-reply.test, fm-backlog-handoff, fm-watch, fm-spawn, fm-send, fm-pending-reply.test),
  0 heavy-pair violations, 0 jobs violations - matches docs/verification/lint-full-wall-time.md exactly.

## Drive B - real pinned ShellCheck, real repo roots, jobs=1 vs jobs=6 (18 light/mid roots)
- jobs=1: rc=0, wall 74s (telemetry wall_seconds=71), peak_parallel_roots=1, peak_reserved_mib=2295
- jobs=6: rc=0, wall 47s (telemetry wall_seconds=44), peak_parallel_roots=6, peak_reserved_mib=6099 <= 6144
- diagnostics stdout and stderr byte-identical (cmp) between job counts; canonical root order kept.

## Drive C - SIGTERM stops real worker trees mid-giant
CI=true TMPDIR=<isolated> bin/fm-lint.sh --full & -> first wave = bin/fm-backlog-handoff.sh alone
(real shellcheck, ~5 GiB reservation). kill -TERM parent:
- parent rc=143, real shellcheck child terminated (no survivor), fm-lint.* temp root removed.

## Drive D - PR affected-root mode, real ShellCheck + pre-change control
Fixture repo (real bin/fm-lint.sh + bin/fm-lint-plan.pl, git): leaf.sh <- middle.sh <- root.sh via
source= directives, plus an untouched bystander.sh; one-file PR edit to bin/leaf.sh.
- NEW owner: CI=true bin/fm-lint.sh --changed <base> --list-files -> bin/leaf.sh, bin/middle.sh,
  bin/root.sh (bystander excluded). Real lint run: analysis_mode=affected, root_count=3, and the
  real ShellCheck catch holds: SC2034 "value appears unused" in bin/leaf.sh line 2, rc=1.
- OLD owner (d5355a9:bin/fm-lint.sh) under CI=true, same one-file diff: lints ALL 8 canonical roots
  (lint-base-owner-pr-forces-full-roots.log) - the forced-full PR behavior this change removes.

## Suites
FM_LIVE=0 bin/fm-test-run.sh tests/fm-lint.test.sh        -> 46/46 ok (502s)
FM_LIVE=0 bin/fm-test-run.sh tests/fm-ci-workflow.test.sh -> 7/7 ok
