#!/usr/bin/env bash
# tests/fm-voice-records.test.sh - bin/fm_voice_records.py: read scope, deny list and handover.
#
# fm_voice_records.py is the seam Ziggy's firstmate agent
# (agents/firstmate/fm_a2a_server.py in the Ziggy repository) imports from this
# home: fleet_status and read_scope answer status questions from the records,
# and queue_request hands real work over through bin/fm-inbox.sh note. Every case
# here drives the module or fm-inbox.sh directly and runs offline.
#
# THE CASE THAT MATTERS MOST is the confidentiality boundary. Finished work and
# free-form note bodies are never assembled at all, and those are exactly where
# commercial detail accumulates. This suite plants a marker in both places and
# fails if it ever reaches an answer, so widening the reader later breaks a test
# instead of quietly widening what is sent to a model in another region.
#
# The markers below are invented for this fixture. Real customer names are not
# committed to a test file.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-voice-records)
HOME_FIXTURE="$TMP_ROOT/home"
CONFIG_HOME="$TMP_ROOT/unconfigured"
mkdir -p "$CONFIG_HOME/config"

# NEVER_TOKEN sits in finished work and in a note body: both are excluded by
# construction, so it must never appear at any scope.
NEVER_TOKEN=NEVERLEAVESTHISHOST
# DENY_TOKEN sits in the title of open in-flight work, which the wide scope does
# report. It proves the deny list suppresses something that genuinely would have
# been sent, rather than passing vacuously against text no answer contains.
DENY_TOKEN=DENYMEPLEASE

seed_home() {
  mkdir -p "$HOME_FIXTURE/data" "$HOME_FIXTURE/state" "$HOME_FIXTURE/config"
  cat > "$HOME_FIXTURE/data/backlog.md" <<EOF
# Backlog

## In flight
- [ ] alpha-one - Fix the sign-in redirect (repo: alpha) (kind: ship) (priority: 0) (since 2026-08-01)
  Long note body written for someone with the whole file open, mentioning
  $NEVER_TOKEN and the rate we agreed.
- [ ] beta-two - Decide the storage shape (repo: beta) (kind: captain) (priority: 1)
- [ ] gamma-three - Migrate the $DENY_TOKEN account onto the new plan (repo: gamma) (kind: ship)

## Queued
- [ ] delta-four - Add the retry (repo: delta) (kind: ship) (hold-kind: captain) (hold: waiting on the user)
- [ ] epsilon-five - Tidy the logs (repo: epsilon) (kind: ship)

## Done
- [x] old-six - Shipped the $NEVER_TOKEN integration (repo: alpha) (done 2026-07-01)
# An unticked line under Done, held for review. Two separate mechanisms keep
# finished work out of an answer: the section is never parsed, and a ticked box is
# dropped. A ticked line is blocked by both, so it cannot tell which one broke.
# This line is blocked by the section rule alone, and the list of what waits on
# the user is assembled with no section filter at all, so it is the one place
# where losing that rule would put finished work into a spoken answer.
- [ ] old-seven - Decide the $NEVER_TOKEN renewal (repo: alpha) (kind: captain)
EOF

  fm_write_meta "$HOME_FIXTURE/state/alpha-one.meta" \
    kind=ship mode=no-mistakes window=firstmate:fm-alpha-one \
    pr=https://github.com/example/alpha/pull/7
  fm_write_meta "$HOME_FIXTURE/state/gamma-three.meta" kind=ship mode=direct-PR
  printf 'working: reading the failing test\n' > "$HOME_FIXTURE/state/alpha-one.status"
  # The bracketed shape, which is what bin/fm-secondmate-report.sh writes and
  # what a keyed decision line looks like. Status metadata sits between the verb
  # and the colon, so a reader that only cuts at the colon reads no verb here.
  printf 'blocked [key=api-shape]: needs a credential (via-helper)\n' \
    > "$HOME_FIXTURE/state/gamma-three.status"
}

records_status() {
  python3 "$ROOT/bin/fm_voice_records.py" status --home "$HOME_FIXTURE" "$@"
}

seed_home


# The inbox is the same rule with a different consequence: note, status,
# list and drain make no model call, so they must keep working unconfigured. The
# records handover depends on note, so that is not a nicety.
#
# EVERY FM_INBOX_ VARIABLE IS NEUTRALIZED HERE, at the harness rather than in each
# case, and the list is read out of the environment rather than written down, so a
# knob added later cannot quietly survive into a refusal case. A shell that
# exports a region and a model id would otherwise walk these cases straight past
# the refusal they assert and into a real model call: an offline suite that can
# spend the operator's credentials is worse than a failing one.
inbox_env=()
while IFS= read -r inbox_knob; do
  [ -n "$inbox_knob" ] || continue
  inbox_env+=(-u "$inbox_knob")
