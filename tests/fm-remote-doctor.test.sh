#!/usr/bin/env bash
# tests/fm-remote-doctor.test.sh - the remote second-mate readiness gate.
#
# Drives the real bin/fm-remote-doctor.sh against a controlled account fixture:
# a private HOME, a fake launchctl backed by state files, a fake busctl that
# answers systemd-logind's KillUserProcesses, and a fake uname that selects the
# platform under test. Every case's home points at one real stream hub
# (bin/fm-stream-hub.py on an ephemeral loopback port) through its own
# config/stream-hub and config/stream-token, so the stream checks run for real.
# Nothing here touches the runner's own launch agents or login session.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (the stream adapter parses its JSON)"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found (the stream adapter talks to the hub with it)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (the hub and plistlib)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-remote-doctor)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
JOB_LABEL=dev.firstmate.remote-job
CASE_N=0
DOCTOR_WORKER_PID=
HUB_PID=
trap 'if [ -n "$DOCTOR_WORKER_PID" ]; then kill "$DOCTOR_WORKER_PID" 2>/dev/null || true; fi; if [ -n "$HUB_PID" ]; then kill "$HUB_PID" 2>/dev/null || true; fi; fm_test_cleanup || true' EXIT

# The doctor never sees the runner's own PATH. Only git and jq are re-exposed,
# by symlink, alongside the system directories the doctor's own helpers need
# (curl and python3 for the stream checks live there).
TOOLS="$TMP_ROOT/tools"
mkdir -p "$TOOLS"
ln -sf "$(command -v git)" "$TOOLS/git"
ln -sf "$(command -v jq)" "$TOOLS/jq"
BASE_PATH="$TOOLS:/usr/bin:/bin:/usr/sbin:/sbin"

# --- the hub every case's home names ----------------------------------------
STREAM_TOKEN="doctor-stream-token-$$"
printf 'publish,subscribe,control:%s\n' "$STREAM_TOKEN" > "$TMP_ROOT/hub-tokens"
chmod 600 "$TMP_ROOT/hub-tokens"
python3 "$ROOT/bin/fm-stream-hub.py" serve --bind 127.0.0.1 --port 0 \
  --token-file "$TMP_ROOT/hub-tokens" --ready-file "$TMP_ROOT/hub-ready" > "$TMP_ROOT/hub.log" 2>&1 &
HUB_PID=$!
for _ in $(seq 1 100); do [ -s "$TMP_ROOT/hub-ready" ] && break; sleep 0.1; done
[ -s "$TMP_ROOT/hub-ready" ] || fail "the stream hub fixture did not start: $(cat "$TMP_ROOT/hub.log")"
read -r STREAM_HOST STREAM_PORT < "$TMP_ROOT/hub-ready"
STREAM_URL="http://$STREAM_HOST:$STREAM_PORT"

