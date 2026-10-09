#!/usr/bin/env bash
# tests/fm-secondmate-liveness.test.sh - the session-start secondmate liveness
# guarantee owned by bin/fm-backend.sh's detailed fm_backend_agent_state and
# bin/fm-bootstrap.sh's secondmate_liveness_sweep that acts on it.
#
# The gap under test (AGENTS.md "Session start"; evidence 2026-07-07): a
# secondmate agent that has exited leaves its backend endpoint alive as a bare
# shell. Endpoint PRESENCE alone reports that shell "alive"; recovery only
# respawns endpoints reported dead, and the watcher deliberately exempts
# secondmates from stale-pane detection (an idle secondmate pane is healthy by
# design). A dead-shell secondmate was therefore invisible to every existing
# check and sat dead indefinitely.
#
# Every endpoint here is a fake stream endpoint on the suite's stub hub
# (tests/fixtures.sh), read through the real stream adapter. The guarantees
# under test:
#   - fm_backend_agent_state is the detailed owner that distinguishes alive,
#     dead, missing, ambiguous, unreadable, and unverified, from the foreground
#     process the endpoint reports and the hub's answer about it.
#   - fm_backend_agent_alive preserves the older three-state compatibility view.
#   - A record on a backend with no adapter (removed zellij, retired tmux and
#     Herdr) is unverified, never a dead reading.
#   - bin/fm-bootstrap.sh's secondmate_liveness_sweep recovers only a dead
#     endpoint it confirmed closed, keeps successful recovery and already-live
#     results silent by default, and reports ambiguous, unreadable, and
#     registry-absent targets distinctly without touching them.
#   - The sweep converges: once a secondmate reads alive, a later run never
#     re-touches it (idempotent by construction, not by remembering what it
#     already did).
#   - The sweep is skipped entirely under FM_BOOTSTRAP_DETECT_ONLY=1 (the
#     read-only session path), matching the other mutating sweeps.
#   - The sweep is naturally scoped to the primary: with no kind=secondmate
#     meta present (a secondmate's own state/ never holds one, since
#     secondmates never spawn secondmates), it is a silent no-op.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-secondmate-liveness)
fm_test_fake_stream_ensure || fail "the fake stream hub did not start"

# --- unit level: the stream classifier and the generic dispatchers ----------

# probe_state <target> -> the detailed state the real adapter reads.
probe_state() {
  FM_HOME="$TMP_ROOT/probe-home" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state "$1" "$2"' \
    "$ROOT" "${2:-stream}" "$1"
}
probe_alive() {
  FM_HOME="$TMP_ROOT/probe-home" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive "$1" "$2"' \
    "$ROOT" "${2:-stream}" "$1"
}

