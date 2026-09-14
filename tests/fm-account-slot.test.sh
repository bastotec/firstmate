#!/usr/bin/env bash
# Public-interface behavior tests for home-local account slots.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-account-slot-tests)
HOME_DIR="$TMP_ROOT/home"
FAKEBIN="$TMP_ROOT/fakebin"
CALLS="$TMP_ROOT/calls"
mkdir -p "$HOME_DIR/config" "$FAKEBIN" "$HOME_DIR/profiles/claude-a" "$HOME_DIR/profiles/claude-b" \
  "$HOME_DIR/profiles/codex-a" "$HOME_DIR/profiles/codex-b"
chmod 700 "$HOME_DIR/config" "$HOME_DIR/profiles" "$HOME_DIR/profiles/"*
for credential in \
  "$HOME_DIR/profiles/claude-a/.credentials.json" \
  "$HOME_DIR/profiles/claude-b/.credentials.json" \
  "$HOME_DIR/profiles/codex-a/auth.json" \
  "$HOME_DIR/profiles/codex-b/auth.json"; do
  printf '{}\n' > "$credential"
  chmod 600 "$credential"
done

write_registry() {
  cat > "$HOME_DIR/config/account-slots.json" <<JSON
{
  "version": 1,
  "slots": {
    "claude-a": {"harness":"claude","storePath":"$HOME_DIR/profiles/claude-a","expectedSource":"oauth-file","expectedAccountId":"claude-account-a"},
    "claude-b": {"harness":"claude","storePath":"$HOME_DIR/profiles/claude-b","expectedSource":"oauth-file","expectedEmail":"claude-b@example.invalid"},
    "codex-a": {"harness":"codex","storePath":"$HOME_DIR/profiles/codex-a","expectedSource":"oauth","expectedAccountId":"codex-account-a"},
    "codex-b": {"harness":"codex","storePath":"$HOME_DIR/profiles/codex-b","expectedSource":"oauth","expectedAccountId":"codex-account-b"}
  }
}
JSON
  chmod 600 "$HOME_DIR/config/account-slots.json"
}

write_dispatch() {
  cat > "$HOME_DIR/config/crew-dispatch.json" <<'JSON'
{"default":[
  {"harness":"claude","model":"sonnet","effort":"high","accountSlots":["claude-a","claude-b"]},
  {"harness":"codex","model":"gpt","effort":"high","accountSlots":["codex-a","codex-b"]}
]}
JSON
  chmod 600 "$HOME_DIR/config/crew-dispatch.json"
}

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --help ]; then
  [ "${FAKE_NO_PROFILE_ONLY:-0}" = 1 ] || printf '%s\n' 'flags: --provider --profile-only --full --json --no-credential-refresh'
  exit 0
fi
if [ "${1:-}" = --version ]; then printf '%s\n' 'quota-axi 0.1.42'; exit 0; fi
printf 'argv=%s|claude=%s|codex=%s|anthropic=%s|openai=%s\n' "$*" "${CLAUDE_CONFIG_DIR-}" "${CODEX_HOME-}" "${ANTHROPIC_API_KEY-}" "${OPENAI_API_KEY-}" >> "${FAKE_CALLS:?}"
provider=
while [ "$#" -gt 0 ]; do
  if [ "$1" = --provider ]; then provider=$2; shift 2; else shift; fi
done
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
case "$provider" in
  claude)
    account=claude-account-a
    email=private@example.invalid
    case "${CLAUDE_CONFIG_DIR-}" in *claude-b) account=private-account; email=claude-b@example.invalid ;; esac
    source=oauth
    attempt=oauth-file
    ;;
  codex)
    account=codex-account-a
    case "${CODEX_HOME-}" in *codex-b) account=codex-account-b ;; esac
    source=oauth
    attempt=oauth
    ;;
esac
selected_store=${CLAUDE_CONFIG_DIR:-${CODEX_HOME:-}}
if [ -n "${FAKE_UNAVAILABLE_SLOT:-}" ]; then
  case "$selected_store" in *"$FAKE_UNAVAILABLE_SLOT") FAKE_MODE=mismatch ;; esac
fi
case "${FAKE_MODE:-ok}" in
  mismatch) account=wrong-account ;;
  wrong-source) source=pi ;;
  stale) stale=true ;;
