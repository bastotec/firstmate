#!/usr/bin/env bash
# tests/fm-remote-secondmate-stream.test.sh - a remote second mate on the
# stream backend, driven through the REAL remote route: the parent's
# bin/fm-spawn.sh / fm-send.sh / fm-peek.sh / fm-control.sh -> bin/fm-on.sh ->
# the deterministic SSH boundary -> bin/fm-remote-entrypoint.sh -> the
# host-local bin/fm-remote-secondmate-control.sh -> the real bin/fm-spawn.sh and
# bin/fm-control.sh on that "host".
#
# The stream side is real: this repository's hub on an ephemeral loopback port
# with a fresh token file, and the real bin/fm-stream-agent.py owning a real
# pseudoterminal that runs the real Deck host driver against a fake `deck`
# binary. The remote home reads the hub and its credential from its own
# config/stream-hub and config/stream-token, as a seeded fleet home does.
# Moving a task between backends is exercised end to end, against a real tmux
# server, by tests/fm-backend-stream.test.sh; here the remote relaunch proves the
# host-side control plane runs and the parent's binding is rewritten.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for tool in jq python3 curl perl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

TMP_ROOT=$(fm_test_tmproot fm-remote-secondmate-stream)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
SSH_COUNT="$TMP_ROOT/ssh.count"
DOCTOR_LOG="$TMP_ROOT/doctor.log"
CONTROL_LOG="$TMP_ROOT/control.log"
CLAIMS="$TMP_ROOT/claims"
TOKEN="remote-stream-token-$$"
ID=ops
HUB_PID=
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT" "$CLAIMS"

stream_agent_pids() {
  ps -eo pid,args 2>/dev/null \
    | awk -v l="--label fm-$ID" -v r="$REMOTE_ROOT" \
        'index($0, "fm-stream-agent.py") && index($0, l) && index($0, r) && !index($0, "awk") {print $1}'
}

