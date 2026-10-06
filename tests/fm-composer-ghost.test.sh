#!/usr/bin/env bash
# Ghost-text robustness (incident composer-robust; task afk-herdr-false-pending).
#
# A harness fills an otherwise-empty composer with de-emphasised ghost text that a
# plain screen read cannot tell apart from human input, so the composer reader
# saw an idle endpoint as holding pending input. Two rendering styles are covered
# by the one shared ANSI-aware owner (fm_composer_strip_ghost,
# bin/fm-composer-lib.sh):
#   - DIM/FAINT (SGR 2): claude's rotating prompt suggestion, codex's idle tip.
#   - a dark/muted TRUECOLOR foreground: grok's placeholder/hint text.
# These tests pin:
#   1. fm_composer_strip_ghost drops dim/faint AND dark-truecolor runs, keeping
#      normal-intensity, brightly-coloured text.
#   2. The composer classifier, fed a styled screen and cursor row through the
#      stream adapter's capability profile (the screen the hub renders), reads a
#      ghost-only composer (either style) as NOT pending, while still treating
#      real (normal/bright) text as pending, and structurally scans every row of
#      a multi-row composer.
#   3. The human/LLM-facing capture path (fm-peek.sh) stays PLAIN - no escape
#      codes ever reach firstmate's context.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

PEEK="$ROOT/bin/fm-peek.sh"

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source stream || { echo "could not load the stream adapter" >&2; exit 1; }

TMP_ROOT=$(fm_test_tmproot fm-ghost-tests)

# ESC byte for building styled fixtures and asserting escape-free output.
ESC=$(printf '\033')

