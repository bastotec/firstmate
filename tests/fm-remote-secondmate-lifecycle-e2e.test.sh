#!/usr/bin/env bash
# Full remote secondmate lifecycle over the deterministic generic SSH boundary.
#
# The remote mate runs on stream the way tests/fm-remote-secondmate-stream.test.sh
# drives it: a real hub (bin/fm-stream-hub.py) on an ephemeral loopback port and
# the real bin/fm-stream-agent.py owning a real pseudoterminal that runs the real
# Deck host driver over a fake `deck` binary, which records every turn's argv.
# The fake SSH boundary plays the fleet's seeding of each remote home's own
# config/stream-hub and config/stream-token before a launch reaches it. A LOCAL
# endpoint (a migration source) lives on the suite's stub hub (tests/fixtures.sh).
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

for tool in jq python3 curl perl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_ROOT=$(fm_test_tmproot fm-remote-secondmate-e2e)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
LOCAL_HOME="$TMP_ROOT/local-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
SSH_COUNT="$TMP_ROOT/ssh.count"
DOCTOR_LOG="$TMP_ROOT/doctor.log"
TURNS="$TMP_ROOT/remote-turns"
CLAIMS="$TMP_ROOT/claims"
HUB_TOKEN="remote-lifecycle-token-$$"
HUB_PID=
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT" "$CLAIMS"

# remote_agents [<id>]: the pids of the stream agents this host runs (for <id>).
remote_agents() {
  ps -eo pid,args 2>/dev/null \
    | awk -v l="--label fm-${1:-}" -v r="$REMOTE_ROOT" \
        'index($0, "fm-stream-agent.py") && index($0, r) && index($0, l) && !index($0, "awk") {print $1}'
}
remote_agent_count() { remote_agents "${1:-}" | wc -l | tr -d ' '; }

cleanup() {
  local worker_pid='' wait_attempt=0 pid
  touch "$TMP_ROOT/provision.release" "$TMP_ROOT/seed.release" "$TMP_ROOT/handoff.release" \
    "$TMP_ROOT/inherit.release" "$TMP_ROOT/launch.release" 2>/dev/null || true
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  for pid in $(remote_agents); do kill "$pid" 2>/dev/null || true; done
  [ -z "$HUB_PID" ] || kill "$HUB_PID" 2>/dev/null || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    kill "$worker_pid" 2>/dev/null || true
    while kill -0 "$worker_pid" 2>/dev/null && [ "$wait_attempt" -lt 100 ]; do
      wait_attempt=$((wait_attempt + 1))
      sleep 0.05
    done
  fi
  rm -rf -- "$TMP_ROOT"
  fm_test_cleanup || true
}
trap cleanup EXIT

# --- the fleet hub every remote home publishes to: real, loopback ------------
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

# Materialize the current branch as the remote host's tracked code root. The
# fixture is a real git repository because provisioning and guarded sync exercise
# the same clone and fast-forward path as a second Mac.
(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)
# The Deck host's startup diagnostics and watcher are shimmed exactly as
# tests/fm-backend-stream.test.sh shims them; the host driver itself is real.
# The `deck` binary records each turn's argv (the model and the prompt) in a log
# kept outside every remote home, so it never dirties a home's tree.
cat > "$REMOTE_ROOT/bin/fm-session-start.sh" <<'SH'
#!/usr/bin/env bash
"$(dirname "$0")/fm-lock.sh" || exit
cat "$FM_HOME/state/.lock" > "$FM_HOME/state/.session-start-complete"
printf 'fixture startup\n'
SH
cat > "$REMOTE_ROOT/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --handling-delivered ] || exit 0
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
while :; do sleep 1; done
SH
cat > "$REMOTE_ROOT/bin/deck" <<PY
#!/usr/bin/env python3
import json, os, sys
with open('$TURNS', 'a') as log:
    log.write(json.dumps({'cwd': os.getcwd(), 'argv': sys.argv[1:]}) + '\n')
print(json.dumps({'type': 'run_started', 'session': 'fixture-session'}), flush=True)
print(json.dumps({'type': 'text_delta', 'text': 'REMOTE-FIXTURE-TURN'}), flush=True)
print(json.dumps({'type': 'run_finished', 'output': 'ready', 'turns': 1}), flush=True)
PY
chmod +x "$REMOTE_ROOT/bin/fm-session-start.sh" "$REMOTE_ROOT/bin/fm-watch-arm.sh" "$REMOTE_ROOT/bin/deck"
# Use the worker's OS Bash for the simulated host's env-based shebangs too.
ln -s /bin/bash "$REMOTE_ROOT/bin/bash"
git -C "$REMOTE_ROOT" init -q -b main
fm_git_foreground_maintenance "$REMOTE_ROOT" || fail 'could not own fixture Git maintenance'
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'remote fixture root'
REMOTE_ORIGIN="$TMP_ROOT/firstmate-origin.git"
git init -q --bare "$REMOTE_ORIGIN"
git -C "$REMOTE_ROOT" remote add origin "file://$REMOTE_ORIGIN"
git -C "$REMOTE_ROOT" push -q -u origin main
git --git-dir="$REMOTE_ORIGIN" symbolic-ref HEAD refs/heads/main
# The code root's origin is the delivery route every home cloned from it takes,
# and a route on the local filesystem - file:// included - is refused as one, so
# it names a forge host. The remote update case below really fetches it, so this
# repository alone gets a transport that serves that host from the local bare
# repository; host-side jobs run under env -i, so it lives in this repository's
# config rather than in the environment, and FM_SSH_BIN is untouched.
REMOTE_FORGE_ROUTE="forge.test:$REMOTE_ORIGIN"
cat > "$FAKEBIN/forge-ssh" <<SH
#!/usr/bin/env bash
# git runs this as ssh for $REMOTE_FORGE_ROUTE: host, then the remote git command.
eval "set -- \${!#}"
exec '$(command -v git)' "\${1#git-}" "\$2"
SH
chmod +x "$FAKEBIN/forge-ssh"
git -C "$REMOTE_ROOT" config core.sshCommand "$FAKEBIN/forge-ssh"
git -C "$REMOTE_ROOT" config ssh.variant simple
git -C "$REMOTE_ROOT" remote set-url origin "$REMOTE_FORGE_ROUTE"

# One remote-backed direct-PR project. The remote home clones its origin, never
# the primary working tree.
git init -q --bare "$TMP_ROOT/alpha.git"
git -C "$PARENT/projects" init -q -b main alpha
git -C "$PARENT/projects/alpha" config user.email test@example.com
git -C "$PARENT/projects/alpha" config user.name Test
printf 'alpha\n' > "$PARENT/projects/alpha/README.md"
git -C "$PARENT/projects/alpha" add README.md
git -C "$PARENT/projects/alpha" commit -qm init
git -C "$PARENT/projects/alpha" remote add origin "file://$TMP_ROOT/alpha.git"
git -C "$PARENT/projects/alpha" push -q -u origin main
# Point the bare origin's HEAD at the branch that was actually pushed, so a
# clone of it checks out a real working tree instead of an empty one.
git --git-dir="$TMP_ROOT/alpha.git" symbolic-ref HEAD refs/heads/main
cat > "$PARENT/data/projects.md" <<EOF
- alpha [direct-PR] - alpha project (added 2026-08-02)
EOF
printf 'deck\n' > "$PARENT/config/secondmate-harness"
printf 'primary harness defaults\n' > "$PARENT/config/crew-harness"
printf 'manual\n' > "$PARENT/config/backlog-backend"

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
count=$(cat "$FM_FAKE_SSH_COUNT" 2>/dev/null || echo 0)
printf '%s\n' "$((count + 1))" > "$FM_FAKE_SSH_COUNT"
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
cd "$FM_FAKE_REMOTE_CWD" || exit 93
home_b64=$3
argv_b64=$4
command_fields=$(perl -MMIME::Base64=decode_base64 -e '
  my $data=decode_base64($ARGV[0]);
  my @args=split(/\0/, $data);
  print join("\t", map { defined $_ && $_ ne "" ? $_ : "-" } @args[0..3]);
' "$argv_b64")
IFS=$'\t' read -r command_name _command_action command_rel command_extra <<EOF
$command_fields
EOF
# The fleet seeds every remote home with the hub its agents publish to and the
# credential for it (docs/stream-backend.md "Security"); this boundary plays
# that seeding for a home about to launch, including a freshly migrated one.
if [ "$command_name" = fm-remote-secondmate-control.sh ] \
  && { [ "$_command_action" = launch ] || [ "$_command_action" = relaunch ]; }; then
  remote_home=$(perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$home_b64")
  if [ -d "$remote_home/config" ] && [ ! -f "$remote_home/config/stream-hub" ]; then
    printf '%s\n' "$FM_FAKE_HUB_URL" > "$remote_home/config/stream-hub"
    (umask 077; printf '%s\n' "$FM_FAKE_HUB_TOKEN" > "$remote_home/config/stream-token")
    printf 'python\n' > "$remote_home/config/stream-impl"
  fi
fi
case "${FM_FAKE_SSH_MODE:-normal}:$command_name:$command_rel" in
  inherit-partial:fm-remote-inherit.sh:config/crew-harness) exit 255 ;;
  inherit-block:fm-remote-inherit.sh:data/captain-shared.md)
    cat > "$FM_FAKE_INHERIT_PAYLOAD"
    touch "$FM_FAKE_INHERIT_ENTERED"
    while [ ! -f "$FM_FAKE_INHERIT_RELEASE" ]; do sleep 0.02; done
    "$FM_FAKE_REMOTE_ENTRYPOINT" "$@" < "$FM_FAKE_INHERIT_PAYLOAD"
    exit $?
    ;;
esac
# The readiness gate is answered here rather than by the real doctor, which
# would inspect and repair the RUNNER's own account. tests/fm-remote-doctor.test.sh
# owns the doctor's real behavior against controlled account fixtures; this
# boundary owns only what the callers do with its verdict.
if [ "$command_name" = fm-remote-doctor.sh ]; then
  # The readiness gate always names the stream backend; --fix follows it.
  doctor_mode=-
  for arg in "$_command_action" "$command_rel" "$command_extra"; do
    [ "$arg" != --fix ] || doctor_mode=--fix
  done
  _command_action=$doctor_mode
  printf '%s %s\n' "${FM_FAKE_SSH_MODE:-normal}" "$doctor_mode" >> "$FM_FAKE_DOCTOR_LOG"
  case "${FM_FAKE_SSH_MODE:-normal}" in
    unreachable) exit 255 ;;
    doctor-fix-unknown)
      if [ "${_command_action:-}" = --fix ]; then
        printf 'fix remote-job-worker=applied: installed or reloaded dev.firstmate.remote-job\n'
        exit 255
      fi
      printf 'check remote-job-worker=fixable: the Linux remote job worker is not running\n'
      printf 'error: this host is not ready for a remote second mate; unresolved: remote-job-worker\n' >&2
      exit 1
      ;;
    doctor-human)
      printf 'check gui-session=human: no Aqua login session exists for uid 501\n'
      printf 'action: gui-session: log that account in once at the console\n'
      printf 'error: this host is not ready for a remote second mate; unresolved: gui-session\n' >&2
      exit 1
      ;;
    doctor-fixable)
      # Red until --fix runs on this host, green on every later read-only run.
      if [ "${_command_action:-}" = --fix ]; then
        touch "$FM_FAKE_DOCTOR_REPAIRED"
        printf 'fix remote-job-worker=applied: installed or reloaded dev.firstmate.remote-job\n'
        printf 'ok: remote second-mate readiness confirmed on this host\n'
        exit 0
      fi
      [ -f "$FM_FAKE_DOCTOR_REPAIRED" ] || {
        printf 'check remote-job-worker=fixable: the Linux remote job worker is not running\n'
        printf 'error: this host is not ready for a remote second mate; unresolved: remote-job-worker\n' >&2
        exit 1
      }
      ;;
  esac
  printf 'check stream-hub=ok: the hub accepted this home token\n'
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
if [ "${FM_FAKE_SSH_MODE:-normal}" = doctor-fixable ] \
  && [ "$command_name" = fm-remote-secondmate-control.sh ] \
  && [ "$_command_action" = state ] \
  && [ ! -f "$FM_FAKE_DOCTOR_REPAIRED" ]; then
  printf 'unreadable\n'
  exit 0
fi
case "${FM_FAKE_SSH_MODE:-normal}:$command_name:$command_rel" in
  migration-launch-fail:fm-remote-secondmate-control.sh:*)
    # A launch that reports failure with its endpoint left agent-free: the
    # host's own control plane stops the agent it just started.
    if [ "$_command_action" = launch ]; then
      "$FM_FAKE_REMOTE_ENTRYPOINT" "$@" >/dev/null 2>&1
      exit_b64=$(printf '%s\0' fm-remote-secondmate-control.sh control "$command_rel" exit | base64 | tr -d '\n')
      "$FM_FAKE_REMOTE_ENTRYPOINT" "$1" "$2" "$3" "$exit_b64" >/dev/null 2>&1
      exit 1
    fi
    ;;
  migration-launch-unknown:fm-remote-secondmate-control.sh:*)
    if [ "$_command_action" = launch ]; then "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"; exit 255; fi
    ;;
  migration-stage-unknown:fm-remote-home-provision.sh:*)
    "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"; exit 255
    ;;
  launch-nonstream-route:fm-remote-secondmate-control.sh:*)
    [ "$_command_action" = launch ] || exit 93
    printf 'schema=fm-remote-secondmate-control.v1\n'
    printf 'backend=tmux\n'
    printf 'target=firstmate:fm-ios\n'
    printf 'harness=deck\n'
    exit 0
    ;;
  provision-block-fail:fm-remote-home-provision.sh:*)
    touch "$FM_FAKE_SEED_ENTERED"
    while [ ! -f "$FM_FAKE_SEED_RELEASE" ]; do sleep 0.02; done
    exit 1
    ;;
  launch-block:fm-remote-secondmate-control.sh:*)
    [ "$_command_action" = launch ] || exit 93
    touch "$FM_FAKE_LAUNCH_ENTERED"
    while [ ! -f "$FM_FAKE_LAUNCH_RELEASE" ]; do sleep 0.02; done
    ;;
esac
case "${FM_FAKE_SSH_MODE:-normal}" in
  unreachable) exit 255 ;;
  ambiguous) "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"; exit 255 ;;
  *) exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@" ;;
esac
SH
chmod +x "$FAKEBIN/fake-ssh"

publish_healthy_watcher_identity() { # <state> <home> <watch-script>
  local state=$1 home=$2 watch=$3 identity
  identity=$(FM_HOME="$PARENT" FM_STATE_OVERRIDE="$PARENT/state" /bin/bash -c \
    '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$$") \
    || fail "could not derive fixture watcher identity"
  mkdir -p "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  printf '%s\n' "$home" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$watch" > "$state/.watch.lock/watcher-path"
  touch "$state/.last-watcher-beat"
}

# Model an SSH login outside the caller's checkout, even when TMPDIR is nested
# inside a gate worktree: host-local commands must discover the remote repository.
remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_SSH_COUNT="$SSH_COUNT" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_SSH_MODE="${FM_FAKE_SSH_MODE:-normal}" \
  FM_FAKE_REMOTE_CWD="$REMOTE_ROOT" \
  FM_FAKE_SEED_ENTERED="$TMP_ROOT/seed.entered" \
  FM_FAKE_SEED_RELEASE="$TMP_ROOT/seed.release" \
  FM_FAKE_DOCTOR_LOG="$DOCTOR_LOG" \
  FM_FAKE_DOCTOR_REPAIRED="$TMP_ROOT/doctor.repaired" \
  FM_FAKE_INHERIT_ENTERED="$TMP_ROOT/inherit.entered" \
  FM_FAKE_INHERIT_RELEASE="$TMP_ROOT/inherit.release" \
  FM_FAKE_INHERIT_PAYLOAD="$TMP_ROOT/inherit.payload" \
  FM_FAKE_LAUNCH_ENTERED="$TMP_ROOT/launch.entered" \
  FM_FAKE_LAUNCH_RELEASE="$TMP_ROOT/launch.release" \
  FM_FAKE_HUB_URL="$HUB_URL" FM_FAKE_HUB_TOKEN="$HUB_TOKEN" \
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 FM_REMOTE_REPLY_WAIT_SECONDS=10 \
  "$@"
}

