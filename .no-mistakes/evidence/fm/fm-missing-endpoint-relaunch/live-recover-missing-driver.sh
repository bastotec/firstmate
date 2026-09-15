#!/usr/bin/env bash
# Live driver for `bin/fm-control.sh <task> recover-missing` against a REAL
# tmux server on a private socket. Nothing about tmux is stubbed: every
# session, window and pane below is real, the local copy is a real git
# worktree, and the stand-in agent is a real long-running process the product's
# own classifier attributes as an agent.
set -u

ROOT=/Users/bastotecnologia/.no-mistakes/worktrees/5a1fd3284f12/01M2HFXB6C7GYHE20VGXWHN7KH

RC=0
fail() { printf 'not ok - %s\n' "$1"; RC=1; }
pass() { printf 'ok - %s\n' "$1"; }

REAL_TMUX=/opt/homebrew/bin/tmux
[ -x "$REAL_TMUX" ] || { echo "skip: tmux not found"; exit 0; }
SLEEP_BIN=$(command -v sleep)
SOCKET="fm-recover-live-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-recover-live.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)

cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB/shim" "$LAB/home/state" "$LAB/home/data" "$LAB/user-home"

cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"

# The stand-in agent. argv0 is the signal bin/backends/tmux.sh attributes a
# foreground process by, so this is a real process the product reads as a live
# claude worker owning the endpoint.
cat > "$LAB/shim/claude" <<SH
#!/usr/bin/env bash
exec -a claude "$SLEEP_BIN" 900
SH
chmod +x "$LAB/shim/claude"

# Ask the product's own classifier what it sees, so every precondition this
# driver asserts is the one fm-control.sh itself reads.
cat > "$LAB/shim/agent-state" <<SH
#!/usr/bin/env bash
set -u
PATH="$LAB/shim:\$PATH"
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux
fm_backend_tmux_agent_state "\$1"
echo
SH
chmod +x "$LAB/shim/agent-state"

export PATH="$LAB/shim:$PATH"

SES=fmses

seed_task() {  # <id> [worktree]
  local id=$1 wt=${2:-$LAB/$1-wt} proj="$LAB/$1-proj"
  mkdir -p "$proj"
  git -C "$proj" init -q
  git -C "$proj" config user.email fixture@example.com
  git -C "$proj" config user.name Fixture
  printf 'seed\n' > "$proj/README.md"
  git -C "$proj" add -A && git -C "$proj" commit -qm seed
  git -C "$proj" worktree add --quiet -b "task-$id" "$wt"
  mkdir -p "$LAB/home/data/$id"
  cat > "$LAB/home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise missing-endpoint recovery for $id.

## Firstmate spec
Recreate the terminal without touching the local copy.
EOF
  cat > "$LAB/home/state/$id.meta" <<EOF
window=$SES:fm-$id
endpoint_task_id=$id
worktree=$wt
project=$proj
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-$id-live
model=default
effort=default
EOF
}

control() {
  env PATH="$PATH" FM_HOME="$LAB/home" HOME="$LAB/user-home" CLAUDE_CONFIG_DIR='' \
      FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 FM_CONTROL_POLL=0.2 \
      FM_CONTROL_LAUNCH_WAIT=30 \
      "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

start_agent_in() {  # <id>
  local id=$1 st=
  "$REAL_TMUX" -L "$SOCKET" new-window -t "$SES" -n "fm-$id" -c "$LAB" || return 1
  "$REAL_TMUX" -L "$SOCKET" send-keys -t "$SES:fm-$id" "exec claude" Enter
  for _ in $(seq 1 100); do
    st=$("$LAB/shim/agent-state" "$SES:fm-$id" | head -1)
    [ "$st" = alive ] && return 0
    sleep 0.2
  done
  echo "the stand-in agent never came up (agent_state=$st)"
  return 1
}

# An operator reaches for this verb after noticing a terminal is gone, not in
# the same millisecond they closed it. Let the endpoint settle to the verdict
# the operator would actually see before driving the verb.
wait_missing() {  # <id>
  local st= i
  for i in $(seq 1 50); do
    st=$("$LAB/shim/agent-state" "$SES:fm-$1" | head -1)
    [ "$st" = missing ] && return 0
    sleep 0.2
  done
  echo "endpoint never settled to missing (reads '$st')"
  return 1
}

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SES" -n scratch -c "$LAB" \
  || { echo "could not start private tmux server"; exit 1; }

########################################################################
echo "=== S1: a live endpoint refuses, and nothing changes ==================="
seed_task live1
start_agent_in live1 || exit 1
echo "precondition: the product classifies $SES:fm-live1 as '$("$LAB/shim/agent-state" "$SES:fm-live1" | head -1)'"
meta_before=$(cat "$LAB/home/state/live1.meta")
brief_before=$(cat "$LAB/home/data/live1/brief.md")
out=$(control live1 recover-missing --note "should never apply"); rc=$?
printf '%s\n' "$out"
if [ "$rc" != 0 ] && case "$out" in *"reads 'alive'"*) true ;; *) false ;; esac; then
  pass "S1 a live endpoint refuses"