# The styled screen fixture FM_FAKE_STYLED, with the cursor on row FM_FAKE_CY
# (unset = no cursor reported), classified exactly as
# fm_backend_stream_composer_state classifies the hub's styled screen.
fixture_composer_state() {
  local screen verdict
  screen=$(cat "${FM_FAKE_STYLED:-/dev/null}" 2>/dev/null)
  verdict=$(fm_composer_classify_screen "$(fm_backend_stream_composer_caps)" "$screen" "${FM_FAKE_CY-}")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

# Pending unless the composer is proven empty - the input guard's reading.
fixture_input_pending() {
  [ "$(fixture_composer_state)" != empty ]
}

# Kept so the cases read as before: a per-case directory, no fake binaries.
make_case_dir() {  # <dir>
  mkdir -p "$1/fakebin"
  printf '%s\n' "$1/fakebin"
}

# --- fm_composer_strip_ghost (pure) ---------------------------------------------

test_strip_ghost_drops_dim_keeps_normal() {
  local out
  # Dim run between ESC[2m and ESC[0m is dropped; the prompt glyph survives.
  out=$(printf '\xe2\x9d\xaf \033[2mWhat is the largest country by area?\033[0m\n' | fm_composer_strip_ghost)
  [ "$out" = "$(printf '\xe2\x9d\xaf ')" ] || fail "dim run not dropped: '$out'"
  # Normal-intensity text is kept verbatim (no styling at all).
  out=$(printf '\xe2\x9d\xaf real human text\n' | fm_composer_strip_ghost)
  [ "$out" = "$(printf '\xe2\x9d\xaf real human text')" ] || fail "normal text changed: '$out'"
  # Bold (SGR 1) is normal-intensity, NOT dim - must be kept.
  out=$(printf '\033[1mbold typed\033[0m\n' | fm_composer_strip_ghost)
  [ "$out" = "bold typed" ] || fail "bold text wrongly dropped: '$out'"
  pass "fm_composer_strip_ghost drops dim/faint runs, keeps normal and bold text"
}

test_strip_ghost_handles_combined_and_boundary_codes() {
  local out
  # Dim combined with a color in one sequence (ESC[2;37m) is still a dim run.
  out=$(printf '\xe2\x9d\xaf \033[2;37mpredicted\033[0m\n' | fm_composer_strip_ghost)
  [ "$out" = "$(printf '\xe2\x9d\xaf ')" ] || fail "combined dim+color not dropped: '$out'"
  # ESC[22m (normal intensity) ends a dim run mid-line; the tail is kept.
  out=$(printf '\033[2mghost\033[22mREALTAIL\n' | fm_composer_strip_ghost)
  [ "$out" = "REALTAIL" ] || fail "ESC[22m did not end the dim run: '$out'"
  # ESC[0;2m (reset then dim) reads as dim (left-to-right within the sequence).
  out=$(printf 'keep\033[0;2mdrop\033[0m\n' | fm_composer_strip_ghost)
  [ "$out" = "keep" ] || fail "reset-then-dim not treated as dim: '$out'"
  pass "fm_composer_strip_ghost handles combined SGR, ESC[22m, and reset-then-dim"
}

test_strip_ghost_keeps_colored_text_with_2_payloads() {
  local out
  # These pin that the awk's truecolor/256-color `2` payload SELECTOR is not
  # mistaken for the SGR-2 dim attribute. The truecolor foregrounds use a BRIGHT
  # colour (grok's real-input RGB 224,222,244, luminance ~225), because a DARK
  # truecolor foreground is now itself a ghost signal (grok's placeholder) and is
  # covered by test_strip_ghost_drops_dark_truecolor_ghost below.
  out=$(printf '\033[38;5;2mgreen typed\033[0m\n' | fm_composer_strip_ghost)
  [ "$out" = "green typed" ] || fail "8-bit color payload 2 was treated as dim: '$out'"
  out=$(printf '\033[38;2;224;222;244mtruecolor typed\033[0m\n' | fm_composer_strip_ghost)
  [ "$out" = "truecolor typed" ] || fail "bright truecolor payload 2 was treated as dim/ghost: '$out'"
  out=$(printf '\033[48;2;4;5;6mbackground typed\033[0m\n' | fm_composer_strip_ghost)
  [ "$out" = "background typed" ] || fail "background truecolor payload was treated as dim: '$out'"
  out=$(printf '\033[58;5;2munderline-color typed\033[0m\n' | fm_composer_strip_ghost)
  [ "$out" = "underline-color typed" ] || fail "underline color payload 2 was treated as dim: '$out'"
  out=$(printf '\033[38:2::224:222:244mcolon truecolor typed\033[0m\n' | fm_composer_strip_ghost)
  [ "$out" = "colon truecolor typed" ] || fail "bright colon truecolor payload 2 was treated as dim/ghost: '$out'"
  out=$(printf '\033[58::5::2mcolon underline typed\033[0m\n' | fm_composer_strip_ghost)
  [ "$out" = "colon underline typed" ] || fail "colon underline SGR leaked or dimmed text: '$out'"
  out=$(printf '\033[4:2mnot dim underline\033[0m\n' | fm_composer_strip_ghost)
  [ "$out" = "not dim underline" ] || fail "colon subparameter 2 was treated as dim: '$out'"
  pass "fm_composer_strip_ghost keeps bright colored text with 2 payloads"
}

# --- Dark truecolor foreground is ghost (grok placeholder), dropped ----------

test_strip_ghost_drops_dark_truecolor_ghost() {
  local out
  # grok renders its placeholder/hint text with a dark, muted truecolor
  # foreground (empirically 38;2;50;47;70 .. 38;2;110;106;134, luminance ~51..110,
  # verified live against grok 0.2.93; the pristine "Type a message..." placeholder
  # was this shape in grok 0.2.82). The shared owner drops it while keeping the
  # bright prompt glyph, so an idle grok composer never reads as pending.
  out=$(printf '\xe2\x9d\xaf \033[38;2;50;47;70mType a message...\033[0m\n' | fm_composer_strip_ghost)
  [ "$out" = "$(printf '\xe2\x9d\xaf ')" ] || fail "dark truecolor ghost not dropped: '$out'"
  out=$(printf '\033[38;2;110;106;134mplaceholder hint text\033[39m\n' | fm_composer_strip_ghost)
  [ -z "$out" ] || fail "dark truecolor hint not dropped: '$out'"
  # The colon form drops too.
  out=$(printf '\xe2\x9d\xaf \033[38:2::86:82:110mmuted\033[0m\n' | fm_composer_strip_ghost)
  [ "$out" = "$(printf '\xe2\x9d\xaf ')" ] || fail "dark colon-truecolor ghost not dropped: '$out'"
  pass "fm_composer_strip_ghost drops a dark/muted truecolor foreground (grok placeholder)"
}

# --- muse's composer sits closest to the ghost threshold ---------------------

# These are muse 0.1.0-R708.1's real captured composer rows. Its prompt glyph
# `⟩` is truecolor 38;2;90;160;255 (luminance ~149.9) and its typed text is
# 38;2;204;211;219 (~209.8), so the glyph clears the 128 default by the
# narrowest margin in the fleet - roughly a fifth of grok's real-input margin.
# Both must survive stripping: dropping the glyph would empty an idle composer's
# plain row, and dropping the typed text would read a pending pane as empty and
# make it an injection target.
test_strip_ghost_keeps_muse_composer_colors() {
  local out glyph
  glyph=$(printf '\xe2\x9f\xa9')
  out=$(printf '\033[0m\033[38;2;90;160;255m\xe2\x9f\xa9 \033[39m\n' | fm_composer_strip_ghost)
  [ "$out" = "$(printf '%s ' "$glyph")" ] \
    || fail "muse's idle composer glyph was stripped as ghost text: '$out'"
  # The submitted-prompt row carries a background colour too; an SGR 48 payload
  # must not be luminance-tested as if it were the foreground.
  out=$(printf '\033[38;2;90;160;255m\033[48;2;38;56;84m\xe2\x9f\xa9 \033[38;2;204;211;219mhello from firstmate\033[39m\n' | fm_composer_strip_ghost)
  [ "$out" = "$(printf '%s hello from firstmate' "$glyph")" ] \
    || fail "muse's typed text or background-coloured glyph row was stripped: '$out'"
  # The restored prompt muse puts back into the composer after an Escape
  # interrupt is real bright text and must stay visible as pending input.
  out=$(printf '\033[0m\033[38;2;90;160;255m\xe2\x9f\xa9 \033[38;2;204;211;219msecond turn to interrupt\033[39m\n' | fm_composer_strip_ghost)
  [ "$out" = "$(printf '%s second turn to interrupt' "$glyph")" ] \
    || fail "muse's restored post-interrupt prompt was stripped as ghost text: '$out'"
  pass "fm_composer_strip_ghost keeps muse's near-threshold glyph and its typed text"
}

# --- composer reader: dim ghost is not pending ------------------------

test_dim_ghost_only_composer_is_not_pending() {
  local dir fb capture
  dir="$TMP_ROOT/ghost-only"; mkdir -p "$dir"
  fb=$(make_case_dir "$dir")
  capture="$dir/styled.txt"
  # The exact rendering claude emits: a normal prompt glyph + a DIM predicted prompt.
  printf '\xe2\x9d\xaf \033[2mWhat is the largest country by area?\033[0m\n' > "$capture"
  if PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
     fixture_input_pending; then
    fail "dim ghost-only composer falsely read as pending"
  fi
  pass "composer reader: a dim ghost-only composer is NOT pending"
}

test_dim_ghost_inside_bordered_composer_is_not_pending() {
  local dir fb capture
  dir="$TMP_ROOT/ghost-bordered"; mkdir -p "$dir"
  fb=$(make_case_dir "$dir")
  capture="$dir/styled.txt"
  # Bordered composer (claude box) holding only dim ghost text.
  printf '╭─────────────────────────────────────╮\n│ \033[2mtry the other approach instead\033[0m      │\n╰─────────────────────────────────────╯\n' > "$capture"
  if PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
     fixture_input_pending; then
    fail "dim ghost in a bordered composer falsely read as pending"
  fi
  pass "composer reader: dim ghost inside a bordered composer is NOT pending"
}

test_normal_text_still_pending() {
  local dir fb capture
  dir="$TMP_ROOT/real-text"; mkdir -p "$dir"
  fb=$(make_case_dir "$dir")
  capture="$dir/styled.txt"
  # Real human text, normal intensity - must still read as pending.
  printf '\xe2\x9d\xaf fix findings 1 and 3, skip 2\n' > "$capture"
  PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fixture_input_pending \
    || fail "real typed text was not detected as pending"
  pass "composer reader: normal-intensity typed text is still pending"
}

test_colored_text_with_2_payload_still_pending() {
  local dir fb capture
  dir="$TMP_ROOT/colored-text"; mkdir -p "$dir"
  fb=$(make_case_dir "$dir")
  capture="$dir/styled.txt"
  printf '\xe2\x9d\xaf \033[38;5;2mgreen typed\033[0m\n' > "$capture"
  PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fixture_input_pending \
    || fail "8-bit colored typed text was not detected as pending"
  printf '\xe2\x9d\xaf \033[38;2;224;222;244mtruecolor typed\033[0m\n' > "$capture"
  PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fixture_input_pending \
    || fail "bright truecolor typed text was not detected as pending"
  printf '\xe2\x9d\xaf \033[58;5;2munderline-color typed\033[0m\n' > "$capture"
  PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fixture_input_pending \
    || fail "underline-colored typed text was not detected as pending"
  printf '\xe2\x9d\xaf \033[58::5::2mcolon underline typed\033[0m\n' > "$capture"
  PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fixture_input_pending \
    || fail "colon underline typed text was not detected as pending"
  pass "composer reader: bright colored text with 2 payloads is still pending"
}

test_dark_truecolor_ghost_only_composer_is_not_pending() {
  local dir fb capture
  dir="$TMP_ROOT/grok-ghost"; mkdir -p "$dir"
  fb=$(make_case_dir "$dir")
  capture="$dir/styled.txt"
  # A grok-style pristine composer: bright prompt glyph + a dark/muted truecolor
  # placeholder. It must read NOT pending (the grok TRUECOLOR gap, now covered by
  # the same ANSI-aware owner as claude's dim ghost).
  printf '\xe2\x9d\xaf \033[38;2;50;47;70mType a message...\033[0m\n' > "$capture"
  if PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
     fixture_input_pending; then
    fail "dark truecolor ghost-only composer falsely read as pending"
  fi
  pass "composer reader: a dark truecolor ghost-only composer (grok placeholder) is NOT pending"
}

test_dark_truecolor_bare_shell_prompt_is_unknown() {
  local dir fb capture out prompt
  dir="$TMP_ROOT/dark-shell-prompt"; mkdir -p "$dir"
  fb=$(make_case_dir "$dir")
  capture="$dir/styled.txt"
  for prompt in '$' 'user@host $'; do
    printf '\033[38;2;50;47;70m%s\033[0m\n' "$prompt" > "$capture"
    out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
      fixture_composer_state)
    [ "$out" = unknown ] \
      || fail "dark truecolor bare shell prompt '$prompt' must read unknown, got '$out'"
  done
  pass "composer reader: dark truecolor shell prompts read unknown"
}

