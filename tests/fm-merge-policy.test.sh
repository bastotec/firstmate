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

test_list_json_covers_touched_repositories() {
  local home out
  home=$(new_home list)
  mkdir -p "$home/projects/app"
  git -C "$home/projects/app" init -q && git -C "$home/projects/app" remote add origin https://github.com/acme/app.git
  printf '%s\n' '{"repos":[{"repo":"bastotec/deck","authority":"x"}]}' > "$home/config/autoland.json"
  FM_HOME="$home" "$POLICY" set DocanaAI/docana ask --by captain --note n >/dev/null || fail "set failed"
  out=$(FM_HOME="$home" "$POLICY" list --json) || fail "list --json failed"
  printf '%s' "$out" | jq -e '
    .default == "ask" and .owners.bastotec == "auto"
    and ([.repos[].repo] == ["acme/app", "bastotec/deck", "DocanaAI/docana"])
    and (.repos[] | select(.repo == "acme/app") | .policy == "ask" and .source == "default" and .at == null)
    and (.repos[] | select(.repo == "bastotec/deck") | .policy == "auto" and .source == "owner")
    and (.repos[] | select(.repo == "DocanaAI/docana") | .source == "set" and .by == "captain" and (.at | type == "number"))
  ' >/dev/null || fail "list --json did not cover touched repositories with their source: $out"
  pass "list --json lists every touched repository with its policy, source, and who set it when"
}

test_builtin_defaults
test_set_resolves_repo_over_owner_over_default
test_invalid_input_and_unreadable_file
test_primary_home_pushes_to_second_mates
test_pr_merge_refuses_a_never_repository
test_list_json_covers_touched_repositories
