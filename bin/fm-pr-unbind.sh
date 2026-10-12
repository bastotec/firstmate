#!/usr/bin/env bash
# Clear a wrong pr= (and its pr_head=) from a task's state/<id>.meta.
# Usage: fm-pr-unbind.sh <task-id>
#
# A task's meta can end up carrying another task's pr=, and no other supported
# command removes the wrong value: bin/fm-pr-check.sh only records or rebinds,
# while teardown, merge, and the audit read the live forge instead. The stale
# value can then leak into public records such as failed-outcome annotations.
# This command is the supported owner for that removal.
#
# Guarded like bin/fm-check-unregister.sh guards custom checks, but against the
# live forge rather than the local filesystem: the removal is allowed only when
# the forge shows no open pull request for the task's OWN fm/<task-id> branch.
# A pull request that exists for that branch - whatever URL the meta carries -
# means the record may be wrong about which PR it names but the task still has
# live review work, so clearing is refused and the operator reconciles by hand.
# The repository is resolved from the task's recorded worktree's github.com
# origin, so a task on any GitHub repository resolves with nothing configured
# per task; a missing worktree origin refuses, and the command explicitly
# supports github.com origins only rather than guessing the repository from the
# very pr= value being cleared.
#
# What is removed, and only that: every pr= and pr_head= line in the meta, plus
# the PR-poll artifacts armed for that same URL (state/<id>.check.sh, .pr-poll,
# .pr-poll-registration). The poll is identified the way the watcher
# identifies it, byte-identity with bin/fm-pr-poll.sh at mode 600, and each
# artifact is then removed only against the hash and file identity the valid
# snapshot captured, so a file swapped between validation and removal is never
# deleted. If an interruption has already removed part of that triple, a rerun
# validates each remaining sidecar against the task and finishes the removal.
# A mode-700 state/<id>.check.sh is a custom check and is left alone:
# custom checks are unrelated to pr= and bin/fm-check-unregister.sh owns them.
# A mode-600 check that is not the poll template is a foreign static check and
# refuses rather than being interpreted. A pending merge-retirement receipt for
# the cleared URL is finished first, exactly as bin/fm-watch.sh would
# (bin/fm-pr-lib.sh's fm_pr_poll_retirement_recover_one), while the meta still
# names the PR it validates against. Leaving an armed poll behind is not an
# option: the watcher cross-checks every armed poll against the task's meta
# (fm_pr_poll_snapshot_capture), so a poll orphaned by the rewrite would be
# rejected as unauthenticated on every cycle from then on. The meta rewrite
# itself is the same atomic tmp-then-mv under the task's metadata lock that
# bin/fm-pr-check.sh uses, and the whole unbind runs under the task's control
# lock (state/.control-<id>.lock). bin/fm-pr-check.sh holds that lock from its
# metadata rewrite through poll publication, bin/fm-watch.sh holds it for a poll
# transaction, and bin/fm-teardown.sh holds it for lifecycle cleanup, so none
# can interleave with unbind. The merge-notification marker and merge-authority
# records are untouched: they describe merges that really happened, and
# teardown owns their removal.
#
# Before starting its own poll-and-meta removals, each unbind attempt appends one
# assertion line to the append-only state/pr-unbinds.log, naming who is clearing
# which pr= from which task at what time, mirroring
# state/endpoint-retirements.log's assertion-before-removal contract. The log
# must be a private mode-600 regular single-link file on the state device; it is
# created with that mode when absent, and descriptor-bound appends never follow
# a link. An unsafe target or failed append refuses the removal outright, so a
# meta is never silently stripped of its PR record.
# Unbind removals are ordered poll-then-meta so every interruption is
# rerunnable: a crash after the poll is gone but before the rewrite leaves the
# stale pr= intact as the identity a rerun validates, then the rerun finishes
# the job with a second assertion line.
#
# Refusals (exit 1, meta untouched beyond a completed retirement recovery): the
# meta is absent or unsafe (symlink, hard link, foreign device); pr= is missing
# or malformed (there is nothing supported to clear); the task's worktree has
# no usable origin or does not use the supported github.com forge; the forge
# cannot be read (gh missing, unauthenticated, offline, or an unreadable
# answer); an open pull request exists for the task's own fm/<task-id> branch;
# the armed check is foreign, or remaining poll artifacts cannot be bound to the
# recorded pr=; a pending retirement receipt cannot be finished; the unbind log
# is unsafe or cannot be appended; the task's control or metadata lock cannot
# be acquired.
# While another lifecycle action holds the control lock the unbind waits for it
# (bin/fm-wake-lib.sh's fm_lock_acquire_wait, the mutation-critical acquire)
# rather than refusing, so it never interleaves with a poll transaction or a
# teardown. Invalid usage exits 2. Reading the guard needs gh; the head
# projection is gh's own --jq, so no separate JSON processor is required.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-project-origin-lib.sh
. "$SCRIPT_DIR/fm-project-origin-lib.sh"