test_real_text_with_trailing_ghost_is_pending() {
  local dir fb capture
  dir="$TMP_ROOT/mixed"; mkdir -p "$dir"
  fb=$(make_case_dir "$dir")
  capture="$dir/styled.txt"
  # A human typed "deploy" and claude appended a dim ghost completion. The real
  # text must win - the composer is pending.
  printf '\xe2\x9d\xaf deploy\033[2m the staging environment now\033[0m\n' > "$capture"
  PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fixture_input_pending \
    || fail "real text with a trailing ghost completion was not detected as pending"
  pass "composer reader: real text plus a trailing ghost run is still pending"
}

# --- composer reader: structural multi-row box scan ------------------

test_two_row_composer_reads_text_above_empty_cursor_row() {
  local dir fb capture out
  dir="$TMP_ROOT/two-row"; mkdir -p "$dir"
  fb=$(make_case_dir "$dir")
  capture="$dir/styled.txt"
  cat > "$capture" <<'EOF'
╭────────────────────────────────────────────────────╮
│ > Read the brief at /tmp/brief.md and follow it.   │
│                                                    │
╰────────────────────────────────────────────────────╯
EOF
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=2 \
    fixture_composer_state)
  [ "$out" = pending ] \
    || fail "two-row composer text above the empty cursor row should be pending, got '$out'"
  pass "composer reader: text above an empty cursor row is pending"
}

