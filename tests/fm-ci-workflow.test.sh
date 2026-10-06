#!/usr/bin/env bash
# Contract tests for .github/workflows/ci.yml's runner-spend safeguards.
#
# Origin: the 2026-09-12 GitHub Actions starvation incident. firstmate CI had no
# concurrency deduplication, so every superseded PR head kept its full job
# fan-out, and four jobs carried no timeout at all. These tests hold both
# safeguards: PR runs supersede within one PR while main pushes are never
# cancelled, and every CI job carries a finite hang tripwire.
#
# The workflow is parsed as YAML and its concurrency expressions are resolved
# against simulated pull_request and push contexts, so the assertions describe
# what GitHub would do, not how the file happens to be spelled.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh" || exit 1

CI_WORKFLOW="$ROOT/.github/workflows/ci.yml"

assert_present "$CI_WORKFLOW" ".github/workflows/ci.yml is missing"
command -v ruby >/dev/null 2>&1 \
  || fail "ruby is required to parse .github/workflows/ci.yml as YAML"

# Resolve the workflow's concurrency contract under one simulated event and
# print "<group><TAB><cancel-in-progress>". Only the two expression constructs
# this workflow uses are resolved: an `a || b` fallback and an `==` comparison.
resolve_concurrency() {
  local event=$1 pr_number=$2 run_id=$3
  ruby -ryaml -e '
doc = YAML.load_file(ARGV[0])
concurrency = doc.fetch("concurrency")
context = {
  "github.workflow" => doc.fetch("name"),
  "github.event_name" => ARGV[1],
  "github.event.pull_request.number" => ARGV[2],
  "github.run_id" => ARGV[3],
}

value = lambda do |token|
  token = token.strip
  next token[1..-2] if token.start_with?("\x27") && token.end_with?("\x27")
  raise "unresolvable context reference: #{token}" unless context.key?(token)
  context.fetch(token)
end

evaluate = lambda do |expression|
  expression = expression.strip
  if expression.include?("==")
    left, right = expression.split("==", 2)
    next value.call(left) == value.call(right) ? "true" : "false"
  end
  resolved = expression.split("||").map { |token| value.call(token) }.find { |v| !v.empty? }
  resolved.to_s
end

interpolate = lambda do |raw|
  raw.to_s.gsub(/\$\{\{(.+?)\}\}/) { evaluate.call(Regexp.last_match(1)) }
end

puts [interpolate.call(concurrency.fetch("group")),
      interpolate.call(concurrency.fetch("cancel-in-progress"))].join("\t")
' "$CI_WORKFLOW" "$event" "$pr_number" "$run_id"
}

job_timeout() {
  ruby -ryaml -e '
puts YAML.load_file(ARGV[0]).fetch("jobs").fetch(ARGV[1]).fetch("timeout-minutes", "none")
' "$CI_WORKFLOW" "$1"
}

group_of() { printf '%s\n' "$1" | cut -f1; }
cancel_of() { printf '%s\n' "$1" | cut -f2; }

test_pr_pushes_supersede_within_one_pr() {
  local first second
  first=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  second=$(resolve_concurrency pull_request 108 900002) || fail "could not resolve PR concurrency"
  [ "$(group_of "$first")" = "$(group_of "$second")" ] \
    || fail "two runs of one PR must share a concurrency group, got $(group_of "$first") and $(group_of "$second")"
  [ "$(cancel_of "$first")" = true ] \
    || fail "PR runs must cancel the in-progress run, got $(cancel_of "$first")"
  pass "a newer push to one PR supersedes that PR's in-flight CI"
}

test_separate_prs_do_not_cancel_each_other() {
  local one two
  one=$(resolve_concurrency pull_request 108 900001) || fail "could not resolve PR concurrency"
  two=$(resolve_concurrency pull_request 109 900003) || fail "could not resolve PR concurrency"
  [ "$(group_of "$one")" != "$(group_of "$two")" ] \
    || fail "distinct PRs must not share a concurrency group ($(group_of "$one"))"
  pass "distinct PRs get distinct concurrency groups"
}

