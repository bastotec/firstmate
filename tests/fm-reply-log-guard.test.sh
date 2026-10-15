#!/usr/bin/env bash
# tests/fm-reply-log-guard.test.sh - bin/fm-reply-log-guard.py keeps a second
# mate's reply logs append-only. A mate that edited its parent-replies.status in
# place (a typo fix, a dedupe, a sed -i) broke its first mate's mirror for 17
# hours; the guard refuses those tool calls and leaves appends and reads alone.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-reply-log-guard.py"

guard_rc() {  # <tool> <command-or-path>
  python3 -c 'import json,sys; t,a=sys.argv[1:3]; print(json.dumps({"tool_name":t,"args":{"command":a} if t=="run_command" else {"path":a,"old_text":"a","new_text":"b"}}))' "$1" "$2" \
    | python3 "$GUARD" /home/m/state/parent-replies.status /parent/state/m.status >/dev/null 2>&1
  echo $?
}

expect() {  # <rc> <tool> <arg> <label>
  [ "$(guard_rc "$2" "$3")" = "$1" ] || fail "guard: $4 (expected exit $1)"
}

expect 2 run_command "python3 - <<'PY'
p='state/parent-replies.status'
s=open(p).read()
open(p,'w').write(s.replace('a','b',1))
PY" "an in-place python rewrite is refused"
expect 2 run_command "awk '!seen[\$0]++' state/parent-replies.status > /tmp/dedup && mv /tmp/dedup state/parent-replies.status" "a dedupe moved over the log is refused"
expect 2 run_command "sed -i 's/x/y/' state/parent-replies.status" "sed -i is refused"
expect 2 run_command "echo x > /parent/state/m.status" "a truncating redirect onto the parent status is refused"
expect 2 edit_file /home/m/state/parent-replies.status "edit_file on the log is refused"
expect 2 run_command "printf 'x\n' 1> state/parent-replies.status" "an fd-numbered truncating redirect is refused"
expect 2 run_command "python3 -c \"open('state/parent-replies.status', 'wb').write(b'x')\"" "a binary write mode is refused"
expect 2 run_command "python3 -c \"from pathlib import Path; open(Path('state/parent-replies.status'), 'w').write('x')\"" "a nested-path write is refused"
expect 2 run_command "awk '!seen[\$0]++' state/parent-replies.status > /tmp/d && mv /tmp/d state/parent-replies.status # dedupe" "a move followed by a comment is refused"
expect 0 run_command "python3 -c \"open('state/parent-replies.status', 'a').write('x')\"" "a python append is allowed"
expect 0 run_command "printf '%s\n' 'done corr=0123456789abcdef: ok' >> state/parent-replies.status" "an append is allowed"
expect 0 run_command "tail -3 state/parent-replies.status; grep -c corr= state/parent-replies.status 2>/dev/null" "reads are allowed"
expect 0 run_command "printf '%s\n' 'done: removed truncate and sed -i from the script' >> state/parent-replies.status" "an appended reply that mentions edit commands is allowed"
expect 0 run_command "grep truncate state/parent-replies.status" "a search for an edit word is allowed"
expect 0 run_command "echo done: x | tee -a /parent/state/m.status" "tee -a is allowed"
expect 0 edit_file /home/m/data/notes.md "other files are not guarded"
out=$(printf '{"tool_name":"edit_file","args":{"path":"state/parent-replies.status"}}' | python3 "$GUARD" /home/m/state/parent-replies.status 2>&1 >/dev/null)
assert_contains "$out" "append" "the refusal does not tell the model to append a correction instead"
pass "fm-reply-log-guard: in-place rewrites of a reply log are refused, appends and reads are not"
