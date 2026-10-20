#!/usr/bin/env bash
# Behavior tests for bin/fm-merge-policy.sh: built-in defaults, repo over owner
# over default, validated dated writes with an audit line, the push to second
# mate homes, and bin/fm-pr-merge.sh refusing a never repository.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POLICY="$ROOT/bin/fm-merge-policy.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-policy)

new_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/data" "$home/state"
  printf '%s\n' "$home"
}

test_builtin_defaults() {
  local home
  home=$(new_home defaults)
  assert_equals 'auto owner bastotec' "$(FM_HOME="$home" "$POLICY" get bastotec/no-mistakes)" "bastotec is not auto by default"
  assert_equals 'auto owner brunobasto' "$(FM_HOME="$home" "$POLICY" get BrunoBasto/dotfiles)" "brunobasto is not auto by default"
  assert_equals 'ask default' "$(FM_HOME="$home" "$POLICY" get DocanaAI/docana)" "another org is not ask by default"
  assert_equals '{"repo":"cadia-studio/cadia","policy":"ask","source":"default"}' \
    "$(FM_HOME="$home" "$POLICY" get cadia-studio/cadia --json)" "--json did not carry the source"
  pass "without a file, bastotec and brunobasto are auto and everything else is ask"
}

test_set_resolves_repo_over_owner_over_default() {
  local home out
  home=$(new_home set)
  out=$(FM_HOME="$home" "$POLICY" set bastotec/secret never --by captain --note "keep manual")
  assert_equals 'set bastotec/secret auto -> never' "$out" "the change was not reported"
  FM_HOME="$home" "$POLICY" set 'acme/*' auto >/dev/null || fail "owner set failed"
  FM_HOME="$home" "$POLICY" set '*' never >/dev/null || fail "default set failed"
  assert_equals 'never repo' "$(FM_HOME="$home" "$POLICY" get BASTOTEC/Secret)" "the repo entry did not win case-insensitively"
  assert_equals 'auto owner bastotec' "$(FM_HOME="$home" "$POLICY" get bastotec/other)" "the owner entry was lost"
  assert_equals 'auto owner acme' "$(FM_HOME="$home" "$POLICY" get acme/tool)" "the new owner entry did not apply"
  assert_equals 'never default' "$(FM_HOME="$home" "$POLICY" get someone/else)" "the new default did not apply"
  jq -e '.repos["bastotec/secret"] | .policy == "never" and .by == "captain" and .note == "keep manual"
         and (.set | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))' "$home/config/merge-policy.json" >/dev/null \
    || fail "the repo entry is not dated with who and why: $(cat "$home/config/merge-policy.json")"
  assert_grep 'captain bastotec/secret auto -> never keep manual' "$home/data/merge-policy.log" "no audit line was written"
  assert_equals 3 "$(wc -l < "$home/data/merge-policy.log" | tr -d ' ')" "not one audit line per change"
  pass "set writes dated repo, owner and default entries with an audit line, and get resolves repo over owner over default"
}

test_invalid_input_and_unreadable_file() {
  local home rc
  home=$(new_home invalid)
  rc=0; FM_HOME="$home" "$POLICY" set bastotec/x sometimes >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "an unknown policy was accepted"
  rc=0; FM_HOME="$home" "$POLICY" set 'not a repo' auto >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "a malformed name was accepted"
  assert_absent "$home/config/merge-policy.json" "a refused set wrote the file"
  printf 'not json\n' > "$home/config/merge-policy.json"
  rc=0; FM_HOME="$home" "$POLICY" get bastotec/x >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" "an unreadable policy file was not reported"
  printf '{"default":"sometimes"}\n' > "$home/config/merge-policy.json"
  rc=0; FM_HOME="$home" "$POLICY" get bastotec/x >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" "a file with an unknown policy was accepted"
  pass "invalid names and policies are refused, and an unreadable file is an error"
}

test_primary_home_pushes_to_second_mates() {
  local home bin
  home=$(new_home push)
  bin="$TMP_ROOT/push-bin"
  mkdir -p "$bin"
  cp "$POLICY" "$bin/fm-merge-policy.sh"
  printf '#!/usr/bin/env bash\necho pushed >> "%s/pushes"\n' "$home" > "$bin/fm-config-push.sh"
  chmod +x "$bin/fm-config-push.sh"
  FM_HOME="$home" "$bin/fm-merge-policy.sh" set bastotec/a ask >/dev/null || fail "set failed"
  assert_absent "$home/pushes" "a home without second mates pushed"
  : > "$home/data/secondmates.md"
  FM_HOME="$home" "$bin/fm-merge-policy.sh" set bastotec/a auto >/dev/null || fail "set failed"
  assert_equals pushed "$(cat "$home/pushes")" "the primary home did not push the change"
  FM_HOME="$home" "$bin/fm-merge-policy.sh" set bastotec/a never --no-push >/dev/null || fail "set failed"
  assert_equals 1 "$(wc -l < "$home/pushes" | tr -d ' ')" "--no-push still pushed"
  pass "the primary home pushes each change to the second mate homes"
}

