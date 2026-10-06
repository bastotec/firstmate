#!/usr/bin/env bash
# tests/fm-afk-launch.test.sh - the script-owned away-daemon launch
# (bin/fm-afk-launch.sh) and the away-mode stale-artifact lifecycle fixes
# (bin/fm-afk-start.sh):
#
#   UNIT: the session-scoped stale-artifact clear on a fresh entry vs a
#   refresh, the correct-ordered stop (daemon SIGTERM'd while state/.afk is
#   still present, .afk cleared last), and the daemon-record lifecycle.
#
#   STREAM: the daemon runs as a detached session leader recorded by pid, and a
#   real daemon on a stream primary owns supervision and flushes through the
#   steer client. A harmless sleeper replaces the real daemon
#   (FM_AFK_LAUNCH_ENTRY) where a case observes only the lifecycle.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAUNCH="$ROOT/bin/fm-afk-launch.sh"
START="$ROOT/bin/fm-afk-start.sh"
CONTRACT="$ROOT/bin/fm-afk-contract.sh"
# A run from inside a stream endpoint would otherwise select the stream backend.
unset FM_STREAM_ENDPOINT_ID
FAKE_STEER="$ROOT/tests/assets/fake-primary-steer.sh"

FAILED=0
fail() { printf 'not ok - %s\n' "$1" >&2; FAILED=1; }
pass() { printf 'ok - %s\n' "$1"; }

SLEEPER=$(mktemp "${TMPDIR:-/tmp}/fm-afk-sleeper.XXXXXX")
# A direct interpreter path and no exec keep the sleeper's argv - and so the
# process identity the launcher records - stable from its first read.
printf '#!/bin/bash\nwhile :; do sleep 1; done\n' > "$SLEEPER"
chmod +x "$SLEEPER"
GLOBAL_CLEANUP() {
  rm -f "$SLEEPER" 2>/dev/null || true
}
trap GLOBAL_CLEANUP EXIT

confirm_posture() {  # <home>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$CONTRACT" propose >/dev/null 2>&1 \
    && FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$CONTRACT" confirm >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# UNIT 0: the away-posture record is the entry. `propose` reads the mandate
# back, `confirm` records it and announces hold-for-return; on Pi the entry
# ends there, and every daemon path requires that confirmed record.
# ---------------------------------------------------------------------------
unit_propose_confirm_records_the_posture_without_a_daemon() {
  local st out rc
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-propose.XXXXXX")
  mkdir -p "$st/state"
  out=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" propose \
    --words 'merge the windows fix when green' --action merge --object 'task fix-windows PR' --when 'checks green' \
    --action merge --object regardless 2>&1)
  rc=$?
  if [ "$rc" -eq 3 ] && [ -f "$st/state/.afk-contract.proposed" ] \
    && printf '%s' "$out" | grep -F '1. merge task fix-windows PR when checks green' >/dev/null \
    && printf '%s' "$out" | grep -F '2. "action=merge object=regardless when=(none)" - refused: missing when' >/dev/null \
    && [ ! -e "$st/state/.afk-contract" ]; then
    pass "propose: the read-back lists accepted and refused clauses and writes only a proposal"
  else
    fail "propose: read-back or proposal wrong (rc=$rc): $out"
  fi
  out=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" confirm 2>&1)
  rc=$?
  if [ "$rc" -eq 0 ] && [ -f "$st/state/.afk-contract" ] && [ ! -e "$st/state/.afk-contract.proposed" ] \
    && [ ! -e "$st/state/.afk" ] && [ ! -e "$st/state/.afk-daemon-terminal" ] \
    && printf '%s' "$out" | grep -F 'hold-for-return only. No phone channel is configured; anything that needs you waits for your return.' >/dev/null; then
    pass "confirm: records the posture, announces hold-for-return only, and launches no daemon"
  else
    fail "confirm: record, announcement, or daemon state wrong (rc=$rc): $out"
  fi
  printf 'schema\tfm-afk-return.v1\nphase\tblocked\n' > "$st/state/.afk-return-catchup"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" propose --action merge --object 'task a PR' --when 'checks green' >/dev/null 2>&1; then
    fail "propose: accepted a new mandate while the prior return catch-up was pending"
  else
    pass "propose: refuses while the prior return catch-up is pending"
  fi
  rm -rf "$st"
}

unit_daemon_entry_requires_confirmation() {
  local st out rc
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-entry-record.XXXXXX")
  mkdir -p "$st/state"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$CONTRACT" propose --action merge --object 'task a PR' --when 'checks green' >/dev/null 2>&1
  out=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" start-native 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ] && [ -f "$st/state/.afk-contract.proposed" ] && [ ! -e "$st/state/.afk-contract" ] \
    && [ ! -e "$st/state/.afk" ] && printf '%s' "$out" | grep -F 'a confirmed away-posture record is required' >/dev/null; then
    pass "daemon entry: a pending proposal cannot bypass captain confirmation"
  else
    fail "daemon entry: pending proposal was promoted or refusal was unclear (rc=$rc): $out"
  fi
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$CONTRACT" confirm >/dev/null 2>&1
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" start-native >/dev/null 2>&1 \
    && [ -e "$st/state/.afk" ]; then
    pass "daemon entry: an explicitly confirmed record permits lifecycle preparation"
  else
    fail "daemon entry: rejected an explicitly confirmed record"
  fi
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1
  rm -rf "$st"
}

unit_failed_daemon_launch_preserves_confirmed_record() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-failed-record.XXXXXX")
  mkdir -p "$st/state"
  confirm_posture "$st" || fail "failed start: could not confirm fixture posture"
  if ! FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_TARGET=unused \
    FM_SUPERVISOR_BACKEND=unsupported "$LAUNCH" start >/dev/null 2>&1 \
    && [ -f "$st/state/.afk-contract" ] && [ ! -e "$st/state/afk-contracts" ]; then
    pass "failed start: preserves the pre-confirmed posture record"
  else
    fail "failed start: changed the pre-confirmed posture record"
  fi
  rm -rf "$st"
}

