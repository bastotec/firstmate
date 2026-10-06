#!/usr/bin/env bash
# tests/fm-session-lock-ancestry.test.sh - session-lock harness identity
# (bin/fm-session-lock-lib.sh).
#
# Two layers. The unit cases drive the library's own functions behind a
# deterministic fake ps, so both platforms' reporting semantics are covered from
# either host: macOS reports argv[0] in `ps -o comm=`, while procps on Linux
# reports the kernel exec name and ignores argv[0] entirely. The end-to-end cases
# run the REAL bin/fm-lock.sh acquisition, then the same ownership check
# bin/fm-deck-worker.sh runs before every turn completes, inside real process
# trees whose shapes differ only in how the per-session process is named and what
# its parent is. Those trees are orphaned before the session acquires, so the
# ancestry walk terminates inside the fixture and can never escape into the
# session running this suite.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-ancestry)
fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-session-lock-lib.sh"

FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/fm-deck-worker"
NAMED_DECK="$FAKEBIN/fm-deck-worker"
ln -s /bin/bash "$FAKEBIN/fm-deck-chat"
NAMED_CHAT="$FAKEBIN/fm-deck-chat"
ln -s /bin/bash "$FAKEBIN/pi"
NAMED_PI="$FAKEBIN/pi"

# --- unit layer: identity behind a deterministic process table ---------------

# Run one library expression with <fakebin> shadowing ps. kill is stubbed so
# liveness questions are decided by the process table alone.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    kill() { return 0; }
    $expr
  " "$LIB"
}

test_argv0_named_host_is_identified_on_both_platforms() {
  local dir fakebin shape got
  dir="$TMP_ROOT/argv0-named"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_HOST_SHAPE:-linux}" in
  700:comm=:linux) printf '%s\n' 'bash' ;;
  700:args=:linux) printf '%s\n' 'fm-deck-chat /repo/bin/fm-deck-chat.sh' ;;
  700:comm=:macos) printf '%s\n' 'fm-deck-chat' ;;
  700:args=:macos) printf '%s\n' 'fm-deck-chat /repo/bin/fm-deck-chat.sh' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-lock.sh' ;;
  *:ppid=:*) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '700\n' > "$dir/state/.lock"

  for shape in linux macos; do
    got=$(FM_TEST_HOST_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
      || fail "$shape: the deck chat host was not found in the ancestry at all"
    [ "$got" = 700 ] || fail "$shape: ancestry resolved '$got', expected the deck chat host pid 700"
    FM_TEST_HOST_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      || fail "$shape: a live deck chat host was not recognized as a harness"
    FM_TEST_HOST_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
      || fail "$shape: the session holding the lock did not recognize itself as the owner"
  done
  pass "session-lock: a deck chat host is identified from argv[0] whether ps reports it or the exec name"
}

# A harness that is pid 1 of its own PID namespace - a container or a sandbox -
# used to be invisible: the walk
# stopped as soon as the NEXT pid was 1, so the one process that identifies the
# session was never examined and the session could not recognize its own lock.
test_harness_at_namespace_pid1_is_examined() {
  local dir fakebin got
  dir="$TMP_ROOT/namespace-pid1"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  1:comm=) printf '%s\n' "${FM_TEST_PID1_COMM:-fm-deck-chat}" ;;
  1:args=) printf '%s\n' "${FM_TEST_PID1_COMM:-fm-deck-chat}" ;;
  1:ppid=) printf '%s\n' 0 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/fm-watch.sh' ;;
  *:ppid=) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '1\n' > "$dir/state/.lock"

  # Non-vacuity: with a host-shaped pid 1 the same table must find nothing, so
  # this case cannot pass by the walk matching everything it reaches.
  if FM_TEST_PID1_COMM=systemd lib_eval "$fakebin" 'fm_harness_ancestry_pid' >/dev/null 2>&1; then
    fail "a host-shaped pid 1 was read as a harness process"
  fi

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "the harness at namespace pid 1 was not found in the ancestry at all"
  [ "$got" = 1 ] || fail "ancestry resolved '$got', expected the namespace harness pid 1"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the session holding the lock at namespace pid 1 did not recognize itself as the owner"
  pass "session-lock: a harness that is pid 1 of its own namespace is examined, not skipped"
}