# new_case <Darwin|Linux> [gui|no-gui]
# Builds one isolated account fixture and points the module-level CASE_*
# variables at it. "gui" makes the fake launchctl report an existing Aqua login
# session. The case's home is seeded with the shared hub and its token.
new_case() {
  local platform=$1 want_gui=${2:-gui}
  unset CASE_REMOTE_JOB_ACTIVE
  unset CASE_PLATFORM_OVERRIDE
  unset CASE_BASE_PATH
  unset CASE_KILL_USER_PROCESSES
  CASE_N=$((CASE_N + 1))
  CASE_DIR="$TMP_ROOT/case$CASE_N"
  CASE_BIN="$CASE_DIR/bin"
  CASE_HOME="$CASE_DIR/home"
  CASE_PROJECT_HOME="$CASE_DIR/project-home"
  CASE_STATE="$CASE_DIR/state"
  CASE_LAUNCHCTL_LOG="$CASE_STATE/launchctl.log"
  CASE_FORBIDDEN_LOG="$CASE_STATE/forbidden.log"
  CASE_JOB_PLIST="$CASE_HOME/Library/LaunchAgents/$JOB_LABEL.plist"
  mkdir -p "$CASE_BIN" "$CASE_HOME" "$CASE_PROJECT_HOME/config" "$CASE_STATE"
  : > "$CASE_LAUNCHCTL_LOG"
  : > "$CASE_FORBIDDEN_LOG"
  [ "$want_gui" != gui ] || touch "$CASE_STATE/gui-session"
  printf '%s\n' "$STREAM_URL" > "$CASE_PROJECT_HOME/config/stream-hub"
  (umask 077; printf '%s\n' "$STREAM_TOKEN" > "$CASE_PROJECT_HOME/config/stream-token")

  cat > "$CASE_BIN/uname" <<SH
#!/usr/bin/env bash
printf '%s\n' '$platform'
SH

  cat > "$CASE_BIN/launchctl" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "$FM_FAKE_LAUNCHCTL_LOG"
domain=${2:-}
label=${domain##*/}
loaded="$FM_FAKE_STATE/loaded-$label"
case "${1:-}" in
  print)
    case "$domain" in
      */*/*) [ -f "$loaded" ] || exit 113; cat "$loaded" ;;
      *) [ -f "$FM_FAKE_STATE/gui-session" ] || exit 113 ;;
    esac
    exit 0
    ;;
  bootout) rm -f "$loaded"; exit 0 ;;
  bootstrap)
    # launchd refuses a gui/<uid> domain that has no login session.
    [ -f "$FM_FAKE_STATE/gui-session" ] || { printf 'Bootstrap failed: 5: Input/output error\n' >&2; exit 5; }
    plist=${3:-}
    label=${plist##*/}
    label=${label%.plist}
    loaded="$FM_FAKE_STATE/loaded-$label"
    [ ! -f "$loaded" ] || { printf 'Bootstrap failed: service already loaded\n' >&2; exit 5; }
    printf 'path = %s\nprogram = %s\nproperties = keepalive | runatload | inferred program\n' \
      "$plist" "$FM_FAKE_JOB_WORKER" > "$loaded"
    exit 0
    ;;
  kickstart) exit 0 ;;
esac
exit 0
SH

  # systemd-logind's answer for the stream-survival check.
  cat > "$CASE_BIN/busctl" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_KILL_USER_PROCESSES:-0}" = 1 ]; then printf 'b true\n'; else printf 'b false\n'; fi
SH

  # Any attempt to reach for auto-login, FileVault, or the keychain records
  # itself here so the test can prove the doctor never goes near them.
  local forbidden
  for forbidden in fdesetup security defaults; do
    cat > "$CASE_BIN/$forbidden" <<SH
#!/usr/bin/env bash
printf '$forbidden %s\n' "\$*" >> "\$FM_FAKE_FORBIDDEN_LOG"
exit 0
SH
    chmod +x "$CASE_BIN/$forbidden"
  done

  cat > "$CASE_BIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  --version:*) printf '0.2.4\n' ;;
  update:--help) printf '%s\n' --archive-body ;;
  mv:--help) printf '%s\n' 'usage: tasks-axi mv <id> [<id>...]' ;;
esac
SH
  cat > "$CASE_BIN/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$CASE_BIN/deck" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$CASE_BIN/uname" "$CASE_BIN/launchctl" "$CASE_BIN/busctl" "$CASE_BIN/tasks-axi" "$CASE_BIN/treehouse" "$CASE_BIN/deck"
  cat > "$CASE_BIN/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$CASE_BIN/sleep"
}

# doctor [args...] -> runs the real doctor against the current fixture,
# capturing merged output in DOCTOR_OUT and its status in DOCTOR_RC.
doctor() {
  local doctor_base_path=${CASE_BASE_PATH:-$BASE_PATH}
  set +e
  DOCTOR_OUT=$(
    HOME="$CASE_HOME" \
    FM_HOME="$CASE_PROJECT_HOME" \
    FM_CONFIG_OVERRIDE='' FM_STREAM_HUB='' FM_STREAM_TOKEN='' \
    PATH="$CASE_HOME/.local/bin:$CASE_BIN:$doctor_base_path" \
    FM_FAKE_STATE="$CASE_STATE" \
    FM_FAKE_LAUNCHCTL_LOG="$CASE_LAUNCHCTL_LOG" \
    FM_FAKE_FORBIDDEN_LOG="$CASE_FORBIDDEN_LOG" \
    FM_FAKE_JOB_WORKER="$ROOT/bin/fm-remote-job-worker.sh" \
    FM_FAKE_KILL_USER_PROCESSES="${CASE_KILL_USER_PROCESSES:-0}" \
    FM_REMOTE_JOB_PLATFORM_OVERRIDE="${CASE_PLATFORM_OVERRIDE-}" \
    FM_REMOTE_JOB_ACTIVE="${CASE_REMOTE_JOB_ACTIVE-1}" \
    "$ROOT/bin/fm-remote-doctor.sh" "$@" 2>&1
  )
  DOCTOR_RC=$?
  set -e
}

