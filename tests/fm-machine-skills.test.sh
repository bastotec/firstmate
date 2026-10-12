#!/usr/bin/env bash
# Behavior tests for bin/fm-machine-skills.sh: refresh records each machine's
# `deck skills` (local and over ssh), keeps a failed machine's previous file,
# and check/where/brief-check refuse a placement on a machine that lacks a
# skill and name the machine that has it. deck and ssh are stubs.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(fm_test_tmproot fm-machine-skills)
FAKEBIN=$(fm_fakebin "$T")
H="$T/home"
SKILLS="$ROOT/bin/fm-machine-skills.sh"
mkdir -p "$H/data" "$H/state" "$T/proj"

# deck lists the Mac's skills locally; FAKE_DECK_LIST overrides it.
cat > "$FAKEBIN/deck" <<'SH'
#!/usr/bin/env bash
[ "$1" = skills ] || exit 0
if [ -n "${FAKE_DECK_LIST:-}" ]; then printf '%b' "$FAKE_DECK_LIST"; exit 0; fi
printf 'afk\trepo\tAway mode\t%s/.agents/skills/afk/SKILL.md\n' "$PWD"
printf 'klipper-printers\tglobal\tPrinters\t/u/dotfiles/skills/klipper-printers/SKILL.md\n'
printf 'pr-review\tglobal\tReview\t/u/dotfiles/skills/pr-review/SKILL.md\n'
SH
# ssh answers for workload with shared skills only; FAKE_SSH_DOWN fails it.
cat > "$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in -o) shift 2 ;; -*) shift ;; *) break ;; esac; done
printf '%s %s\n' "$1" "$2" >> "$FAKE_SSH_LOG"
[ -z "${FAKE_SSH_DOWN:-}" ] || { echo 'ssh: connect to host workload port 22: Connection refused' >&2; exit 255; }
printf 'afk\trepo\tAway mode\t/home/b/firstmate/.agents/skills/afk/SKILL.md\n'
printf 'pr-review\tglobal\tReview\t/home/b/.agents/skills/pr-review/SKILL.md\n'
SH
chmod +x "$FAKEBIN/deck" "$FAKEBIN/ssh"
export FAKE_SSH_LOG="$T/ssh.log"
: > "$FAKE_SSH_LOG"
printf -- '- bob - helper (host: workload; root: /home/b/firstmate; home: /home/b/sm/bob; scope: misc; projects: ; added 2026-09-16)\n' > "$H/data/secondmates.md"
printf -- '- laya - local mate (home: %s/laya; scope: misc; projects: ; added 2026-09-16)\n' "$T" >> "$H/data/secondmates.md"

expect_code() { [ "$1" = "$2" ] || fail "$3: expected exit $1, got $2"; }
skills() { PATH="$FAKEBIN:$PATH" FM_HOME="$H" FM_ROOT_OVERRIDE="$T/proj" FM_STATE_OVERRIDE="$H/state" FM_DATA_OVERRIDE="$H/data" "$SKILLS" "$@" 2>&1; }

out=$(skills refresh)
assert_contains "$out" "refresh local=done: 3 skills" "local refresh"
assert_contains "$out" "refresh workload=done: 2 skills" "remote refresh"
grep -q "^# machine=workload root=/home/b/firstmate refreshed=.* count=2$" "$H/state/machine-skills/workload.tsv" || fail "header line"
assert_grep "pr-review	global	/home/b/.agents/skills/pr-review/SKILL.md" "$H/state/machine-skills/workload.tsv" "skill line"
assert_grep "workload cd '/home/b/firstmate'" "$FAKE_SSH_LOG" "remote deck runs in the code root"
assert_equals "local	$T/proj
workload	/home/b/firstmate" "$(skills roots)" "roots lists local first, then remote hosts once"
pass "refresh records local and remote inventories"