esac
stale=${stale:-false}
status=fresh
[ "$stale" = false ] || status=stale
valid_account=$account
emit_document() {
cat <<JSON
{"generatedAt":"$now","schemaVersion":5,"providers":[{"provider":"$provider","source":"$source","account":{"accountId":"$account","email":"${email:-private@example.invalid}","organization":"private","identityStatus":"verified"},"attempts":[{"source":"$attempt","status":"success","path":"/private/credential"}],"state":{"status":"$status","stale":$stale,"refreshedAt":"$now"},"quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":75,"runway":{"status":"through_reset"},"selection":{"status":"known","spendPriority":-0.25}}]}}]}
JSON
}
if [ "${FAKE_MODE:-ok}" = invalid-then-valid ]; then
  account=wrong-account
  emit_document
  account=$valid_account
  emit_document
else
  emit_document
fi
SH
chmod +x "$FAKEBIN/quota-axi"

write_registry
write_dispatch
: > "$CALLS"

PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-account-slot.sh" validate >/dev/null || fail "valid four-slot registry and dispatch were refused"
pass "validates a strict four-slot registry and dispatch cross-references"

out=$(PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" ANTHROPIC_API_KEY=hostile CODEX_HOME=/hostile \
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" probe claude-a) \
  || fail "valid Claude slot probe failed"
assert_contains "$out" '"accountSlot":"claude-a"' "sanitized output omitted the logical slot"
assert_contains "$out" '"spendPriority":-0.25' "sanitized output omitted quota ranking evidence"
assert_not_contains "$out" 'claude-account-a' "sanitized output leaked account identity"
assert_not_contains "$out" 'private@example.invalid' "sanitized output leaked email"
assert_not_contains "$out" '/private/credential' "sanitized output leaked a credential path"
call=$(cat "$CALLS")
assert_contains "$call" 'argv=--provider claude --profile-only --full --json --no-credential-refresh' "probe argv did not request source-only full JSON without refresh"
assert_contains "$call" "claude=$HOME_DIR/profiles/claude-a|codex=|anthropic=|openai=" "Claude probe did not isolate the selected store and clear competing selectors"
pass "probes Claude through one isolated profile and emits only sanitized quota evidence"

: > "$CALLS"
PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" CLAUDE_CONFIG_DIR=/hostile OPENAI_API_KEY=hostile \
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" probe codex-a >/dev/null \
  || fail "valid Codex slot probe failed"
call=$(cat "$CALLS")
assert_contains "$call" "claude=|codex=$HOME_DIR/profiles/codex-a|anthropic=|openai=" "Codex probe did not isolate the selected store and clear competing selectors"
pass "probes Codex through one isolated profile"

PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-account-slot.sh" probe claude-b >/dev/null \
  || fail "email-identified Claude slot probe failed"
PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-account-slot.sh" probe claude-a >/dev/null \
  || fail "account-ID-identified Claude slot probe failed"
pass "keeps account-ID and email identity fields distinct"

: > "$CALLS"
PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-account-slot.sh" probe-all claude-a claude-a codex-a >/dev/null \
  || fail "deduplicated probe-all failed"
assert_equals 2 "$(wc -l < "$CALLS" | tr -d ' ')" "probe-all did not invoke each distinct slot exactly once"
pass "deduplicates slot probes within one decision"

: > "$CALLS"
out=$(PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FAKE_UNAVAILABLE_SLOT=claude-a FM_HOME="$HOME_DIR" \
  "$ROOT/bin/fm-account-slot.sh" probe-all claude-a codex-a) \
  || fail "one unavailable slot prevented later healthy probes"
assert_equals 2 "$(wc -l < "$CALLS" | tr -d ' ')" "mixed probe-all did not probe every selected slot"
printf '%s' "$out" | jq -e '
  .slots | length == 2 and
  .[0] == {accountSlot:"claude-a",availability:{status:"unavailable"}} and
  .[1].accountSlot == "codex-a" and .[1].providers[0].provider == "codex"
' >/dev/null || fail "mixed probe-all did not emit sanitized unavailable evidence beside the healthy result"
if printf '%s' "$out" | jq -e 'any(.. | objects; has("account") or has("attempts") or has("source") or has("storePath"))' >/dev/null; then
  fail "mixed probe-all leaked a forbidden private field"
fi
printf '%s\n' '{"forbidden":{"source":"private"},"later":{}}' | jq -e 'any(.. | objects; has("account") or has("attempts") or has("source") or has("storePath"))' >/dev/null \
  || fail "forbidden-field privacy predicate missed a nested field"
pass "continues after an unavailable slot and emits one privacy verdict"

