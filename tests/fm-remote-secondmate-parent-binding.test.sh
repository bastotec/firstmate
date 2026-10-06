#!/usr/bin/env bash
# tests/fm-remote-secondmate-parent-binding.test.sh - regression coverage for the
# fm-remote-sm-cleanup-parent-binding-s1 scout report: finished-worker cleanup
# inside a REMOTE second-mate home refused forever with "cannot resolve the
# primary home ... durable parent binding", because the remote launch hands the
# child the remote code checkout as its parent home (bin/fm-spawn.sh's sole
# writer of FM_PUBLIC_FOLLOWUP_PRIMARY_HOME receives FM_HOME=$FM_ROOT from
# bin/fm-remote-secondmate-control.sh's host-local launch), and that path can
# never carry the parent's real state or registry.
#
# The fix (report section 7, captain-approved same-machine scope): a durable
# .fm-secondmate-parent record, written once at seeding next to the
# .fm-secondmate-home identity marker, names this home's route to its parent as
# "local" or "remote". bin/fm-teardown.sh's cleanup gate reads it and treats a
# remote parent as OUT OF SCOPE (never refuses purely for being cross-machine,
# since the whole promised-public-reply subsystem is same-filesystem by
# construction) while still refusing on a genuine same-filesystem signal
# committed directly to this home's own .env file - never on an unrelated
# process-environment export, which is what let the remote host's own login
# shell mask into this home's binding before.
#
# This drives the REAL remote route (fm-remote-home-seed.sh -> fm-on.sh ->
# fm-remote-entrypoint.sh -> the host-local fm-remote-secondmate-control.sh ->
# the real bin/fm-spawn.sh --secondmate) across the repo's own deterministic SSH
# boundary onto a real stream hub and agent (the shape
# tests/fm-remote-secondmate-stream.test.sh uses), then runs the real
# bin/fm-teardown.sh for a finished child worker inside the produced remote home
# - never source-text matching. The child's own endpoint lives on the suite's
# fake stream hub (tests/fixtures.sh).
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

for tool in jq python3 curl perl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

TMP_ROOT=$(fm_test_tmproot fm-remote-parent-binding)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
SSH_COUNT="$TMP_ROOT/ssh.count"
DOCTOR_LOG="$TMP_ROOT/doctor.log"
TURNS="$TMP_ROOT/remote-turns"
CLAIMS="$TMP_ROOT/claims"
HUB_TOKEN="remote-binding-token-$$"
HUB_PID=
PUBLISH_PID=
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT" "$CLAIMS"

stream_agent_pids() {
  ps -eo pid,args 2>/dev/null \
    | awk -v r="$REMOTE_ROOT" 'index($0, "fm-stream-agent.py") && index($0, r) && !index($0, "awk") {print $1}'
}

cleanup() {
  local worker_pid='' pid
  if [ -n "$PUBLISH_PID" ]; then
    touch "$PUBLISH_RELEASE" 2>/dev/null || true
    kill "$PUBLISH_PID" 2>/dev/null || true
    wait "$PUBLISH_PID" 2>/dev/null || true
  fi
  FM_HOME="$PARENT" FM_PROCEVENT_CLAIM_ROOT="$CLAIMS" \
    "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  for pid in $(stream_agent_pids); do kill "$pid" 2>/dev/null || true; done
  [ -z "$HUB_PID" ] || kill "$HUB_PID" 2>/dev/null || true
  if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
    worker_pid=$(cat "$TMP_ROOT/remote-jobs/worker.pid")
    kill "$worker_pid" 2>/dev/null || true
  fi
  rm -rf -- "$TMP_ROOT"
  fm_test_cleanup || true
}
trap cleanup EXIT

PUBLISH_HOME="$TMP_ROOT/publication-home"
PUBLISH_FAKEBIN=$(fm_fakebin "$TMP_ROOT/publication-fake")
PUBLISH_ENTERED="$TMP_ROOT/publication-marker-entered"
PUBLISH_RELEASE="$TMP_ROOT/publication-marker-release"
PUBLISH_MANIFEST="$TMP_ROOT/publication.manifest"
REAL_MV=$(command -v mv)
cat > "$PUBLISH_FAKEBIN/mv" <<'SH'
#!/usr/bin/env bash
destination=${!#}
case "$destination" in
  */.fm-secondmate-home)
    touch "$FM_TEST_PUBLISH_ENTERED"
    while [ ! -f "$FM_TEST_PUBLISH_RELEASE" ]; do sleep 0.02; done
    ;;