unit_stop_archives_the_record_last() {
  local st epoch
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop-archive.XXXXXX")
  mkdir -p "$st/state"
  confirm_posture "$st" || fail "stop archive: could not confirm fixture posture"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" start-native >/dev/null 2>&1 || fail "stop archive: native entry failed"
  epoch=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$CONTRACT" field entered_epoch)
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1 \
    && [ ! -e "$st/state/.afk" ] && [ ! -e "$st/state/.afk-contract" ] \
    && [ -f "$st/state/afk-contracts/$epoch.afk-contract" ]; then
    pass "stop: clears the away flag and archives the posture record under its entry time"
  else
    fail "stop: the posture record was not archived (state: $(ls -a "$st/state"))"
  fi
  rm -rf "$st"
}

# ---------------------------------------------------------------------------
# UNIT 1: fm_afk_clear_stale_artifacts removes exactly the three stale artifacts.
# ---------------------------------------------------------------------------
unit_clear_stale() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-clear.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.subsuper-escalations"
  : > "$st/state/.subsuper-escalations.since"
  : > "$st/state/.subsuper-inject-wedged"
  : > "$st/state/.wake-queue"          # durable queue must be untouched
  # Source fm-afk-start.sh inside a child bash (it sets `set -eu` and would
  # otherwise leak that into this test shell) and call the clear helper.
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
    bash -c '. "$1"; fm_afk_clear_stale_artifacts "$2"' _ "$START" "$st/state"
  if [ ! -e "$st/state/.subsuper-escalations" ] \
     && [ ! -e "$st/state/.subsuper-escalations.since" ] \
     && [ ! -e "$st/state/.subsuper-inject-wedged" ]; then
    pass "clear-stale: removes escalations buffer, sidecar, and wedge marker"
  else
    fail "clear-stale: stale artifacts survived"
  fi
  if [ -e "$st/state/.wake-queue" ]; then
    pass "clear-stale: leaves the durable wake-queue intact (no pending work dropped)"
  else
    fail "clear-stale: removed the durable wake-queue"
  fi
  rm -rf "$st"
}

unit_relative_paths_are_absolute_before_daemon_launch() {
  local root home state out status linked_home
  root=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-relative-home.XXXXXX")
  mkdir -p "$root/home/state" "$root/cdpath/home/state"
  home=$(cd "$root/home" && pwd -P)
  state="$home/state"
  out=$(
    cd "$root" || exit 1
    CDPATH="$root/cdpath" FM_HOME=home FM_STATE_OVERRIDE=home/state \
      bash -c '. "$1"; printf "%s\n%s\n" "$FM_HOME" "$FM_AFK_LAUNCH_STATE"' _ "$LAUNCH"
  )
  if [ "$out" = "$home"$'\n'"$state" ]; then
    pass "launcher paths: relative home and state ignore CDPATH before daemon command construction"
  else
    fail "launcher paths: relative home or state remained cwd-dependent ($out)"
  fi
  linked_home="$root/home-link"
  ln -s "$root/home" "$linked_home"
  out=$(FM_HOME="$linked_home" FM_STATE_OVERRIDE="$linked_home/state" \
    bash -c '. "$1"; printf "%s\n%s\n" "$FM_HOME" "$FM_AFK_LAUNCH_STATE"' _ "$LAUNCH")
  if [ "$out" = "$linked_home"$'\n'"$linked_home/state" ]; then
    pass "launcher paths: absolute symlink spellings are preserved"
  else
    fail "launcher paths: absolute symlink spelling changed ($out)"
  fi
  out=$(
    cd "$root" || exit 1
    FM_HOME=missing-home "$LAUNCH" help 2>&1
  )
  status=$?
  if [ "$status" -ne 0 ] && printf '%s\n' "$out" | grep -F "FM_HOME directory cannot be resolved: missing-home" >/dev/null; then
    pass "launcher paths: unresolved relative FM_HOME fails loudly"
  else
    fail "launcher paths: unresolved relative FM_HOME did not name the bad input ($out)"
  fi
  out=$(
    cd "$root" || exit 1
    FM_HOME=home FM_STATE_OVERRIDE=missing-state "$LAUNCH" help 2>&1
  )
  status=$?
  if [ "$status" -ne 0 ] && printf '%s\n' "$out" | grep -F "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" >/dev/null; then
    pass "launcher paths: unresolved relative FM_STATE_OVERRIDE fails loudly"
  else
    fail "launcher paths: unresolved relative FM_STATE_OVERRIDE did not name the bad input ($out)"
  fi
  rm -rf "$root"
}

# ---------------------------------------------------------------------------
# UNIT 2: a FRESH entry clears; a REFRESH (daemon already alive) preserves the
# current session's buffered escalations.
# ---------------------------------------------------------------------------
unit_fresh_vs_refresh() {
  local st sleep_pid lock
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-refresh.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.subsuper-escalations"
  : > "$st/state/.subsuper-inject-wedged"
  # A live "daemon": a real process whose identity the lock records, so
  # daemon_lock_held_by_live_daemon returns true (a refresh).
  sleep 600 &
  sleep_pid=$!
  lock="$st/state/.supervise-daemon.lock"
  mkdir -p "$lock"
  printf '%s' "$sleep_pid" > "$lock/pid"
  # shellcheck source=/dev/null
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$sleep_pid" > "$lock/pid-identity" 2>/dev/null ) || true
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$START" >/dev/null 2>&1
  if [ -e "$st/state/.subsuper-escalations" ] && [ -e "$st/state/.subsuper-inject-wedged" ]; then
    pass "refresh: daemon already alive - stale artifacts preserved (current session's buffer kept)"
  else
    fail "refresh: incorrectly cleared the current session's buffered escalations"
  fi
  kill "$sleep_pid" 2>/dev/null || true
  wait "$sleep_pid" 2>/dev/null || true
  rm -rf "$st"
}

