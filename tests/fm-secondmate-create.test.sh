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
  echo "error: stub $stub refused this order" >&2
  exit 1
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
