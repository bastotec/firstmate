#!/usr/bin/env bash
# Behavior tests for bin/fm-machine-rules.sh: a machine whose ~/.agents/AGENTS.md
# says "firstmate: ask before comment" makes an agent there ask the captain
# instead of commenting, while actions it does not name stay allowed.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(fm_test_tmproot fm-machine-rules)
R="$ROOT/bin/fm-machine-rules.sh"
mkdir -p "$T/workload/.agents" "$T/mac"
rules() { HOME="$1" "$R" "${@:2}" 2>&1; }
code() { set +e; HOME="$1" "$R" "${@:2}" >/dev/null 2>&1; local rc=$?; set -e; printf '%s' "$rc"; }

cat > "$T/workload/.agents/AGENTS.md" <<'MD'
# workload

Shared box for long builds. Never run GPU jobs here.

firstmate: Ask before comment, publish
MD

assert_equals 4 "$(code "$T/workload" check comment)" "a mate on a no-comment machine must not comment"
assert_equals 'ask: this machine'"'"'s ~/.agents/AGENTS.md says "firstmate: Ask before comment, publish"; ask the captain (a decision card) instead of acting' \
  "$(rules "$T/workload" check comment)" "the refusal quotes the machine's own line and asks the captain"
assert_equals 4 "$(code "$T/workload" check publish)" "publish is asked too"
assert_equals allow "$(rules "$T/workload" check merge)" "merge was not named, so it stays allowed"
pass "a mate on a no-comment machine asks the captain instead of commenting"

assert_equals allow "$(rules "$T/mac" check comment)" "a machine without instructions allows"
printf 'We talk about firstmate: ask before merge in prose here.\n' > "$T/mac/notes"
mkdir -p "$T/mac/.agents"
printf 'Prose that mentions firstmate: ask before merge mid-line is not a rule.\n' > "$T/mac/.agents/AGENTS.md"
assert_equals allow "$(rules "$T/mac" check merge)" "only a line that starts with the rule counts"
for text in '- firstmate: ask before merge' '> firstmate: ask before merge' 'firstmate: ask before merge and publish' 'firstmate: ask before merge1' 'firstmate: ask before merge!'; do
  printf '%s\n' "$text" > "$T/mac/.agents/AGENTS.md"
  assert_equals allow "$(rules "$T/mac" check merge)" "undocumented forms are not rules: $text"
done
printf '  FIRSTMATE: ASK BEFORE   merge , COMMENT  \n' > "$T/mac/.agents/AGENTS.md"
assert_equals 4 "$(code "$T/mac" check merge)" "case and whitespace are accepted"
assert_equals 4 "$(code "$T/mac" check comment)" "comma-separated actions are accepted"
assert_equals 2 "$(code "$T/mac" list)" "unsupported list command refuses"
chmod 000 "$T/mac/.agents/AGENTS.md"
if [ ! -r "$T/mac/.agents/AGENTS.md" ]; then
  assert_equals 4 "$(code "$T/mac" check merge)" "an unreadable file refuses"
fi
chmod 600 "$T/mac/.agents/AGENTS.md"
assert_equals 2 "$(code "$T/mac" check delete)" "unknown action is a usage error"
pass "rules apply only when written, and unreadable instructions refuse"

echo "ALL TESTS PASSED"