test_writer_lock_recovery() {
  local home lock scenario pid rc
  pid=$(bash -c 'echo $$')
  for scenario in old-empty old-live dead live; do
    home=$(new_home "writer-$scenario")
    lock="$home/config/.merge-policy.lock"
    mkdir "$lock"
    case "$scenario" in
      old-live|live) printf '%s\n' "$$" > "$lock/pid" ;;
      dead) printf '%s\n' "$pid" > "$lock/pid" ;;
    esac
    case "$scenario" in old-*) touch -t 200001010000 "$lock" ;; esac
    rc=0
    FM_HOME="$home" "$POLICY" set bastotec/app never --no-push > "$home/output" 2>&1 || rc=$?
    if [ "$scenario" = live ]; then
      assert_equals 1 "$rc" "a current writer lock was stolen"
      assert_equals "$$" "$(cat "$lock/pid")" "the active writer's ownership changed"
      assert_absent "$home/config/merge-policy.json" "a blocked writer published policy"
    else
      assert_equals 0 "$rc" "a stale writer lock was not reclaimed: $scenario: $(cat "$home/output")"
      assert_equals 'never repo' "$(FM_HOME="$home" "$POLICY" get bastotec/app)" "recovered writer did not publish policy"
      assert_absent "$lock" "recovered writer did not release its lock"
    fi
  done
  pass "policy writers reclaim old or dead-owner locks but respect a live current writer"
}