for mode in mismatch wrong-source stale; do
  if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FAKE_MODE="$mode" FM_HOME="$HOME_DIR" \
      "$ROOT/bin/fm-account-slot.sh" probe claude-a >/dev/null 2>"$TMP_ROOT/$mode.err"; then
    fail "$mode quota evidence was accepted"
  fi
  assert_contains "$(cat "$TMP_ROOT/$mode.err")" "stale, mismatched, or malformed quota evidence" "$mode refusal was not concrete"
done
pass "rejects stale, wrong-source, and mismatched-account evidence"

if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FAKE_MODE=invalid-then-valid FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-account-slot.sh" probe claude-a >"$TMP_ROOT/multi-document.out" 2>"$TMP_ROOT/multi-document.err"; then
  fail "multiple quota JSON roots were accepted"
fi
assert_contains "$(cat "$TMP_ROOT/multi-document.err")" "malformed quota evidence" "multiple-root refusal was unclear"
assert_equals "" "$(cat "$TMP_ROOT/multi-document.out")" "multiple-root refusal emitted sanitized evidence"
pass "requires exactly one JSON root from every quota probe"

if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FAKE_NO_PROFILE_ONLY=1 FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-account-slot.sh" validate >/dev/null 2>"$TMP_ROOT/capability.err"; then
  fail "slotted dispatch accepted quota-axi without --profile-only"
fi
assert_contains "$(cat "$TMP_ROOT/capability.err")" "must support --profile-only" "missing capability refusal did not name the prerequisite"
pass "feature-detects the upstream source-only prerequisite"

cp "$HOME_DIR/config/account-slots.json" "$TMP_ROOT/valid-registry"
cp "$HOME_DIR/config/crew-dispatch.json" "$TMP_ROOT/valid-dispatch"
jq '.slots.default=.slots["claude-a"]' "$TMP_ROOT/valid-registry" > "$HOME_DIR/config/account-slots.json"
chmod 600 "$HOME_DIR/config/account-slots.json"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" validate >/dev/null 2>"$TMP_ROOT/default-registry.err"; then
  fail "reserved default registry slot was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/default-registry.err")" "default is reserved" "reserved registry slot refusal was unclear"
cp "$TMP_ROOT/valid-registry" "$HOME_DIR/config/account-slots.json"
jq '.default[0].accountSlots=["default"]' "$TMP_ROOT/valid-dispatch" > "$HOME_DIR/config/crew-dispatch.json"
chmod 600 "$HOME_DIR/config/account-slots.json" "$HOME_DIR/config/crew-dispatch.json"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" validate >/dev/null 2>"$TMP_ROOT/default-dispatch.err"; then
  fail "reserved default dispatch slot was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/default-dispatch.err")" "default is reserved" "reserved dispatch slot refusal was unclear"
: > "$CALLS"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" probe-all claude-a codex-a >/dev/null 2>"$TMP_ROOT/default-probe-all.err"; then
  fail "probe-all converted malformed dispatch configuration into per-slot unavailability"
fi
assert_equals 0 "$(wc -l < "$CALLS" | tr -d ' ')" "probe-all reached provider probes before refusing malformed dispatch configuration"
cp "$TMP_ROOT/valid-dispatch" "$HOME_DIR/config/crew-dispatch.json"
chmod 600 "$HOME_DIR/config/crew-dispatch.json"
pass "reserves default as the account-slot clear sentinel"

printf '{bad\n' > "$HOME_DIR/config/crew-dispatch.json"
chmod 600 "$HOME_DIR/config/crew-dispatch.json"
: > "$CALLS"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" probe-all claude-a >/dev/null 2>"$TMP_ROOT/malformed-dispatch.err"; then
  fail "malformed dispatch JSON was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/malformed-dispatch.err")" "cannot be inspected for accountSlots" "malformed dispatch refusal was unclear"
assert_equals 0 "$(wc -l < "$CALLS" | tr -d ' ')" "malformed dispatch reached a quota probe"
cp "$TMP_ROOT/valid-dispatch" "$HOME_DIR/config/crew-dispatch.json"
chmod 600 "$HOME_DIR/config/crew-dispatch.json"
pass "rejects malformed dispatch JSON before any quota probe"

printf '{bad\n' > "$HOME_DIR/config/account-slots.json"
chmod 600 "$HOME_DIR/config/account-slots.json"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" validate >/dev/null 2>&1; then
  fail "malformed registry JSON was accepted"
fi
: > "$CALLS"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" probe-all claude-a >/dev/null 2>"$TMP_ROOT/malformed-probe-all.err"; then
  fail "probe-all converted a malformed registry into per-slot unavailability"