test_wrapped_composer_reads_all_content_rows() {
  local dir fb capture out
  dir="$TMP_ROOT/wrapped"; mkdir -p "$dir"
  fb=$(make_case_dir "$dir")
  capture="$dir/styled.txt"
  cat > "$capture" <<'EOF'
╭────────────────────────────────────────────╮
│ > This deliberately long instruction wraps │
│ across a second composer content row and   │
│ across a third composer content row too.   │
│                                            │
╰────────────────────────────────────────────╯
EOF
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=4 \
    fixture_composer_state)
  [ "$out" = pending ] \
    || fail "a three-row wrapped composer should be pending, got '$out'"
  pass "composer reader: a message wrapped across three rows is pending"
}

test_proven_box_bottom_border_cursor_classifies_content() {
  local dir fb capture out
  dir="$TMP_ROOT/bottom-border-ghost"; mkdir -p "$dir"
  fb=$(make_case_dir "$dir")
  capture="$dir/styled.txt"
  printf '╭────────────────────────╮\n│ ❯ \033[38;2;50;47;70mType a message...\033[0m    │\n╰──────── Grok 4.5 ──────╯\n' > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=2 \
    fixture_composer_state)
  [ "$out" = empty ] \
    || fail "a cursor on a proven titled box bottom must classify its content, got '$out'"
  pass "composer reader: a proven titled box tolerates a bottom-border cursor"
}