test_pr_merge_refuses_a_never_repository() {
  local home dir out rc=0
  home=$(new_home never-merge)
  dir="$TMP_ROOT/never-gh"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\necho "gh $*" >> "%s/gh.log"\nexit 1\n' "$dir" > "$dir/gh"
  chmod +x "$dir/gh"
  FM_HOME="$home" "$POLICY" set o/r never >/dev/null || fail "set failed"
  out=$(FM_HOME="$home" PATH="$dir:$PATH" "$ROOT/bin/fm-pr-merge.sh" t1 https://github.com/o/r/pull/7 2>&1) || rc=$?
  assert_equals 1 "$rc" "a never repository was not refused: $out"
  assert_contains "$out" "merge policy for o/r is never" "the refusal did not name the policy"
  assert_absent "$dir/gh.log" "the refusal still called GitHub"
  pass "fm-pr-merge.sh refuses a never repository before touching GitHub"
}

test_owner_keys_are_case_insensitive() {
  local home out
  home=$(new_home owner-case)
  FM_HOME="$home" "$POLICY" set 'BASTOTEC/*' never >/dev/null || fail "uppercase owner set failed"
  assert_equals 'never owner bastotec' "$(FM_HOME="$home" "$POLICY" get bastotec/app)" "uppercase set retained built-in authority"
  printf '%s\n' '{"owners":{"BASTOTEC":"never"}}' > "$home/config/merge-policy.json"
  assert_equals 'never owner bastotec' "$(FM_HOME="$home" "$POLICY" get bastotec/app)" "file owner did not override the built-in case-insensitively"
  printf '%s\n' '{"repos":[{"repo":"bastotec/app","authority":"x"}]}' > "$home/config/autoland.json"
  out=$(FM_HOME="$home" "$POLICY" list --json)
  printf '%s' "$out" | jq -e '.owners.bastotec == "never" and (.repos[0] | .policy == "never" and .source == "owner")' >/dev/null \
    || fail "list retained built-in authority: $out"
  FM_HOME="$home" "$POLICY" set 'BastoTec/*' ask >/dev/null || fail "mixed-case owner set failed"
  assert_equals 'ask owner bastotec' "$(FM_HOME="$home" "$POLICY" get BASTOTEC/app)" "owner case variant was not replaced"
  jq -e '.owners == {bastotec:"ask"}' "$home/config/merge-policy.json" >/dev/null || fail "set persisted conflicting case variants"
  assert_grep 'BastoTec/* never -> ask' "$home/data/merge-policy.log" "audit did not report the previous effective policy"
  pass "owner writes, file overlays, and list resolve case-insensitively"
}

test_list_json_covers_touched_repositories() {
  local home out
  home=$(new_home list)
  mkdir -p "$home/projects/app" "$home/projects/ssh" "$home/projects/ssh-suffix"
  git -C "$home/projects/app" init -q && git -C "$home/projects/app" remote add origin https://github.com/acme/app.git
  git -C "$home/projects/ssh" init -q && git -C "$home/projects/ssh" remote add origin ssh://git@github.com/acme/ssh
  git -C "$home/projects/ssh-suffix" init -q && git -C "$home/projects/ssh-suffix" remote add origin ssh://git@github.com/ACME/ssh.git
  printf '%s\n' '{"repos":[{"repo":"bastotec/deck","authority":"x"}]}' > "$home/config/autoland.json"
  FM_HOME="$home" "$POLICY" set DocanaAI/docana ask --by captain --note n >/dev/null || fail "set failed"
  out=$(FM_HOME="$home" "$POLICY" list --json) || fail "list --json failed"
  printf '%s' "$out" | jq -e '
    .default == "ask" and .owners.bastotec == "auto"
    and ([.repos[].repo | ascii_downcase] == ["acme/app", "acme/ssh", "bastotec/deck", "docanaai/docana"])
    and (.repos[] | select(.repo | ascii_downcase == "acme/ssh") | .policy == "ask" and .source == "default")
    and (.repos[] | select(.repo == "acme/app") | .policy == "ask" and .source == "default" and .at == null)
    and (.repos[] | select(.repo == "bastotec/deck") | .policy == "auto" and .source == "owner")
    and (.repos[] | select(.repo == "DocanaAI/docana") | .source == "set" and .by == "captain" and (.at | type == "number"))
  ' >/dev/null || fail "list --json did not cover touched repositories with their source: $out"
  pass "list --json lists every touched repository with its policy, source, and who set it when"
}

merge_home() {
  local home
  home=$(new_home "$1")
  mkdir -p "$home/bin"
  printf '%s\n' '- app [direct-PR] - fixture (added 2026-01-01)' > "$home/data/projects.md"
  printf '%s\n' '{"repos":[{"repo":"bastotec/app","project":"app"}]}' > "$home/config/autoland.json"
  jq -n --arg head aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa '
    {url:"https://github.com/bastotec/app/pull/7", state:"OPEN", isDraft:false,
     mergeable:"MERGEABLE", mergeStateStatus:"CLEAN", headRefOid:$head, baseRefName:"main",
     repository:{nameWithOwner:"bastotec/app",defaultBranchRef:{name:"main"}},
     labels:[], body:"ordinary PR body",
     statusCheckRollup:[{__typename:"CheckRun",name:"ci",status:"COMPLETED",conclusion:"SUCCESS"}]}' > "$home/live.json"
  cat > "$home/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/gh.log"
case "$1 $2" in
  'api graphql')
    case "$*" in
      *'search(query:'*)
        jq '{data:{search:{nodes:[. + {labels:{nodes:[]},commits:{nodes:[{commit:{statusCheckRollup:{contexts:{nodes:.statusCheckRollup}}}}]}}]}}}' "$FM_HOME/live.json" ;;
      *) printf 'state=MERGED\nmerged=true\nqueued=false\nbase=main\n' ;;
    esac ;;
  'pr view')
    case "$*" in
      *'--json state -q .state'*) echo MERGED ;;
      *)
        if [ -n "${FM_TEST_REVOKE:-}" ]; then
          views=$(cat "$FM_HOME/views" 2>/dev/null || echo 0)
          views=$((views + 1))
          printf '%s\n' "$views" > "$FM_HOME/views"
          if [ "$views" -eq "${FM_TEST_REVOKE_ON_VIEW:-1}" ]; then
            "$FM_TEST_POLICY" set bastotec/app "$FM_TEST_REVOKE" --no-push > "$FM_HOME/revocation"
          fi
        fi
        cat "$FM_HOME/live.json" ;;
    esac ;;
  'pr merge')
    if [ "${FM_TEST_TRY_WRITE:-false}" = true ]; then
      rc=0
      "$FM_TEST_POLICY" set bastotec/app never --no-push > "$FM_HOME/write-output" 2>&1 || rc=$?
      printf '%s\n' "$rc" > "$FM_HOME/write-rc"
    fi ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$home/bin/gh"
  printf '%s\n' "$home"
}

merge_in_home() {
  local home=$1
  shift
  env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_MACHINE_INSTRUCTIONS="$home/machine.md" \
    FM_TEST_POLICY="$POLICY" PATH="$home/bin:$PATH" "$@"
}