done < <(env | sed -n 's/^\(FM_INBOX_[A-Za-z0-9_]*\)=.*/\1/p' | sort -u)
inbox_env+=(FM_HOME="$CONFIG_HOME" FM_STATE_OVERRIDE="$CONFIG_HOME/state"
            FM_CONFIG_OVERRIDE="$CONFIG_HOME/config")

# And a stub that records any attempt, so "no model call" is a checked fact rather
# than a claim about control flow. The real aws would need credentials; this one
# leaves evidence and exits non-zero.
INBOX_FAKEBIN=$(fm_fakebin "$TMP_ROOT/inbox-fake")
AWS_CALLED="$TMP_ROOT/aws-was-called"
cat > "$INBOX_FAKEBIN/aws" <<SH
#!/usr/bin/env bash
printf 'aws %s\n' "\$*" >> "$AWS_CALLED"
exit 9
SH
chmod +x "$INBOX_FAKEBIN/aws"
inbox_env+=(PATH="$INBOX_FAKEBIN:$PATH")

set +e
ask_out=$(env "${inbox_env[@]}" "$ROOT/bin/fm-inbox.sh" ask "how is the fleet" 2>&1)
ask_code=$?
set -e
[ "$ask_code" -ne 0 ] || fail "ask ran with nothing configured"
assert_contains "$ask_out" 'inbox-region' \
  "the first refusal should name the region file: $ask_out"

# One file at a time, so each refusal names one thing to do.
printf 'eu-somewhere-1\n' > "$CONFIG_HOME/config/inbox-region"
set +e
ask_out=$(env "${inbox_env[@]}" "$ROOT/bin/fm-inbox.sh" ask "how is the fleet" 2>&1)
ask_code=$?
set -e
[ "$ask_code" -ne 0 ] || fail "ask ran without a configured model"
assert_contains "$ask_out" 'inbox-ask-model' \
  "the refusal should name the model file to write: $ask_out"

set +e
say_out=$(printf '' | env "${inbox_env[@]}" "$ROOT/bin/fm-inbox.sh" say 2>&1)
say_code=$?
set -e
[ "$say_code" -ne 0 ] || fail "say ran without a configured model"
assert_contains "$say_out" 'inbox-stt-model' \
  "the refusal should name the model file to write: $say_out"

rm -f "$CONFIG_HOME/config/inbox-region"
unconfigured_note=$(env "${inbox_env[@]}" \
  "$ROOT/bin/fm-inbox.sh" note "the handover must work with no configuration") \
  || fail "note should not need any configuration"
assert_contains "$unconfigured_note" 'queued ' "note should still queue a record"
assert_absent "$AWS_CALLED" \
  "no case above may reach a model: the aws stub recorded an attempt"
pass "the model-backed subcommands refuse by name while note keeps working"

# --help prints the whole header block, and finds where that block ends rather
# than counting lines to it, so growing the header cannot silently truncate the
# help again. The PRIVACY paragraph is the part that matters: it is the only place
# a new operator is told which subcommands send audio or text off this host, and a
# fixed line range had already dropped it.
inbox_help=$("$ROOT/bin/fm-inbox.sh" --help) || fail "fm-inbox.sh --help failed"
assert_contains "$inbox_help" 'PRIVACY:' \
  "the help must say which subcommands send anything to a model"
assert_contains "$inbox_help" 'make no network call at all' \
  "the help must name the subcommands that stay on this host"
assert_contains "$inbox_help" 'FM_HOME' \
  "the help must keep its environment section"
assert_contains "$inbox_help" 'inbox-ask-model' \
  "the help must name the files a home has to write"
assert_contains "$inbox_help" 'fm-inbox.sh note' \
  "the help must still open with the usage it always had"
pass "fm-inbox.sh --help prints its whole header, privacy paragraph included"

# --- read scope -------------------------------------------------------------

narrow=$(records_status --scope counts) || fail "counts scope failed"
assert_contains "$narrow" '"scope": "counts"' "counts scope should say so"
assert_contains "$narrow" '"in_flight": 3' "counts scope should still count in-flight work"
assert_contains "$narrow" '"queued": 2' "counts scope should still count queued work"
assert_contains "$narrow" '"awaiting_captain": 2' "counts scope should count what waits on the user"
assert_contains "$narrow" '"open_pull_requests": 1' "counts scope should count open pull requests"
# No record free text is assembled at all at this scope, so there is nothing to
# filter and nothing to get wrong.
assert_not_contains "$narrow" 'alpha-one' "counts scope must not name work"
assert_not_contains "$narrow" 'sign-in redirect' "counts scope must not carry titles"
assert_not_contains "$narrow" 'github.com' "counts scope must not carry pull request links"
pass "the narrow scope answers how much is waiting without saying what it is"

