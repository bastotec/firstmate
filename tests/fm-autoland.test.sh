#!/usr/bin/env bash
# Behavior tests for bin/fm-autoland.sh, the auto-land watcher check, and for
# the watcher's short auto-land cadence between full check sweeps.
#
# Every case runs the real script against a scratch home with a fake `gh` on
# PATH. The fake answers the tick's one GraphQL call from a fixture file, the
# live `gh pr view` re-read, and `gh pr merge`, and logs every call, so a case
# can assert both what was printed and what was (not) merged. A copied bin with
# a stub fm-pr-merge.sh proves task-owned PRs go through that entrypoint.
# Post-merge hooks are tiny scripts under the scratch home's config/post-merge.
#
# No case contacts GitHub.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUTOLAND="$ROOT/bin/fm-autoland.sh"
TMP_ROOT=$(fm_test_tmproot fm-autoland)
FAKEBIN="$TMP_ROOT/fakebin"
HEAD_A=1111111111111111111111111111111111111111
HEAD_B=2222222222222222222222222222222222222222
MAIN_1=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
MAIN_2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "$1 $2" in
  "api graphql") cat "$FM_TEST_GQL"; exit 0 ;;
  "pr merge") sleep "${FM_TEST_MERGE_DELAY:-0}"; exit "${FM_TEST_MERGE_RC:-0}" ;;
  "pr view")
    case "$*" in
      *"--json state -q .state"*) printf '%s\n' "${FM_TEST_AFTER_STATE:-MERGED}" ;;
      *) sleep "${FM_TEST_VIEW_DELAY:-0}"; cat "$FM_TEST_LIVE" ;;
    esac
    exit 0
    ;;
  "api repos/"*) printf '%s\n' "${FM_TEST_HEAD_OID:-}"; exit 0 ;;
esac
exit 1
SH
chmod +x "$FAKEBIN/gh"

# make_home <name> [<projects.md line>...]: a scratch home with state and data.
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  shift
  mkdir -p "$home/state" "$home/data" "$home/config/post-merge"
  : > "$home/data/projects.md"
  for line in "$@"; do printf '%s\n' "$line" >> "$home/data/projects.md"; done
  : > "$home/gh.log"
  printf '%s\n' "$home"
}

write_config() {  # <home> <json>
  printf '%s\n' "$2" > "$1/config/autoland.json"
}

# pr_node <head> [key=value...]: one search node; defaults describe a PR that
# should land (non-draft, clean, one green check, current attestation, low risk).
pr_node() {
  local head=$1 url=https://github.com/o/r/pull/7 repo=o/r draft=false mergeable=MERGEABLE
  local mstate=CLEAN base=main check=SUCCESS status=COMPLETED attest_head=$1 risk='✅ Low: small change' label=''
  local review=completed test=completed document=completed kv
  shift
  for kv in "$@"; do
    case "$kv" in
      url=*) url=${kv#url=} ;;
      repo=*) repo=${kv#repo=} ;;
      draft=*) draft=${kv#draft=} ;;
      mergeable=*) mergeable=${kv#mergeable=} ;;
      mstate=*) mstate=${kv#mstate=} ;;
      base=*) base=${kv#base=} ;;
      check=*) check=${kv#check=} ;;
      status=*) status=${kv#status=} ;;
      attest_head=*) attest_head=${kv#attest_head=} ;;
      risk=*) risk=${kv#risk=} ;;
      label=*) label=${kv#label=} ;;
      review=*) review=${kv#review=} ;;
      test=*) test=${kv#test=} ;;
      document=*) document=${kv#document=} ;;
    esac
  done
  jq -cn --arg url "$url" --arg repo "$repo" --argjson draft "$draft" --arg m "$mergeable" \
    --arg ms "$mstate" --arg head "$head" --arg base "$base" --arg check "$check" --arg status "$status" \
    --arg ah "$attest_head" --arg risk "$risk" --arg label "$label" --arg review "$review" \
    --arg test "$test" --arg document "$document" '
    {url: $url, isDraft: $draft, mergeable: $m, mergeStateStatus: $ms, headRefOid: $head, baseRefName: $base,
     body: ("## What Changed\n\n- x\n\n## Risk Assessment\n\n" + $risk + "\n\n<!-- no-mistakes-pipeline-attestation:v1 "
       + ({head_sha: $ah, steps: [{step: "review", status: $review}, {step: "test", status: $test},
           {step: "document", status: $document}, {step: "pr", status: "running"}]} | tojson) + " -->"),
     repository: {nameWithOwner: $repo, defaultBranchRef: {name: "main"}},
     labels: {nodes: (if $label == "" then [] else [{name: $label}] end)},
     commits: {nodes: [{commit: {statusCheckRollup: {contexts: {nodes: [
       {__typename: "CheckRun", name: "ci", status: $status, conclusion: (if $status == "COMPLETED" then $check else null end),
        startedAt: "2026-10-05T10:00:00Z"}]}}}}]}}'
}