# The host-side adapter as that host itself reads <home>'s endpoints.
# shellcheck disable=SC2016 # $1 and $@ expand in the inner shell.
host_backend() {  # <home> <function> [args...]
  local home=$1
  shift
  env -u FM_STREAM_HUB -u FM_STREAM_TOKEN -u FM_STREAM_MACHINE -u FM_STREAM_AGENT_BIN \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_ROOT="$REMOTE_ROOT" \
    bash -c '. "$1/bin/fm-backend.sh"; shift; "$@"' _ "$REMOTE_ROOT" "$@"
}

# turns_with <text>: how many recorded Deck turns carry <text> in their argv.
turns_with() { grep -cF -- "$1" "$TURNS" 2>/dev/null || true; }
wait_turn_with() {  # <text>
  local waited=0
  while [ "$(turns_with "$1")" = 0 ] && [ "$waited" -lt 300 ]; do sleep 0.1; waited=$((waited + 1)); done
  [ "$(turns_with "$1")" != 0 ]
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

# The correlation token of the newest record in the remote secondmate's
# steering inbox: a remote steer is delivered as a durable record there, so
# the corr a reply must echo is read from the record body, never from typed
# pane bytes.
newest_remote_inbox_corr() {
  grep -Eoh 'corr=[a-f0-9]{16}' "$REMOTE_HOME"/state/parent-route/ios.inbox/*.msg 2>/dev/null \
    | tail -1 | cut -d= -f2-
}

seed_env() {
  FM_HOME="$TMP_ROOT/seed-parent" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_SSH_COUNT="$SSH_COUNT" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_SSH_MODE="${FM_FAKE_SSH_MODE:-normal}" \
  FM_FAKE_REMOTE_CWD="$REMOTE_ROOT" \
  FM_FAKE_SEED_ENTERED="$TMP_ROOT/seed.entered" \
  FM_FAKE_SEED_RELEASE="$TMP_ROOT/seed.release" \
  FM_FAKE_DOCTOR_LOG="$DOCTOR_LOG" \
  FM_FAKE_DOCTOR_REPAIRED="$TMP_ROOT/doctor.repaired" \
  FM_FAKE_HUB_URL="$HUB_URL" FM_FAKE_HUB_TOKEN="$HUB_TOKEN" \
  "$@"
}

# Migration uses the same real transport/provisioning/spawn owners and the
# real stream hub and agent, never the runner's real sessions or remote accounts.
if [ "${FM_TEST_MIGRATION_ONLY:-0}" = 1 ]; then
  # <id> [<project-delivery-mode>]: a source home is a real firstmate checkout
  # carrying durable records, an excluded credential set, and optionally one
  # registered project clone whose origin the remote host must clone for itself.
  migration_source() {
    local id=$1 mode=${2:-} source="$TMP_ROOT/source-$1"
    git clone -q "$REMOTE_ROOT" "$source" || fail 'source clone failed'
    mkdir -p "$source/data/report" "$source/state/inbox" "$source/config" "$source/projects" "$PARENT/data/$id"
    if [ -n "$mode" ]; then
      git clone -q "file://$TMP_ROOT/alpha.git" "$source/projects/alpha" || fail 'source project clone failed'
      printf -- '- alpha [%s] - alpha project (added 2026-08-02)\n' "$mode" > "$source/data/projects.md"
    fi
    printf '%s\n' "$id" > "$source/.fm-secondmate-home"
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT" > "$source/.fm-secondmate-parent"
    printf 'Persistent charter. Replies: %s/state/%s.status; steer: %s/state/%s.inbox\nFor posterity: this mate was first set up under %s and that is where its early reports were written.\n' \
      "$PARENT" "$id" "$PARENT" "$id" "$source" > "$source/data/charter.md"
    cp "$source/data/charter.md" "$PARENT/data/$id/brief.md"
    printf '## In flight\n\n## Queued\n\n- [ ] preserve - Open decision\n  A durable unlanded record.\n\n## Done\n' > "$source/data/backlog.md"
    printf 'memory\000binary-safe\n' > "$source/data/learnings.md"
    printf 'report with trailing blank lines\n\n\n' > "$source/data/report/report.md"
    printf 'pending note\n' > "$source/state/inbox/note.md"
    printf 'needs-decision [key=old]: preserved historical event\n' > "$source/state/old.status"
    printf 'deck\n' > "$source/config/crew-harness"
    printf 'source-only-token\n' > "$source/config/stream-token"
    printf 'http://source-only.invalid:7717\n' > "$source/config/stream-hub"
    printf 'rust\n' > "$source/config/stream-impl"
    printf 'source-machine\n' > "$source/config/stream-machine"
    printf '/source/native\n' > "$source/config/stream-native-dir"
    printf '{"http://source.invalid": "secret-value-never-transfer"}\n' > "$source/config/stream-hub-tokens"
    printf 'secret-value-never-transfer\n' > "$source/config/cmux-socket-password"
    printf 'secret-value-never-transfer\n' > "$source/.env"
    mkdir "$source/data/credentials"
    printf 'secret-value-never-transfer\n' > "$source/data/credentials/token"
    printf -- '- %s - Persistent responsibility (home: %s; scope: exact selected work; projects: ; added 2026-08-02)\n' "$id" "$source" >> "$PARENT/data/secondmates.md"
    # The stopped local mate: its endpoint stands with only its shell in the
    # foreground, which is what reads `dead` - the state a migration requires.
    {
      fm_test_stream_task "$PARENT/state" "$id"
      fm_test_fake_stream_foreground "$(fm_test_stream_target_of "$PARENT/state" "$id")" bash
      printf 'harness=deck\nkind=secondmate\nhome=%s\nworktree=%s\nproject=%s\n' "$source" "$source" "$REMOTE_ROOT"
    } > "$PARENT/state/$id.meta"
  }
  migrate() {
    local id=$1
    PATH="$REMOTE_ROOT/bin:$PATH" remote_env "$ROOT/bin/fm-remote-home-seed.sh" --migrate "$id" \
      "$TMP_ROOT/source-$id" remote-mac "$REMOTE_ROOT" "$TMP_ROOT/migrated-$id"
  }
  migration_source keep-local
  cp "$PARENT/state/keep-local.meta" "$TMP_ROOT/sibling.meta"
  cp "$TMP_ROOT/source-keep-local/data/backlog.md" "$TMP_ROOT/sibling.backlog"
  migration_source move-work
  printf 'kind=ship\n' > "$TMP_ROOT/source-move-work/state/child.meta"
  if migrate move-work > "$TMP_ROOT/migrate.out" 2>&1; then fail 'migration accepted child work'; fi
  assert_grep 'child work records remain' "$TMP_ROOT/migrate.out" 'missing child refusal'
  assert_absent "$TMP_ROOT/migrated-move-work" 'child refusal created remote home'
  assert_absent "$TMP_ROOT/source-move-work/.fm-home-migration" 'child refusal froze source'
  rm "$TMP_ROOT/source-move-work/state/child.meta"
  # The remaining stopped-home preconditions refuse on the same terms: a home
  # that is still supervising, still away, or still a parent cannot be moved.
  # A session lock names a harness process, so hold one: a lock carrying any
  # other live pid is correctly read as stale and must not block a migration.
  # A harness-named argv[0] is what both platforms can see - macOS reports it as
  # the command name and procps exposes it as argv[0] - and it needs no binary
  # copy, which macOS refuses to execute once its signature no longer matches.
  bash -c 'exec -a fm-deck-chat sleep 600' &
  harness_pid=$!
  printf '%s\n' "$harness_pid" > "$TMP_ROOT/source-move-work/state/.lock"
  if migrate move-work > "$TMP_ROOT/migrate.out" 2>&1; then fail 'migration accepted a live session'; fi
  assert_grep 'source session is not stopped' "$TMP_ROOT/migrate.out" 'missing live-session refusal'
  kill "$harness_pid" 2>/dev/null || true
  wait "$harness_pid" 2>/dev/null || true
  rm "$TMP_ROOT/source-move-work/state/.lock"
  printf 'away\n' > "$TMP_ROOT/source-move-work/state/.afk"
  if migrate move-work > "$TMP_ROOT/migrate.out" 2>&1; then fail 'migration accepted an away home'; fi
  assert_grep 'leave away/quiet mode before migration' "$TMP_ROOT/migrate.out" 'missing away-posture refusal'
  rm "$TMP_ROOT/source-move-work/state/.afk"
  printf -- '- child - A nested route (home: /nowhere; scope: none; projects: ; added 2026-08-02)\n' \
    > "$TMP_ROOT/source-move-work/data/secondmates.md"
  if migrate move-work > "$TMP_ROOT/migrate.out" 2>&1; then fail 'migration accepted a home with nested routes'; fi
  assert_grep 'nested secondmate routes remain' "$TMP_ROOT/migrate.out" 'missing nested-route refusal'
  rm "$TMP_ROOT/source-move-work/data/secondmates.md"
  assert_absent "$TMP_ROOT/migrated-move-work" 'a refused precondition still provisioned the remote home'
  assert_absent "$TMP_ROOT/source-move-work/.fm-home-migration" 'a refused precondition still froze the source'
  mkdir -p "$PARENT/state/move-work.inbox/handled" "$PARENT/state/pending-replies"
  printf 'schema=fm-task-inbox.v1\n\nrequest corr=0123456789abcdef\n' > "$PARENT/state/move-work.inbox/001.msg"
  printf 'prior handled request\n' > "$PARENT/state/move-work.inbox/handled/000.msg"
  printf 'task_id=move-work\nphase=resolved\n' > "$PARENT/state/pending-replies/0123456789abcdef"
  cp "$PARENT/state/pending-replies/0123456789abcdef" "$TMP_ROOT/correlation.before"
  if FM_FAKE_SSH_MODE=doctor-human migrate move-work > "$TMP_ROOT/migrate.out" 2>&1; then fail 'migration bypassed doctor'; fi
  assert_grep 'check gui-session=human:' "$TMP_ROOT/migrate.out" "doctor gap was hidden: $(cat "$TMP_ROOT/migrate.out")"
  assert_no_grep 'doctor-human --fix' "$DOCTOR_LOG" 'migration repaired the real-host boundary implicitly'
  assert_absent "$TMP_ROOT/migrated-move-work" 'unready host was provisioned'
  assert_grep 'home: ' "$PARENT/data/secondmates.md" 'unready migration removed local route'
  rc=0
  FM_FAKE_SSH_MODE=migration-stage-unknown migrate move-work > "$TMP_ROOT/migrate.out" 2>&1 || rc=$?
  [ "$rc" = 255 ] || fail "staging unknown was not SSH255: $(cat "$TMP_ROOT/migrate.out")"
  assert_present "$TMP_ROOT/migrated-move-work/data/backlog.md" "unknown stage lost remote data: $(cat "$TMP_ROOT/migrate.out")"
  assert_grep 'move-work - Persistent responsibility (home:' "$PARENT/data/secondmates.md" 'unknown staging switched live route'
  assert_absent "$TMP_ROOT/migrated-move-work/state/parent-route/move-work.meta" 'unknown staging launched an agent'
  # The parent keeps steering a stopped mate between attempts. A steer queued
  # after the first snapshot is real work the rerun has to carry across, and the
  # watcher bookkeeping its re-ring ladder writes beside it is ordinary inbox
  # furniture the rerun has to ignore. Neither may wedge the migration.
  printf 'schema=fm-task-inbox.v1\n\nlater request\n' > "$PARENT/state/move-work.inbox/002.msg"
  printf '001.msg\t1\t1756000000\n' > "$PARENT/state/move-work.inbox/.ring-state"
  printf '001.msg\n' > "$PARENT/state/move-work.inbox/.escalated"
  : > "$PARENT/state/move-work.inbox/.staging.Ab3xZ9"
  : > "$PARENT/state/move-work.inbox/.dedup.Cd4yW1"
  out=$(migrate move-work 2>&1) || fail "migration recovery failed: $out"
  assert_grep 'move-work - Persistent responsibility (host:' "$PARENT/data/secondmates.md" 'successful migration did not switch route'
  for path in data/backlog.md data/learnings.md data/report/report.md state/inbox/note.md; do
    cmp -s "$TMP_ROOT/source-move-work/$path" "$TMP_ROOT/migrated-move-work/$path" || fail "durable bytes changed: $path"
  done
  cmp -s "$TMP_ROOT/source-move-work/state/old.status" "$TMP_ROOT/migrated-move-work/.fm-migration/state/old.status" || fail 'unlanded state evidence lost'
  cmp -s "$PARENT/state/move-work.inbox/001.msg" "$TMP_ROOT/migrated-move-work/state/parent-route/move-work.inbox/001.msg" || fail 'pending steer bytes/correlation lost'
  cmp -s "$PARENT/state/move-work.inbox/002.msg" "$TMP_ROOT/migrated-move-work/state/parent-route/move-work.inbox/002.msg" \
    || fail 'a steer queued after the first snapshot did not cross on the rerun'
  for artifact in .ring-state .escalated .staging.Ab3xZ9 .dedup.Cd4yW1; do
    assert_absent "$TMP_ROOT/migrated-move-work/state/parent-route/move-work.inbox/$artifact" \
      'watcher inbox bookkeeping was transferred as a durable record'
  done
  cmp -s "$TMP_ROOT/correlation.before" "$PARENT/state/pending-replies/0123456789abcdef" || fail 'parent correlation changed'
  cmp -s "$TMP_ROOT/source-move-work/data/charter.md" "$TMP_ROOT/migrated-move-work/.fm-migration/original-charter.md" || fail 'original charter lost'
  # The active charter re-points exactly the two live parent addresses and is
  # byte-identical everywhere else, so prose naming the old home as history
  # survives the move unrewritten.
  sed -e "s#$PARENT/state/move-work.status#$TMP_ROOT/migrated-move-work/state/parent-replies.status#g" \
      -e "s#$PARENT/state/move-work.inbox#$TMP_ROOT/migrated-move-work/state/parent-route/move-work.inbox#g" \
      "$TMP_ROOT/source-move-work/data/charter.md" > "$TMP_ROOT/charter.expected"
  cmp -s "$TMP_ROOT/charter.expected" "$TMP_ROOT/migrated-move-work/data/charter.md" \
    || fail 'the active charter re-points more or less than the two parent addresses'
  grep -q "$TMP_ROOT/source-move-work" "$TMP_ROOT/migrated-move-work/data/charter.md" \
    || fail 'charter prose naming the old home as history was rewritten'
  for path in .env config/cmux-socket-password data/credentials; do
    assert_absent "$TMP_ROOT/migrated-move-work/$path" 'credential transferred'
    assert_present "$TMP_ROOT/source-move-work/$path" 'excluded credential removed locally'
  done
  for name in stream-token stream-hub stream-impl stream-machine stream-native-dir stream-hub-tokens; do
    assert_present "$TMP_ROOT/source-move-work/config/$name" 'host-local stream config removed locally'
    jq -e --arg p "config/$name" \
      '(.excluded | index($p)) != null and all(.records[]; .path != $p)' \
      "$TMP_ROOT/migrated-move-work/.fm-migration/bundle.json" >/dev/null \
      || fail "host-bound stream config was transferred: $name"
  done
  [ "$(cat "$TMP_ROOT/migrated-move-work/config/stream-hub")" = "$HUB_URL" ] \
    || fail 'migration overwrote destination hub routing'
  [ "$(cat "$TMP_ROOT/migrated-move-work/config/stream-impl")" = python ] \
    || fail 'migration overwrote destination stream implementation'
  [ "$(cat "$TMP_ROOT/migrated-move-work/config/stream-token")" = "$HUB_TOKEN" ] \
    || fail 'migration replaced the destination credential with the source token'
  if FM_HOME="$TMP_ROOT/source-move-work" "$ROOT/bin/fm-lock.sh" > "$TMP_ROOT/frozen.out" 2>&1; then fail 'archive acquired session'; fi
  assert_grep 'frozen migration archive' "$TMP_ROOT/frozen.out" 'archive not protected'
  if FM_HOME="$TMP_ROOT/source-move-work" "$ROOT/bin/fm-spawn.sh" unsafe --secondmate > "$TMP_ROOT/frozen.out" 2>&1; then fail 'archive spawned work'; fi
  assert_grep 'frozen migration archive' "$TMP_ROOT/frozen.out" 'archive dispatch not protected'
  assert_grep 'remote_backend=stream' "$PARENT/state/move-work.meta" 'migration did not launch on stream'
  [ "$(host_backend "$TMP_ROOT/migrated-move-work" fm_backend_agent_state stream \
    "$(sed -n 's/^remote_target=//p' "$PARENT/state/move-work.meta")")" = alive ] \
    || fail 'the migrated mate is not running on the host'
  [ -z "$(find "$TMP_ROOT" -maxdepth 1 -name '.fm-migration-move-work.*' -print)" ] \
    || fail 'a published migration left a duplicate of the durable records staged outside the home'
  pass 'migration refuses children and doctor gaps, converges a rerun that finds new steering, preserves exact durable bytes and correlations, excludes secrets, and relaunches the same identity'

  migration_source fail-work
  if FM_FAKE_SSH_MODE=migration-launch-fail migrate fail-work > "$TMP_ROOT/migrate.out" 2>&1; then fail 'failed launch reported migrated'; fi
  assert_grep 'original route restored' "$TMP_ROOT/migrate.out" "known failure did not roll back: $(cat "$TMP_ROOT/migrate.out")"
  assert_grep 'fail-work - Persistent responsibility (home:' "$PARENT/data/secondmates.md" 'rollback did not restore local route'
  cmp -s "$PARENT/data/fail-work/migration/meta.before" "$PARENT/state/fail-work.meta" || fail 'rollback did not restore endpoint records'
  assert_present "$TMP_ROOT/source-fail-work/.fm-home-migration" 'rollback allowed unsafe local restart'
  assert_present "$TMP_ROOT/migrated-fail-work/data/backlog.md" 'rollback discarded remote durable data'
  # The published home is the newer copy once a placement exists on the host, so
  # a rerun after the rollback retries the launch and must not re-land the frozen
  # source's older records over it, even with steering queued since.
  printf -- '- [ ] landed on the host after the move\n' >> "$TMP_ROOT/migrated-fail-work/data/backlog.md"
  printf 'memory written on the host\n' > "$TMP_ROOT/migrated-fail-work/data/learnings.md"
  printf 'report written on the host\n' > "$TMP_ROOT/migrated-fail-work/data/report/report.md"
  printf 'note written on the host\n' > "$TMP_ROOT/migrated-fail-work/state/inbox/note.md"
  mkdir -p "$PARENT/state/fail-work.inbox"
  printf 'schema=fm-task-inbox.v1\n\nsteer queued after the rollback\n' > "$PARENT/state/fail-work.inbox/001.msg"
  cp -R "$TMP_ROOT/migrated-fail-work" "$TMP_ROOT/remote-before-rerun"
  out=$(migrate fail-work 2>&1) || fail "the rerun after a rollback did not converge: $out"
  for path in data/backlog.md data/learnings.md data/report/report.md state/inbox/note.md; do
    cmp -s "$TMP_ROOT/remote-before-rerun/$path" "$TMP_ROOT/migrated-fail-work/$path" \
      || fail "the rerun after a rollback re-landed the frozen source over the published home: $path"
  done
  assert_grep 'fail-work - Persistent responsibility (host:' "$PARENT/data/secondmates.md" \
    'the rerun after a rollback did not re-publish the remote route'
  pass 'known launch failure restores route while preserving both stopped copies, and its rerun retries the launch without re-landing records'

  migration_source unknown-work
  rc=0
  FM_FAKE_SSH_MODE=migration-launch-unknown migrate unknown-work > "$TMP_ROOT/migrate.out" 2>&1 || rc=$?
  [ "$rc" = 255 ] || fail "unknown launch did not retain SSH255: $(cat "$TMP_ROOT/migrate.out")"
  assert_grep 'unknown-work - Persistent responsibility (host:' "$PARENT/data/secondmates.md" 'unknown launch rolled back route'
  # Count the agents that EXIST, not the creations: only a genuine duplicate
  # leaves the host running one more agent for this mate than before the rerun.
  endpoints=$(remote_agent_count unknown-work)
  out=$(migrate unknown-work 2>&1) || fail "unknown launch reconciliation failed: $out"
  [ "$(remote_agent_count unknown-work)" = "$endpoints" ] \
    || fail "unknown recovery left a duplicate endpoint: $endpoints -> $(remote_agent_count unknown-work)"
  cmp -s "$TMP_ROOT/sibling.meta" "$PARENT/state/keep-local.meta" || fail 'migration touched local sibling endpoint'
  cmp -s "$TMP_ROOT/sibling.backlog" "$TMP_ROOT/source-keep-local/data/backlog.md" || fail 'migration touched local sibling home'
  assert_grep 'keep-local - Persistent responsibility (home:' "$PARENT/data/secondmates.md" 'migration moved an unselected sibling'
  pass 'unknown launch preserves remote placement and converges without duplicates or touching the local sibling'

  migration_source local-project local-only
  if migrate local-project > "$TMP_ROOT/migrate.out" 2>&1; then fail 'migration moved a local-only project'; fi
  assert_grep 'project alpha cannot be remote: local-only' "$TMP_ROOT/migrate.out" \
    "local-only project was not refused: $(cat "$TMP_ROOT/migrate.out")"
  assert_absent "$TMP_ROOT/migrated-local-project" 'refused local-only project was provisioned'
  assert_grep 'local-project - Persistent responsibility (home:' "$PARENT/data/secondmates.md" \
    'local-only refusal switched the route'
  assert_absent "$TMP_ROOT/source-local-project/.fm-home-migration" 'local-only refusal left the source frozen'
  assert_absent "$PARENT/data/local-project/migration" 'local-only refusal retained its journal'

  # A home the command refuses locally must stay usable: the refusal names what
  # it could not carry, and the archive guard that stops a frozen home starting
  # a session must not be left behind by a migration that never staged anything.
  # The ordinary remote job ceiling is 1 MiB, and a mate carrying real reports
  # and memory packs well past it. Move one whose durable records exceed that
  # ceiling to prove the raised migration bound holds on both sides of the
  # transport - the staging side and the worker that runs the staged job.
  migration_source big-work
  yes 'a durable line of memory that pushes this record past the ordinary remote job ceiling' \
    | head -c 1572864 > "$TMP_ROOT/source-big-work/data/learnings.md"
  [ "$(LC_ALL=C wc -c < "$TMP_ROOT/source-big-work/data/learnings.md" | tr -d ' ')" -gt 1048576 ] \
    || fail 'the oversized fixture record is not above the ordinary remote job ceiling'
  out=$(migrate big-work 2>&1) || fail "a migration past the ordinary job ceiling failed: $out"
  cmp -s "$TMP_ROOT/source-big-work/data/learnings.md" "$TMP_ROOT/migrated-big-work/data/learnings.md" \
    || fail 'the oversized durable record did not cross byte-exact'
  cmp -s "$TMP_ROOT/source-big-work/data/backlog.md" "$TMP_ROOT/migrated-big-work/data/backlog.md" \
    || fail 'the rest of the oversized snapshot did not cross byte-exact'
  assert_grep 'big-work - Persistent responsibility (host:' "$PARENT/data/secondmates.md" \
    'the oversized migration did not switch the route'
  assert_grep 'remote_backend=stream' "$PARENT/state/big-work.meta" \
    'the oversized migration did not launch on stream'
  pass 'a snapshot past the ordinary remote job ceiling stages, reaches the worker, and completes'

  # Records only ever arrive or change while the source is frozen, so a snapshot
  # that has stopped carrying one the host already holds is a signal, not a
  # deletion instruction: it is refused by name and the host keeps its bytes.
  migration_source drop-work
  rc=0
  FM_FAKE_SSH_MODE=migration-stage-unknown migrate drop-work > "$TMP_ROOT/migrate.out" 2>&1 || rc=$?
  [ "$rc" = 255 ] || fail "staging unknown was not SSH255: $(cat "$TMP_ROOT/migrate.out")"
  assert_present "$TMP_ROOT/migrated-drop-work/data/report/report.md" \
    "unknown staging did not publish the remote home: $(cat "$TMP_ROOT/migrate.out")"
  cp "$TMP_ROOT/source-drop-work/data/report/report.md" "$TMP_ROOT/report.published"
  rm "$TMP_ROOT/source-drop-work/data/report/report.md"
  if migrate drop-work > "$TMP_ROOT/migrate.out" 2>&1; then fail 'a snapshot that drops a published record was accepted'; fi
  assert_grep 'data/report/report.md' "$TMP_ROOT/migrate.out" \
    "the refusal did not name the dropped record: $(cat "$TMP_ROOT/migrate.out")"
  cmp -s "$TMP_ROOT/report.published" "$TMP_ROOT/migrated-drop-work/data/report/report.md" \
    || fail 'the refused rerun changed the published home instead of leaving it alone'
  assert_grep 'drop-work - Persistent responsibility (home:' "$PARENT/data/secondmates.md" \
    'the refused rerun switched the route'
  printf 'report rewritten before the next attempt\n' > "$TMP_ROOT/source-drop-work/data/report/report.md"
  out=$(migrate drop-work 2>&1) || fail "a rerun that only changes record bytes did not converge: $out"
  cmp -s "$TMP_ROOT/source-drop-work/data/report/report.md" "$TMP_ROOT/migrated-drop-work/data/report/report.md" \
    || fail 'a rerun that only changes record bytes did not re-land them'
  assert_grep 'drop-work - Persistent responsibility (host:' "$PARENT/data/secondmates.md" \
    'the converged rerun did not switch the route'
  pass 'a rerun that drops a published record is refused by name while one that only changes bytes converges'

  # The receipt - the bundle plus the digest naming it - is the only record that
  # tells this host which snapshot it carries, and a home that is already live is
  # the one place it is not published by a whole-home rename. A copy killed
  # part-way through must therefore never be observable on the live receipt:
  # the home keeps a bundle that still parses and a digest that still names it,
  # and the next attempt converges instead of needing hand repair.
  receipt_home="$TMP_ROOT/migrated-drop-work"
  printf 'report rewritten again, after the receipt copy was killed\n' > "$TMP_ROOT/receipt.report"
  jq --arg b64 "$(base64 < "$TMP_ROOT/receipt.report" | tr -d '\n')" \
     --arg sha "$(shasum -a 256 "$TMP_ROOT/receipt.report" | awk '{print $1}')" \
     '.records |= map(if .path == "data/report/report.md" then .bytes = $b64 | .sha256 = $sha else . end)' \
     "$receipt_home/.fm-migration/bundle.json" > "$TMP_ROOT/receipt-bundle.json" \
    || fail 'could not build the next migration snapshot for the receipt crash'
  receipt_digest=$(shasum -a 256 "$TMP_ROOT/receipt-bundle.json" | awk '{print $1}')
  mkdir -p "$TMP_ROOT/crashbin"
  cat > "$TMP_ROOT/crashbin/cp" <<'SH'
#!/usr/bin/env bash
# A kill part-way through the receipt copy: whatever the copy was writing to
# keeps a truncated prefix, and the caller sees the copy fail.
set -u
dest=${!#}
case "$dest" in
  */.fm-migration/bundle.json*) head -c 40 -- "$1" > "$dest"; exit 137 ;;
esac
exec /bin/cp "$@"
SH
  chmod +x "$TMP_ROOT/crashbin/cp"
  if PATH="$TMP_ROOT/crashbin:$PATH" FM_HOME="$receipt_home" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
      "$REMOTE_ROOT/bin/fm-remote-home-provision.sh" --migration drop-work "$receipt_digest" \
      < "$TMP_ROOT/receipt-bundle.json" > "$TMP_ROOT/receipt-crash.out" 2>&1; then
    fail 'a receipt copy killed part-way through still reported the migration verified'
  fi
  jq -e . "$receipt_home/.fm-migration/bundle.json" > /dev/null 2>&1 \
    || fail "a killed receipt copy left the live home holding a half-written bundle: $(cat "$TMP_ROOT/receipt-crash.out")"
  [ "$(shasum -a 256 "$receipt_home/.fm-migration/bundle.json" | awk '{print $1}')" \
    = "$(cat "$receipt_home/.fm-migration/digest")" ] \
    || fail 'a killed receipt copy left the live bundle and its digest disagreeing'
  FM_HOME="$receipt_home" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
    "$REMOTE_ROOT/bin/fm-remote-home-provision.sh" --migration drop-work "$receipt_digest" \
    < "$TMP_ROOT/receipt-bundle.json" > "$TMP_ROOT/receipt-rerun.out" 2>&1 \
    || fail "the rerun after a killed receipt copy could not read the home: $(cat "$TMP_ROOT/receipt-rerun.out")"
  cmp -s "$TMP_ROOT/receipt.report" "$receipt_home/data/report/report.md" \
    || fail 'the rerun after a killed receipt copy did not land the newer record'
  cmp -s "$TMP_ROOT/receipt-bundle.json" "$receipt_home/.fm-migration/bundle.json" \
    || fail 'the converged rerun did not publish the bundle its digest names'
  [ "$(cat "$receipt_home/.fm-migration/digest")" = "$receipt_digest" ] \
    || fail 'the converged rerun did not publish its own receipt digest'
  pass 'a receipt copy killed part-way through never reaches the live receipt, and the next attempt converges'

  migration_source guard-work
  lock_session() {
    FM_HOME="$TMP_ROOT/source-guard-work" FM_STATE_OVERRIDE="$TMP_ROOT/source-guard-work/state" \
      bash -c 'exec -a fm-deck-chat bash "$0"' "$ROOT/bin/fm-lock.sh"
  }
  printf 'x=1\n' > "$TMP_ROOT/source-guard-work/config/x-mode.env"
  if migrate guard-work > "$TMP_ROOT/migrate.out" 2>&1; then fail 'migration accepted an unclassifiable config file'; fi
  assert_grep 'unclassified config: config/x-mode.env' "$TMP_ROOT/migrate.out" \
    "the refusal did not name the config file it could not carry: $(cat "$TMP_ROOT/migrate.out")"
  assert_absent "$TMP_ROOT/source-guard-work/.fm-home-migration" 'an unclassifiable config file froze the source'
  assert_absent "$PARENT/data/guard-work/migration" 'an unclassifiable config file left a migration journal'
  lock_session > "$TMP_ROOT/lock.out" 2>&1 || fail "the refused home can no longer start a session: $(cat "$TMP_ROOT/lock.out")"
  rm "$TMP_ROOT/source-guard-work/state/.lock" "$TMP_ROOT/source-guard-work/config/x-mode.env"
  # The same holds for a refusal that lands after the freeze: nothing has been
  # staged on the host yet, so the freeze and its journal are unwound.
  mkdir -p "$PARENT/state/guard-work.inbox"
  printf 'not a durable record\n' > "$PARENT/state/guard-work.inbox/scratch"
  if migrate guard-work > "$TMP_ROOT/migrate.out" 2>&1; then fail 'migration accepted an unclassified inbox artifact'; fi
  assert_grep 'unclassified inbox artifact: scratch' "$TMP_ROOT/migrate.out" \
    "the snapshot refusal did not name the artifact: $(cat "$TMP_ROOT/migrate.out")"
  assert_absent "$TMP_ROOT/migrated-guard-work" 'a refused migration provisioned the remote home'
  assert_absent "$TMP_ROOT/source-guard-work/.fm-home-migration" 'a refusal before any remote staging left the source frozen'
  assert_absent "$PARENT/data/guard-work/migration" 'a refusal before any remote staging retained its journal'
  assert_grep 'guard-work - Persistent responsibility (home:' "$PARENT/data/secondmates.md" 'a refused migration switched the route'
  lock_session > "$TMP_ROOT/lock.out" 2>&1 || fail "an unwound refusal left the home unable to start: $(cat "$TMP_ROOT/lock.out")"
  rm "$TMP_ROOT/source-guard-work/state/.lock" "$PARENT/state/guard-work.inbox/scratch"
  pass 'a local refusal names its cause and leaves the source unfrozen and startable'

  migration_source project-work direct-PR
  alpha_head=$(git -C "$TMP_ROOT/source-project-work/projects/alpha" rev-parse HEAD) \
    || fail 'source project clone has no commit to compare against'
  assert_present "$TMP_ROOT/source-project-work/projects/alpha/README.md" \
    'source project clone has no working tree to distinguish from a cloned one'
  printf 'uncommitted local edit\n' > "$TMP_ROOT/source-project-work/projects/alpha/scratch.txt"
  out=$(migrate project-work 2>&1) || fail "project migration failed: $out"
  assert_present "$TMP_ROOT/migrated-project-work/projects/alpha/README.md" \
    'the remote home did not clone the registered project origin'
  assert_absent "$TMP_ROOT/migrated-project-work/projects/alpha/scratch.txt" \
    'the local project working tree was copied instead of cloned from origin'
  migrated_head=$(git -C "$TMP_ROOT/migrated-project-work/projects/alpha" rev-parse HEAD) \
    || fail 'the cloned project has no commit'
  [ "$migrated_head" = "$alpha_head" ] \
    || fail "the cloned project does not carry the registered origin commit: $migrated_head vs $alpha_head"
  assert_present "$TMP_ROOT/source-project-work/projects/alpha/scratch.txt" \
    'migration disturbed the local project working tree'
  cmp -s "$TMP_ROOT/source-project-work/data/projects.md" "$TMP_ROOT/migrated-project-work/data/projects.md" \
    || fail 'the project registry did not survive migration byte-exact'
  pass 'migration clones registered project origins on the host and refuses a local-only project'
  echo 'ALL TESTS PASSED'
  exit 0
fi

REAL_GIT=$(command -v git)
cat > "$FAKEBIN/git" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = clone ] && [ "\${!#}" = "$TMP_ROOT/concurrent-home" ]; then
  printf 'clone\n' >> "$TMP_ROOT/provision-clones"
  if mkdir "$TMP_ROOT/provision-first" 2>/dev/null; then
    touch "$TMP_ROOT/provision.entered"
    while [ ! -f "$TMP_ROOT/provision.release" ]; do sleep 0.02; done
  fi