# ---------------------------------------------------------------------------
# UNIT 2a: away/quiet mode plumbing (kunchenguid/firstmate#2356). fm_afk_mode
# is the single owner of reading the mode; these pin its write side
# (fm_afk_launch_flag_write / fm_afk_flag_write) against the exact double-
# write risk a live entry hits - the launcher writes the flag, then the
# terminal-side fm-afk-start.sh entry re-writes it a second time on every
# real (non-native) entry, per UNIT 2 above.
# ---------------------------------------------------------------------------
read_mode() {  # <state-dir>
  bash -c '. "$1"; fm_afk_mode "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$1"
}

unit_mode_explicit_write() {
  local st out
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-mode-explicit.XXXXXX")
  mkdir -p "$st/state"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_AFK_MODE=quiet \
    bash -c '. "$1"; fm_afk_launch_flag_write' _ "$LAUNCH"
  out=$(read_mode "$st/state")
  if [ "$out" = quiet ]; then
    pass "mode: a fresh entry with FM_AFK_MODE=quiet writes quiet"
  else
    fail "mode: explicit FM_AFK_MODE=quiet fresh entry wrote '$out' instead of quiet"
  fi
  rm -rf "$st"
}

unit_mode_fresh_defaults_away() {
  local st out
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-mode-default.XXXXXX")
  mkdir -p "$st/state"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" \
    bash -c '. "$1"; fm_afk_launch_flag_write' _ "$LAUNCH"
  out=$(read_mode "$st/state")
  if [ "$out" = away ]; then
    pass "mode: a fresh entry with FM_AFK_MODE unset defaults to away"
  else
    fail "mode: fresh unset-mode entry wrote '$out' instead of away"
  fi
  rm -rf "$st"
}

unit_mode_refresh_preserves_quiet() {
  local st sleep_pid lock out
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-mode-preserve.XXXXXX")
  mkdir -p "$st/state"
  printf 'quiet\n%s\n' "$(date '+%s')" > "$st/state/.afk"
  sleep 600 &
  sleep_pid=$!
  lock="$st/state/.supervise-daemon.lock"
  mkdir -p "$lock"
  printf '%s' "$sleep_pid" > "$lock/pid"
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$sleep_pid" > "$lock/pid-identity" 2>/dev/null ) || true
  # The exact real-entry shape: a bare direct re-write with no explicit mode,
  # simulating the terminal-side fm-afk-start.sh redundant write that would
  # silently clobber quiet back to away if it were not preserve-on-refresh.
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$START" >/dev/null 2>&1
  out=$(read_mode "$st/state")
  if [ "$out" = quiet ]; then
    pass "mode: a bare refresh (FM_AFK_MODE unset) of an already-running quiet daemon preserves quiet, never resets to away"
  else
    fail "mode: refresh incorrectly changed quiet mode to '$out'"
  fi
  kill "$sleep_pid" 2>/dev/null || true
  wait "$sleep_pid" 2>/dev/null || true
  rm -rf "$st"
}

unit_mode_garbage_and_legacy_content_reads_away() {
  local st out
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-mode-garbage.XXXXXX")
  mkdir -p "$st/state"

  : > "$st/state/.afk"
  out=$(read_mode "$st/state")
  if [ "$out" = away ]; then
    pass "mode: an empty (legacy pre-mode) flag reads as away"
  else
    fail "mode: empty flag read as '$out' instead of away"
  fi

  date '+%s' > "$st/state/.afk"
  out=$(read_mode "$st/state")
  if [ "$out" = away ]; then
    pass "mode: a bare-epoch-timestamp (legacy pre-mode) flag reads as away"
  else
    fail "mode: legacy timestamp flag read as '$out' instead of away"
  fi

  printf 'nonsense-mode\n' > "$st/state/.afk"
  out=$(read_mode "$st/state")
  if [ "$out" = away ]; then
    pass "mode: unrecognized content falls back to away"
  else
    fail "mode: unrecognized content read as '$out' instead of away"
  fi

  out=$(read_mode "$st/state/missing")
  if [ "$out" = away ]; then
    pass "mode: a missing flag reads as away"
  else
    fail "mode: missing flag read as '$out' instead of away"
  fi
  rm -rf "$st"
}

