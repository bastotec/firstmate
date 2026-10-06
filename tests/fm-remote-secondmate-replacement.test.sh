#!/usr/bin/env bash
# tests/fm-remote-secondmate-replacement.test.sh - a remote second mate's
# launch and relaunch report success only after proving, by process identity,
# that the new agent replaced the old one, an already-running healthy agent is
# reused rather than doubled, a relaunch whose endpoint is already gone is
# delegated rather than refused as an unidentifiable running agent, and a
# recorded agent still running outside its endpoint blocks the relaunch before
# anything is touched
# (bin/fm-remote-secondmate-control.sh's header owns the contract).
#
# This drives the real host-local control script, the real bin/fm-spawn.sh and
# bin/fm-control.sh against a real stream hub and the real bin/fm-stream-agent.py,
# whose pseudoterminal runs the real Deck host driver over a fake `deck` binary,
# so every verdict here is read from the process table: a pid, its identity,
# and its arguments. A previous agent that survives outside its endpoint is a
# real process whose identity is recorded exactly as a proved launch records it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for tool in jq python3 curl perl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

TMP_ROOT=$(fm_test_tmproot fm-remote-replacement)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
CODE="$TMP_ROOT/code"
SM_HOME="$TMP_ROOT/sm-home"
FIXTURE="$TMP_ROOT/fixture"
USER_HOME="$TMP_ROOT/user-home"
SM_ID=sm1
ROUTE_META="$SM_HOME/state/parent-route/$SM_ID.meta"
IDENTITY="$SM_HOME/state/parent-route/$SM_ID.agent-identity"
HUB_TOKEN="remote-replacement-token-$$"
HUB_PID=
EXTRA_PIDS=()
mkdir -p "$CODE" "$SM_HOME" "$FIXTURE/bin" "$USER_HOME"

stream_agent_pids() {
  ps -eo pid,args 2>/dev/null \
    | awk -v r="$CODE" 'index($0, "fm-stream-agent.py") && index($0, r) && !index($0, "awk") {print $1}'
}

