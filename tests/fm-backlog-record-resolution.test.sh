#!/usr/bin/env bash
# Failure evidence at the public backlog record-validation/publication boundary.
# Controlled command failures test diagnostics, not the cause of an intermittent
# startup incident; real Perl exercises the path and record-preservation guards.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backlog-transition-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backlog-record-resolution)
REAL_PERL=$(command -v perl)
export REAL_PERL
export FM_HOME="$TMP_ROOT/home with space"
mkdir -p "$FM_HOME/state/nested" "$FM_HOME/other" "$TMP_ROOT/foreign"
STATE="$FM_HOME/state"
RECORD="$STATE/nested/retained.meta"
printf 'kind=secondmate\nspawn_gen=fixture-generation\n' > "$RECORD"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=fixture-host\n' > "$FM_HOME/.fm-secondmate-parent"
cp "$RECORD" "$TMP_ROOT/record.before"
cp "$FM_HOME/.fm-secondmate-parent" "$TMP_ROOT/binding.before"
STDERR_FILE="$TMP_ROOT/stderr"

fm_backlog_record_present "$RECORD" 'task record' "$STATE" 2> "$STDERR_FILE" \
  || fail "a regular record was refused: $FM_BACKLOG_TRANSITION_ERROR"
[ ! -s "$STDERR_FILE" ] || fail 'successful resolution should be silent'
pass 'real resolver accepts regular records without diagnostic output'

# An absent ancestor forces a realpath error on platforms that permit a
# nonexistent final leaf to resolve lexically before the directory guard.
missing="$FM_HOME/missing/state"
if fm_backlog_record_present "$missing/task.meta" 'task record' "$missing" 2> "$STDERR_FILE"; then
  fail 'missing root was accepted'
fi
assert_contains "$(cat "$STDERR_FILE")" 'realpath failed: No such file or directory' 'missing root lost its errno'
assert_contains "$FM_BACKLOG_TRANSITION_ERROR" 'resolver status=1;' 'missing root lost its exit status'
assert_contains "$FM_BACKLOG_TRANSITION_ERROR" 'authorized directory cannot be resolved' 'missing root changed the refusal'
pass 'missing-root refusal retains the actual errno and child status'

FAKEBIN=$(fm_fakebin "$TMP_ROOT/commands")
cat > "$FAKEBIN/perl" <<'SH'
#!/usr/bin/env bash
args=("$@")
path=${args[${#args[@]}-1]}
[ "$path" = "$FM_TEST_RESOLVE_PATH" ] || exec "$REAL_PERL" "$@"
case "$FM_TEST_RESOLVE_MODE" in
  nonzero)
    "$REAL_PERL" "$@" || exit "$?"
    printf 'synthetic resolver stderr\n' >&2
    exit 37
    ;;
  empty) exit 0 ;;
  malformed) printf 'not-a-directory'; exit 0 ;;
  long)
    printf 'line-one\n'
    printf '%0600d' 0
    exit 37
    ;;
esac
exit 99
SH
chmod +x "$FAKEBIN/perl"
PATH="$FAKEBIN:$PATH"
export PATH FM_TEST_RESOLVE_PATH FM_TEST_RESOLVE_MODE
FM_TEST_RESOLVE_MODE=nonzero

# Discriminate all four assignment boundaries while executing the real helper.
for stage in root home parent final; do
  case "$stage" in
    root) FM_TEST_RESOLVE_PATH="$STATE"; expected='authorized directory cannot be resolved' ;;
    home) FM_TEST_RESOLVE_PATH="$FM_HOME"; expected='home directory cannot be resolved' ;;
    parent) FM_TEST_RESOLVE_PATH="$STATE/nested"; expected='parent directory cannot be resolved' ;;
    final) FM_TEST_RESOLVE_PATH="$RECORD"; expected='task record cannot be resolved' ;;
  esac
  rc=0
  fm_backlog_record_present "$RECORD" 'task record' "$STATE" 2> "$STDERR_FILE" || rc=$?
  [ "$rc" = 1 ] || fail "$stage: public refusal changed to $rc"
  assert_contains "$FM_BACKLOG_TRANSITION_ERROR" "$expected" "$stage: wrong failure boundary"
  assert_contains "$FM_BACKLOG_TRANSITION_ERROR" 'resolver status=37;' "$stage: child status was lost"
  # shellcheck disable=SC2016 # Perl owns ARGV, not the calling shell.
  resolved=$("$REAL_PERL" -MCwd=realpath -e 'print realpath($ARGV[0])' "$FM_TEST_RESOLVE_PATH")
  printf -v escaped '%q' "$resolved"
  assert_contains "$FM_BACKLOG_TRANSITION_ERROR" "stdout=$escaped;" "$stage: valid child stdout was lost"
  assert_contains "$FM_BACKLOG_TRANSITION_ERROR" 'source=' "$stage: resolver owner is missing"
  assert_contains "$(cat "$STDERR_FILE")" 'synthetic resolver stderr' "$stage: child stderr was discarded"