set +e
out=$(FAKE_SSH_DOWN=1 skills refresh)
rc=$?
set -e
expect_code 1 "$rc" "refresh with an unreachable machine"
assert_contains "$out" "refresh workload=failed: ssh: connect to host workload port 22: Connection refused" "failure reason"
assert_contains "$out" "refresh local=done" "a failed machine does not stop the others"
assert_grep "pr-review" "$H/state/machine-skills/workload.tsv" "the previous inventory is kept"
out=$(skills refresh newbox:/srv/fm)
assert_contains "$out" "refresh newbox=done: 2 skills" "an unregistered machine refreshes with an explicit root"
rm -f "$H/state/machine-skills/newbox.tsv"
pass "refresh keeps a failed machine's file and takes an explicit root"

set +e
out=$(skills check workload klipper-printers pr-review)
rc=$?
set -e
expect_code 1 "$rc" "a Mac-only skill on workload"
assert_equals "place=refuse: workload lacks klipper-printers; they are on: local" "$out" "refusal names the machine that has it"
set +e
out=$(skills check bob klipper-printers)
rc=$?
set -e
expect_code 1 "$rc" "a mate on workload"
assert_contains "$out" "place=refuse: workload lacks klipper-printers" "a secondmate id resolves to its host"
assert_equals "place=ok machine=local" "$(skills check laya klipper-printers)" "a local mate is on this machine"
assert_equals "place=ok machine=workload" "$(skills check workload pr-review afk)" "shared skills place anywhere"
set +e
out=$(skills check workload sayme)
set -e
assert_equals "place=refuse: workload lacks sayme; no machine in the inventory has them all" "$out" "none has it"
assert_equals "has local" "$(skills where klipper-printers)" "where"
assert_equals "has none" "$(skills where sayme)" "where none"
set +e
out=$(skills check ghost pr-review)
set -e
assert_contains "$out" "ghost has no recorded skill inventory" "unknown machine"
pass "check never places Mac-only work on workload and says where it can go"

printf '# Task\nDo it.\nSkills: `klipper-printers`, pr-review\n' > "$T/brief.md"
set +e
out=$(FAKE_DECK_LIST='pr-review\tglobal\tReview\t/x\n' skills brief-check "$T/brief.md" "$T/proj")
rc=$?
set -e
expect_code 1 "$rc" "brief-check without the skill"
assert_equals "refuse: this machine lacks the skills the brief needs (klipper-printers); they are on: local" "$out" "brief-check refusal"
skills brief-check "$T/brief.md" "$T/proj" >/dev/null || fail "brief-check with every skill present"
printf '# Task\nNo skills named.\n' > "$T/plain.md"
FAKE_DECK_LIST='' skills brief-check "$T/plain.md" "$T/proj" >/dev/null || fail "a brief without a Skills line"
mkdir -p "$T/mate/state"
set +e
out=$(PATH="$FAKEBIN:$PATH" FM_HOME="$T/mate" FM_SECONDMATE_PARENT_HOME="$H" FAKE_DECK_LIST='pr-review\tglobal\tReview\t/x\n' \
  "$SKILLS" brief-check "$T/brief.md" "$T/proj" 2>&1)
set -e
assert_contains "$out" "they are on: local" "a local mate answers where from its primary's inventory"
pass "brief-check refuses a spawn whose brief needs a skill the machine lacks"