# Parse the doctor's owned launch-agent plist. The plist is Firstmate's output,
# so semantic structure is in bounds; never match the XML source as a substring.
plist_value() { # <plist> <key>
  python3 -c 'import plistlib,sys; value=plistlib.load(open(sys.argv[1], "rb"))[sys.argv[2]]; print(value)' "$1" "$2"
}

plist_first_value() { # <plist> <array-key>
  python3 -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1], "rb"))[sys.argv[2]][0])' "$1" "$2"
}

assert_no_dangerous_calls() { # <msg>
  [ ! -s "$CASE_FORBIDDEN_LOG" ] \
    || fail "$1"$'\n'"--- attempted ---"$'\n'"$(cat "$CASE_FORBIDDEN_LOG")"
  assert_absent "$CASE_HOME/Library/Preferences/com.apple.loginwindow.plist" \
    "the doctor wrote a loginwindow preference"
  assert_absent "$CASE_HOME/kcpassword" "the doctor wrote an auto-login password"
}

# --- unreadable worker versions remain distinct through the protocol --------

new_case Linux no-gui
CASE_REMOTE_JOB_ACTIVE=
CASE_PLATFORM_OVERRIDE=Linux
cat > "$CASE_BIN/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  --version:*) printf 'tasks-axi development build\n' ;;
  update:--help) printf '%s\n' --archive-body ;;
  mv:--help) printf '%s\n' 'usage: tasks-axi mv <id> [<id>...]' ;;
esac
SH
chmod +x "$CASE_BIN/tasks-axi"
rm -f "$CASE_BIN/sleep" "$CASE_BIN/uname"
mkdir -p "$CASE_HOME/.local/bin"
for tool in tasks-axi treehouse deck; do
  ln -s "$CASE_BIN/$tool" "$CASE_HOME/.local/bin/$tool"
done
HOME="$CASE_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  "$ROOT/bin/fm-remote-job-worker.sh" > "$CASE_STATE/worker.out" 2> "$CASE_STATE/worker.err" &
DOCTOR_WORKER_PID=$!
for _ in $(seq 1 100); do
  [ -f "$CASE_HOME/.firstmate/remote-job/worker.ready" ] && break
  sleep 0.05
done
assert_present "$CASE_HOME/.firstmate/remote-job/worker.ready" "the unreadable-version fixture worker did not start"
doctor
expect_code 1 "$DOCTOR_RC" "doctor accepted a tasks-axi build with an unreadable version"
assert_contains "$DOCTOR_OUT" 'required tasks-axi=VERSION_UNREADABLE (requires semantic version >=0.2.4)' \
  "doctor hid the unreadable installed tasks-axi version"
assert_not_contains "$DOCTOR_OUT" 'required tasks-axi=MISSING' \
  "doctor falsely reported the installed tasks-axi build as missing"
assert_contains "$DOCTOR_OUT" 'check remote-job-probe=ok: the remote job worker completed the required-tool probe' \
  "doctor rejected the worker protocol's unreadable-version result"
assert_contains "$DOCTOR_OUT" 'error: required tool versions are unreadable on the remote runtime PATH: tasks-axi' \
  "doctor did not preserve the unreadable-version caveat in its failure"
kill -TERM "$DOCTOR_WORKER_PID"
for _ in $(seq 1 100); do
  kill -0 "$DOCTOR_WORKER_PID" 2>/dev/null || break
  sleep 0.05
done
if kill -0 "$DOCTOR_WORKER_PID" 2>/dev/null; then
  kill -KILL "$DOCTOR_WORKER_PID" 2>/dev/null || true
fi
DOCTOR_WORKER_PID=
pass "doctor preserves unreadable versions through the worker protocol"

make_no_python_path() {
  local target=$1 system_dir system_tool
  mkdir -p "$target"
  for system_dir in /usr/bin /bin /usr/sbin /sbin; do
    for system_tool in "$system_dir"/*; do
      [ -x "$system_tool" ] || continue
      [ "${system_tool##*/}" != python3 ] || continue
      [ -e "$target/${system_tool##*/}" ] || ln -s "$system_tool" "$target/${system_tool##*/}"
    done
  done
}