test_main_pushes_are_never_cancelled() {
  local first second
  first=$(resolve_concurrency push '' 900010) || fail "could not resolve push concurrency"
  second=$(resolve_concurrency push '' 900011) || fail "could not resolve push concurrency"
  [ "$(group_of "$first")" != "$(group_of "$second")" ] \
    || fail "each main push must get its own concurrency group, got $(group_of "$first") twice"
  [ "$(cancel_of "$first")" = false ] \
    || fail "push runs must never cancel an in-progress run, got $(cancel_of "$first")"
  pass "every main push keeps its own group and is never cancelled"
}

test_every_job_has_a_finite_timeout() {
  local reported
  reported=$(ruby -ryaml -e '
YAML.load_file(ARGV[0]).fetch("jobs").each do |name, job|
  timeout = job["timeout-minutes"]
  next if timeout.is_a?(Integer) && timeout > 0
  puts "#{name}: #{timeout.inspect}"
end
' "$CI_WORKFLOW") || fail "could not read job timeouts from ci.yml"
  [ -z "$reported" ] || fail "these CI jobs have no finite hang tripwire:"$'\n'"$reported"
  pass "every ci.yml job carries a finite timeout"
}

test_previously_unbounded_jobs_keep_their_caps() {
  local job expected actual
  while read -r job expected; do
    [ -n "$job" ] || continue
    actual=$(job_timeout "$job") || fail "could not read the $job timeout"
    [ "$actual" = "$expected" ] \
      || fail "$job timeout must stay $expected minutes, got $actual"
  done <<'CAPS'
lint 15
tests-timing-aggregate 5
invariants 5
CAPS
  pass "the incident's unbounded jobs keep their authorized caps"
}

# Cancellation makes an undersized cap costlier: a falsely tripped job now also
# discards a run nobody replaced. These bounds were measured, not guessed.
test_measured_lanes_keep_their_authorized_bounds() {
  local job expected actual
  while read -r job expected; do
    [ -n "$job" ] || continue
    actual=$(job_timeout "$job") || fail "could not read the $job timeout"
    [ "$actual" = "$expected" ] \
      || fail "$job timeout must stay $expected minutes, got $actual"
  done <<'CAPS'
tests-portable-parallel 15
tests-portable-serial 15
macos-stock-bash 10
CAPS
  pass "the measured lane bounds match their authorized caps"
}

# The account runs at most 20 jobs at once, and the "Require no-mistakes" check
# takes one more slot per PR. Holding CI to 18 runner jobs keeps one PR's run
# from queueing behind itself; wall time comes from running proven-concurrent
# work inside a runner (bin/fm-test-run.sh), not from adding runners.
test_ci_stays_within_its_runner_budget() {
  local total
  total=$(ruby -ryaml -e '
total = YAML.load_file(ARGV[0]).fetch("jobs").sum do |_name, job|
  matrix = job.dig("strategy", "matrix") || {}
  matrix.values.select { |v| v.is_a?(Array) }.map(&:length).reduce(1, :*)
end
puts total
' "$CI_WORKFLOW") || fail "could not count ci.yml jobs"
  [ "$total" -le 18 ] || fail "ci.yml expands to $total jobs, over its 18-job runner budget"
  pass "ci.yml expands to $total jobs, within its 18-job runner budget"
}

test_coverage_guard_and_proven_set_have_owner_jobs() {
  local tmp job args expected
  tmp=$(fm_test_tmproot fm-ci-test-owner-jobs)
  mkdir -p "$tmp/bin"
  cat >"$tmp/bin/fm-test-run.sh" <<'SH'
#!/usr/bin/env bash
printf 'CALL\n' >>"$RUNNER_TEMP/invocation"
printf '%s\n' "$@" >>"$RUNNER_TEMP/invocation"
SH
  chmod +x "$tmp/bin/fm-test-run.sh"
  ruby -ryaml -e '
jobs = YAML.load_file(ARGV[0]).fetch("jobs")
{
  "invariants" => "Prove complete regression partition",
  "tests-portable-parallel" => "Run the proven-isolated set",
}.each do |job, name|
  step = jobs.fetch(job).fetch("steps").find { |s| s["name"] == name }
  abort "missing #{job} owner step" unless step
  abort "#{job} owner step must be unconditional" if step.key?("if")
  File.write(File.join(ARGV[1], "#{job}.sh"), step.fetch("run"))
end
' "$CI_WORKFLOW" "$tmp" || fail "could not extract coverage and proven-isolated owner steps"
  for job in invariants tests-portable-parallel; do
    rm -f "$tmp/invocation"
    (cd "$tmp" && RUNNER_TEMP="$tmp" bash -e "$job.sh") \
      || fail "$job workflow owner step failed"
    args=$(cat "$tmp/invocation")
    if [ "$job" = invariants ]; then
      expected="CALL"$'\n'"--check-coverage"
    else
      expected="CALL"$'\n'"--proven-isolated"$'\n'"--jobs"$'\n'"4"$'\n'"--json"$'\n'"$tmp/fm-test/fm-test-timing-portable-parallel.json"
    fi
    [ "$args" = "$expected" ] || fail "$job did not execute its required runner invocation: $args"
  done
  pass "the coverage guard and the proven-isolated set each have an owner job"
}

test_lint_event_modes_execute_the_owner() {
  local tmp event args base shard expected_shard
  tmp=$(fm_test_tmproot fm-ci-lint-events)
  mkdir -p "$tmp/bin"
  cat > "$tmp/bin/fm-lint.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$RUNNER_TEMP/invocation"
SH
  chmod +x "$tmp/bin/fm-lint.sh"
  # shellcheck disable=SC2016 # Resolve GitHub expressions in Ruby, not Bash.
  ruby -ryaml -e '
jobs = YAML.load_file(ARGV[0]).fetch("jobs")
job = jobs.fetch("lint")
strategy = job.fetch("strategy")
shards = strategy.fetch("matrix").fetch("shard")
abort "lint needs three shards" unless shards == (1..3).to_a
abort "lint must report every shard" unless strategy.fetch("fail-fast") == false
serial = jobs.fetch("tests-portable-serial").fetch("strategy")
abort "serial needs nine shards" unless serial.fetch("matrix").fetch("shard") == (1..9).to_a
abort "serial must report every shard" unless serial.fetch("fail-fast") == false
steps = job.fetch("steps")
checkout = steps.find { |s| s.fetch("uses", "").start_with?("actions/checkout@") }
abort "affected lint needs history" unless checkout.fetch("with").fetch("fetch-depth") == 0
lint = steps.last
File.write(ARGV[1], lint.fetch("run"))
shards.each do |shard|
  context = {
    "github.event.pull_request.base.sha" => "abc123",
    "matrix.shard" => shard.to_s,
    "strategy.job-total" => shards.length.to_s,
  }
  env = lint.fetch("env").transform_values do |raw|
    raw.gsub(/\$\{\{(.+?)\}\}/) { context.fetch(Regexp.last_match(1).strip) }
  end
  puts [env.fetch("LINT_BASE"), env.fetch("LINT_SHARD"), "#{shard}/#{shards.length}"].join("\t")
end
' "$CI_WORKFLOW" "$tmp/step.sh" > "$tmp/env" || fail "could not resolve lint matrix step"
  while IFS=$'\t' read -r base shard expected_shard; do
    [ "$shard" = "$expected_shard" ] || fail "lint shard must resolve to $expected_shard, got $shard"
    for event in pull_request push; do
      (cd "$tmp" && GITHUB_EVENT_NAME="$event" LINT_BASE="$base" LINT_SHARD="$shard" RUNNER_TEMP="$tmp" bash -e step.sh) \
        || fail "lint workflow failed for $event shard $shard"
      args=$(cat "$tmp/invocation")
      if [ "$event" = pull_request ]; then
        [ "$args" = "--changed"$'\n'"abc123"$'\n'"--shard"$'\n'"$shard"$'\n'"--telemetry"$'\n'"$tmp/lint.tsv" ] \
          || fail "PR did not select the owner's affected-root shard: $args"
      else
        [ "$args" = "--full"$'\n'"--shard"$'\n'"$shard"$'\n'"--telemetry"$'\n'"$tmp/lint.tsv" ] \
          || fail "main push did not select the full canonical lint shard: $args"
      fi
    done
  done < "$tmp/env"
  pass "PR and main push steps execute all affected and full owner shards with history"
}

test_lint_event_modes_execute_the_owner
test_ci_stays_within_its_runner_budget
test_coverage_guard_and_proven_set_have_owner_jobs
test_pr_pushes_supersede_within_one_pr
test_separate_prs_do_not_cancel_each_other
test_main_pushes_are_never_cancelled
test_every_job_has_a_finite_timeout
test_previously_unbounded_jobs_keep_their_caps
test_measured_lanes_keep_their_authorized_bounds
