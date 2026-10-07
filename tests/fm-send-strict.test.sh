#!/usr/bin/env bash
# fm-send strict target resolution and key delivery reporting.
#
# A send that cannot be tied to a recorded task/lane or to an explicit
# well-formed backend target must fail loudly. These tests pin the historical
# silent-fallback failures: missing FM_HOME, unresolved selectors, dead explicit
# endpoints, and the healthy exact/fm-id paths.
# They also verify that a key send reports whether delivery actually succeeded.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-strict)

# make_stubs (tests/fixtures.sh) is a no-op sleep; every endpoint is a fake
# stream endpoint whose launch log records each text and key it receives.

setup_home() {  # <name> -> echoes home dir
  local home="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

test_exact_lane_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/exact"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home exact); err="$dir/send.err"; log="$dir/endpoint.log"; : > "$log"
  { fm_test_stream_task "$home/state" mpf-lane-m8 "$log"; printf 'kind=ship\n'; } > "$home/state/mpf-lane-m8.meta" \
    || fail "could not register the lane endpoint"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 \
    "$SEND" mpf-lane-m8 "lost dispatch" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "exact task id send should succeed when metadata exists"$'\n'"$(cat "$err")"
  got=$(cat "$log")
  assert_contains "$got" ": Firstmate instruction waiting" "exact id should ring the doorbell at the meta target"
  assert_contains "$(cat "$log.keys")" "[key] Enter" "exact id should submit the doorbell with Enter"
  grep -qF 'lost dispatch' "$home/state/mpf-lane-m8.inbox/001.msg" \
    || fail "exact id should record the steer in the task inbox"
  pass "fm-send strict: exact task/lane ids resolve through home metadata"
}

test_unset_fm_home_fails() {
  local dir fb err rc
  dir="$TMP_ROOT/nohome"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); err="$dir/send.err"

  env -u FM_HOME PATH="$fb:$PATH" FM_ROOT_OVERRIDE="$dir" FM_SEND_SETTLE=0 \
    "$SEND" hub-zz:0000abcd "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unset FM_HOME should fail"
  assert_contains "$(cat "$err")" "FM_HOME is not set" "unset FM_HOME diagnostic should be explicit"
  pass "fm-send strict: unset FM_HOME fails before target resolution"
}

test_unresolvable_target_is_refused() {
  local dir fb home err rc
  dir="$TMP_ROOT/unresolved"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home unresolved); err="$dir/send.err"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 \
    "$SEND" lost-target "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "unresolvable target should fail"
  assert_contains "$(cat "$err")" "not resolvable" "unresolvable diagnostic should be loud"
  assert_contains "$(cat "$err")" "metadata window/terminal lookup" "unresolvable diagnostic should name the attempted lookup"
  assert_contains "$(cat "$err")" "backend=none" "unresolvable diagnostic should name that no backend was assumed"
  pass "fm-send strict: an unresolvable selector is refused, never guessed"
}

test_unmatched_single_colon_target_must_exist() {
  local dir fb home err rc target
  dir="$TMP_ROOT/dead-explicit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home deadexplicit); err="$dir/send.err"
  fm_test_fake_stream_ensure || fail "fake stream hub did not start"
  # This hub's tag, but an endpoint the hub never registered.
  target="$FM_TEST_STREAM_TAG:0000dead0000dead0000dead0000dead"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 \
    "$SEND" "$target" "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a dead explicit stream target should fail"
  assert_contains "$(cat "$err")" "not a live stream endpoint" "dead explicit target diagnostic should name the backend"
  assert_contains "$(cat "$err")" "backend=stream" "dead explicit target diagnostic should name the tried backend"
  pass "fm-send strict: unmatched explicit targets must verify live before sending"
}

