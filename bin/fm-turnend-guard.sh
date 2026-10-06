#!/usr/bin/env bash
# Turn-end guard for any firstmate PRIMARY session: the main home OR a
# secondmate's own home. A secondmate runs its own primary firstmate session and
# is guarded exactly like the main primary; only child crew/scout worktrees are
# exempt (see the scoping block below and docs/turnend-guard.md).
#
# fm-guard.sh (bin/fm-guard.sh) is pull-based: it only warns when some other
# supervision script happens to run. A primary session that ends a turn without
# resuming its harness supervision protocol, and then never runs another
# fleet-touching command itself, can sit blind for hours.
# This script is push-based: the Pi turn-end extension
# (.pi/extensions/fm-primary-turnend-guard.ts) invokes it every time the primary
# is about to end a turn and forces one bounded follow-up on exit 2, because
# Pi's turn-end event is passive. See docs/turnend-guard.md for the mechanics,
# validation evidence, and fail-open tradeoffs.
#
# Ships with the TRACKED .pi/extensions at the repo root, so this file is
# checked out into every worktree of this repo: the primary checkout, every
# secondmate home (treehouse-leased or git-cloned), and any crewmate/scout task
# worktree spawned to work on firstmate itself (the recursive "firstmate
# improving itself" case). A secondmate home runs its OWN primary firstmate
# session, so it must be guarded like the main primary; only child crew/scout
# worktrees are exempt. It must therefore scope itself at runtime to a real
# primary checkout - the main home or a genuinely marked secondmate home - and
# stay a silent, fast no-op inside child task worktrees.
#
# Away mode (state/.afk): the away-mode daemon owns supervision and runs the
# watcher one-shot, restarting it after every wake, so the watch lock is
# regularly unheld at a turn boundary with nothing wrong. A live
# identity-matched daemon holding this home, plus a fresh beacon, is what
# proves supervision there - see fm_afk_daemon_owns_supervision in
# bin/fm-wake-lib.sh. The beacon freshness test there uses AFK_GRACE
# (fm_poll_derived_grace, docs/turnend-guard.md "Guard grace and the poll
# cadence"), not the flat $GRACE every other check on this page uses: the
# daemon starts a fresh one-shot watcher only after it finishes handling the
# previous wake, and that handling can legitimately run past a flat 300s
# window under load (a slow registered check, a busy supervisor pane) with the
# daemon perfectly healthy throughout. The strict watcher predicate and $GRACE
# are unchanged everywhere else, including for a dead daemon pid or a beacon
# older than AFK_GRACE, which still block.
#
# Loop-guard: never block twice in the same turn. A payload whose
# stop_hook_active (or typed camel-case stopHookActive, which takes precedence)
# is true already follows a block, so this guard always allows it. That bounds
# a session to at most one forced continuation per turn - never a wedged,
# un-endable session - while still nagging again on a later turn if the problem
# persists.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
GRACE=${FM_GUARD_GRACE:-300}
WATCH="$SCRIPT_DIR/fm-watch.sh"

if [ "$#" -gt 0 ]; then
  echo "usage: $(basename "$0") < payload.json" >&2
  exit 2
fi

# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

# Read the whole turn-end hook payload once; never block on unreadable/absent
# stdin.
PAYLOAD=$(cat 2>/dev/null || true)
[ -n "$PAYLOAD" ] || exit 0

# jq is the repo's established JSON dependency (bin/fm-x-poll.sh uses the same
# "missing jq -> silent no-op" degrade). Without it we cannot safely read the
# loop-guard field, so we must never block - fail open, not noisy.
command -v jq >/dev/null 2>&1 || exit 0