fi
exec "$REAL_GIT" "\$@"
SH
chmod +x "$FAKEBIN/git"
printf 'schema=fm-remote-home-provision.v1\nid_b64=%s\ncharter_b64=%s\nproject_count=0\n' \
  "$(printf ios | base64 | tr -d '\n')" \
  "$(printf 'Concurrent provisioning charter.\n' | base64 | tr -d '\n')" \
  > "$TMP_ROOT/provision.manifest"
PATH="$FAKEBIN:$PATH" FM_HOME="$TMP_ROOT/concurrent-home" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  "$REMOTE_ROOT/bin/fm-remote-home-provision.sh" < "$TMP_ROOT/provision.manifest" \
  > "$TMP_ROOT/provision-one.out" 2>&1 &
provision_one=$!
provision_wait=0
while [ ! -f "$TMP_ROOT/provision.entered" ]; do
  kill -0 "$provision_one" 2>/dev/null || fail "first provisioning attempt exited before cloning"
  provision_wait=$((provision_wait + 1))
  [ "$provision_wait" -le 250 ] || fail "first provisioning attempt never reached cloning"
  sleep 0.02
done
PATH="$FAKEBIN:$PATH" FM_HOME="$TMP_ROOT/concurrent-home" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  "$REMOTE_ROOT/bin/fm-remote-home-provision.sh" < "$TMP_ROOT/provision.manifest" \
  > "$TMP_ROOT/provision-two.out" 2>&1 &