else
  fail "S1 a live endpoint was not refused (rc=$rc)"
fi
[ "$(cat "$LAB/home/state/live1.meta")" = "$meta_before" ] \
  && pass "S1 the durable record is byte-identical after the refusal" \
  || fail "S1 the durable record changed on a refused recovery"
[ "$(cat "$LAB/home/data/live1/brief.md")" = "$brief_before" ] \
  && pass "S1 the instructions are byte-identical after the refusal" \
  || fail "S1 the instructions changed on a refused recovery"

########################################################################
echo
echo "=== S2: the task's window is gone from a session that is still alive ==="
"$REAL_TMUX" -L "$SOCKET" kill-window -t "$SES:fm-live1"
wait_missing live1
echo "--- windows in $SES before recovery:"
"$REAL_TMUX" -L "$SOCKET" list-windows -t "$SES" -F '#{window_name}'
echo "--- the product's own verdict on the recorded endpoint:"
"$LAB/shim/agent-state" "$SES:fm-live1"
brief_before=$(cat "$LAB/home/data/live1/brief.md")
out=$(control live1 recover-missing --note "the terminal was closed out from under it"); rc=$?
printf '%s\n' "$out"
echo "--- windows in $SES after recovery:"
"$REAL_TMUX" -L "$SOCKET" list-windows -t "$SES" -F '#{window_name}'
"$REAL_TMUX" -L "$SOCKET" list-windows -t "$SES" -F '#{window_name}' | grep -qx "fm-live1" \
  && pass "S2 the recorded window fm-live1 is back in the real session" \
  || fail "S2 the recorded window was not recreated"
echo "--- the recreated pane's working directory (must be the recorded local copy):"
"$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SES:fm-live1" '#{pane_current_path}'
[ "$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SES:fm-live1" '#{pane_current_path}')" = "$LAB/live1-wt" ] \
  && pass "S2 the recreated terminal is bound to the recorded local copy" \
  || fail "S2 the recreated terminal is not in the recorded local copy"
[ "$(grep '^window=' "$LAB/home/state/live1.meta")" = "window=$SES:fm-live1" ] \
  && pass "S2 the endpoint handle is unchanged" || fail "S2 the endpoint handle changed"
[ "$(grep '^worktree=' "$LAB/home/state/live1.meta")" = "worktree=$LAB/live1-wt" ] \
  && pass "S2 the local copy was reused, never reallocated" || fail "S2 the local copy was reallocated"
grep -q "the terminal was closed out from under it" "$LAB/home/data/live1/brief.md" \
  && pass "S2 the progress note landed in the instructions the replacement reads" \
  || fail "S2 the progress note is missing"
case "$(cat "$LAB/home/data/live1/brief.md")" in
  "$brief_before"*) pass "S2 the original instructions were appended to, never rewritten" ;;
  *) fail "S2 the original instructions were rewritten" ;;
esac
echo "--- transaction journal:"
cat "$LAB/home/state/live1.control-relaunch" 2>/dev/null
if [ "$rc" = 0 ]; then
  pass "S2 the replacement worker launched and the verb reported success"
else
  fail "S2 the launch handoff FAILED after the terminal was recreated (rc=$rc)"
fi

########################################################################
echo
echo "=== S3: the WHOLE recorded session is gone ============================="
"$REAL_TMUX" -L "$SOCKET" kill-session -t "$SES"
wait_missing live1
echo "--- sessions on the server now:"
"$REAL_TMUX" -L "$SOCKET" list-sessions 2>&1
echo "--- the product's own verdict on the recorded endpoint:"
"$LAB/shim/agent-state" "$SES:fm-live1"
out=$(control live1 recover-missing --note "the whole session was gone"); rc=$?
printf '%s\n' "$out"
echo "--- sessions after recovery:"
"$REAL_TMUX" -L "$SOCKET" list-sessions -F '#{session_name}' 2>&1
"$REAL_TMUX" -L "$SOCKET" has-session -t "=$SES" 2>/dev/null \
  && pass "S3 the session came back under its EXACT recorded name ($SES)" \
  || fail "S3 the session was not recreated under its recorded name"