test_stream_agent_state_classifies() {
  local state="$TMP_ROOT/probe-state" target out name
  mkdir -p "$state" "$TMP_ROOT/probe-home"
  fm_test_stream_task "$state" probe >/dev/null || fail "could not register the probe endpoint"
  target=$(fm_test_stream_target_of "$state" probe)

  for name in pi pi-signed fm-deck-worker deck; do
    fm_test_fake_stream_foreground "$target" "$name"
    out=$(probe_state "$target")
    [ "$out" = alive ] || fail "a live $name foreground process should classify as alive, got '$out'"
  done

  for name in zsh bash -zsh; do
    fm_test_fake_stream_foreground "$target" "$name"
    out=$(probe_state "$target")
    [ "$out" = dead ] || fail "a bare $name foreground process should classify as dead, got '$out'"
  done

  fm_test_fake_stream_foreground "$target" node
  out=$(probe_state "$target")
  [ "$out" = ambiguous ] || fail "an existing node process should classify as ambiguous, got '$out'"
  [ "$(probe_alive "$target")" = unknown ] \
    || fail "the compatibility view must keep an existing node process unknown"

  fm_test_fake_stream_set "$target" '{"foreground": [{"pid": "", "name": "pi", "argv0": "pi", "args": "pi"}], "stale": true}'
  out=$(probe_state "$target")
  [ "$out" = unreadable ] || fail "a stale reading should stay unreadable, got '$out'"
  fm_test_fake_stream_set "$target" '{"stale": false}'

  out=$(FM_STREAM_HUB=http://127.0.0.1:9 probe_state "127.0.0.1-9:${target##*:}")
  [ "$out" = unreadable ] || fail "a hub that cannot be reached should leave the endpoint unreadable, got '$out'"

  for bad in nocolon "${FM_TEST_STREAM_TAG}:" ":abc" "${FM_TEST_STREAM_TAG}:not-hex"; do
    out=$(probe_state "$bad")
    [ "$out" = unreadable ] || fail "malformed stream target '$bad' should classify as unreadable, got '$out'"
  done

  fm_test_fake_stream_set "$target" '{"forget": true}'
  out=$(probe_state "$target")
  [ "$out" = missing ] || fail "an endpoint the hub keeps answering 404 for should classify as missing, got '$out'"
  [ "$(probe_alive "$target")" = dead ] \
    || fail "the compatibility view should treat a missing endpoint as dead"

  pass "fm_backend_stream_agent_state: separates live, dead, missing, ambiguous, and unreadable"
}

test_agent_state_dispatcher_and_compatibility() {
  local state="$TMP_ROOT/dispatch-state" target out backend
  mkdir -p "$state" "$TMP_ROOT/probe-home"
  fm_test_stream_task "$state" dispatch >/dev/null || fail "could not register the dispatch endpoint"
  target=$(fm_test_stream_target_of "$state" dispatch)
  fm_test_fake_stream_foreground "$target" fm-deck-worker
  out=$(probe_state "$target" stream)
  [ "$out" = alive ] || fail "detailed dispatcher should route stream, got '$out'"

  for backend in zellij tmux herdr; do
    out=$(probe_state sess:7 "$backend")
    [ "$out" = unverified ] || fail "a backend with no adapter ($backend) should be unverified, got '$out'"
    out=$(probe_alive sess:7 "$backend")
    [ "$out" = unknown ] || fail "the compatibility dispatcher should map unverified $backend to unknown, got '$out'"
  done

  pass "fm_backend_agent_state: routes stream and keeps a backend with no adapter unverified"
}

# --- sweep level: bin/fm-bootstrap.sh's secondmate_liveness_sweep -----------

# make_toolchain <dir>: the fixed set of stubs bin/fm-bootstrap.sh's read-only
# diagnostics need to stay quiet (mirrors tests/fm-secondmate-sync.test.sh's
# make_fake_toolchain).
make_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" node chrome-devtools-axi deck
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.46
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.29'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh-axi"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = get ] && [ "${2:-}" = --help ]; then
  printf '%s\n' 'Usage: treehouse get [--lease]'
fi
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.46.0 (fake)'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' '0.2.4' ;;
  "update --help") printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --archive-body' ;;
  "mv --help") printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.29'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
}

# new_world <name>: a scratch firstmate HOME (state/, watcher beacon, pinned
# harness) with no kind=secondmate meta yet. FM_ROOT is left to resolve
# naturally to the real checkout under test ($ROOT), exactly as production
# always has it - this sweep's own fm-spawn.sh invocation resolves the
# secondmate harness through $FM_ROOT/bin/fm-harness.sh, which only exists in
# the real tree. The harness is pinned because ambient own-harness detection is
# environment-dependent: interactive harness sessions expose markers or parent
# process names, while a plain pipeline shell can fall through to "unknown",
# which has no fm-spawn.sh launch template.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/config"
  touch "$w/home/state/.last-watcher-beat"
  printf 'deck\n' > "$w/home/config/crew-harness"
  printf '%s\n' "$w"
}

# add_sm_home <w> <id> [harness] [backend]: a plain (non-git) secondmate home -
# the probe/respawn machinery under test never requires the home to be a real
# worktree; a non-git home just makes the unrelated fast-forward sweep log a
# harmless "not a git repo" skip. Its endpoint is a fake stream endpoint whose
# target is kept in <w>/<id>.target; a named backend records the mate on that
# backend with no endpoint at all.
add_sm_home() {
  local w=$1 id=$2 harness=${3:-deck} backend=${4:-}
  local home="$w/$id"
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'charter\n' > "$home/data/charter.md"
  {
    if [ -n "$backend" ]; then
      printf 'window=firstmate:fm-%s\nbackend=%s\n' "$id" "$backend"
    else
      fm_test_stream_task "$w/home/state" "$id"
    fi
    printf 'kind=secondmate\n'
    printf 'harness=%s\n' "$harness"
    printf 'home=%s\n' "$home"
  } > "$w/home/state/$id.meta"
  [ -n "$backend" ] || fm_test_stream_target_of "$w/home/state" "$id" > "$w/$id.target"
}