# write_gql <home> <main-oid> [<node-json>...]: the tick's GraphQL answer.
write_gql() {
  local home=$1 oid=$2 nodes
  shift 2
  nodes=$(printf '%s\n' "$@" | jq -cs '.')
  [ "$#" -gt 0 ] || nodes='[]'
  jq -n --argjson nodes "$nodes" --arg oid "$oid" \
    '{data: {search: {nodes: $nodes}, r0: {nameWithOwner: "o/r", defaultBranchRef: {target: {oid: $oid}}}}}' \
    > "$home/gql.json"
}

# write_live <home> <node-json>: what the pre-merge `gh pr view` re-read returns.
write_live() {
  printf '%s' "$2" | jq -c '{url, state: "OPEN", isDraft, mergeable, mergeStateStatus, headRefOid, baseRefName, body,
    labels: .labels.nodes, statusCheckRollup: .commits.nodes[0].commit.statusCheckRollup.contexts.nodes}' > "$1/live.json"
}

tick() {  # <home> [<script>] [env...] -> stdout of one tick
  local home=$1 script=${2:-$AUTOLAND}
  shift 2 2>/dev/null || shift $#
  env FM_HOME="$home" FM_TEST_GH_LOG="$home/gh.log" FM_TEST_GQL="$home/gql.json" FM_TEST_LIVE="$home/live.json" \
    PATH="$FAKEBIN:$PATH" "$@" "$script" check
}

merges() { grep -c '^pr merge' "$1/gh.log" || true; }