wide=$(records_status --scope full) || fail "full scope failed"
assert_contains "$wide" '"scope": "full"' "full scope should say so"
assert_contains "$wide" 'alpha-one' "full scope should name in-flight work"
assert_contains "$wide" 'sign-in redirect' "full scope should carry titles"
assert_contains "$wide" 'https://github.com/example/alpha/pull/7' \
  "full scope should carry the pull request link"
assert_contains "$wide" 'beta-two' "full scope should name what waits on the user"
# The state verb only. The agent speaks to the user and must not read an
# internal event line aloud.
assert_contains "$wide" '"state": "working"' "full scope should carry the state verb"
assert_not_contains "$wide" 'reading the failing test' \
  "full scope must not carry the raw event line"
# The same rule against the bracketed shape: the verb is still the verb, and the
# metadata and the note stay unspoken.
assert_contains "$wide" '"state": "blocked"' \
  "a status line with a metadata token before the colon should still report its verb"
assert_not_contains "$wide" 'key=api-shape' \
  "full scope must not carry status metadata"
assert_not_contains "$wide" 'needs a credential' \
  "full scope must not carry the raw event line of a bracketed status"
pass "the wide scope names open work and reports state without quoting event lines"

# THE DEFAULT IS THE NARROW SCOPE. A home that has configured nothing has granted
# nothing, and sending task identifiers, titles and pull request links to a model
# in another region is not something to inherit from somebody else's settings
# file. Widening is one line the owner of those records writes themselves.
default=$(records_status) || fail "default scope failed"
assert_contains "$default" '"scope": "counts"' \
  "an unconfigured home should get the narrow scope"
assert_not_contains "$default" 'alpha-one' \
  "an unconfigured home must not name work"
assert_not_contains "$default" 'sign-in redirect' \
  "an unconfigured home must not carry titles"
assert_not_contains "$default" 'github.com' \
  "an unconfigured home must not carry pull request links"
assert_contains "$default" '"in_flight": 3' \
  "an unconfigured home should still say how much is waiting"
pass "an absent read-scope setting means the narrowest answer, not the widest"

# Widening is what the file is for, and it takes effect without a flag.
printf 'full\n' > "$HOME_FIXTURE/config/voice-read-scope"
widened=$(records_status) || fail "configured wide scope failed"
assert_contains "$widened" '"scope": "full"' \
  "writing full into config/voice-read-scope should widen the answer"
assert_contains "$widened" 'alpha-one' "the wide scope should then name work"
rm -f "$HOME_FIXTURE/config/voice-read-scope"
pass "a home widens its own read scope by writing the setting"

# --- the confidentiality boundary -------------------------------------------
#
# This is the case that lets a home widen to the full scope at all.

for scope in full counts; do
  answer=$(records_status --scope "$scope") || fail "scope $scope failed"
  assert_not_contains "$answer" "$NEVER_TOKEN" \
    "finished work and note bodies must never reach a $scope answer"
  assert_not_contains "$answer" 'old-six' \
    "finished work must not be named in a $scope answer"
  assert_not_contains "$answer" 'old-seven' \
    "an unticked line under finished work must not be named in a $scope answer"
  assert_not_contains "$answer" 'the rate we agreed' \
    "a note body must not reach a $scope answer"
  # The count is the assertion that bites if the section rule is lost: old-seven
  # is held for review and that list has no section filter of its own.
  assert_contains "$answer" '"awaiting_captain": 2' \
    "finished work must not be counted as waiting on the user at $scope scope"
done
pass "finished work and note bodies never reach a spoken answer at any scope"

# The exclusion has to be structural rather than a filter on the way out, so the
# count of in-flight work stays honest while the body stays unread.
assert_contains "$wide" '"in_flight": 3' \
  "excluding note bodies must not change the count of in-flight work"
pass "excluding a note body does not distort the counts"

# --- the deny list ----------------------------------------------------------
#
# Reachable first, suppressed second. Without the first assertion the second
# proves nothing.

assert_contains "$wide" "$DENY_TOKEN" \
  "fixture is wrong: the deny marker should be reachable before it is denied"

printf '# one plain substring per line\n%s\n' "$DENY_TOKEN" \
  > "$HOME_FIXTURE/config/voice-read-deny"
denied=$(records_status --scope full) || fail "full scope with a deny list failed"
assert_not_contains "$denied" "$DENY_TOKEN" "the deny list must suppress a match"
assert_not_contains "$denied" 'gamma-three' \
  "a denied item must not be named at all"