test_bordered_busy_signatures_are_pending() {
  local dir fb capture out signature
  dir="$TMP_ROOT/bordered-busy-signatures"; mkdir -p "$dir"
  fb=$(make_case_dir "$dir")
  capture="$dir/styled.txt"
  for signature in 'Working...' 'Ctrl+c:cancel'; do
    printf '╭────────────────────╮\n│ %-18s │\n╰────────────────────╯\n' "$signature" > "$capture"
    out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
      fixture_composer_state)
    [ "$out" = pending ] \
      || fail "typed bordered busy signature '$signature' should be pending, got '$out'"
  done
  pass "composer reader: typed Pi and Grok busy signatures inside a box are pending"
}

test_non_bordered_busy_footer_is_unknown_strict() {
  # STRICT divergence (captain decision blank-row-injection-posture): a bare
  # busy-footer row under the cursor is not a composer container, so it no
  # longer reads `empty` the way the old allow-busy compatibility fallback
  # did. Its one load-bearing consumer - submit confirmation on a harness
  # whose mid-turn screen hides the composer (pi) - moved to the submit
  # core's baseline-idle turn-started conversion (the shared submit core), which
  # requires an idle-to-busy transition across our own Enter instead of
  # trusting any busy-looking row.
  local dir fb capture out
  dir="$TMP_ROOT/non-bordered-busy"; mkdir -p "$dir"
  fb=$(make_case_dir "$dir")
  capture="$dir/styled.txt"
  printf 'Working...\n' > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fixture_composer_state)
  [ "$out" = unknown ] \
    || fail "a non-bordered busy footer must read unknown under the strict rule, got '$out'"
  pass "composer reader: a bare busy-footer row reads unknown (strict container-proof rule)"
}

test_clipped_bordered_box_is_unknown() {
  local dir fb capture out
  dir="$TMP_ROOT/clipped-box"; mkdir -p "$dir"
  fb=$(make_case_dir "$dir")
  capture="$dir/styled.txt"
  printf '╭────────────────────╮\n│ >                  │\n' > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
    fixture_composer_state)
  [ "$out" = unknown ] \
    || fail "a bordered box with no readable bottom border should be unknown, got '$out'"
  pass "composer reader: an unbounded bordered box fails closed as unknown"
}