esac
exec "$FM_TEST_REAL_MV" "$@"
SH
chmod +x "$PUBLISH_FAKEBIN/mv"
printf 'schema=fm-remote-home-provision.v1\nid_b64=%s\ncharter_b64=%s\nparent_host_b64=%s\nproject_count=0\n' \
  "$(printf publication | base64 | tr -d '\n')" \
  "$(printf 'Publication-order regression charter.\n' | base64 | tr -d '\n')" \
  "$(printf publish-host | base64 | tr -d '\n')" > "$PUBLISH_MANIFEST"
PATH="$PUBLISH_FAKEBIN:$PATH" FM_HOME="$PUBLISH_HOME" FM_ROOT_OVERRIDE="$ROOT" \
  FM_TEST_REAL_MV="$REAL_MV" FM_TEST_PUBLISH_ENTERED="$PUBLISH_ENTERED" \
  FM_TEST_PUBLISH_RELEASE="$PUBLISH_RELEASE" \
  "$ROOT/bin/fm-remote-home-provision.sh" < "$PUBLISH_MANIFEST" >/dev/null 2>&1 &
PUBLISH_PID=$!
publish_wait=0
while [ ! -f "$PUBLISH_ENTERED" ]; do
  kill -0 "$PUBLISH_PID" 2>/dev/null || fail "remote provisioning exited before its completion marker"
  publish_wait=$((publish_wait + 1))
  [ "$publish_wait" -le 250 ] || fail "remote provisioning never reached its completion marker"
  sleep 0.02
done
cmp -s "$PUBLISH_HOME/.fm-secondmate-parent" <(
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=publish-host\n'
) || fail "remote provisioning exposed completion before publishing the durable parent record"
assert_absent "$PUBLISH_HOME/.fm-secondmate-home" \
  "the remote identity marker must remain absent until durable parent publication completes"
touch "$PUBLISH_RELEASE"
wait "$PUBLISH_PID" || fail "remote provisioning failed after publishing durable state"
PUBLISH_PID=
assert_present "$PUBLISH_HOME/.fm-secondmate-home" \
  "remote provisioning must publish its identity marker as the completion point"
pass "remote provisioning publishes durable parent state before its completion marker"

# --- the remote host's tracked code root, real git repos, one project --------
(
  cd "$ROOT" || exit
  tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - .
) | (cd "$REMOTE_ROOT" && tar -xf -)
# The remote secondmate runs on deck through the real Deck host driver; its
# startup diagnostics and watcher are shimmed as tests/fm-backend-stream.test.sh
# shims them, and the `deck` binary records the primary-home binding its
# process environment actually received.
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
    log.write(json.dumps({'primary_home': os.environ.get('FM_PUBLIC_FOLLOWUP_PRIMARY_HOME', '')}) + '\n')
print(json.dumps({'type': 'run_started', 'session': 'fixture-session'}), flush=True)
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
# Every home cloned from this code root takes its origin as the delivery route,
# and a local route - file:// included - is refused; nothing here fetches it.
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
printf -- '- alpha [direct-PR] - alpha project (added 2026-08-04)\n' > "$PARENT/data/projects.md"
printf 'deck\n' > "$PARENT/config/secondmate-harness"
printf 'manual\n' > "$PARENT/config/backlog-backend"

# --- the fleet hub the remote home publishes to: real, loopback, ephemeral ---
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

# The primary home is the X-mode / relay home: the captain's real activation.
printf 'FMX_PAIRING_TOKEN=repro-token\n' > "$PARENT/.env"

# --- deterministic SSH boundary, identical shape to the lifecycle e2e suite --
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
IFS=$'\t' read -r command_name _command_action command_rel <<EOF
$command_fields
EOF
if [ "$command_name" = fm-remote-doctor.sh ]; then
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
if [ "$command_name" = fm-remote-secondmate-control.sh ] \
   && [ "$_command_action" = launch ] \
   && [ -n "${FM_TEST_PUBLICATION_TARGET:-}" ]; then
  out=$("$FM_FAKE_REMOTE_ENTRYPOINT" "$@")
  rc=$?
  rm -f "$FM_TEST_PUBLICATION_TARGET"
  ln -s "$FM_TEST_PUBLICATION_FOREIGN" "$FM_TEST_PUBLICATION_TARGET" || exit 94
  printf '%s\n' "$out"
  exit "$rc"
