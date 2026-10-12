#!/usr/bin/env bash
# Behavior tests for bin/fm-machine-instructions.sh: show and save a machine's
# ~/.agents/AGENTS.md locally and over a stub ssh, with a backup, the
# changed-since-read refusal, and the pickup sentence naming the mates there.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(fm_test_tmproot fm-machine-instructions)
FAKEBIN=$(fm_fakebin "$T")
H="$T/home"
I="$ROOT/bin/fm-machine-instructions.sh"
mkdir -p "$H/data" "$T/mac" "$T/acct"
printf -- '- bob - helper (host: workload; root: /home/b/firstmate; home: /home/b/sm/bob; scope: misc; projects: ; added 2026-09-16)\n' > "$H/data/secondmates.md"
printf -- '- laya - local mate (home: %s/laya; scope: misc; projects: ; added 2026-09-16)\n' "$T" >> "$H/data/secondmates.md"
# ssh runs the command locally as the scratch remote account.
cat > "$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
[ "$1" = workload ] || { echo "ssh: unknown host $1" >&2; exit 255; }
shift
cd "$FAKE_ACCT" && HOME="$FAKE_ACCT" exec sh -c "$*"
SH
chmod +x "$FAKEBIN/ssh"
expect_code() { [ "$1" = "$2" ] || fail "$3: expected exit $1, got $2"; }
instr() { PATH="$FAKEBIN:$PATH" HOME="$T/mac" FAKE_ACCT="$T/acct" FM_HOME="$H" FM_DATA_OVERRIDE="$H/data" FM_ROOT_OVERRIDE="$T/fm" "$I" "$@" 2>&1; }

out=$(instr show workload)
assert_contains "$out" "present=no" "absent file"
assert_contains "$out" "sha=none" "absent sha"
assert_contains "$out" "pickup: Deck reads it when a session starts: bob pick it up on their next restart" "pickup names the remote mate"
out=$(printf '# workload\nNever run GPU jobs here.\n' | instr save workload --expect none)
assert_contains "$out" "saved=" "first save"
assert_equals "$(printf '# workload\nNever run GPU jobs here.')" "$(cat "$T/acct/.agents/AGENTS.md")" "remote file written"
sha=$(instr show workload --json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["present"] and d["mates"]==["bob"], d; print(d["sha"])')
[ -n "$sha" ] || fail "show --json gave no sha"
assert_contains "$(instr show workload --json)" '"text": "# workload\nNever run GPU jobs here.\n"' "json text"
pass "show and save a remote machine's instructions"

set +e
out=$(printf 'stale edit\n' | instr save workload --expect none)
rc=$?
set -e
expect_code 3 "$rc" "save over a changed file"
assert_contains "$out" "changed since it was read" "conflict refusal"
assert_contains "$(cat "$T/acct/.agents/AGENTS.md")" "GPU" "conflict left the file alone"
printf 'Use at most 4 CPUs.\n' | instr save workload --expect "$sha" >/dev/null
assert_equals "Use at most 4 CPUs." "$(cat "$T/acct/.agents/AGENTS.md")" "second save"
assert_contains "$(cat "$T/acct/.agents/AGENTS.md.bak")" "GPU" "previous version kept"
out=$(printf '' | instr save workload)
assert_contains "$out" "saved=removed" "empty save removes"
assert_absent "$T/acct/.agents/AGENTS.md" "file removed"
pass "save refuses a changed file, keeps a backup, and empty removes"

out=$(printf 'Mac rules\n' | instr save local --json)
assert_contains "$out" '"mates": ["primary", "laya"]' "local pickup names the primary and local mates"
assert_equals "Mac rules" "$(cat "$T/mac/.agents/AGENTS.md")" "local file written"
set +e
out=$(instr show ghost)
rc=$?
set -e
expect_code 1 "$rc" "unknown machine"
assert_contains "$out" "refuse: not a known machine: ghost" "unknown machine refusal"
set +e
out=$(head -c 70000 /dev/zero | tr '\0' a | instr save local)
rc=$?
set -e
expect_code 1 "$rc" "oversized text"
assert_contains "$(cat "$T/mac/.agents/AGENTS.md")" "Mac rules" "oversized save left the file alone"
pass "local saves name the primary, and unknown machines and oversized text are refused"

echo "ALL TESTS PASSED"