# ---------------------------------------------------------------------------
# UNIT 3: exit ordering - fm_afk_launch_stop SIGTERMs the daemon WHILE .afk is
# still present (so its flush is not a no-op), and clears .afk last.
# ---------------------------------------------------------------------------
unit_stop_ordering() {
  local st lock marker daemon_pid
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop.XXXXXX")
  mkdir -p "$st/state"
  date '+%s' > "$st/state/.afk"
  marker="$st/afk-at-term"
  # A fake daemon: on SIGTERM, record whether .afk was still present, then exit.
  bash -c '
    trap "if [ -f \"$1/state/.afk\" ]; then echo present > \"$2\"; else echo absent > \"$2\"; fi; exit 0" TERM
    while :; do sleep 0.2; done
  ' _ "$st" "$marker" &
  # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
  daemon_pid=$!
  lock="$st/state/.supervise-daemon.lock"
  mkdir -p "$lock"
  printf '%s' "$daemon_pid" > "$lock/pid"
  # shellcheck source=/dev/null
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$daemon_pid" > "$lock/pid-identity" 2>/dev/null ) || true
  printf 'none\t-\tnative\n' > "$st/state/.afk-daemon-terminal"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1
  # shellcheck disable=SC2031 # The background daemon writes this shared file; no shell variable is reassigned.
  if [ "$(cat "$marker" 2>/dev/null || echo missing)" = present ]; then
    pass "stop-ordering: daemon SIGTERM'd while .afk still present (flush is not a no-op)"
  else
    fail "stop-ordering: .afk was already cleared when the daemon got SIGTERM"
  fi
  if [ ! -e "$st/state/.afk" ]; then
    pass "stop-ordering: .afk cleared last"
  else
    fail "stop-ordering: .afk not cleared"
  fi
  if [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "stop-ordering: daemon-terminal record removed"
  else
    fail "stop-ordering: record not removed"
  fi
  kill "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  rm -rf "$st"
}

unit_stop_rejects_reused_pid() {
  local st lock sleeper_pid
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-pid-reuse.XXXXXX")
  mkdir -p "$st/state"
  date '+%s' > "$st/state/.afk"
  sleep 600 &
  # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
  sleeper_pid=$!
  lock="$st/state/.supervise-daemon.lock"
  mkdir -p "$lock"
  printf '%s' "$sleeper_pid" > "$lock/pid"
  printf 'different-process-identity' > "$lock/pid-identity"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1
  if kill -0 "$sleeper_pid" 2>/dev/null; then
    pass "stop identity: stale lock cannot signal an unrelated live process"
  else
    fail "stop identity: stale lock signaled an unrelated live process"
  fi
  kill "$sleeper_pid" 2>/dev/null || true
  wait "$sleeper_pid" 2>/dev/null || true
  rm -rf "$st"
}

unit_failed_start_rolls_back_state() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-failed-start.XXXXXX")
  mkdir -p "$st/state"
  printf 'pending\n' > "$st/state/.subsuper-escalations"
  printf 'wedged\n' > "$st/state/.subsuper-inject-wedged"
  confirm_posture "$st" || fail "failed start: could not confirm fixture posture"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_TARGET=unused \
    FM_SUPERVISOR_BACKEND=unsupported "$LAUNCH" start >/dev/null 2>&1; then
    fail "failed start: unsupported backend unexpectedly succeeded"
  elif [ ! -e "$st/state/.afk" ] \
    && [ "$(cat "$st/state/.subsuper-escalations")" = pending ] \
    && [ "$(cat "$st/state/.subsuper-inject-wedged")" = wedged ]; then
    pass "failed start: away flag and delivery artifacts roll back"
  else
    fail "failed start: left false away state or discarded delivery artifacts"
  fi
  rm -rf "$st"
}

unit_concurrent_start_serialized() {
  local st first second pid sleeper live
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-concurrent.XXXXXX")
  mkdir -p "$st/state"
  # A sleeper unique to this case, so its live copies can be counted. A direct
  # interpreter path keeps its argv stable from the first identity read, which
  # an env shebang would change once env execs bash.
  sleeper="$st/concurrent-sleeper"
  printf '#!/bin/bash\nwhile :; do sleep 1; done\n' > "$sleeper"
  chmod +x "$sleeper"
  confirm_posture "$st" || fail "concurrent start: could not confirm fixture posture"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_TARGET=hub-7717:0123abcd \
    FM_SUPERVISOR_BACKEND=stream FM_AFK_LAUNCH_ENTRY="$sleeper" "$LAUNCH" start >/dev/null 2>&1 &
  # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
  first=$!
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_TARGET=hub-7717:0123abcd \
    FM_SUPERVISOR_BACKEND=stream FM_AFK_LAUNCH_ENTRY="$sleeper" "$LAUNCH" start >/dev/null 2>&1 &
  # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
  second=$!
  wait "$first"; wait "$second"
  pid=$(cut -f2 "$st/state/.afk-daemon-terminal" 2>/dev/null || true)
  live=$(ps -eo pid=,args= | awk -v s="$sleeper" 'index($0, s) && !index($0, "awk") {n++} END {print n+0}')
  if [ "$(cut -f1 "$st/state/.afk-daemon-terminal" 2>/dev/null)" = process ] \
    && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ "$live" -eq 1 ]; then
    pass "concurrent start: one serialized daemon process remains tracked"
  else
    fail "concurrent start: leaked or lost daemon process (live $live, record pid $pid)"
  fi
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1
  ps -eo pid=,args= | awk -v s="$sleeper" 'index($0, s) && !index($0, "awk") {print $1}' \
    | while read -r pid; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$st"
}

unit_lock_initialization_grace() {
  local st marker initializer
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-lock-init.XXXXXX")
  marker="$st/initialized"
  mkdir -p "$st/state/.afk-launch.lock"
  (
    sleep 0.15
    if [ -d "$st/state/.afk-launch.lock" ]; then
      printf '%s' "$$" > "$st/state/.afk-launch.lock/pid"
      # shellcheck source=/dev/null
      ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$$" > "$st/state/.afk-launch.lock/pid-identity" 2>/dev/null ) || true
      # shellcheck disable=SC2031 # The subshell writes the path value; it does not reassign the variable.
      : > "$marker"
      sleep 0.15
      rm -rf "$st/state/.afk-launch.lock"
    fi
  ) &
  # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
  initializer=$!
  # shellcheck disable=SC2031 # The initializer communicates through this shared file path.
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_lock_acquire
    fm_afk_launch_lock_release
  ' _ "$LAUNCH" && [ -e "$marker" ]; then
    pass "launcher lock: incomplete publication receives initialization grace"
  else
    fail "launcher lock: contender removed a lock during initialization"
  fi
  wait "$initializer" 2>/dev/null || true
  rm -rf "$st"
}

unit_signal_exits_with_lock_cleanup() {
  local st marker child
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-signal.XXXXXX")
  marker="$st/resumed"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_start() { sleep 30; }
    fm_afk_launch_main start
    : > "$2"
  ' _ "$LAUNCH" "$marker" &
  # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
  child=$!
  # Signal only once the lifecycle actually holds its lock. Killing before the
  # lock exists tests nothing, and on a loaded machine it used to race: the
  # lock could be created just after the kill and outlive the process.
  local locked=0 _
  for _ in $(seq 1 100); do
    if [ -d "$st/state/.afk-launch.lock" ]; then locked=1; break; fi
    sleep 0.05
  done
  [ "$locked" = 1 ] || fail "launcher signal: lifecycle never acquired its lock to interrupt"
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  # The signal handler releases the lock as it exits; give that removal a
  # bounded settle rather than sampling the instant `wait` returns.
  for _ in $(seq 1 100); do
    [ -e "$st/state/.afk-launch.lock" ] || break
    sleep 0.05
  done
  if [ ! -e "$marker" ] && [ ! -e "$st/state/.afk-launch.lock" ]; then
    pass "launcher signal: TERM exits and releases the lifecycle lock"
  else
    fail "launcher signal: interrupted lifecycle resumed or retained its lock"
  fi
  rm -rf "$st"
}