provision_two=$!
sleep 0.2
[ "$(grep -cF clone "$TMP_ROOT/provision-clones")" -eq 1 ] \
  || fail "overlapping provisioning reached home classification concurrently"
touch "$TMP_ROOT/provision.release"
wait "$provision_one" || fail "first serialized provisioning attempt failed"
wait "$provision_two" || fail "reconciled provisioning attempt failed"
[ "$(cat "$TMP_ROOT/concurrent-home/.fm-secondmate-home")" = ios ] \
  || fail "serialized provisioning lost the published home"
[ "$(grep -cF clone "$TMP_ROOT/provision-clones")" -eq 1 ] \
  || fail "reconciled provisioning cloned the already-published home"
pass "overlapping remote home provisioning serializes through publication and rollback"
if [ "${FM_TEST_PROVISION_ONLY:-0}" = 1 ]; then
  echo "ALL TESTS PASSED"
  exit 0
fi

mkdir -p "$TMP_ROOT/seed-parent/data" "$TMP_ROOT/seed-parent/state"
FM_SECONDMATE_CHARTER='Failing seed charter.' FM_SECONDMATE_SCOPE='failed seed' \
  FM_FAKE_SSH_MODE=provision-block-fail seed_env "$ROOT/bin/fm-remote-home-seed.sh" \
  seed-fail remote-mac "$REMOTE_ROOT" "$TMP_ROOT/seed-fail-home" --no-projects \
  > "$TMP_ROOT/seed-fail.out" 2>&1 &
seed_fail_pid=$!
seed_wait=0
while [ ! -f "$TMP_ROOT/seed.entered" ]; do
  kill -0 "$seed_fail_pid" 2>/dev/null || fail "failing seed exited before remote provisioning"
  seed_wait=$((seed_wait + 1))
  [ "$seed_wait" -le 250 ] || fail "failing seed never reached remote provisioning"
  sleep 0.02
done
FM_SECONDMATE_CHARTER='Successful seed charter.' FM_SECONDMATE_SCOPE='successful seed' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-keep remote-mac "$REMOTE_ROOT" \
  "$TMP_ROOT/seed-keep-home" --no-projects > "$TMP_ROOT/seed-keep.out" 2>&1 &
seed_keep_pid=$!
sleep 0.2
kill -0 "$seed_keep_pid" 2>/dev/null || fail "competing seed bypassed the shared registry transaction"
touch "$TMP_ROOT/seed.release"
if wait "$seed_fail_pid"; then
  fail "known-failing seed unexpectedly succeeded"
fi
wait "$seed_keep_pid" || fail "serialized successful seed failed"
assert_no_grep '- seed-fail ' "$TMP_ROOT/seed-parent/data/secondmates.md" "failed seed route survived rollback"
assert_grep '- seed-keep ' "$TMP_ROOT/seed-parent/data/secondmates.md" "failed seed rollback removed a competing successful route"
assert_present "$TMP_ROOT/seed-keep-home/.fm-secondmate-home" "serialized seed lost its published remote home"
pass "remote seed rollback preserves serialized competing routes"

: > "$DOCTOR_LOG"
if FM_SECONDMATE_CHARTER='Unknown readiness charter.' FM_SECONDMATE_SCOPE='unknown readiness' \
  FM_FAKE_SSH_MODE=doctor-fix-unknown seed_env "$ROOT/bin/fm-remote-home-seed.sh" \
  seed-unknown remote-mac "$REMOTE_ROOT" "$TMP_ROOT/seed-unknown-home" --no-projects \
  > "$TMP_ROOT/seed-unknown.out" 2>&1; then
  fail "seeding claimed success after readiness repair completion became unknown"
fi
assert_grep 'remote readiness completion is unknown' "$TMP_ROOT/seed-unknown.out" \
  "unknown readiness did not report its distinct completion state"
assert_grep '- seed-unknown ' "$TMP_ROOT/seed-parent/data/secondmates.md" \
  "unknown readiness removed the registered route"
assert_present "$TMP_ROOT/seed-parent/data/seed-unknown/brief.md" \
  "unknown readiness removed the scaffolded brief"
assert_absent "$TMP_ROOT/seed-unknown-home" \
  "unknown readiness proceeded into remote home provisioning"
