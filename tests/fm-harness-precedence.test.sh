#!/usr/bin/env bash
# Behavior tests for bin/fm-harness.sh's Deck-only detection and the
# supervision protocol session start selects from it.
#
# Deck is the only supported harness, and it publishes no identity variable, so
# detection is ancestry alone: the nearest Deck process (`deck`, or a host
# running under argv[0] `fm-deck-worker` or `fm-deck-chat`) in the parent
# chain. Environment markers a removed harness used to publish (CLAUDECODE,
# PI_CODING_AGENT, ...) and processes named after a removed harness must never
# produce a verdict: a home still running one reads `unknown`.
#
# The cases drive real processes named after each harness, plus a fake ps that
# blinds the walk, so a case cannot pass vacuously: the blinded case proves the
# walk is what answers, and the named-process cases prove it is live.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"
RENDER="$ROOT/bin/fm-supervision-instructions.sh"
TMP_ROOT=$(fm_test_tmproot fm-harness-precedence)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# A real process whose argv[0] names a harness, asked for its verdict from a
# child. `exec -a` sets argv[0], which macOS reports as the process name and
# Linux keeps in /proc/<pid>/cmdline. The command substitution around the probe
# is load-bearing: a bare `-c <cmd>` lets the shell exec the probe in place,
# which REPLACES the harness-named process the walk is supposed to find.
under_named() {  # <name> <probe> [VAR=VAL ...]
  local name=$1 probe=$2
  shift 2
  # shellcheck disable=SC2016 # expands inside the renamed shell.
  env "$@" bash -c 'exec -a "$1" bash -c "r=\$(\"\$0\"); printf %s \"\$r\"" "$2"' _ "$name" "$probe"
}

# A fake ps that reports a bash ancestor terminating at pid 1, so the ancestry
# walk proves nothing.
blind_ancestry_bin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'ppid='*) printf '%s\n' 1 ;;
  *) printf '%s\n' bash ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

# A fake ps that models a PID NAMESPACE: every process reports bash with ppid 1,
# and pid 1 reports whatever FM_TEST_PID1_COMM names. This is what a harness
# looks like from inside a container, where it is pid 1 of its own namespace.
namespace_ancestry_bin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
pid=
prev=
for a in "$@"; do
  [ "$prev" = -p ] && pid=$a
  prev=$a
done
if [ "$pid" = 1 ]; then
  comm=${FM_TEST_PID1_COMM:-init}
  ppid=0
else
  comm=bash
  ppid=1
fi
case "$*" in
  *'ppid='*) printf '%s\n' "$ppid" ;;
  *) printf '%s\n' "$comm" ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

# On Linux the kernel name of a host started with `exec -a fm-deck-chat bash`
# is still `bash`; only argv[0] carries the host name, which is how
# bin/fm-deck-chat.sh and fm-deck-worker launches really look there.
test_deck_ancestry_is_detected() {
  local name got
  for name in deck fm-deck-worker fm-deck-chat; do
    got=$(under_named "$name" "$HARNESS")
    [ "$got" = deck ] || fail "a session under a process named $name resolved '$got', expected deck"
  done
  pass "a deck, fm-deck-worker, or fm-deck-chat ancestor is detected as deck"
}

test_removed_harnesses_and_markers_read_unknown() {
  local dir name got fakebin baseline
  dir="$TMP_ROOT/removed"
  # A removed harness in the chain adds nothing, so the verdict under it is the
  # verdict this suite already gets from its own ancestry (unknown in CI, deck
  # when a Deck session happens to run the suite).
  baseline=$("$HARNESS")
  for name in pi pi-signed claude codex opencode grok omp; do
    got=$(under_named "$name" "$HARNESS" CLAUDECODE=1 PI_CODING_AGENT=true FM_PI_HARNESS=pi-signed GROK_AGENT=1 CURSOR_AGENT=1)
    [ "$got" = "$baseline" ] || fail "a session under a removed harness named $name resolved '$got', expected '$baseline'"
  done
  fakebin=$(blind_ancestry_bin "$dir/blind")
  got=$(env CLAUDECODE=1 PI_CODING_AGENT=true GROK_AGENT=1 PATH="$fakebin:$BASE_PATH" "$HARNESS")
  [ "$got" = unknown ] || fail "a removed harness marker with no Deck ancestor resolved '$got', expected unknown"
  pass "removed harness processes and markers never produce a verdict"
}

test_deck_at_namespace_pid1_is_examined() {
  local fakebin got
  fakebin=$(namespace_ancestry_bin "$TMP_ROOT/namespace-pid1")
  # Non-vacuity: a host-shaped pid 1 must not match, so the case below cannot
  # pass by the walk matching everything.
  got=$(env FM_TEST_PID1_COMM=init PATH="$fakebin:$BASE_PATH" "$HARNESS")
  [ "$got" = unknown ] || fail "a host-shaped pid 1 resolved '$got', expected unknown"
  got=$(env FM_TEST_PID1_COMM=deck PATH="$fakebin:$BASE_PATH" "$HARNESS")
  [ "$got" = deck ] || fail "a Deck session at namespace pid 1 resolved '$got', expected deck"
  got=$(env FM_TEST_PID1_COMM=deck PATH="$fakebin:$BASE_PATH" "$HARNESS" ancestry)
  [ "$got" = "comm deck" ] || fail "the namespace pid 1 harness must be reported by ancestry, got '$got'"
  pass "a harness that is pid 1 of its own namespace is examined, not skipped"
}

test_supervision_protocol_follows_the_verdict() {
  local dir home fakebin got
  dir="$TMP_ROOT/supervision"
  home="$dir/home"
  mkdir -p "$home/state" "$home/config"
  fakebin=$(blind_ancestry_bin "$dir/blind")
  got=$(env CLAUDECODE=1 PI_CODING_AGENT=true FM_HOME="$home" PATH="$fakebin:$BASE_PATH" "$RENDER")
  assert_contains "$got" "primary harness: unknown" \
    "with no Deck ancestor, a removed harness marker must render the unknown protocol"

  got=$(under_named fm-deck-chat "$RENDER" CLAUDECODE=1 FM_HOME="$home")
  assert_contains "$got" "primary harness: deck" \
    "a deck chat primary carrying a retained CLAUDECODE did not render the deck protocol"
  assert_contains "$got" "Mode: Deck home-host-owned wake input." \
    "the rendered block is not Deck's host-owned protocol"
  pass "session start renders the deck protocol for a deck primary and unknown otherwise"
}

test_deck_ancestry_is_detected
test_removed_harnesses_and_markers_read_unknown
test_deck_at_namespace_pid1_is_examined
test_supervision_protocol_follows_the_verdict