unit_record_failure_closes_terminal() {
  local st closed
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-record-fail.XXXXXX")
  closed="$st/closed"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" CLOSED="$closed" bash -c '
    . "$1"
    fm_afk_launch_record_write() { return 1; }
    fm_afk_launch_close_terminal() { printf "%s:%s" "$1" "$2" > "$CLOSED"; }
    ! fm_afk_launch_commit_terminal process 999999 identity
  ' _ "$LAUNCH"
  if [ "$(cat "$closed" 2>/dev/null || true)" = "process:999999" ]; then
    pass "record failure: newly created terminal is closed by exact id"
  else
    fail "record failure: newly created terminal leaked"
  fi
  rm -rf "$st"
}

unit_readiness_failure_rolls_back_terminal() {
  local st closed
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-not-ready.XXXXXX")
  closed="$st/closed"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" CLOSED="$closed" bash -c '
    . "$1"
    fm_afk_launch_wait_ready() { return 1; }
    fm_afk_launch_close_terminal() { printf "%s:%s" "$1" "$2" > "$CLOSED"; }
    fm_afk_launch_terminal_absent() { [ -e "$CLOSED" ]; }
    ! fm_afk_launch_commit_terminal process 999999 identity
  ' _ "$LAUNCH"
  if [ "$(cat "$closed" 2>/dev/null || true)" = "process:999999" ] \
    && [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "readiness failure: exact terminal and durable record roll back"
  else
    fail "readiness failure: terminal or record survived"
  fi
  rm -rf "$st"
}

unit_readiness_failure_preserves_unconfirmed_record() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-not-ready-unconfirmed.XXXXXX")
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_wait_ready() { return 1; }
    fm_afk_launch_close_terminal() { return 1; }
    fm_afk_launch_terminal_absent() { return 1; }
    ! fm_afk_launch_commit_terminal process 999999 identity
  ' _ "$LAUNCH"
  if [ "$(cut -f2 "$st/state/.afk-daemon-terminal" 2>/dev/null || true)" = 999999 ]; then
    pass "readiness failure: unconfirmed terminal retains its reconciliation id"
  else
    fail "readiness failure: unconfirmed terminal lost its reconciliation id"
  fi
  rm -rf "$st"
}

unit_native_lifecycle() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-native.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.subsuper-escalations"
  confirm_posture "$st" || fail "native lifecycle: could not confirm fixture posture"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" start-native >/dev/null 2>&1 \
    && [ "$(cut -f1 "$st/state/.afk-daemon-terminal")" = none ] \
    && [ -e "$st/state/.afk" ] \
    && [ ! -e "$st/state/.subsuper-escalations" ]; then
    pass "native lifecycle: launcher owns state with no terminal"
  else
    fail "native lifecycle: state preparation or no-terminal record failed"
  fi
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1
  if [ ! -e "$st/state/.afk" ] && [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "native lifecycle: uniform stop clears state without closing a terminal"
  else
    fail "native lifecycle: uniform stop retained state"
  fi
  rm -rf "$st"
}

unit_native_entry_preserves_prepared_state() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-native-entry.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.afk"
  : > "$st/state/.subsuper-escalations"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_AFK_STATE_PREPARED=1 bash -c '
    . "$1"
    FM_AFK_DAEMON=/bin/true
    fm_afk_start_main
  ' _ "$START" >/dev/null 2>&1
  if [ -e "$st/state/.afk" ] && [ -e "$st/state/.subsuper-escalations" ]; then
    pass "native entry: launcher-prepared lifecycle state is not rewritten"
  else
    fail "native entry: launcher-prepared lifecycle state was mutated"
  fi
  rm -rf "$st"
}

unit_close_failure_preserves_record() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-close-fail.XXXXXX")
  mkdir -p "$st/state"
  printf 'process\t999999\towned\n' > "$st/state/.afk-daemon-terminal"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_close_terminal() { return 1; }
    fm_afk_launch_terminal_absent() { return 1; }
    ! fm_afk_launch_reconcile
  ' _ "$LAUNCH"
  if [ -e "$st/state/.afk-daemon-terminal" ]; then
    pass "teardown failure: exact terminal record is preserved"
  else
    fail "teardown failure: exact terminal record was discarded"
  fi
  rm -rf "$st"
}

unit_record_publication_atomic() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-record-atomic.XXXXXX")
  mkdir -p "$st/state"
  printf 'process\t999998\towned\n' > "$st/state/.afk-daemon-terminal"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    mv() { return 1; }
    ! fm_afk_launch_record_write process 999997 owned
  ' _ "$LAUNCH" \
    && [ "$(cat "$st/state/.afk-daemon-terminal")" = $'process\t999998\towned' ] \
    && ! find "$st/state" -name '.afk-daemon-terminal.pending.*' -print -quit | grep -q .; then
    pass "record publication: failed atomic rename preserves the complete prior record"
  else
    fail "record publication: failed write truncated or replaced the prior record"
  fi
  rm -rf "$st"
}