[ "$(cat "$DOCTOR_LOG")" = 'doctor-fix-unknown -
doctor-fix-unknown --fix' ] || fail "unknown readiness did not occur during the repair stage"$'\n'"$(cat "$DOCTOR_LOG")"
pass "unknown readiness preserves its route and brief for reconciliation"

# A host that cannot hold a durable second mate must be rejected by the
# readiness gate before any home is created on it, and the operator must get the
# gap text rather than a bare refusal.
: > "$DOCTOR_LOG"
if FM_SECONDMATE_CHARTER='Unready host charter.' FM_SECONDMATE_SCOPE='unready host' \
  FM_FAKE_SSH_MODE=doctor-human seed_env "$ROOT/bin/fm-remote-home-seed.sh" \
  seed-toolless remote-mac "$REMOTE_ROOT" "$TMP_ROOT/seed-toolless-home" --no-projects \
  > "$TMP_ROOT/seed-toolless.out" 2>&1; then
  fail "seeding proceeded against a host that is not ready for a remote second mate"
fi
assert_grep 'check gui-session=human:' \
  "$TMP_ROOT/seed-toolless.out" "the seed hid the remaining human gap"
assert_grep 'action: gui-session:' \
  "$TMP_ROOT/seed-toolless.out" "the seed hid the operator step that closes the gap"
assert_grep 'remote runtime preflight failed' "$TMP_ROOT/seed-toolless.out" \
  "the seed did not report the failing stage"
assert_absent "$TMP_ROOT/seed-toolless-home" "the seed provisioned a home despite a failing preflight"
assert_no_grep '- seed-toolless ' "$TMP_ROOT/seed-parent/data/secondmates.md" \
  "the refused route survived the preflight rollback"
assert_absent "$TMP_ROOT/seed-parent/data/seed-toolless/brief.md" \
  "the refused route left its scaffolded charter behind"
[ "$(cat "$DOCTOR_LOG")" = 'doctor-human -
doctor-human --fix
doctor-human -' ] || fail "the seed did not run the check, repair, re-check sequence"$'\n'"$(cat "$DOCTOR_LOG")"
pass "remote seeding checks, repairs, and re-checks readiness, then stops on a remaining gap"

# The same gate must accept a host whose only gaps were repairable.
: > "$DOCTOR_LOG"
rm -f "$TMP_ROOT/doctor.repaired"
out=$(FM_SECONDMATE_CHARTER='Repairable host charter.' FM_SECONDMATE_SCOPE='repairable host' \
  FM_FAKE_SSH_MODE=doctor-fixable seed_env "$ROOT/bin/fm-remote-home-seed.sh" \
  seed-repair remote-mac "$REMOTE_ROOT" "$TMP_ROOT/seed-repair-home" --no-projects 2>&1) \
  || fail "seeding refused a host whose gaps the repair closed"$'\n'"$out"
assert_present "$TMP_ROOT/seed-repair-home/.fm-secondmate-home" "the repaired host was never provisioned"
assert_grep '- seed-repair ' "$TMP_ROOT/seed-parent/data/secondmates.md" "the repaired route was not registered"
[ "$(cat "$DOCTOR_LOG")" = 'doctor-fixable -
doctor-fixable --fix
doctor-fixable -' ] || fail "the repaired seed did not re-check after its repair"$'\n'"$(cat "$DOCTOR_LOG")"
pass "remote seeding proceeds once the repair closes every gap"

# Seeding must not need a copy of the project in this home: firstmate names the
# origin it already resolved, the seed validates and transports it, and the
# primary project tree is left exactly as it was found.
projects_snapshot() { # <dir>
  local dir=$1 path
  (
    cd "$dir" 2>/dev/null || exit 0
    find . -print | LC_ALL=C sort | while IFS= read -r path; do
      if [ -f "$path" ] && [ ! -L "$path" ]; then
        printf '%s %s\n' "$path" "$(sha256_file "$path")"
      else
        printf '%s\n' "$path"
      fi
    done
  )
}
mkdir -p "$TMP_ROOT/seed-parent/projects"
fm_git_init_commit "$TMP_ROOT/seed-parent/projects/resident"
# Pin the bare origin's initial branch to the one fm_git_init_commit creates.
# Left to init.defaultBranch, its HEAD names a branch the push never creates on
# a host that still defaults to master, and cloning it checks out nothing.
git init -q --bare -b main "$TMP_ROOT/beta.git"
fm_git_init_commit "$TMP_ROOT/beta-src"
git -C "$TMP_ROOT/beta-src" remote add origin "file://$TMP_ROOT/beta.git"
git -C "$TMP_ROOT/beta-src" push -q -u origin HEAD
rm -rf "$TMP_ROOT/beta-src"
cat > "$TMP_ROOT/seed-parent/data/projects.md" <<'EOF'
- beta [direct-PR] - beta project (added 2026-08-06)
- delta [local-only] - delta project (added 2026-08-06)
EOF
BETA_ORIGIN="file://$TMP_ROOT/beta.git"
PROJECTS_BEFORE=$(projects_snapshot "$TMP_ROOT/seed-parent/projects")

if FM_SECONDMATE_CHARTER='Unsupplied origin charter.' FM_SECONDMATE_SCOPE='unsupplied origin' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-noorigin remote-mac "$REMOTE_ROOT" \
  "$TMP_ROOT/seed-noorigin-home" beta > "$TMP_ROOT/seed-noorigin.out" 2>&1; then
  fail "seeding an uncloned project with no origin claimed success"
fi
assert_grep 'pass beta=<origin-url>' "$TMP_ROOT/seed-noorigin.out" \
  "the refusal did not name how to supply the origin"
assert_absent "$TMP_ROOT/seed-noorigin-home" "the unresolvable origin still provisioned a remote home"

if FM_SECONDMATE_CHARTER='Unsafe origin charter.' FM_SECONDMATE_SCOPE='unsafe origin' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-unsafe remote-mac "$REMOTE_ROOT" \
  "$TMP_ROOT/seed-unsafe-home" 'beta=ext::git-upload-pack' \
  > "$TMP_ROOT/seed-unsafe.out" 2>&1; then
  fail "seeding accepted a remote-helper origin the remote host would execute"
fi
assert_grep 'not an accepted clone URL' "$TMP_ROOT/seed-unsafe.out" \
  "the unsafe-origin refusal did not name the reason"
assert_absent "$TMP_ROOT/seed-unsafe-home" "the unsafe origin still provisioned a remote home"

if FM_SECONDMATE_CHARTER='Local-only charter.' FM_SECONDMATE_SCOPE='local only' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-localonly remote-mac "$REMOTE_ROOT" \
  "$TMP_ROOT/seed-localonly-home" "delta=$BETA_ORIGIN" \
  > "$TMP_ROOT/seed-localonly.out" 2>&1; then
  fail "a supplied origin bypassed the local-only delivery-mode refusal"
fi
assert_grep 'is local-only and cannot be provisioned remotely' "$TMP_ROOT/seed-localonly.out" \
  "the local-only refusal did not name the registered mode"

if FM_SECONDMATE_CHARTER='Unregistered charter.' FM_SECONDMATE_SCOPE='unregistered' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-unregistered remote-mac "$REMOTE_ROOT" \
  "$TMP_ROOT/seed-unregistered-home" "gamma=$BETA_ORIGIN" \
  > "$TMP_ROOT/seed-unregistered.out" 2>&1; then
  fail "a supplied origin bypassed the project registry requirement"
fi
assert_grep 'has no registry record' "$TMP_ROOT/seed-unregistered.out" \
  "the unregistered-project refusal did not name the missing record"

out=$(FM_SECONDMATE_CHARTER='Own beta delivery on the build Mac.' \
  FM_SECONDMATE_SCOPE='beta delivery and validation' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-noclone remote-mac "$REMOTE_ROOT" \
  "$TMP_ROOT/seed-noclone-home" "beta=$BETA_ORIGIN" 2>&1) \
  || fail "seeding refused a registered project whose origin was supplied"$'\n'"$out"
assert_contains "$out" "home=remote-mac:$TMP_ROOT/seed-noclone-home" \
  "the no-clone seed did not report the host-qualified home"
assert_grep '- seed-noclone ' "$TMP_ROOT/seed-parent/data/secondmates.md" \
  "the no-clone seed did not register the remote route"
assert_present "$TMP_ROOT/seed-noclone-home/projects/beta/README.md" \
  "the remote host did not clone the supplied origin"
[ "$(git -C "$TMP_ROOT/seed-noclone-home/projects/beta" remote get-url origin)" = "$BETA_ORIGIN" ] \
  || fail "the remote clone did not come from the supplied origin"
assert_grep '- beta [direct-PR]' "$TMP_ROOT/seed-noclone-home/data/projects.md" \
  "the remote home did not publish the project's registered posture"
assert_absent "$TMP_ROOT/seed-parent/projects/beta" \
  "seeding cloned the project into the primary project tree"
[ "$(projects_snapshot "$TMP_ROOT/seed-parent/projects")" = "$PROJECTS_BEFORE" ] \
  || fail "seeding changed the primary project tree"
pass "remote seeding provisions a supplied origin without touching the primary project tree"

# The receiving host validates the origin itself rather than trusting whatever
# reached it, so a manifest naming an executable transport provisions nothing.
printf 'schema=fm-remote-home-provision.v1\nid_b64=%s\ncharter_b64=%s\nproject_count=1\nproject=%s|%s|%s|%s\n' \
  "$(printf unsafe-origin | base64 | tr -d '\n')" \
  "$(printf 'Unsafe origin manifest charter.\n' | base64 | tr -d '\n')" \
  "$(printf beta | base64 | tr -d '\n')" \
  "$(printf 'ext::git-upload-pack' | base64 | tr -d '\n')" \
  "$(printf -- '- beta [direct-PR] - beta project (added 2026-08-06)' | base64 | tr -d '\n')" \
  "$(printf direct-PR | base64 | tr -d '\n')" \
  > "$TMP_ROOT/unsafe-origin.manifest"
if FM_HOME="$TMP_ROOT/unsafe-origin-home" FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  "$REMOTE_ROOT/bin/fm-remote-home-provision.sh" < "$TMP_ROOT/unsafe-origin.manifest" \
  > "$TMP_ROOT/unsafe-origin.out" 2>&1; then
  fail "remote provisioning accepted an origin the transport had not validated"
fi
assert_grep 'not an accepted clone URL' "$TMP_ROOT/unsafe-origin.out" \
  "remote provisioning did not name the rejected origin"
assert_absent "$TMP_ROOT/unsafe-origin-home" "the rejected manifest left a remote home behind"
pass "remote provisioning re-validates a supplied origin at the receiving host"

# Firstmate is a shared template, so seeding must carry a project origin from any
# forge or host, not a privileged one. These four URL shapes have to survive the
# parent's validation, the manifest, the transport, and the receiving host's own
# validation, and arrive at git unchanged. A fixture resolver records the exact
# clone source the remote side hands to git and then serves it from a local bare
# repository, because an offline run cannot reach bitbucket.org itself.
FORGE_CLONE_LOG="$TMP_ROOT/forge-clone.log"
FORGE_ORIGIN_MAP="$TMP_ROOT/forge-origin.map"
: > "$FORGE_CLONE_LOG"
: > "$FORGE_ORIGIN_MAP"
forge_project() { # <project> <origin-url>
  local project=$1 origin=$2 tab
  tab=$(printf '\t')
  fm_git_init_commit "$TMP_ROOT/forge-src-$project"
  printf 'served from %s\n' "$origin" > "$TMP_ROOT/forge-src-$project/ORIGIN.txt"
  git -C "$TMP_ROOT/forge-src-$project" add ORIGIN.txt
  git -C "$TMP_ROOT/forge-src-$project" \
    -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm origin
  git clone --quiet --bare "$TMP_ROOT/forge-src-$project" "$TMP_ROOT/forge-$project.git"
  rm -rf "$TMP_ROOT/forge-src-$project"
  printf '%s%s%s\n' "$origin" "$tab" "$TMP_ROOT/forge-$project.git" >> "$FORGE_ORIGIN_MAP"
  printf -- '- %s [direct-PR] - %s project (added 2026-08-06)\n' "$project" "$project" \
    >> "$TMP_ROOT/seed-parent/data/projects.md"
}
forge_project bitbucket-app 'https://bitbucket.org/team/bitbucket-app.git'
forge_project ghe-app 'https://git.example.com/org/ghe-app.git'
forge_project gitlab-app 'ssh://git@gitlab.self.hosted:2222/group/subgroup/gitlab-app.git'
forge_project scp-app 'git@host.internal:group/scp-app.git'

cat > "$REMOTE_ROOT/bin/git" <<SH
#!/usr/bin/env bash
# Fixture origin resolver for the remote side: record the clone source exactly as
# the production code hands it to git, then serve any recorded URL from a local
# bare repository so the run stays offline. Everything else is real git.
set -u
if [ "\${1:-}" = clone ]; then
  printf '%s\n' "\$*" >> '$FORGE_CLONE_LOG'
  args=()
  for arg in "\$@"; do
    replacement=\$(awk -v k="\$arg" -F'\t' '\$1 == k { print \$2; exit }' '$FORGE_ORIGIN_MAP' 2>/dev/null)
    if [ -n "\$replacement" ]; then args+=("\$replacement"); else args+=("\$arg"); fi
  done
  exec '$REAL_GIT' "\${args[@]}"
fi
exec '$REAL_GIT' "\$@"
SH
chmod +x "$REMOTE_ROOT/bin/git"

FORGE_HOME="$TMP_ROOT/seed-forge-home"
out=$(FM_SECONDMATE_CHARTER='Own delivery for projects hosted anywhere.' \
  FM_SECONDMATE_SCOPE='multi-forge delivery' \
  seed_env "$ROOT/bin/fm-remote-home-seed.sh" seed-forge remote-mac "$REMOTE_ROOT" \
  "$FORGE_HOME" \
  'bitbucket-app=https://bitbucket.org/team/bitbucket-app.git' \
  'ghe-app=https://git.example.com/org/ghe-app.git' \
  'gitlab-app=ssh://git@gitlab.self.hosted:2222/group/subgroup/gitlab-app.git' \
  'scp-app=git@host.internal:group/scp-app.git' 2>&1) \
  || fail "seeding refused origins hosted outside GitHub"$'\n'"$out"

while IFS="$(printf '\t')" read -r forge_origin _; do
  [ -n "$forge_origin" ] || continue
  assert_grep "$forge_origin" "$FORGE_CLONE_LOG" \
    "the remote host did not clone from the supplied origin $forge_origin"
done < "$FORGE_ORIGIN_MAP"
for forge_project_name in bitbucket-app ghe-app gitlab-app scp-app; do
  assert_present "$FORGE_HOME/projects/$forge_project_name/.git" \
    "the remote home has no clone for $forge_project_name"
  assert_grep "$forge_project_name" "$FORGE_HOME/data/projects.md" \
    "the remote registry omitted $forge_project_name"
  assert_absent "$TMP_ROOT/seed-parent/projects/$forge_project_name" \
    "seeding $forge_project_name cloned it into the primary project tree"
done
# Each clone must carry its own origin's content, so one shared fixture repo
# cannot make a mismatched route look routed.
[ "$(cat "$FORGE_HOME/projects/bitbucket-app/ORIGIN.txt")" = \
  'served from https://bitbucket.org/team/bitbucket-app.git' ] \
  || fail "the bitbucket route did not clone its own origin"
[ "$(cat "$FORGE_HOME/projects/scp-app/ORIGIN.txt")" = \
  'served from git@host.internal:group/scp-app.git' ] \
  || fail "the scp-like route did not clone its own origin"
[ "$(projects_snapshot "$TMP_ROOT/seed-parent/projects")" = "$PROJECTS_BEFORE" ] \
  || fail "seeding non-GitHub projects changed the primary project tree"
assert_grep '- seed-forge ' "$TMP_ROOT/seed-parent/data/secondmates.md" \
  "the multi-forge route was not registered"

rm -f "$REMOTE_ROOT/bin/git"
[ -z "$(git -C "$REMOTE_ROOT" status --porcelain)" ] \
  || fail "the fixture origin resolver was left behind in the remote code root"
pass "seeding carries bitbucket, self-hosted, and scp-like origins through to the remote clone"

# Provision and register the remote route from the captain-facing primary.
out=$(FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
  FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" alpha)
assert_contains "$out" "home=remote-mac:$REMOTE_HOME" "remote seed did not report the host-qualified home"
assert_grep 'host: remote-mac; root:' "$PARENT/data/secondmates.md" "registry did not record the remote host dimension"
assert_present "$REMOTE_HOME/.fm-secondmate-home" "remote provisioning did not publish the identity marker"
assert_present "$REMOTE_HOME/projects/alpha/.git" "remote provisioning did not clone the project on that host"
assert_grep "$REMOTE_HOME/state/parent-replies.status" "$REMOTE_HOME/data/charter.md" "remote charter did not use its append-only reply log"
assert_no_grep "$PARENT/state/ios.status" "$REMOTE_HOME/data/charter.md" "remote charter retained the inaccessible local status path"
# The steering inbox the charter names must be the one on THIS host, not the
# parent's state path: a remote steer is delivered host-locally, so a mate that
# navigates to the path its own brief names would otherwise find nothing.
assert_grep "durable message files in '$REMOTE_HOME/state/parent-route/ios.inbox'." "$REMOTE_HOME/data/charter.md" "remote charter did not name its host-local steering inbox"
assert_grep "mv '$REMOTE_HOME/state/parent-route/ios.inbox'/NNN.msg '$REMOTE_HOME/state/parent-route/ios.inbox'/handled/" "$REMOTE_HOME/data/charter.md" "remote charter's acknowledgement command did not name its host-local steering inbox"
assert_no_grep "$PARENT/state/ios.inbox" "$REMOTE_HOME/data/charter.md" "remote charter retained the inaccessible local steering inbox path"
if FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
  FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios remote-mac "$REMOTE_ROOT" "$TMP_ROOT/other-home" alpha \
  >/dev/null 2>&1; then
  fail "remote seed allowed an existing id to move to another home"
fi
assert_grep "home: $REMOTE_HOME" "$PARENT/data/secondmates.md" "refused remote reassignment changed the durable route"
# The home is cloned from that host's own Firstmate copy, which would leave the
# copy's PATH as the home's delivery route for the firstmate repo itself: a
# validated firstmate change made there would be pushed into that directory and
# never open a pull request, with the absent PR as the only symptom. It must end
# up on the route the code root delivers to.
[ "$(git -C "$REMOTE_HOME" remote get-url origin)" = "$REMOTE_FORGE_ROUTE" ] \
  || fail "the remote home delivers firstmate changes to $(git -C "$REMOTE_HOME" remote get-url origin), not the route its code root uses"
pass "remote seed registers the route and provisions the whole home and project clone on that host"

PROTOCOL_HOME="$TMP_ROOT/protocol-home"
mkdir -p "$PROTOCOL_HOME/config" "$PROTOCOL_HOME/data" "$PROTOCOL_HOME/state"
printf 'complete inherited payload\n' > "$TMP_ROOT/inherit-complete"
inherit_bytes=$(LC_ALL=C wc -c < "$TMP_ROOT/inherit-complete" | tr -d ' ')
inherit_hash=$(sha256_file "$TMP_ROOT/inherit-complete")
if printf 'complete' | FM_HOME="$PROTOCOL_HOME" "$REMOTE_ROOT/bin/fm-remote-inherit.sh" \
  put config/crew-harness "$inherit_bytes" "$inherit_hash" 1 >/dev/null 2>&1; then
  fail "remote inheritance published a truncated payload"
fi
assert_absent "$PROTOCOL_HOME/config/crew-harness" "truncated inheritance published a destination"
FM_HOME="$PROTOCOL_HOME" "$REMOTE_ROOT/bin/fm-remote-inherit.sh" \
  put config/crew-harness "$inherit_bytes" "$inherit_hash" 2 \
  < "$TMP_ROOT/inherit-complete" >/dev/null
printf 'stale inherited payload\n' > "$TMP_ROOT/inherit-stale"
inherit_stale_bytes=$(LC_ALL=C wc -c < "$TMP_ROOT/inherit-stale" | tr -d ' ')
inherit_stale_hash=$(sha256_file "$TMP_ROOT/inherit-stale")
if FM_HOME="$PROTOCOL_HOME" "$REMOTE_ROOT/bin/fm-remote-inherit.sh" \
  put config/crew-harness "$inherit_stale_bytes" "$inherit_stale_hash" 1 \
  < "$TMP_ROOT/inherit-stale" >/dev/null 2>&1; then
  fail "remote inheritance accepted a superseded payload generation"
fi
cmp -s "$TMP_ROOT/inherit-complete" "$PROTOCOL_HOME/config/crew-harness" \
  || fail "superseded inheritance replaced the current payload"
pass "remote inheritance rejects incomplete and superseded payload generations"

# Add one local route to prove mixed fleets remain parseable and projected.
mkdir -p "$LOCAL_HOME/data" "$LOCAL_HOME/state" "$LOCAL_HOME/config" "$LOCAL_HOME/projects" "$LOCAL_HOME/bin"
printf 'local\n' > "$LOCAL_HOME/.fm-secondmate-home"
printf 'fixture\n' > "$LOCAL_HOME/AGENTS.md"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LOCAL_HOME/data/backlog.md"
cat >> "$PARENT/data/secondmates.md" <<EOF
- local - Local delivery (home: $LOCAL_HOME; scope: local work; projects: alpha; added 2026-08-02)
EOF
remote_env "$ROOT/bin/fm-home-seed.sh" validate >/dev/null || fail "mixed local and remote registry validation failed"
pass "mixed local and remote routes validate without migration"

# Launch on the remote home's own configured backend. Parent metadata records
# host placement separately from that backend and arms the reply source.
printf 'deck\n' > "$PARENT/config/crew-harness"
printf 'deck codex/gpt-6-luna\n' > "$PARENT/config/secondmate-harness"
launches_before_inherit=$(remote_agent_count ios)
if FM_FAKE_SSH_MODE=inherit-partial remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate \
  > "$TMP_ROOT/spawn-inherit-partial.out" 2>&1; then
  fail "remote spawn launched after ambiguous partial inheritance"
fi
launches_after_inherit=$(remote_agent_count ios)
[ "$launches_before_inherit" -eq "$launches_after_inherit" ] \
  || fail "remote spawn reached launch after ambiguous partial inheritance"
assert_absent "$PARENT/state/ios.meta" "failed remote inheritance published launch metadata"
out=$(remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate)
assert_contains "$out" 'remote=remote-mac backend=stream' "remote spawn did not report separate host and backend dimensions"
assert_grep 'remote_host=remote-mac' "$PARENT/state/ios.meta" "parent metadata omitted the remote host"
assert_grep 'remote_backend=stream' "$PARENT/state/ios.meta" "parent metadata omitted the remote-local backend"
assert_grep "remote_stream_hub=$HUB_URL" "$PARENT/state/ios.meta" "parent metadata did not record the hub the agent publishes to"
assert_grep "remote_target=$(sed -n 's/^window=//p' "$REMOTE_HOME/state/parent-route/ios.meta")" "$PARENT/state/ios.meta" \
  "parent metadata does not name the endpoint the host recorded"
assert_grep 'backend=stream' "$REMOTE_HOME/state/parent-route/ios.meta" "remote metadata did not record its stream endpoint"
assert_no_grep "$HUB_TOKEN" "$PARENT/state/ios.meta" "the parent record carries the hub credential"
[ "$(remote_agent_count ios)" = 1 ] || fail "remote launch did not run exactly one agent for the mate"
assert_grep 'window=remote:ios' "$PARENT/state/ios.meta" "parent metadata pretended the endpoint was local"
assert_present "$PARENT/state/procevent/remote-reply-ios.source" "remote spawn did not arm its reply source"
publish_healthy_watcher_identity "$PARENT/state" "$PARENT" "$ROOT/bin/fm-watch.sh"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail "remote endpoint was not projected alive from its own host"
# The delivery observation runs on the mate's own host: busy or idle are both
# answers from its endpoint, while unknown would mean it never read it.
observed=$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh observe ios)
case "$observed" in
  busy|idle|fallback-idle) ;;
  *) fail "remote endpoint delivery observation did not execute on its own host: $observed" ;;
esac
pass "remote spawn launches on the remote-local backend and records a host-qualified route"
grep -Fx 'model=codex/gpt-6-luna' "$PARENT/state/ios.meta" >/dev/null \
  || fail "configured exact model did not reach parent metadata"
grep -Fx 'model=codex/gpt-6-luna' "$REMOTE_HOME/state/parent-route/ios.meta" >/dev/null \
  || fail "configured exact model did not reach host launch metadata"
wait_turn_with codex/gpt-6-luna || fail "configured exact model did not reach the remote agent's turns"
pass "remote configured exact model launches without an undefined resolver"
printf 'Configured-model launch output:\n%s\n' "$out"
remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh route ios

# Stop the remote endpoint through its backend, then let the ordinary startup
# liveness owner recover it through the parent spawn path with a configured
# chain. The host transport and terminal are the existing deterministic rig;
# the spawn, bootstrap, host-local control and replacement processes are real.
stop_model_endpoint() {
  local target state
  target=$(sed -n 's/^window=//p' "$REMOTE_HOME/state/parent-route/ios.meta")
  host_backend "$REMOTE_HOME" fm_backend_kill stream "$target" >/dev/null \
    || fail "could not stop the remote model endpoint"
  # The kill returns once the hub took the close; the agent exits a beat later,
  # so read the state until it settles rather than once.
  local i=0
  while :; do
    state=$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)
    case "$state" in dead|missing) break ;; esac
    [ "$i" -lt 30 ] || fail "the remote endpoint was not stopped before recovery: $state"
    i=$((i + 1))
    sleep 0.5
  done
  # The hub frees the fm-ios label only once the endpoint is closed; a
  # relaunch before that is refused as a duplicate label.
  i=0
  while [ -n "$(open_mate_endpoints)" ]; do
    [ "$i" -lt 100 ] || fail "fm-ios endpoints still open after stopping $target: $(open_mate_endpoints | tr '\n' ' ')