wait_result() {  # <home> <hook> <status>
  local i=0
  while [ "$i" -lt 300 ]; do
    if [ -f "$1/state/autoland/$2.result" ] && [ "$(cut -f1 "$1/state/autoland/$2.result")" = "$3" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_deployed() {  # <home> <hook> <oid>
  local i=0
  while [ "$i" -lt 300 ]; do
    [ "$(cat "$1/state/autoland/$2.deployed" 2>/dev/null)" = "$3" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

CONFIG_AUTH='{"repos":[{"repo":"o/r","authority":"standing ruling","attestation":true}]}'

test_help_and_unknown_action() {
  local out rc=0
  out=$("$AUTOLAND" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "--help exit"
  assert_contains "$out" "arm" "--help lists arm"
  assert_contains "$out" "deploy <hook>" "--help lists deploy"
  rc=0
  "$AUTOLAND" bogus >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "unknown action exit"
  pass "fm-autoland: help and unknown action"
}

test_arm_and_disarm() {
  local home out
  home=$(make_home arm)
  out=$(FM_HOME="$home" "$AUTOLAND" arm 2>/dev/null) || fail "arm failed"
  assert_contains "$out" "armed: state/autoland.check.sh" "arm reports the shim"
  [ -f "$home/state/autoland.check.sh" ] && [ -f "$home/state/autoland.check-trust" ] || fail "arm left no bound shim"
  FM_HOME="$home" "$AUTOLAND" disarm >/dev/null || fail "disarm failed"
  [ ! -e "$home/state/autoland.check.sh" ] && [ ! -e "$home/state/autoland.check-trust" ] || fail "disarm left the shim"
  pass "fm-autoland: arm binds the shim and disarm removes it"
}

test_missing_config_reported_once() {
  local home out
  home=$(make_home noconfig)
  out=$(tick "$home")
  assert_contains "$out" "autoland is armed but config/autoland.json is missing" "missing config is reported"
  out=$(tick "$home")
  [ -z "$out" ] || fail "missing config repeated: $out"
  pass "fm-autoland: a missing config is reported once"
}

test_green_pr_merges_once() {
  local home node out
  home=$(make_home green)
  write_config "$home" "$CONFIG_AUTH"
  node=$(pr_node "$HEAD_A")
  write_gql "$home" "$MAIN_1" "$node"
  write_live "$home" "$node"
  out=$(tick "$home")
  assert_contains "$out" "merged https://github.com/o/r/pull/7" "green PR merge is reported"
  grep -qxF "pr merge https://github.com/o/r/pull/7 --squash --match-head-commit $HEAD_A" "$home/gh.log" \
    || fail "merge was not pinned to the verified head: $(cat "$home/gh.log")"
  write_gql "$home" "$MAIN_1"
  out=$(tick "$home")
  [ -z "$out" ] || fail "a quiet tick printed: $out"
  pass "fm-autoland: a green, attested, low-risk PR merges pinned to its head and is reported once"
}

test_pending_and_red_checks_stay_silent() {
  local home out
  home=$(make_home pending)
  write_config "$home" "$CONFIG_AUTH"
  write_gql "$home" "$MAIN_1" "$(pr_node "$HEAD_A" status=IN_PROGRESS)"
  out=$(tick "$home")
  [ -z "$out" ] || fail "pending checks printed: $out"
  write_gql "$home" "$MAIN_1" "$(pr_node "$HEAD_A" check=FAILURE)"
  out=$(tick "$home")
  [ -z "$out" ] || fail "red checks printed: $out"
  [ "$(merges "$home")" = 0 ] || fail "a non-green PR was merged"
  pass "fm-autoland: pending and red checks are left to the owner, silently"
}

test_green_draft_wakes_once_per_head() {
  local home out
  home=$(make_home draft)
  write_config "$home" "$CONFIG_AUTH"
  write_gql "$home" "$MAIN_1" "$(pr_node "$HEAD_A" draft=true)"
  out=$(tick "$home")
  assert_contains "$out" "green PR not landing: https://github.com/o/r/pull/7 because it is still a draft" "green draft wakes"
  out=$(tick "$home")
  [ -z "$out" ] || fail "the same draft repeated: $out"
  write_gql "$home" "$MAIN_1" "$(pr_node "$HEAD_B" draft=true)"
  out=$(tick "$home")
  assert_contains "$out" "because it is still a draft" "a new head re-reports"
  [ "$(merges "$home")" = 0 ] || fail "a draft was merged"
  pass "fm-autoland: a green draft wakes once per head and never merges"
}

test_blocking_reasons_are_named() {
  local home out
  home=$(make_home reasons)
  write_config "$home" "$CONFIG_AUTH"
  write_gql "$home" "$MAIN_1" "$(pr_node "$HEAD_A" attest_head="$HEAD_B")"
  out=$(tick "$home")
  assert_contains "$out" "its no-mistakes attestation is for 2222222, not the current head 1111111" "stale attestation"
  write_gql "$home" "$MAIN_1" "$(pr_node "$HEAD_A" review=skipped)"
  out=$(tick "$home")
  assert_contains "$out" "attestation shows review skipped" "skipped review"
  write_gql "$home" "$MAIN_1" "$(pr_node "$HEAD_A" risk='⚠️ Medium: touches merges')"
  out=$(tick "$home")
  assert_contains "$out" "no-mistakes rated it medium risk (auto-merge cap: low)" "medium risk"
  write_gql "$home" "$MAIN_1" "$(pr_node "$HEAD_A" label=do-not-merge)"
  out=$(tick "$home")
  assert_contains "$out" "it is labelled do-not-merge" "hold label"
  write_gql "$home" "$MAIN_1" "$(pr_node "$HEAD_A" mergeable=CONFLICTING mstate=DIRTY)"
  out=$(tick "$home")
  assert_contains "$out" "it has merge conflicts" "conflicts"
  write_gql "$home" "$MAIN_1" "$(pr_node "$HEAD_A" mstate=BLOCKED)"
  out=$(tick "$home")
  assert_contains "$out" "blocked by a branch rule" "blocked"
  [ "$(merges "$home")" = 0 ] || fail "a held PR was merged"
  write_gql "$home" "$MAIN_1" "$(pr_node "$HEAD_A" mstate=BEHIND)"
  out=$(tick "$home")
  assert_contains "$out" "its branch is behind the base" "behind"
  write_gql "$home" "$MAIN_1" "$(pr_node "$HEAD_A" test=pending)"
  out=$(tick "$home")
  assert_contains "$out" "attestation shows test pending" "incomplete test"
  write_gql "$home" "$MAIN_1" "$(pr_node "$HEAD_A" document=skipped)"
  out=$(tick "$home")
  assert_contains "$out" "attestation shows document skipped" "incomplete document"
  write_gql "$home" "$MAIN_1" "$(pr_node "$HEAD_A" | jq '.body = "ordinary PR body"')"
  out=$(tick "$home")
  assert_contains "$out" "it carries no no-mistakes attestation" "missing attestation without risk section"
  write_gql "$home" "$MAIN_1" "$(pr_node "$HEAD_A" | jq '.body = "<!-- no-mistakes-pipeline-attestation:v1 {broken} -->"')"
  out=$(tick "$home")
  assert_contains "$out" "its no-mistakes attestation cannot be read" "unreadable attestation"
  write_gql "$home" "$MAIN_1" "$(pr_node "$HEAD_A" | jq '.commits.nodes[0].commit.statusCheckRollup.contexts.nodes = []')"
  out=$(tick "$home")
  assert_contains "$out" "no CI checks are reported on its head" "no CI"
  [ "$(merges "$home")" = 0 ] || fail "a held PR was merged"
  pass "fm-autoland: every green-but-held PR names its reason and does not merge"
}

test_refused_merge_is_reported() {
  local home node out
  home=$(make_home refused)
  write_config "$home" "$CONFIG_AUTH"
  node=$(pr_node "$HEAD_A")
  write_gql "$home" "$MAIN_1" "$node"
  write_live "$home" "$node"
  out=$(tick "$home" "$AUTOLAND" FM_TEST_MERGE_RC=1)
  assert_contains "$out" "green PR not landing: https://github.com/o/r/pull/7 because gh refused the merge" "refused merge"
  write_live "$home" "$(pr_node "$HEAD_B")"
  out=$(tick "$home" "$AUTOLAND" FM_TEST_MERGE_RC=0)
  assert_contains "$out" "its head moved while it was being checked" "moved head refuses"
  pass "fm-autoland: a refused merge or a moved head is reported, not claimed"
}

test_authority_follows_the_registry() {
  local home node out
  home=$(make_home registry '- proj [no-mistakes] - a project (added 2026-01-01)')
  write_config "$home" '{"repos":[{"repo":"o/r","project":"proj","attestation":true}]}'
  node=$(pr_node "$HEAD_A")
  write_gql "$home" "$MAIN_1" "$node"
  write_live "$home" "$node"
  out=$(tick "$home")
  [ -z "$out" ] && [ "$(merges "$home")" = 0 ] || fail "a project without +yolo was merged or reported: $out"
  printf '%s\n' '- proj [no-mistakes +yolo] - a project (added 2026-01-01)' > "$home/data/projects.md"
  out=$(tick "$home")
  assert_contains "$out" "merged https://github.com/o/r/pull/7" "+yolo project merges"
  pass "fm-autoland: registry-backed authority needs +yolo at tick time"
}

test_other_base_and_other_repo_are_ignored() {
  local home out
  home=$(make_home ignored)
  write_config "$home" "$CONFIG_AUTH"
  write_gql "$home" "$MAIN_1" "$(pr_node "$HEAD_A" base=feature)" "$(pr_node "$HEAD_B" repo=o/other url=https://github.com/o/other/pull/1)"
  out=$(tick "$home")
  [ -z "$out" ] && [ "$(merges "$home")" = 0 ] || fail "a stacked or unconfigured PR was touched: $out"
  pass "fm-autoland: stacked PRs and unconfigured repositories are left alone"
}

owned_bin() {
  local tmpbin="$1/bin" lib
  mkdir -p "$tmpbin"
  cp "$AUTOLAND" "$tmpbin/"
  for lib in fm-timeout-lib.sh fm-pr-lib.sh fm-line-cap-lib.sh fm-check-lib.sh fm-project-mode.sh fm-fleet-sync.sh fm-wake-lib.sh; do
    ln -s "$ROOT/bin/$lib" "$tmpbin/$lib"
  done
  cat > "$tmpbin/fm-pr-merge.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/pr-merge.log"
printf '%s\n' "${FM_PR_MERGE_EXPECT_HEAD:-unset}" >> "$FM_HOME/expected-head.log"
if [ -n "${FM_TEST_OWNED_DELAY:-}" ]; then
  if [ -f "$FM_HOME/state/autoland/notified" ]; then
    cp "$FM_HOME/state/autoland/notified" "$FM_HOME/notified-at-merge"
  else
    printf 'absent\n' > "$FM_HOME/notified-at-merge"
  fi
  sleep "$FM_TEST_OWNED_DELAY"
fi
if [ "${FM_TEST_OWNED_RC:-0}" != 0 ]; then
  echo 'error: task task-x is still held for the captain; release it before merging' >&2
  exit "$FM_TEST_OWNED_RC"
fi
SH
  chmod +x "$tmpbin/fm-pr-merge.sh"
  printf 'pr=https://github.com/o/r/pull/7\n' > "$1/state/task-x.meta"
  printf '%s\n' "$tmpbin"
}

test_task_owned_pr_uses_fm_pr_merge() {
  local home tmpbin node out
  home=$(make_home owned)
  tmpbin=$(owned_bin "$home")
  write_config "$home" "$CONFIG_AUTH"
  node=$(pr_node "$HEAD_A")
  write_gql "$home" "$MAIN_1" "$node"
  write_live "$home" "$node"
  out=$(tick "$home" "$tmpbin/fm-autoland.sh")
  assert_contains "$out" "merged https://github.com/o/r/pull/7" "task-owned merge reported"
  grep -qxF "task-x https://github.com/o/r/pull/7 -- --squash" "$home/pr-merge.log" \
    || fail "fm-pr-merge.sh was not used: $(cat "$home/pr-merge.log" 2>/dev/null)"
  grep -qxF "$HEAD_A" "$home/expected-head.log" || fail "task merge was not pinned to the tick head"
  out=$(tick "$home" "$tmpbin/fm-autoland.sh" FM_TEST_OWNED_RC=1)
  assert_contains "$out" "because task task-x is still held for the captain" "task helper refusal reported"
  [ "$(merges "$home")" = 0 ] || fail "gh merged around fm-pr-merge.sh"
  pass "fm-autoland: task-owned PRs use the head-pinned helper and report its refusals"
}

test_risk_section_is_required_for_attestation() {
  local home node out
  home=$(make_home norisk)
  write_config "$home" "$CONFIG_AUTH"
  node=$(pr_node "$HEAD_A" | jq '.body |= sub("## Risk Assessment[^<]*"; "")')
  write_gql "$home" "$MAIN_1" "$node"
  write_live "$home" "$node"
  out=$(tick "$home")
  assert_contains "$out" "because its no-mistakes risk assessment is missing" "attested PR without risk section is held and reported"
  [ "$(merges "$home")" = 0 ] || fail "an attestation-required PR merged without a risk rating"
  write_config "$home" '{"repos":[{"repo":"o/r","authority":"r"}]}'
  node=$(pr_node "$HEAD_B" | jq '.body = "ordinary direct-PR body"')
  write_gql "$home" "$MAIN_1" "$node"
  write_live "$home" "$node"
  tick "$home" >/dev/null
  [ "$(merges "$home")" = 1 ] || fail "a direct PR with no risk section disappeared"
  pass "fm-autoland: unrated PRs are retained but held when attestation is required"
}

test_attestation_follows_registered_mode() {
  local home mode setting out node
  node=$(pr_node "$HEAD_A" | jq '.body = "ordinary PR body"')
  for mode in no-mistakes no-mistakes-prod-only direct-PR local-only; do
    for setting in omitted false true; do
      home=$(make_home "mode-$mode-$setting" "- proj [$mode +yolo] - project")
      write_config "$home" "$(jq -cn --arg setting "$setting" '
        {repos:[{repo:"o/r", project:"proj", authority:"standing ruling"}
          + (if $setting == "omitted" then {} else {attestation:($setting == "true")} end)]}')"
      write_gql "$home" "$MAIN_1" "$node"
      write_live "$home" "$node"
      out=$(tick "$home")
      if [ "$setting" = true ] || [ "$mode" = no-mistakes ] || [ "$mode" = no-mistakes-prod-only ]; then
        assert_contains "$out" "it carries no no-mistakes attestation" "registered $mode with $setting"
        [ "$(merges "$home")" = 0 ] || fail "registered attestation requirement was bypassed"
      else
        [ "$(merges "$home")" = 1 ] || fail "$mode with $setting did not merge: $out"
      fi
    done
  done
  pass "fm-autoland: configuration cannot disable registered no-mistakes attestation"
}

test_live_policy_applies_to_both_merge_paths() {
  local home script path variant node live out
  for path in unowned owned; do
    home=$(make_home "live-$path")
    script=$AUTOLAND
    [ "$path" != owned ] || script="$(owned_bin "$home")/fm-autoland.sh"
    write_config "$home" "$CONFIG_AUTH"
    node=$(pr_node "$HEAD_A")
    write_gql "$home" "$MAIN_1" "$node"
    for variant in label risk missing-risk attestation head; do
      case "$variant" in
        label) live=$(pr_node "$HEAD_A" label=security) ;;
        risk) live=$(pr_node "$HEAD_A" risk='High: dangerous') ;;
        missing-risk) live=$(pr_node "$HEAD_A" | jq '.body |= sub("## Risk Assessment[^<]*"; "")') ;;
        attestation) live=$(pr_node "$HEAD_A" attest_head="$HEAD_B") ;;
        head) live=$(pr_node "$HEAD_B") ;;
      esac
      write_live "$home" "$live"
      out=$(tick "$home" "$script")
      assert_contains "$out" "green PR not landing:" "$path live $variant is reported"
      if [ "$variant" = missing-risk ]; then
        assert_contains "$out" "its no-mistakes risk assessment is missing" "$path missing live risk is held"
      fi
      [ "$(merges "$home")" = 0 ] || fail "$path live $variant merged"
      [ ! -e "$home/pr-merge.log" ] || fail "task helper ran despite live $variant"
    done
  done
  pass "fm-autoland: both merge paths re-read live head, labels, risk, and attestation"
}