test_ordinary_paths_are_never_harness_processes() {
  local dir fakebin shape
  dir="$TMP_ROOT/ordinary-paths"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_PATH_SHAPE:-hookdir}" in
  810:comm=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh' ;;
  810:args=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh --quiet' ;;
  810:comm=:prefix) printf '%s\n' '/opt/fm-deck-chat-tools/bin/runner' ;;
  810:args=:prefix) printf '%s\n' '/opt/fm-deck-chat-tools/bin/runner --once' ;;
  810:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-watch-arm.sh' ;;
  *:ppid=:*) printf '%s\n' 810 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '810\n' > "$dir/state/.lock"

  # Identity may be read from an executable path, but only from whole path
  # components: anything merely living under ~/.claude, and any component that
  # merely starts with a harness name, must stay outside the harness identity.
  for shape in hookdir prefix; do
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
      fail "$shape: an ordinary script path was treated as a harness process"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 810'; then
      fail "$shape: an ordinary script path passed the harness-liveness predicate"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
      fail "$shape: an ordinary script path claimed the home's session lock"
    fi
  done
  pass "session-lock: ordinary script paths under a harness directory are not harness processes"
}

test_harness_beyond_a_gap_never_owns_the_lock() {
  local dir fakebin got
  dir="$TMP_ROOT/gap"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  900:comm=) printf '%s\n' fm-deck-worker ;;
  900:args=) printf '%s\n' 'fm-deck-worker' ;;
  900:ppid=) printf '%s\n' 910 ;;
  910:comm=) printf '%s\n' bash ;;
  910:args=) printf '%s\n' 'bash tests/run.sh' ;;
  910:ppid=) printf '%s\n' 920 ;;
  920:comm=) printf '%s\n' fm-deck-worker ;;
  920:args=) printf '%s\n' 'fm-deck-worker' ;;
  920:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 900 ;;
esac
SH
  chmod +x "$fakebin/ps"

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "the innermost harness was not resolved"
  [ "$got" = 900 ] || fail "ancestry crossed a non-harness gap, resolved '$got' instead of 900"
  printf '920\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "an unrelated harness beyond a non-harness gap was accepted as this session's lock owner"
  fi
  printf '900\n' > "$dir/state/.lock"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the innermost harness did not recognize its own lock"
  pass "session-lock: ownership stops at the innermost harness and never crosses a non-harness gap"
}

test_competing_host_session_is_seen_as_live() {
  local dir fakebin
  dir="$TMP_ROOT/competing"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  600:comm=) printf '%s\n' bash ;;
  600:args=) printf '%s\n' 'fm-deck-chat /repo/bin/fm-deck-chat.sh' ;;
  600:ppid=) printf '%s\n' 1 ;;
  650:comm=) printf '%s\n' fm-deck-worker ;;
  650:args=) printf '%s\n' fm-deck-worker ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 650 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # pid 600 is a different live session that holds the lock; this process
  # descends from 650 instead. Treating 600 as dead would let this session
  # reclaim a live competitor's home.
  printf '600\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a lock held outside this ancestry was claimed as this session's own"
  fi
  lib_eval "$fakebin" 'fm_harness_pid_alive 600' \
    || fail "a live competing deck chat host was classified as a dead lock owner"
  pass "session-lock: a live deck chat host holding the lock is not mistaken for a stale owner"
}

# Only the deck hosts (the persistent fm-deck-worker driver and the
# fm-deck-chat primary host) may own a home session lock. Removed harness
# names - Pi included - never do.
test_removed_primaries_never_own_the_lock() {
  local dir fakebin name
  dir="$TMP_ROOT/removed-primaries"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  500:comm=) printf '%s\n' "$FM_TEST_COMM" ;;
  500:args=) printf '%s\n' "$FM_TEST_COMM" ;;
  500:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 500 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '500\n' > "$dir/state/.lock"
  for name in pi pi-signed deck claude codex opencode grok kimi omp cursor-agent /Users/u/.local/share/cursor-agent/versions/2026.01.01-abc/cursor-agent /Users/u/.local/share/claude/versions/2.1.220; do
    if FM_TEST_COMM="$name" lib_eval "$fakebin" 'fm_harness_ancestry_pid' >/dev/null; then
      fail "$name was resolved as a primary harness"
    fi
    if FM_TEST_COMM="$name" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
      fail "$name claimed the home's session lock"
    fi
  done
  for name in fm-deck-worker fm-deck-chat; do
    FM_TEST_COMM="$name" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
      || fail "$name did not recognize its own session lock"
  done
  pass "session-lock: only fm-deck-worker and fm-deck-chat may own a home session lock"
}

# --- end-to-end layer: real lock acquisition in real process trees ----------

install_lock_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-lock.sh" "$ROOT/bin/fm-session-lock-lib.sh" \
    "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/"
  chmod +x "$dir/bin/fm-lock.sh"
}

