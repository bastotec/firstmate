# shellcheck shell=bash
# Shared per-line cap for agent-facing digest lines.
# Usage: . bin/fm-line-cap-lib.sh; fm_cap_line "<line>" [<max>]
#
# ONE OWNER for the bounded-line shape both digests use. The wake digest's
# OPEN DECISIONS section (bin/fm-wake-drain.sh) and the session-start digest's
# per-task status tails (bin/fm-session-start.sh) render the same kind of
# content - an agent-written status line, which AGENTS.md section 8 treats as a
# wake EVENT rather than current state - into a size-bounded view. An agent
# reading both must recognize one truncation marker, and the two caps must not
# drift apart, so the cut and its marker live here.
#
# Callers keep their own composite policy: fm-wake-drain.sh still owns the
# OPEN DECISIONS global byte cap and its "N more omitted" disclosure, and
# fm-session-start.sh still owns how many tail lines it prints per task. This
# file owns only the per-line cut.
#
# The cap follows the caller's Bash locale: characters in a UTF-8 locale,
# bytes in a C/POSIX locale. After slicing, a byte-local check drops any trailing
# partial UTF-8 sequence so valid UTF-8 input stays valid; whole-character cuts
# are unchanged. Deck's argv parser rejects a prompt with invalid UTF-8.
# Regression coverage: tests/fm-line-cap-lib.test.sh.
# Truncation stays recoverable because the session-start digest prints each
# task's full status log path, while every OPEN DECISIONS entry begins with the
# task id that identifies its durable state/<id>.status source.

FM_LINE_CAP_DEFAULT=220
FM_LINE_CAP_SUFFIX=' [truncated]'

# fm_cap_line_var <line> [<max>]: put <line> in FM_LINE_CAP_LINE, cut to <max>
# in the locale-dependent units above with FM_LINE_CAP_SUFFIX in place of the
# tail when it is longer. A line at or under the cap is kept unchanged, marker
# and all bytes intact.
# This is the rule itself. It assigns rather than prints so a caller that needs
# the value - the wake digest builds its section in a variable to weigh each
# item against a global budget - never pays a command substitution per item on
# a path that runs at the top of every wake-handling turn.
fm_cap_line_var() {
  local line=$1 max=${2:-$FM_LINE_CAP_DEFAULT} keep
  if [ "${#line}" -le "$max" ]; then
    FM_LINE_CAP_LINE=$line
    return 0
  fi
  keep=$((max - ${#FM_LINE_CAP_SUFFIX}))
  [ "$keep" -ge 0 ] || keep=0
  line=${line:0:$keep}
  fm_cap_line_drop_partial_utf8
  FM_LINE_CAP_LINE="$line$FM_LINE_CAP_SUFFIX"
}

# Drops an incomplete trailing UTF-8 sequence from the caller's $line. Byte
# semantics (LC_ALL=C) make this a no-op on a cut that ended on a whole
# character, whatever the caller's locale.
fm_cap_line_drop_partial_utf8() {
  local LC_ALL=C lead2=$'[\xc0-\xff]' lead3=$'[\xe0-\xff]' lead4=$'[\xf0-\xff]' cont=$'[\x80-\xbf]'
  # shellcheck disable=SC2254 # the patterns are byte classes, not literals
  case "$line" in
    *$lead2) line=${line%?} ;;
    *$lead3$cont) line=${line%??} ;;
    *$lead4$cont$cont) line=${line%???} ;;
  esac
}

# fm_cap_line <line> [<max>]: the same cut, printed on stdout, for a caller that
# is streaming lines rather than accumulating them.
fm_cap_line() {
  fm_cap_line_var "$@"
  printf '%s\n' "$FM_LINE_CAP_LINE"
}