test_asymmetric_composer_edges_are_unknown() {
  local dir fb capture out row
  dir="$TMP_ROOT/asymmetric-box"; mkdir -p "$dir"
  fb=$(make_case_dir "$dir")
  capture="$dir/styled.txt"
  for row in '│ > text' 'text │' '│ > text ┃' '──────' '+----' 'text +'; do
    printf '%s\n' "$row" > "$capture"
    out=$(PATH="$fb:$PATH" LC_ALL=C FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
      fixture_composer_state)
    [ "$out" = unknown ] \
      || fail "unbounded composer-edge row '$row' should be unknown, got '$out'"
  done
  pass "composer reader: clipped and asymmetric composer edges fail closed"
}

test_mismatched_box_families_are_unknown() {
  local dir fb capture out
  dir="$TMP_ROOT/mismatched-box"; mkdir -p "$dir"
  fb=$(make_case_dir "$dir")
  capture="$dir/styled.txt"
  printf '╭────────╮\n┃ >      ┃\n╰────────╯\n' > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
    fixture_composer_state)
  [ "$out" = unknown ] \
    || fail "a box with mismatched border families should be unknown, got '$out'"
  pass "composer reader: inconsistent box geometry fails closed"
}

test_misaligned_box_is_unknown() {
  local dir fb capture out fixture
  dir="$TMP_ROOT/misaligned-box"; mkdir -p "$dir"
  fb=$(make_case_dir "$dir")
  capture="$dir/styled.txt"
  for fixture in offset width; do
    case "$fixture" in
      offset) printf ' ╭────╮\n │    │\n╰────╯\n' > "$capture" ;;
      width) printf '╭────╮\n│     │\n╰────╯\n' > "$capture" ;;
    esac
    out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
      fixture_composer_state)
    [ "$out" = unknown ] \
      || fail "a box with inconsistent $fixture geometry should be unknown, got '$out'"
  done
  pass "composer reader: misaligned box bounds fail closed"
}

test_unproved_empty_geometry_fails_closed() {
  local dir fb capture out fixture expected
  dir="$TMP_ROOT/unproved-empty-geometry"; mkdir -p "$dir"
  fb=$(make_case_dir "$dir")
  capture="$dir/styled.txt"
  for fixture in ghost idle malformed-top; do
    case "$fixture" in
      ghost)
        expected=unknown
        printf '╭────────────╮\n│ \033[2mghost\033[0m │\n╰────────────╯\n' > "$capture"
        out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
          fixture_composer_state)
        ;;
      idle)
        expected=pending-unproven
        printf '╭────────────╮\n│ idle hint │\n╰────────────╯\n' > "$capture"
        out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
          FM_COMPOSER_IDLE_RE='^idle hint$' fixture_composer_state)
        ;;
      malformed-top)
        expected=unknown
        printf '╭────x───────╮\n│            │\n╰────────────╯\n' > "$capture"
        out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
          fixture_composer_state)
        ;;
    esac
    [ "$out" = "$expected" ] \
      || fail "unproved geometry '$fixture' should be $expected, got '$out'"
  done
  pass "composer reader: unproved ghost and malformed geometry stay unknown while styled placeholder-like text stays pending-unproven"
}

test_differing_widths_use_asymmetric_verdicts() {
  local dir fb capture out
  dir="$TMP_ROOT/differing-widths"; mkdir -p "$dir"
  fb=$(make_case_dir "$dir")
  capture="$dir/styled.txt"
  printf '╭──────────╮\n│ > text │\n╰──────────╯\n' > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
    fixture_composer_state)
  [ "$out" = pending-unproven ] \
    || fail "text in a differing-width box should be pending-unproven, got '$out'"
  printf '╭──────────╮\n│        │\n╰──────────╯\n' > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
    fixture_composer_state)
  [ "$out" = unknown ] \
    || fail "an empty differing-width box should be unknown, never empty, got '$out'"
  pass "composer reader: differing widths prefer pending or unknown, never empty"
}

test_wide_composer_text_is_pending() {
  local dir fb capture out text
  dir="$TMP_ROOT/wide-text"; mkdir -p "$dir"
  fb=$(make_case_dir "$dir")
  capture="$dir/styled.txt"
  for text in '修复登录问题' 'fix the bug 🔧'; do
    printf '╭────────────────────╮\n│ > %s │\n╰────────────────────╯\n' "$text" > "$capture"
    out=$(PATH="$fb:$PATH" LC_ALL=C FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
      fixture_composer_state)
    [ "$out" = pending-unproven ] \
      || fail "wide composer text '$text' should be pending-unproven, got '$out'"
  done
  pass "composer reader: emoji and CJK text remain pending under the C locale"
}