assert_contains "$denied" '"withheld_as_confidential": 1' \
  "a denied item must still be counted so the user knows it exists"
assert_contains "$denied" '"in_flight": 3' \
  "denying an item must not change the count of in-flight work"
# The other in-flight work is unaffected: this is a substring list, not a switch.
assert_contains "$denied" 'alpha-one' "the deny list must not suppress everything"
pass "a denied item becomes a withheld count without hiding that work exists"

# Case-insensitive, because a confidentiality list that depends on the user
# matching the file's capitalisation is a confidentiality list that fails quietly.
printf '%s\n' "$(printf '%s' "$DENY_TOKEN" | tr '[:upper:]' '[:lower:]')" \
  > "$HOME_FIXTURE/config/voice-read-deny"
lower=$(records_status --scope full) || fail "lowercase deny list failed"
assert_not_contains "$lower" "$DENY_TOKEN" "the deny list must match regardless of case"
pass "the deny list matches regardless of case"

# The withheld figure counts denied items, not refusals, and the lists overlap by
# design: alpha-one is in flight AND carries a pull request, beta-two is in flight
# AND waiting on the user. Counting each refusal would tell the user four
# things are being withheld when two are, which is a wrong number spoken
# confidently about exactly the subject the user is most careful with.
printf '%s\n%s\n' alpha-one beta-two > "$HOME_FIXTURE/config/voice-read-deny"
overlap=$(records_status --scope full) || fail "overlapping deny list failed"
assert_contains "$overlap" '"withheld_as_confidential": 2' \
  "two denied items appearing in two lists each must be withheld twice, not four times"
assert_not_contains "$overlap" 'alpha-one' "a denied item must not be named"
assert_not_contains "$overlap" 'beta-two' "a denied item must not be named"
assert_not_contains "$overlap" 'github.com' \
  "denying an item must suppress its pull request link too"
assert_contains "$overlap" '"in_flight": 3' \
  "denying items must not change the count of in-flight work"
assert_contains "$overlap" '"open_pull_requests": 1' \
  "denying items must not change the count of open pull requests"
pass "an item denied in more than one list is counted as withheld once"

rm -f "$HOME_FIXTURE/config/voice-read-deny"

# THE CASE THE DENY LIST EXISTS FOR, and the one a per-list decision gets wrong.
# The docstring says the list is for a future open task carrying a customer name,
# and a name like that lives in the TITLE or in the HOLD text of an item that is
# also in flight, also waiting on the user, and also carrying a pull request.
# A decision taken separately in each list, from whichever fields that list
# happens to use, withholds such an item from one list and names it in another.
# That is not a narrower answer, it is a leak with a reassuring count beside it.
# Both items below sit in all three lists, and each is matched on a field only
# one of those lists reads.
#
# The third item is the one an in-flight-only fixture cannot catch: a QUEUED item
# that nothing holds for review, so no list iterates it, while its pull
# request link still reaches the answer through the worker records. Assembling its
# fields only where some list walks past it misses a match on its own title.
LEAK_HOME="$TMP_ROOT/deny-every-list"
TITLE_TOKEN=LEAKSBYTITLE
HOLD_TOKEN=LEAKSBYHOLD
QUEUED_TOKEN=LEAKSFROMQUEUED
mkdir -p "$LEAK_HOME/data" "$LEAK_HOME/state" "$LEAK_HOME/config"
cat > "$LEAK_HOME/data/backlog.md" <<EOF
# Backlog

## In flight
- [ ] omega-nine - Renew the $TITLE_TOKEN contract (repo: omega) (kind: captain)
- [ ] sigma-ten - Move the account onto the new tier (repo: sigma) (kind: ship) (hold-kind: captain) (hold: waiting on the $HOLD_TOKEN owner)

## Queued
- [ ] zeta-eight - Migrate the $QUEUED_TOKEN estate (repo: zeta) (kind: ship)
EOF
fm_write_meta "$LEAK_HOME/state/omega-nine.meta" \
  kind=captain pr=https://github.com/example/omega/pull/11
fm_write_meta "$LEAK_HOME/state/sigma-ten.meta" \
  kind=ship pr=https://github.com/example/sigma/pull/12
fm_write_meta "$LEAK_HOME/state/zeta-eight.meta" \
  kind=ship pr=https://github.com/example/zeta/pull/99

leak_status() {
  python3 "$ROOT/bin/fm_voice_records.py" status --home "$LEAK_HOME" --scope full
}