# A primary home whose session process acquires the session lock through the
# real bin/fm-lock.sh, exactly as session start does, and then runs the same
# ownership check bin/fm-deck-worker.sh runs before each turn completes.
make_primary_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_lock_scripts "$dir"
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FIXTURE_ORPHAN_HERE:-0}" = 1 ]; then
  i=0
  while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
    sleep 0.05
    i=$((i + 1))
  done
fi
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
"$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/lock.out" 2>&1
lock_rc=$?
bash -c '. "$1"; fm_session_lock_owned_by_self "$2"' _ \
  "$FM_HOME/bin/fm-session-lock-lib.sh" "$FM_HOME/state"
owned_rc=$?
printf '%s %s\n' "$lock_rc" "$owned_rc" > "$FM_HOME/state/session.rc"
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
"$FM_SESSION_BIN" "$FM_HOME/session.sh"
exit 0
SH
  chmod +x "$dir/session.sh" "$dir/daemon.sh"
}

# Start the fixture tree detached from this suite's own process tree: the
# launcher exits immediately, so the tree is reparented to init and the ancestry
# walk terminates inside the fixture. Returns once the session has recorded its
# exit codes.
run_fixture_tree() {  # <dir> <session-bin> [<daemon-bin>]
  local dir=$1 session_bin=$2 daemon_bin=${3:-} i
  if [ -n "$daemon_bin" ]; then
    FM_HOME="$dir" FM_SESSION_BIN="$session_bin" FM_FIXTURE_ORPHAN_HERE=0 \
      bash -c '"$0" "$1" &' "$daemon_bin" "$dir/daemon.sh"
  else
    FM_HOME="$dir" FM_FIXTURE_ORPHAN_HERE=1 \
      bash -c '"$0" "$1" &' "$session_bin" "$dir/session.sh"
  fi
  i=0
  while [ "$i" -lt 400 ] && [ ! -s "$dir/state/session.rc" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/state/session.rc" ] || fail "the fixture session never finished"
}

# Assert the session acquired the lock under its own pid and then recognized
# itself as the owner.
assert_session_owns_home() {  # <dir> <label>
  local dir=$1 label=$2 session_pid lock_after
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock" 2>/dev/null || true)
  [ "$(cat "$dir/state/session.rc")" = "0 0" ] \
    || fail "$label: acquire/ownership rc was '$(cat "$dir/state/session.rc")': $(cat "$dir/state/lock.out")"
  [ "$lock_after" = "$session_pid" ] || fail "$label: the session lock names $lock_after, expected the session pid $session_pid"
}

test_e2e_deck_chat_host_claims_the_home() {
  local dir
  dir="$TMP_ROOT/e2e-deck-chat"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$NAMED_CHAT"
  assert_session_owns_home "$dir" "deck chat host"
  pass "session-lock e2e: the fm-deck-chat primary host acquires its home and owns it"
}

test_e2e_deck_driver_claims_the_home() {
  local dir
  dir="$TMP_ROOT/e2e-deck-driver"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$NAMED_DECK"
  assert_session_owns_home "$dir" "deck driver"
  pass "session-lock e2e: the persistent fm-deck-worker driver acquires its home and owns it"
}

test_e2e_daemon_parented_session_claims_the_home() {
  local dir session_pid daemon_pid
  dir="$TMP_ROOT/e2e-daemon-parented"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$NAMED_CHAT" "$NAMED_DECK"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  [ -n "$session_pid" ] && [ "$session_pid" != "$daemon_pid" ] \
    || fail "fixture did not produce a distinct daemon and session: session=$session_pid daemon=$daemon_pid"
  assert_session_owns_home "$dir" "daemon-parented session"
  pass "session-lock e2e: a session parented by a harness-named daemon locks to itself, not the daemon"
}

test_e2e_removed_primary_cannot_claim_the_home() {
  local dir
  dir="$TMP_ROOT/e2e-removed-primary"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$NAMED_PI"
  case "$(cat "$dir/state/session.rc")" in
    "0 "*) fail "a pi-named session acquired the home lock: $(cat "$dir/state/lock.out")" ;;
  esac
  [ ! -e "$dir/state/.lock" ] || fail "a pi-named session left a session lock behind"
  assert_contains "$(cat "$dir/state/lock.out")" "cannot locate harness process in ancestry" \
    "a pi-named session must be refused for lack of a primary harness"
  pass "session-lock e2e: a pi-named session is not a primary and cannot claim the home"
}

test_argv0_named_host_is_identified_on_both_platforms
test_harness_at_namespace_pid1_is_examined
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_host_session_is_seen_as_live
test_removed_primaries_never_own_the_lock
test_e2e_deck_chat_host_claims_the_home
test_e2e_deck_driver_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_removed_primary_cannot_claim_the_home
