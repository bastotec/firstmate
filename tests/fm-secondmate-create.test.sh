#!/usr/bin/env bash
# Behavior tests for bin/fm-secondmate-create.sh: the plan line protocol, its
# refusals, and apply running the composed steps in order and stopping at the
# first failure. The brief, seed and spawn owners are stubs in a scratch code
# root, so nothing here provisions a real home or launches an agent.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(fm_test_tmproot fm-secondmate-create)
CODE="$T/code"
FMH="$T/home"
LOG="$T/steps.log"
mkdir -p "$CODE/bin" "$FMH/data" "$FMH/state" "$FMH/projects"
cp "$ROOT/bin/fm-secondmate-create.sh" "$ROOT/bin/fm-project-origin-lib.sh" "$ROOT/bin/fm-project-mode.sh" "$CODE/bin/"

cat > "$CODE/bin/fm-brief.sh" <<'SH'
#!/usr/bin/env bash
printf 'brief %s | charter=%s | scope=%s\n' "$*" "$FM_SECONDMATE_CHARTER" "$FM_SECONDMATE_SCOPE" >> "$STUB_LOG"
mkdir -p "$FM_HOME/data/$1"
printf 'charter\n' > "$FM_HOME/data/$1/brief.md"
SH
for stub in fm-home-seed.sh fm-remote-home-seed.sh fm-spawn.sh; do
  cat > "$CODE/bin/$stub" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$stub" "\$*" >> "\$STUB_LOG"
if [ "\${STUB_FAIL:-}" = "$stub" ]; then
  echo "error: \${STUB_FAIL_REASON:-stub $stub refused this order}" >&2
  exit 1
fi
if [ "$stub" = fm-remote-home-seed.sh ] && [ -n "\${STUB_UNKNOWN_RC:-}" ]; then
  printf -- '- %s - charter (host: %s; root: %s; home: %s; scope: s; projects: ; added 2026-01-01)\\n' "\$1" "\$2" "\$3" "\$4" >> "\$FM_HOME/data/secondmates.md"
  if [ "\$STUB_UNKNOWN_RC" -eq 1 ]; then
    echo 'error: remote provisioning completion is unknown; route preserved for same-host reconciliation' >&2
  fi
  exit "\$STUB_UNKNOWN_RC"