# Reachable in all three lists first, or the suppression below proves nothing.
reachable=$(leak_status) || fail "the deny-every-list fixture failed"
assert_contains "$reachable" "$TITLE_TOKEN" "fixture: the title marker should be reachable"
assert_contains "$reachable" 'omega-nine' "fixture: the item should be named"
assert_contains "$reachable" 'pull/11' "fixture: its pull request should be reachable"
assert_contains "$reachable" 'sigma-ten' "fixture: the held item should be named"
assert_contains "$reachable" 'pull/12' "fixture: its pull request should be reachable"
assert_contains "$reachable" '"awaiting_captain": 2' \
  "fixture: both in-flight items should be waiting on the user"
assert_contains "$reachable" 'pull/99' \
  "fixture: the queued item should reach the answer through its pull request"
assert_contains "$reachable" '"queued": 1' "fixture: the queued item should be counted"

# Matched on its title, which only the in-flight list reads.
printf '%s\n' "$TITLE_TOKEN" > "$LEAK_HOME/config/voice-read-deny"
by_title=$(leak_status) || fail "deny by title failed"
assert_not_contains "$by_title" "$TITLE_TOKEN" "a title match must be suppressed"
assert_not_contains "$by_title" 'omega-nine' \
  "a denied item must not be named in any list"
assert_not_contains "$by_title" 'pull/11' \
  "a denied item must not surface through its pull request link"
assert_contains "$by_title" '"withheld_as_confidential": 1' \
  "the denied item should be counted once"
# The other items are untouched, so this is a substring list and not a switch.
assert_contains "$by_title" 'sigma-ten' "the deny list must not suppress everything"
assert_contains "$by_title" 'pull/12' "the other pull requests should still be named"
assert_contains "$by_title" 'pull/99' "the other pull requests should still be named"
assert_contains "$by_title" '"open_pull_requests": 3' \
  "denying an item must not change the count of open pull requests"

# Matched on its hold text, which only the held-for-review list reads. The mirror of the
# case above: get one list right and this one still leaks.
printf '%s\n' "$HOLD_TOKEN" > "$LEAK_HOME/config/voice-read-deny"
by_hold=$(leak_status) || fail "deny by hold text failed"
assert_not_contains "$by_hold" 'sigma-ten' \
  "an item matched on its hold text must not be named in the in-flight list"
assert_not_contains "$by_hold" 'pull/12' \
  "an item matched on its hold text must not surface through its pull request"
assert_contains "$by_hold" '"withheld_as_confidential": 1' \
  "the denied item should be counted once"
assert_contains "$by_hold" 'omega-nine' "the deny list must not suppress everything"
assert_contains "$by_hold" 'pull/11' "the other pull request should still be named"
assert_contains "$by_hold" '"in_flight": 2' \
  "denying an item must not change the count of in-flight work"

# Matched on the title of a QUEUED item that no list iterates. Its only way into
# the answer is its pull request link, and the pull request list knows nothing
# about titles, so a field set assembled per list never sees the match at all.
printf '%s\n' "$QUEUED_TOKEN" > "$LEAK_HOME/config/voice-read-deny"
by_queued=$(leak_status) || fail "deny by queued title failed"
assert_not_contains "$by_queued" "$QUEUED_TOKEN" \
  "a queued item's title match must be suppressed"
assert_not_contains "$by_queued" 'zeta-eight' \
  "a denied queued item must not be named"
assert_not_contains "$by_queued" 'pull/99' \
  "a denied queued item must not surface through its pull request link"
assert_contains "$by_queued" '"withheld_as_confidential": 1' \
  "a denied queued item must be counted, so nothing is hidden silently"
assert_contains "$by_queued" '"queued": 1' \
  "denying it must not change the count of queued work"
assert_contains "$by_queued" 'pull/11' "the other pull requests should still be named"
assert_contains "$by_queued" 'pull/12' "the other pull requests should still be named"
pass "one deny decision per item covers every list that item could appear in"

# --- what a status line may say ---------------------------------------------
#
# A status line is free text a crewmate appended, and the verb taken off the
# front of it is the ONE record-derived string a counts-scope answer says out
# loud. At that scope there is no title and no link, so there is nothing for the
# deny list to filter and no scope setting that makes it safe. The vocabulary is
# therefore closed to the states bin/fm-brief.sh gives every crewmate plus the two
# bin/fm-classify-lib.sh adds when a decision closes, and anything else is a note.
VERB_HOME="$TMP_ROOT/status-verbs"
# Lowercase on purpose. The reader lowercases a verb before it could ever be
# emitted, and assert_not_contains compares case-sensitively, so an uppercase
# marker here would make the assertion below unable to fail on leaking code.
CUSTOMER_TOKEN=acmecorpmigration
mkdir -p "$VERB_HOME/data" "$VERB_HOME/state"
cat > "$VERB_HOME/data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] one - First thing (repo: a) (kind: ship)
- [ ] two - Second thing (repo: b) (kind: ship)
- [ ] three - Third thing (repo: c) (kind: ship)
EOF
fm_write_meta "$VERB_HOME/state/one.meta" kind=ship
fm_write_meta "$VERB_HOME/state/two.meta" kind=ship
fm_write_meta "$VERB_HOME/state/three.meta" kind=ship
printf 'needs-decision [key=shape]: which shape\n' > "$VERB_HOME/state/one.status"
printf '%s: waiting on their security review\n' "$CUSTOMER_TOKEN" \
  > "$VERB_HOME/state/two.status"