test_duplicate_hooks_are_rejected() {
  local home out
  home=$(make_home duplicate-hooks)
  write_config "$home" '{"repos":[{"repo":"o/r","authority":"r","hook":"svc"},{"repo":"o/other","authority":"r","hook":"svc"}]}'
  out=$(tick "$home")
  assert_contains "$out" "config/autoland.json is not valid" "duplicate hook rejected"
  [ ! -s "$home/gh.log" ] || fail "invalid config contacted GitHub"
  pass "fm-autoland: each hook has one repository owner"
}

test_merges_are_bounded_and_notifications_follow_output() {
  local home script node out started elapsed path
  for path in owned unowned; do
    home=$(make_home "deadline-$path")
    script=$AUTOLAND
    [ "$path" != owned ] || script="$(owned_bin "$home")/fm-autoland.sh"
    write_config "$home" "$CONFIG_AUTH"
    node=$(pr_node "$HEAD_A")
    write_gql "$home" "$MAIN_1" "$(pr_node "$HEAD_B" draft=true url=https://github.com/o/r/pull/8)" "$node"
    write_live "$home" "$node"
    started=$SECONDS
    out=$(tick "$home" "$script" FM_CHECK_TIMEOUT=8 FM_AUTOLAND_MERGE_BUDGET=100 \
      FM_TEST_OWNED_DELAY=30 FM_TEST_VIEW_DELAY=1 FM_TEST_MERGE_DELAY=30)
    elapsed=$((SECONDS - started))
    [ "$elapsed" -lt 8 ] || fail "$path merge exceeded the check deadline ($elapsed seconds)"
    assert_contains "$out" "it is still a draft" "draft survives slow merge"
    assert_contains "$out" "merge operation timed out" "complete $path operation is bounded"
    grep -q 'hold|https://github.com/o/r/pull/8|' "$home/state/autoland/notified" || fail "emitted hold was not recorded"
    if [ "$path" = owned ]; then
      [ "$(cat "$home/notified-at-merge")" = absent ] || fail "hold marked delivered before output"
    fi
    out=$(tick "$home" "$script" FM_CHECK_TIMEOUT=3 FM_AUTOLAND_MERGE_BUDGET=100)
    [ -z "$out" ] || fail "already delivered draft repeated: $out"
  done
  pass "fm-autoland: complete merges respect the deadline and queued notifications are not pre-marked"
}