new_case Linux no-gui
NO_PYTHON_BIN="$CASE_DIR/no-python-bin"
make_no_python_path "$NO_PYTHON_BIN"
CASE_BASE_PATH=$NO_PYTHON_BIN
doctor
expect_code 1 "$DOCTOR_RC" "a Deck-only host without Python was reported ready"
assert_contains "$DOCTOR_OUT" "required harness=deck:$CASE_BIN/deck" \
  "the readiness inventory did not select Deck"
assert_contains "$DOCTOR_OUT" "required python3=MISSING" \
  "Deck readiness did not report its missing Python dependency"
# The stream agent itself needs python3 too; that gap is the stream-tools check's.
assert_contains "$DOCTOR_OUT" "check stream-tools=human: backend=stream selected but 'python3' is not installed" \
  "the stream agent's python3 gap was not reported by stream-tools: $DOCTOR_OUT"
printf '#!/usr/bin/env bash\nexit 0\n' > "$CASE_BIN/python3"
chmod +x "$CASE_BIN/python3"
doctor --fix
expect_code 0 "$DOCTOR_RC" "a Deck host with Python was not ready"
assert_contains "$DOCTOR_OUT" "required python3=$CASE_BIN/python3" \
  "Deck readiness did not report its Python dependency"
pass "Deck readiness requires Python only when Deck is selected"

new_case Linux no-gui
CASE_REMOTE_JOB_ACTIVE=
CASE_PLATFORM_OVERRIDE=Linux
rm -f "$CASE_BIN/sleep" "$CASE_BIN/uname"
mkdir -p "$CASE_HOME/.local/bin"
for tool in tasks-axi treehouse deck; do
  ln -s "$CASE_BIN/$tool" "$CASE_HOME/.local/bin/$tool"
done
HOME="$CASE_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  "$ROOT/bin/fm-remote-job-worker.sh" > "$CASE_STATE/worker.out" 2> "$CASE_STATE/worker.err" &
DOCTOR_WORKER_PID=$!
for _ in $(seq 1 100); do
  [ -f "$CASE_HOME/.firstmate/remote-job/worker.ready" ] && break
  sleep 0.05
done
assert_present "$CASE_HOME/.firstmate/remote-job/worker.ready" "the Deck probe fixture worker did not start"
doctor --fix
expect_code 0 "$DOCTOR_RC" "the normalized worker probe rejected its selected runtime"
assert_contains "$DOCTOR_OUT" 'required harness=' \
  "the worker probe omitted its selected runtime"
if printf '%s\n' "$DOCTOR_OUT" | grep -q '^required harness=deck:'; then
  assert_contains "$DOCTOR_OUT" 'required python3=' \
    "the worker probe omitted Deck's Python dependency"
  assert_not_contains "$DOCTOR_OUT" 'required python3=MISSING' \
    "the worker probe lost its Python runtime"
else
  assert_not_contains "$DOCTOR_OUT" 'required python3=' \
    "the worker probe attached Deck's dependency to another selected runtime"
fi
assert_contains "$DOCTOR_OUT" 'check remote-job-probe=ok: the remote job worker completed the required-tool probe' \
  "the parent rejected the selected runtime's dependency facts"
kill -TERM "$DOCTOR_WORKER_PID"
for _ in $(seq 1 100); do
  kill -0 "$DOCTOR_WORKER_PID" 2>/dev/null || break
  sleep 0.05
done
if kill -0 "$DOCTOR_WORKER_PID" 2>/dev/null; then
  kill -KILL "$DOCTOR_WORKER_PID" 2>/dev/null || true
fi
DOCTOR_WORKER_PID=
pass "the normalized worker probe accepts exactly the selected runtime's dependency facts"
# --- an absent remote-job launch agent is a fixable gap that --fix installs --