$(mate_close_diagnostics)"
    i=$((i + 1))
    sleep 0.1
  done
}
mate_close_diagnostics() {
  curl -sS -m 10 --config <(printf 'header = "Authorization: Bearer %s"\n' "$HUB_TOKEN") "$HUB_URL/v1/tasks" \
    | jq -c '.tasks[] | select(.label == "fm-ios")' 2>&1
  ps -eo pid,ppid,pgid,sid,stat,args 2>/dev/null | awk '/fm-stream-agent|deck|fm-deck/ && !/awk/'
}
open_mate_endpoints() {
  curl -fsS -m 10 --config <(printf 'header = "Authorization: Bearer %s"\n' "$HUB_TOKEN") \
    "$HUB_URL/v1/tasks" \
    | jq -r '.tasks[] | select(.label == "fm-ios" and .closed_at == null) | .endpoint_id'
}
# A relaunch returns once the endpoint took the launch line; the agent starts
# a beat later.
mate_alive_soon() {
  local i=0
  until [ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ]; do
    [ "$i" -lt 30 ] || return 1
    i=$((i + 1))
    sleep 0.5
  done
}
stop_model_endpoint
printf 'deck codex/gpt-6-luna,codex/gpt-6-luna-fallback\n' > "$PARENT/config/secondmate-harness"
model_boot=$(remote_env "$ROOT/bin/fm-bootstrap.sh" 2>&1)
assert_not_contains "$model_boot" 'command not found' "configured chain recovery crashed before launch"
mate_alive_soon || fail "startup did not recover the stopped remote agent with a configured chain: $model_boot"
grep -Fx 'model=codex/gpt-6-luna' "$PARENT/state/ios.meta" >/dev/null \
  || fail "recovery did not publish the chain head"
assert_present "$PARENT/state/model-chain/secondmate.state" "recovery did not materialize the configured chain lane"
grep -Fx 'model=codex/gpt-6-luna' "$REMOTE_HOME/state/parent-route/ios.meta" >/dev/null \
  || fail "recovery did not launch the chain head on the host"
pass "startup recovers a stopped remote secondmate on the configured chain head"
printf 'Stopped-agent recovery output:\n%s\n' "$model_boot"
remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh route ios

# Seed the shared lane's public cooldown state directly: this check owns
# launch selection, not the separate task-to-lane refusal-recording policy.
FM_HOME="$PARENT" bash -c '. "$1/bin/fm-model-chain-lib.sh";
  fm_model_chain_record_refusal "$2/state/model-chain/secondmate.state" "$3" "$(date +%s)"' \
  _ "$ROOT" "$PARENT" codex/gpt-6-luna || fail "could not seed the head cooldown"
stop_model_endpoint
model_fall=$(remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1) \
  || fail "remote chain fallback launch failed: $model_fall"
assert_contains "$model_fall" 'chain skip: codex/gpt-6-luna' "remote fallback did not disclose the cooled-down head"
assert_contains "$model_fall" 'selected codex/gpt-6-luna-fallback' "remote fallback did not select its ready tail"
grep -Fx 'model=codex/gpt-6-luna-fallback' "$PARENT/state/ios.meta" >/dev/null \
  || fail "fallback did not reach parent metadata"
grep -Fx 'model=codex/gpt-6-luna-fallback' "$REMOTE_HOME/state/parent-route/ios.meta" >/dev/null \
  || fail "fallback did not reach the host launch"
wait_turn_with codex/gpt-6-luna-fallback || fail "fallback did not reach the remote agent's turns"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail "the fallback left no live remote replacement"
pass "a remote recovery skips a refused head and launches its configured tail"
printf 'Cooldown fallback output:\n%s\n' "$model_fall"
remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh route ios

FM_HOME="$PARENT" bash -c '. "$1/bin/fm-model-chain-lib.sh";
  fm_model_chain_record_refusal "$2/state/model-chain/secondmate.state" "$3" "$(date +%s)"' \
  _ "$ROOT" "$PARENT" codex/gpt-6-luna-fallback || fail "could not seed the tail cooldown"
cp "$PARENT/state/ios.meta" "$TMP_ROOT/model-before-exhaustion.meta"
model_launches=$(remote_agent_count ios)
if model_exhaust=$(remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1); then
  fail "an exhausted remote model chain launched: $model_exhaust"
fi
assert_contains "$model_exhaust" 'model chain exhausted' "remote exhaustion did not explain its refusal"
cmp -s "$PARENT/state/ios.meta" "$TMP_ROOT/model-before-exhaustion.meta" \
  || fail "remote exhaustion changed the preserved route"
[ "$(remote_agent_count ios)" = "$model_launches" ] \
  || fail "remote exhaustion created a new endpoint"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail "remote exhaustion stopped the existing agent"
pass "an exhausted remote chain refuses without launching or changing the existing route"
printf 'Exhausted-chain refusal output:\n%s\n' "$model_exhaust"
# Subsequent lifecycle cases retain their original default-model posture.
printf 'deck\n' > "$PARENT/config/secondmate-harness"

# A host record whose window does not name its recorded endpoint is refused by
# every verb before the adapter is asked anything, and the live agent and both
# records are left exactly as they were.
remote_route_meta="$REMOTE_HOME/state/parent-route/ios.meta"
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-before-mismatch.meta"
live_target=$(sed -n 's/^window=//p' "$remote_route_meta")
awk -v t="${live_target%%:*}:ffffffffffffffffffffffffffffffff" '
  /^window=/ { print "window=" t; next }
  { print }
' "$TMP_ROOT/remote-ios-before-mismatch.meta" > "$remote_route_meta"
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-mismatched.meta"
turns_before_mismatch=$(wc -l < "$TURNS" | tr -d ' ')
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios 2>/dev/null)" = unverified ] \
  || fail "mismatched remote endpoint metadata was not classified unverified"
if remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh route ios >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh send ios probe >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh key ios Enter >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh capture ios >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh observe ios >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh retire ios --force >/dev/null 2>&1 \
  || remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh launch ios deck - - stream >/dev/null 2>&1; then
  fail "mismatched remote endpoint metadata remained operational"
fi
cmp -s "$TMP_ROOT/remote-ios-mismatched.meta" "$remote_route_meta" \
  || fail "a refused verb rewrote the mismatched endpoint metadata"
assert_present "$REMOTE_HOME" "refused retirement removed the remote home"
[ "$(remote_agent_count ios)" = 1 ] || fail "a refused verb started or stopped an agent"
[ "$(wc -l < "$TURNS" | tr -d ' ')" = "$turns_before_mismatch" ] || fail "a refused verb reached the live agent"
mv -f "$TMP_ROOT/remote-ios-before-mismatch.meta" "$remote_route_meta"
pass "mismatched remote endpoints fail closed before backend access"

cp "$PARENT/state/ios.meta" "$TMP_ROOT/parent-ios-before-nonstream.meta"
cp "$PARENT/data/secondmates.md" "$TMP_ROOT/registry-before-nonstream.md"
set +e
FM_FAKE_SSH_MODE=launch-nonstream-route remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate \
  > "$TMP_ROOT/spawn-nonstream-route.out" 2>&1
nonstream_parent_rc=$?
set -e
[ "$nonstream_parent_rc" -ne 0 ] || fail "parent accepted a non-stream remote launch route"
assert_grep "remote launch returned backend 'tmux', expected stream" "$TMP_ROOT/spawn-nonstream-route.out" \
  "parent refusal did not name the returned remote backend"
cmp -s "$TMP_ROOT/parent-ios-before-nonstream.meta" "$PARENT/state/ios.meta" \
  || fail "parent rewrote its endpoint metadata after a non-stream route refusal"
cmp -s "$TMP_ROOT/registry-before-nonstream.md" "$PARENT/data/secondmates.md" \
  || fail "parent removed or changed the registry route after a non-stream route refusal"

cp "$remote_route_meta" "$TMP_ROOT/remote-ios-before-legacy.meta"
cat > "$remote_route_meta" <<EOF
window=firstmate:fm-ios
worktree=$REMOTE_HOME
project=$REMOTE_ROOT
harness=deck
kind=secondmate
backend=tmux
EOF
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-legacy-before-refusal.meta"
set +e
remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh launch ios deck - - stream \
  > "$TMP_ROOT/legacy-refusal.out" 2>&1
legacy_rc=$?
set -e
[ "$legacy_rc" -ne 0 ] || fail "remote control relaunched over a record left on a retired backend"
assert_grep "recorded on the retired 'tmux' backend" "$TMP_ROOT/legacy-refusal.out" \
  "remote refusal did not name the endpoint's retired backend"
printf -v retirement_command 'FM_HOME=%q FM_ROOT_OVERRIDE=%q FM_STATE_OVERRIDE=%q FM_DATA_OVERRIDE=%q FM_CONFIG_OVERRIDE=%q %q %q' \
  "$REMOTE_ROOT" "$REMOTE_ROOT" "$REMOTE_HOME/state/parent-route" "$REMOTE_HOME/data/.parent-route" \
  "$REMOTE_HOME/config" "$REMOTE_ROOT/bin/fm-retire-endpoint.sh" ios
assert_contains "$(cat "$TMP_ROOT/legacy-refusal.out")" "retire the record on this host with $retirement_command" \
  "remote refusal printed a retirement command that cannot reach the parent-route record"
cmp -s "$TMP_ROOT/remote-ios-legacy-before-refusal.meta" "$remote_route_meta" \
  || fail "remote refusal changed the legacy endpoint metadata"
cmp -s "$TMP_ROOT/registry-before-nonstream.md" "$PARENT/data/secondmates.md" \
  || fail "remote legacy refusal removed or changed the registry route"
mv -f "$TMP_ROOT/remote-ios-before-legacy.meta" "$remote_route_meta"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail "the refusals disturbed the live remote agent"
pass "non-stream remote routes and records on a retired backend are refused without changing either route"

cp "$remote_route_meta" "$TMP_ROOT/remote-ios-before-unconfirmed-kill.meta"
cp "$REMOTE_HOME/config/stream-hub" "$TMP_ROOT/remote-hub-before-unconfirmed-kill"
cp "$REMOTE_HOME/config/stream-token" "$TMP_ROOT/remote-token-before-unconfirmed-kill"
{
  fm_test_stream_task "$REMOTE_HOME/state/parent-route" ios
  printf 'harness=deck\nkind=secondmate\nworktree=%s\nproject=%s\n' "$REMOTE_HOME" "$REMOTE_ROOT"
} > "$remote_route_meta"
unconfirmed_target=$(fm_test_stream_target_of "$REMOTE_HOME/state/parent-route" ios)
fm_test_fake_stream_foreground "$unconfirmed_target" bash
fm_test_fake_stream_set "$unconfirmed_target" '{"kill_undelivered": true}'
printf '%s\n' "$FM_TEST_STREAM_URL" > "$REMOTE_HOME/config/stream-hub"
printf '%s\n' "$FM_STREAM_TOKEN" > "$REMOTE_HOME/config/stream-token"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = dead ] \
  || fail 'the unconfirmed-kill fixture is not an agent-less endpoint'
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-unconfirmed-kill.meta"
fm_test_fake_stream_endpoints | jq -S '.endpoints | sort_by(.endpoint_id)' > "$TMP_ROOT/endpoints-before-unconfirmed-kill.json"
turns_before_unconfirmed_kill=$(wc -l < "$TURNS" | tr -d ' ')
if remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh launch ios deck - - stream \
  > "$TMP_ROOT/unconfirmed-kill.out" 2>&1; then
  fail 'remote launch replaced an endpoint whose kill was not acknowledged'
fi
assert_grep 'was not confirmed gone, so this launch would risk a duplicate' "$TMP_ROOT/unconfirmed-kill.out" \
  'remote launch did not explain the unconfirmed kill refusal'
cmp -s "$TMP_ROOT/remote-ios-unconfirmed-kill.meta" "$remote_route_meta" \
  || fail 'unconfirmed kill changed the host endpoint metadata'
cmp -s "$TMP_ROOT/parent-ios-before-nonstream.meta" "$PARENT/state/ios.meta" \
  || fail 'unconfirmed kill changed the parent endpoint metadata'
fm_test_fake_stream_endpoints | jq -S '.endpoints | sort_by(.endpoint_id)' > "$TMP_ROOT/endpoints-after-unconfirmed-kill.json"
cmp -s "$TMP_ROOT/endpoints-before-unconfirmed-kill.json" "$TMP_ROOT/endpoints-after-unconfirmed-kill.json" \
  || fail 'unconfirmed kill stopped, replaced, or steered a fake endpoint'
[ "$(remote_agent_count ios)" = 1 ] || fail 'unconfirmed kill started or stopped a real agent'
[ "$(wc -l < "$TURNS" | tr -d ' ')" = "$turns_before_unconfirmed_kill" ] \
  || fail 'unconfirmed kill launched a replacement turn'
fm_test_fake_stream_set "$unconfirmed_target" '{"forget": true}'
mv -f "$TMP_ROOT/remote-ios-before-unconfirmed-kill.meta" "$remote_route_meta"
mv -f "$TMP_ROOT/remote-hub-before-unconfirmed-kill" "$REMOTE_HOME/config/stream-hub"
mv -f "$TMP_ROOT/remote-token-before-unconfirmed-kill" "$REMOTE_HOME/config/stream-token"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail 'unconfirmed kill refusal disturbed the live remote agent'
pass "an agent-less remote endpoint whose kill nothing confirmed is refused, not relaunched onto"

rm -f "$TMP_ROOT/inherit.entered" "$TMP_ROOT/inherit.release" "$TMP_ROOT/inherit.payload"
cat > "$PARENT/data/captain-shared.md" <<'EOF'
# Shared captain preferences
This file is main-authoritative and maintained by the main firstmate.
It is read-only in secondmate homes and must not be edited there.
Changes return through a marked status document pointer.
stale spawn preference
EOF
FM_FAKE_SSH_MODE=inherit-block remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate \
  > "$TMP_ROOT/spawn-concurrent.out" 2>&1 &