test_all_harness_composers_share_classification() {
  local dir fb capture out harness
  dir="$TMP_ROOT/all-harness-composers"; mkdir -p "$dir"
  fb=$(make_case_dir "$dir")
  capture="$dir/styled.txt"
  for harness in claude codex opencode pi pi-signed grok; do
    case "$harness" in
      claude) printf '╭────────────╮\n│ ❯ \033[2mtry\033[0m      │\n╰────────────╯\n' > "$capture" ;;
      codex) printf '╭────────────╮\n│ › \033[2mtip\033[0m      │\n╰────────────╯\n' > "$capture" ;;
      opencode) printf '╭────────────╮\n│ >          │\n╰────────────╯\n' > "$capture" ;;
      pi|pi-signed) printf '╭────────────╮\n│            │\n╰────────────╯\n' > "$capture" ;;
      grok) printf '╭────────────╮\n│ ❯ \033[38;2;50;47;70mType\033[0m     │\n╰────────────╯\n' > "$capture" ;;
    esac
    out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
      fixture_composer_state)
    [ "$out" = empty ] \
      || fail "$harness aligned idle composer should be empty, got '$out'"
    case "$harness" in
      claude|grok) printf '╭────────────╮\n│ ❯ fix      │\n╰────────────╯\n' > "$capture" ;;
      codex) printf '╭────────────╮\n│ › fix      │\n╰────────────╯\n' > "$capture" ;;
      opencode|pi|pi-signed) printf '╭────────────╮\n│ > fix      │\n╰────────────╯\n' > "$capture" ;;
    esac
    out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
      fixture_composer_state)
    [ "$out" = pending ] \
      || fail "$harness composer with text should be pending, got '$out'"
  done
  pass "composer reader: all harnesses share empty and pending classification"
}

test_absent_identity_keeps_enclosed_bare_verdict() {
  local dir fb capture out nbsp
  dir="$TMP_ROOT/absent-identity"; mkdir -p "$dir"
  fb=$(make_case_dir "$dir")
  capture="$dir/styled.txt"
  nbsp=$(printf '\302\240')
  printf '────────────────────────\n❯%s\n────────────────────────\n' "$nbsp" > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=1 \
    fixture_composer_state)
  [ "$out" = empty ] \
    || fail "an enclosed Claude glyph must keep its bare empty verdict when the Pi-only probe is absent, got '$out'"
  pass "composer reader: absent Pi identity preserves Claude's enclosed bare verdict"
}

test_legitimate_empty_routes_remain_empty() {
  local dir fb capture out fixture cursor
  dir="$TMP_ROOT/legitimate-empty"; mkdir -p "$dir"
  fb=$(make_case_dir "$dir")
  capture="$dir/styled.txt"
  # A blank pane is deliberately absent here: under the strict container-proof
  # rule (captain decision blank-row-injection-posture) a blank cursor row is
  # unknown, pinned by tests/fm-daemon.test.sh and tests/fm-composer-lib.test.sh.
  for fixture in bordered double-bordered agent-prompt; do
    case "$fixture" in
      bordered) printf '╭────╮\n│    │\n╰────╯\n' > "$capture"; cursor=1 ;;
      double-bordered) printf '╔════╗\n║    ║\n╚════╝\n' > "$capture"; cursor=1 ;;
      agent-prompt) printf '›\n' > "$capture"; cursor=0 ;;
    esac
    out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY="$cursor" \
      fixture_composer_state)
    [ "$out" = empty ] \
      || fail "legitimate empty route '$fixture' should remain empty, got '$out'"
  done
  pass "composer reader: only proven structural and non-bordered empty routes stay empty"
}

