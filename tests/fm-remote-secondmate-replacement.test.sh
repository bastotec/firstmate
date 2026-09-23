#!/usr/bin/env bash
# tests/fm-remote-secondmate-replacement.test.sh - a remote second mate's
# launch and relaunch report success only after proving, by process identity,
# that the new agent replaced the old one on the configured Claude permission
# posture, an already-running agent without that posture is reported as a
# posture mismatch instead of being returned as healthy, a relaunch whose
# endpoint is already gone is delegated rather than refused as an
# unidentifiable running agent, a running agent whose posture cannot be
# resolved is refused rather than returned as healthy, and a recorded agent
# still running outside its endpoint blocks the relaunch before anything is
# touched
# (bin/fm-remote-secondmate-control.sh's header owns the contract).
#
# This drives the real host-local control script and the real bin/fm-spawn.sh
# against tests/remote-herdr-fixture.sh, whose submitted launch lines start real
# stand-in agent processes, so every verdict here is read from the process
# table: a pid, its identity, and its arguments.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/remote-herdr-fixture.sh
. "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-remote-replacement)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
CODE="$TMP_ROOT/code"
SM_HOME="$TMP_ROOT/sm-home"
FIXTURE="$TMP_ROOT/fixture"
HERDR_STATE="$TMP_ROOT/herdr.state"
HERDR_LOG="$TMP_ROOT/herdr.log"
KNOB="$TMP_ROOT/herdr-send-fail"
USER_HOME="$TMP_ROOT/user-home"
SM_ID=sm1
ROUTE_META="$SM_HOME/state/parent-route/$SM_ID.meta"
IDENTITY="$SM_HOME/state/parent-route/$SM_ID.agent-identity"
EXTRA_PIDS=()
mkdir -p "$CODE" "$SM_HOME" "$FIXTURE" "$USER_HOME"