fi
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

# The parent reaches the mate only through the SSH boundary; the suite's fake
# hub (the child worker's) stays out of that path.
remote_env() {
  env -u FM_STREAM_HUB -u FM_STREAM_TOKEN -u FM_STREAM_MACHINE -u FM_STREAM_AGENT_BIN \
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
  FM_SEND_SETTLE=0 FM_SEND_SLEEP=0 \
  "$@"
}

FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
  FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
  remote_env "$ROOT/bin/fm-remote-home-seed.sh" ios remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" alpha \
  >/dev/null || fail "real remote secondmate seeding failed"
# The fleet-seeded credential and the Python stream agent (the copied code root
# has no native build of its own), as tests/fm-remote-secondmate-stream.test.sh
# seeds them.
printf '%s\n' "$HUB_URL" > "$REMOTE_HOME/config/stream-hub"
(umask 077; printf '%s\n' "$HUB_TOKEN" > "$REMOTE_HOME/config/stream-token")
printf 'python\n' > "$REMOTE_HOME/config/stream-impl"

# --- the durable record itself: the fundamental part of the fix -------------
assert_present "$REMOTE_HOME/.fm-secondmate-parent" \
  "real remote provisioning must write a durable parent record"
cmp -s "$REMOTE_HOME/.fm-secondmate-parent" <(
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=remote-mac\n'
) || fail "real remote provisioning must write the exact durable remote parent record"

out=$(remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1) \
  || fail "real remote secondmate launch failed: $out"

waited=0
while ! grep -q primary_home "$TURNS" 2>/dev/null && [ "$waited" -lt 300 ]; do sleep 0.1; waited=$((waited + 1)); done
DELIVERED=$(jq -r '.primary_home' "$TURNS" 2>/dev/null | tail -1)
[ -n "$DELIVERED" ] || fail "the remote launch did not deliver a primary-home binding to assert against"
case "$DELIVERED" in
  "$REMOTE_ROOT") : ;;
  *) fail "test setup drifted: expected the remote code root to be delivered as the (wrong) parent binding, got: $DELIVERED" ;;
esac

# --- a finished child worker inside the remote secondmate home --------------
CHILD_WT="$REMOTE_HOME/projects/alpha"
mkdir -p "$REMOTE_HOME/state"
# This regression exercises remote-parent binding, not backlog mutation. Keep
# its synthetic child home on the supported hand-edited backend so teardown's
# fused automatic close is correctly exempt without requiring a tasks-axi mock.
printf '%s\n' manual > "$REMOTE_HOME/config/backlog-backend"
write_child_meta() {
  # shellcheck disable=SC2046 # one meta line per word
  fm_write_meta "$REMOTE_HOME/state/work-child.meta" \
    $(fm_test_stream_task "$REMOTE_HOME/state" work-child) \
    "worktree=$CHILD_WT" "project=$CHILD_WT" "harness=deck" "kind=ship" \
    "mode=local-only" "yolo=off"
  # A finished worker: its endpoint stands at its shell.
  fm_test_fake_stream_foreground "$(fm_test_stream_target_of "$REMOTE_HOME/state" work-child)" bash
}
mkdir -p "$TMP_ROOT/childfake"
for t in treehouse no-mistakes gh gh-axi tasks-axi; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_ROOT/childfake/$t"
  chmod +x "$TMP_ROOT/childfake/$t"
done

run_child_teardown() { # <extra env assignments...>
  local out rc=0
  write_child_meta
  out=$(env "$@" PATH="$TMP_ROOT/childfake:$PATH" \
    FM_HOME="$REMOTE_HOME" FM_STATE_OVERRIDE="$REMOTE_HOME/state" \
    FM_DATA_OVERRIDE="$REMOTE_HOME/data" FM_CONFIG_OVERRIDE="$REMOTE_HOME/config" \
    "$REMOTE_ROOT/bin/fm-teardown.sh" work-child 2>&1) || rc=$?
  CHILD_TEARDOWN_OUT=$out
  CHILD_TEARDOWN_RC=$rc
}

