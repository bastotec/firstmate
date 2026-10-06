#!/usr/bin/env bash
# tests/fm-line-cap-lib.test.sh - the shared per-line digest cap
# (bin/fm-line-cap-lib.sh) never emits invalid UTF-8, whatever the locale.
#
# A remote fm-on job runs under env -i, so a stream endpoint it starts has no
# LANG and Bash slices bytes. A cut through a multibyte character then reached
# Deck's argv parser inside the session-start digest, which refuses the whole
# prompt ("invalid UTF-8 was detected in one or more arguments").
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# cap_is_valid <locale> <line> <max>: 0 when the capped line is valid UTF-8.
cap_is_valid() {
  LC_ALL=$1 bash -c '. "$1/bin/fm-line-cap-lib.sh"; fm_cap_line "$2" "$3"' _ "$ROOT" "$2" "$3" \
    | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1
}

test_cut_never_splits_a_character() {
  local loc ch line max
  for loc in C en_US.UTF-8; do
    for ch in 'é' '—' '😀'; do
      line="abcxxxxxx$ch$ch$ch${ch}tail-tail-tail-tail"
      for max in 20 21 22 23 24 25; do
        cap_is_valid "$loc" "$line" "$max" \
          || fail "LC_ALL=$loc cut '$ch' at max=$max into invalid UTF-8"
      done
    done
  done
  pass "fm_cap_line: a cut through a multibyte character stays valid UTF-8 in C and UTF-8 locales"
}

test_ascii_cut_is_unchanged() {
  local out
  out=$(LC_ALL=C bash -c '. "$1/bin/fm-line-cap-lib.sh"; fm_cap_line "$2" 20' _ "$ROOT" 'abcdefghijklmnopqrstuvwxyz')
  [ "$out" = 'abcdefgh [truncated]' ] || fail "ASCII cut changed: '$out'"
  pass "fm_cap_line: an ASCII cut keeps its exact length"
}

test_cut_never_splits_a_character
test_ascii_cut_is_unchanged