# Resolved after the libraries because fm-wake-lib.sh derives its own STATE with
# a defaulting expansion that would silently turn an explicitly empty
# FM_STATE_OVERRIDE back into FM_HOME/state; this form keeps the empty value so
# the guard below refuses it, the way bin/fm-check-unregister.sh refuses.
STATE="${FM_STATE_OVERRIDE-$FM_HOME/state}"

if [ "$#" -ne 1 ] || ! fm_pr_task_id_valid "$1"; then
  echo "error: invalid PR unbind request" >&2
  exit 2
fi
ID=$1

if [ -z "${STATE-}" ] || [ ! -d "${STATE-}" ] || [ -L "${STATE-}" ]; then
  echo "error: state directory is unavailable" >&2
  exit 1
fi

META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi
STATE_DEVICE=$(fm_pr_file_device "$STATE") || {
  echo "error: state directory is unavailable" >&2
  exit 1
}
[ "$(fm_pr_file_device "$META")" = "$STATE_DEVICE" ] || {
  echo "error: task metadata is unavailable" >&2
  exit 1
}

# Exactly one canonical pr= line is required, the same shape
# fm_pr_metadata_identity_parse enforces elsewhere.
if ! fm_pr_metadata_identity_parse "$META"; then
  echo "error: task metadata carries no single valid pr= to clear" >&2
  exit 1
fi
PR_URL=$FM_PR_META_URL

# The whole unbind runs under the task's control lock, the same lock
# bin/fm-pr-check.sh holds through poll publication, bin/fm-watch.sh holds for a
# PR-poll transaction, and bin/fm-teardown.sh holds for lifecycle cleanup.
CONTROL_LOCK="$STATE/.control-$ID.lock"
CONTROL_LOCK_HELD=0
META_TMP=
META_LOCK=
META_LOCK_HELD=0
unbind_cleanup() {
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    fm_lock_release "$CONTROL_LOCK" || true
    CONTROL_LOCK_HELD=0
  fi
}
trap unbind_cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_lock_acquire_wait "$CONTROL_LOCK" || {
  echo "error: could not take the task $ID control lock (is the state directory gone?); nothing was changed" >&2
  exit 1
}
CONTROL_LOCK_HELD=1