# Case B-equivalent: the delivered (wrong) binding points at the remote code
# root, and that root itself carries an X-mode .env - a plausible real-world
# state (a captain who also runs Firstmate directly on the build Mac). Before
# the fix this refused; the durable record now makes it out of scope.
printf 'FMX_PAIRING_TOKEN=remote-host-token\n' > "$REMOTE_ROOT/.env"
run_child_teardown FM_PUBLIC_FOLLOWUP_PRIMARY_HOME="$DELIVERED"
rm -f "$REMOTE_ROOT/.env"
[ "$CHILD_TEARDOWN_RC" -eq 0 ] \
  || fail "a remote-routed child must allow cleanup when only the remote code root looks relay-active (rc=$CHILD_TEARDOWN_RC): $CHILD_TEARDOWN_OUT"
assert_not_contains "$CHILD_TEARDOWN_OUT" "cannot resolve the primary home" \
  "a cross-machine parent must never be reported as an unresolved binding"
pass "a remote secondmate's finished worker cleans up when the remote code root's own .env looked relay-active"

# Case C-equivalent: FMX_PAIRING_TOKEN exported directly in the process
# environment, simulating the remote host's own login-shell export reaching the
# agent's pane. fm_pf_relay_active's environment-wins rule would make this look
# identical to a genuine same-home commitment; the fix must tell them apart by
# reading only $FM_HOME/.env, never the process environment, once the durable
# record says the parent is remote.
run_child_teardown FM_PUBLIC_FOLLOWUP_PRIMARY_HOME="$DELIVERED" FMX_PAIRING_TOKEN=ambient-login-token
[ "$CHILD_TEARDOWN_RC" -eq 0 ] \
  || fail "a remote-routed child must allow cleanup when only an ambient exported token looks relay-active (rc=$CHILD_TEARDOWN_RC): $CHILD_TEARDOWN_OUT"
assert_not_contains "$CHILD_TEARDOWN_OUT" "cannot resolve the primary home" \
  "an ambient exported token from the remote host's own shell must never bind this child"
pass "a remote secondmate's finished worker cleans up when only an ambient exported token looked relay-active"

# Baseline: no signal anywhere. Must keep succeeding exactly as before the fix.
run_child_teardown
[ "$CHILD_TEARDOWN_RC" -eq 0 ] \
  || fail "a remote-routed child with no relay signal anywhere must allow cleanup (rc=$CHILD_TEARDOWN_RC): $CHILD_TEARDOWN_OUT"
pass "a remote secondmate's finished worker cleans up with no relay signal anywhere"

# Protection-preserved case: THIS home's own .env file (not the process
# environment, not the remote code root) carries a real token. That is a
# genuine same-filesystem signal this child's own home could hold, so it must
# still refuse even though the parent route is remote.
printf 'FMX_PAIRING_TOKEN=child-own-token\n' > "$REMOTE_HOME/.env"
run_child_teardown
rm -f "$REMOTE_HOME/.env"
[ "$CHILD_TEARDOWN_RC" -ne 0 ] \
  || fail "a remote secondmate's own committed .env token must still refuse cleanup, got rc=0: $CHILD_TEARDOWN_OUT"
assert_contains "$CHILD_TEARDOWN_OUT" "cannot resolve the primary home" \
  "a genuine same-filesystem token on this home must remain an actionable refusal"
assert_present "$REMOTE_HOME/state/work-child.meta" \
  "a genuine refusal must preserve the child work metadata"
pass "a remote secondmate's own committed relay token still refuses cleanup"

FOREIGN_META="$TMP_ROOT/foreign-ios.meta"
LOCAL_META="$PARENT/state/ios.meta"
printf 'foreign sentinel\n' > "$FOREIGN_META"
rm -f "$LOCAL_META"
PUBLICATION_RC=0
PUBLICATION_OUT=$(FM_TEST_PUBLICATION_TARGET="$LOCAL_META" \
  FM_TEST_PUBLICATION_FOREIGN="$FOREIGN_META" \
  remote_env "$ROOT/bin/fm-spawn.sh" ios --secondmate 2>&1) || PUBLICATION_RC=$?
[ "$PUBLICATION_RC" -ne 0 ] \
  || fail "remote secondmate publication accepted a target resolving outside its home"
assert_contains "$PUBLICATION_OUT" "task record could not be published" \
  "remote secondmate publication did not report its record-boundary refusal"
cmp -s "$FOREIGN_META" <(printf 'foreign sentinel\n') \
  || fail "remote secondmate publication wrote through the foreign target"
[ -L "$LOCAL_META" ] \
  || fail "remote secondmate publication replaced the refused target boundary"
pass "remote secondmate publication refuses targets outside its home"

echo "ALL TESTS PASSED"