test_non_bordered_composer_uses_compatibility_fallback() {
  local dir fb capture out
  dir="$TMP_ROOT/non-bordered-fallback"; mkdir -p "$dir"
  fb=$(make_case_dir "$dir")
  capture="$dir/styled.txt"
  printf '› deploy staging\n' > "$capture"
  out=$(PATH="$fb:$PATH" FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
    fixture_composer_state)
  [ "$out" = pending ] \
    || fail "a non-bordered composer should retain cursor-row classification, got '$out'"
  pass "composer reader: panes without bordered structure retain compatibility fallback"
}

test_non_bordered_interior_edges_are_pending() {
  local dir fb capture out row
  dir="$TMP_ROOT/non-bordered-interior-edges"; mkdir -p "$dir"
  fb=$(make_case_dir "$dir")
  capture="$dir/styled.txt"
  for row in '› cat file | grep x' '› explain │ this glyph'; do
    printf '%s\n' "$row" > "$capture"
    out=$(PATH="$fb:$PATH" LC_ALL=C FM_FAKE_STYLED="$capture" FM_FAKE_CY=0 \
      fixture_composer_state)
    [ "$out" = pending ] \
      || fail "non-bordered interior edge row '$row' should be pending, got '$out'"
  done
  pass "composer reader: interior edge glyphs retain non-bordered fallback"
}

# --- fm-peek.sh stays escape-free (LLM-facing path) -------------------------

test_peek_output_is_escape_free() {
  local dir capture home out target
  dir="$TMP_ROOT/peek"; mkdir -p "$dir"
  capture="$dir/styled.txt"
  # A screen full of styling, including dim ghost text. The plain peek path must
  # surface NONE of these escape codes into firstmate's context.
  printf 'normal output line\n\xe2\x9d\xaf \033[2mpredicted next prompt\033[0m\n' > "$capture"
  # Empty FM_HOME so fm-guard.sh finds no in-flight task and stays silent.
  home="$dir/home"; mkdir -p "$home/state"
  # An explicit endpoint target, so resolution needs no metadata.
  target=$(fm_test_stream_task "$dir/endpoints" win "" "$capture" | sed -n 's/^window=//p')
  out=$(FM_HOME="$home" "$PEEK" "$target" 2>/dev/null)
  case "$out" in
    *"$ESC"*) fail "fm-peek surfaced ANSI escape codes into LLM-facing output" ;;
  esac
  # And it should still carry the real content.
  case "$out" in
    *"predicted next prompt"*) : ;;
    *) fail "fm-peek dropped screen content (expected the ghost text body as plain text): $out" ;;
  esac
  pass "fm-peek output is escape-free (no styled bytes reach firstmate context)"
}

test_strip_ghost_drops_dim_keeps_normal
test_strip_ghost_handles_combined_and_boundary_codes
test_strip_ghost_keeps_colored_text_with_2_payloads
test_strip_ghost_drops_dark_truecolor_ghost
test_strip_ghost_keeps_muse_composer_colors
test_dim_ghost_only_composer_is_not_pending
test_dim_ghost_inside_bordered_composer_is_not_pending
test_normal_text_still_pending
test_colored_text_with_2_payload_still_pending
test_dark_truecolor_ghost_only_composer_is_not_pending
test_dark_truecolor_bare_shell_prompt_is_unknown
test_real_text_with_trailing_ghost_is_pending
test_two_row_composer_reads_text_above_empty_cursor_row
test_wrapped_composer_reads_all_content_rows
test_proven_box_bottom_border_cursor_classifies_content
test_bordered_busy_signatures_are_pending
test_non_bordered_busy_footer_is_unknown_strict
test_clipped_bordered_box_is_unknown
test_asymmetric_composer_edges_are_unknown
test_mismatched_box_families_are_unknown
test_misaligned_box_is_unknown
test_unproved_empty_geometry_fails_closed
test_differing_widths_use_asymmetric_verdicts
test_wide_composer_text_is_pending
test_all_harness_composers_share_classification
test_absent_identity_keeps_enclosed_bare_verdict
test_legitimate_empty_routes_remain_empty
test_non_bordered_composer_uses_compatibility_fallback
test_non_bordered_interior_edges_are_pending
test_peek_output_is_escape_free