attest_home() {
  jq '.body = "## Risk Assessment\n\nLow: bounded\n\n<!-- no-mistakes-pipeline-attestation:v1 "
    + ({head_sha:.headRefOid,steps:[{step:"review",status:"completed"},{step:"test",status:"completed"},{step:"document",status:"completed"}]} | tojson) + " -->"' \
    "$1/live.json" > "$1/attested.json"
  mv "$1/attested.json" "$1/live.json"
}

test_policy_auto_requires_attestation() {
  local home out source
  for source in owner repo; do
    home=$(merge_home "attestation-$source")
    if [ "$source" = repo ]; then
      FM_HOME="$home" "$POLICY" set bastotec/app auto --no-push >/dev/null || fail "set failed"
    fi
    out=$(merge_in_home "$home" "$ROOT/bin/fm-autoland.sh" check)
    assert_contains "$out" 'no no-mistakes attestation' "policy auto merged an unattested direct-PR: $out"
    assert_no_grep 'pr merge ' "$home/gh.log" "unattested direct-PR was merged"
    attest_home "$home"
    out=$(merge_in_home "$home" "$ROOT/bin/fm-autoland.sh" check)
    assert_contains "$out" 'merged https://github.com/bastotec/app/pull/7' "attested policy-auto PR did not land: $out"
  done
  home=$(merge_home legacy-attestation)
  printf '%s\n' '{"owners":{"bastotec":"auto"}}' > "$home/config/merge-policy.json"
  jq '.url = "https://github.com/other/app/pull/7" | .repository.nameWithOwner = "other/app"' "$home/live.json" > "$home/other.json"
  mv "$home/other.json" "$home/live.json"
  printf '%s\n' '{"repos":[{"repo":"other/app","project":"app","authority":"existing ruling"}]}' > "$home/config/autoland.json"
  out=$(merge_in_home "$home" "$ROOT/bin/fm-autoland.sh" check)
  assert_contains "$out" 'merged https://github.com/other/app/pull/7' "bare default lost legacy direct-PR authority: $out"
  pass "policy auto requires pipeline evidence for direct-PR while bare-default legacy authority remains"
}