unit_malformed_record_fails_closed() {
  local st acted
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-record-malformed.XXXXXX")
  mkdir -p "$st/state"
  printf 'process\tonly-two-fields\n' > "$st/state/.afk-daemon-terminal"
  acted="$st/acted"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" ACTED="$acted" bash -c '
    . "$1"
    fm_afk_launch_close_terminal() { : > "$ACTED"; }
    ! fm_afk_launch_reconcile
  ' _ "$LAUNCH" \
    && [ ! -e "$acted" ] && [ -e "$st/state/.afk-daemon-terminal" ]; then
    pass "record read: malformed record fails closed without acting on a partial id"
  else
    fail "record read: malformed record was acted on or discarded"
  fi
  rm -rf "$st"
}

unit_retired_backend_record_fails_closed() {
  local st backend out
  for backend in tmux herdr; do
    st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-retired.XXXXXX")
    mkdir -p "$st/state"
    : > "$st/state/.afk"
    printf '%s\tleftover\tdaemon\n' "$backend" > "$st/state/.afk-daemon-terminal"
    out=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop 2>&1)
    if [ -e "$st/state/.afk" ] && [ -e "$st/state/.afk-daemon-terminal" ] \
      && printf '%s' "$out" | grep -F "retired '$backend' backend" >/dev/null; then
      pass "retired record: a $backend daemon record is refused with a by-hand instruction"
    else
      fail "retired record: a $backend daemon record was acted on or not explained: $out"
    fi
    rm -rf "$st"
  done
}

unit_stop_malformed_record_fails_closed() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop-malformed.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.afk"
  printf 'process\tonly-two-fields\n' > "$st/state/.afk-daemon-terminal"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    ! fm_afk_launch_stop
  ' _ "$LAUNCH" && [ -e "$st/state/.afk" ] && [ -e "$st/state/.afk-daemon-terminal" ]; then
    pass "stop: malformed terminal record preserves away state and fails closed"
  else
    fail "stop: malformed terminal record cleared protected lifecycle state"
  fi
  rm -rf "$st"
}

unit_stop_validates_before_signal() {
  local st sleeper_pid
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop-validate.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.afk"
  printf 'process\tonly-two-fields\n' > "$st/state/.afk-daemon-terminal"
  sleep 30 &
  # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
  sleeper_pid=$!
  mkdir -p "$st/state/.supervise-daemon.lock"
  printf '%s' "$sleeper_pid" > "$st/state/.supervise-daemon.lock/pid"
  # shellcheck source=/dev/null
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$sleeper_pid" > "$st/state/.supervise-daemon.lock/pid-identity" )
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1 || true
  if kill -0 "$sleeper_pid" 2>/dev/null && [ -e "$st/state/.afk" ]; then
    pass "stop validation: malformed record causes no daemon or state side effects"
  else
    fail "stop validation: malformed record signaled daemon or cleared state"
  fi
  kill "$sleeper_pid" 2>/dev/null || true
  wait "$sleeper_pid" 2>/dev/null || true
  rm -rf "$st"
}

unit_lock_requires_complete_metadata() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-lock-metadata.XXXXXX")
  mkdir -p "$st/state"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_pid_identity() { return 1; }
    ! fm_afk_launch_lock_acquire
  ' _ "$LAUNCH" && [ ! -e "$st/state/.afk-launch.lock" ]; then
    pass "launcher lock: incomplete metadata fails acquisition and releases lock"
  else
    fail "launcher lock: incomplete metadata was accepted"
  fi
  rm -rf "$st"
}

unit_stop_surfaces_afk_removal_failure() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop-remove.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.afk"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    rm() { local last=${!#}; [ "$last" != "$FM_AFK_LAUNCH_STATE/.afk" ]; }
    ! fm_afk_launch_stop
  ' _ "$LAUNCH"; then
    pass "stop state: away-flag removal failure is surfaced"
  else
    fail "stop state: away-flag removal failure reported success"
  fi
  rm -rf "$st"
}

unit_stop_confirms_daemon_exit() {
  local st daemon_pid
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stop-live.XXXXXX")
  mkdir -p "$st/state/.supervise-daemon.lock"
  : > "$st/state/.afk"
  printf 'none\t-\tnative\n' > "$st/state/.afk-daemon-terminal"
  bash -c 'trap "" TERM; while :; do sleep 1; done' &
  # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
  daemon_pid=$!
  printf '%s' "$daemon_pid" > "$st/state/.supervise-daemon.lock/pid"
  # shellcheck source=/dev/null
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$daemon_pid" > "$st/state/.supervise-daemon.lock/pid-identity" )
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    seq() { printf "1\n"; }
    sleep() { :; }
    kill() {
      command kill "$@"
      if [ "$1" = -TERM ]; then
        rm -rf "$FM_AFK_LAUNCH_STATE/.supervise-daemon.lock"
      fi
    }
    ! fm_afk_launch_stop
  ' _ "$LAUNCH" && kill -0 "$daemon_pid" 2>/dev/null \
    && [ ! -e "$st/state/.supervise-daemon.lock" ] \
    && [ -e "$st/state/.afk" ] && [ -e "$st/state/.afk-daemon-terminal" ]; then
    pass "stop liveness: captured live daemon preserves lifecycle state after lock release"
  else
    fail "stop liveness: lock release was mistaken for captured daemon exit"
  fi
  kill -KILL "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  rm -rf "$st"
}

unit_refresh_validates_record() {
  local st daemon_pid
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-refresh-record.XXXXXX")
  mkdir -p "$st/state/.supervise-daemon.lock"
  printf 'process\tonly-two-fields\n' > "$st/state/.afk-daemon-terminal"
  sleep 30 &
  # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
  daemon_pid=$!
  printf '%s' "$daemon_pid" > "$st/state/.supervise-daemon.lock/pid"
  # shellcheck source=/dev/null
  ( . "$ROOT/bin/fm-wake-lib.sh"; fm_pid_identity "$daemon_pid" > "$st/state/.supervise-daemon.lock/pid-identity" )
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_TARGET=unused \
    FM_SUPERVISOR_BACKEND=stream bash -c '
      . "$1"
      ! fm_afk_launch_start && ! fm_afk_launch_start_native
    ' _ "$LAUNCH" && [ ! -e "$st/state/.afk" ]; then
    pass "refresh record: malformed terminal identity fails closed"
  else
    fail "refresh record: malformed terminal identity was accepted"
  fi
  kill "$daemon_pid" 2>/dev/null || true
  wait "$daemon_pid" 2>/dev/null || true
  rm -rf "$st"
}

