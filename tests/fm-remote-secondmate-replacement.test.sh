#!/usr/bin/env bash
# tests/fm-remote-secondmate-replacement.test.sh - a remote second mate's
# launch and relaunch report success only after proving, by process identity,
# that the new agent replaced the old one on the configured Claude permission
# posture, an already-running agent without that posture is reported as a
# posture mismatch instead of being returned as healthy, a relaunch whose
# endpoint is already gone is delegated rather than refused as an
# unidentifiable running agent, and a running agent whose posture cannot be
# resolved is refused rather than returned as healthy
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
out=$(control launch "$SM_ID" claude - - herdr 2>&1) || fail "first launch failed: $out"
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