# --- bin/fm-machine.sh skills: ship the shared skills over ssh ---
ACCT="$T/acct"
SBIN="$T/sbin"
mkdir -p "$ACCT/.local/bin" "$SBIN" "$T/srvfm"
cp "$FAKEBIN/deck" "$ACCT/.local/bin/deck"
# ssh for fm-machine.sh: -G answers from a fixed config; anything else runs
# locally as the scratch remote account, so git push and the installer are real.
cat > "$SBIN/ssh" <<'SH'
#!/usr/bin/env bash
G=0
while [ "$#" -gt 0 ]; do case "$1" in -G) G=1; shift ;; -o|-F) shift 2 ;; -*) shift ;; *) break ;; esac; done
if [ "$G" -eq 1 ]; then printf 'hostname box.lan\nuser captain\nport 22\n'; exit 0; fi
shift
cd "$FAKE_ACCT" && HOME="$FAKE_ACCT" exec sh -c "$*"
SH
chmod +x "$SBIN/ssh"
git init -q --bare -b main "$T/dots-origin.git"
git init -q -b main "$T/dots"
mkdir -p "$T/dots/skills/pr-review"
printf -- '---\nname: pr-review\n---\n' > "$T/dots/skills/pr-review/SKILL.md"
cat > "$T/dots/install.sh" <<'SH'
#!/bin/sh
[ "$1" = --skills-only ] || exit 9
mkdir -p "$HOME/.agents/skills"
for d in "$PWD"/skills/*/; do ln -sfn "${d%/}" "$HOME/.agents/skills/$(basename "$d")"; done
SH
chmod +x "$T/dots/install.sh"
git -C "$T/dots" add -A
git -C "$T/dots" -c user.name=t -c user.email=t@t commit -qm one
git -C "$T/dots" remote add origin "$T/dots-origin.git"
git -C "$T/dots" push -q origin main
mkdir -p "$H/config"
printf 'source=%s\n' "$T/dots" > "$H/config/shared-skills"
machine() { PATH="$SBIN:$FAKEBIN:$PATH" FAKE_ACCT="$ACCT" FM_HOME="$H" FM_KNOWN_HOSTS="$T/known" FM_SSH_CONFIG="$T/ssh_config" "$ROOT/bin/fm-machine.sh" "$@" 2>&1; }
: > "$T/ssh_config"

out=$(machine skills box "$T/srvfm")
assert_contains "$out" "step shared-skills=done: ~/dotfiles at origin/main" "first ship"
assert_contains "$out" "1 skill links in ~/.agents/skills" "linked count"
assert_contains "$out" "step skill-inventory=done: 3 skills recorded in state/machine-skills/box.tsv" "inventory after ship"
assert_equals "$T/dots/skills/pr-review" "$(readlink "$ACCT/.agents/skills/pr-review" | sed "s|$ACCT/dotfiles|$T/dots|")" "skill is a symlink into the clone"
assert_equals "$(git -C "$T/dots" rev-parse HEAD)" "$(git -C "$ACCT/dotfiles" rev-parse HEAD)" "remote clone at the shipped commit"
assert_equals "$T/dots-origin.git" "$(git -C "$ACCT/dotfiles" config --get remote.origin.url)" "fresh clone keeps the source's origin"
assert_equals main "$(git -C "$ACCT/dotfiles" symbolic-ref --short HEAD)" "fresh clone is on main"

# A new upstream commit fast-forwards the machine.
git clone -q "$T/dots-origin.git" "$T/dots2"
printf 'x\n' > "$T/dots2/skills/pr-review/notes.md"
git -C "$T/dots2" add -A
git -C "$T/dots2" -c user.name=t -c user.email=t@t commit -qm two
git -C "$T/dots2" push -q origin main
out=$(machine skills box "$T/srvfm")
assert_contains "$out" "step shared-skills=done:" "second ship"
assert_equals "$(git -C "$T/dots2" rev-parse HEAD)" "$(git -C "$ACCT/dotfiles" rev-parse HEAD)" "the machine fast-forwarded to origin/main"

# Local changes on the machine are never overwritten.
printf 'mine\n' >> "$ACCT/dotfiles/install.sh"
set +e
out=$(machine skills box "$T/srvfm")
rc=$?
set -e
expect_code 1 "$rc" "ship over local changes"
assert_contains "$out" "step shared-skills=failed: $ACCT/dotfiles has local changes" "dirty refusal"
assert_contains "$(cat "$ACCT/dotfiles/install.sh")" "mine" "local change kept"
pass "fm-machine.sh skills ships the shared skills repo over ssh and records the inventory"

echo "ALL TESTS PASSED"