unit_clear_failure_aborts_entry() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-clear-fail.XXXXXX")
  mkdir -p "$st/state"
  : > "$st/state/.subsuper-escalations"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_reconcile() { return 0; }
    fm_afk_clear_stale_artifacts() { return 1; }
    ! fm_afk_launch_start_native
  ' _ "$LAUNCH" && [ ! -e "$st/state/.afk" ] && [ -e "$st/state/.subsuper-escalations" ]; then
    pass "clear failure: native entry aborts and restores prior state"
  else
    fail "clear failure: native entry proceeded or lost prior state"
  fi
  rm -rf "$st"
}

unit_confirmed_absence_succeeds() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-confirmed-absent.XXXXXX")
  mkdir -p "$st/state"
  printf 'process\t999999\towned\n' > "$st/state/.afk-daemon-terminal"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_close_terminal() { return 1; }
    fm_afk_launch_terminal_absent() { return 0; }
    fm_afk_launch_reconcile
  ' _ "$LAUNCH" && [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "confirmed absence: cleanup succeeds and removes the stale record"
  else
    fail "confirmed absence: close error incorrectly failed reconciliation"
  fi
  rm -rf "$st"
}

unit_incomplete_restore_retains_backup() {
  local st backup
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-restore-fail.XXXXXX")
  mkdir -p "$st/state"
  backup=$(mktemp -d "$st/state/.afk-launch-backup.XXXXXX")
  printf 'prior\n' > "$backup/.afk"
  if FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    cp() { return 1; }
    ! fm_afk_launch_restore_backup "$2" 1
  ' _ "$LAUNCH" "$backup" && [ -d "$backup" ] && [ -e "$backup/.afk" ]; then
    pass "rollback restore: incomplete restoration retains its recovery backup"
  else
    fail "rollback restore: incomplete restoration discarded its backup"
  fi
  rm -rf "$st"
}