fi
assert_equals 0 "$(wc -l < "$CALLS" | tr -d ' ')" "probe-all reached provider probes before refusing a malformed registry"
cp "$TMP_ROOT/valid-registry" "$HOME_DIR/config/account-slots.json"
chmod 600 "$HOME_DIR/config/account-slots.json"
jq --arg path "$HOME_DIR/profiles/claude-a" '.slots["claude-b"].storePath=$path' \
  "$HOME_DIR/config/account-slots.json" > "$TMP_ROOT/duplicate"
mv "$TMP_ROOT/duplicate" "$HOME_DIR/config/account-slots.json"
chmod 600 "$HOME_DIR/config/account-slots.json"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" validate >/dev/null 2>"$TMP_ROOT/duplicate.err"; then
  fail "duplicate canonical profile path was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/duplicate.err")" "duplicates another slot" "duplicate path refusal was unclear"
pass "rejects malformed registries and duplicate canonical profile paths"

cp "$TMP_ROOT/valid-registry" "$HOME_DIR/config/account-slots.json"
chmod 644 "$HOME_DIR/config/account-slots.json"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" validate >/dev/null 2>"$TMP_ROOT/file-mode.err"; then
  fail "group/world-readable registry was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/file-mode.err")" "no group or world permissions" "registry mode refusal was unclear"
chmod 600 "$HOME_DIR/config/account-slots.json"

mv "$HOME_DIR/config/account-slots.json" "$TMP_ROOT/registry-target"
ln -s "$TMP_ROOT/registry-target" "$HOME_DIR/config/account-slots.json"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" validate >/dev/null 2>"$TMP_ROOT/file-symlink.err"; then
  fail "symlinked registry was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/file-symlink.err")" "non-symlink regular file" "registry symlink refusal was unclear"
rm "$HOME_DIR/config/account-slots.json"
mv "$TMP_ROOT/registry-target" "$HOME_DIR/config/account-slots.json"

ln "$HOME_DIR/config/account-slots.json" "$TMP_ROOT/registry-hardlink"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" validate >/dev/null 2>"$TMP_ROOT/file-hardlink.err"; then
  fail "hardlinked registry was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/file-hardlink.err")" "must not be hardlinked" "registry hardlink refusal was unclear"
rm "$TMP_ROOT/registry-hardlink"

chmod 755 "$HOME_DIR/profiles/claude-a"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" validate >/dev/null 2>"$TMP_ROOT/dir-mode.err"; then
  fail "group/world-accessible profile directory was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/dir-mode.err")" "no group or world permissions" "profile directory mode refusal was unclear"
chmod 700 "$HOME_DIR/profiles/claude-a"

ln -s "$HOME_DIR/profiles/claude-a" "$HOME_DIR/profiles/claude-link"
jq --arg path "$HOME_DIR/profiles/claude-link" '.slots["claude-a"].storePath=$path' \
  "$HOME_DIR/config/account-slots.json" > "$TMP_ROOT/symlinked-store-registry"
mv "$TMP_ROOT/symlinked-store-registry" "$HOME_DIR/config/account-slots.json"
chmod 600 "$HOME_DIR/config/account-slots.json"
if PATH="$FAKEBIN:$PATH" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-account-slot.sh" validate >/dev/null 2>"$TMP_ROOT/dir-symlink.err"; then
  fail "symlinked profile directory was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/dir-symlink.err")" "existing non-symlink directory" "profile directory symlink refusal was unclear"
rm "$HOME_DIR/profiles/claude-link"
cp "$TMP_ROOT/valid-registry" "$HOME_DIR/config/account-slots.json"
chmod 600 "$HOME_DIR/config/account-slots.json"

OWNERBIN="$TMP_ROOT/ownerbin"
mkdir -p "$OWNERBIN"
cat > "$OWNERBIN/id" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -u ]; then
  actual=$("${FM_REAL_ID:?}" -u)
  printf '%s\n' "$((actual + 1))"
  exit 0
fi
exec "${FM_REAL_ID:?}" "$@"
SH
chmod +x "$OWNERBIN/id"
if PATH="$OWNERBIN:$FAKEBIN:$PATH" FM_REAL_ID="$(command -v id)" FAKE_CALLS="$CALLS" FM_HOME="$HOME_DIR" \
    "$ROOT/bin/fm-account-slot.sh" validate >/dev/null 2>"$TMP_ROOT/owner.err"; then
  fail "registry owner mismatch was accepted"
fi
assert_contains "$(cat "$TMP_ROOT/owner.err")" "owned by the current user" "owner mismatch refusal was unclear"
pass "rejects unsafe owner, mode, symlink, and hardlink states through the public validator"

printf 'all fm-account-slot tests passed\n'
