#!/usr/bin/env bash
set -u

# shellcheck source=tests/fm-control-relaunch.test.sh
FM_MODEL_CHAIN_TEST_SKIP_RUN=1 . "$(dirname "${BASH_SOURCE[0]}")/fm-control-relaunch.test.sh"

test_stop_boundary_activity() {
  local mode=$1 route=$2 guarded=$3 dir gen before brief out rc
  local -a args
  dir=$(new_case "stop-boundary-$mode-$route-$guarded" stopped)
  add_ship_task "$dir" stopped
  cp -R "$ROOT/bin" "$dir/bin"
  CONTROL="$dir/bin/fm-control.sh"
  cat > "$dir/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: paused · source: status-log · waiting\n'
SH
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" stopped --state idle)
  printf 'busy_gen=%s\n' "$gen" >> "$dir/home/state/stopped.meta"
  printf 'paused: waiting\n' > "$dir/home/state/stopped.status"
  before=$(cat "$dir/home/state/stopped.meta")
  brief=$(cat "$dir/home/data/stopped/brief.md")
  cat > "$dir/resume" <<SH
#!/usr/bin/env bash
[ "\$1" = GET ] && [ "\$2" = '$route' ] || exit 0
[ ! -f '$dir/resumed' ] || exit 0
[ "\$(sed -n 's/^phase=//p' '$dir/home/state/stopped.control-relaunch')" = stopping ] || exit 0
: > '$dir/resumed'
case '$mode' in
  busy) '$dir/bin/fm-busy-event.sh' apply '$dir/home/state' stopped busy --current-gen --source deck-wrapper --event turn-start ;;
  status) printf 'working: resumed\n' >> '$dir/home/state/stopped.status' ;;
esac
SH
  chmod +x "$dir/resume" "$dir/bin/fm-crew-state.sh"
  args=(stopped relaunch --note 'Continue the unfinished work')
  if [ "$guarded" = yes ]; then
    args+=(--expected-record "$before" --if-still-stopped "$(wc -c < "$dir/home/state/stopped.status" | tr -d ' ')")
  fi

  out=$(FM_FAKE_ON_REQUEST="$dir/resume" run_control "$dir" "${args[@]}"); rc=$?

  assert_present "$dir/resumed" "$mode must resume during the $route preflight"
  if [ "$guarded" = yes ]; then
    expect_code 3 "$rc" "guarded retry must refuse $mode during $route: $out"
    assert_contains "$out" 'changed during scan' 'the caller must receive an activity refusal'
    assert_equals "$before" "$(cat "$dir/home/state/stopped.meta")" 'refusal must preserve the incarnation'
    assert_equals "$brief" "$(cat "$dir/home/data/stopped/brief.md")" 'refusal must restore the instructions'
    assert_equals fm-deck-worker "$(cat "$dir/fake/command")" 'the resumed agent must remain alive'
    [ ! -s "$dir/fake/keys" ] || fail 'guarded refusal must send no interrupt or exit keys'
    [ ! -s "$dir/fake/literal" ] || fail 'guarded refusal must send no exit or launch text'

    "$dir/bin/fm-busy-event.sh" apply "$dir/home/state" stopped idle --current-gen --source deck-wrapper --event turn-end >/dev/null
    out=$(run_control "$dir" stopped relaunch --note 'Retry after the worker stops again' \
      --expected-record "$before" --if-still-stopped "$(wc -c < "$dir/home/state/stopped.status" | tr -d ' ')"); rc=$?
    expect_code 0 "$rc" "a later stopped stretch must remain eligible for retry: $out"
  else
    expect_code 0 "$rc" "unguarded relaunch must keep its interrupt behavior: $out"
    assert_equals C-c "$(cat "$dir/fake/keys" | head -n 1)" 'unguarded relaunch must interrupt the busy worker'
  fi
  assert_grep '/quit' "$dir/fake/literal" 'an admitted relaunch must exit the old agent'
  assert_grep 'encode launch-brief' "$dir/fake/literal" 'an admitted relaunch must launch the replacement'
  pass "fm-control guarded relaunch: $mode during $route (guarded=$guarded)"
}

for route in processes screen; do
  for mode in busy status; do
    test_stop_boundary_activity "$mode" "$route" yes
  done
done
test_stop_boundary_activity busy processes no