new_case Darwin gui
doctor
expect_code 1 "$DOCTOR_RC" "a host with no remote job worker was reported ready"
assert_contains "$DOCTOR_OUT" 'backend=stream' "the doctor did not report the stream backend"
assert_contains "$DOCTOR_OUT" 'check gui-session=ok:' "an existing login session was not detected"
assert_contains "$DOCTOR_OUT" 'check stream-survival=skip:' "logind was consulted on darwin"
assert_contains "$DOCTOR_OUT" 'check remote-job-worker=fixable:' "an absent remote job worker was not tagged fixable"
assert_contains "$DOCTOR_OUT" "$JOB_LABEL.plist" "the gap did not name the launch agent path"
assert_contains "$DOCTOR_OUT" 'check remote-job-worker-loaded=fixable:' "an unloaded remote job worker was not tagged fixable"
assert_contains "$DOCTOR_OUT" 'check remote-job-probe=ok:' "the controlled job-worker probe was not reported"
assert_absent "$CASE_JOB_PLIST" "a read-only doctor run installed a remote job worker"
assert_no_grep bootstrap "$CASE_LAUNCHCTL_LOG" "a read-only doctor run loaded a launch agent"
pass "an absent remote job worker is a fixable gap and the read-only run changes nothing"

doctor --fix
expect_code 0 "$DOCTOR_RC" "--fix left a repairable host unready: $DOCTOR_OUT"
assert_contains "$DOCTOR_OUT" 'fix remote-job-worker=applied:' "--fix did not report installing the worker"
assert_contains "$DOCTOR_OUT" 'check remote-job-worker=ok:' "--fix did not install the remote job worker contract"
assert_contains "$DOCTOR_OUT" 'check remote-job-worker-loaded=ok:' "--fix did not load the remote job worker"
assert_present "$CASE_JOB_PLIST" "--fix reported success without writing the remote job worker plist"
[ "$(plist_value "$CASE_JOB_PLIST" Label)" = "$JOB_LABEL" ] \
  || fail "the worker plist does not carry the Firstmate label"
[ "$(plist_value "$CASE_JOB_PLIST" LimitLoadToSessionType)" = Aqua ] \
  || fail "the worker plist is not Aqua-scoped"
[ "$(plist_first_value "$CASE_JOB_PLIST" ProgramArguments)" = "$ROOT/bin/fm-remote-job-worker.sh" ] \
  || fail "the worker plist does not use the configured code root"
assert_grep "bootstrap gui/$(id -u)" "$CASE_LAUNCHCTL_LOG" "the worker was not bootstrapped into the GUI domain"
assert_no_dangerous_calls "the repair reached for auto-login, FileVault, or the keychain"
pass "--fix installs and loads the Aqua remote job worker"

PLIST_BEFORE=$(cat "$CASE_JOB_PLIST")
: > "$CASE_LAUNCHCTL_LOG"
doctor --fix
expect_code 0 "$DOCTOR_RC" "a second --fix on a ready host reported a gap"
assert_not_contains "$DOCTOR_OUT" 'fix remote-job-worker=applied:' "a second --fix reloaded a healthy worker"
[ "$(cat "$CASE_JOB_PLIST")" = "$PLIST_BEFORE" ] || fail "a second --fix changed the installed plist"
assert_no_grep bootstrap "$CASE_LAUNCHCTL_LOG" "a second --fix re-bootstrapped a loaded worker"
pass "--fix is idempotent once the host is ready"

# --- no GUI login session: every dependent gap stays human -------------------

new_case Darwin no-gui
doctor --fix
expect_code 1 "$DOCTOR_RC" "a host with no login session was reported ready"
assert_contains "$DOCTOR_OUT" 'check gui-session=human:' "an absent login session was not tagged human"
assert_contains "$DOCTOR_OUT" 'check remote-job-worker-loaded=human:' "loading without a login session was not tagged human"
assert_contains "$DOCTOR_OUT" 'fix remote-job-worker=failed: no Aqua login session' \
  "the worker repair did not name the missing login session"
assert_not_contains "$DOCTOR_OUT" 'fix gui-session=applied' "--fix claimed to have created a login session"
assert_not_contains "$DOCTOR_OUT" 'fix remote-job-worker=applied' "--fix claimed to have loaded an unloadable worker"
assert_contains "$DOCTOR_OUT" 'action: gui-session:' "the login-session gap came with no operator action"
assert_contains "$DOCTOR_OUT" 'automatic login' "the login-session action did not name the operator step"
assert_contains "$DOCTOR_OUT" 'error: this host is not ready for a remote second mate' \
  "a remaining human gap did not fail the readiness verdict"
assert_no_dangerous_calls "the doctor tried to create a login session by force"
pass "human gaps are reported with their operator step and never claimed as fixed"

# --- --fix may add only owned wrappers for version-manager tools -------------