# endpoint_mode <w> <id> <mode>: what the mate's endpoint reports - a foreground
# process name, `missing` (the hub answers 404 for it), `unreadable` (a stale
# reading), or `unconfirmed-kill` (a dead shell whose kill its agent never
# acknowledges).
endpoint_mode() {
  local target
  target=$(cat "$1/$2.target")
  case "$3" in
    missing) fm_test_fake_stream_set "$target" '{"forget": true}' ;;
    unreadable) fm_test_fake_stream_set "$target" '{"stale": true}' ;;
    unconfirmed-kill)
      fm_test_fake_stream_foreground "$target" zsh
      fm_test_fake_stream_set "$target" '{"kill_undelivered": true}'
      ;;
    *) fm_test_fake_stream_foreground "$target" "$3" ;;
  esac
}

# The fate of the endpoint the mate was recorded on, and of its record.
endpoint_closed() {  # <w> <id>
  [ -n "$(fm_test_fake_stream_endpoints | jq -r --arg e "$(cut -d: -f2 "$1/$2.target")" \
    '.endpoints[] | select(.endpoint_id == $e) | .closed_by // empty')" ]
}
relaunched() {  # <w> <id>: the record now names a new endpoint
  local now
  now=$(sed -n 's/^window=//p' "$1/home/state/$2.meta")
  [ -n "$now" ] && [ "$now" != "$(cat "$1/$2.target")" ]
}
untouched() {  # <w> <id>
  ! endpoint_closed "$1" "$2" && ! relaunched "$1" "$2"
}

