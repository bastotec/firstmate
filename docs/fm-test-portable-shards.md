# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The current balance hint baselines come from fully serial runs of the real lanes on `ubuntu-latest`; future refreshes use the concurrent execution conditions described below.
The concurrent isolation proof in [fm-test-isolation-proof.md](fm-test-isolation-proof.md) establishes concurrency safety, not CI duration.
Local timings are not interchangeable with CI timings: platform and machine load can affect each script differently and change their relative weights.

The parallel hint baseline uses the slowest completed value each script reached across six CI runs on 2026-09-10; later replacements are recorded under [Parallel lanes](#parallel-lanes): [34459949083](https://github.com/kunchenguid/firstmate/actions/runs/34459949083), [34460760299](https://github.com/kunchenguid/firstmate/actions/runs/34460760299), [34462530836](https://github.com/kunchenguid/firstmate/actions/runs/34462530836), [34462758357](https://github.com/kunchenguid/firstmate/actions/runs/34462758357), [34466966385](https://github.com/kunchenguid/firstmate/actions/runs/34466966385), and [34470382458](https://github.com/kunchenguid/firstmate/actions/runs/34470382458).
Shard 2 completed in all six, so its scripts come from the uploaded `fm-test-timing-portable-parallel-2` artifacts.
Shard 1 was cancelled at its job cap in five of the six, so its scripts come from the `FM_TEST_END duration_ms=` markers in each cancelled job's log, which record every script that finished before the cancellation, plus the one complete `fm-test-timing-portable-parallel-1` artifact from run 34462758357.
Observed maxima provide conservative packing weights, not an upper bound on future durations.

Those six runs cover all 24 candidates, with six samples per script except:

| Samples | Scripts |
|---:|---|
| 4 | `tests/fm-lint.test.sh` |
| 3 | `tests/fm-pi-primary-types.test.sh`, `tests/fm-review-diff.test.sh` |
| 1 | `tests/fm-brief.test.sh`, `tests/fm-transition-lib.test.sh` |

The two scripts with one sample are the tail of shard 1 that only the complete run reached.
Collect completed per-script measurements for every member before calculating a split.
A cancelled lane's elapsed duration is only a lower bound; its unfinished scripts have no completed duration for that invocation.
The complete historical run supplies tail-script hints, not a completion time for any later cancelled invocation or for the rebalanced jobs.

## Parallel lanes

CI runs the whole proven-isolated set as one job, `bin/fm-test-run.sh --proven-isolated --jobs 4`, four workers at once, which is the concurrency [fm-test-isolation-proof.md](fm-test-isolation-proof.md) proved for that set.
The run starts its scripts longest-hint-first from `portable_parallel_weight_hints`, so the longest member, `tests/fm-captain-hold-lifecycle.test.sh`, starts at once and sets the job's floor while the rest of the set packs beside it.

The two `portable-parallel-1`/`-2` lanes remain a duration-balanced split of the same set, for a local or two-runner reproduction; CI no longer runs them as separate jobs.
They use longest-processing-time assignment over those hints.
The hints for `tests/fm-lint.test.sh` and `tests/fm-test-run.test.sh` were refreshed to 212915 ms and 151312 ms from the completed script markers in [run 37361945831, parallel job 1](https://github.com/bastotec/firstmate/actions/runs/37361945831/job/111938422392), which reached its old 10-minute cap after 583 seconds of script time.
Repacking with those hints estimates about 469 seconds per lane and retains `tests/fm-pi-primary-types.test.sh` in lane 1.
[`bin/fm-test-run.sh`](../bin/fm-test-run.sh) holds the duration values in `portable_parallel_weight_hints` and the ordered memberships beside `list_portable_parallel_1` and `list_portable_parallel_2`.
Read the derived packing estimates with that runner's `--check-coverage`; its header and `--help` own the output fields and the selection-specific `--list-scheduled` weight rules.
The largest individual hint sets a lower bound on the estimated duration of any split, regardless of how evenly the remaining work is assigned.
The CI cap and its rationale are owned by [`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_parallel_lanes_stay_duration_balanced`, requires every parallel member to have a hint and the lane sums to differ by no more than five percent of the larger sum.
Its scheduling regressions also check stored parallel lane order, the proven-isolated set's longest-first order, and serial-weight scheduling for other selections.
These checks do not detect a script outgrowing an existing hint or establish measured job headroom.
Refresh `portable_parallel_weight_hints` with the slowest completed `duration_ms` per script from several green CI runs' `fm-test-timing-portable-parallel` artifacts whenever the set gains scripts or a member grows materially.
New artifacts measure scripts sharing the runner at the job's configured concurrency, so refreshed hints include that contention; the historical serial hints above do not establish concurrent job duration.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is neither proven-isolated nor `real-herdr-gated`.
It keeps watcher, lock, AFK, real tmux, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, and other unproven work serial.
Membership is derived rather than enumerated, so a newly added test lands here by default.

## Portable serial CI shards

On green CI run [30725985757](https://github.com/kunchenguid/firstmate/actions/runs/30725985757), that remainder accumulated 19m04s of script time against a 20-minute job timeout.
On [PR 1495](https://github.com/kunchenguid/firstmate/pull/1495), its main step ran about 19m51s before the job was cancelled at that boundary.
`portable-serial-<k>of<n>` splits it across `n` separate CI runners.

[`bin/fm-test-run.sh`](../bin/fm-test-run.sh)'s header owns the shard phase schedule, worker count, isolation boundaries, and explicit `--jobs` overrides.
Family-phase admission rests on the evidence in [fm-test-isolation-proof.md](fm-test-isolation-proof.md#family-concurrency-proofs), not on treating all serial-lane scripts as independently isolated.
The runner's `PORTABLE_SERIAL_PHASE_JOBS` rationale preserves CPU headroom because the watcher proof is sensitive to starvation on hosted runners.

`bin/fm-test-run.sh` owns `n` and refuses any lane whose `of<n>` disagrees with it.
`.github/workflows/ci.yml` derives the same `n` from `strategy.job-total` rather than a literal, so changing the shard count in either file without the other fails the lane loudly instead of leaving part of the required suite unrun.

`portable_serial_assignments` in [`bin/fm-test-run.sh`](../bin/fm-test-run.sh) owns the phase-aware longest-processing-time packing algorithm; its comments define how family worker loads and unproven hints contribute to the estimate.
The embedded hints are the slowest completed `duration_ms` per script from the `fm-test-timing-portable-serial-*` artifacts of seven green CI runs from 2026-10-04 to 2026-10-06, [37272453924](https://github.com/bastotec/firstmate/actions/runs/37272453924), [37251695405](https://github.com/bastotec/firstmate/actions/runs/37251695405), [37253443319](https://github.com/bastotec/firstmate/actions/runs/37253443319), [37247916281](https://github.com/bastotec/firstmate/actions/runs/37247916281), [37397713888](https://github.com/bastotec/firstmate/actions/runs/37397713888), [37401433503](https://github.com/bastotec/firstmate/actions/runs/37401433503), and [37413095868](https://github.com/bastotec/firstmate/actions/runs/37413095868), plus the 5121 ms native-Windows focused runner measurement for `tests/fm-pi-windows-shell-invocation.test.sh` from 2026-09-06T21:02Z.
Taking the slowest of several CI runs rather than a single run keeps the balance honest on a slow runner.
A script with no hint gets the conservative `PORTABLE_SERIAL_DEFAULT_WEIGHT_MS` default.
Hints only affect balance: the coverage guard keeps the partition complete and disjoint whatever they say, so a stale hint costs a slower shard rather than lost coverage.
Balance is still worth keeping current, because enough unmeasured scripts let one shard carry more than twice another shard's real work and reach the job cap while another runner sits idle.
That is not hypothetical: by 2026-09-01 the lane had grown from 116 to 139 scripts and from ~42 to ~63 minutes, 17 scripts were still unmeasured, and several hints were low by 2-5x, so shard 3 of 4 ran 17-20 minutes against its 20-minute cap while shard 1 ran 11.5 minutes and run [33574154856](https://github.com/kunchenguid/firstmate/actions/runs/33574154856) timed out seconds after a passing test.
`bin/fm-test-run.sh --check-coverage` now reports the unmeasured share as `serial_unhinted=` and refuses past `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so hint drift fails the coverage guard instead of silently pushing one shard into its job cap.
Refresh the hints whenever the serial lane gains scripts, rather than waiting for that bound to trip.

`bin/fm-test-run.sh` owns the per-shard packing, so its `--check-coverage` output is the current account of lane size, shard count, phase workers, and the slowest shard's packed estimate (`serial_max_ms=`) rather than a copied table.
Before the phase model, twelve fully serial shards ran 8-14 minutes on runs 37397713888 and 37401433503, and the single-script `tests/fm-watch-triage.test.sh` (about 11 minutes) was the floor for any shard count.
That script is now five topic suites, `tests/fm-watch-triage*.test.sh`, sharing `tests/watch-triage-helpers.sh`; each case lives in exactly one of them, and each carries its cases' share of the old script's hint, from the per-case output timestamps of run 37401433503.
The phase-model packing estimate is not a measured concurrent job duration; use `serial_max_ms=` for its current critical-path estimate.
The first phase-model run, [37413095868](https://github.com/bastotec/firstmate/actions/runs/37413095868), finished in 11m23s with its two slowest shards at 647 seconds of script time against a 518-second mean: three-way phases slowed the heaviest family scripts by up to half (`tests/fm-backlog-atomicity.test.sh` went from 289 to 376 seconds), which hints measured before the phase model did not carry.
That run's durations are now in the hints.

Refresh the CI-derived hints by downloading the per-shard timing artifacts from several green CI runs and replacing the `portable_serial_weight_hints` table in `bin/fm-test-run.sh` with the slowest measured `duration_ms` per `path`:

```sh
for run in <run-id> <run-id> <run-id>; do
  gh run download "$run" -R bastotec/firstmate --pattern 'fm-test-timing-portable-serial-*' -D "/tmp/fm-serial/$run"
done
jq -r '.scripts[] | [.path, .duration_ms] | @tsv' /tmp/fm-serial/*/*.json \
  | awk -F'\t' '$2 > m[$1] { m[$1] = $2 } END { for (p in m) print p, m[p] }' \
  | LC_ALL=C sort
bin/fm-test-run.sh --check-coverage
```

A timed-out shard uploads no artifact, so pick runs where every serial shard is green or the lane's slowest scripts go unmeasured in exactly the shard that needs them most.
New family-phase artifacts measure scripts beside their phase siblings, so refreshed hints include that contention; the current historical hints and split-suite shares above were measured without it.
Measure native-Windows-only scripts through the focused Git Bash runner and retain that `duration_ms` separately, because the portable CI shards skip them.
Opt-in live-harness timing hints can measure credential-free CI skips, not native harness execution; `tests/lib.sh`'s `fm_live_gate` owns that skip policy.

## Coverage guard

CI runs `bin/fm-test-run.sh --check-coverage` in the `Repo invariants` job.
It verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes, portable serial lane, and real-Herdr family are disjoint and cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
It reports the unmeasured serial share as `serial_unhinted=` and refuses when that share exceeds `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so the shards stay balanced on evidence rather than on the default weight.

[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh)'s `test_portable_serial_shard_survives_a_stalled_consumer` checks listing completeness under pipe backpressure and a producer exit, using `/bin/bash` when available; `emit_via_file` in [`bin/fm-test-run.sh`](../bin/fm-test-run.sh) owns the pipe-write safety rationale.
A pass on Bash 5 alone does not establish the Bash 3.2 regression, because Bash 5 restarts the interrupted pipe write.

## Timing artifacts

The portable parallel job, each portable serial shard, and the Herdr lane upload runner-generated timing JSON.
`bin/fm-test-run.sh --aggregate-json` creates the combined summary artifact.
`.github/workflows/ci.yml` owns the exact artifact names and aggregation wiring.

## Local entry points

[CONTRIBUTING.md](../CONTRIBUTING.md) owns the local test policy and common entry points.
`bin/fm-test-run.sh --help` owns exact lane names, selection flags, and bounded `--jobs` mechanics.

## Timeouts

| Lane | Bound | Rationale |
|---|---|---|
| portable parallel | See [CI workflow](../.github/workflows/ci.yml) | The workflow owns the parallel cap rationale and its evidence limits. |
| portable serial shards | See [CI workflow](../.github/workflows/ci.yml) | The workflow owns the serial cap and its setup and runner-speed margin; the packing evidence is above. |
| Herdr | family-run step `timeout-minutes: 20`; job `timeout-minutes: 75` backstop | Healthy runs finished around 7 minutes before this lane gained `fm-backend-herdr-focus-flash-e2e`, which measures about 2 minutes against a real lab locally, so the step bound is still the hang tripwire (cleanup and timing artifacts still upload) while the job cap stays a last-resort backstop. Refresh this figure from the lane's uploaded timing artifact. |

Timeouts are intended as hang tripwires; a passing coverage guard does not establish a healthy job duration.
`.github/workflows/ci.yml` owns the exact numbers.