spawn_concurrent=$!
spawn_inherit_wait=0
# Earlier inherited files traverse the worker before captain-shared.md, so give
# a loaded portable runner 30 seconds to reach this deliberately blocked write.
while [ ! -f "$TMP_ROOT/inherit.entered" ]; do
  kill -0 "$spawn_concurrent" 2>/dev/null || fail "remote spawn exited before its blocked inheritance write"
  spawn_inherit_wait=$((spawn_inherit_wait + 1))
  [ "$spawn_inherit_wait" -le 1500 ] || fail "remote spawn never reached its blocked inheritance write"
  sleep 0.02
done
cat > "$PARENT/data/captain-shared.md" <<'EOF'
# Shared captain preferences
This file is main-authoritative and maintained by the main firstmate.
It is read-only in secondmate homes and must not be edited there.
Changes return through a marked status document pointer.
current post-spawn preference
EOF
remote_env "$ROOT/bin/fm-config-push.sh" > "$TMP_ROOT/spawn-concurrent-push.out" 2>&1 &
spawn_config_push=$!
sleep 0.2
kill -0 "$spawn_config_push" 2>/dev/null \
  || fail "config push bypassed the active remote spawn inheritance transaction"
touch "$TMP_ROOT/inherit.release"
wait "$spawn_concurrent" || fail "serialized remote spawn failed"
wait "$spawn_config_push" || fail "config push failed after serialized remote spawn"$'\n'"$(cat "$TMP_ROOT/spawn-concurrent-push.out")"
[ "$(tail -1 "$REMOTE_HOME/data/captain-shared.md")" = 'current post-spawn preference' ] \
  || fail "stale spawn inheritance overwrote later config convergence"
pass "remote spawn serializes inheritance through launch publication"

# A normal marked parent request traverses SSH as a durable remote inbox
# record plus a rung doorbell - the payload is never typed into the pane. An
# ambiguous transport (the remote leg executed, then ssh exit 255) is retried
# identically once, and the idempotent remote write lands both executions on
# ONE record; the send reports itself unconfirmed with a correlation-preserving
# resend command, and the expectation resolves only after the correlated remote log
# delta is ingested.
ssh_before_send=$(cat "$SSH_COUNT")
records_before_send=$(find "$REMOTE_HOME/state/parent-route/ios.inbox" -maxdepth 1 -name '*.msg' 2>/dev/null | wc -l | tr -d ' ')
set +e
FM_FAKE_SSH_MODE=ambiguous remote_env "$ROOT/bin/fm-send.sh" fm-ios \
  'report the build result' > "$TMP_ROOT/send.out" 2> "$TMP_ROOT/send.err"
send_rc=$?
set -e
[ "$send_rc" -ne 0 ] || fail "ambiguous remote send claimed definite delivery"
assert_grep 'Only the correlation-reusing resend below is idempotent' "$TMP_ROOT/send.err" "ambiguous remote send did not state the correlation-preserving resend boundary"
assert_no_grep 'do not resend' "$TMP_ROOT/send.err" "ambiguous remote send kept the deleted do-not-resend trap"
ssh_after_send=$(cat "$SSH_COUNT")
[ "$ssh_after_send" -eq $((ssh_before_send + 2)) ] \
  || fail "ambiguous remote send was not retried exactly once (ssh calls: $((ssh_after_send - ssh_before_send)))"