test_policy_revocation_at_merge_boundaries() {
  local home out rc path policy
  for path in task unowned; do
    for policy in never ask; do
      [ "$path:$policy" != task:ask ] || continue
      home=$(merge_home "revoked-$path-$policy")
      attest_home "$home"
      if [ "$path" = task ]; then
        printf 'kind=ship\nmode=no-mistakes\nproject=app\n' > "$home/state/t1.meta"
        rc=0
        out=$(merge_in_home "$home" env FM_TEST_REVOKE="$policy" "$ROOT/bin/fm-pr-merge.sh" t1 https://github.com/bastotec/app/pull/7 2>&1) || rc=$?
        assert_equals 1 "$rc" "revoked task merge did not refuse: $out"
        assert_contains "$out" 'merge policy for bastotec/app is never' "task refusal did not name the revocation: $out"
      else
        out=$(merge_in_home "$home" env FM_TEST_REVOKE="$policy" "$ROOT/bin/fm-autoland.sh" check)
        assert_contains "$out" 'current merge policy no longer permits autoland' "autoland ignored revocation: $out"
      fi
      assert_grep "auto -> $policy" "$home/revocation" "policy revocation did not succeed"
      assert_no_grep 'pr merge ' "$home/gh.log" "a completed revocation was bypassed"
      assert_absent "$home/config/.merge-policy.lock" "a refused merge leaked the policy lock"
    done
  done
  pass "both final merge boundaries refuse policy revoked after the initial read"
}

test_task_autoland_rechecks_policy() {
  local home out path
  for path in autoland captain; do
    home=$(merge_home "task-ask-$path")
    attest_home "$home"
    printf 'kind=ship\nmode=no-mistakes\nproject=app\npr=https://github.com/bastotec/app/pull/7\n' > "$home/state/t1.meta"
    if [ "$path" = autoland ]; then
      out=$(merge_in_home "$home" env FM_TEST_REVOKE=ask FM_TEST_REVOKE_ON_VIEW=2 "$ROOT/bin/fm-autoland.sh" check)
      assert_contains "$out" 'current merge policy no longer permits autoland' "task-owned autoland ignored revocation: $out"
      assert_equals 2 "$(cat "$home/views")" "revocation did not reach the task helper's live read"
      assert_no_grep 'pr merge ' "$home/gh.log" "task-owned autoland bypassed completed revocation"
    else
      out=$(merge_in_home "$home" env FM_TEST_REVOKE=ask "$ROOT/bin/fm-pr-merge.sh" t1 https://github.com/bastotec/app/pull/7 2>&1) || fail "captain-approved ask merge refused: $out"
      assert_grep 'pr merge ' "$home/gh.log" "captain-approved ask merge never reached the forge"
    fi
    assert_equals 'ask repo' "$(FM_HOME="$home" "$POLICY" get bastotec/app)" "the policy did not change to ask"
    assert_grep 'auto -> ask' "$home/revocation" "policy revocation did not succeed"
  done
  pass "task-owned autoland rechecks authority while captain-approved ask merges still proceed"
}

test_merges_ignore_writer_lock() {
  local home out path lock
  for path in task unowned; do
    home=$(merge_home "lock-$path")
    attest_home "$home"
    lock="$home/config/.merge-policy.lock"
    mkdir "$lock"
    printf '%s\n' "$$" > "$lock/pid"
    if [ "$path" = task ]; then
      printf 'kind=ship\nmode=no-mistakes\nproject=app\n' > "$home/state/t1.meta"
      out=$(merge_in_home "$home" "$ROOT/bin/fm-pr-merge.sh" t1 https://github.com/bastotec/app/pull/7 2>&1) || fail "task merge failed: $out"
    else
      out=$(merge_in_home "$home" "$ROOT/bin/fm-autoland.sh" check)
    fi
    assert_grep 'pr merge ' "$home/gh.log" "the forge command was blocked by a policy writer: $out"
    assert_equals "$$" "$(cat "$lock/pid")" "merge disturbed the policy writer's lock"
    rm "$lock/pid"
    rmdir "$lock"
  done
  pass "both merge paths proceed without acquiring or disturbing the policy writer lock"
}

test_policy_changes_during_inflight_merge() {
  local home out path
  for path in task unowned; do
    home=$(merge_home "inflight-$path")
    attest_home "$home"
    if [ "$path" = task ]; then
      printf 'kind=ship\nmode=no-mistakes\nproject=app\n' > "$home/state/t1.meta"
      out=$(merge_in_home "$home" env FM_TEST_TRY_WRITE=true "$ROOT/bin/fm-pr-merge.sh" t1 https://github.com/bastotec/app/pull/7 2>&1) || fail "task merge failed: $out"
    else
      out=$(merge_in_home "$home" env FM_TEST_TRY_WRITE=true "$ROOT/bin/fm-autoland.sh" check)
    fi
    assert_grep 'pr merge ' "$home/gh.log" "the forge command was never exercised: $out"
    assert_equals 0 "$(cat "$home/write-rc")" "an in-flight forge command blocked a policy write"
    assert_equals 'never repo' "$(FM_HOME="$home" "$POLICY" get bastotec/app)" "in-flight revocation was not published"
    assert_absent "$home/config/.merge-policy.lock" "policy writer did not release its lock"
  done
  pass "policy changes can complete while either forge merge command is in flight"
}

test_attended_override_validates_policy() {
  local home out rc
  home=$(merge_home attended-policy)
  printf 'not json\n' > "$home/config/merge-policy.json"
  rc=0
  out=$(merge_in_home "$home" "$ROOT/bin/fm-pr-merge.sh" t1 https://github.com/bastotec/app/pull/7 --attended-override 2>&1) || rc=$?
  assert_equals 1 "$rc" "attended override accepted unreadable policy: $out"
  assert_contains "$out" 'merge policy cannot be read' "attended refusal did not name unreadable policy: $out"
  assert_absent "$home/gh.log" "unreadable policy reached GitHub under attended override"
  printf '%s\n' '{"repos":{"bastotec/app":{"policy":"never"}}}' > "$home/config/merge-policy.json"
  printf 'kind=ship\nmode=no-mistakes\nproject=app\n' > "$home/state/t1.meta"
  out=$(merge_in_home "$home" "$ROOT/bin/fm-pr-merge.sh" t1 https://github.com/bastotec/app/pull/7 --attended-override 2>&1) || fail "attended never override refused: $out"
  assert_grep 'pr merge ' "$home/gh.log" "valid attended never override did not merge"
  pass "attended override bypasses never but never policy validation"
}

test_builtin_defaults
test_set_resolves_repo_over_owner_over_default
test_invalid_input_and_unreadable_file
test_primary_home_pushes_to_second_mates
test_writer_lock_recovery
test_pr_merge_refuses_a_never_repository
test_list_json_covers_touched_repositories
test_owner_keys_are_case_insensitive
test_policy_auto_requires_attestation
test_policy_revocation_at_merge_boundaries
test_task_autoland_rechecks_policy
test_merges_ignore_writer_lock
test_policy_changes_during_inflight_merge
test_attended_override_validates_policy