META_LOCK=$(fm_meta_lock_path "$META") || {
  echo "error: task metadata is unavailable" >&2
  exit 1
}
fm_lock_acquire_wait "$META_LOCK" || {
  echo "error: task metadata is unavailable" >&2
  exit 1
}
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
[ "$(fm_pr_file_device "$META")" = "$STATE_DEVICE" ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
fm_pr_metadata_identity_parse "$META" \
  && [ "$FM_PR_META_URL" = "$PR_URL" ] || {
  echo "error: task metadata changed while the unbind was being prepared" >&2
  exit 1
}

# Resolve the repository to query from the task's own worktree origin, so the
# guard reads the forge the task actually targets. A missing, non-directory,
# or non-git worktree refuses, and a non-github.com origin reaches the explicit
# supported-forge refusal below rather than guessing from the stale pr=.
WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
REPO=
ORIGIN=
if [ -n "$WT" ] && [ -d "$WT" ]; then
  ORIGIN=$(git -C "$WT" remote get-url origin 2>/dev/null) || ORIGIN=
fi
if [ -z "$ORIGIN" ]; then
  echo "error: the task's worktree has no usable origin, so the forge cannot be checked for the task's own branch" >&2
  exit 1
fi
if ! fm_project_origin_safe "$ORIGIN"; then
  echo "error: the task's worktree origin does not name a valid repository" >&2
  exit 1
fi
ORIGIN_HOST=
ORIGIN_PATH=
case "$ORIGIN" in
  https://*|http://*|ssh://*|git://*)
    origin_rest=${ORIGIN#*://}
    origin_authority=${origin_rest%%/*}
    origin_hostport=${origin_authority##*@}
    ORIGIN_HOST=${origin_hostport%%:*}
    if [ "$origin_rest" != "$origin_authority" ]; then
      ORIGIN_PATH=${origin_rest#*/}
    fi
    ;;
  *:*)
    origin_rest=$ORIGIN
    case "$origin_rest" in
      *@*) origin_rest=${origin_rest#*@} ;;
    esac
    ORIGIN_HOST=${origin_rest%%:*}
    ORIGIN_PATH=${origin_rest#*:}
    ;;
esac
ORIGIN_HOST=$(printf '%s' "$ORIGIN_HOST" | tr '[:upper:]' '[:lower:]')
if [ "$ORIGIN_HOST" != github.com ]; then
  echo "error: the PR unbind supports github.com origins only; the task's worktree origin is unsupported" >&2
  exit 1
fi
REPO=${ORIGIN_PATH%/}
REPO=${REPO%.git}
# Reuse the canonical URL parser to validate the derived owner/repository shape,
# rather than trusting whatever string the remote URL carried.
if ! fm_pr_url_parse "https://github.com/$REPO/pull/1"; then
  echo "error: the task's worktree origin does not name a valid GitHub repository" >&2
  exit 1
fi
command -v gh >/dev/null 2>&1 || {
  echo "error: clearing a pr= record requires gh on PATH" >&2
  exit 1
}

# The guard itself: no open pull request may exist for the task's own
# fm/<task-id> branch. gh pr list applies its own --jq projection to the JSON
# it produced, so a successful read already proves the answer was a well-formed
# array; the headRefName values it prints must then equal the branch exactly,
# and an empty list is the passing answer.
BRANCH="fm/$ID"
OPEN_HEADS=$(gh pr list --repo "$REPO" --state open --head "$BRANCH" \
  --limit 5 --json headRefName --jq '.[].headRefName' 2>/dev/null) || {
  echo "error: could not read the forge for the task's own branch (gh missing, not authenticated, unreachable, or an unreadable answer)" >&2
  exit 1
}
while IFS= read -r head; do
  [ -n "$head" ] || continue
  if [ "$head" = "$BRANCH" ]; then
    echo "error: an open pull request exists for the task's own branch $BRANCH; reconcile the record by hand instead of clearing it" >&2
    exit 1
  fi
done <<EOF
$OPEN_HEADS
EOF

POLL_CHECK="$STATE/$ID.check.sh"
POLL_DATA="$STATE/$ID.pr-poll"
POLL_REG="$STATE/$ID.pr-poll-registration"
poll_artifact_present() {  # <path>
  [ -e "$1" ] || [ -L "$1" ]
}
POLL_TEMPLATE="$SCRIPT_DIR/fm-pr-poll.sh"

# A pending merge-retirement receipt is finished before classifying the poll,
# exactly as bin/fm-watch.sh would, while the meta still names the PR the
# receipt validates against. Recovery explicitly accepts a receipt whose
# pinned removals were interrupted, including one whose check is already gone.
if ! fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$POLL_TEMPLATE"; then
  echo "error: a pending PR poll retirement could not be validated; reconcile by hand" >&2
  exit 1
fi
if poll_artifact_present "$STATE/$ID.pr-poll-retirement"; then
  echo "error: a pending PR poll retirement could not be finished; reconcile by hand" >&2
  exit 1
fi

# Classify what remains after receipt recovery. A complete poll is captured by
# the shared snapshot validator. If a previous unbind was interrupted after
# removing the check, each remaining sidecar is instead validated directly
# against the task, recorded pr=, state device, and (where recorded) template
# and peer identity. This makes every removal boundary rerunnable without
# treating malformed or mismatched fixed-path files as poll artifacts.
STATE_DEVICE_NOW=$(fm_pr_file_device "$STATE") || {
  echo "error: state directory is unavailable" >&2
  exit 1
}
UNBIND_POLL=0
UNBIND_CHECK_PRESENT=0
UNBIND_DATA_PRESENT=0
UNBIND_REG_PRESENT=0
UNBIND_CHECK_IDENTITY=
UNBIND_CHECK_HASH=
UNBIND_DATA_IDENTITY=
UNBIND_DATA_HASH=
UNBIND_REG_IDENTITY=
UNBIND_REG_HASH=
if poll_artifact_present "$POLL_CHECK"; then
  if [ "$(fm_pr_file_mode "$POLL_CHECK")" = 600 ] \
    && cmp -s "$POLL_TEMPLATE" "$POLL_CHECK"; then
    if ! fm_pr_poll_snapshot_capture "$STATE" "$ID" "$POLL_TEMPLATE"; then
      echo "error: the task's armed PR poll does not validate against its recorded pr=; reconcile by hand" >&2
      exit 1
    fi
    UNBIND_POLL=1
    UNBIND_CHECK_PRESENT=1
    UNBIND_DATA_PRESENT=1
    UNBIND_REG_PRESENT=1
    UNBIND_CHECK_IDENTITY=$FM_PR_POLL_SNAPSHOT_CHECK_IDENTITY
    UNBIND_CHECK_HASH=$FM_PR_POLL_SNAPSHOT_TEMPLATE_HASH
    UNBIND_DATA_IDENTITY=$FM_PR_POLL_SNAPSHOT_DATA_IDENTITY
    UNBIND_DATA_HASH=$FM_PR_POLL_SNAPSHOT_DATA_HASH
    UNBIND_REG_IDENTITY=$FM_PR_POLL_SNAPSHOT_REG_IDENTITY
    UNBIND_REG_HASH=$FM_PR_POLL_SNAPSHOT_REG_HASH
  elif [ "$(fm_pr_file_mode "$POLL_CHECK")" = 700 ]; then
    if poll_artifact_present "$POLL_DATA" || poll_artifact_present "$POLL_REG"; then
      echo "error: poll sidecars exist beside a custom check; reconcile by hand" >&2
      exit 1
    fi
  else
    echo "error: state/$ID.check.sh is not a PR poll or a custom check; reconcile by hand" >&2
    exit 1
  fi
elif poll_artifact_present "$POLL_DATA" || poll_artifact_present "$POLL_REG"; then
  UNBIND_POLL=1
  if poll_artifact_present "$POLL_DATA"; then
    UNBIND_DATA_IDENTITY=$(fm_pr_file_identity "$POLL_DATA") \
      && UNBIND_DATA_HASH=$(fm_pr_sha256 "$POLL_DATA") \
      && fm_pr_private_file_valid "$POLL_DATA" 600 "$STATE_DEVICE_NOW" \
      && fm_pr_poll_data_parse "$POLL_DATA" \
      && [ "$FM_PR_DATA_PROVIDER" = "$FM_PR_META_PROVIDER" ] \
      && [ "$FM_PR_DATA_URL" = "$FM_PR_META_URL" ] \
      && [ "$FM_PR_DATA_HOST" = "$FM_PR_META_HOST" ] \
      && [ "$FM_PR_DATA_PATH" = "$FM_PR_META_PATH" ] \
      && [ "$FM_PR_DATA_NUMBER" = "$FM_PR_META_NUMBER" ] \
      && [ "$(fm_pr_file_identity "$POLL_DATA")" = "$UNBIND_DATA_IDENTITY" ] \
      && [ "$(fm_pr_sha256 "$POLL_DATA")" = "$UNBIND_DATA_HASH" ] || {
      echo "error: the remaining PR poll sidecar is ambiguous; reconcile by hand" >&2
      exit 1
    }
    UNBIND_DATA_PRESENT=1
  fi
  if poll_artifact_present "$POLL_REG"; then
    POLL_TEMPLATE_HASH=$(fm_pr_sha256 "$POLL_TEMPLATE") || {
      echo "error: the PR poll template is unreadable" >&2
      exit 1
    }
    UNBIND_REG_IDENTITY=$(fm_pr_file_identity "$POLL_REG") \
      && UNBIND_REG_HASH=$(fm_pr_sha256 "$POLL_REG") \
      && fm_pr_private_file_valid "$POLL_REG" 600 "$STATE_DEVICE_NOW" \
      && fm_pr_poll_registration_parse "$POLL_REG" \
      && [ "$FM_PR_REG_ID" = "$ID" ] \
      && [ "$FM_PR_REG_PROVIDER" = "$FM_PR_META_PROVIDER" ] \
      && [ "$FM_PR_REG_URL" = "$FM_PR_META_URL" ] \
      && [ "$FM_PR_REG_HOST" = "$FM_PR_META_HOST" ] \
      && [ "$FM_PR_REG_PATH" = "$FM_PR_META_PATH" ] \
      && [ "$FM_PR_REG_NUMBER" = "$FM_PR_META_NUMBER" ] \
      && [ "$FM_PR_REG_TEMPLATE_HASH" = "$POLL_TEMPLATE_HASH" ] \
      && [ "$(fm_pr_file_identity "$POLL_REG")" = "$UNBIND_REG_IDENTITY" ] \
      && [ "$(fm_pr_sha256 "$POLL_REG")" = "$UNBIND_REG_HASH" ] || {
      echo "error: the remaining PR poll registration is ambiguous; reconcile by hand" >&2
      exit 1
    }
    UNBIND_REG_PRESENT=1
  fi
  if [ "$UNBIND_DATA_PRESENT" = 1 ] && [ "$UNBIND_REG_PRESENT" = 1 ]; then
    [ "$FM_PR_REG_DATA_IDENTITY" = "$UNBIND_DATA_IDENTITY" ] \
      && [ "$FM_PR_REG_DATA_HASH" = "$UNBIND_DATA_HASH" ] || {
      echo "error: the remaining PR poll sidecars disagree; reconcile by hand" >&2
      exit 1
    }
  fi
fi

# Register the removal before anything is removed. The line records the
# assertion and the cleared URL; no outcome is written back to it.
UNBIND_LOG="$STATE/pr-unbinds.log"
UNBIND_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
UNBIND_BY=$(id -un 2>/dev/null || printf '%s' "${USER:-unknown}")
if ! (umask 077; : | python3 "$SCRIPT_DIR/fm-state-io.py" \
  root-private-append "$STATE" pr-unbinds.log); then
  echo "error: the unbind could not be registered in $UNBIND_LOG; nothing was cleared" >&2
  exit 1
fi
fm_pr_private_file_valid "$UNBIND_LOG" 600 "$STATE_DEVICE_NOW" || {
  echo "error: the unbind could not be registered in $UNBIND_LOG; nothing was cleared" >&2
  exit 1
}
if ! printf '%s\tasserted\t%s\tpr=%s\tby=%s\n' "$UNBIND_AT" "$ID" "$PR_URL" "$UNBIND_BY" \
  | (umask 077; python3 "$SCRIPT_DIR/fm-state-io.py" \
      root-private-append "$STATE" pr-unbinds.log); then
  echo "error: the unbind could not be registered in $UNBIND_LOG; nothing was cleared" >&2
  exit 1
fi
fm_pr_private_file_valid "$UNBIND_LOG" 600 "$STATE_DEVICE_NOW" || {
  echo "error: the unbind could not be registered in $UNBIND_LOG; nothing was cleared" >&2
  exit 1
}

# Remove the poll artifacts first, each pinned to the exact bytes and file
# identity the validated snapshot captured, so a swap between validation and
# removal is refused rather than deleted. This ordering keeps every
# interruption rerunnable: with the poll gone but the meta not yet rewritten
# there is no orphaned watch for the watcher to reject, and the intact stale
# pr= gives a rerun the identity it needs to finish the clear.
if [ "$UNBIND_POLL" = 1 ]; then
  if [ "$UNBIND_CHECK_PRESENT" = 1 ]; then
    fm_pr_poll_retirement_remove_exact "$POLL_CHECK" "$STATE_DEVICE_NOW" \
      "$UNBIND_CHECK_IDENTITY" "$UNBIND_CHECK_HASH" || {
      echo "error: the armed PR poll check could not be removed; the meta still names its PR" >&2
      exit 1
    }
  fi
  if [ "$UNBIND_REG_PRESENT" = 1 ]; then
    fm_pr_poll_retirement_remove_exact "$POLL_REG" "$STATE_DEVICE_NOW" \
      "$UNBIND_REG_IDENTITY" "$UNBIND_REG_HASH" || {
      echo "error: the PR poll registration could not be removed; the meta still names its PR" >&2
      exit 1
    }
  fi
  if [ "$UNBIND_DATA_PRESENT" = 1 ]; then
    fm_pr_poll_retirement_remove_exact "$POLL_DATA" "$STATE_DEVICE_NOW" \
      "$UNBIND_DATA_IDENTITY" "$UNBIND_DATA_HASH" || {
      echo "error: the PR poll sidecar could not be removed; the meta still names its PR" >&2
      exit 1
    }
  fi
fi

# Atomic guarded rewrite: drop only pr= and pr_head= lines, preserving every
# other line and its order byte-for-byte.
META_TMP=$(mktemp "$STATE/.fm-pr-unbind-meta.XXXXXX") || {
  echo "error: could not prepare the metadata rewrite" >&2
  exit 1
}
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || {
  echo "error: could not prepare the metadata rewrite" >&2
  exit 1
}

# The rewritten record must carry no pr= identity at all.
if grep -q '^pr=' "$META_TMP"; then
  echo "error: could not prepare the metadata rewrite" >&2
  exit 1
fi
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || {
  echo "error: task metadata is unavailable" >&2
  exit 1
}
mv -f -- "$META_TMP" "$META" || {
  echo "error: could not replace the task metadata" >&2
  exit 1
}
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || {
  echo "error: task metadata is unavailable after the rewrite" >&2
  exit 1
}
if grep -q '^pr=' "$META" 2>/dev/null; then
  echo "error: task metadata still names a PR after the rewrite" >&2
  exit 1
fi
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

printf 'unbound: state/%s.meta pr=%s\n' "$ID" "$PR_URL"
