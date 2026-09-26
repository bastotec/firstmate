#!/usr/bin/env bash
# Behavior tests for the spawn-side model fallback chain
# (bin/fm-model-chain-lib.sh, bin/fm-record-model-refusal.sh, and the chain
# resolution wired into bin/fm-spawn.sh and bin/fm-control.sh).
#
# Four capabilities are under test:
#   A) Parsing. The branch idiom (.pi/extensions/lib/fm-branch-model-chain.ts)
#      literally: one <provider>/<model-id> label per line split at the FIRST
#      slash (provider-qualified ids survive), blank and # comment lines
#      skipped, and any malformed or duplicate label a loud refusal naming that
#      line instead of a silent selection around it.
#   B) Fall-through. A launch resolves the first label whose cooldown has
#      expired; labels in cooldown are skipped and disclosed. The supervisor
#      records a refusal (quota, cooldown, repeated provider error) through
#      bin/fm-record-model-refusal.sh onto the task's lane.
#   C) Cooldown expiry. A recorded refusal sits out five minutes doubling to an
#      hour; once the retry epoch passes the label is ready again, so a later
#      launch restores the head of the chain.
#   D) Exhaustion. A chain whose every label is in cooldown refuses with a
#      clear reason, never substituting an out-of-chain model - including on
#      the spawn path itself, where the refusal must precede any task record.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-model-chain-lib.sh"
# shellcheck source=bin/fm-model-chain-lib.sh
. "$LIB"

TMP_ROOT=$(fm_test_tmproot fm-model-chain)
CHAIN=$'codex/gpt-6-luna\nzai/glm-5.3\nvercel/xiaomi/mimo-v2.6-flash\n'

# --- A) Parsing -------------------------------------------------------------

out=$(fm_model_chain_parse "$CHAIN")
assert_equals $'codex|gpt-6-luna\nzai|glm-5.3\nvercel|xiaomi/mimo-v2.6-flash' "$out" \
  "parse splits at the first slash so provider-qualified ids survive"

out=$(fm_model_chain_parse $'# comment\n\n  \ncodex/gpt-6-luna\n')
assert_equals 'codex|gpt-6-luna' "$out" "parse skips blank and comment lines"

out=$(fm_model_chain_parse 'a/b' 2>"$TMP_ROOT/err"); rc=$?
[ "$rc" -eq 0 ] || fail "single valid label parses"
assert_equals 'a|b' "$out" "single label parses to its pair"

out=$(fm_model_chain_parse $'good/model\nnoslash\n' 2>"$TMP_ROOT/err"); rc=$?
[ "$rc" -eq 1 ] || fail "a label without a slash refuses"
assert_contains "$(cat "$TMP_ROOT/err")" "noslash" "malformed refusal names the bad line"

out=$(fm_model_chain_parse $'a/b\na/b\n' 2>"$TMP_ROOT/err"); rc=$?
[ "$rc" -eq 1 ] || fail "a duplicate label refuses"
assert_contains "$(cat "$TMP_ROOT/err")" "duplicate" "duplicate refusal says duplicate"

out=$(fm_model_chain_parse $'onlyprovider/\n' 2>"$TMP_ROOT/err"); rc=$?
[ "$rc" -eq 1 ] || fail "a provider-only label refuses"

out=$(fm_model_chain_parse $'has space/model\n' 2>"$TMP_ROOT/err"); rc=$?
[ "$rc" -eq 1 ] || fail "a label with whitespace refuses"

out=$(fm_model_chain_head "$CHAIN")
assert_equals 'codex/gpt-6-luna' "$out" "head prints the first label"

fm_model_chain_head '' > "$TMP_ROOT/head-empty"; rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$TMP_ROOT/head-empty" ] || fail "an empty chain has no head but does not refuse"

fm_model_chain_parse_file "$TMP_ROOT/absent-chain" > "$TMP_ROOT/file-out"; rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$TMP_ROOT/file-out" ] || fail "an absent chain file parses as empty"
pass "parsing follows the branch idiom including loud refusals"

# --- B) Fall-through and the refusal recorder --------------------------------

STATEFILE="$TMP_ROOT/lane.state"
NOW=$(date +%s)

out=$(fm_model_chain_select "$STATEFILE" "$CHAIN" 2>"$TMP_ROOT/skip")
assert_equals 'codex/gpt-6-luna' "$out" "a fresh chain selects its head"
[ -s "$TMP_ROOT/skip" ] && fail "a fresh chain discloses no skips"

fm_model_chain_record_refusal "$STATEFILE" 'codex/gpt-6-luna' "$NOW"
out=$(fm_model_chain_select "$STATEFILE" "$CHAIN" 2>"$TMP_ROOT/skip")
assert_equals 'zai/glm-5.3' "$out" "a refused head falls through to the next label"
assert_contains "$(cat "$TMP_ROOT/skip")" "chain skip: codex/gpt-6-luna" "the skipped head is disclosed"

fm_model_chain_record_refusal "$STATEFILE" 'zai/glm-5.3' "$NOW"
out=$(fm_model_chain_select "$STATEFILE" "$CHAIN" 2>"$TMP_ROOT/skip")
assert_equals 'vercel/xiaomi/mimo-v2.6-flash' "$out" "two refusals reach the third label"