# A log past the tail window, so the read is proven to end at the last line
# rather than at the start of whatever window it happened to open.
{
  verb_line=0
  while [ "$verb_line" -lt 400 ]; do
    printf 'working: step %s of a long task with a wordy status line\n' "$verb_line"
    verb_line=$((verb_line + 1))
  done
  printf 'done: shipped it\n'
} > "$VERB_HOME/state/three.status"
[ "$(wc -c < "$VERB_HOME/state/three.status")" -gt 8192 ] \
  || fail "fixture: the long status log should exceed the tail window"

verb_status() {
  python3 "$ROOT/bin/fm_voice_records.py" status --home "$VERB_HOME" "$@"
}

verbs=$(verb_status --scope counts) || fail "counts scope with odd verbs failed"
assert_not_contains "$verbs" "$CUSTOMER_TOKEN" \
  "a word outside the vocabulary must not be spoken, at the default scope least of all"
assert_contains "$verbs" '"note": 1' \
  "an unrecognised verb should be counted as a note instead"
assert_contains "$verbs" '"needs-decision": 1' \
  "a canonical verb, brackets and all, should survive the fold"
assert_contains "$verbs" '"done": 1' \
  "the last line of a long log is the line that counts"
assert_not_contains "$verbs" '"working"' \
  "an earlier line in the same log must not be reported as the state"
pass "the state verb is a closed vocabulary, so free text cannot ride out on it"

# The two halves of one answer must come from one home. Every script that sets
# FM_DATA_OVERRIDE sets FM_STATE_OVERRIDE beside it, so a reader that resolved one
# and not the other would count workers and notes from one home while counting
# in-flight work from another, which reads exactly like an ordinary answer.
alt_data="$TMP_ROOT/data-elsewhere"
mkdir -p "$alt_data"
cat > "$alt_data/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] moved-one - Work recorded in the overridden data directory (repo: m) (kind: ship)
EOF
moved=$(FM_DATA_OVERRIDE="$alt_data" verb_status --scope full) \
  || fail "status with an overridden data directory failed"
assert_contains "$moved" 'moved-one' \
  "the reader must take the backlog from the overridden data directory"
assert_contains "$moved" '"in_flight": 1' "and count only what that backlog holds"
inbox_moved=$(FM_HOME="$VERB_HOME" FM_STATE_OVERRIDE="$VERB_HOME/state" \
  FM_DATA_OVERRIDE="$alt_data" "$ROOT/bin/fm-inbox.sh" status) \
  || fail "fm-inbox status with an overridden data directory failed"
assert_contains "$inbox_moved" 'moved-one' \
  "the human rendering of the same records must read the same backlog"
pass "the backlog and the state directory always come from the same home"

# --- pull requests on finished work -----------------------------------------
#
# A task keeps its state/<id>.meta after its backlog item is marked done, because
# removing the record and moving the item are separate steps. So a reader that took
# every worker carrying a pull request would count and name finished work, which
# this module promises never to read. Worse, the deny list could not reach those
# items: with no open item there is no title in the field set, so a deny
# substring matching the title silently failed for exactly them while working
# everywhere else. Losing the count of a pull request on a finished task is the
# accepted cost of that control applying everywhere it appears to.
DONE_HOME="$TMP_ROOT/finished-pull-requests"
FINISHED_TOKEN=SHIPPEDLASTWEEK
mkdir -p "$DONE_HOME/data" "$DONE_HOME/state" "$DONE_HOME/config"
cat > "$DONE_HOME/data/backlog.md" <<EOF
# Backlog

## In flight
- [ ] still-open - Fix the retry (repo: a) (kind: ship)
- [x] ticked-two - Renew the $FINISHED_TOKEN contract (repo: b) (kind: ship)

## Done
- [x] older-three - Migrate the $FINISHED_TOKEN estate (repo: c) (kind: ship)
EOF
fm_write_meta "$DONE_HOME/state/still-open.meta" \
  kind=ship pr=https://github.com/example/a/pull/1
