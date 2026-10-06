#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh concrete dispatch profile flags.
#
# These tests drive fm-spawn through meta writing and launch construction with a
# fake tmux pane and a real isolated git worktree. The fake tmux captures the
# literal launch command sent with `tmux send-keys -l`, so assertions pin the
# command firstmate would run without starting any real harness.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-dispatch-profile)

make_spawn_pi_probe() {
  local fakebin=$1 tool=$2
  cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  if [ "${FM_FAKE_PI_VERSION:-0.84.0}" = 0.82.0 ]; then
    printf '%s\n' 'Pi 0.82.0' 'Options: --help'
  else
    printf '%s\n' "Pi ${FM_FAKE_PI_VERSION:-0.84.0}" 'Options: --help --tui-mode <mode>'
  fi
fi
exit 0
SH
  chmod +x "$fakebin/$tool"
}

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$dir")
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != -k ] || shift 2
shift
exec "$@"
SH
  chmod +x "$fakebin/timeout"
  make_spawn_pi_probe "$fakebin" pi
  make_spawn_pi_probe "$fakebin" pi-signed
  fm_test_fake_deck "$fakebin"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

enable_dispatch_profile() {
  local home=$1
  printf '%s\n' '{"rules":[{"when":"current events","use":{"harness":"deck","model":"example/route"}}],"default":{"harness":"pi","model":"openai-codex/gpt-5","effort":"medium"}}' \
    > "$home/config/crew-dispatch.json"
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PI_VERSION="${FM_TEST_PI_VERSION:-0.84.0}" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@"
}

# Ship spawns carry an explicit delivery contract (AGENTS.md section 7); these
# tests are about profile resolution, so they pass a fixed valid one.
run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

assert_meta_profile() {
  local meta=$1 harness=$2 model=$3 effort=$4
  assert_grep "harness=$harness" "$meta" "meta missing harness=$harness"
  assert_grep "model=$model" "$meta" "meta missing model=$model"
  assert_grep "effort=$effort" "$meta" "meta missing effort=$effort"
}