records_after_send=$(find "$REMOTE_HOME/state/parent-route/ios.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')
[ "$records_after_send" -eq $((records_before_send + 1)) ] \
  || fail "the retried remote steer did not dedup onto one new record, went $records_before_send -> $records_after_send"
wait_turn_with 'Firstmate instruction waiting' || fail "the remote doorbell never rang"
[ "$(turns_with 'report the build result')" = 0 ] || fail "the steer payload was typed into the remote agent"
CORR=$(newest_remote_inbox_corr)
[ -n "$CORR" ] || fail "remote send did not carry a correlation token"
# Tie the charter's named inbox to the directory the real steer just wrote into,
# so the path assertion above cannot drift away from actual delivery.
delivered_record=$(find "$REMOTE_HOME/state/parent-route/ios.inbox" -maxdepth 1 -name '*.msg' | sort | tail -1)
[ -f "$delivered_record" ] || fail "no delivered steering record to bind the charter's inbox path to"
assert_grep "durable message files in '$(dirname "$delivered_record")'." "$REMOTE_HOME/data/charter.md" \
  "the charter names an inbox the remote steer was not delivered into"
assert_grep "FM_PENDING_REPLY_EXISTING_CORR=$CORR" "$TMP_ROOT/send.err" "ambiguous remote send did not print its correlation-reusing command"
phase=$(grep '^phase=' "$PARENT/state/pending-replies/$CORR" | cut -d= -f2-)
[ "$phase" = delivery_unknown ] || fail "ambiguous remote send did not preserve its pending expectation"
printf 'done [corr=%s]: remote build passed\n' "$CORR" >> "$REMOTE_HOME/state/parent-replies.status"
SID='remote-reply-ios'
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "remote reply source did not capture the correlated answer"
RESULT="$PARENT/state/procevent-inbox/$SID.1.result"
remote_env "$ROOT/bin/fm-procevent-remote-reply.sh" handle ios 1 "$RESULT" >/dev/null \
  || fail "remote reply ingest failed"
assert_grep "done [corr=$CORR]: remote build passed" "$PARENT/state/ios.status" "correlated remote reply did not reach the parent status channel"
phase=$(grep '^phase=' "$PARENT/state/pending-replies/$CORR" | cut -d= -f2-)
[ "$phase" = resolved ] || fail "correlated remote reply did not resolve the parent expectation"
pass "marked send and routed reply complete through the existing parent correlation owner"
rm -f "$PARENT/state/.wake-queue"

printf '{"revision":2}\n' > "$PARENT/config/crew-dispatch.json"
printf 'default\n' > "$PARENT/config/crew-harness"
set +e
FM_FAKE_SSH_MODE=inherit-partial remote_env "$ROOT/bin/fm-config-push.sh" \
  > "$TMP_ROOT/config-partial.out" 2>&1
config_partial_rc=$?
set -e
[ "$config_partial_rc" -ne 0 ] || fail "partial remote inheritance claimed complete convergence"
assert_grep '"revision":2' "$REMOTE_HOME/config/crew-dispatch.json" "partial inheritance did not apply its first file"
[ "$(cat "$REMOTE_HOME/config/crew-harness")" != default ] \
  || fail "partial inheritance unexpectedly applied the failed file"
NUDGE_MARKER="$PARENT/state/.secondmate-nudge-pending/ios.pending"
assert_grep 'remote=1' "$NUDGE_MARKER" "partial inheritance left no durable remote reread marker"
publish_healthy_watcher_identity "$PARENT/state" "$PARENT" "$REMOTE_ROOT/bin/fm-watch.sh"
remote_env "$ROOT/bin/fm-bootstrap.sh" > "$TMP_ROOT/config-partial-retry.out" \
  || fail "bootstrap did not converge partial remote inheritance"
[ "$(cat "$REMOTE_HOME/config/crew-harness")" = default ] \
  || fail "bootstrap did not apply the remaining inherited file"
assert_absent "$NUDGE_MARKER" "bootstrap cleared no remote reread marker after convergence"
PARTIAL_CONFIG_CORR=$(newest_remote_inbox_corr)
[ -n "$PARTIAL_CONFIG_CORR" ] || fail "bootstrap config reread did not carry a correlation token"
printf 'done [corr=%s]: converged inherited config re-read\n' "$PARTIAL_CONFIG_CORR" >> "$REMOTE_HOME/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "remote reply source did not capture the converged config acknowledgment"
PARTIAL_CONFIG_RESULT="$PARENT/state/procevent-inbox/$SID.2.result"
remote_env "$ROOT/bin/fm-procevent-remote-reply.sh" handle ios 2 "$PARTIAL_CONFIG_RESULT" >/dev/null \
  || fail "converged remote config acknowledgment was not ingested"
pass "partial remote inheritance retains reread intent through bootstrap convergence"

rm -f "$TMP_ROOT/inherit.entered" "$TMP_ROOT/inherit.release" "$TMP_ROOT/inherit.payload"
cat > "$PARENT/data/captain-shared.md" <<'EOF'
# Shared captain preferences
This file is main-authoritative and maintained by the main firstmate.
It is read-only in secondmate homes and must not be edited there.
Changes return through a marked status document pointer.
stale concurrent preference
EOF
FM_FAKE_SSH_MODE=inherit-block remote_env "$ROOT/bin/fm-config-push.sh" \
  > "$TMP_ROOT/config-concurrent-first.out" 2>&1 &
config_first=$!
inherit_wait=0
while [ ! -f "$TMP_ROOT/inherit.entered" ]; do
  kill -0 "$config_first" 2>/dev/null || fail "first inheritance transaction exited before its blocked write"
  inherit_wait=$((inherit_wait + 1))
  # Match the earlier spawn/inheritance wait: a loaded portable runner can
  # spend several seconds in the remote entrypoint before reaching this write.
  [ "$inherit_wait" -le 1500 ] || fail "first inheritance transaction never reached its blocked write"
  sleep 0.02
done
cat > "$PARENT/data/captain-shared.md" <<'EOF'
# Shared captain preferences
This file is main-authoritative and maintained by the main firstmate.
It is read-only in secondmate homes and must not be edited there.
Changes return through a marked status document pointer.
current concurrent preference
EOF
remote_env "$ROOT/bin/fm-bootstrap.sh" > "$TMP_ROOT/config-concurrent-second.out" 2>&1 &
config_second=$!
sleep 0.2
kill -0 "$config_second" 2>/dev/null \
  || fail "bootstrap bypassed the active remote inheritance transaction"
touch "$TMP_ROOT/inherit.release"
wait "$config_first" || fail "first serialized inheritance transaction failed"
wait "$config_second" || fail "bootstrap inheritance transaction failed after waiting"
[ "$(tail -1 "$REMOTE_HOME/data/captain-shared.md")" = 'current concurrent preference' ] \
  || fail "later bootstrap convergence was overwritten by stale inherited bytes"
pass "config push and bootstrap serialize remote inheritance convergence"

printf 'deck\n' > "$PARENT/config/crew-harness"
# A failed reread nudge now means the durable remote inbox RECORD could not be
# written (a swallowed doorbell alone no longer fails a recorded steer), so
# the failure is induced by making the remote steering inbox unwritable.
chmod 555 "$REMOTE_HOME/state/parent-route/ios.inbox"
if remote_env "$ROOT/bin/fm-config-push.sh" > "$TMP_ROOT/config-push-fail.out" 2>&1; then
  chmod 755 "$REMOTE_HOME/state/parent-route/ios.inbox"
  fail "remote config push claimed success after its reread record could not be written"
fi
if [ ! -f "$NUDGE_MARKER" ]; then
  chmod 755 "$REMOTE_HOME/state/parent-route/ios.inbox"
  printf 'config push failure output:\n%s\n' "$(cat "$TMP_ROOT/config-push-fail.out")" >&2
  fail "failed remote config reread did not retain a retry marker"
fi
assert_grep 'remote=1' "$NUDGE_MARKER" "remote config reread marker lost its placement"
chmod 755 "$REMOTE_HOME/state/parent-route/ios.inbox"
remote_env "$ROOT/bin/fm-config-push.sh" > "$TMP_ROOT/config-push-retry.out" \
  || fail "unchanged remote config push did not retry its pending reread"
assert_absent "$NUDGE_MARKER" "successful remote config reread left its retry marker"
assert_grep 'config-reread: sent' "$TMP_ROOT/config-push-retry.out" "remote config reread retry was not reported"
CONFIG_CORR=$(newest_remote_inbox_corr)
[ -n "$CONFIG_CORR" ] || fail "remote config reread did not carry a correlation token"
printf 'done [corr=%s]: inherited config re-read\n' "$CONFIG_CORR" >> "$REMOTE_HOME/state/parent-replies.status"
remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
  || fail "remote reply source did not capture the config reread acknowledgement"
CONFIG_RESULT="$PARENT/state/procevent-inbox/$SID.3.result"
remote_env "$ROOT/bin/fm-procevent-remote-reply.sh" handle ios 3 "$CONFIG_RESULT" >/dev/null \
  || fail "remote config reread acknowledgement was not ingested"
pass "remote inherited config retains and retries a failed live reread nudge"

resolve_ios_pending() {
  local pending_record pending_corr pending_result pending_seq
  for pending_record in "$PARENT/state/pending-replies"/*; do
    [ -f "$pending_record" ] || continue
    [ "$(grep '^task_id=' "$pending_record" | cut -d= -f2-)" = ios ] || continue
    [ "$(grep '^phase=' "$pending_record" | cut -d= -f2-)" != resolved ] || continue
    pending_corr=$(basename "$pending_record")
    printf 'done [corr=%s]: concurrent inherited data re-read\n' "$pending_corr" \
      >> "$REMOTE_HOME/state/parent-replies.status"
    remote_env "$ROOT/bin/fm-procevent.sh" start "$SID" >/dev/null \
      || fail "remote reply source did not capture a concurrent inheritance acknowledgment"
    pending_result=$(find "$PARENT/state/procevent-inbox" -name "$SID.*.result" -print | sort | tail -1)
    pending_seq=${pending_result%.result}
    pending_seq=${pending_seq##*.}
    remote_env "$ROOT/bin/fm-procevent-remote-reply.sh" handle ios "$pending_seq" "$pending_result" >/dev/null \
      || fail "concurrent inheritance acknowledgment was not ingested"
  done
}
resolve_ios_pending

# Structured fleet state comes from each home's published ledger. The remote
# host is explicit, and the local route remains alongside it.
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LOCAL_HOME" \
  "$ROOT/bin/fm-home-summary-refresh.sh" >/dev/null \
  || fail "local fixture did not publish its home ledger"
remote_env "$ROOT/bin/fm-on.sh" ios fm-home-summary-refresh.sh >/dev/null \
  || fail "remote fixture did not publish its home ledger"
SNAPSHOT=$(remote_env "$ROOT/bin/fm-fleet-snapshot.sh" --json)
if ! printf '%s' "$SNAPSHOT" | jq -e '.secondmate_current.records | any(.id == "ios" and .remote == true and .host == "remote-mac" and .provenance.selected == "structured-home")' >/dev/null; then
  printf 'secondmate projection:\n%s\n' "$(printf '%s' "$SNAPSHOT" | jq '.secondmate_current')" >&2
  fail "fleet snapshot did not select the remote structured-home projection"
fi
printf '%s' "$SNAPSHOT" | jq -e '.tasks[] | select(.id == "ios") | .paths.home.present == null and .endpoint.agent_alive == "unknown"' >/dev/null \
  || fail "the fleet snapshot performed or invented a remote endpoint-liveness probe"
printf '%s' "$SNAPSHOT" | jq -e '.secondmate_current.records | any(.id == "local" and .remote == false)' >/dev/null \
  || fail "fleet snapshot lost the existing local secondmate route"
pass "fleet snapshot projects mixed local and remote structured state"
rm -f "$PARENT/state/.wake-queue"

# The remote code root updates independently, then the persistent home imports
# and fast-forwards to that host-local commit without touching project clones.
REMOTE_SEED="$TMP_ROOT/firstmate-seed"
git clone -q "file://$REMOTE_ORIGIN" "$REMOTE_SEED"
git -C "$REMOTE_SEED" config user.email test@example.com
git -C "$REMOTE_SEED" config user.name Test
printf 'remote update probe\n' > "$REMOTE_SEED/REMOTE_UPDATE_PROBE"
git -C "$REMOTE_SEED" add REMOTE_UPDATE_PROBE
git -C "$REMOTE_SEED" commit -qm 'advance remote code root'
git -C "$REMOTE_SEED" push -q origin main
UPDATE_OUT=$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh update ios)
assert_contains "$UPDATE_OUT" 'synced:' "remote update did not report a host-local fast-forward"
[ "$(git -C "$REMOTE_HOME" rev-parse HEAD)" = "$(git -C "$REMOTE_ROOT" rev-parse HEAD)" ] \
  || fail "remote persistent home did not fast-forward to its code-root commit"
assert_present "$REMOTE_HOME/REMOTE_UPDATE_PROBE" "remote update did not materialize the code-root commit"
pass "remote update imports and fast-forwards the persistent home on its configured host"

# The remote restart verb is not a second implementation: its host-local leg runs
# the ORDINARY control plane against a record that is plain and local on that
# host. These two refusals can only come from that plane's own pre-stop
# capability tables, and they leave the live agent exactly as it was - which is
# the whole safety property of asking before anything is stopped.
RELAUNCH_UNVERIFIED=$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh \
  relaunch ios notaharness - - 2>&1) && fail "an unverified runtime should refuse a remote restart"
assert_contains "$RELAUNCH_UNVERIFIED" 'unverified remote secondmate harness' \
  "the remote restart verb did not refuse an unverified runtime"
RELAUNCH_ROUTE_META="$REMOTE_HOME/state/parent-route/ios.meta"
cp "$RELAUNCH_ROUTE_META" "$TMP_ROOT/ios-before-relaunch.meta"
# A bare repository stops discovery at this fixture instead of finding an
# enclosing worktree when TMPDIR lives inside the checkout under test.
mkdir -p "$TMP_ROOT/not-a-checkout"
git -C "$TMP_ROOT/not-a-checkout" init -q --bare
sed "s|^worktree=.*|worktree=$TMP_ROOT/not-a-checkout|" \
  "$TMP_ROOT/ios-before-relaunch.meta" > "$RELAUNCH_ROUTE_META"
RELAUNCH_CHECKPOINT=$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh \
  relaunch ios deck - - 2>&1) && fail "a restart with no accountable checkout should refuse"
assert_contains "$RELAUNCH_CHECKPOINT" 'refusing to relaunch without a checkout whose unlanded work can be accounted for' \
  "the host-local restart did not reach the control plane's own pre-stop checkpoint"
cp "$TMP_ROOT/ios-before-relaunch.meta" "$RELAUNCH_ROUTE_META"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail "a refused remote restart must leave the running agent untouched"
pass "the remote restart verb delegates to the host-local control plane and refuses before stopping anything"


rm -f "$TMP_ROOT/doctor.repaired"
: > "$DOCTOR_LOG"
[ "$(FM_FAKE_SSH_MODE=doctor-fixable remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = unreadable ] \
  || fail "the stopped-server fixture did not make the pre-repair endpoint probe unreadable"
launches_before_repair=$(remote_agent_count ios)
BOOT_REPAIRED=$(FM_FAKE_SSH_MODE=doctor-fixable remote_env "$ROOT/bin/fm-bootstrap.sh")
[ "$(cat "$DOCTOR_LOG")" = 'doctor-fixable -
doctor-fixable --fix
doctor-fixable -' ] || fail "liveness did not check, repair, and re-check readiness before probing"$'\n'"$(cat "$DOCTOR_LOG")"
assert_not_contains "$BOOT_REPAIRED" 'SECONDMATE_LIVENESS: secondmate ios:' \
  "successful pre-probe readiness repair produced a liveness failure"
launches_after_repair=$(remote_agent_count ios)
[ "$launches_before_repair" -eq "$launches_after_repair" ] \
  || fail "readiness repair introduced a new remote relaunch point"
[ "$(remote_env "$ROOT/bin/fm-on.sh" ios fm-remote-secondmate-control.sh state ios)" = alive ] \
  || fail "the endpoint was not probed successfully after readiness repair"
pass "startup repairs remote readiness before probing without relaunching"

remote_route_meta="$REMOTE_HOME/state/parent-route/ios.meta"
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-before-liveness-legacy.meta"
cp "$PARENT/state/ios.meta" "$TMP_ROOT/parent-ios-before-liveness-legacy.meta"
cp "$PARENT/data/secondmates.md" "$TMP_ROOT/registry-before-liveness-legacy.md"
cat > "$remote_route_meta" <<EOF
window=firstmate:fm-ios
worktree=$REMOTE_HOME
project=$REMOTE_ROOT
harness=deck
kind=secondmate
backend=tmux
EOF
cp "$remote_route_meta" "$TMP_ROOT/remote-ios-liveness-legacy.meta"
launches_before_legacy=$(remote_agent_count ios)
BOOT_LEGACY=$(remote_env "$ROOT/bin/fm-bootstrap.sh")
assert_contains "$BOOT_LEGACY" "SECONDMATE_LIVENESS: secondmate ios: skipped: remote endpoint state is unverified on remote-mac" \
  "liveness accepted an alive legacy remote backend"
cmp -s "$TMP_ROOT/remote-ios-liveness-legacy.meta" "$remote_route_meta" \
  || fail "liveness rewrote the alive legacy endpoint metadata"
cmp -s "$TMP_ROOT/parent-ios-before-liveness-legacy.meta" "$PARENT/state/ios.meta" \
  || fail "liveness rewrote the parent route metadata for an alive legacy endpoint"
cmp -s "$TMP_ROOT/registry-before-liveness-legacy.md" "$PARENT/data/secondmates.md" \
  || fail "liveness changed the registry route for an alive legacy endpoint"
launches_after_legacy=$(remote_agent_count ios)
[ "$launches_before_legacy" -eq "$launches_after_legacy" ] \
  || fail "liveness relaunched an alive legacy endpoint"
mv -f "$TMP_ROOT/remote-ios-before-liveness-legacy.meta" "$remote_route_meta"
pass "startup reports records on a retired backend without changing their routes"

# Host loss never creates a local replacement. Remove both the published ledger
# and its parent-side cache so the structured-home read degrades explicitly;
# endpoint liveness remains the startup supervisor's concern.
rm -f -- "$REMOTE_HOME/state/home-summary.json"
rm -rf -- "$PARENT/state/secondmate-summary-cache"
launches_before=$(remote_agent_count ios)
rm -rf -- "$PARENT/state/.watch.lock"
rm -f -- "$PARENT/state/.last-watcher-beat"
BOOT_UNAVAILABLE=$(FM_FAKE_SSH_MODE=unreachable remote_env "$ROOT/bin/fm-bootstrap.sh")
assert_contains "$BOOT_UNAVAILABLE" 'SECONDMATE_LIVENESS: secondmate ios: skipped: remote host unavailable or endpoint state unknown' \
  "bootstrap did not preserve an unreachable remote endpoint as unknown"
UNAVAILABLE=$(FM_FAKE_SSH_MODE=unreachable remote_env "$ROOT/bin/fm-fleet-snapshot.sh" --json)
printf '%s' "$UNAVAILABLE" | jq -e '.secondmate_current.records | any(.id == "ios"
  and .current.state == "unknown" and .provenance.selected != "structured-home"
  and (.current.reason | test("home ledger.*(timed out|missing|unreadable|invalid)")))' >/dev/null \
  || fail "unreachable no-ledger remote home did not degrade to explicit unknown state"
printf '%s' "$UNAVAILABLE" | jq -e '.tasks[] | select(.id == "ios") | .paths.home.present == null and .endpoint.agent_alive == "unknown"' >/dev/null \
  || fail "unreachable remote endpoint liveness was not left to supervision"
rm -f "$PARENT/state/.wake-queue"
launches_after=$(remote_agent_count ios)
[ "$launches_before" -eq "$launches_after" ] || fail "unreachable projection attempted a replacement launch"
assert_present "$PARENT/state/ios.meta" "unreachable readiness removed the parent route metadata"
assert_grep '- ios ' "$PARENT/data/secondmates.md" "unreachable readiness removed the registry route"
pass "unreachable no-ledger remote state remains explicit with no local respawn or failover"

# Retirement delegates its safety check to the remote home. An in-flight child
# record refuses cleanup and preserves both machines' durable routes.
# A sibling remote secondmate's agent publishes to the same hub from the same
# host and must survive every refusal and the eventual successful retirement of
# ios.
# This fixture overrides FM_ROOT for transport, so teardown's root-owned guard
# sees the fixture root rather than the source script path used by fm-send.
publish_healthy_watcher_identity "$PARENT/state" "$PARENT" "$REMOTE_ROOT/bin/fm-watch.sh"
resolve_ios_pending
mkdir -p "$TMP_ROOT/sibling"
(umask 077; printf '%s\n' "$HUB_TOKEN" > "$TMP_ROOT/sibling/token")
python3 "$REMOTE_ROOT/bin/fm-stream-agent.py" serve --hub "$HUB_URL" \
  --token-file "$TMP_ROOT/sibling/token" --machine "$(hostname | tr -c 'A-Za-z0-9._-' '-')" \
  --label fm-macos --cwd "$TMP_ROOT/sibling" --status-path "$TMP_ROOT/sibling/macos.status" \
  --ready-file "$TMP_ROOT/sibling/ready" > "$TMP_ROOT/sibling/agent.log" 2>&1 &
waited=0
while [ ! -s "$TMP_ROOT/sibling/ready" ] && [ "$waited" -lt 150 ]; do sleep 0.1; waited=$((waited + 1)); done
SIBLING_EID=$(awk '{print $NF}' "$TMP_ROOT/sibling/ready" 2>/dev/null)
[ -n "$SIBLING_EID" ] || fail "the sibling agent did not register: $(cat "$TMP_ROOT/sibling/agent.log")"
SIBLING_PID=$(remote_agents macos | head -1)
[ -n "$SIBLING_PID" ] || fail "the sibling agent is not running"
printf 'kind=ship\n' > "$REMOTE_HOME/state/child.meta"
rm -rf "$PARENT/state/procevent"
: > "$PARENT/state/procevent"
if remote_env "$ROOT/bin/fm-teardown.sh" ios >/dev/null 2>&1; then
  fail "remote retirement ignored in-flight child work"
fi
assert_present "$REMOTE_HOME" "refused remote retirement removed the home"
assert_present "$PARENT/state/ios.meta" "refused remote retirement removed parent metadata"
assert_grep '- ios ' "$PARENT/data/secondmates.md" "refused remote retirement removed the route"
rm -f "$PARENT/state/procevent"
mkdir "$PARENT/state/procevent"
remote_env "$ROOT/bin/fm-bootstrap.sh" >/dev/null \
  || fail "bootstrap failed while repairing a preserved remote reply source"
assert_present "$PARENT/state/procevent/remote-reply-ios.source" \
  "bootstrap did not repair reply registration after retirement rollback"
resolve_ios_pending
rm -f "$REMOTE_HOME/state/child.meta"
mkdir -p "$PARENT/data/handoff"
ln -s "$TMP_ROOT/missing-outbox-target" "$PARENT/data/handoff/ios.outbox.md"
if remote_env "$ROOT/bin/fm-teardown.sh" ios >/dev/null 2>&1; then
  fail "remote retirement accepted an unsafe backlog outbox"
fi
assert_present "$REMOTE_HOME" "unsafe backlog outbox retirement removed the remote home"
rm -f "$PARENT/data/handoff/ios.outbox.md"
mkdir -p "$TMP_ROOT/external-pending"
printf 'task_id=ios\nphase=resolved\n' > "$TMP_ROOT/external-pending/escape"
mv "$PARENT/state/pending-replies" "$PARENT/state/pending-replies.safe"
ln -s "$TMP_ROOT/external-pending" "$PARENT/state/pending-replies"
if remote_env "$ROOT/bin/fm-teardown.sh" ios >/dev/null 2>&1; then
  fail "remote retirement accepted a symlinked pending-replies directory"
fi
assert_present "$REMOTE_HOME" "unsafe pending-replies retirement removed the remote home"
assert_present "$TMP_ROOT/external-pending/escape" "unsafe retirement removed an external pending reply"
rm -f "$PARENT/state/pending-replies"
mv "$PARENT/state/pending-replies.safe" "$PARENT/state/pending-replies"
retired_wake_corr=$(FM_HOME="$PARENT" bash -c '
  . "$1"
  fm_pending_reply_create "$2" "$2/state" ios "New routed work is in your backlog."
' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$PARENT") \
  || fail "could not seed remote receiver wake retirement state"
retired_wake_rec="$PARENT/state/pending-replies/$retired_wake_corr"
FM_HOME="$PARENT" bash -c '
  . "$1"
  fm_pending_reply_set "$2" phase resolved
  fm_pending_reply_set "$2" delivered_epoch 1
' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$retired_wake_rec" \
  || fail "could not settle remote receiver wake retirement state"
printf 'confirmed:%s\n' "$retired_wake_corr" > "$PARENT/state/.backlog-handoff-ios.wake-pending"
handoff_lock="$PARENT/state/.backlog-handoff-ios.lock"
FM_HOME="$PARENT" /bin/bash -c '
  . "$1"
  fm_lock_acquire_wait "$2"
  touch "$3"
  while [ ! -f "$4" ]; do sleep 0.02; done
  fm_lock_release "$2"
' _ "$ROOT/bin/fm-wake-lib.sh" "$handoff_lock" "$TMP_ROOT/handoff.entered" \
  "$TMP_ROOT/handoff.release" &
handoff_holder_pid=$!
handoff_wait=0
while [ ! -f "$TMP_ROOT/handoff.entered" ]; do
  kill -0 "$handoff_holder_pid" 2>/dev/null || fail "handoff lock holder exited before acquiring the route lock"
  handoff_wait=$((handoff_wait + 1))
  [ "$handoff_wait" -le 250 ] || fail "handoff lock holder never acquired the route lock"
  sleep 0.02
done
rm -f "$TMP_ROOT/launch.entered" "$TMP_ROOT/launch.release"
FM_FAKE_SSH_MODE=launch-block remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate \
  > "$TMP_ROOT/spawn-retirement.out" 2>&1 &
spawn_retirement_pid=$!
launch_wait=0
# The respawn performs readiness and inheritance jobs before launch, so allow
# the same 30-second loaded-runner bound as the earlier blocked worker path.
while [ ! -f "$TMP_ROOT/launch.entered" ]; do
  kill -0 "$spawn_retirement_pid" 2>/dev/null || fail "remote respawn exited before its blocked launch"
  launch_wait=$((launch_wait + 1))
  [ "$launch_wait" -le 1500 ] || fail "remote respawn never reached its blocked launch"
  sleep 0.02
done
remote_env "$ROOT/bin/fm-teardown.sh" ios > "$TMP_ROOT/teardown-serialized.out" 2>&1 &
teardown_pid=$!
sleep 0.2
kill -0 "$teardown_pid" 2>/dev/null || fail "remote retirement bypassed an active remote respawn"
assert_present "$REMOTE_HOME" "remote retirement removed the home during an active remote respawn"
touch "$TMP_ROOT/launch.release"
if ! wait "$spawn_retirement_pid"; then
  printf 'serialized respawn output:\n%s\n' "$(cat "$TMP_ROOT/spawn-retirement.out")" >&2
  fail "serialized remote respawn failed"
fi
sleep 0.2
kill -0 "$teardown_pid" 2>/dev/null || fail "remote retirement bypassed an active backlog handoff"
touch "$TMP_ROOT/handoff.release"
wait "$handoff_holder_pid" || fail "handoff lock holder failed to release"
if ! wait "$teardown_pid"; then
  printf 'serialized retirement output:\n%s\n' "$(cat "$TMP_ROOT/teardown-serialized.out")" >&2
  fail "safe remote retirement failed after handoff serialization"
fi
assert_absent "$REMOTE_HOME" "remote retirement did not remove the remote home"
assert_absent "$PARENT/state/ios.meta" "remote retirement did not remove parent metadata"
assert_absent "$PARENT/state/.backlog-handoff-ios.wake-pending" \
  "remote retirement left receiver wake state that could poison a replacement route"
assert_absent "$retired_wake_rec" "remote retirement left the retired receiver wake correlation"
assert_no_grep '- ios ' "$PARENT/data/secondmates.md" "remote retirement did not remove the registry route"
[ "$(remote_agent_count ios)" = 0 ] || fail "remote retirement left the retired mate's agent running"
kill -0 "$SIBLING_PID" 2>/dev/null || fail "remote retirement stopped the sibling secondmate's agent"
curl -sS -m 5 -o /dev/null --config <(printf 'header = "Authorization: Bearer %s"\n' "$HUB_TOKEN") \
  "$HUB_URL/v1/health" || fail "remote retirement stopped the shared hub"
pass "remote retirement refuses child work, then removes only its own endpoint while a sibling on the same hub survives"

echo "ALL TESTS PASSED"