fm_write_meta "$DONE_HOME/state/ticked-two.meta" \
  kind=ship pr=https://github.com/example/b/pull/2
fm_write_meta "$DONE_HOME/state/older-three.meta" \
  kind=ship pr=https://github.com/example/c/pull/3

done_status() {
  python3 "$ROOT/bin/fm_voice_records.py" status --home "$DONE_HOME" --scope full
}

open_only=$(done_status) || fail "the finished-pull-request fixture failed"
assert_contains "$open_only" '"open_pull_requests": 1' \
  "only open work has an open pull request"
assert_contains "$open_only" 'pull/1' "the open task's pull request should be named"
assert_not_contains "$open_only" 'ticked-two' \
  "a ticked item must not be named through its pull request"
assert_not_contains "$open_only" 'pull/2' \
  "a ticked item's pull request must not be named"
assert_not_contains "$open_only" 'older-three' \
  "an item under Done must not be named through its pull request"
assert_not_contains "$open_only" 'pull/3' \
  "an item under Done must not have its pull request named"
assert_not_contains "$open_only" "$FINISHED_TOKEN" \
  "no finished title may reach the answer at any scope"
# Excluded by construction, not withheld and counted. A later change that put
# finished work back in and leaned on the deny list to hide it would fail here.
assert_contains "$open_only" '"withheld_as_confidential": 0' \
  "finished work is left out rather than counted as withheld"
# The worker count is deliberately NOT open-only: a task keeps its runtime record
# until teardown removes it, and that record is what "on deck" counts. Asserted in
# the same case as the pull request count so the two cannot quietly converge.
assert_contains "$open_only" '"workers_on_deck": 3' \
  "every live runtime record is still on deck, finished or not"
pass "a finished task's pull request is neither counted nor named"

# The deny list, observed doing its job on the one list that still carries links.
# A substring matching an OPEN task's title takes that task out of the pull
# request detail and says one thing is being withheld, while the count stays
# honest: that split is the contract this module states and the earlier cases
# pin, so the user learns how much is waiting without learning what it is.
printf '%s\n' 'Fix the retry' > "$DONE_HOME/config/voice-read-deny"
denied_open=$(done_status) || fail "deny by an open title failed"
assert_not_contains "$denied_open" 'still-open' \
  "a denied open task must not be named in the pull request detail"
assert_not_contains "$denied_open" 'pull/1' \
  "a denied open task's pull request link must go with it"
assert_contains "$denied_open" '"withheld_as_confidential": 1' \
  "and the user must be told one thing is being withheld"
assert_contains "$denied_open" '"open_pull_requests": 1' \
  "while the count of open pull requests stays honest"
rm -f "$DONE_HOME/config/voice-read-deny"
pass "a deny substring on an open title removes its pull request and says so"

# --- refusals ---------------------------------------------------------------
#
# A misconfigured read scope must stop rather than fall back to the wider one,
# because falling back would widen what is sent on the strength of a typo.

printf 'everything\n' > "$HOME_FIXTURE/config/voice-read-scope"
set +e
out=$(records_status 2>&1)
code=$?
set -e
expect_code 2 "$code" "an unknown read scope should refuse"
assert_contains "$out" 'voice-read-scope' "the refusal should name the setting"
pass "an unknown read scope refuses instead of widening"

printf 'counts\n' > "$HOME_FIXTURE/config/voice-read-scope"
configured=$(records_status) || fail "configured scope failed"
assert_contains "$configured" '"scope": "counts"' "the configured scope should be used"
rm -f "$HOME_FIXTURE/config/voice-read-scope"
pass "the configured read scope is honoured"

# --- handover ---------------------------------------------------------------
#
# The point of the boundary: real work is queued for firstmate, not done by the
# agent that asked. It reuses bin/fm-inbox.sh rather than carrying a second queue.

before=$(find "$HOME_FIXTURE/state" -maxdepth 2 -name '*.note' | wc -l | tr -d '[:space:]')
[ "$before" = 0 ] || fail "fixture should start with an empty inbox"

handed=$(FM_HOME="$HOME_FIXTURE" python3 "$ROOT/bin/fm_voice_records.py" queue \
  "Refactor the login module and open a pull request for it" \
  --home "$HOME_FIXTURE") || fail "handover failed"
assert_contains "$handed" '"queued": true' "handover should report the request queued"
assert_contains "$handed" 'did not do the work yourself' \
  "handover should tell the model it handed over rather than acted"