# A stream endpoint no record in this home names (a child home's crewmate, or
# one reached by hand) is "<hub-tag>:<endpoint-id>". On this home's configured
# hub it routes to stream; the same shape tagged for another hub is refused.
test_unrecorded_stream_target_routes_to_stream() {
  local dir fb home err rc pair target foreign
  if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    pass "fm-send strict: stream routing skipped (jq/curl unavailable)"
    return 0
  fi
  dir="$TMP_ROOT/stream-explicit"; mkdir -p "$dir/cwd"
  fb=$(make_stubs "$dir"); home=$(setup_home streamexplicit); err="$dir/send.err"
  fm_test_fake_stream "$dir" || fail "fake stream hub did not start"
  pair=$(FM_HOME="$home" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source stream && fm_backend_stream_create_task fm-elsewhere "$2"' _ "$ROOT" "$dir/cwd") \
    || fail "could not create the unrecorded stream endpoint"
  target="${pair%% *}:${pair##* }"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 \
    "$SEND" "$target" "hello stream" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "an unrecorded stream target on this home's hub should send"$'\n'"$(cat "$err")"
  assert_equals "hello stream" "$(fm_test_fake_stream_submitted "$target")" "the text should reach the stream endpoint"

  foreign="other-hub-7717:${target#*:}"
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 \
    "$SEND" "$foreign" "hello" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "a stream-shaped target for another hub should not send"
  assert_contains "$(cat "$err")" "not a live stream endpoint on this home's hub" "a target tagged for another hub should be refused"
  pass "fm-send strict: an unrecorded stream target on this home's hub routes to stream, another hub's is refused"
}

test_healthy_fm_id_send_still_works() {
  local dir fb home err log rc got
  dir="$TMP_ROOT/healthy"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home healthy); err="$dir/send.err"; log="$dir/endpoint.log"; : > "$log"
  { fm_test_stream_task "$home/state" lane-ok "$log"; printf 'kind=ship\nharness=deck\n'; } > "$home/state/lane-ok.meta" \
    || fail "could not register the lane endpoint"

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 \
    "$SEND" fm-lane-ok "hello captain" >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "healthy fm-id send should succeed"$'\n'"$(cat "$err")"
  got=$(cat "$log")
  assert_contains "$got" ": Firstmate instruction waiting" "healthy send should ring the doorbell at the meta target"
  assert_contains "$(cat "$log.keys")" "[key] Enter" "healthy send should submit the doorbell with Enter"
  grep -qF 'hello captain' "$home/state/lane-ok.inbox/001.msg" \
    || fail "healthy send should record the steer in the task inbox"
  assert_contains "$(cat "$err")" "requested message WILL still be sent" "fm-send guard banner should keep send-specific continuation wording"
  pass "fm-send strict: healthy fm-<id> sends record the steer and ring once"
}

# A --key send is how firstmate interrupts a worker, so its exit status is the
# only signal that the interrupt actually landed.
# Reporting success for a key that was never delivered would leave supervision
# believing a runaway worker had been stopped, so the failing case must exit
# nonzero and name the key.
# Both directions are asserted from one stub so the failing case cannot go
# quietly vacuous if the key ever stops being delivered at all.
test_key_send_exit_status_follows_delivery() {
  local dir fb home err log rc target
  dir="$TMP_ROOT/key-exit"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); home=$(setup_home keyexit); err="$dir/send.err"; log="$dir/endpoint.log"; : > "$log"
  { fm_test_stream_task "$home/state" lane-key "$log"; printf 'kind=ship\n'; } > "$home/state/lane-key.meta" \
    || fail "could not register the lane endpoint"
  target=$(fm_test_stream_target_of "$home/state" lane-key)

  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 \
    "$SEND" lane-key --key Escape >/dev/null 2>"$err"; rc=$?
  expect_code 0 "$rc" "a delivered --key interrupt should report success"$'\n'"$(cat "$err")"
  assert_contains "$(cat "$log.keys")" "[key] Escape" "the delivered case should send the named key"

  : > "$log"; : > "$log.keys"
  fm_test_fake_stream_set "$target" '{"fail_keys": ["Escape"]}'
  PATH="$fb:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$home" FM_SEND_SETTLE=0 \
    "$SEND" lane-key --key Escape >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "an undelivered --key interrupt reported success"
  assert_contains "$(cat "$err")" "key 'Escape' not sent" "the undelivered case should name the key that failed"
  assert_contains "$(cat "$log.keys")" "[key-failed] Escape" "the undelivered case should still have attempted the send"
  pass "fm-send --key: exit status follows delivery, and an undelivered key never reports success"
}

test_exact_lane_id_send_still_works
test_key_send_exit_status_follows_delivery
test_unset_fm_home_fails
test_unresolvable_target_is_refused
test_unmatched_single_colon_target_must_exist
test_unrecorded_stream_target_routes_to_stream
test_healthy_fm_id_send_still_works