new_case Linux no-gui
MANAGER_BIN="$CASE_HOME/.nvm/versions/node/v24/bin"
mkdir -p "$MANAGER_BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MANAGER_BIN/deck"
chmod +x "$MANAGER_BIN/deck"
mv "$CASE_BIN/tasks-axi" "$MANAGER_BIN/tasks-axi"
doctor
expect_code 1 "$DOCTOR_RC" "a version-manager-only required tool was reported ready"
assert_contains "$DOCTOR_OUT" 'required tasks-axi=MISSING' "the missing managed tool was not reported"
assert_contains "$DOCTOR_OUT" 'tools in an unselected nvm version or outside the discovered asdf or mise paths need an absolute wrapper' \
  "the missing-tool diagnostic contradicted filesystem version-manager discovery"
doctor --fix
expect_code 0 "$DOCTOR_RC" "--fix did not create a wrapper for the discoverable managed tool"
assert_contains "$DOCTOR_OUT" 'fix required-tasks-axi=applied:' "--fix did not report the owned wrapper"
assert_contains "$DOCTOR_OUT" "required tasks-axi=$CASE_HOME/.local/bin/tasks-axi" \
  "the worker PATH did not resolve the generated wrapper"
assert_grep '# Firstmate remote tool wrapper v1' "$CASE_HOME/.local/bin/tasks-axi" \
  "the generated wrapper is not marked Firstmate-owned"
assert_grep "$MANAGER_BIN/tasks-axi" "$CASE_HOME/.local/bin/tasks-axi" \
  "the generated wrapper does not execute the discovered absolute target"
assert_absent "$CASE_HOME/.local/bin/deck" "--fix wrapped the harness although deck already satisfied readiness"

rm -f "$CASE_BIN/deck"
doctor --fix
expect_code 0 "$DOCTOR_RC" "--fix did not wrap the discoverable harness when none resolved"
assert_present "$CASE_HOME/.local/bin/deck" "--fix did not create the needed harness wrapper"

mv "$CASE_BIN/treehouse" "$MANAGER_BIN/treehouse"
mkdir -p "$CASE_HOME/.local/bin"
printf 'operator wrapper\n' > "$CASE_HOME/.local/bin/treehouse"
doctor --fix
expect_code 1 "$DOCTOR_RC" "--fix overwrote an operator-owned reserved wrapper"
assert_contains "$DOCTOR_OUT" 'fix required-treehouse=failed:' \
  "the non-Firstmate wrapper refusal was not reported"
[ "$(cat "$CASE_HOME/.local/bin/treehouse")" = 'operator wrapper' ] \
  || fail "--fix overwrote an operator-owned wrapper"
pass "--fix creates only owned version-manager wrappers and never clobbers an operator file"

new_case Linux no-gui
CASE_REMOTE_JOB_ACTIVE=
CASE_PLATFORM_OVERRIDE=Linux
rm -f "$CASE_BIN/sleep" "$CASE_BIN/uname"
mkdir -p "$CASE_HOME/.local/bin"
for tool in tasks-axi treehouse deck; do
  ln -s "$CASE_BIN/$tool" "$CASE_HOME/.local/bin/$tool"
done
HOME="$CASE_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  "$ROOT/bin/fm-remote-job-worker.sh" > "$CASE_STATE/worker.out" 2> "$CASE_STATE/worker.err" &
DOCTOR_WORKER_PID=$!
for _ in $(seq 1 100); do
  [ -f "$CASE_HOME/.firstmate/remote-job/worker.ready" ] && break
  sleep 0.05
done
assert_present "$CASE_HOME/.firstmate/remote-job/worker.ready" "the stale-identity fixture worker did not start"
printf 'stale-worker-identity\n' > "$CASE_HOME/.firstmate/remote-job/worker.identity"
doctor
expect_code 1 "$DOCTOR_RC" "doctor accepted a live worker with stale code identity"
assert_contains "$DOCTOR_OUT" 'check remote-job-worker=fixable: the running remote job worker does not match the current Firstmate code' \
  "doctor did not classify stale worker identity as fixable"
assert_contains "$DOCTOR_OUT" 'check remote-job-probe=fixable: the remote job worker identity is stale' \
  "doctor probed through stale worker code"