STOP_HOOK_ACTIVE=$(printf '%s' "$PAYLOAD" | jq -r '
  if type != "object" then error("payload")
  elif has("stopHookActive") then
    if ((.stopHookActive | type) == "boolean") then .stopHookActive else error("stopHookActive") end
  elif has("stop_hook_active") then
    if ((.stop_hook_active | type) == "boolean") then .stop_hook_active else error("stop_hook_active") end
  else false
  end
' 2>/dev/null) || exit 0
if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

# --- scope precisely to a PRIMARY checkout ----------------------------------
# A genuinely-marked secondmate home runs its OWN primary firstmate session, so
# force-INCLUDE it as a guarded primary whether treehouse leased it as a linked
# worktree (git-dir != git-common-dir) or it is a git-cloned plain checkout. This
# mirrors the cd-guard's intent that a secondmate's own session is a guarded
# primary. Only an UNMARKED checkout (or one with an invalid marker) falls
# through to the linked-worktree exemption: firstmate hands out crewmate/scout
# task worktrees as genuine linked `git worktree`s (bin/fm-spawn.sh aborts
# otherwise), whose git-dir lives under the parent repo's .git/worktrees/<name>
# and differs from the common (shared) git-dir, while a main, non-worktree
# checkout has the two equal. Child worktrees never carry the gitignored marker,
# so this exempts them while guarding every real secondmate home.
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- the actual predicate ----------------------------------------------------
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

fm_supervision_status "$STATE" "$GRACE"
[ "$FM_SUP_NEEDED" = false ] && exit 0

if fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME"; then
  exit 0
fi

# Away mode transfers supervision ownership from the watcher to the away-mode
# daemon, which runs the watcher one-shot and starts its replacement after every
# wake (bin/fm-supervise-daemon.sh). A turn boundary regularly lands in that
# hand-off, when no watcher process holds the lock and nothing is wrong, so
# requiring one here alarmed on healthy away-mode supervision. A live
# identity-matched daemon holding this home is the right owner to test for.
# The beacon half of the predicate still applies: a daemon that stops
# restarting its watcher still blocks once the beacon passes grace, and a home
# with no daemon and no watcher blocks exactly as before. It uses AFK_GRACE
# (poll-cadence-derived, see the comment above) instead of the flat $GRACE
# every other check on this page uses, so a daemon that is genuinely still
# cycling - just slower than a fixed 300s window - is not misread as down.
AFK_GRACE=${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}
if [ "$(fm_path_age "$STATE/.last-watcher-beat")" -lt "$AFK_GRACE" ] \
  && fm_afk_daemon_owns_supervision "$STATE"; then
  exit 0
fi

block_stop() {
  local afk x_mode reason rule
  afk=0
  [ -e "$STATE/.afk" ] && afk=1
  x_mode=0
  [ -f "$CONFIG/x-mode.env" ] && x_mode=1
  reason=$("$SCRIPT_DIR/fm-supervision-instructions.sh" --afk "$afk" --x-mode "$x_mode" --repair-line 2>/dev/null \
    || printf '%s\n' 'tasks in flight, no live watcher - repair missing watcher supervision according to the session-start operating block before ending the turn')
  rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$rule"
    printf '●  TURN WOULD END BLIND - SUPERVISION IS OFF\n'
    if [ "$FM_SUP_IN_FLIGHT" -gt 0 ]; then
      printf '●  %s task(s) in flight, but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_IN_FLIGHT" "$FM_SUP_BEACON_DESC"
    elif [ "$FM_SUP_SOURCES" -gt 0 ]; then
      printf '●  %s process-event source(s) registered, but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_SOURCES" "$FM_SUP_BEACON_DESC"
    elif [ "$FM_SUP_CHECKS" -gt 0 ]; then
      printf '●  %s registered custom check(s), but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_CHECKS" "$FM_SUP_BEACON_DESC"
    else
      printf '●  X-mode relay polling needs supervision, but no live watcher holds this home lock (last beat: %s).\n' "$FM_SUP_BEACON_DESC"
    fi
    printf '●  %s\n' "$reason"
    printf '●%s\n' "$rule"
  } >&2
  exit 2
}

block_stop