run_bootstrap() {  # <fakebin> <home> [extra env...] -> stdout
  local fb=$1 home=$2; shift 2
  PATH="$fb:$BASE_PATH" FM_HOME="$home" env "$@" "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

test_sweep_respawns_confirmed_dead_secondmate() {
  local w fb out
  w=$(new_world sweep-dead)
  add_sm_home "$w" sm1
  endpoint_mode "$w" sm1 zsh
  fb=$(make_toolchain "$w")

  out=$(run_bootstrap "$fb" "$w/home")

  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1" \
    "a successfully respawned secondmate should be handled silently: $out"
  endpoint_closed "$w" sm1 \
    || fail "the stale endpoint must be closed before respawn"
  relaunched "$w" sm1 || fail "a confirmed-dead secondmate should actually be relaunched"
  pass "sweep: a confirmed-dead secondmate endpoint is closed and respawned"
}

# A relaunch onto an endpoint nothing proved gone is how a second agent gets
# started beside a first one that may still be running. The sweep kills the
# endpoint first for exactly that reason, so a kill its agent never
# acknowledged has to stop the relaunch rather than be discarded.
# A mate stopped on purpose (bin/fm-control.sh <id> exit, for example before a
# migration) carries state/<id>.held-stopped; session start must leave it down.
test_sweep_leaves_a_deliberately_stopped_secondmate_down() {
  local w fb out
  w=$(new_world sweep-held)
  add_sm_home "$w" sm1
  endpoint_mode "$w" sm1 zsh
  printf 'stopped_at=1\n' > "$w/home/state/sm1.held-stopped"
  fb=$(make_toolchain "$w")

  out=$(run_bootstrap "$fb" "$w/home")

  untouched "$w" sm1 || fail "session start relaunched a secondmate stopped on purpose: $out"
  assert_contains "$out" "secondmate sm1: skipped: stopped on purpose" \
    "a deliberately stopped secondmate should be reported as skipped: $out"
  [ ! -e "$w/home/state/.control-sm1.lock" ] && [ ! -L "$w/home/state/.control-sm1.lock" ] \
    || fail "startup recovery kept its lifecycle lock after honoring a deliberate stop"
  pass "sweep: a secondmate stopped on purpose is left down and reported"
}

test_sweep_skips_a_secondmate_with_a_live_control_lock() {
  local w fb out holder
  w=$(new_world sweep-control-held)
  add_sm_home "$w" sm1
  endpoint_mode "$w" sm1 zsh
  fb=$(make_toolchain "$w")

  FM_HOME="$w/home" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    lock="$STATE/.control-sm1.lock"
    fm_lock_try_acquire "$lock" || exit 1
    trap '\''fm_lock_release "$lock"'\'' EXIT
    : > "$2/control-ready"
    while [ ! -e "$2/control-release" ]; do sleep 0.1; done
  ' _ "$ROOT" "$w" &
  holder=$!
  fm_test_track_helper_pid "$holder"
  for _ in $(seq 100); do
    [ ! -e "$w/control-ready" ] || break
    sleep 0.1
  done
  [ -e "$w/control-ready" ] || fail "the lifecycle lock holder did not start"

  out=$(run_bootstrap "$fb" "$w/home")

  untouched "$w" sm1 || fail "session start touched a secondmate under lifecycle control: $out"
  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: another lifecycle action is already running" \
    "an active lifecycle action should make startup recovery skip the mate: $out"
  [ "$(cat "$w/home/state/.control-sm1.lock/pid")" = "$holder" ] \
    || fail "startup recovery changed the live lifecycle lock"
  kill -0 "$holder" 2>/dev/null || fail "startup recovery stopped the lifecycle lock holder"

  touch "$w/control-release"
  wait "$holder" || fail "the lifecycle lock holder did not exit cleanly"
  out=$(run_bootstrap "$fb" "$w/home")
  endpoint_closed "$w" sm1 || fail "startup recovery did not close the dead endpoint after control released it: $out"
  relaunched "$w" sm1 || fail "startup recovery did not relaunch the mate after control released it: $out"
  [ ! -e "$w/home/state/.control-sm1.lock" ] && [ ! -L "$w/home/state/.control-sm1.lock" ] \
    || fail "startup recovery left its lifecycle lock held after relaunch"
  pass "sweep: a live lifecycle lock prevents recovery until its owner releases it"
}

test_sweep_skips_relaunch_when_the_endpoint_kill_is_unconfirmed() {
  local w fb out
  w=$(new_world sweep-kill-unconfirmed)
  add_sm_home "$w" sm1
  endpoint_mode "$w" sm1 unconfirmed-kill
  fb=$(make_toolchain "$w")

  out=$(run_bootstrap "$fb" "$w/home")

  assert_contains "$out" "secondmate sm1: skipped: the existing endpoint was not confirmed gone" \
    "an unconfirmed kill must be reported rather than discarded: $out"
  relaunched "$w" sm1 && fail "the sweep relaunched onto an endpoint nothing proved gone"
  assert_present "$w/home/state/sm1.meta" "the skipped secondmate lost its record"
  [ ! -e "$w/home/state/.control-sm1.lock" ] && [ ! -L "$w/home/state/.control-sm1.lock" ] \
    || fail "startup recovery kept its lifecycle lock after an unconfirmed kill"
  pass "sweep: an endpoint whose kill nothing confirmed is reported and not relaunched onto"
}

test_sweep_leaves_alive_secondmate_untouched() {
  local w fb out
  w=$(new_world sweep-alive)
  add_sm_home "$w" sm1
  endpoint_mode "$w" sm1 fm-deck-worker
  fb=$(make_toolchain "$w")

  out=$(run_bootstrap "$fb" "$w/home")

  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1" \
    "an already-live secondmate should be handled silently: $out"
  untouched "$w" sm1 || fail "an already-live secondmate must never be killed or respawned"

  out=$(run_bootstrap "$fb" "$w/home" FM_BOOTSTRAP_VERBOSE_FACTS=1)
  assert_contains "$out" "BOOTSTRAP_INFO: secondmate sm1 already live (backend=stream)" \
    "verbose diagnostics should identify the already-live outcome"
  untouched "$w" sm1 || fail "verbose reporting must not touch an already-live secondmate"
  pass "sweep: an already-live secondmate is untouched and distinguishable in verbose diagnostics"
}

# The hub's registry is in memory: a hub that restarted answers 404 for every
# endpoint until its agents rejoin, so absence there is not proof the agent is
# gone and never licenses a relaunch beside it.
test_sweep_never_relaunches_a_registry_absent_secondmate() {
  local w fb out
  w=$(new_world sweep-missing-deck)
  add_sm_home "$w" sm1 deck
  endpoint_mode "$w" sm1 missing
  fb=$(make_toolchain "$w")

  out=$(run_bootstrap "$fb" "$w/home")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: absence from the hub registry does not prove the agent is gone" \
    "a registry-absent Deck secondmate should be reported, not relaunched: $out"
  assert_not_contains "$out" "unverified for recovery" \
    "a recorded Deck secondmate should be verified for recovery"
  relaunched "$w" sm1 && fail "a registry-absent Deck secondmate was relaunched beside a possibly running agent"
  pass "sweep: a secondmate the hub registry has no record of is reported and never relaunched"
}

test_sweep_never_acts_on_ambiguous_existing_process() {
  local w fb out
  w=$(new_world sweep-ambiguous)
  add_sm_home "$w" sm1
  endpoint_mode "$w" sm1 node
  fb=$(make_toolchain "$w")

  out=$(run_bootstrap "$fb" "$w/home")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: existing endpoint has ambiguous agent process" \
    "an existing unclassifiable process should be reported as ambiguous"
  untouched "$w" sm1 || fail "an ambiguous existing process must never trigger kill or relaunch"
  pass "sweep: an existing ambiguous process prevents duplicate recovery"
}

test_sweep_never_acts_on_transient_unreadability() {
  local w fb out
  w=$(new_world sweep-unreadable)
  add_sm_home "$w" sm1
  endpoint_mode "$w" sm1 unreadable
  fb=$(make_toolchain "$w")

  out=$(run_bootstrap "$fb" "$w/home")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: endpoint probe unreadable" \
    "a transiently unreadable target should be distinguished from an absent one"
  untouched "$w" sm1 || fail "an unreadable target must never trigger kill or relaunch"
  pass "sweep: transient target unreadability never licenses recovery"
}

test_sweep_reports_dead_endpoint_relaunch_failure() {
  local w fb out
  w=$(new_world sweep-relaunch-failure)
  add_sm_home "$w" sm1
  endpoint_mode "$w" sm1 zsh
  fb=$(make_toolchain "$w")
  # The relaunch cannot resolve the recorded harness's executable.
  rm -f "$fb/deck"

  out=$(PATH="$fb:$BASE_PATH" FM_HOME="$w/home" "$ROOT/bin/fm-bootstrap.sh" 2>&1)

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: respawn failed after confirmed agent absence on existing endpoint" \
    "a failed relaunch should retain its authorizing cause: $out"
  [ ! -e "$w/home/state/.control-sm1.lock" ] && [ ! -L "$w/home/state/.control-sm1.lock" ] \
    || fail "startup recovery kept its lifecycle lock after a failed relaunch"
  pass "sweep: failed relaunch diagnostics name the confirmed absence that authorized it"
}

test_sweep_never_acts_on_unverified_harness_dead_reading() {
  local w fb out harness
  for harness in custom-agent claude; do
    w=$(new_world "sweep-unverified-$harness")
    add_sm_home "$w" sm1 "$harness"
    endpoint_mode "$w" sm1 zsh
    fb=$(make_toolchain "$w")

    out=$(run_bootstrap "$fb" "$w/home")

    assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: recorded harness '$harness' is unverified for recovery" \
      "an unverified harness ($harness) should not let a dead endpoint become actionable: $out"
    untouched "$w" sm1 || fail "an unverified harness ($harness) must never trigger kill or relaunch"
  done
  pass "sweep: an unverified or removed-adapter harness blocks recovery with a concrete diagnostic"
}

# A secondmate whose record names a backend with no adapter (the retired tmux
# and Herdr, or zellij) cannot be classified at all, so the sweep leaves it to
# the operator rather than relaunching it somewhere else.
test_sweep_never_acts_on_a_retired_backend_record() {
  local w fb out before
  w=$(new_world sweep-retired)
  add_sm_home "$w" sm1 deck tmux
  before=$(cat "$w/home/state/sm1.meta")
  fb=$(make_toolchain "$w")

  out=$(run_bootstrap "$fb" "$w/home")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped:" \
    "a record on a retired backend should be reported: $out"
  [ "$(cat "$w/home/state/sm1.meta")" = "$before" ] \
    || fail "the sweep rewrote or relaunched a record on a retired backend"
  pass "sweep: a record on a retired backend is reported and never relaunched"
}

# Deck hosts secondmates on the stream backend, so a dead Deck endpoint is
# recovery-authorized: the sweep closes the endpoint it proved agent-free and
# relaunches the mate on its recorded harness.
test_sweep_recovers_confirmed_dead_deck_secondmate() {
  local w fb out
  w=$(new_world sweep-deck)
  printf 'deck\n' > "$w/home/config/secondmate-harness"
  add_sm_home "$w" sm1 deck
  endpoint_mode "$w" sm1 zsh
  fb=$(make_toolchain "$w")
  fm_fake_exit0 "$fb" deck

  out=$(run_bootstrap "$fb" "$w/home")

  assert_not_contains "$out" "unverified for recovery" \
    "a recorded deck secondmate should be verified for recovery: $out"
  assert_not_contains "$out" "respawn failed" \
    "a confirmed-dead deck secondmate should be relaunched: $out"
  endpoint_closed "$w" sm1 || fail "the dead deck endpoint must be closed before respawn"
  relaunched "$w" sm1 || fail "a confirmed-dead deck secondmate should actually be relaunched"
  pass "sweep: a confirmed-dead deck secondmate endpoint is closed and respawned"
}

test_sweep_converges_no_retouch_once_alive() {
  local w fb out1 out2
  w=$(new_world sweep-idempotent)
  add_sm_home "$w" sm1
  endpoint_mode "$w" sm1 zsh
  fb=$(make_toolchain "$w")

  # Round 1: dead -> respawned silently onto a new endpoint.
  out1=$(run_bootstrap "$fb" "$w/home")
  assert_not_contains "$out1" "SECONDMATE_LIVENESS: secondmate sm1" "round 1 should handle the successful respawn silently: $out1"
  relaunched "$w" sm1 || fail "round 1 should have respawned the dead secondmate"

  # Round 2: the (now-respawned) secondmate is genuinely alive - a second
  # sweep must converge to a pure no-op, not respawn again.
  sed -n 's/^window=//p' "$w/home/state/sm1.meta" > "$w/sm1.target"
  endpoint_mode "$w" sm1 fm-deck-worker
  out2=$(run_bootstrap "$fb" "$w/home")
  assert_not_contains "$out2" "SECONDMATE_LIVENESS: secondmate sm1" "round 2 should handle the already-live secondmate silently: $out2"
  untouched "$w" sm1 || fail "round 2 must not re-kill or re-respawn an already-live secondmate"
  pass "sweep: idempotent by construction - a live secondmate is never re-touched on a later run"
}

test_sweep_skipped_under_detect_only() {
  local w fb out
  w=$(new_world sweep-detect-only)
  add_sm_home "$w" sm1
  endpoint_mode "$w" sm1 zsh
  printf 'deck\n' > "$w/home/config/crew-harness"
  fb=$(make_toolchain "$w")

  out=$(run_bootstrap "$fb" "$w/home" FM_BOOTSTRAP_DETECT_ONLY=1)

  assert_not_contains "$out" "CREW_HARNESS_OVERRIDE:" \
    "detect-only should keep routine harness facts silent"
  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "the read-only detect-only path must never run the mutating liveness sweep"
  untouched "$w" sm1 || fail "detect-only must never touch any endpoint"
  pass "sweep: skipped entirely under FM_BOOTSTRAP_DETECT_ONLY=1, exactly like the other mutating sweeps"
}

test_sweep_noop_with_no_secondmate_meta() {
  local w fb out before
  w=$(new_world sweep-no-secondmates)
  # No add_sm_home call: this state/ dir looks exactly like what a
  # secondmate's OWN home always has (secondmates never spawn secondmates),
  # proving the sweep's primary-only scoping falls out naturally.
  fb=$(make_toolchain "$w")
  before=$(fm_test_fake_stream_endpoints | jq -c '[.endpoints[] | {endpoint_id, closed_by}]')

  out=$(run_bootstrap "$fb" "$w/home")

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "with no kind=secondmate meta present, the sweep must print nothing"
  [ "$(fm_test_fake_stream_endpoints | jq -c '[.endpoints[] | {endpoint_id, closed_by}]')" = "$before" ] \
    || fail "with no secondmate meta, no endpoint should ever be touched"
  pass "sweep: a silent no-op with no kind=secondmate meta present (a secondmate home's own natural scoping)"
}

test_stream_agent_state_classifies
test_agent_state_dispatcher_and_compatibility
test_sweep_respawns_confirmed_dead_secondmate
test_sweep_leaves_a_deliberately_stopped_secondmate_down
test_sweep_skips_a_secondmate_with_a_live_control_lock
test_sweep_skips_relaunch_when_the_endpoint_kill_is_unconfirmed
test_sweep_leaves_alive_secondmate_untouched
test_sweep_never_relaunches_a_registry_absent_secondmate
test_sweep_never_acts_on_ambiguous_existing_process
test_sweep_never_acts_on_transient_unreadability
test_sweep_reports_dead_endpoint_relaunch_failure
test_sweep_never_acts_on_unverified_harness_dead_reading
test_sweep_never_acts_on_a_retired_backend_record
test_sweep_recovers_confirmed_dead_deck_secondmate
test_sweep_converges_no_retouch_once_alive
test_sweep_skipped_under_detect_only
test_sweep_noop_with_no_secondmate_meta

echo "# all fm-secondmate-liveness tests passed"