echo "--- windows in the recreated session:"
"$REAL_TMUX" -L "$SOCKET" list-windows -t "$SES" -F '#{window_name}' 2>&1
"$REAL_TMUX" -L "$SOCKET" list-windows -t "$SES" -F '#{window_name}' 2>/dev/null | grep -qx "fm-live1" \
  && pass "S3 the task window is back inside the recreated session" \
  || fail "S3 the task window is not in the recreated session"
if [ "$rc" = 0 ]; then
  pass "S3 the replacement worker launched and the verb reported success"
else
  fail "S3 the launch handoff FAILED after the session and window were recreated (rc=$rc)"
fi

########################################################################
echo
echo "=== S4: a session that is still alive is left untouched ================"
before_id=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SES" '#{session_id}')
"$REAL_TMUX" -L "$SOCKET" kill-window -t "$SES:fm-live1"
wait_missing live1
control live1 recover-missing --note "window only" >/dev/null 2>&1
after_id=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$SES" '#{session_id}')
echo "session_id before=$before_id after=$after_id"
[ "$before_id" = "$after_id" ] \
  && pass "S4 a surviving session is the SAME session, never recreated" \
  || fail "S4 the surviving session was replaced"

########################################################################
echo
echo "=== S5: a dirty local copy refuses rather than being reset ============="
"$REAL_TMUX" -L "$SOCKET" kill-window -t "$SES:fm-live1" 2>/dev/null
wait_missing live1
printf 'uncommitted work the captain must not lose\n' > "$LAB/live1-wt/README.md"
meta_before=$(cat "$LAB/home/state/live1.meta")
brief_before=$(cat "$LAB/home/data/live1/brief.md")
echo "--- git status in the local copy:"
git -C "$LAB/live1-wt" status --porcelain
out=$(control live1 recover-missing --note "should never apply"); rc=$?
printf '%s\n' "$out"
if [ "$rc" != 0 ] && case "$out" in *"uncommitted changes"*) true ;; *) false ;; esac; then
  pass "S5 a dirty local copy refuses"
else
  fail "S5 a dirty local copy was not refused (rc=$rc)"
fi
grep -q 'uncommitted work the captain must not lose' "$LAB/live1-wt/README.md" \
  && pass "S5 the uncommitted work is still there, untouched" \
  || fail "S5 the refused recovery touched the local copy"
[ "$(cat "$LAB/home/state/live1.meta")" = "$meta_before" ] \
  && pass "S5 the durable record is byte-identical after the refusal" \
  || fail "S5 the durable record changed"
[ "$(cat "$LAB/home/data/live1/brief.md")" = "$brief_before" ] \
  && pass "S5 the instructions are byte-identical after the refusal" \
  || fail "S5 the instructions changed"
"$REAL_TMUX" -L "$SOCKET" list-windows -t "$SES" -F '#{window_name}' | grep -qx "fm-live1" \
  && fail "S5 the refused recovery created a terminal anyway" \
  || pass "S5 no terminal was created by the refused recovery"

########################################################################
echo
echo "=== S6: only the previous spawn's own leftovers still recovers ========="
git -C "$LAB/live1-wt" checkout -- README.md
mkdir -p "$LAB/live1-wt/.claude"
printf '{}\n' > "$LAB/live1-wt/.claude/settings.local.json"
echo "--- git status in the local copy:"
git -C "$LAB/live1-wt" status --porcelain
out=$(control live1 recover-missing --note "spawn leftovers must not block a rescue"); rc=$?
printf '%s\n' "$out"
case "$out" in
  *"uncommitted changes"*) fail "S6 the spawn's own leftovers blocked the rescue" ;;
  *) pass "S6 a worktree holding only the spawn's own leftovers passes the dirty gate" ;;
esac
"$REAL_TMUX" -L "$SOCKET" list-windows -t "$SES" -F '#{window_name}' | grep -qx "fm-live1" \
  && pass "S6 the terminal was recreated despite the leftovers" \
  || fail "S6 no terminal after the leftovers case"