cleanup() {
  local pid
  for pid in ${EXTRA_PIDS[@]+"${EXTRA_PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

# The host's own Firstmate copy, kept apart from this checkout because the
# host-local launch runs with that copy as its firstmate home.
(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$CODE" && tar -xf -)
git -C "$CODE" init -q -b main
git -C "$CODE" add .
git -C "$CODE" commit -qm 'host code root'
cp -p "$CODE/bin/fm-control.sh" "$TMP_ROOT/fm-control.real"
install_remote_herdr_fixture "$FIXTURE" "$HERDR_STATE" "$HERDR_LOG" "$KNOB" "$TMP_ROOT/herdr.sock"

# A seeded second-mate home on this host, running Claude in auto posture.
mkdir -p "$SM_HOME/bin" "$SM_HOME/data" "$SM_HOME/state" "$SM_HOME/config" "$SM_HOME/projects"
printf '%s\n' "$SM_ID" > "$SM_HOME/.fm-secondmate-home"
cp "$CODE/AGENTS.md" "$SM_HOME/AGENTS.md"
printf '# Charter\nServe as a test second mate.\n' > "$SM_HOME/data/charter.md"
printf 'auto\n' > "$SM_HOME/config/claude-permission-mode"
git -C "$SM_HOME" init -q -b main
git -C "$SM_HOME" add .
git -C "$SM_HOME" commit -qm 'seeded home'

control() {  # <verb> [args...]
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u FM_BACKEND -u HERDR_SESSION -u CLAUDECODE -u TMUX \
    HOME="$USER_HOME" CLAUDE_CONFIG_DIR='' PATH="$FIXTURE/bin:$PATH" \
    FM_HOME="$SM_HOME" FM_ROOT_OVERRIDE="$CODE" \
    FM_REMOTE_AGENT_IDENTITY_WAIT=3 FM_REMOTE_AGENT_IDENTITY_POLL=0.2 \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    "$CODE/bin/fm-remote-secondmate-control.sh" "$@"
}

route_pane() { sed -n 's/^herdr_pane_id=//p' "$ROUTE_META"; }
pane_agent() { jq -r --arg p "$1" '.agents[$p] // empty' "$HERDR_STATE"; }
alive() { kill -0 "$1" 2>/dev/null; }
# Make the recorded endpoint agent-less the way Herdr reports a pane whose
# agent registration is gone, leaving the pane itself standing.
deregister() {
  jq --arg p "$1" 'del(.typed[$p]) | del(.working[$p])' "$HERDR_STATE" > "$HERDR_STATE.tmp"
  mv -f "$HERDR_STATE.tmp" "$HERDR_STATE"
}
# A claude process the fixture did not start, standing in for a session some
# other launcher resumed without the permission flag.
bare_stand_in() {  # <pane>
  local pid
  ( exec -a claude sh -c 'trap "exit 0" HUP TERM; while [ -e "$1" ]; do sleep 1 & wait $!; done' \
      claude "$HERDR_STATE" --resume 00000000-test ) </dev/null >/dev/null 2>&1 &
  pid=$!
  EXTRA_PIDS+=("$pid")
  jq --arg p "$1" --argjson pid "$pid" '.agents[$p] = $pid' "$HERDR_STATE" > "$HERDR_STATE.tmp"
  mv -f "$HERDR_STATE.tmp" "$HERDR_STATE"
  printf '%s\n' "$pid"
}

# --- 1. A first launch proves its agent and records its identity ------------
out=$(umask 002; control launch "$SM_ID" claude - - herdr 2>&1) || fail "first launch failed: $out"
# The parent-route root is also the Deck driver's status directory. Exercise
# its exact safe-I/O boundary, not merely mkdir's successful exit status.
route_state=$(dirname "$ROUTE_META")
route_mode=$(python3 -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$route_state")
[ "$route_mode" = 0o700 ] || fail "parent-route creation under umask 002 is unsafe: $route_mode"
printf 'working: directory accepted\n' | python3 "$ROOT/bin/fm-state-io.py" root-append "$route_state" mode-check.status \
  || fail "Deck safe status I/O rejected the created parent-route directory"
[ "$(cat "$route_state/mode-check.status")" = 'working: directory accepted' ] || fail "safe status write was lost"
pass "parent-route creation is private under umask 002 and accepted by Deck safe status I/O"
assert_contains "$out" "backend=herdr" "first launch did not print its route"
pane=$(route_pane)
first=$(pane_agent "$pane")
{ [ -n "$first" ] && alive "$first"; } || fail "the launch left no live agent process in its pane"
assert_contains "$out" "posture=ok $first" "route did not report the agent's verified posture"
[ -f "$IDENTITY" ] || fail "the proved agent identity was not recorded"
grep -q "^$first " "$IDENTITY" || fail "the recorded identity is not the launched agent's"
pass "a first launch reports success only for a live agent carrying the configured permission flag"

# --- 2. An already-running agent without the posture is a mismatch ----------
out=$(control launch "$SM_ID" claude - - herdr 2>&1) || fail "reusing a healthy agent failed: $out"
alive "$first" || fail "reusing a healthy agent stopped it"
kill -HUP "$first"
bare=$(bare_stand_in "$pane")
out=$(control route "$SM_ID" 2>&1) || fail "route failed: $out"
assert_contains "$out" "posture=mismatch $bare" "route reported a flagless agent as healthy"
cp "$ROUTE_META" "$TMP_ROOT/meta.before-mismatch"
tabs_before=$(jq '.tabs | length' "$HERDR_STATE")
if out=$(control launch "$SM_ID" claude - - herdr 2>&1); then
  fail "launch returned a running agent without the permission flag as healthy: $out"
fi
assert_contains "$out" "posture mismatch" "the refusal did not name the posture mismatch"
assert_contains "$out" "pid $bare" "the refusal did not name the mismatched agent"
alive "$bare" || fail "reporting a posture mismatch stopped the running agent"
cmp -s "$TMP_ROOT/meta.before-mismatch" "$ROUTE_META" || fail "reporting a posture mismatch rewrote the endpoint"
[ "$(jq '.tabs | length' "$HERDR_STATE")" = "$tabs_before" ] || fail "reporting a posture mismatch launched an agent"
pass "a running agent without the configured posture is reported as a mismatch, neither stopped nor replaced"

# --- 3. A replacement that lacks the posture is a failed relaunch -----------
deregister "$pane"
: > "$KNOB.bare"
if out=$(control launch "$SM_ID" claude - - herdr 2>&1); then
  fail "a relaunch whose new agent lacks the permission flag reported success: $out"
fi
rm -f "$KNOB.bare"
assert_contains "$out" "lacks the configured Claude permission flag '--permission-mode auto'" \
  "the failure did not name the missing permission flag"
assert_contains "$out" "not reporting it as relaunched" "the failure did not refuse the success report"
assert_not_contains "$out" "backend=herdr" "a failed proof still printed a route"
# The endpoint's removal HUPs the old agent asynchronously, so wait for its
# death within the same bound section 6 uses rather than racing it.
n=0
while alive "$bare" && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
alive "$bare" && fail "the old agent survived its endpoint's removal in the fixture"
pass "a relaunch whose new agent lacks the configured permission flag is reported as a failure"

# --- 4. A previous agent that outlives its endpoint blocks the relaunch ----
pane=$(route_pane)
deregister "$pane"
out=$(control launch "$SM_ID" claude - - herdr 2>&1) || fail "a clean relaunch failed: $out"
pane=$(route_pane)
survivor=$(pane_agent "$pane")
alive "$survivor" || fail "the clean relaunch left no live agent"
grep -q "^$survivor " "$IDENTITY" || fail "the clean relaunch did not record its agent"
deregister "$pane"
: > "$KNOB.survive"
tabs_before=$(jq '.tabs | length' "$HERDR_STATE")
if out=$(control launch "$SM_ID" claude - - herdr 2>&1); then
  fail "a relaunch started a second agent beside a previous one still running: $out"
fi
rm -f "$KNOB.survive"
EXTRA_PIDS+=("$survivor")
assert_contains "$out" "(pid $survivor) is still running without its endpoint" \
  "the refusal did not name the surviving previous agent"
alive "$survivor" || fail "the refusal stopped the surviving agent itself"
[ "$(jq '.tabs | length' "$HERDR_STATE")" -lt "$tabs_before" ] || fail "the refused launch created a new endpoint"
kill -HUP "$survivor"
pass "a previous agent still running outside its endpoint blocks the relaunch instead of gaining a twin"

# --- 5. The relaunch verb proves the old agent is gone ----------------------
out=$(control launch "$SM_ID" claude - - herdr 2>&1) || fail "relaunch setup failed: $out"
pane=$(route_pane)
current=$(pane_agent "$pane")
alive "$current" || fail "relaunch setup left no live agent"
# A control plane that reports "relaunched" while the old agent keeps running.
cat > "$CODE/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
echo "relaunched $1 harness=claude from=claude model=default effort=default backend=herdr"
SH
chmod +x "$CODE/bin/fm-control.sh"
if out=$(control relaunch "$SM_ID" claude default default 2>&1); then
  fail "a relaunch that left the old agent running reported success: $out"
fi
assert_contains "$out" "the previous agent process (pid $current) is still running" \
  "the failure did not name the old agent still running"
assert_not_contains "$out" "relaunched $SM_ID" "a failed proof still reported the relaunch"
# A control plane that genuinely replaces it, in the same pane, on the posture.
cat > "$CODE/bin/fm-control.sh" <<SH
#!/usr/bin/env bash
pid=\$(jq -r --arg p '$pane' '.agents[\$p] // empty' '$HERDR_STATE')
kill -HUP "\$pid"
while kill -0 "\$pid" 2>/dev/null; do sleep 0.1; done
herdr pane send-text '$pane' 'claude --permission-mode auto --settings {}' --session fm-remote
herdr pane send-keys '$pane' enter --session fm-remote
echo "relaunched \$1 harness=claude from=claude model=default effort=default backend=herdr"
SH
out=$(control relaunch "$SM_ID" claude default default 2>&1) || fail "a proved relaunch failed: $out"
assert_contains "$out" "relaunched $SM_ID" "a proved relaunch did not report success"
replacement=$(pane_agent "$pane")
{ [ "$replacement" != "$current" ] && alive "$replacement"; } || fail "the relaunch did not leave a new live agent"
alive "$current" && fail "the old agent is still running after a proved relaunch"
grep -q "^$replacement " "$IDENTITY" || fail "the relaunch did not record the replacement's identity"
cp -p "$TMP_ROOT/fm-control.real" "$CODE/bin/fm-control.sh"
pass "the relaunch verb reports success only after the old agent is gone and a new one carries the posture"

# --- 6. A relaunch whose endpoint is gone is not refused as unidentifiable ---
out=$(control launch "$SM_ID" claude - - herdr 2>&1) || fail "gone-endpoint setup failed: $out"
pane=$(route_pane)
current=$(pane_agent "$pane")
alive "$current" || fail "gone-endpoint setup left no live agent"
# A Herdr host drops the pane itself when its shell goes, and a gone pane's
# process read fails on the real server, so the endpoint reads missing with no
# agent left to identify.
"$FIXTURE/bin/herdr" pane close "$pane" --session fm-remote
n=0
while alive "$current" && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
alive "$current" && fail "closing the endpoint left its agent running"
cat > "$CODE/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
echo "relaunched $1 harness=claude from=claude model=default effort=default backend=herdr"
SH
chmod +x "$CODE/bin/fm-control.sh"
if out=$(control relaunch "$SM_ID" claude default default 2>&1); then
  fail "a relaunch into a gone endpoint reported success without a provable agent: $out"
fi
assert_not_contains "$out" "cannot be identified by process" \
  "the relaunch refused an agent-free endpoint as an unidentifiable running agent"
assert_contains "$out" "cannot be read" "the failure did not name the unreadable endpoint"
assert_contains "$out" "not reporting it as relaunched" "the failure did not refuse the success report"
cp -p "$TMP_ROOT/fm-control.real" "$CODE/bin/fm-control.sh"
pass "a relaunch whose endpoint is gone is delegated, not refused as a running agent"

# --- 7. A running agent whose posture cannot be resolved is not healthy ------
out=$(control launch "$SM_ID" claude - - herdr 2>&1) || fail "posture-resolution setup failed: $out"
pane=$(route_pane)
healthy=$(pane_agent "$pane")
alive "$healthy" || fail "posture-resolution setup left no live agent"
cp -p "$ROUTE_META" "$TMP_ROOT/meta.before-resolution"
tabs_before=$(jq '.tabs | length' "$HERDR_STATE")
printf 'nonsense\n' > "$SM_HOME/config/claude-permission-mode"
if out=$(control launch "$SM_ID" claude - - herdr 2>&1); then
  fail "launch returned a running agent as healthy while its posture could not be resolved: $out"
fi
assert_contains "$out" "cannot be resolved" "the refusal did not name the unresolvable posture"
assert_contains "$out" "claude-permission-mode" "the refusal did not surface the config problem"
alive "$healthy" || fail "refusing the unresolvable posture stopped the running agent"
cmp -s "$TMP_ROOT/meta.before-resolution" "$ROUTE_META" || fail "refusing the unresolvable posture rewrote the endpoint"
[ "$(jq '.tabs | length' "$HERDR_STATE")" = "$tabs_before" ] || fail "refusing the unresolvable posture launched an agent"
pass "a running agent is not returned as healthy when its posture cannot be resolved"

# --- 8. A previous agent outside a agent-free endpoint blocks the relaunch ---
printf 'auto\n' > "$SM_HOME/config/claude-permission-mode"
pane=$(route_pane)
survivor=$(pane_agent "$pane")
alive "$survivor" || fail "survivor setup left no live agent"
cp -p "$ROUTE_META" "$TMP_ROOT/meta.before-survivor"
tabs_before=$(jq '.tabs | length' "$HERDR_STATE")
# The pane reads positively agent-free while the recorded agent keeps running
# outside its process view - the survivor shape a launch refuses.
deregister "$pane"
cat > "$CODE/bin/fm-control.sh" <<SH
#!/usr/bin/env bash
: > '$TMP_ROOT/relaunch-delegated'
herdr pane send-text '$pane' 'claude --permission-mode auto --settings {}' --session fm-remote
herdr pane send-keys '$pane' enter --session fm-remote
echo "relaunched \$1 harness=claude from=claude model=default effort=default backend=herdr"
SH
chmod +x "$CODE/bin/fm-control.sh"
if out=$(control relaunch "$SM_ID" claude default default 2>&1); then
  fail "a relaunch started a replacement beside a previous agent still running outside its endpoint: $out"
fi
EXTRA_PIDS+=("$survivor")
assert_contains "$out" "still running without its endpoint" \
  "the refusal did not name the surviving previous agent"
assert_contains "$out" "refusing to start a second agent beside it" \
  "the relaunch was not refused before its replacement could start"
[ ! -e "$TMP_ROOT/relaunch-delegated" ] || fail "the relaunch delegated instead of refusing the surviving agent"
[ "$(pane_agent "$pane")" = "$survivor" ] || fail "the relaunch swapped the surviving agent's registration"
alive "$survivor" || fail "the refusal stopped the surviving agent itself"
cmp -s "$TMP_ROOT/meta.before-survivor" "$ROUTE_META" || fail "the refused relaunch rewrote the endpoint"
[ "$(jq '.tabs | length' "$HERDR_STATE")" = "$tabs_before" ] || fail "the refused relaunch created a new endpoint"
cp -p "$TMP_ROOT/fm-control.real" "$CODE/bin/fm-control.sh"
pass "a recorded agent still running outside its endpoint blocks the relaunch before anything is touched"

kill -HUP "$survivor" 2>/dev/null || true
reset_remote_herdr_fixture "$HERDR_STATE"
rm -f "$ROUTE_META" "$IDENTITY"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FIXTURE/bin/deck"
chmod +x "$FIXTURE/bin/deck"
out=$(control launch "$SM_ID" deck example/route - herdr 2>&1) || fail "Deck remote launch failed: $out"
pane=$(route_pane)
current=$(pane_agent "$pane")
{ [ -n "$current" ] && alive "$current"; } || fail "Deck remote launch left no live host process"
assert_contains "$out" "harness=deck" "Deck remote launch did not report its runtime"
assert_grep 'fm-deck-worker' "$HERDR_LOG" "Deck remote launch did not submit its persistent host to Herdr"
cat > "$CODE/bin/fm-control.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > '$TMP_ROOT/deck-relaunch-args'
pid=\$(jq -r --arg p '$pane' '.agents[\$p] // empty' '$HERDR_STATE')
kill -HUP "\$pid"
while kill -0 "\$pid" 2>/dev/null; do sleep 0.1; done
herdr pane send-text '$pane' 'FM_SUPERVISION_MODEL=autoarm exec -a fm-deck-worker bash host' --session fm-remote
herdr pane send-keys '$pane' enter --session fm-remote
echo "relaunched \$1 harness=deck from=deck model=default effort=default backend=herdr"
SH
chmod +x "$CODE/bin/fm-control.sh"
out=$(control relaunch "$SM_ID" deck default default 2>&1) || fail "Deck remote relaunch failed: $out"
replacement=$(pane_agent "$pane")
{ [ "$replacement" != "$current" ] && alive "$replacement"; } || fail "Deck remote relaunch left no replacement host"
[ "$(cat "$TMP_ROOT/deck-relaunch-args")" = "$SM_ID relaunch --harness deck --model default --effort default" ] \
  || fail "Deck remote relaunch did not preserve its profile: $(cat "$TMP_ROOT/deck-relaunch-args")"
grep -q "^$replacement " "$IDENTITY" || fail "Deck remote relaunch did not record the replacement identity"
cp -p "$TMP_ROOT/fm-control.real" "$CODE/bin/fm-control.sh"
pass "Deck remote launch and relaunch preserve the Herdr host runtime"

# --- 9. A launch reconciles a pre-existing unsafe parent-route mode ---------
# A home that launched before private creation left state/parent-route as 0775,
# which Deck's safe status I/O refuses; the launch that owns the root repairs
# it rather than demanding a hand chmod. Refuse loudly on anything not
# provably owned: a symlink, a non-owned directory, or a non-directory.
dir_mode() { python3 -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$1"; }
kill -HUP "$replacement" 2>/dev/null || true
reset_remote_herdr_fixture "$HERDR_STATE"
rm -f "$ROUTE_META" "$IDENTITY"
chmod 0775 "$route_state"
if printf 'x' | python3 "$ROOT/bin/fm-state-io.py" root-append "$route_state" mode-check.status >/dev/null 2>&1; then
  fail "fixture: Deck safe status I/O accepted a 0775 parent-route root"
fi
out=$(control launch "$SM_ID" deck example/route - herdr 2>&1) || fail "launch over a 0775 parent-route failed: $out"
[ "$(dir_mode "$route_state")" = 0o700 ] || fail "launch did not reconcile 0775 to private: $(dir_mode "$route_state")"
printf 'working: reconciled\n' | python3 "$ROOT/bin/fm-state-io.py" root-append "$route_state" mode-check.status \
  || fail "Deck safe status I/O still rejected the reconciled parent-route directory"
pass "a launch reconciles a pre-existing 0775 parent-route root to a mode Deck accepts"

# --- 10. The reconcile refuses anything it cannot provably own --------------
# Drive the REAL control script with FM_HOME pointed at a fixture home whose
# parent-route root is the artifact under test, so each refusal comes from the
# production reconcile rather than a copy of it.
refusal_launch() {  # <fixture-home>
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u FM_BACKEND -u HERDR_SESSION -u CLAUDECODE -u TMUX \
    HOME="$USER_HOME" CLAUDE_CONFIG_DIR='' PATH="$FIXTURE/bin:$PATH" \
    FM_HOME="$1" FM_ROOT_OVERRIDE="$CODE" \
    FM_REMOTE_AGENT_IDENTITY_WAIT=3 FM_REMOTE_AGENT_IDENTITY_POLL=0.2 \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    "$CODE/bin/fm-remote-secondmate-control.sh" launch "$SM_ID" deck example/route - herdr 2>&1
}

make_refusal_home() {  # <home-path> - a seeded home skeleton for a refusal fixture
  local home=$1
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$SM_ID" > "$home/.fm-secondmate-home"
  cp "$CODE/AGENTS.md" "$home/AGENTS.md"
  printf '# Charter\nServe as a test second mate.\n' > "$home/data/charter.md"
}

link_home="$TMP_ROOT/refuse-home.symlink"
make_refusal_home "$link_home"
# A distinct 0775 target, so this case proves the refusal alone left it alone:
# the real route root was already reconciled by section 9's successful launch.
link_target="$TMP_ROOT/symlink-target"
mkdir -p "$link_target"
chmod 0775 "$link_target"
ln -s "$link_target" "$link_home/state/parent-route"
out=$(refusal_launch "$link_home") && fail "symlink: launch succeeded where it must refuse"
assert_contains "$out" "not a directory" "symlink refusal did not name the path"
assert_contains "$out" "$link_home/state/parent-route" "symlink refusal did not name the exact path"
[ "$(dir_mode "$link_target")" = 0o775 ] || fail "symlink refusal chmod-ed the link target"

nondir_home="$TMP_ROOT/refuse-home.nondir"
make_refusal_home "$nondir_home"
printf 'plain file\n' > "$nondir_home/state/parent-route"
out=$(refusal_launch "$nondir_home") && fail "non-directory: launch succeeded where it must refuse"
assert_contains "$out" "not a directory" "non-directory refusal did not name the path"

foreign_uid=0
[ "$(id -u)" -ne 0 ] || foreign_uid=1
foreign_home="$TMP_ROOT/refuse-home.foreign"
make_refusal_home "$foreign_home"
mkdir -p "$foreign_home/state/parent-route"
chmod 0775 "$foreign_home/state/parent-route"
if chown "$foreign_uid" "$foreign_home/state/parent-route" 2>/dev/null; then
  out=$(refusal_launch "$foreign_home") && fail "foreign-owned: launch succeeded where it must refuse"
  assert_contains "$out" "owned by uid $foreign_uid" "foreign-owner refusal did not name the owner"
  [ "$(dir_mode "$foreign_home/state/parent-route")" = 0o775 ] \
    || fail "foreign-owner refusal chmod-ed a directory it does not own"
  chown "$(id -u)" "$foreign_home/state/parent-route"
else
  printf 'not run - foreign-owner refusal requires chown privilege\n'
fi
pass "the reconcile refuses a symlink, a foreign-owned root, and a non-directory, naming each"

# --- 11. A relocated parent-route data root still launches ------------------
# The data root is not the directory Deck's safe status I/O validates, so an
# operator who relocates it (a symlink to storage elsewhere) keeps launching:
# only the state root is reconciled, and a launch tightens nothing it does not
# own. The relocated root is group-writable on purpose - the old data-root
# reconcile refused and chmod-ed exactly this shape.
relocated_data="$TMP_ROOT/relocated-route-data"
mkdir -p "$relocated_data"
chmod 0775 "$relocated_data"
printf 'relocated\n' > "$relocated_data/relocation-marker"
previous=$(pane_agent "$(route_pane)")
if [ -n "$previous" ]; then kill -HUP "$previous" 2>/dev/null || true; fi
reset_remote_herdr_fixture "$HERDR_STATE"
rm -f "$ROUTE_META" "$IDENTITY"
rm -rf "$SM_HOME/data/.parent-route"
ln -s "$relocated_data" "$SM_HOME/data/.parent-route"
out=$(control launch "$SM_ID" deck example/route - herdr 2>&1) \
  || fail "a launch over a relocated parent-route data root failed: $out"
assert_contains "$out" "harness=deck" "the relocated-data launch did not report its runtime"
[ -L "$SM_HOME/data/.parent-route" ] || fail "the launch replaced the relocated data root"
[ "$(dir_mode "$relocated_data")" = 0o775 ] \
  || fail "the launch tightened a data root it does not own: $(dir_mode "$relocated_data")"
[ "$(cat "$SM_HOME/data/.parent-route/relocation-marker" 2>/dev/null)" = relocated ] \
  || fail "the launch did not keep the relocated data root wired to the home"
[ "$(dir_mode "$route_state")" = 0o700 ] || fail "the state root lost its reconciled private mode"
printf 'working: relocated route\n' | python3 "$ROOT/bin/fm-state-io.py" root-append "$route_state" mode-check.status \
  || fail "Deck safe status I/O rejected the state root beside a relocated data root"
pass "a symlinked or relocated parent-route data root still launches"

# --- 12. A GNU-shaped stat on PATH cannot poison the owner read -------------
# The shape this repository recorded in production: GNU `stat -f` is FILESYSTEM
# stat, so it prints a dump on stdout and still exits 0. A collapsed
# `stat -f '%u' || stat -c '%u'` fallback never reaches its second form, the
# owner variable holds the dump, and the launch dies naming a bogus foreign
# owner - for every harness, on every launch. Drive the real control script with
# that stat shadowing PATH and assert the reconcile still repairs the root.
previous=$(pane_agent "$(route_pane)")
if [ -n "$previous" ]; then kill -HUP "$previous" 2>/dev/null || true; fi
reset_remote_herdr_fixture "$HERDR_STATE"
rm -f "$ROUTE_META" "$IDENTITY"
chmod 0775 "$route_state"
cat > "$FIXTURE/bin/stat" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = -f ]; then
  printf '  File: "%s"\n    ID: 0 Namelen: 255 Type: ext2/ext3\n' "${3:-}"
  exit 0
fi
for real in /usr/bin/stat /bin/stat; do
  [ -x "$real" ] && exec "$real" "$@"
done
exit 1
FAKE
chmod +x "$FIXTURE/bin/stat"
out=$(control launch "$SM_ID" deck example/route - herdr 2>&1) \
  || fail "a GNU-shaped stat on PATH blocked the launch: $out"
assert_contains "$out" "harness=deck" "the shadowed-stat launch did not report its runtime"
[ "$(dir_mode "$route_state")" = 0o700 ] \
  || fail "the owner read did not survive a GNU-shaped stat: $(dir_mode "$route_state")"
printf 'working: shadowed stat\n' | python3 "$ROOT/bin/fm-state-io.py" root-append "$route_state" mode-check.status \
  || fail "Deck safe status I/O rejected the root reconciled under a shadowed stat"
rm -f "$FIXTURE/bin/stat"
pass "a GNU-shaped stat on PATH cannot poison the parent-route owner read"