unit_flag_write_failure_aborts() {
  local st
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-flag-fail.XXXXXX")
  mkdir -p "$st/state"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
    . "$1"
    fm_afk_launch_flag_write() { return 1; }
    ! fm_afk_launch_start_native
  ' _ "$LAUNCH"
  if [ ! -e "$st/state/.afk" ] && [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "flag failure: lifecycle aborts without active state"
  else
    fail "flag failure: lifecycle reported active state"
  fi
  rm -rf "$st"
}

# ---------------------------------------------------------------------------
# STREAM: a primary on a stream endpoint has no local pane, so the daemon runs
# as a detached process in its own session, recorded by pid.
# ---------------------------------------------------------------------------
unit_stream_detached_process_lifecycle() {
  local st pid rec
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stream.XXXXXX")
  mkdir -p "$st/state"
  confirm_posture "$st" || fail "stream lifecycle: could not confirm fixture posture"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_BACKEND=stream \
    FM_SUPERVISOR_TARGET=hub-7717:0123abcd FM_AFK_LAUNCH_ENTRY="$SLEEPER" \
    "$LAUNCH" start >/dev/null 2>&1
  rec=$(cat "$st/state/.afk-daemon-terminal" 2>/dev/null || true)
  pid=$(printf '%s' "$rec" | cut -f2)
  if [ "$(printf '%s' "$rec" | cut -f1)" = process ] && [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
    && [ "$(ps -o pgid= -p "$pid" | tr -d ' ')" = "$pid" ] && [ -e "$st/state/.afk" ]; then
    pass "stream lifecycle: start runs the entry as a detached session leader and records its pid"
  else
    fail "stream lifecycle: no detached process record (record='$rec')"
  fi
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1
  if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && [ ! -e "$st/state/.afk-daemon-terminal" ] \
    && [ ! -e "$st/state/.afk" ] && [ ! -e "$st/state/.afk-contract" ]; then
    pass "stream lifecycle: stop ends the recorded process by pid, clears .afk, and archives the posture"
  else
    fail "stream lifecycle: stop left the process or state behind (pid=$pid)"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  fi
  rm -rf "$st"
}

unit_stream_reused_pid_is_not_signalled() {
  local st other
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stream-reuse.XXXXXX")
  mkdir -p "$st/state"
  # A live pid that does not lead its own process group stands in for a reused one.
  sleep 600 &
  # shellcheck disable=SC2031 # $! is read right after this function's own background job
  other=$!
  printf 'process\t%s\t%s\n' "$other" "$st/state/.afk-daemon.out" > "$st/state/.afk-daemon-terminal"
  : > "$st/state/.afk"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1
  if kill -0 "$other" 2>/dev/null && [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "stream lifecycle: a recorded pid that no longer leads its group is never signalled"
  else
    fail "stream lifecycle: stop signalled a reused pid or kept the record"
  fi
  kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
  rm -rf "$st"
}

unit_stream_identity_mismatch_is_not_signalled() {
  local st other action
  for action in stop reconcile; do
    st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stream-identity.XXXXXX")
    mkdir -p "$st/state"
    confirm_posture "$st" || fail "stream identity: could not confirm fixture posture"
    FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_BACKEND=stream \
      FM_SUPERVISOR_TARGET=hub-7717:0123abcd FM_AFK_LAUNCH_ENTRY="$SLEEPER" \
      "$LAUNCH" start >/dev/null 2>&1
    other=$(cut -f2 "$st/state/.afk-daemon-terminal")
    FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
      . "$1"
      fm_afk_launch_record_read && fm_afk_launch_terminal_alive "$FM_AFK_REC_BACKEND" "$FM_AFK_REC_TARGET"
    ' _ "$LAUNCH" || fail "stream identity: matching live session leader was not alive"
    printf 'process\t%s\tstale process identity\n' "$other" > "$st/state/.afk-daemon-terminal"
    FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" bash -c '
      . "$1"
      fm_afk_launch_record_read || exit 1
      ! fm_afk_launch_terminal_alive "$FM_AFK_REC_BACKEND" "$FM_AFK_REC_TARGET" || exit 1
      fm_afk_launch_terminal_absent "$FM_AFK_REC_BACKEND" "$FM_AFK_REC_TARGET"
    ' _ "$LAUNCH" || fail "stream identity: mismatched live session leader did not read as gone"
    FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" "$action" >/dev/null 2>&1
    if kill -0 "$other" 2>/dev/null && [ ! -e "$st/state/.afk-daemon-terminal" ]; then
      pass "stream identity: $action never signals a live session leader with a mismatched identity"
    else
      fail "stream identity: $action signalled an unrelated session leader or kept its record"
    fi
    kill "$other" 2>/dev/null || true
    rm -rf "$st"
  done
}

e2e_stream_real_daemon() {
  local st steer pid out
  st=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-stream-e2e.XXXXXX")
  steer="$st/steer"
  mkdir -p "$st/state" "$steer"
  printf '{"session":"s1"}\n' > "$st/state/primary-chat.json"
  confirm_posture "$st" || fail "stream e2e: could not confirm fixture posture"
  out=$(FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" FM_SUPERVISOR_BACKEND=stream \
    FM_PRIMARY_STEER_BIN="$FAKE_STEER" FAKE_STEER_DIR="$steer" FM_ESCALATE_BATCH_SECS=99999 \
    FM_WEDGE_ALARM_EXEC=discard "$LAUNCH" start 2>&1)
  pid=$(cut -f2 "$st/state/.afk-daemon-terminal" 2>/dev/null || true)
  if bash -c '. "$1"; fm_afk_daemon_owns_supervision "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$st/state" \
    && [ "$(cat "$st/state/.supervise-daemon.lock/pid" 2>/dev/null)" = "$pid" ] \
    && grep -F 'backend=stream' "$st/state/.supervise-daemon.log" >/dev/null; then
    pass "stream e2e: the detached daemon starts on backend=stream and owns supervision"
  else
    fail "stream e2e: daemon not running or not supervising ($out; log: $(cat "$st/state/.supervise-daemon.log" 2>/dev/null))"
  fi
  # The deck-chat host pauses its own watcher while state/.afk exists; the
  # daemon's watcher child must then hold the home's watcher lock.
  local watch_pid='' tries=0
  while [ "$tries" -lt 100 ]; do
    watch_pid=$(cat "$st/state/.watch.lock/pid" 2>/dev/null || true)
    [ -n "$watch_pid" ] && break
    sleep 0.1
    tries=$((tries + 1))
  done
  if [ -n "$watch_pid" ] && [ "$(ps -o ppid= -p "$watch_pid" 2>/dev/null | tr -d ' ')" = "$pid" ]; then
    pass "stream e2e: the daemon's own watcher child holds the home's watcher lock"
  else
    fail "stream e2e: watcher lock not held by the daemon's child (lock pid='$watch_pid', daemon=$pid)"
  fi
  printf 'needs-decision: pick A\n' > "$st/state/.subsuper-escalations"
  date +%s > "$st/state/.subsuper-escalations.since"
  FM_HOME="$st" FM_STATE_OVERRIDE="$st/state" "$LAUNCH" stop >/dev/null 2>&1
  if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && grep -F 'pick A' "$steer/published/1.msg" >/dev/null 2>&1 \
    && [ ! -s "$st/state/.subsuper-escalations" ] && [ ! -e "$st/state/.afk" ] \
    && [ ! -e "$st/state/.afk-daemon-terminal" ]; then
    pass "stream e2e: stop flushes the buffer through the steer client before the daemon exits"
  else
    fail "stream e2e: stop did not flush via steer or left state (published: $(ls "$steer/published" 2>/dev/null); log: $(tail -5 "$st/state/.supervise-daemon.log" 2>/dev/null))"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  fi
  rm -rf "$st"
}

unit_clear_stale
unit_propose_confirm_records_the_posture_without_a_daemon
unit_daemon_entry_requires_confirmation
unit_failed_daemon_launch_preserves_confirmed_record
unit_stop_archives_the_record_last
unit_relative_paths_are_absolute_before_daemon_launch
unit_fresh_vs_refresh
unit_mode_explicit_write
unit_mode_fresh_defaults_away
unit_mode_refresh_preserves_quiet
unit_mode_garbage_and_legacy_content_reads_away
unit_stop_ordering
unit_stop_rejects_reused_pid
unit_failed_start_rolls_back_state
unit_concurrent_start_serialized
unit_lock_initialization_grace
unit_signal_exits_with_lock_cleanup
unit_record_failure_closes_terminal
unit_readiness_failure_rolls_back_terminal
unit_readiness_failure_preserves_unconfirmed_record
unit_native_lifecycle
unit_native_entry_preserves_prepared_state
unit_close_failure_preserves_record
unit_record_publication_atomic
unit_malformed_record_fails_closed
unit_retired_backend_record_fails_closed
unit_stop_malformed_record_fails_closed
unit_stop_validates_before_signal
unit_lock_requires_complete_metadata
unit_stop_surfaces_afk_removal_failure
unit_stop_confirms_daemon_exit
unit_refresh_validates_record
unit_clear_failure_aborts_entry
unit_confirmed_absence_succeeds
unit_incomplete_restore_retains_backup
unit_flag_write_failure_aborts
unit_stream_detached_process_lifecycle
unit_stream_reused_pid_is_not_signalled
unit_stream_identity_mismatch_is_not_signalled
e2e_stream_real_daemon

[ "$FAILED" -eq 0 ] || exit 1