done
pass 'each assignment retains a nonzero child status, valid stdout and stderr without accepting the record'

FM_TEST_RESOLVE_PATH="$STATE"
for FM_TEST_RESOLVE_MODE in empty malformed; do
  if fm_backlog_record_present "$RECORD" 'task record' "$STATE" 2> "$STDERR_FILE"; then
    fail "$FM_TEST_RESOLVE_MODE successful stdout was accepted"
  fi
  assert_contains "$FM_BACKLOG_TRANSITION_ERROR" 'authorized directory is not a directory' 'stdout shape was confused with a nonzero child'
  assert_not_contains "$FM_BACKLOG_TRANSITION_ERROR" 'resolver status=' 'zero child status was reported as child failure'
done
pass 'zero-status empty or malformed stdout still fails the directory guard'

FM_TEST_RESOLVE_MODE=long
if fm_backlog_record_present "$RECORD" 'task record' "$STATE" 2> "$STDERR_FILE"; then
  fail 'oversized failing stdout was accepted'
fi
assert_contains "$FM_BACKLOG_TRANSITION_ERROR" '(truncated)' 'failing stdout preview was not bounded'
assert_not_contains "$FM_BACKLOG_TRANSITION_ERROR" $'line-one\n' 'failing stdout injected a diagnostic line'
[ "${#FM_BACKLOG_TRANSITION_ERROR}" -lt 1200 ] || fail 'failing stdout diagnostic grew without a bound'
pass 'failing stdout preview is bounded and shell-escaped'

# Failed publication/removal must preserve both durable bytes and parent binding.
FM_TEST_RESOLVE_MODE=nonzero
STAGED="$STATE/staged.meta"
printf 'new staged bytes\n' > "$STAGED"
cp "$STAGED" "$TMP_ROOT/staged.before"
if fm_backlog_record_publish "$STAGED" "$RECORD" 'task record' "$STATE" 2> "$STDERR_FILE"; then
  fail 'publication accepted a failed resolver'
fi
cmp -s "$STAGED" "$TMP_ROOT/staged.before" || fail 'failed publication consumed staged bytes'
if fm_backlog_record_remove "$RECORD" 'task record' "$STATE" 2> "$STDERR_FILE"; then
  fail 'removal accepted a failed resolver'
fi
cmp -s "$RECORD" "$TMP_ROOT/record.before" || fail 'failed mutation changed retained record bytes'
cmp -s "$FM_HOME/.fm-secondmate-parent" "$TMP_ROOT/binding.before" || fail 'failed mutation changed parent binding'
pass 'resolver failure preserves transactional records and durable parent binding'

# Only real resolution for the unsafe-path cases, not an injected refusal.
FM_TEST_RESOLVE_PATH=__no_injection__
printf 'foreign bytes\n' > "$TMP_ROOT/foreign/foreign.meta"
printf 'other bytes\n' > "$FM_HOME/other/other.meta"
ln -s "$TMP_ROOT/foreign/foreign.meta" "$STATE/outside.meta"
ln -s "$RECORD" "$STATE/internal.meta"
ln -s "$TMP_ROOT/foreign" "$FM_HOME/escape"
for kind in final-outside internal-alias root-outside traversal; do
  root="$STATE"
  case "$kind" in
    final-outside) path="$STATE/outside.meta"; expected='resolves outside its authorized directory' ;;
    internal-alias) path="$STATE/internal.meta"; expected='resolves through a different final path' ;;
    root-outside) root="$FM_HOME/escape"; path="$root/foreign.meta"; expected='authorized directory resolves outside this home' ;;
    traversal) path="$STATE/../other/other.meta"; expected='resolves outside its authorized directory' ;;
  esac
  if fm_backlog_record_present "$path" 'task record' "$root" 2> "$STDERR_FILE"; then
    fail "$kind unsafe path was accepted"
  fi
  assert_contains "$FM_BACKLOG_TRANSITION_ERROR" "$expected" "$kind: changed containment refusal"
done
cmp -s "$RECORD" "$TMP_ROOT/record.before" || fail 'unsafe-path checks changed retained bytes'
pass 'real resolution preserves symlink, home-root and traversal refusals'