write_hook() {  # <home> <name> <exit> [<mode>]
  # shellcheck disable=SC2016  # the hook's own expansions
  printf '#!/usr/bin/env bash\nprintf "run %%s\\n" "$1" >> "$FM_HOME/hook-%s.runs"\necho "summary for $FM_AUTOLAND_REPO prev=${FM_AUTOLAND_DEPLOYED:-none}"\nexit %s\n' "$2" "$3" \
    > "$1/config/post-merge/$2.sh"
  chmod "${4:-0755}" "$1/config/post-merge/$2.sh"
}

test_deploy_runs_after_merge_and_reports() {
  local home out
  home=$(make_home deploy)
  write_config "$home" '{"repos":[{"repo":"o/r","authority":"r","hook":"svc"}]}'
  write_hook "$home" svc 0
  write_gql "$home" "$MAIN_1"
  out=$(tick "$home")
  wait_result "$home" svc deployed || fail "the deploy runner did not finish"
  [ "$(cat "$home/state/autoland/svc.deployed")" = "$MAIN_1" ] || fail "deployed commit not recorded"
  out=$(tick "$home")
  assert_contains "$out" "deployed svc aaaaaaa: summary for o/r prev=none" "deploy result reported"
  out=$(tick "$home")
  [ -z "$out" ] || fail "deploy result repeated: $out"
  [ "$(wc -l < "$home/hook-svc.runs" | tr -d ' ')" = 1 ] || fail "an up-to-date deploy re-ran"
  write_gql "$home" "$MAIN_2"
  tick "$home" >/dev/null
  wait_deployed "$home" svc "$MAIN_2" || fail "a new default-branch head was not deployed"
  grep -q "prev=$MAIN_1" "$home/state/autoland/svc.log" || fail "hook did not see the previous deploy"
  pass "fm-autoland: a new default-branch head deploys once, records the commit, and reports"
}

