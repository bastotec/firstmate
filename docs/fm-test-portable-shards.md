# Firstmate portable test shards

`bin/fm-test-run.sh` owns portable lane composition and execution.
`bin/fm-test-isolation-proof.sh` owns the proven-isolated candidate set.

## Verification inputs

The balance hints come from CI measurements on `ubuntu-latest`; [Parallel lanes](#parallel-lanes) and [Portable serial CI shards](#portable-serial-ci-shards) own each set's provenance and measured concurrency.
The concurrent isolation proof in [fm-test-isolation-proof.md](fm-test-isolation-proof.md) establishes concurrency safety, not CI duration.
Local timings are not interchangeable with CI timings: platform and machine load can affect each script differently and change their relative weights.

Collect completed per-script measurements for every member before calculating a split.
A cancelled lane's elapsed duration is only a lower bound; its unfinished scripts have no completed duration for that invocation.
Observed maxima provide conservative packing weights, not an upper bound on future durations.

## Parallel lanes

CI runs the whole proven-isolated set as one job, `bin/fm-test-run.sh --proven-isolated --jobs 4`, four workers at once, which is the concurrency [fm-test-isolation-proof.md](fm-test-isolation-proof.md) proved for that set.
The run starts its scripts longest-hint-first from `portable_parallel_weight_hints`, so the longest member, `tests/fm-captain-hold-lifecycle.test.sh`, starts at once and sets the job's floor while the rest of the set packs beside it.

The two `portable-parallel-1`/`-2` lanes remain a duration-balanced split of the same set, for a local or two-runner reproduction; CI does not run them as separate jobs.
They use longest-processing-time assignment over those hints.
[`bin/fm-test-run.sh`](../bin/fm-test-run.sh) holds the duration values in `portable_parallel_weight_hints` and the ordered memberships beside `list_portable_parallel_1` and `list_portable_parallel_2`.
Read the derived packing estimates with that runner's `--check-coverage`; its header and `--help` own the output fields and the selection-specific `--list-scheduled` weight rules.
The largest individual hint sets a lower bound on the estimated duration of any split, regardless of how evenly the remaining work is assigned.
The CI cap and its rationale are owned by [`.github/workflows/ci.yml`](../.github/workflows/ci.yml).

Every current hint is the completed `duration_ms` from the `fm-test-timing-portable-parallel` artifact of green CI run [37527983434](https://github.com/bastotec/firstmate/actions/runs/37527983434) on 2026-10-06, the first run after the tmux and herdr backends were removed.
That job ran the set at `--jobs 4`, so the hints carry four-worker contention: `tests/fm-captain-hold-lifecycle.test.sh` measured 483410 ms and the job took 8m27s from start to finish, setup included.
The hints come from that one run, so a slower runner can exceed them; prefer the slowest value across several green runs at the next refresh.

[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh), in `test_portable_parallel_lanes_stay_duration_balanced`, requires every parallel member to have a hint and the lane sums to differ by no more than five percent of the larger sum.
Its scheduling regressions also check stored parallel lane order, the proven-isolated set's longest-first order, and serial-weight scheduling for other selections.
These checks do not detect a script outgrowing an existing hint or establish measured job headroom.
Refresh `portable_parallel_weight_hints` with the slowest completed `duration_ms` per script from several green CI runs' `fm-test-timing-portable-parallel` artifacts whenever the set gains scripts or a member grows materially.

## Portable serial remainder

`portable-serial` includes every `tests/*.test.sh` that is not proven-isolated.
It keeps watcher, lock, AFK, daemon, secondmate lifecycle, bootstrap, the `live-harness-optin` family, and other unproven work serial.
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
The embedded hints are the slowest completed `duration_ms` per script from the `fm-test-timing-portable-serial-*` artifacts of eight green CI runs from 2026-10-04 to 2026-10-06: [37272453924](https://github.com/bastotec/firstmate/actions/runs/37272453924), [37251695405](https://github.com/bastotec/firstmate/actions/runs/37251695405), [37253443319](https://github.com/bastotec/firstmate/actions/runs/37253443319), [37247916281](https://github.com/bastotec/firstmate/actions/runs/37247916281), [37397713888](https://github.com/bastotec/firstmate/actions/runs/37397713888), [37401433503](https://github.com/bastotec/firstmate/actions/runs/37401433503), [37413095868](https://github.com/bastotec/firstmate/actions/runs/37413095868), and [37527983434](https://github.com/bastotec/firstmate/actions/runs/37527983434).
The last of those is the first stream-only run.
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
Family-phase artifacts measure scripts beside their phase siblings, so refreshed hints include that contention.
The pre-phase measurements and split-suite shares remain serial baselines, not measured concurrent durations.
Opt-in live-harness timing hints can measure credential-free CI skips, not native harness execution; `tests/lib.sh`'s `fm_live_gate` owns that skip policy.

## Coverage guard

CI runs `bin/fm-test-run.sh --check-coverage` in the `Repo invariants` job.
It verifies that both parallel lanes partition the proven-isolated set.
It also verifies that the parallel lanes and the portable serial lane are disjoint and together cover every `tests/*.test.sh` script.
It separately verifies that the portable serial CI shards are non-empty, disjoint, and together equal the portable serial lane.
It reports the unmeasured serial share as `serial_unhinted=` and refuses when that share exceeds `PORTABLE_SERIAL_MAX_UNHINTED_PERCENT`, so the shards stay balanced on evidence rather than on the default weight.

[`tests/fm-test-run.test.sh`](../tests/fm-test-run.test.sh)'s `test_portable_serial_shard_survives_a_stalled_consumer` checks listing completeness under pipe backpressure and a producer exit, using `/bin/bash` when available; `emit_via_file` in [`bin/fm-test-run.sh`](../bin/fm-test-run.sh) owns the pipe-write safety rationale.
A pass on Bash 5 alone does not establish the Bash 3.2 regression, because Bash 5 restarts the interrupted pipe write.

## Timing artifacts

The portable parallel job and each portable serial shard upload runner-generated timing JSON.
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

Timeouts are intended as hang tripwires; a passing coverage guard does not establish a healthy job duration.
`.github/workflows/ci.yml` owns the exact numbers.
