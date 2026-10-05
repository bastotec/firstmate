#!/usr/bin/env bash
# Supplemental dependency-return tests, not live-kernel evidence.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/.validation-stream-selected.test.sh"
command -v setsid >/dev/null 2>&1 && fail 'POSIX-return checks require the Perl fallback'
for result in negative undefined; do
  start_case_hub "forced-$result"
  mkdir -p "$CASE_DIR/perl-module"
  if [ "$result" = negative ]; then expression=-1; else expression=undef; fi
  printf "package ForcedSetsid; use POSIX (); no warnings 'redefine'; *POSIX::setsid = sub { \$! = 1; return %s; }; 1;\n" \
    "$expression" > "$CASE_DIR/perl-module/ForcedSetsid.pm"
  rc=0
  out=$(PERL5LIB="$CASE_DIR/perl-module" PERL5OPT=-MForcedSetsid \
    with_stream_env fm_backend_stream_create_task "fm-forced-$result-$$" "$CASE_DIR/cwd" 2>&1) || rc=$?
  printf 'injected POSIX::setsid=%s, endpoint refusal exit=%s: %s\n' "$expression" "$rc" "$out"
  [ "$rc" -ne 0 ] || fail "setsid return $expression must refuse"
  assert_contains "$out" 'setsid: Operation not permitted' 'failure must surface detachment diagnostic'
  count=$(with_stream_env fm_backend_stream_api GET /v1/tasks | jq '.tasks | length')
  assert_equals "$count" 0 'failed POSIX return must leave the real hub registry empty'
  printf 'real hub registry after injected %s: %s endpoints\n' "$expression" "$count"
  pass "supplemental $expression return refuses before starting the agent"
done
rc=0
out=$(with_stream_env fm_backend_stream_detached /nonexistent/fm-stream-exec-test 2>&1) || rc=$?
printf 'nonexistent executable refusal exit=%s: %s\n' "$rc" "$out"
[ "$rc" -ne 0 ] || fail 'failed exec must return nonzero'
assert_contains "$out" 'exec:' 'failed exec must carry its own diagnostic'