doctor --fix
expect_code 0 "$DOCTOR_RC" "--fix did not replace the stale worker identity"
assert_contains "$DOCTOR_OUT" 'fix remote-job-worker=applied:' "--fix did not report refreshing the stale worker"
assert_contains "$DOCTOR_OUT" 'check remote-job-worker=ok:' "the refreshed worker was not confirmed ready"
assert_contains "$DOCTOR_OUT" 'check remote-job-probe=ok: the remote job worker completed the required-tool probe' \
  "doctor did not probe tools through the refreshed worker"
DOCTOR_WORKER_PID=$(cat "$CASE_HOME/.firstmate/remote-job/worker.pid")
kill -TERM "$DOCTOR_WORKER_PID"
for _ in $(seq 1 100); do
  kill -0 "$DOCTOR_WORKER_PID" 2>/dev/null || break
  sleep 0.05
done
if kill -0 "$DOCTOR_WORKER_PID" 2>/dev/null; then
  kill -KILL "$DOCTOR_WORKER_PID" 2>/dev/null || true
fi
DOCTOR_WORKER_PID=
pass "doctor refreshes stale worker identity before probing tools"

# --- the entrypoint symlink is recreated when it is missing ------------------

new_case Linux no-gui
REMOTE_ROOT="$CASE_DIR/remote-root"
mkdir -p "$REMOTE_ROOT/bin"
printf '#!/usr/bin/env bash\n' > "$REMOTE_ROOT/bin/fm-remote-entrypoint.sh"
export FM_ROOT_OVERRIDE="$REMOTE_ROOT"
doctor
assert_contains "$DOCTOR_OUT" 'check entrypoint-link=fixable:' "a missing entrypoint symlink was not tagged fixable"
doctor --fix
assert_contains "$DOCTOR_OUT" 'fix entrypoint-link=applied:' "--fix did not report linking the entrypoint"
assert_contains "$DOCTOR_OUT" 'check entrypoint-link=ok:' "the recreated entrypoint symlink was not confirmed"
[ "$(readlink "$CASE_HOME/.local/bin/fm-remote-entrypoint.sh")" = "$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" ] \
  || fail "the entrypoint symlink does not point at this code root"
printf 'not a symlink\n' > "$CASE_HOME/.local/bin/other"
rm -f "$CASE_HOME/.local/bin/fm-remote-entrypoint.sh"
printf 'operator wrapper\n' > "$CASE_HOME/.local/bin/fm-remote-entrypoint.sh"
doctor --fix
assert_contains "$DOCTOR_OUT" 'check entrypoint-link=human:' "an operator-owned entrypoint file was not left to the operator"
[ "$(cat "$CASE_HOME/.local/bin/fm-remote-entrypoint.sh")" = 'operator wrapper' ] \
  || fail "--fix overwrote a file it did not create"
unset FM_ROOT_OVERRIDE
pass "the entrypoint symlink is recreated when absent and never overwritten when operator-owned"

# --- the stream checks: tools, token, hub, and logind survival ---------------

new_case Linux no-gui
rm -rf "$CASE_PROJECT_HOME"
doctor
expect_code 0 "$DOCTOR_RC" "pre-provision readiness required a home credential: $DOCTOR_OUT"
assert_contains "$DOCTOR_OUT" 'check stream-tools=ok:' "pre-provision readiness skipped stream tools"
assert_contains "$DOCTOR_OUT" 'check stream-token=skip: the destination home has not been provisioned' \
  "an absent home was not distinguished from a missing credential"
assert_contains "$DOCTOR_OUT" 'check stream-hub=skip: the destination home has not been provisioned' \
  "pre-provision readiness probed a home-specific hub"
assert_absent "$CASE_PROJECT_HOME" "readiness created the destination home"
CASE_KILL_USER_PROCESSES=1
doctor --fix
expect_code 1 "$DOCTOR_RC" "pre-provision readiness ignored logout survival"
assert_contains "$DOCTOR_OUT" 'check stream-survival=human:' "the absent home hid the logind gap"
assert_absent "$CASE_PROJECT_HOME" "--fix provisioned a home or minted credentials"
CASE_KILL_USER_PROCESSES=0
mkdir -p "$CASE_PROJECT_HOME/config"
doctor
expect_code 1 "$DOCTOR_RC" "an existing home was accepted without credentials"
assert_contains "$DOCTOR_OUT" 'check stream-token=human:' "an existing home skipped credential readiness"