test_fleet_sync_timeout_is_a_continuing_warning() {
  local home tmpbin out
  home=$(make_home sync-timeout '- proj [direct-PR +yolo] - project')
  tmpbin=$(owned_bin "$home")
  mkdir -p "$home/projects/proj" "$home/fakebin"
  rm "$tmpbin/fm-fleet-sync.sh"
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$tmpbin/fm-fleet-sync.sh"
  chmod +x "$tmpbin/fm-fleet-sync.sh"
  cat > "$home/fakebin/timeout" <<'SH'
#!/usr/bin/env bash
seconds=$3
shift 3
if [ "$seconds" = 300 ]; then
  printf '%s\n' "$seconds" > "$FM_HOME/sync-bound"
  seconds=1
fi
. "$FM_TEST_ROOT/bin/fm-timeout-lib.sh"
FM_TIMEOUT_MECHANISM_OVERRIDE=bash
fm_run_timed "$seconds" "$@"
SH
  chmod +x "$home/fakebin/timeout"
  write_config "$home" '{"repos":[{"repo":"o/r","project":"proj","hook":"svc"}]}'
  write_hook "$home" svc 0
  out=$(FM_HOME="$home" FM_TEST_ROOT="$ROOT" PATH="$home/fakebin:$PATH" \
    "$tmpbin/fm-autoland.sh" deploy-run svc "$MAIN_1" 2>&1) || fail "sync timeout blocked deployment: $out"
  [ "$(cat "$home/sync-bound")" = 300 ] || fail "fleet sync was not bounded to 300 seconds"
  grep -q 'fleet sync of projects/proj timed out after 300s (continuing)' "$home/state/autoland/svc.log" || fail "sync timeout warning missing"
  [ "$(cat "$home/state/autoland/svc.deployed")" = "$MAIN_1" ] || fail "hook did not deploy after sync timeout"
  [ ! -e "$home/state/autoland/svc.lock" ] || fail "runner retained its hook lock"
  pass "fm-autoland: a bounded fleet sync timeout warns and continues to the hook"
}