# The recorded backoff is the branch's: base five minutes, doubling.
record=$(fm_model_chain__state_lookup "$STATEFILE" 'codex/gpt-6-luna')
assert_equals "$((NOW + 300)) 300" "$record" "the first refusal of a streak sits out five minutes"
fm_model_chain_record_refusal "$STATEFILE" 'codex/gpt-6-luna' "$((NOW + 10))"
record=$(fm_model_chain__state_lookup "$STATEFILE" 'codex/gpt-6-luna')
assert_equals "$((NOW + 10 + 600)) 600" "$record" "an immediate re-refusal doubles the sitting-out time"
fm_model_chain_record_refusal "$STATEFILE" 'codex/gpt-6-luna' "$((NOW + 20))"
record=$(fm_model_chain__state_lookup "$STATEFILE" 'codex/gpt-6-luna')
assert_equals "$((NOW + 20 + 1200)) 1200" "$record" "a third refusal doubles the stored cooldown again"
fm_model_chain_record_refusal "$STATEFILE" 'codex/gpt-6-luna' "$((NOW + 30))"
record=$(fm_model_chain__state_lookup "$STATEFILE" 'codex/gpt-6-luna')
assert_equals "$((NOW + 30 + 2400)) 2400" "$record" "the fourth refusal doubles to forty minutes"
fm_model_chain_record_refusal "$STATEFILE" 'codex/gpt-6-luna' "$((NOW + 40))"
record=$(fm_model_chain__state_lookup "$STATEFILE" 'codex/gpt-6-luna')
assert_equals "$((NOW + 40 + 3600)) 3600" "$record" "the backoff caps at one hour"
pass "fall-through records refusals with the branch backoff"

# An expired streak starts fresh at the base instead of doubling across it:
# the first record for this label expired before the second refusal arrives,
# so the second sits out the base again, not a doubled interval.
fm_model_chain_record_refusal "$STATEFILE" 'vercel/xiaomi/mimo-v2.6-flash' "$((NOW - 400))"
record=$(fm_model_chain__state_lookup "$STATEFILE" 'vercel/xiaomi/mimo-v2.6-flash')
assert_equals "$((NOW - 100)) 300" "$record" "a refusal's record expires on its own schedule"
fm_model_chain_record_refusal "$STATEFILE" 'vercel/xiaomi/mimo-v2.6-flash' "$((NOW - 90))"
record=$(fm_model_chain__state_lookup "$STATEFILE" 'vercel/xiaomi/mimo-v2.6-flash')
assert_equals "$((NOW - 90 + 300)) 300" "$record" "a refusal after expiry starts a fresh streak"
pass "backoff streaks reset once a cooldown has expired"

# --- C) Cooldown expiry restores the head ------------------------------------

SHORT=$'a/model\nb/model\n'
EXPIRY="$TMP_ROOT/expiry.state"
fm_model_chain_record_refusal "$EXPIRY" 'a/model' "$NOW"
fm_model_chain_record_refusal "$EXPIRY" 'b/model' "$NOW"
out=$(fm_model_chain_select "$EXPIRY" "$SHORT" 2>/dev/null); rc=$?
[ "$rc" -eq 1 ] || fail "both labels cooling down exhausts the chain"
# Backdate both records past their retry epochs: the head comes back first.
printf 'a/model\t%s\nb/model\t%s\n' "$((NOW - 5))" "$((NOW - 1))" > "$EXPIRY"
out=$(fm_model_chain_select "$EXPIRY" "$SHORT" 2>"$TMP_ROOT/skip")
assert_equals 'a/model' "$out" "an expired head is restored ahead of an expired tail"
# fm_model_chain_clear is the success side: clearing the head's record drops
# its streak, exactly like the branch clearing a backoff after a clean turn.
fm_model_chain_clear "$EXPIRY" 'a/model'
out=$(fm_model_chain_select "$EXPIRY" "$SHORT" 2>/dev/null)
assert_equals 'a/model' "$out" "clearing a refusal makes the label ready again"
pass "cooldown expiry and clearing restore the head of the chain"

# --- D) Exhaustion refuses ----------------------------------------------------

EXHAUST="$TMP_ROOT/exhaust.state"
fm_model_chain_record_refusal "$EXHAUST" 'a/model' "$NOW"
fm_model_chain_record_refusal "$EXHAUST" 'b/model' "$NOW"
out=$(fm_model_chain_select "$EXHAUST" "$SHORT" 2>"$TMP_ROOT/exhaust.err"); rc=$?
[ "$rc" -eq 1 ] || fail "an exhausted chain refuses"
[ -z "$out" ] || fail "an exhausted chain prints no model"
assert_contains "$(cat "$TMP_ROOT/exhaust.err")" "model chain exhausted" "the exhaustion refusal says why"
assert_not_contains "$(cat "$TMP_ROOT/exhaust.err")" "a/model b/model" "no out-of-chain model is ever named or substituted"
pass "exhaustion refuses with a clear reason and no substitution"