cleanup() {
  local pid
  for pid in ${EXTRA_PIDS[@]+"${EXTRA_PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
  for pid in $(stream_agent_pids); do kill "$pid" 2>/dev/null || true; done
  [ -z "$HUB_PID" ] || kill "$HUB_PID" 2>/dev/null || true
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

# --- the fleet hub: real, loopback, ephemeral port --------------------------
printf 'publish,subscribe,control:%s\n' "$HUB_TOKEN" > "$TMP_ROOT/hub-tokens"
chmod 600 "$TMP_ROOT/hub-tokens"
python3 "$ROOT/bin/fm-stream-hub.py" serve --bind 127.0.0.1 --port 0 \
  --token-file "$TMP_ROOT/hub-tokens" --ready-file "$TMP_ROOT/hub-ready" \
  > "$TMP_ROOT/hub.log" 2>&1 &
HUB_PID=$!
waited=0
while [ ! -s "$TMP_ROOT/hub-ready" ] && [ "$waited" -lt 100 ]; do sleep 0.1; waited=$((waited + 1)); done
[ -s "$TMP_ROOT/hub-ready" ] || fail "hub did not start: $(cat "$TMP_ROOT/hub.log")"
read -r HUB_HOST HUB_PORT < "$TMP_ROOT/hub-ready"
HUB_URL="http://$HUB_HOST:$HUB_PORT"

# The host's own Firstmate copy, kept apart from this checkout because the
# host-local launch runs with that copy as its firstmate home. The Deck host's
# startup diagnostics and watcher are shimmed as tests/fm-backend-stream.test.sh
# shims them; the host driver itself is real.
(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$CODE" && tar -xf -)
cat > "$CODE/bin/fm-session-start.sh" <<'SH'
#!/usr/bin/env bash
"$(dirname "$0")/fm-lock.sh" || exit
cat "$FM_HOME/state/.lock" > "$FM_HOME/state/.session-start-complete"
printf 'fixture startup\n'
SH
cat > "$CODE/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --handling-delivered ] || exit 0
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
while :; do sleep 1; done
SH
chmod +x "$CODE/bin/fm-session-start.sh" "$CODE/bin/fm-watch-arm.sh"
git -C "$CODE" init -q -b main
git -C "$CODE" add .
git -C "$CODE" commit -qm 'host code root'
cp -p "$CODE/bin/fm-control.sh" "$TMP_ROOT/fm-control.real"
# The real control plane, beside its libraries, for a wrapper to delegate to.
cp -p "$CODE/bin/fm-control.sh" "$CODE/bin/fm-control-real.sh"
# The deck launch resolves its executable on the host's PATH; the Deck host
# driver runs one finished turn per prompt through it.
cat > "$FIXTURE/bin/deck" <<'PY'
#!/usr/bin/env python3
import json
print(json.dumps({'type': 'run_started', 'session': 'fixture-session'}), flush=True)
print(json.dumps({'type': 'run_finished', 'output': 'ready', 'turns': 1}), flush=True)
PY
chmod +x "$FIXTURE/bin/deck"

# A seeded second-mate home on this host, running the Deck worker, publishing to
# the hub its own config names with the credential provisioned beside it.
mkdir -p "$SM_HOME/bin" "$SM_HOME/data" "$SM_HOME/state" "$SM_HOME/config" "$SM_HOME/projects"
printf '%s\n' "$SM_ID" > "$SM_HOME/.fm-secondmate-home"
cp "$CODE/AGENTS.md" "$SM_HOME/AGENTS.md"
printf '# Charter\nServe as a test second mate.\n' > "$SM_HOME/data/charter.md"
printf '%s\n' "$HUB_URL" > "$SM_HOME/config/stream-hub"
(umask 077; printf '%s\n' "$HUB_TOKEN" > "$SM_HOME/config/stream-token")
printf 'python\n' > "$SM_HOME/config/stream-impl"
printf 'manual\n' > "$SM_HOME/config/backlog-backend"
git -C "$SM_HOME" init -q -b main
git -C "$SM_HOME" add .
git -C "$SM_HOME" commit -qm 'seeded home'

# control [env assignments...] <verb> [args...]
control() {
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u FM_BACKEND -u FM_STREAM_HUB -u FM_STREAM_TOKEN -u FM_STREAM_MACHINE -u FM_STREAM_AGENT_BIN \
    -u CLAUDECODE -u TMUX \
    HOME="$USER_HOME" PATH="$FIXTURE/bin:$PATH" \
    FM_HOME="$SM_HOME" FM_ROOT_OVERRIDE="$CODE" \
    FM_REMOTE_AGENT_IDENTITY_WAIT=30 FM_REMOTE_AGENT_IDENTITY_POLL=0.2 \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    "$CODE/bin/fm-remote-secondmate-control.sh" "$@"
}
# A refusal is proved by the bound running out, so it runs with a short one.
control_quick() {
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u FM_BACKEND -u FM_STREAM_HUB -u FM_STREAM_TOKEN -u FM_STREAM_MACHINE -u FM_STREAM_AGENT_BIN \
    -u CLAUDECODE -u TMUX \
    HOME="$USER_HOME" PATH="$FIXTURE/bin:$PATH" \
    FM_HOME="$SM_HOME" FM_ROOT_OVERRIDE="$CODE" \
    FM_REMOTE_AGENT_IDENTITY_WAIT=2 FM_REMOTE_AGENT_IDENTITY_POLL=0.2 \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    "$CODE/bin/fm-remote-secondmate-control.sh" "$@"
}

# The endpoint as this host's own adapter reads it.
# shellcheck disable=SC2016 # $1 and $@ expand in the inner shell.
host_backend() {  # <function> [args...]
  env -u FM_STREAM_HUB -u FM_STREAM_TOKEN -u FM_STREAM_MACHINE -u FM_STREAM_AGENT_BIN \
    FM_HOME="$SM_HOME" FM_ROOT="$CODE" bash -c '. "$1/bin/fm-backend.sh"; shift; "$@"' _ "$CODE" "$@"
}
route_target() { sed -n 's/^window=//p' "$ROUTE_META" | tail -1; }
endpoint_agent() { host_backend fm_backend_agent_pids stream "$(route_target)" 2>/dev/null | head -1; }
# A launch returns once the endpoint took the launch line; the agent starts a
# beat later, so a freshly launched endpoint is read until it names one.
launched_agent() {
  local i=0 pid
  while [ "$i" -lt 30 ]; do
    pid=$(endpoint_agent)
    [ -z "$pid" ] || { printf '%s\n' "$pid"; return 0; }
    i=$((i + 1))
    sleep 0.5
  done
  return 1
}
alive() { kill -0 "$1" 2>/dev/null; }
wait_gone() {  # <pid>
  local n=0
  while alive "$1" && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
  ! alive "$1"
}
# Wait until the endpoint reads <state> to this host.
wait_endpoint_state() {  # <state>
  local n=0
  while [ "$(host_backend fm_backend_agent_state stream "$(route_target)" 2>/dev/null)" != "$1" ] && [ "$n" -lt 150 ]; do
    sleep 0.2
    n=$((n + 1))
  done
  [ "$(host_backend fm_backend_agent_state stream "$(route_target)" 2>/dev/null)" = "$1" ] \
    || fail "endpoint $(route_target) did not reach $1"
}
# Stop the agent its endpoint hosts, leaving the endpoint itself standing with
# its shell: the agent-free state a launch treats as a reusable id.
stop_agent() {  # <pid>
  kill -HUP "$1" 2>/dev/null || true
  wait_gone "$1" || fail "agent $1 survived its hang-up"
  wait_endpoint_state dead
}
# A previous agent still running outside its endpoint: a real process, recorded
# by the identity a proved launch would have written for it.
outside_survivor() {  # -> SURVIVOR
  local identity
  bash -c 'exec -a fm-deck-worker sleep 600' &
  SURVIVOR=$!
  EXTRA_PIDS+=("$SURVIVOR")
  # Identify it only once it runs under its own name.
  local n=0
  until ps -o args= -p "$SURVIVOR" 2>/dev/null | grep -q '^fm-deck-worker' || [ "$n" -ge 50 ]; do
    sleep 0.1
    n=$((n + 1))
  done
  # Reduced exactly as the control script reduces an identity to its token.
  identity=$(FM_HOME="$SM_HOME" /bin/bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$SURVIVOR") \
    || fail "could not identify the survivor"
  identity=$(printf '%s' "$identity" | cksum | awk '{ print $1 "-" $2 }')
  printf '%s %s\n' "$SURVIVOR" "$identity" > "$IDENTITY"
}
# Forget the route entirely: close its endpoint and drop its records.
# The hub's open endpoints labelled for this mate, one "<id> <closed_by>" line each.
open_route_endpoints() {
  curl -fsS -m 10 --config <(printf 'header = "Authorization: Bearer %s"\n' "$HUB_TOKEN") \
    "$HUB_URL/v1/tasks" \
    | jq -r --arg l "fm-$SM_ID" '.tasks[] | select(.label == $l and .closed_at == null) | .endpoint_id'
}
reset_route() {
  local pid target kill_out kill_rc=0 n=0
  if [ -f "$ROUTE_META" ]; then
    pid=$(endpoint_agent)
    target=$(route_target)
    kill_out=$(host_backend fm_backend_kill stream "$target" 2>&1) || kill_rc=$?
    [ -z "$pid" ] || wait_gone "$pid" || kill -KILL "$pid" 2>/dev/null || true
    # The hub frees the label only once the endpoint is closed; a launch
    # before that is refused as a duplicate.
    while [ -n "$(open_route_endpoints)" ] && [ "$n" -lt 100 ]; do
      sleep 0.1
      n=$((n + 1))
    done
    [ -z "$(open_route_endpoints)" ] \
      || fail "fm-$SM_ID endpoints still open after closing $target (kill rc=$kill_rc: $kill_out): $(open_route_endpoints | tr '\n' ' ')"
  fi
  rm -f "$ROUTE_META" "$IDENTITY"
}
fake_control() {  # <script body>
  printf '#!/usr/bin/env bash\n%s\n' "$1" > "$CODE/bin/fm-control.sh"
  chmod +x "$CODE/bin/fm-control.sh"
}
real_control() { cp -p "$TMP_ROOT/fm-control.real" "$CODE/bin/fm-control.sh"; }

# --- 1. A first launch proves its agent and records its identity ------------
out=$(umask 002; control launch "$SM_ID" deck - - stream 2>&1) || fail "first launch failed: $out"
# The parent-route root is also the Deck driver's status directory. Exercise
# its exact safe-I/O boundary, not merely mkdir's successful exit status.
route_state=$(dirname "$ROUTE_META")
route_mode=$(python3 -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$route_state")
[ "$route_mode" = 0o700 ] || fail "parent-route creation under umask 002 is unsafe: $route_mode"
printf 'working: directory accepted\n' | python3 "$ROOT/bin/fm-state-io.py" root-append "$route_state" mode-check.status \
  || fail "Deck safe status I/O rejected the created parent-route directory"
[ "$(cat "$route_state/mode-check.status")" = 'working: directory accepted' ] || fail "safe status write was lost"
pass "parent-route creation is private under umask 002 and accepted by Deck safe status I/O"
assert_contains "$out" "backend=stream" "first launch did not print its route"
first=$(endpoint_agent)
{ [ -n "$first" ] && alive "$first"; } || fail "the launch left no live agent process in its endpoint"
ps -o args= -p "$first" | grep -q 'fm-deck-worker' || fail "the endpoint's agent is not the Deck host: $(ps -o args= -p "$first")"
[ -f "$IDENTITY" ] || fail "the proved agent identity was not recorded"
grep -q "^$first " "$IDENTITY" || fail "the recorded identity is not the launched agent's"
pass "a first launch reports success only for a live agent it proved by process identity"

# --- 2. An already-running healthy agent is reused, not doubled -----------
target_before=$(route_target)
agents_before=$(stream_agent_pids | wc -l | tr -d ' ')
out=$(control launch "$SM_ID" deck - - stream 2>&1) || fail "reusing a healthy agent failed: $out"
alive "$first" || fail "reusing a healthy agent stopped it"
[ "$(route_target)" = "$target_before" ] || fail "reusing a healthy agent moved it to another endpoint"
[ "$(endpoint_agent)" = "$first" ] || fail "reusing a healthy agent replaced it"
[ "$(stream_agent_pids | wc -l | tr -d ' ')" = "$agents_before" ] || fail "reusing a healthy agent launched a second endpoint"
[ "$(control state "$SM_ID")" = alive ] || fail "a working remote Deck mate did not read alive to the control plane"
pass "a launch over a healthy running agent reuses it instead of starting a twin"

# --- 3. Retire the first agent ----------------------------------------------
# Hang it up so the next launch below starts from an agent-free endpoint with
# nothing left running.
stop_agent "$first"

# --- 4. A previous agent that outlives its endpoint blocks the relaunch ----
out=$(control launch "$SM_ID" deck - - stream 2>&1) || fail "a clean relaunch failed: $out"
current=$(endpoint_agent)
alive "$current" || fail "the clean relaunch left no live agent"
grep -q "^$current " "$IDENTITY" || fail "the clean relaunch did not record its agent"
stop_agent "$current"
outside_survivor
target_before=$(route_target)
agents_before=$(stream_agent_pids | wc -l | tr -d ' ')
if out=$(control_quick launch "$SM_ID" deck - - stream 2>&1); then
  fail "a relaunch started a second agent beside a previous one still running: $out"
fi
assert_contains "$out" "(pid $SURVIVOR) is still running without its endpoint" \
  "the refusal did not name the surviving previous agent"
alive "$SURVIVOR" || fail "the refusal stopped the surviving agent itself"
[ "$(route_target)" = "$target_before" ] || fail "the refused launch rewrote the endpoint"
[ "$(stream_agent_pids | wc -l | tr -d ' ')" -le "$agents_before" ] || fail "the refused launch created a new endpoint"
kill "$SURVIVOR"
wait_gone "$SURVIVOR" || fail "the survivor did not stop"
pass "a previous agent still running outside its endpoint blocks the relaunch instead of gaining a twin"

# --- 5. The relaunch verb proves the old agent is gone ----------------------
out=$(control launch "$SM_ID" deck - - stream 2>&1) || fail "relaunch setup failed: $out"
current=$(launched_agent)
alive "$current" || fail "relaunch setup left no live agent"
# A control plane that reports "relaunched" while the old agent keeps running.
# shellcheck disable=SC2016 # the fake control plane expands $1 itself.
fake_control 'echo "relaunched $1 harness=deck from=deck model=default effort=default backend=stream"'
if out=$(control_quick relaunch "$SM_ID" deck default default 2>&1); then
  fail "a relaunch that left the old agent running reported success: $out"
fi
assert_contains "$out" "the previous agent process (pid $current) is still running" \
  "the failure did not name the old agent still running"
assert_not_contains "$out" "relaunched $SM_ID" "a failed proof still reported the relaunch"
# The real control plane genuinely replaces it.
real_control
out=$(control relaunch "$SM_ID" deck default default 2>&1) || fail "a proved relaunch failed: $out"
assert_contains "$out" "relaunched $SM_ID" "a proved relaunch did not report success"
replacement=$(endpoint_agent)
{ [ -n "$replacement" ] && [ "$replacement" != "$current" ] && alive "$replacement"; } \
  || fail "the relaunch did not leave a new live agent"
alive "$current" && fail "the old agent is still running after a proved relaunch"
grep -q "^$replacement " "$IDENTITY" || fail "the relaunch did not record the replacement's identity"
pass "the relaunch verb reports success only after the old agent is gone and a new one is running"

# --- 6. A relaunch whose endpoint is gone is not refused as unidentifiable ---
current=$replacement
# Closing the endpoint itself takes its agent with it, so the endpoint reads
# gone with no agent left to identify.
host_backend fm_backend_kill stream "$(route_target)" >/dev/null 2>&1 || fail "could not close the endpoint"
wait_gone "$current" || fail "closing the endpoint left its agent running"
# shellcheck disable=SC2016 # the fake control plane expands $1 itself.
fake_control 'echo "relaunched $1 harness=deck from=deck model=default effort=default backend=stream"'
if out=$(control_quick relaunch "$SM_ID" deck default default 2>&1); then
  fail "a relaunch into a gone endpoint reported success without a provable agent: $out"
fi
assert_not_contains "$out" "cannot be identified by process" \
  "the relaunch refused an agent-free endpoint as an unidentifiable running agent"
assert_contains "$out" "not reporting it as relaunched" "the failure did not refuse the success report"
real_control
pass "a relaunch whose endpoint is gone is delegated, not refused as a running agent"

# --- 7. Setup: a fresh healthy agent for the survivor case below ----------
out=$(control launch "$SM_ID" deck - - stream 2>&1) || fail "survivor setup launch failed: $out"
current=$(launched_agent)
alive "$current" || fail "survivor setup launch left no live agent: $out
$(curl -sS -m 10 --config <(printf 'header = "Authorization: Bearer %s"\n' "$HUB_TOKEN") "$HUB_URL/v1/tasks" \
  | jq -c --arg l "fm-$SM_ID" '.tasks[] | select(.label == $l)' 2>&1)
$(curl -sS -m 10 --config <(printf 'header = "Authorization: Bearer %s"\n' "$HUB_TOKEN") \
  "$HUB_URL/v1/tasks/$(route_target | sed 's/^[^:]*://')/screen" 2>&1 | tail -c 3000)
$(ps -eo pid,ppid,pgid,sid,stat,args 2>/dev/null | awk '/fm-stream-agent|deck|fm-deck/ && !/awk/')"

# --- 8. A previous agent outside a agent-free endpoint blocks the relaunch ---
# The endpoint reads positively agent-free while the recorded agent keeps
# running outside its process view - the survivor shape a relaunch refuses.
stop_agent "$current"
outside_survivor
cp -p "$ROUTE_META" "$TMP_ROOT/meta.before-survivor"
agents_before=$(stream_agent_pids | wc -l | tr -d ' ')
rm -f "$TMP_ROOT/relaunch-delegated"
fake_control ": > '$TMP_ROOT/relaunch-delegated'; echo \"relaunched \$1 harness=deck from=deck model=default effort=default backend=stream\""
if out=$(control_quick relaunch "$SM_ID" deck default default 2>&1); then
  fail "a relaunch started a replacement beside a previous agent still running outside its endpoint: $out"
fi
assert_contains "$out" "still running without its endpoint" \
  "the refusal did not name the surviving previous agent"
assert_contains "$out" "refusing to start a second agent beside it" \
  "the relaunch was not refused before its replacement could start"
[ ! -e "$TMP_ROOT/relaunch-delegated" ] || fail "the relaunch delegated instead of refusing the surviving agent"
[ -z "$(endpoint_agent)" ] || fail "the relaunch started an agent in the endpoint beside the survivor"
alive "$SURVIVOR" || fail "the refusal stopped the surviving agent itself"
cmp -s "$TMP_ROOT/meta.before-survivor" "$ROUTE_META" || fail "the refused relaunch rewrote the endpoint"
[ "$(stream_agent_pids | wc -l | tr -d ' ')" = "$agents_before" ] || fail "the refused relaunch created a new endpoint"
real_control
kill "$SURVIVOR"
wait_gone "$SURVIVOR" || fail "the survivor did not stop"
pass "a recorded agent still running outside its endpoint blocks the relaunch before anything is touched"

reset_route
out=$(control launch "$SM_ID" deck example/route - stream 2>&1) || fail "Deck remote launch failed: $out"
current=$(endpoint_agent)
{ [ -n "$current" ] && alive "$current"; } || fail "Deck remote launch left no live host process"
assert_contains "$out" "harness=deck" "Deck remote launch did not report its runtime"
assert_contains "$out" "model=example/route" "Deck remote launch did not report its model"
ps -o args= -p "$current" | grep -q 'fm-deck-worker' || fail "Deck remote launch did not run its persistent host"
fake_control "printf '%s\n' \"\$*\" > '$TMP_ROOT/deck-relaunch-args'; exec '$CODE/bin/fm-control-real.sh' \"\$@\""
out=$(control relaunch "$SM_ID" deck default default 2>&1) || fail "Deck remote relaunch failed: $out"
replacement=$(endpoint_agent)
{ [ -n "$replacement" ] && [ "$replacement" != "$current" ] && alive "$replacement"; } \
  || fail "Deck remote relaunch left no replacement host"
[ "$(cat "$TMP_ROOT/deck-relaunch-args")" = "$SM_ID relaunch --harness deck --model default --effort default" ] \
  || fail "Deck remote relaunch did not preserve its profile: $(cat "$TMP_ROOT/deck-relaunch-args")"
grep -q "^$replacement " "$IDENTITY" || fail "Deck remote relaunch did not record the replacement identity"
real_control
pass "Deck remote launch and relaunch preserve the stream host runtime"

# --- 9. Launch and relaunch reconcile a pre-existing unsafe mode -----------
# A home that launched before private creation left state/parent-route as 0775,
# which Deck's safe status I/O refuses; each lifecycle verb that starts an
# agent repairs the root rather than demanding a hand chmod - the launch that
# owns it, and the relaunch whose delegated control plane would otherwise
# recreate the root with a plain mkdir -p. Refuse loudly on anything not
# provably owned: a symlink, a non-owned directory, or a non-directory.
dir_mode() { python3 -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$1"; }
reset_route
chmod 0775 "$route_state"
if printf 'x' | python3 "$ROOT/bin/fm-state-io.py" root-append "$route_state" mode-check.status >/dev/null 2>&1; then
  fail "fixture: Deck safe status I/O accepted a 0775 parent-route root"
fi
out=$(control launch "$SM_ID" deck example/route - stream 2>&1) || fail "launch over a 0775 parent-route failed: $out"
[ "$(dir_mode "$route_state")" = 0o700 ] || fail "launch did not reconcile 0775 to private: $(dir_mode "$route_state")"
printf 'working: reconciled\n' | python3 "$ROOT/bin/fm-state-io.py" root-append "$route_state" mode-check.status \
  || fail "Deck safe status I/O still rejected the reconciled parent-route directory"
pass "a launch reconciles a pre-existing 0775 parent-route root to a mode Deck accepts"
chmod 0775 "$route_state"
out=$(control relaunch "$SM_ID" deck default default 2>&1) || fail "relaunch over a 0775 parent-route failed: $out"
assert_contains "$out" "relaunched $SM_ID" "the reconciling relaunch did not report success"
[ "$(dir_mode "$route_state")" = 0o700 ] || fail "relaunch did not reconcile 0775 to private: $(dir_mode "$route_state")"
printf 'working: relaunch reconciled\n' | python3 "$ROOT/bin/fm-state-io.py" root-append "$route_state" mode-check.status \
  || fail "Deck safe status I/O still rejected the relaunch-reconciled parent-route directory"
pass "a relaunch reconciles a pre-existing 0775 parent-route root to a mode Deck accepts"

# --- 10. The reconcile refuses anything it cannot provably own --------------
# Drive the REAL control script with FM_HOME pointed at a fixture home whose
# parent-route root is the artifact under test, so each refusal comes from the
# production reconcile rather than a copy of it.
refusal_launch() {  # <fixture-home>
  env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u FM_BACKEND -u CLAUDECODE -u TMUX \
    HOME="$USER_HOME" PATH="$FIXTURE/bin:$PATH" \
    FM_HOME="$1" FM_ROOT_OVERRIDE="$CODE" \
    FM_REMOTE_AGENT_IDENTITY_WAIT=3 FM_REMOTE_AGENT_IDENTITY_POLL=0.2 \
    FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
    "$CODE/bin/fm-remote-secondmate-control.sh" launch "$SM_ID" deck example/route - stream 2>&1
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
reset_route
rm -rf "$SM_HOME/data/.parent-route"
ln -s "$relocated_data" "$SM_HOME/data/.parent-route"
out=$(control launch "$SM_ID" deck example/route - stream 2>&1) \
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
reset_route
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
out=$(control launch "$SM_ID" deck example/route - stream 2>&1) \
  || fail "a GNU-shaped stat on PATH blocked the launch: $out"
assert_contains "$out" "harness=deck" "the shadowed-stat launch did not report its runtime"
[ "$(dir_mode "$route_state")" = 0o700 ] \
  || fail "the owner read did not survive a GNU-shaped stat: $(dir_mode "$route_state")"
printf 'working: shadowed stat\n' | python3 "$ROOT/bin/fm-state-io.py" root-append "$route_state" mode-check.status \
  || fail "Deck safe status I/O rejected the root reconciled under a shadowed stat"
rm -f "$FIXTURE/bin/stat"
pass "a GNU-shaped stat on PATH cannot poison the parent-route owner read"

echo "ALL TESTS PASSED"