wait_file() {
  local i=0
  while [ "$i" -lt 200 ]; do
    [ -e "$1" ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

write_waiting_hook() {
  cat > "$1/config/post-merge/svc.sh" <<'SH'
#!/usr/bin/env bash
if ! mkdir "$FM_HOME/hook-active"; then
  touch "$FM_HOME/overlapping-hooks"
fi
touch "$FM_HOME/hook-entered"
while [ ! -e "$FM_HOME/release-hook" ]; do sleep 0.05; done
rmdir "$FM_HOME/hook-active" 2>/dev/null || true
SH
  chmod 0755 "$1/config/post-merge/svc.sh"
}

test_hook_lock_publication_and_stale_reclaim_are_serialized() {
  local stage home first second owner first_rc second_rc tool
  for stage in fresh stale; do
    home=$(make_home "lock-$stage")
    write_config "$home" '{"repos":[{"repo":"o/r","authority":"r","hook":"svc"}]}'
    write_waiting_hook "$home"
    mkdir -p "$home/fakebin" "$home/state/autoland"
    if [ "$stage" = stale ]; then
      mkdir "$home/state/autoland/svc.lock"
      printf '99999999\n' > "$home/state/autoland/svc.lock/pid"
    fi
    cat > "$home/fakebin/lock-barrier" <<'SH'
#!/usr/bin/env bash
touch "$FM_HOME/lock-operation-paused"
while [ ! -e "$FM_HOME/release-lock-operation" ]; do sleep 0.05; done
SH
    cat > "$home/fakebin/mkdir" <<'SH'
#!/usr/bin/env bash
"$FM_TEST_REAL_MKDIR" "$@" || exit $?
if [ "${FM_TEST_LOCK_PAUSE:-0}" = 1 ] && [ "${!#}" = "$FM_HOME/state/autoland/svc.lock" ]; then
  lock-barrier
fi
SH
    cat > "$home/fakebin/mv" <<'SH'
#!/usr/bin/env bash
"$FM_TEST_REAL_MV" "$@" || exit $?
if [ "${FM_TEST_LOCK_PAUSE:-0}" = 1 ]; then
  case "${!#}" in
    "$FM_HOME/state/autoland/svc.lock"|"$FM_HOME/state/autoland/".svc.stale.*/lock) lock-barrier ;;
  esac
fi
SH
    cat > "$home/fakebin/rm" <<'SH'
#!/usr/bin/env bash
if [ "${FM_TEST_LOCK_PAUSE:-0}" = 1 ] && [ "${!#}" = "$FM_HOME/state/autoland/svc.lock" ]; then
  lock-barrier
fi
exec "$FM_TEST_REAL_RM" "$@"
SH
    for tool in mkdir mv rm lock-barrier; do chmod +x "$home/fakebin/$tool"; done
    FM_HOME="$home" FM_TEST_LOCK_PAUSE=1 FM_TEST_REAL_MKDIR="$(command -v mkdir)" \
      FM_TEST_REAL_MV="$(command -v mv)" FM_TEST_REAL_RM="$(command -v rm)" \
      PATH="$home/fakebin:$PATH" "$AUTOLAND" deploy-run svc "$MAIN_1" > "$home/first.out" 2>&1 &
    first=$!
    fm_test_track_helper_pid "$first"
    wait_file "$home/lock-operation-paused" || fail "$stage lock operation never reached its barrier"
    owner=$(cat "$home/state/autoland/svc.lock/pid" 2>/dev/null || true)
    (
      second_rc=0
      FM_HOME="$home" "$AUTOLAND" deploy-run svc "$MAIN_1" > "$home/second.out" 2>&1 || second_rc=$?
      printf '%s\n' "$second_rc" > "$home/second.rc"
    ) &
    second=$!
    fm_test_track_helper_pid "$second"
    for ((tool=0; tool<200; tool++)); do
      [ -e "$home/second.rc" ] || [ -e "$home/hook-entered" ] || { sleep 0.05; continue; }
      break
    done
    touch "$home/release-lock-operation"
    wait_file "$home/hook-entered" || fail "$stage lock winner never started the hook"
    touch "$home/release-hook"
    first_rc=0
    wait "$first" || first_rc=$?
    wait "$second" || fail "$stage competing runner fixture failed"
    expect_code 0 "$first_rc" "$stage first runner"
    expect_code 3 "$(cat "$home/second.rc")" "$stage competing runner must be busy"
    [ ! -e "$home/overlapping-hooks" ] || fail "$stage hook ran concurrently"
    [ ! -e "$home/state/autoland/svc.lock" ] || fail "$stage winner did not release its lock"
    if [ "$stage" = fresh ]; then
      [ "$owner" = "$first" ] || fail "a fresh lock became visible without its owner pid"
    fi
  done
  pass "fm-autoland: owner publication and stale reclaim exclude concurrent hook runners"
}

test_hook_lock_release_preserves_another_owner() {
  local home runner rc=0
  home=$(make_home lock-release)
  write_config "$home" '{"repos":[{"repo":"o/r","authority":"r","hook":"svc"}]}'
  write_waiting_hook "$home"
  FM_HOME="$home" "$AUTOLAND" deploy-run svc "$MAIN_1" > "$home/runner.out" 2>&1 &
  runner=$!
  fm_test_track_helper_pid "$runner"
  wait_file "$home/hook-entered" || fail "lock-release hook did not start"
  printf '%s\n' "$$" > "$home/state/autoland/svc.lock/pid"
  touch "$home/release-hook"
  wait "$runner" || rc=$?
  expect_code 0 "$rc" "lock-release runner"
  [ "$(cat "$home/state/autoland/svc.lock/pid" 2>/dev/null)" = "$$" ] || fail "runner removed another owner's lock"
  pass "fm-autoland: a runner releases only its own hook lock"
}

test_failed_and_deferred_hooks() {
  local home out
  home=$(make_home deployfail)
  write_config "$home" '{"repos":[{"repo":"o/r","authority":"r","hook":"bad"}]}'
  write_hook "$home" bad 3
  write_gql "$home" "$MAIN_1"
  tick "$home" >/dev/null
  wait_result "$home" bad failed || fail "failure not recorded"
  out=$(tick "$home")
  assert_contains "$out" "deploy of bad aaaaaaa FAILED: exit 3" "failure reported"
  out=$(tick "$home")
  [ -z "$out" ] || fail "failure repeated: $out"
  [ "$(wc -l < "$home/hook-bad.runs" | tr -d ' ')" = 1 ] || fail "a failed deploy was retried on its own"
  [ ! -e "$home/state/autoland/bad.deployed" ] || fail "a failed deploy was recorded as deployed"

  home=$(make_home deploydefer)
  write_config "$home" '{"repos":[{"repo":"o/r","authority":"r","hook":"later"}]}'
  write_hook "$home" later 75
  write_gql "$home" "$MAIN_1"
  tick "$home" >/dev/null
  wait_result "$home" later deferred || fail "deferral not recorded"
  out=$(tick "$home" "$AUTOLAND" FM_AUTOLAND_DEFER_RETRY=999)
  assert_contains "$out" "deploy of later aaaaaaa deferred" "deferral reported"
  sleep 1.1
  write_hook "$home" later 0
  tick "$home" "$AUTOLAND" FM_AUTOLAND_DEFER_RETRY=1 >/dev/null
  wait_result "$home" later deployed || fail "a deferred deploy was not retried"
  pass "fm-autoland: a failed hook reports once without retrying; a deferred one retries"
}

test_unsafe_hook_and_foreground_deploy() {
  local home out rc=0
  home=$(make_home unsafe)
  write_config "$home" '{"repos":[{"repo":"o/r","authority":"r","hook":"svc"}]}'
  write_hook "$home" svc 0 0775
  out=$(FM_HOME="$home" FM_TEST_GH_LOG="$home/gh.log" FM_TEST_HEAD_OID="$MAIN_1" PATH="$FAKEBIN:$PATH" \
    "$AUTOLAND" deploy svc 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a group-writable hook ran"
  assert_contains "$out" "writable by others" "unsafe hook named"
  [ ! -e "$home/hook-svc.runs" ] || fail "a group-writable hook executed"
  chmod 0755 "$home/config/post-merge/svc.sh"
  out=$(FM_HOME="$home" FM_TEST_GH_LOG="$home/gh.log" FM_TEST_HEAD_OID="$MAIN_1" PATH="$FAKEBIN:$PATH" \
    "$AUTOLAND" deploy svc 2>&1) || fail "foreground deploy failed: $out"
  assert_contains "$out" "svc deployed aaaaaaa" "foreground deploy result"
  write_gql "$home" "$MAIN_1"
  out=$(tick "$home")
  [ -z "$out" ] || fail "a foreground result was re-reported: $out"
  pass "fm-autoland: hooks writable by others never run; a foreground deploy is not re-reported"
}

# The watcher runs an armed autoland.check.sh on its own short cadence between
# full sweeps without running other checks or postponing the full sweep.
test_watcher_runs_autoland_between_full_sweeps() {
  local home state before after rc=0 out
  home=$(make_home watcher)
  state="$home/state"
  printf '#!/usr/bin/env bash\nprintf "autoland: fast lane\\n"\n' > "$state/autoland.check.sh"
  printf '#!/usr/bin/env bash\nprintf "other ran\\n"\n' > "$state/other.check.sh"
  chmod 0700 "$state/autoland.check.sh" "$state/other.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" autoland >/dev/null || fail "register autoland"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" other >/dev/null || fail "register other"
  touch "$state/.last-check" "$state/.last-heartbeat" "$state/.last-watcher-beat"
  fm_touch_epoch "$(( $(date +%s) - 60 ))" "$state/.last-check"
  before=$(/bin/ls -l "$state/.last-check")
  out=$(perl -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm 20; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
    env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=3600 FM_AUTOLAND_INTERVAL=1 FM_CHECK_TIMEOUT=5 \
      FM_POLL=0.05 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 "$ROOT/bin/fm-watch.sh" 2>"$home/watch.err") || rc=$?
  expect_code 0 "$rc" "watcher cycle ($(cat "$home/watch.err"))"
  assert_contains "$out" "autoland: fast lane" "fast lane woke the watcher"
  assert_not_contains "$out" "other ran" "the full sweep did not run"
  after=$(/bin/ls -l "$state/.last-check")
  [ "$before" = "$after" ] || fail "the fast lane touched the full-sweep cadence marker"
  pass "fm-watch: an armed autoland check runs on its own cadence between full sweeps"
}

test_help_and_unknown_action
test_arm_and_disarm
test_missing_config_reported_once
test_green_pr_merges_once
test_pending_and_red_checks_stay_silent
test_green_draft_wakes_once_per_head
test_blocking_reasons_are_named
test_refused_merge_is_reported
test_authority_follows_the_registry
test_other_base_and_other_repo_are_ignored
test_task_owned_pr_uses_fm_pr_merge
test_risk_section_is_required_for_attestation
test_attestation_follows_registered_mode
test_live_policy_applies_to_both_merge_paths
test_duplicate_hooks_are_rejected
test_merges_are_bounded_and_notifications_follow_output
test_deploy_runs_after_merge_and_reports
test_fleet_sync_timeout_is_a_continuing_warning
test_hook_lock_publication_and_stale_reclaim_are_serialized
test_hook_lock_release_preserves_another_owner
test_failed_and_deferred_hooks
test_unsafe_hook_and_foreground_deploy
test_watcher_runs_autoland_between_full_sweeps