new_case Darwin no-gui
rm -rf "$CASE_PROJECT_HOME"
doctor
expect_code 1 "$DOCTOR_RC" "pre-provision readiness ignored the missing GUI session"
assert_contains "$DOCTOR_OUT" 'check gui-session=human:' "an absent home hid the GUI session gap"
pass "pre-provision readiness checks the host and defers only home credentials and hub access"

new_case Linux no-gui
doctor --backend stream
expect_code 0 "$DOCTOR_RC" "a ready stream host was refused: $DOCTOR_OUT"
assert_contains "$DOCTOR_OUT" 'backend=stream' "the doctor did not report the stream backend"
assert_contains "$DOCTOR_OUT" 'platform=linux' "the platform was misreported"
assert_contains "$DOCTOR_OUT" 'check gui-session=skip:' "an Aqua login session was required on linux"
assert_contains "$DOCTOR_OUT" 'check stream-tools=ok:' "stream tools were not confirmed: $DOCTOR_OUT"
assert_contains "$DOCTOR_OUT" 'check stream-token=ok:' "a readable stream token was not confirmed: $DOCTOR_OUT"
assert_contains "$DOCTOR_OUT" "check stream-hub=ok: $STREAM_URL accepted this home's token" \
  "a reachable hub accepting the token was not confirmed: $DOCTOR_OUT"
assert_contains "$DOCTOR_OUT" 'check stream-survival=ok: systemd-logind KillUserProcesses=no' \
  "logind survival was not confirmed: $DOCTOR_OUT"
assert_not_contains "$DOCTOR_OUT" "$STREAM_TOKEN" "the doctor printed the stream credential"
doctor
expect_code 0 "$DOCTOR_RC" "the default run disagreed with --backend stream: $DOCTOR_OUT"
assert_contains "$DOCTOR_OUT" 'check stream-hub=ok:' "the default run did not check the stream hub"
doctor --backend herdr
expect_code 2 "$DOCTOR_RC" "a retired backend was accepted by the doctor"

CASE_KILL_USER_PROCESSES=1
doctor --fix
expect_code 1 "$DOCTOR_RC" "a host that kills user processes at logout was reported ready"
assert_contains "$DOCTOR_OUT" 'check stream-survival=human:' "logind's KillUserProcesses=yes was not a human gap"
assert_contains "$DOCTOR_OUT" 'action: stream-survival: set KillUserProcesses=no' "the logind gap had no operator step"
assert_not_contains "$DOCTOR_OUT" 'fix stream-survival=' "--fix claimed to change logind"
CASE_KILL_USER_PROCESSES=0

(umask 077; printf 'not-the-token\n' > "$CASE_PROJECT_HOME/config/stream-token")
doctor
expect_code 1 "$DOCTOR_RC" "a refused stream token still reported the host ready"
assert_contains "$DOCTOR_OUT" 'check stream-hub=human:' "a refused token was not a human gap: $DOCTOR_OUT"
rm -f "$CASE_PROJECT_HOME/config/stream-token"
doctor --fix
expect_code 1 "$DOCTOR_RC" "a missing stream token still reported the host ready"
assert_contains "$DOCTOR_OUT" 'check stream-token=human:' "a missing stream token was not a human gap: $DOCTOR_OUT"
assert_contains "$DOCTOR_OUT" 'check stream-hub=skip:' "the hub was probed without a token: $DOCTOR_OUT"
assert_not_contains "$DOCTOR_OUT" 'fix stream-token=' "--fix claimed to mint a stream credential"
assert_absent "$CASE_PROJECT_HOME/config/stream-token" "--fix wrote a stream credential"

(umask 077; printf '%s\n' "$STREAM_TOKEN" > "$CASE_PROJECT_HOME/config/stream-token")
DEAD_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
printf 'http://127.0.0.1:%s\n' "$DEAD_PORT" > "$CASE_PROJECT_HOME/config/stream-hub"
doctor --fix
expect_code 1 "$DOCTOR_RC" "an unreachable hub was reported ready"
assert_contains "$DOCTOR_OUT" 'check stream-hub=human:' "an unreachable hub was not a human gap: $DOCTOR_OUT"
assert_contains "$DOCTOR_OUT" 'action: stream-hub:' "the hub gap came with no operator action"
assert_not_contains "$DOCTOR_OUT" 'fix stream-hub=' "--fix claimed to start a hub"
pass "the stream checks confirm tools, token, hub, and logind survival, and every gap stays human"