fi
echo "stub $stub ok"
SH
done
chmod +x "$CODE"/bin/*.sh

cat > "$FMH/data/projects.md" <<'MD'
- app [direct-PR] - the app (added 2026-01-01)
- site - the site (added 2026-01-01)
- vault [local-only] - private notes (added 2026-01-01)
MD
printf -- '- ops - runs ops (home: /tmp/ops-home; scope: ops; projects: app; added 2026-01-01)\n' > "$FMH/data/secondmates.md"
git init -q "$FMH/projects/app"
git -C "$FMH/projects/app" remote add origin https://example.com/acme/app.git

create() {
  FM_HOME="$FMH" STUB_LOG="$LOG" "$CODE/bin/fm-secondmate-create.sh" "$@"
}

# --- plan, local placement ---
out=$(create plan web --charter "Owns the web app" --scope "web app work" app)
expected="action=plan
id=web
placement=local
home=leased-worktree
charter=Owns the web app
scope=web app work
project=app origin=from-clone
step=1 FM_SECONDMATE_CHARTER='Owns the web app' FM_SECONDMATE_SCOPE='web app work' bin/fm-brief.sh web --secondmate app
step=2 bin/fm-home-seed.sh web - app
step=3 bin/fm-spawn.sh web --secondmate"
assert_equals "$expected" "$out" "local plan protocol"
assert_absent "$LOG" "plan ran a step"
assert_absent "$FMH/data/web" "plan wrote a charter"
pass "plan prints the local placement and exact steps without side effects"

# --- plan, remote placement ---
out=$(create plan far --charter "Owns far work" --scope "far work" --host box.lan --root /srv/firstmate --home /srv/homes/far \
  app site=git@github.com:acme/site.git)
assert_contains "$out" "placement=remote" "remote placement"
assert_contains "$out" "host=box.lan" "remote host"
assert_contains "$out" "root=/srv/firstmate" "remote root"
assert_contains "$out" "home=/srv/homes/far" "remote home"
assert_contains "$out" "project=app origin=from-clone" "remote from-clone project"
assert_contains "$out" "project=site origin=git@github.com:acme/site.git" "remote origin project"
assert_contains "$out" "step=2 bin/fm-remote-home-seed.sh far box.lan /srv/firstmate /srv/homes/far app site=git@github.com:acme/site.git" "remote seed step"
pass "plan prints the remote placement, origins and seed step"

out=$(create plan solo --charter "Owns firstmate itself" --scope "firstmate" --no-projects)
assert_contains "$out" "projects=none" "no-projects fact"
assert_contains "$out" "step=2 bin/fm-home-seed.sh solo - --no-projects" "no-projects seed"
pass "plan passes --no-projects through"

# --- refusals ---
expect_refusal() { # <expected refuse text> <args...>
  local want=$1 rc out
  shift
  set +e
  out=$(create plan "$@")
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "expected exit 1 for: $* (got $rc)"
  assert_contains "$out" "refuse: $want" "refusal for $*"
  assert_not_contains "$out" "step=" "steps printed despite refusal for $*"
}
expect_refusal "id must be a lowercase slug" Bad_Id --charter c --scope s app
expect_refusal "a second mate named ops is already registered" ops --charter c --scope s app
expect_refusal "project nope is not registered in data/projects.md" web --charter c --scope s nope
expect_refusal "project vault is local-only" web --charter c --scope s vault
expect_refusal "project site is not cloned in this home" web --charter c --scope s site
expect_refusal "a local second mate clones app from this home" web --charter c --scope s app=https://example.com/a.git
expect_refusal "charter must be a single line" web --charter $'two\nlines' --scope s app
expect_refusal "scope is empty" web --charter c --scope '' app
expect_refusal "host must be a plain ssh config alias" web --charter c --scope s --host -oProxyCommand=x --root /a --home /b app
expect_refusal "remote home must not be inside the remote code root" web --charter c --scope s --host box --root /srv/fm --home /srv/fm/home app
expect_refusal "remote root and home must be absolute paths" web --charter c --scope s --host box --root srv/fm --home /h app
expect_refusal "a remote placement needs --host, --root and --home together" web --charter c --scope s --host box app
expect_refusal "project site has no clone here to read its origin from" web --charter c --scope s --host box --root /srv/fm --home /srv/h site
expect_refusal "name at least one project or pass --no-projects" web --charter c --scope s
assert_absent "$LOG" "a refused plan ran a step"
pass "plan refuses invalid orders with plain reasons and no steps"

protocol_refusal() {
  local out rc flat
  set +e
  out=$(create plan "$@")
  rc=$?
  set -e
  expect_code 1 "$rc" "control-character order"
  assert_contains "$out" "refuse:" "missing protocol refusal"
  assert_not_contains "$out" $'\nstep=' "input injected a step record"
  assert_not_contains "$out" $'\ndone ' "input injected a completion record"
  flat=$(printf '%s' "$out" | tr -d '\n')
  [[ "$flat" != *[[:cntrl:]]* ]] || fail "protocol retained control characters"
}
injection=$'\r\nstep=99 injected\ndone id=fake\t\033\177'
protocol_refusal "bad$injection" --charter c --scope s --no-projects
protocol_refusal web --charter "c$injection" --scope s --no-projects
protocol_refusal web --charter c --scope "s$injection" --no-projects
protocol_refusal web --charter c --scope s --host "box$injection" --root /a --home /b --no-projects
protocol_refusal web --charter c --scope s --host box --root "/a$injection" --home /b --no-projects
protocol_refusal web --charter c --scope s --host box --root /a --home "/b$injection" --no-projects
protocol_refusal web --charter c --scope s --host box --root /a --home /b "site=https://example.com/a$injection"
protocol_refusal web --charter c --scope s "site$injection"
out=$(create plan tabs --charter $'c\ttab' --scope $'s\033escape' --no-projects)
assert_contains "$out" "charter=c tab" "tab normalization"
assert_contains "$out" "scope=s escape" "escape normalization"
step=$(printf '%s\n' "$out" | awk 'index($0, "step=1 ") == 1 { print substr($0, 8) }')
(FM_HOME="$FMH" STUB_LOG="$LOG"; export FM_HOME STUB_LOG; cd "$CODE"; eval "$step")
assert_contains "$(cat "$LOG")" $'charter=c\ttab | scope=s\033escape' "printed step changed its arguments"
: > "$LOG"
pass "facts and refusals normalize control characters without changing printed commands"

# --- apply ---
out=$(create apply web --charter "Owns the web app" --scope "web app work" app 2>/dev/null)
assert_contains "$out" "ran step=3" "apply ran every step"
assert_equals "$(printf '%s\n' "$out" | tail -n 1)" "done id=web" "apply final line"
assert_equals "$(cat "$LOG")" "brief web --secondmate app | charter=Owns the web app | scope=web app work
fm-home-seed.sh web - app
fm-spawn.sh web --secondmate" "apply step order"
pass "apply runs brief, seed and spawn in order and prints done"

: > "$LOG"
set +e
out=$(STUB_FAIL=fm-home-seed.sh create apply app2 --charter c --scope s app 2>/dev/null)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "failed seed should exit 1 (got $rc)"
assert_contains "$out" "failed step=2: stub fm-home-seed.sh refused this order" "seed failure line"
assert_not_contains "$out" "done id=" "done printed after failure"
assert_no_grep "fm-spawn.sh" "$LOG" "spawn ran after a failed seed"
assert_absent "$FMH/data/app2/brief.md" "charter left behind after a failed seed"
pass "apply stops at a failed seed and removes the charter it wrote"

set +e
out=$(STUB_FAIL=fm-home-seed.sh STUB_FAIL_REASON=$'refused\torder\r\033\177' create apply noisy --charter c --scope s app 2>/dev/null)
rc=$?
set -e
expect_code 1 "$rc" "seed failure with control characters"
assert_contains "$out" 'failed step=2: refused order   ' "step failure reason normalization"
assert_absent "$FMH/data/noisy/brief.md" "known seed failure kept its charter"

for status in 1 255; do
  : > "$LOG"
  id="unknown$status"
  set +e
  out=$(STUB_UNKNOWN_RC="$status" create apply "$id" --charter c --scope s --host box --root /srv/fm --home "/srv/homes/$id" --no-projects 2>/dev/null)
  rc=$?
  set -e
  expect_code 1 "$rc" "unknown remote seed outcome"
  assert_contains "$out" "failed step=2:" "unknown seed failure line"
  assert_contains "$out" "reconcile with the printed step 2 command, then step 3" "unknown seed recovery advice"
  assert_not_contains "$out" "send the same order again" "invalid recovery advice"
  assert_present "$FMH/data/$id/brief.md" "unknown seed lost its charter"
  assert_grep "- $id " "$FMH/data/secondmates.md" "unknown seed lost its route"
  assert_no_grep "fm-spawn.sh" "$LOG" "spawn ran with unknown seed completion"
  set +e
  out=$(create plan "$id" --charter c --scope s --host box --root /srv/fm --home "/srv/homes/$id" --no-projects)
  rc=$?
  set -e
  expect_code 1 "$rc" "repeated create after unknown seed"
  assert_contains "$out" "already registered" "unknown seed did not preserve identity"
done
pass "apply preserves reconciliation records for both unknown seed failure statuses"

: > "$LOG"
set +e
out=$(STUB_FAIL=fm-spawn.sh create apply app3 --charter c --scope s app 2>/dev/null)
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "failed spawn should exit 1 (got $rc)"
assert_contains "$out" "failed step=3: stub fm-spawn.sh refused this order" "spawn failure line"
assert_present "$FMH/data/app3/brief.md" "a seeded mate's charter was removed after a failed launch"
pass "apply reports a failed launch without undoing the seed"

echo "ALL TESTS PASSED"