cleanup() {
  local worker_pid='' pid
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  for pid in $(stream_agent_pids); do kill "$pid" 2>/dev/null || true; done
  [ -z "$HUB_PID" ] || kill "$HUB_PID" 2>/dev/null || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    kill "$worker_pid" 2>/dev/null || true
  fi
  rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT

# --- the fleet hub: real, loopback, ephemeral port --------------------------
printf 'publish,subscribe,control:%s\n' "$TOKEN" > "$TMP_ROOT/hub-tokens"
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

# --- the remote host's tracked code root ------------------------------------
(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)
# The Deck host's startup diagnostics, watcher, and model are shimmed exactly as
# tests/fm-backend-stream.test.sh shims them; the host driver itself is real.
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
# The turn log lives outside the remote home: a file inside it would dirty the
# home's tree and make the parent's sync skip it.
TURNS="$TMP_ROOT/remote-turns"
cat > "$REMOTE_ROOT/bin/deck" <<PY
#!/usr/bin/env python3
import json, sys
with open('$TURNS', 'a') as log:
    log.write(json.dumps(sys.argv[2:]) + '\n')
print(json.dumps({'type': 'run_started', 'session': 'fixture-session'}), flush=True)
print(json.dumps({'type': 'text_delta', 'text': 'REMOTE-FIXTURE-TURN'}), flush=True)
print(json.dumps({'type': 'run_finished', 'output': 'ready', 'turns': 1}), flush=True)
PY
chmod +x "$REMOTE_ROOT/bin/fm-session-start.sh" "$REMOTE_ROOT/bin/fm-watch-arm.sh" "$REMOTE_ROOT/bin/deck"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'remote fixture root'
REMOTE_ORIGIN="$TMP_ROOT/firstmate-origin.git"
git init -q --bare "$REMOTE_ORIGIN"
git -C "$REMOTE_ROOT" remote add origin "file://$REMOTE_ORIGIN"
git -C "$REMOTE_ROOT" push -q -u origin main
git --git-dir="$REMOTE_ORIGIN" symbolic-ref HEAD refs/heads/main
git -C "$REMOTE_ROOT" remote set-url origin "forge.test:$REMOTE_ORIGIN"

git init -q --bare "$TMP_ROOT/alpha.git"
git -C "$PARENT/projects" init -q -b main alpha
git -C "$PARENT/projects/alpha" config user.email test@example.com
git -C "$PARENT/projects/alpha" config user.name Test
printf 'alpha\n' > "$PARENT/projects/alpha/README.md"
git -C "$PARENT/projects/alpha" add README.md
git -C "$PARENT/projects/alpha" commit -qm init
git -C "$PARENT/projects/alpha" remote add origin "file://$TMP_ROOT/alpha.git"
git -C "$PARENT/projects/alpha" push -q -u origin main
git --git-dir="$TMP_ROOT/alpha.git" symbolic-ref HEAD refs/heads/main
printf -- '- alpha [direct-PR] - alpha project (added 2026-10-05)\n' > "$PARENT/data/projects.md"
printf 'deck\n' > "$PARENT/config/secondmate-harness"
printf 'manual\n' > "$PARENT/config/backlog-backend"

# --- deterministic SSH boundary, the shape the other remote suites use -------
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
argv_b64=$4
command_fields=$(perl -MMIME::Base64=decode_base64 -e '
  my $data=decode_base64($ARGV[0]);
  my @args=split(/\0/, $data);
  print join("\t", map { defined $_ ? $_ : "" } @args[0..2]);
' "$argv_b64")
IFS=$'\t' read -r command_name command_action command_arg <<EOF
$command_fields
EOF
# The readiness gate is answered here (tests/fm-remote-doctor.test.sh owns the
# doctor's own checks); the log records which backend each launch asked for.
if [ "$command_name" = fm-remote-doctor.sh ]; then
  printf '%s %s\n' "${command_action:--}" "${command_arg:--}" >> "$FM_FAKE_DOCTOR_LOG"
  if [ "${FM_FAKE_DOCTOR_RC:-0}" -ne 0 ]; then
    printf 'check stream-survival=human: systemd-logind kills this user at logout\n'
    exit "$FM_FAKE_DOCTOR_RC"
  fi
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
if [ "$command_name" = fm-remote-secondmate-control.sh ]; then
  printf '%s %s\n' "$command_action" "$command_arg" >> "$FM_FAKE_CONTROL_LOG"
fi
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

remote_env() {
  FM_HOME="$PARENT" \
  FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
  FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
  FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_SSH_COUNT="$SSH_COUNT" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
  FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  FM_FAKE_DOCTOR_LOG="$DOCTOR_LOG" \
  FM_FAKE_CONTROL_LOG="$CONTROL_LOG" \
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
  "$@"
}

# The hub as an operator on the parent sees it (through a tunnel in the fleet).
hub_state() {  # <target>
  (
    export FM_STREAM_HUB="$HUB_URL" FM_STREAM_TOKEN="$TOKEN" FM_HOME="$PARENT" FM_ROOT="$ROOT"
    # shellcheck source=bin/fm-backend.sh
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_agent_state stream "$1"
  )
}

wait_hub_state() {  # <target> <state>
  local waited=0
  while [ "$(hub_state "$1")" != "$2" ] && [ "$waited" -lt 300 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  assert_equals "$2" "$(hub_state "$1")" "endpoint $1 did not reach $2"
}

meta_value() { sed -n "s/^$2=//p" "$1" | tail -1; }

FM_SECONDMATE_CHARTER='Own operations from the workload host.' \
  FM_SECONDMATE_SCOPE='operations' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" "$ID" remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" alpha \
  >/dev/null || fail "real remote secondmate seeding failed"
# The fleet-seeded credential: this home's own hub URL and token files.
printf '%s\n' "$HUB_URL" > "$REMOTE_HOME/config/stream-hub"
(umask 077; printf '%s\n' "$TOKEN" > "$REMOTE_HOME/config/stream-token")
# The copied code root has no native build of its own, so this home uses the
# Python stream agent (the documented rollback, docs/stream-backend.md).
printf 'python\n' > "$REMOTE_HOME/config/stream-impl"
printf 'manual\n' > "$REMOTE_HOME/config/backlog-backend"

PARENT_META="$PARENT/state/$ID.meta"
HOST_META="$REMOTE_HOME/state/parent-route/$ID.meta"

# --- launch on stream --------------------------------------------------------
out=$(remote_env "$ROOT/bin/fm-spawn.sh" "$ID" --secondmate --backend stream 2>&1) \
  || fail "remote stream launch failed: $out"
assert_contains "$out" "backend=stream" "the spawn did not report the stream backend: $out"
assert_grep '--backend stream' "$DOCTOR_LOG" "the readiness gate did not check the stream backend"
assert_equals stream "$(meta_value "$PARENT_META" remote_backend)" "the parent did not record remote_backend=stream"
STREAM_TARGET=$(meta_value "$PARENT_META" remote_target)
EID=$(meta_value "$PARENT_META" remote_stream_endpoint_id)
case "$EID" in ''|*[!0-9a-f]*) fail "the parent recorded no stream endpoint id: $(cat "$PARENT_META")" ;; esac
assert_equals "${STREAM_TARGET#*:}" "$EID" "remote_target does not name the recorded endpoint id"
assert_equals "$HUB_URL" "$(meta_value "$PARENT_META" remote_stream_hub)" "the parent did not record the hub the agent publishes to"
assert_no_grep 'remote_herdr_session=' "$PARENT_META" "a stream route recorded a Herdr session"
assert_equals stream "$(meta_value "$HOST_META" backend)" "the host record is not on stream"
assert_no_grep "$TOKEN" "$PARENT_META" "the parent record carries the hub credential"
wait_hub_state "$STREAM_TARGET" alive
waited=0
while ! grep -q 'launch-brief' "$TURNS" 2>/dev/null && [ "$waited" -lt 200 ]; do sleep 0.1; waited=$((waited + 1)); done
assert_grep 'launch-brief' "$TURNS" "the remote Deck host never ran its charter turn"
for pid in $(stream_agent_pids); do
  if ps -o args= -p "$pid" 2>/dev/null | grep -qF -- "$TOKEN"; then
    fail "the stream agent carries the hub credential on its command line"
  fi
done
pass "remote: a stream launch records the stream binding and runs the agent on the host's hub"

assert_readiness_refusal() {
  local expected_rc=$1 expected_check=$2 expected_calls=$3 out rc=0
  shift 3
  cp "$PARENT_META" "$TMP_ROOT/parent-before.meta"
  cp "$HOST_META" "$TMP_ROOT/host-before.meta"
  cp "$REMOTE_HOME/state/parent-route/$ID.agent-identity" "$TMP_ROOT/identity-before"
  cp "$CONTROL_LOG" "$TMP_ROOT/control-before.log"
  : > "$DOCTOR_LOG"
  out=$(FM_FAKE_DOCTOR_RC="$expected_rc" remote_env "$ROOT/bin/fm-control.sh" "$ID" relaunch "$@" 2>&1) || rc=$?
  expect_code "$expected_rc" "$rc" "readiness refusal"
  assert_contains "$out" 'relaunch refused' "readiness did not refuse relaunch: $out"
  assert_contains "$out" 'systemd-logind kills this user at logout' "readiness did not relay the doctor gap: $out"
  if [ "$expected_rc" -eq 255 ]; then
    assert_contains "$out" 'readiness is unknown' "SSH failure did not report unknown readiness: $out"
  fi
  assert_equals "$expected_check" "$(head -n 1 "$DOCTOR_LOG")" "readiness selected the wrong backend"
  assert_equals "$expected_calls" "$(wc -l < "$DOCTOR_LOG" | tr -d ' ')" "readiness ran the wrong check/repair sequence"
  cmp -s "$PARENT_META" "$TMP_ROOT/parent-before.meta" || fail "readiness refusal changed the parent record"
  cmp -s "$HOST_META" "$TMP_ROOT/host-before.meta" || fail "readiness refusal changed the host record"
  cmp -s "$REMOTE_HOME/state/parent-route/$ID.agent-identity" "$TMP_ROOT/identity-before" \
    || fail "readiness refusal replaced the mate's identity"
  cmp -s "$CONTROL_LOG" "$TMP_ROOT/control-before.log" || fail "readiness refusal reached host lifecycle control"
  wait_hub_state "$STREAM_TARGET" alive
}

assert_readiness_refusal 1 '- -' 3 --backend herdr
assert_readiness_refusal 1 '--backend stream' 3
assert_readiness_refusal 255 '--backend stream' 1 --backend stream
cp "$PARENT_META" "$TMP_ROOT/recorded-backend.meta"
awk -F= '$1 != "remote_backend"' "$TMP_ROOT/recorded-backend.meta" > "$PARENT_META"
assert_readiness_refusal 1 '- -' 3
mv "$TMP_ROOT/recorded-backend.meta" "$PARENT_META"
pass "remote: readiness gaps and unknown outcomes preserve the mate before relaunch"

if [ "${FM_REMOTE_SECONDMATE_PROFILE_ONLY:-0}" != 1 ]; then
# --- steering, peek, state, and the parent's lifecycle verbs ----------------
out=$(remote_env "$ROOT/bin/fm-send.sh" "$ID" 'remote stream steer' 2>&1) || fail "remote send failed: $out"
assert_grep 'remote stream steer' "$REMOTE_HOME/state/parent-route/$ID.inbox/001.msg" \
  "the steer was not durably recorded on the host"
waited=0
while ! grep -q 'Firstmate instruction waiting:' "$TURNS" && [ "$waited" -lt 200 ]; do sleep 0.1; waited=$((waited + 1)); done
assert_grep 'Firstmate instruction waiting:' "$TURNS" "the doorbell did not become a Deck turn"
out=$(remote_env "$ROOT/bin/fm-peek.sh" "$ID" 40 2>&1) || fail "remote peek failed: $out"
assert_contains "$out" REMOTE-FIXTURE-TURN "peek did not read the stream endpoint: $out"
out=$(remote_env "$ROOT/bin/fm-crew-state.sh" "$ID" 2>&1) || fail "remote crew-state failed: $out"
assert_not_contains "$out" unverified "crew-state could not read the stream endpoint: $out"
out=$(remote_env "$ROOT/bin/fm-control.sh" "$ID" interrupt 2>&1) || fail "remote interrupt failed: $out"
assert_contains "$out" "interrupt-delivered $ID" "remote interrupt did not report its postcondition: $out"
pass "remote: send, peek, crew-state, and interrupt reach a stream mate"

# --- liveness: an alive stream route is accepted, never respawned ------------
out=$(FM_BOOTSTRAP_NETWORK=only remote_env "$ROOT/bin/fm-bootstrap.sh" 2>&1) || true
assert_not_contains "$out" "secondmate $ID: skipped" "the liveness sweep refused a live stream route: $out"
assert_not_contains "$out" "secondmate $ID: respawn" "the liveness sweep respawned a live stream mate: $out"
assert_equals "$STREAM_TARGET" "$(meta_value "$PARENT_META" remote_target)" "the liveness sweep moved the mate"
pass "remote: the liveness sweep accepts a live stream mate"

# --- relaunch through the parent's control plane rebinds the parent ---------
# A stale parent binding (the shape a herdr-era record has) must be replaced by
# what the host's route reports after the relaunch.
stale="$PARENT_META.stale"
grep -v -E '^remote_(backend|target|herdr_session|stream_)' "$PARENT_META" > "$stale"
printf 'remote_backend=herdr\nremote_herdr_session=fm-remote\nremote_target=fm-remote:w9:p9\n' >> "$stale"
mv -f "$stale" "$PARENT_META"
out=$(remote_env "$ROOT/bin/fm-control.sh" "$ID" relaunch --backend stream 2>&1) \
  || fail "remote relaunch failed: $out"
assert_contains "$out" "rebound $ID remote=remote-mac backend=stream target=$STREAM_TARGET" "the parent was not rebound: $out"
assert_equals stream "$(meta_value "$PARENT_META" remote_backend)" "the parent record was not rebound to stream"
assert_equals "$STREAM_TARGET" "$(meta_value "$PARENT_META" remote_target)" "the parent record names the wrong endpoint"
assert_equals "$EID" "$(meta_value "$PARENT_META" remote_stream_endpoint_id)" "the parent record lost the endpoint id"
assert_no_grep 'remote_herdr_session=' "$PARENT_META" "the stale Herdr binding survived the rebind"
assert_equals deck "$(meta_value "$PARENT_META" harness)" "the rebind changed the harness"
assert_equals "$(meta_value "$HOST_META" model)" "$(meta_value "$PARENT_META" model)" "the rebind did not read the host model"
assert_equals "$(meta_value "$HOST_META" effort)" "$(meta_value "$PARENT_META" effort)" "the rebind did not read the host effort"
wait_hub_state "$STREAM_TARGET" alive
assert_present "$REMOTE_HOME/state/parent-route/$ID.inbox/001.msg" "the relaunch discarded the durable steer"
pass "remote: relaunch runs on the host and rewrites the parent's binding from its route"
fi

set_parent_profile() {
  local model=$1
  awk -F= '$1 != "harness" && $1 != "model" && $1 != "effort"' "$PARENT_META" > "$PARENT_META.profile"
  printf 'harness=pi\nmodel=%s\neffort=high\n' "$model" >> "$PARENT_META.profile"
  mv "$PARENT_META.profile" "$PARENT_META"
}
set_parent_profile fixture/pi
: > "$DOCTOR_LOG"
out=$(remote_env "$ROOT/bin/fm-control.sh" "$ID" relaunch --harness deck 2>&1) \
  || fail "remote harness-change reset failed: $out"
assert_equals '--backend stream' "$(cat "$DOCTOR_LOG")" "a ready stream relaunch did not check its recorded backend"
assert_equals default "$(meta_value "$HOST_META" model)" "harness change retained the old model"
assert_equals default "$(meta_value "$HOST_META" effort)" "harness change retained the old effort"
assert_equals default "$(meta_value "$PARENT_META" model)" "parent did not bind the reset model"
assert_equals default "$(meta_value "$PARENT_META" effort)" "parent did not bind the reset effort"
pass "remote: changing harness resets unnamed model and effort pins"

set_parent_profile fixture/pi
FM_HOME="$REMOTE_HOME" FM_STATE_OVERRIDE="$REMOTE_HOME/state/parent-route" \
  "$REMOTE_ROOT/bin/fm-record-model-refusal.sh" "$ID" fixture/first >/dev/null \
  || fail "could not seed the host's model cooldown"
out=$(remote_env "$ROOT/bin/fm-control.sh" "$ID" relaunch --harness deck --model fixture/first,fixture/second 2>&1) \
  || fail "remote explicit model chain failed: $out"
assert_equals fixture/second "$(meta_value "$HOST_META" model)" "host did not skip the cooled model"
assert_equals fixture/second "$(meta_value "$PARENT_META" model)" "parent recorded the requested chain instead of the resolved model"
assert_equals default "$(meta_value "$PARENT_META" effort)" "an explicit model prevented the unnamed effort reset"
assert_equals "$(meta_value "$HOST_META" effort)" "$(meta_value "$PARENT_META" effort)" "parent and host effort pins diverged"
pass "remote: explicit model chains resolve on the host and rebind their resolved pins"
[ "${FM_REMOTE_SECONDMATE_PROFILE_ONLY:-0}" != 1 ] || exit 0

out=$(remote_env "$ROOT/bin/fm-control.sh" "$ID" recover-missing 2>&1) \
  && fail "recover-missing was accepted for a remote mate: $out"
assert_contains "$out" "not available for it here" "recover-missing refusal was not named: $out"
out=$(remote_env "$ROOT/bin/fm-control.sh" "$ID" exit 2>&1) || fail "remote exit failed: $out"
wait_hub_state "$STREAM_TARGET" dead
pass "remote: exit stops a stream mate on its host; recover-missing stays refused"

echo "ALL TESTS PASSED"