notes=$(find "$HOME_FIXTURE/state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d '[:space:]')
[ "$notes" = 1 ] || fail "handover should leave exactly one note, found $notes"
note_file=$(find "$HOME_FIXTURE/state/inbox" -maxdepth 1 -name '*.note' | head -1)
assert_grep 'Refactor the login module' "$note_file" \
  "the note should carry the user's words"

# Exactly one wake, so a spoken request is presented once at firstmate's next
# check rather than queued twice or lost.
assert_present "$HOME_FIXTURE/state/.wake-queue" \
  "handover should wake firstmate"
wakes=$(grep -c 'inbox:' "$HOME_FIXTURE/state/.wake-queue")
[ "$wakes" = 1 ] || fail "handover should append exactly one wake, found $wakes"

# The reading half must see what the queueing half just wrote, or the agent says
# the request is queued and then, asked what is waiting, says nothing is.
paired=$(records_status --scope counts) || fail "status after a handover failed"
assert_contains "$paired" '"captain_notes_waiting": 1' \
  "the reader should count the note the handover just queued"
pass "handover queues the request for firstmate and wakes it exactly once"

# A handover while earlier notes sit unread must not promise a prompt pickup:
# the user hears that firstmate is not reading its inbox instead of waiting
# out an ask nobody is going to answer.
assert_not_contains "$handed" 'delivery_warning' \
  "a handover with nothing overdue should carry no delivery warning"
warn_home="$TMP_ROOT/overdue-home"
mkdir -p "$warn_home/state/inbox" "$warn_home/data"
printf 'id=1000-old001\n--\nwhat are you doing\n' > "$warn_home/state/inbox/1000-old001.note"
warned=$(FM_HOME="$warn_home" python3 "$ROOT/bin/fm_voice_records.py" queue \
  "Why are the second mates idle" --home "$warn_home") || fail "handover with an overdue note failed"
assert_contains "$warned" '"queued": true' "an overdue inbox must not stop the handover"
assert_contains "$warned" '"delivery_warning": "1 earlier captain note(s) still unread, oldest 1000-old001' \
  "the handover did not pass on the overdue warning: $warned"
assert_contains "$warned" 'Tell the captain' "the handover still promised a prompt pickup: $warned"
pass "a handover says so when firstmate has left earlier notes unread"

# The same pairing when the state directory is moved. bin/fm-inbox.sh resolves
# ${FM_STATE_OVERRIDE:-$FM_HOME/state} and the handover queues through it with
# the ambient environment, so a reader that ignored the override would count
# notes in a directory nothing writes to.
alt_state="$TMP_ROOT/state-elsewhere"
alt_home="$TMP_ROOT/override-home"
mkdir -p "$alt_state" "$alt_home/data" "$alt_home/state"
FM_STATE_OVERRIDE="$alt_state" python3 "$ROOT/bin/fm_voice_records.py" queue \
  "Chase the flaky retry test" --home "$alt_home" >/dev/null \
  || fail "handover with an overridden state directory failed"

moved=$(find "$alt_state/inbox" -maxdepth 1 -name '*.note' | wc -l | tr -d '[:space:]')
[ "$moved" = 1 ] || \
  fail "the queue should write into the overridden state directory, found $moved"
[ ! -e "$alt_home/state/inbox" ] || \
  fail "the queue should not have written under the home when the state is moved"

overridden=$(FM_STATE_OVERRIDE="$alt_state" python3 \
  "$ROOT/bin/fm_voice_records.py" status --home "$alt_home") \
  || fail "status with an overridden state directory failed"
assert_contains "$overridden" '"captain_notes_waiting": 1' \
  "the reader must count notes where the queue actually wrote them"
pass "the reader and the queue resolve the state directory the same way"

set +e
empty_out=$(python3 "$ROOT/bin/fm_voice_records.py" queue "   " \
  --home "$HOME_FIXTURE" 2>&1)
empty_code=$?
set -e
expect_code 2 "$empty_code" "queueing empty text should refuse"
assert_contains "$empty_out" 'empty' "the refusal should say the request was empty"
pass "an empty request is refused rather than queued as a blank note"

# --- absent records ---------------------------------------------------------
#
# A home with no records at all must answer "nothing" rather than fail, because
# the agent is spoken to and an exception is not an answer.

bare="$TMP_ROOT/bare"
mkdir -p "$bare"
bare_out=$(python3 "$ROOT/bin/fm_voice_records.py" status --home "$bare") \
  || fail "an empty home should still answer"
assert_contains "$bare_out" '"in_flight": 0' "an empty home should report no work"
assert_contains "$bare_out" '"workers_on_deck": 0' "an empty home should report no workers"
pass "a home with no records answers nothing rather than failing"

printf 'all voice records cases passed\n'