test_no_profile_keeps_pi_profile_defaults() {
  local rec id out status expected launch
  id=profile-off-z1
  rec=$(make_spawn_case profile-off pi "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "pi spawn without profile flags should succeed"
  assert_contains "$out" "spawned $id harness=pi" "spawn did not report pi"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi default default

  launch=$(cat "$LAUNCH_LOG")
  expected="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS FM_PI_HARNESS=pi '$FAKEBIN_DIR/pi' --tui-mode regular -e '$HOME_DIR/state/$id.pi-ext.ts' \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/launch-brief.md')\""
  [ "$launch" = "$expected" ] || fail "no-profile pi launch did not use the canonical launch kind"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  assert_not_contains "$launch" "--model" "no-profile pi launch invented a model flag"
  assert_not_contains "$launch" "--thinking" "no-profile pi launch invented a thinking flag"
  pass "no --model/--effort records defaults and types the canonical pi launch"
}

test_non_cursor_launch_clears_inherited_cursor_markers() {
  local rec id out status launch
  id=profile-deck-cursor-markers-z1b
  rec=$(make_spawn_case profile-deck-cursor-markers deck "$id")
  read_case_record "$rec"

  out=$(CURSOR_AGENT=1 CURSOR_INVOKED_AS=cursor-agent \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "deck spawn under Cursor markers should succeed: $out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS env -u CLAUDECODE" \
    "non-cursor launch must clear both inherited Cursor identity markers"
  pass "non-cursor launches clear inherited Cursor identity markers"
}

test_relative_home_overrides_launch_with_absolute_cross_process_paths() {
  local rec id out status launch home_real
  id=profile-relative-paths-z1b
  rec=$(make_spawn_case profile-relative-paths pi "$id")
  read_case_record "$rec"
  home_real=$(cd "$HOME_DIR" && pwd -P)
  mkdir -p "$CASE_DIR/cdpath/home/state" "$CASE_DIR/cdpath/home/data"
  : > "$LAUNCH_LOG"

  out=$(
    cd "$CASE_DIR" || exit 1
    CDPATH="$CASE_DIR/cdpath" FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=home/state FM_DATA_OVERRIDE=home/data \
      FM_PROJECTS_OVERRIDE=home/projects FM_CONFIG_OVERRIDE=home/config \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with relative home overrides should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$home_real/state/$id.pi-ext.ts'" \
    "relative FM_STATE_OVERRIDE leaked into Pi's cross-process extension path"
  assert_contains "$launch" "< '$home_real/data/$id/launch-brief.md'" \
    "relative FM_DATA_OVERRIDE leaked into the cross-process brief path"
  pass "relative home overrides ignore CDPATH and become absolute before spawn launch construction"
}

test_home_defaults_preserve_absolute_or_resolve_relative_paths() {
  local rec relative_id absolute_id out status launch home_real linked_home
  relative_id=profile-relative-home-defaults-z1c
  absolute_id=profile-absolute-home-defaults-z1d
  rec=$(make_spawn_case profile-home-defaults pi "$relative_id" "$absolute_id")
  read_case_record "$rec"
  home_real=$(cd "$HOME_DIR" && pwd -P)

  : > "$LAUNCH_LOG"
  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      FM_PROJECTS_OVERRIDE=home/projects FM_CONFIG_OVERRIDE=home/config \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$relative_id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with relative FM_HOME defaults should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$home_real/state/$relative_id.pi-ext.ts'" \
    "relative FM_HOME leaked into Pi's default cross-process extension path"
  assert_contains "$launch" "< '$home_real/data/$relative_id/launch-brief.md'" \
    "relative FM_HOME leaked into the default cross-process brief path"

  linked_home="$CASE_DIR/home-link"
  ln -s "$HOME_DIR" "$linked_home"
  : > "$LAUNCH_LOG"
  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$linked_home" \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      FM_PROJECTS_OVERRIDE="$linked_home/projects" FM_CONFIG_OVERRIDE="$linked_home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$absolute_id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with absolute symlink-spelled FM_HOME defaults should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$linked_home/state/$absolute_id.pi-ext.ts'" \
    "absolute FM_HOME spelling changed in Pi's default cross-process extension path"
  assert_contains "$launch" "< '$linked_home/data/$absolute_id/launch-brief.md'" \
    "absolute FM_HOME spelling changed in the default cross-process brief path"
  pass "FM_HOME defaults resolve relative paths and preserve absolute spellings"
}

test_absolute_override_spelling_is_preserved_in_launch_paths() {
  local rec id out status launch linked_home
  id=profile-absolute-paths-z1c
  rec=$(make_spawn_case profile-absolute-paths pi "$id")
  read_case_record "$rec"
  linked_home="$CASE_DIR/home-link"
  ln -s "$HOME_DIR" "$linked_home"
  : > "$LAUNCH_LOG"

  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$linked_home" \
      FM_STATE_OVERRIDE="$linked_home/state" FM_DATA_OVERRIDE="$linked_home/data" \
      FM_PROJECTS_OVERRIDE="$linked_home/projects" FM_CONFIG_OVERRIDE="$linked_home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with absolute symlink-spelled overrides should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$linked_home/state/$id.pi-ext.ts'" \
    "absolute FM_STATE_OVERRIDE spelling changed in Pi's cross-process extension path"
  assert_contains "$launch" "< '$linked_home/data/$id/launch-brief.md'" \
    "absolute FM_DATA_OVERRIDE spelling changed in the cross-process brief path"
  pass "absolute override spellings are preserved in spawn launch paths"
}

test_unresolvable_relative_overrides_fail_loudly() {
  local rec id out status
  id=profile-unresolvable-paths-z1d
  rec=$(make_spawn_case profile-unresolvable-paths pi "$id")
  read_case_record "$rec"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=missing-home \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative home should fail"
  assert_contains "$out" "FM_HOME directory cannot be resolved: missing-home" \
    "spawn did not name the unresolvable FM_HOME"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=missing-state FM_DATA_OVERRIDE=home/data \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative state override should fail"
  assert_contains "$out" "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" \
    "spawn did not name the unresolvable FM_STATE_OVERRIDE"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=home/state FM_DATA_OVERRIDE=missing-data \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative data override should fail"
  assert_contains "$out" "FM_DATA_OVERRIDE directory cannot be resolved: missing-data" \
    "spawn did not name the unresolvable FM_DATA_OVERRIDE"
  pass "unresolvable relative spawn overrides fail with named diagnostics"
}

test_active_dispatch_profile_requires_explicit_harness_for_ship() {
  local rec id out status
  id=profile-required-ship-z11
  rec=$(make_spawn_case profile-required-ship pi "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "ship spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "spawn did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "ship refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for ship spawns"
}

test_active_dispatch_profile_requires_explicit_harness_for_scout() {
  local rec id out status
  id=profile-required-scout-z12
  rec=$(make_spawn_case profile-required-scout pi "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 1 "$status" "scout spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "scout refusal did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "scout refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for scout spawns"
}

test_active_dispatch_profile_allows_explicit_harness() {
  local rec id out status launch
  id=profile-explicit-z13
  rec=$(make_spawn_case profile-explicit pi "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness pi-signed --model openai-codex/gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "explicit harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=pi-signed" "spawn did not report explicit pi-signed harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi-signed openai-codex/gpt-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed '$FAKEBIN_DIR/pi-signed' --tui-mode regular --model 'openai-codex/gpt-5' --thinking 'high' -e" \
    "explicit harness launch did not thread model and effort"
  pass "active crew-dispatch profile allows an explicit resolved harness"
}

test_active_dispatch_profile_allows_positional_harness() {
  local rec id out status
  id=profile-positional-z14
  rec=$(make_spawn_case profile-positional pi "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" deck --model example/route)
  status=$?
  expect_code 0 "$status" "positional harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=deck" "spawn did not report positional deck harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" deck example/route default
  pass "active crew-dispatch profile allows the legacy positional harness form"
}

test_active_dispatch_profile_allows_raw_launch_command() {
  local rec id out status launch
  id=profile-raw-z15
  rec=$(make_spawn_case profile-raw pi "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "custom-agent --flag")
  status=$?
  expect_code 0 "$status" "raw launch command should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=custom-agent" "spawn did not report raw command harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" custom-agent default default
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "custom-agent --flag" ] || fail "raw launch command changed"$'\n'"actual: $launch"
  pass "active crew-dispatch profile allows the raw launch-command escape hatch"
}

test_native_effort_validator_keeps_axes_separate() {
  local harness
  for harness in pi pi-signed; do
    "$ROOT/bin/fm-harness.sh" validate-native-effort "$harness" codex-native/gpt-6-astra ultra \
      || fail "native validator refused supported harness $harness"
  done
  if "$ROOT/bin/fm-harness.sh" validate-native-effort 'pi:codex-native/forged' '' ultra 2>/dev/null; then
    fail "native validator accepted a model prefix embedded in the harness axis"
  fi
  pass "native effort validator checks harness and model as separate axes"
}

test_native_pi_ultra_is_explicit_and_model_scoped() {
  local rec id out launch harness mode native_profile model
  for harness in pi pi-signed; do
    for mode in no-mistakes direct-PR; do
      id="ultra-$harness-$mode"
      rec=$(make_spawn_case "$id" "$harness" "$id")
      read_case_record "$rec"
      out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
        --harness "$harness" --model codex-native/gpt-6-astra --effort ultra --mode "$mode" --yolo off)
      expect_code 0 "$?" "native Ultra spawn failed: $out"
      assert_meta_profile "$HOME_DIR/state/$id.meta" "$harness" codex-native/gpt-6-astra ultra
      launch=$(cat "$LAUNCH_LOG")
      assert_contains "$launch" "--model 'codex-native/gpt-6-astra' --codex-effort 'ultra'" "native Ultra flag missing"
      assert_not_contains "$launch" "--thinking" "native Ultra was converted into Pi thinking"
      assert_not_contains "$launch" "'max'" "native Ultra was aliased to max"
    done
  done
  for native_profile in 'pi:openai-codex/gpt-6-astra' 'pi-signed:openai-codex/gpt-6-astra' 'pi:default' 'pi:codex-native/'; do
    harness=${native_profile%%:*}; model=${native_profile#*:}; id="ultra-refused-$RANDOM"
    rec=$(make_spawn_case "$id" "$harness" "$id")
    read_case_record "$rec"
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --harness "$harness" --model "$model" --effort ultra 2>&1)
    expect_code 1 "$?" "unsupported Ultra profile should refuse: $native_profile"
    assert_contains "$out" "ultra effort requires pi or pi-signed" "native-only refusal missing"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "unsupported Ultra published metadata"
    [ ! -e "$HOME_DIR/state/$id.busy-gen" ] || fail "unsupported Ultra provisioned lifecycle wiring"
    [ ! -s "$LAUNCH_LOG" ] || fail "unsupported Ultra launched an agent"
  done
  id=ultra-raw-refused
  rec=$(make_spawn_case "$id" pi "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    'pi --offline' --model codex-native/gpt-6-astra --effort ultra 2>&1)
  expect_code 1 "$?" "raw launch silently omitted the native Ultra flag"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "raw Ultra launch published metadata"
  assert_contains "$out" "canonical --harness pi or pi-signed" "raw launch refusal was not actionable"
  pass "Ultra is explicit for native Pi and Pi-signed, including direct-PR, and refuses unsupported profiles before provisioning"
}

test_batch_preserves_native_ultra() {
  local rec id1=ultra-batch-a id2=ultra-batch-b out launch
  rec=$(make_spawn_case ultra-batch pi "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness pi --model codex-native/gpt-6-astra --effort ultra)
  expect_code 0 "$?" "native Ultra batch failed: $out"
  assert_meta_profile "$HOME_DIR/state/$id1.meta" pi codex-native/gpt-6-astra ultra
  assert_meta_profile "$HOME_DIR/state/$id2.meta" pi codex-native/gpt-6-astra ultra
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--codex-effort 'ultra'" "batch dropped native effort"
  assert_not_contains "$launch" "--thinking 'ultra'" "batch passed an invalid Pi level"
  pass "batch dispatch preserves native Ultra in metadata and launch flags"
}

test_pi_threads_model_and_max_effort() {
  local rec id out status launch
  id=profile-pi-z8
  rec=$(make_spawn_case profile-pi pi "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-sol --effort max)
  status=$?
  expect_code 0 "$status" "pi spawn with max effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi openai-codex/gpt-5.6-sol max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi '$FAKEBIN_DIR/pi' --tui-mode regular --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "pi launch did not force the regular TUI while threading the requested model and max thinking level"
  assert_not_contains "$launch" "FM_FIRSTMATE_PI_LAUNCH_BRIEF=" \
    "pi launch still exports the removed Calm input-reroute binding"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" \
    "pi launch lost the canonical typed launch-brief envelope"
  pass "pi receives --model and --thinking max profile flags"
}

test_pi_signed_threads_shared_pi_profile_and_preserves_identity() {
  local rec id out status launch
  id=profile-pi-signed-z8b
  rec=$(make_spawn_case profile-pi-signed pi-signed "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-sol --effort max)
  status=$?
  expect_code 0 "$status" "pi-signed spawn with max effort should succeed"
  assert_contains "$out" "spawned $id harness=pi-signed" "pi-signed spawn did not preserve its visible identity"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi-signed openai-codex/gpt-5.6-sol max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed '$FAKEBIN_DIR/pi-signed' --tui-mode regular --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "pi-signed launch did not force the regular TUI with Pi's model, thinking, and extension semantics"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" \
    "pi-signed launch lost the canonical typed launch-brief envelope"
  assert_present "$HOME_DIR/state/$id.pi-ext.ts" "pi-signed launch did not install Pi's turn-end extension"
  assert_present "$HOME_DIR/state/$id.busy-gen" "pi-signed spawn did not arm the busy-state contract"
  assert_contains "$(cat "$HOME_DIR/state/$id.busy-state")" "state=busy source=fm-spawn" \
    "pi-signed spawn did not seed the busy-state record from the launch brief"
  local ext gen
  ext=$(cat "$HOME_DIR/state/$id.pi-ext.ts")
  gen=$(cat "$HOME_DIR/state/$id.busy-gen")
  assert_contains "$ext" 'pi.on("agent_start"' "pi extension lost the semantic agent_start busy edge"
  assert_contains "$ext" 'pi.on("agent_settled"' "pi extension lost the semantic agent_settled idle edge"
  assert_contains "$ext" 'ctx.isIdle()' "pi extension no longer confirms idle with ctx.isIdle()"
  assert_contains "$ext" "\"--gen\", \"$gen\"" "pi extension does not carry the armed incarnation gen"
  assert_contains "$ext" '"--source", "pi-ext"' "pi extension does not attribute its semantic source"
  assert_contains "$ext" 'pi.on("turn_end"' "pi extension lost the turn-end notification touch"
  pass "pi-signed shares Pi launch semantics while preserving its configured and recorded identity"
}

test_pi_tui_mode_probe_is_safe_for_old_and_new_pi() {
  local harness version rec id out status launch
  for harness in pi pi-signed; do
    for version in 0.82.0 0.84.0; do
      id="profile-${harness}-tui-${version//./}-z8d"
      rec=$(make_spawn_case "profile-__MODELFLAG__-${harness}-tui-${version//./}" "$harness" "$id")
      read_case_record "$rec"

      out=$(FM_TEST_PI_VERSION="$version" \
        run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
        "$id" "$PROJ_DIR")
      status=$?
      expect_code 0 "$status" "$harness $version spawn should succeed"
      launch=$(cat "$LAUNCH_LOG")
      assert_contains "$launch" "'$FAKEBIN_DIR/$harness'" \
        "$harness $version launch must use the executable selected for probing"
      assert_not_contains "$launch" "FM_PI_HARNESS=$harness $harness" \
        "$harness $version launch must not re-resolve a bare executable in the worker"
      if [ "$version" = 0.82.0 ]; then
        assert_not_contains "$launch" "--tui-mode" \
          "$harness $version launch must omit unsupported --tui-mode"
      else
        assert_contains "$launch" "'$FAKEBIN_DIR/$harness' --tui-mode regular" \
          "$harness $version launch must preserve the regular TUI"
      fi
    done
  done
  pass "Pi launch probing omits --tui-mode on older Pi and preserves it on supporting Pi"
}

test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata() {
  local rec id out status
  id=profile-pi-signed-missing-z8c
  rec=$(make_spawn_case profile-pi-signed-missing pi-signed "$id")
  read_case_record "$rec"
  rm -f "$FAKEBIN_DIR/pi-signed"
  : > "$LAUNCH_LOG"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "a missing pi-signed executable should refuse the spawn"
  assert_contains "$out" "pi-signed executable not found on PATH" \
    "missing pi-signed refusal did not name the actionable requirement"
  assert_absent "$HOME_DIR/state/$id.meta" "missing pi-signed refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "missing pi-signed refusal typed a launch command"
  pass "pi-signed refuses safely and actionably when the selected executable is unavailable"
}

test_deck_threads_model_and_refuses_effort() {
  local rec id out status launch
  id=profile-deck-z7
  rec=$(make_spawn_case profile-deck deck "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model example/route)
  status=$?
  expect_code 0 "$status" "deck spawn with a model should succeed: $out"
  assert_meta_profile "$HOME_DIR/state/$id.meta" deck example/route default
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "fm-deck-worker '$ROOT/bin/fm-deck-worker.sh' --id '$id'" \
    "deck launch did not run the deck worker driver for this task"
  assert_contains "$launch" "--deck '$FAKEBIN_DIR/deck' --model 'example/route' -- " \
    "deck launch did not thread the model before the brief"
  assert_not_contains "$launch" "--thinking" "deck launch must not pass Pi's thinking flag"
  assert_not_contains "$launch" "--tui-mode" "deck launch must not receive Pi's TUI mode override"

  id=profile-deck-effort-z7b
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model example/route --effort high)
  status=$?
  expect_code 1 "$status" "deck spawn with an effort should refuse"
  assert_contains "$out" "deck has no effort control" "deck effort refusal was not actionable"
  assert_absent "$HOME_DIR/state/$id.meta" "deck effort refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "deck effort refusal typed a launch command"
  pass "deck receives --model and refuses the effort axis before provisioning"
}

test_removed_harness_is_refused_as_unknown() {
  local rec id out status
  id=profile-removed-harness-z7c
  rec=$(make_spawn_case profile-removed-harness pi "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --harness claude --model sonnet)
  status=$?
  expect_code 1 "$status" "a removed worker harness should refuse"
  assert_contains "$out" "unknown harness 'claude'" "removed harness refusal did not name the harness"
  assert_absent "$HOME_DIR/state/$id.meta" "removed harness refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "removed harness refusal typed a launch command"
  pass "a removed worker harness is refused as unknown before provisioning"
}

test_deck_secondmate_uses_home_driver_and_configured_pin() {
  local rec id sm out status launch
  id=profile-deck-host
  rec=$(make_spawn_case profile-deck-host pi "$id")
  read_case_record "$rec"
  printf '%s\n' 'deck example/route' > "$HOME_DIR/config/secondmate-harness"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  sm=$(cd "$sm" && pwd -P)
  cp "$sm/data/charter.md" "$CASE_DIR/charter-before"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "Deck secondmate spawn should succeed: $out"
  assert_meta_profile "$HOME_DIR/state/$id.meta" deck example/route default
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--secondmate --id '$id'" "Deck launch omitted host mode"
  assert_contains "$launch" "FM_HOME='$sm'" "Deck launch did not select the secondmate home"
  assert_contains "$launch" "< '$sm/data/charter.md'" "Deck launch lost the charter"
  assert_contains "$launch" "--model 'example/route'" "Deck pin lost the model"
  assert_absent "$HOME_DIR/data/$id/launch-brief.md" "secondmate received worker overlay"
  cmp -s "$CASE_DIR/charter-before" "$sm/data/charter.md" || fail "Deck spawn rewrote charter"
  pass "Deck secondmate spawn resolves the configured pin and launches its home host"
}

test_pi_signed_persistent_secondmate_uses_pi_extensions_and_identity() {
  local rec id sm out status launch
  id=profile-pi-signed-secondmate-z8d
  rec=$(make_spawn_case profile-pi-signed-secondmate pi "$id")
  read_case_record "$rec"
  printf '%s\n' pi-signed > "$HOME_DIR/config/secondmate-harness"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  sm=$(cd "$sm" && pwd -P)
  cp "$ROOT/AGENTS.md" "$sm/AGENTS.md"
  cp "$sm/data/charter.md" "$CASE_DIR/charter-before"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "pi-signed persistent secondmate spawn should succeed"
  assert_contains "$out" "spawned $id harness=pi-signed kind=secondmate" \
    "pi-signed secondmate spawn did not preserve its runtime identity"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi-signed default default
  cmp -s "$ROOT/AGENTS.md" "$sm/AGENTS.md" || fail "secondmate launch rewrote the supervisor contract"
  cmp -s "$CASE_DIR/charter-before" "$sm/data/charter.md" || fail "secondmate launch rewrote the charter"
  assert_absent "$HOME_DIR/data/$id/launch-brief.md" "secondmate launch received a worker overlay"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "< '$sm/data/charter.md'" "secondmate launch lost its original charter"
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed '$FAKEBIN_DIR/pi-signed' --tui-mode regular -e '$sm/.pi/extensions/fm-primary-turnend-guard.ts' -e '$sm/.pi/extensions/fm-primary-pi-watch.ts'" \
    "pi-signed secondmate did not force the regular TUI with Pi's primary extension launch shape"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# evidence begin: persistent secondmate\n%s\n' "$out"
    printf 'launch command:\n%s\noriginal charter:\n' "$launch"
    cat "$sm/data/charter.md"
    printf 'supervisor AGENTS.md and charter remain byte-identical; no worker overlay created\n# evidence end\n'
  fi
  pass "pi-signed is a distinct persistent secondmate runtime with shared Pi supervision semantics"
}

test_batch_forwards_shared_profile_flags() {
  local rec id1 id2 out status
  id1=profile-batch-a-z9
  id2=profile-batch-b-z10
  rec=$(make_spawn_case profile-batch deck "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness pi --model openai-codex/gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "batch spawn with shared profile flags should succeed: $out"
  assert_contains "$out" "spawned $id1 harness=pi" "first batch task did not use shared harness"
  assert_contains "$out" "spawned $id2 harness=pi" "second batch task did not use shared harness"
  assert_meta_profile "$HOME_DIR/state/$id1.meta" pi openai-codex/gpt-5 high
  assert_meta_profile "$HOME_DIR/state/$id2.meta" pi openai-codex/gpt-5 high
  pass "batch dispatch shares --harness, --model, and --effort"
}

test_active_dispatch_profile_does_not_block_secondmate_launch() {
  local rec id sm out status
  id=profile-secondmate-z16
  rec=$(make_spawn_case profile-secondmate pi "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should be exempt from the dispatch-profile explicit harness requirement"
  assert_contains "$out" "spawned $id harness=pi kind=secondmate" "secondmate launch did not use secondmate harness resolution"
  assert_grep "kind=secondmate" "$HOME_DIR/state/$id.meta" "secondmate meta missing kind=secondmate"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi default default
  pass "active crew-dispatch profile does not block secondmate launches"
}

# Execute the actual emitted command in a synthetic pane environment: the
# fake backend records delivery, while real shells exercise the env boundary.
# No developer environment or credential values are inspected by these probes.
test_launch_environment_allowlist() {
  local setting rec id out status probe result expected launch value pane_shell pane_path
  # shellcheck disable=SC2016
  value='synthetic value; $(touch SHOULD_NOT_EXIST) `false` "quoted"'
  for setting in absent missing-config enabled empty; do
    id="env-$setting"
    rec=$(make_spawn_case "$id" pi "$id")
    read_case_record "$rec"
    case "$setting" in
      missing-config) rm "$HOME_DIR/config/crew-harness"; rmdir "$HOME_DIR/config" ;;
      enabled) printf '# Synthetic credential name\nFM_TEST_ALLOWED\nFM_TEST_EMPTY\nFM_TEST_UNSET\n' > "$HOME_DIR/config/launch-env-allowlist" ;;
      empty) : > "$HOME_DIR/config/launch-env-allowlist" ;;
    esac
    probe="$CASE_DIR/probe.sh"
    cat > "$probe" <<'SH'
#!/bin/sh
printf '%s\n' "${FM_TEST_AMBIENT_SENTINEL-unset}" "${FM_TEST_ALLOWED-unset}" \
  "${FM_TEST_EMPTY-unset}" "${FM_TEST_UNSET-unset}" "$HOME" "$PATH" "$TERM" "$TMUX" "$GOTMPDIR"
SH
    out=$(FM_TEST_AMBIENT_SENTINEL=synthetic-unrelated \
      run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --harness "/bin/sh '$probe'")
    status=$?
    expect_code 0 "$status" "allowlist=$setting spawn should succeed: $out"
    launch=$(cat "$LAUNCH_LOG")
    for pane_shell in /bin/sh /bin/bash /bin/zsh; do
      [ -x "$pane_shell" ] || continue
      pane_path=$(env -i HOME="$HOME_DIR/user-home" PATH=/usr/bin:/bin TERM=xterm \
        TMUX=synthetic-pane GOTMPDIR=/synthetic/gotmp \
        "$pane_shell" -c "printf %s \"\$PATH\"") \
        || fail "could not read $pane_shell startup PATH"
      result=$(env -i HOME="$HOME_DIR/user-home" PATH=/usr/bin:/bin TERM=xterm \
      TMUX=synthetic-pane GOTMPDIR=/synthetic/gotmp \
      FM_TEST_AMBIENT_SENTINEL=synthetic-unrelated FM_TEST_ALLOWED="$value" FM_TEST_EMPTY='' \
      "$pane_shell" -c "$launch") || fail "allowlist=$setting emitted launch failed in $pane_shell"
      case "$setting" in
        absent|missing-config) expected=$(printf '%s\n' synthetic-unrelated "$value" '' unset) ;;
        enabled) expected=$(printf '%s\n' unset "$value" '' unset) ;;
        empty) expected=$(printf '%s\n' unset unset unset unset) ;;
      esac
      expected="$expected"$'\n'"$HOME_DIR/user-home"$'\n'"$pane_path"$'\nxterm\nsynthetic-pane\n/synthetic/gotmp'
      [ "$result" = "$expected" ] || fail "allowlist=$setting worker environment mismatch: $result"
    done
    pass "allowlist=$setting preserves the operational floor and filters only when opted in"
  done
}

test_launch_environment_invalid_config_refuses() {
  local rec id bad out status
  id=env-invalid
  rec=$(make_spawn_case "$id" pi "$id")
  read_case_record "$rec"
  for bad in 'FM_TEST_ALLOWED=value' 'NAME;false' '1INVALID' '*'; do
    printf '%s\n' "$bad" > "$HOME_DIR/config/launch-env-allowlist"
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 1 "$status" "invalid allowlist must refuse spawn"
    assert_contains "$out" 'launch-env-allowlist' "refusal must identify the config file"
    [ ! -s "$LAUNCH_LOG" ] || fail "invalid allowlist delivered a launch command"
    [ ! -f "$HOME_DIR/state/$id.meta" ] || fail "invalid allowlist published a task"
  done
  pass "invalid allowlist names refuse before launch or task publication"
}

test_launch_environment_inaccessible_config_refuses() {
  local setting presence rec id blocked out status
  if [ "$(id -u)" = 0 ]; then
    printf '# skip - inaccessible launch configuration requires a non-root user\n'
    return
  fi
  for setting in config ancestor; do
    for presence in present absent; do
      id="env-inaccessible-$setting-$presence"
      rec=$(make_spawn_case "$id" pi "$id")
      read_case_record "$rec"
      if [ "$presence" = present ]; then
        printf 'FM_TEST_ALLOWED\n' > "$HOME_DIR/config/launch-env-allowlist"
      fi
      blocked="$HOME_DIR/config"
      if [ "$setting" = ancestor ]; then
        blocked="$HOME_DIR/config-parent"
        mkdir "$blocked"
        mv "$HOME_DIR/config" "$blocked/config"
        ln -s config-parent/config "$HOME_DIR/config"
      fi
      chmod 600 "$blocked" || fail "could not remove configuration search permission"
      out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
        "$id" "$PROJ_DIR" --harness pi --backend tmux)
      status=$?
      chmod 700 "$blocked" || fail "could not restore configuration search permission"
      expect_code 1 "$status" "inaccessible $setting with $presence allowlist must refuse spawn: $out"
      assert_contains "$out" 'launch-env-allowlist' "refusal must identify the launch configuration"
      [ ! -s "$LAUNCH_LOG" ] || fail "inaccessible configuration delivered a launch command"
      [ ! -f "$HOME_DIR/state/$id.meta" ] || fail "inaccessible configuration published a task"
      pass "inaccessible $setting with $presence allowlist refuses before launch or task publication"
    done
  done
}

test_launch_environment_inherited_by_secondmate() {
  local rec id sm out status result
  id=env-secondmate
  rec=$(make_spawn_case "$id" pi "$id")
  read_case_record "$rec"
  printf 'FM_TEST_ALLOWED\n' > "$HOME_DIR/config/launch-env-allowlist"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate with an allowlist should spawn: $out"
  cmp -s "$HOME_DIR/config/launch-env-allowlist" "$sm/config/launch-env-allowlist" \
    || fail "secondmate did not inherit the launch environment contract"
  cat > "$FAKEBIN_DIR/pi" <<'SH'
#!/bin/sh
printf '%s\n' "${FM_TEST_AMBIENT_SENTINEL-unset}" "$FM_TEST_ALLOWED" "$FM_HOME" "${FM_STATE_OVERRIDE-unset}"
SH
  chmod +x "$FAKEBIN_DIR/pi"
  result=$(env -i HOME="$HOME_DIR/user-home" PATH="$FAKEBIN_DIR:$PATH" \
    FM_TEST_AMBIENT_SENTINEL=synthetic-unrelated FM_TEST_ALLOWED=synthetic-provider \
    /bin/sh -c "$(cat "$LAUNCH_LOG")") || fail "secondmate's emitted command failed"
  [ "$result" = "unset"$'\nsynthetic-provider\n'"$sm" ] \
    || fail "secondmate's environment lost filtering or explicit home assignments: $result"
  # Exercise the same inheritance owner used by local and remote transfers;
  # removal must restore absence downstream as well as copying an opt-in.
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-config-inherit-lib.sh"
    rm "$HOME_DIR/config/launch-env-allowlist"
    propagate_secondmate_inheritance "$HOME_DIR" "$sm" >/dev/null
  ) || fail "allowlist removal failed to converge"
  [ ! -e "$sm/config/launch-env-allowlist" ] || fail "secondmate retained a removed allowlist"
  pass "secondmate launch inherits the allowlist for subsequent worker launches"
}

run_launch_environment_inheritance() {
  local route=$1 home=$2 dest=$3 fakebin=$4 generation=$5
  if [ "$route" = local ]; then
    (
      # shellcheck source=/dev/null
      . "$ROOT/bin/fm-config-inherit-lib.sh"
      FM_INHERITABLE_CONFIG=launch-env-allowlist \
        propagate_inheritable_config "$home/config" "$dest/config"
    )
  else
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" \
      FM_DATA_OVERRIDE="$home/data" FM_INHERITABLE_CONFIG=launch-env-allowlist \
      FM_SSH_BIN="$fakebin/inherit-ssh" \
      "$ROOT/bin/fm-remote-inherit-push.sh" inherited-env "$generation"
  fi
}

test_launch_environment_inheritance_preserves_on_source_errors() {
  local route rec id dest out status
  if [ "$(id -u)" = 0 ]; then
    printf '# skip - inaccessible inheritance sources require a non-root user\n'
    return
  fi
  for route in local remote; do
    id="env-inherit-$route"
    rec=$(make_spawn_case "$id" pi "$id")
    read_case_record "$rec"
    dest="$CASE_DIR/inherited-home"
    mkdir -p "$dest/config"
    printf 'FM_TEST_ALLOWED\n' > "$HOME_DIR/config/launch-env-allowlist"
    printf -- '- inherited-env - Test route (host: inherit-host; root: %s; home: %s; scope: test; projects: ; added 2026-09-05)\n' \
      "$ROOT" "$dest" > "$HOME_DIR/data/secondmates.md"
    cat > "$FAKEBIN_DIR/inherit-ssh" <<'SH'
#!/usr/bin/env bash
set -eu
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "$#" -eq 6 ] && [ "$1" = inherit-host ] && [ "$2" = fm-remote-entrypoint.sh ] && [ "$3" = 1 ] || exit 91
remote_root=$(printf '%s' "$4" | base64 --decode)
remote_home=$(printf '%s' "$5" | base64 --decode)
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done < <(printf '%s' "$6" | base64 --decode)
[ "${args[0]}" = fm-remote-inherit.sh ] || exit 92
FM_HOME="$remote_home" FM_STATE_OVERRIDE="$remote_home/state" \
  exec "$remote_root/bin/${args[0]}" "${args[@]:1}"
SH
    chmod +x "$FAKEBIN_DIR/inherit-ssh"
    out=$(run_launch_environment_inheritance "$route" "$HOME_DIR" "$dest" "$FAKEBIN_DIR" 1 2>&1)
    status=$?
    expect_code 0 "$status" "$route allowlist inheritance should succeed: $out"
    [ "$(cat "$dest/config/launch-env-allowlist")" = FM_TEST_ALLOWED ] \
      || fail "$route inheritance did not publish the allowlist"

    chmod 600 "$HOME_DIR/config" || fail "could not remove source search permission"
    out=$(run_launch_environment_inheritance "$route" "$HOME_DIR" "$dest" "$FAKEBIN_DIR" 2 2>&1)
    status=$?
    chmod 700 "$HOME_DIR/config" || fail "could not restore source search permission"
    expect_code 1 "$status" "$route inheritance must refuse an inaccessible source: $out"
    assert_contains "$out" launch-env-allowlist "$route inspection error must identify the allowlist"
    [ "$(cat "$dest/config/launch-env-allowlist")" = FM_TEST_ALLOWED ] \
      || fail "$route inheritance removed or changed the allowlist after an inspection error"

    rm "$HOME_DIR/config/launch-env-allowlist"
    ln -s missing-allowlist "$HOME_DIR/config/launch-env-allowlist"
    out=$(run_launch_environment_inheritance "$route" "$HOME_DIR" "$dest" "$FAKEBIN_DIR" 3 2>&1)
    status=$?
    expect_code 1 "$status" "$route inheritance must refuse a dangling source link: $out"
    [ "$(cat "$dest/config/launch-env-allowlist")" = FM_TEST_ALLOWED ] \
      || fail "$route inheritance treated a dangling source link as absence"

    rm "$HOME_DIR/config/launch-env-allowlist"
    out=$(run_launch_environment_inheritance "$route" "$HOME_DIR" "$dest" "$FAKEBIN_DIR" 4 2>&1)
    status=$?
    expect_code 0 "$status" "$route inheritance should mirror proven absence: $out"
    [ ! -e "$dest/config/launch-env-allowlist" ] || fail "$route inheritance retained a removed allowlist"
    pass "$route inheritance preserves the allowlist on source errors and mirrors proven absence"
  done
}

test_deck_secondmate_uses_home_driver_and_configured_pin
test_launch_environment_allowlist
test_launch_environment_invalid_config_refuses
test_launch_environment_inaccessible_config_refuses
test_launch_environment_inherited_by_secondmate
test_launch_environment_inheritance_preserves_on_source_errors

test_worker_launch_delivers_role_scope() {
  local rec id out launch kind prompt envelope encoded brief_kind brief content first_line role_line task_line inbox
  for brief_kind in heading legacy scaffold; do
  for kind in no-mistakes direct-PR local-only scout; do
    [ "$brief_kind" = heading ] && [ "$kind" != no-mistakes ] && continue
    id="role-launch-$brief_kind-$kind"
    rec=$(make_spawn_case "$id" pi)
    read_case_record "$rec"
    if [ "$brief_kind" != scaffold ]; then
      fm_test_spawn_brief "$HOME_DIR" "$id"
      if [ "$brief_kind" = heading ]; then
        printf '\n# Worker role\nFollow the project instructions.\n' >> "$HOME_DIR/data/$id/brief.md"
      fi
    else
      if [ "$kind" = scout ]; then
        FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$id" arbitrary-project-name --scout >/dev/null || fail "scout scaffold failed"
      else
        FM_HOME="$HOME_DIR" "$ROOT/bin/fm-brief.sh" "$id" arbitrary-project-name --mode "$kind" >/dev/null || fail "$kind scaffold failed"
      fi
      brief="$HOME_DIR/data/$id/brief.md"
      content=$(cat "$brief")
      content=${content//'{TASK}'/brief for $id}
      content=${content//'{FIRSTMATE_SPEC}'/Exercise the spawn behavior under test.}
      printf '%s\n' "$content" > "$brief"
    fi
    cp "$HOME_DIR/data/$id/brief.md" "$CASE_DIR/brief-before"
    # Answer the spawn-time --help probe like Pi, then capture the launch argv.
    cat > "$FAKEBIN_DIR/pi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  printf '%s\n' 'Pi 0.84.0' 'Options: --help --tui-mode <mode>'
  exit 0
fi
printf '%s\n' "$@" > "$FM_ROLE_PROMPT"
SH
    chmod +x "$FAKEBIN_DIR/pi"
    if [ "$kind" = scout ]; then
      out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
    else
      out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --mode "$kind" --yolo off)
    fi
    expect_code 0 "$?" "$kind worker spawn failed: $out"
    launch=$(cat "$LAUNCH_LOG")
    envelope="$CASE_DIR/prompt-envelope"
    encoded="$CASE_DIR/encoded-prompt"
    prompt="$CASE_DIR/prompt"
    FM_ROLE_PROMPT="$envelope" PATH="$FAKEBIN_DIR:$PATH" bash -c "$launch" || fail "could not consume $kind launch command"
    sed -n '/FIRSTMATE_OP: v1 launch-brief:/,$p' "$envelope" > "$encoded"
    "$ROOT/bin/fm-operational-input.sh" body < "$encoded" > "$prompt" ||
      fail "could not decode $kind launch-brief envelope"
    # The final prompt delivered to the harness is the generated interface.
    # The current identity must precede the authored task, because a Firstmate
    # worktree's own AGENTS.md assigns the unrelated supervisor identity.
    first_line=$(sed -n '1p' "$prompt")
    [ "$first_line" = '# Current worker role contract' ] ||
      fail "$brief_kind $kind did not establish worker identity before task content"
    role_line=$(grep -n '^# Current worker role contract$' "$prompt" | cut -d: -f1)
    task_line=$(grep -n '^# Task$' "$prompt" | head -1 | cut -d: -f1)
    [ "$role_line" -lt "$task_line" ] || fail "$brief_kind $kind put the worker identity after the task"
    assert_grep 'follow this brief instead of that supervisor contract' "$prompt" "$kind command did not deliver the role correction"
    assert_grep 'You are a crewmate: an autonomous worker agent managed by firstmate' "$prompt" "$kind command did not establish the worker identity directly"
    inbox="$HOME_DIR/state/$id.inbox"
    assert_grep "$inbox" "$prompt" "$kind command did not name the worker's own steering inbox"
    assert_grep "do not reject it as another home's state" "$prompt" "$kind command did not distinguish its inbox from another home's namespace"
    assert_grep "Never inspect or change any other home's endpoint namespace" "$prompt" "$kind command weakened cross-home isolation"
    assert_grep 'brief for' "$prompt" "$kind command lost the task"
    [ "$(grep -c '^# Current worker role contract$' "$prompt")" -eq 1 ] ||
      fail "$brief_kind $kind duplicated the delivered worker contract"
    if [ "$brief_kind" = heading ]; then
      assert_grep 'Follow the project instructions' "$prompt" "$kind command dropped the authored role section"
    fi
    cmp -s "$CASE_DIR/brief-before" "$HOME_DIR/data/$id/brief.md" || fail "spawn rewrote the authored brief"
    if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
      printf '# evidence begin: %s %s worker\n%s\n' "$brief_kind" "$kind" "$out"
      printf 'launch command executed with an argv-capture harness:\n%s\nreceived arguments and final prompt:\n' "$launch"
      cat "$prompt"
      printf 'authored brief remains byte-identical\n# evidence end\n'
    fi
  done
  done
  pass "fm-spawn: actual ship/scout launch commands deliver the worker role contract"
}

test_worker_launch_delivers_role_scope
test_no_profile_keeps_pi_profile_defaults
test_non_cursor_launch_clears_inherited_cursor_markers
test_relative_home_overrides_launch_with_absolute_cross_process_paths
test_home_defaults_preserve_absolute_or_resolve_relative_paths
test_absolute_override_spelling_is_preserved_in_launch_paths
test_unresolvable_relative_overrides_fail_loudly
test_active_dispatch_profile_requires_explicit_harness_for_ship
test_active_dispatch_profile_requires_explicit_harness_for_scout
test_active_dispatch_profile_allows_explicit_harness
test_active_dispatch_profile_allows_positional_harness
test_active_dispatch_profile_allows_raw_launch_command
test_native_effort_validator_keeps_axes_separate
test_native_pi_ultra_is_explicit_and_model_scoped
test_batch_preserves_native_ultra
test_pi_threads_model_and_max_effort
test_pi_tui_mode_probe_is_safe_for_old_and_new_pi
test_pi_signed_threads_shared_pi_profile_and_preserves_identity
test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata
test_deck_threads_model_and_refuses_effort
test_removed_harness_is_refused_as_unknown
test_pi_signed_persistent_secondmate_uses_pi_extensions_and_identity
test_batch_forwards_shared_profile_flags
test_active_dispatch_profile_does_not_block_secondmate_launch

echo "# all fm-spawn-dispatch-profile tests passed"