########################################################################
echo
echo "=== S7: real untracked source work still refuses ======================="
"$REAL_TMUX" -L "$SOCKET" kill-window -t "$SES:fm-live1" 2>/dev/null
wait_missing live1
printf 'new module nobody committed yet\n' > "$LAB/live1-wt/feature.py"
echo "--- git status in the local copy:"
git -C "$LAB/live1-wt" status --porcelain
out=$(control live1 recover-missing --note "should never apply"); rc=$?
printf '%s\n' "$out"
if [ "$rc" != 0 ] && case "$out" in *"uncommitted changes"*) true ;; *) false ;; esac; then
  pass "S7 untracked work that is not a spawn leftover still refuses"
else
  fail "S7 untracked source work was not refused (rc=$rc)"
fi
[ -f "$LAB/live1-wt/feature.py" ] && pass "S7 the untracked work survives the refusal" \
  || fail "S7 the untracked work was destroyed"
rm -f "$LAB/live1-wt/feature.py"

########################################################################
echo
echo "=== S8: a pool slot claimed by another task refuses ===================="
POOL="$LAB/pool"
mkdir -p "$POOL/1"
printf '{}\n' > "$POOL/treehouse-state.json"
seed_task pool1 "$POOL/1/checkout"
printf 'task=someone-else\nhome=%s\n' "$LAB/other-home" > "$POOL/1/.fm-slot-owner"
echo "--- the slot's ownership claim:"
cat "$POOL/1/.fm-slot-owner"
meta_before=$(cat "$LAB/home/state/pool1.meta")
out=$(control pool1 recover-missing --note "should never apply"); rc=$?
printf '%s\n' "$out"
if [ "$rc" != 0 ] && case "$out" in *"claimed by task someone-else"*) true ;; *) false ;; esac; then
  pass "S8 a pool slot owned by another task refuses rather than tangling ownership"
else
  fail "S8 a conflicting pool slot was not refused (rc=$rc)"
fi
grep -qx 'task=someone-else' "$POOL/1/.fm-slot-owner" \
  && pass "S8 the other task's claim is untouched" || fail "S8 the claim was rewritten"
[ "$(cat "$LAB/home/state/pool1.meta")" = "$meta_before" ] \
  && pass "S8 the durable record is byte-identical after the refusal" \
  || fail "S8 the durable record changed"

########################################################################
echo
echo "=== S8b: an unreadable slot claim refuses =============================="
printf 'garbage with no task line\n' > "$POOL/1/.fm-slot-owner"
out=$(control pool1 recover-missing --note "should never apply"); rc=$?
printf '%s\n' "$out"
if [ "$rc" != 0 ] && case "$out" in *"unreadable owner claim"*) true ;; *) false ;; esac; then
  pass "S8b an unreadable pool-slot claim refuses"
else
  fail "S8b an unreadable claim was not refused (rc=$rc)"
fi

########################################################################
echo
echo "=== S8c: the task's OWN slot recovers, claim untouched ================="
printf 'task=pool1\nhome=%s\n' "$LAB/home" > "$POOL/1/.fm-slot-owner"
claim_before=$(cat "$POOL/1/.fm-slot-owner")
out=$(control pool1 recover-missing --note "recovering onto my own slot"); rc=$?
printf '%s\n' "$out"
case "$out" in
  *"refusing to recover"*) fail "S8c the task's own slot was refused" ;;
  *) pass "S8c the task's own pool slot is not treated as a conflict" ;;
esac
"$REAL_TMUX" -L "$SOCKET" list-windows -t "$SES" -F '#{window_name}' | grep -qx "fm-pool1" \
  && pass "S8c the terminal was recreated on the task's own slot" \
  || fail "S8c no terminal was created on the task's own slot"
[ "$(cat "$POOL/1/.fm-slot-owner")" = "$claim_before" ] \
  && pass "S8c the task's own claim is byte-identical (nothing reallocated)" \
  || fail "S8c the claim was rewritten"

########################################################################
echo
echo "=== S9: an absent local copy refuses rather than reallocating one ======"
seed_task gone1
rm -rf "$LAB/gone1-wt"
out=$(control gone1 recover-missing --note "should never apply"); rc=$?
printf '%s\n' "$out"
if [ "$rc" != 0 ] && case "$out" in *"is absent"*) true ;; *) false ;; esac; then
  pass "S9 an absent local copy refuses"
else
  fail "S9 an absent local copy was not refused (rc=$rc)"
fi
[ -d "$LAB/gone1-wt" ] && fail "S9 a replacement worktree was created" \
  || pass "S9 nothing was reallocated"

########################################################################
echo
echo "=== S10: runtime-switch flags belong to relaunch ======================="
for flag in --harness --model --effort; do
  out=$(control live1 recover-missing "$flag" something --note x); rc=$?
  printf '%s -> %s\n' "$flag" "$out"
  if [ "$rc" != 0 ] && case "$out" in *"apply to 'relaunch' only"*) true ;; *) false ;; esac; then
    pass "S10 $flag is refused for recover-missing"
  else
    fail "S10 $flag was not refused (rc=$rc)"
  fi
done

########################################################################
echo
echo "=== S11: how often does the full rescue actually complete? ============="
echo "(missing window -> recover-missing -> replacement worker confirmed alive)"
ok_n=0; bad_n=0
for i in $(seq 1 8); do
  "$REAL_TMUX" -L "$SOCKET" kill-window -t "$SES:fm-live1" 2>/dev/null
  wait_missing live1 || { printf 'attempt %d: fixture could not restore the missing precondition\n' "$i"; continue; }
  out=$(control live1 recover-missing --note "rescue attempt $i" 2>&1); rc=$?
  if [ "$rc" = 0 ]; then
    ok_n=$((ok_n+1)); printf 'attempt %d: RECOVERED\n' "$i"
  else
    bad_n=$((bad_n+1))
    printf 'attempt %d: FAILED -> %s\n' "$i" "$(printf '%s' "$out" | grep '^error:' | head -1)"
  fi
done
printf 'full rescue completed %d/8, failed %d/8\n' "$ok_n" "$bad_n"
[ "$bad_n" = 0 ] \
  && pass "S11 the rescue the verb exists for completes every time" \
  || fail "S11 the rescue the verb exists for fails $bad_n out of 8 times on this machine"

########################################################################
echo
echo "=== S11b: the same, for the WHOLE-SESSION-GONE shape =================="
echo "(the shape firstmate-account-slot-routing is in: recorded session absent)"
ok_n=0; bad_n=0
for i in $(seq 1 8); do
  "$REAL_TMUX" -L "$SOCKET" kill-session -t "$SES" 2>/dev/null
  wait_missing live1 || { printf 'attempt %d: fixture could not restore the missing precondition\n' "$i"; continue; }
  out=$(control live1 recover-missing --note "session rescue attempt $i" 2>&1); rc=$?
  if [ "$rc" = 0 ]; then
    ok_n=$((ok_n+1)); printf 'attempt %d: RECOVERED\n' "$i"
  else
    bad_n=$((bad_n+1))
    printf 'attempt %d: FAILED -> %s\n' "$i" "$(printf '%s' "$out" | grep '^error:' | head -1)"
  fi
done
printf 'whole-session rescue completed %d/8, failed %d/8\n' "$ok_n" "$bad_n"
[ "$bad_n" = 0 ] \
  && pass "S11b the whole-session rescue completes every time" \
  || fail "S11b the whole-session rescue fails $bad_n out of 8 times on this machine"

########################################################################
echo
echo "=== S12: what the operator can do after a failed handoff =============="
"$REAL_TMUX" -L "$SOCKET" kill-window -t "$SES:fm-live1" 2>/dev/null
wait_missing live1
out=$(control live1 recover-missing --note "first attempt" 2>&1); rc=$?
if [ "$rc" = 0 ]; then
  echo "(this attempt happened to win the race; forcing the failed-handoff shape is not possible here)"
else
  printf '%s\n' "$out" | grep '^error:' | tail -1
  echo "--- the endpoint now reads:"
  "$LAB/shim/agent-state" "$SES:fm-live1"
  out2=$(control live1 recover-missing --note "retry the same verb" 2>&1); rc2=$?
  printf 'retry recover-missing -> rc=%s: %s\n' "$rc2" "$(printf '%s' "$out2" | grep '^error:' | head -1)"
  [ "$rc2" != 0 ] \
    && pass "S12 the same verb is NOT retryable after a failed handoff (documented: use relaunch)" \
    || fail "S12 expected the retry to refuse"
  out3=$(control live1 relaunch --note "recovering after the failed handoff" 2>&1); rc3=$?
  printf 'relaunch -> rc=%s\n%s\n' "$rc3" "$out3"
  [ "$rc3" = 0 ] \
    && pass "S12 the escape hatch the error names ('relaunch') does work" \
    || fail "S12 the escape hatch the error names does NOT work - the task is stranded"
fi

echo
echo "RESULT rc=$RC"
exit "$RC"
