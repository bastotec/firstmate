#!/usr/bin/env bash
# fm-approval-wait.sh - parent-owned, untimed approval exclusion for automatic
# stopped-worker retry/retirement. This is not an external-capability wait or
# a captain question. Ordinary keyed blockers remain retry-eligible.
#
# Usage (FM_HOME must explicitly name the owning home):
#   fm-approval-wait.sh declare <task> --key <open-decision-key> --expected-record <metadata> --instruction-file <absolute-path>
#   fm-approval-wait.sh show <task>
#   fm-approval-wait.sh release <task> --instruction-sha256 <digest> --release-file <absolute-path>
#
# declare records the parent's explicit approval prohibition, not an inference
# from worker prose. The caller must be the owning mate acting on that authority.
# It holds the task control lock and requires unchanged metadata and an exact
# open status decision key, storing these bindings plus the task, owning home,
# and preserved instruction path/digest in
# state/<task>.approval-wait (schema fm-approval-wait.v1). It never touches the
# worker, instructions, branch, endpoint, backlog, or any captain hold.
# Identical declarations are idempotent; replacement requires explicit release.
# No clock, ledger change, endpoint loss or new incarnation releases a wait.
# release requires the original instruction digest and a distinct parent release
# instruction file; it archives the record, including the release path/digest,
# under state/approval-waits/. Release only removes this automatic-action
# exclusion: it grants no recovery, cleanup, publication or source authority.
# Neither command sends a message or resumes work. The owning mate must retain
# and enforce the actual instruction separately; recording it here does not
# broaden it. No declaration/release is inferred from status keys or prose.
#
# Sourceable helper fm_approval_wait_admit <state-dir> <task>: exit 0 iff no
# record object exists. Any existing object (even corrupt or a broken symlink)
# refuses automatic action until the owning mate reconciles it. Shared locked
# stopped admission and record-less closure recheck this predicate before acting.
# All mutations use the task's control lock; reads create nothing.
# Exit: 0 success, 1 refusal, 2 usage error.
set -u

FM_APPROVAL_WAIT_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fm_approval_wait_admit() {  # <state-dir> <task>
  [ ! -e "$1/$2.approval-wait" ] && [ ! -L "$1/$2.approval-wait" ]
}

fm_approval_wait_main() {
  local cmd=${1:-} id=${2:-} expected='' instruction='' digest='' release='' key='' open=''
  local state record lock home hash tmp archive stamp
  case "$cmd" in
    -h|--help) sed -n '2,/^set -u/{ /^#/s/^# \{0,1\}//p; }' "${BASH_SOURCE[0]}"; return 0 ;;
    declare|show|release) ;;
    *) echo 'error: use declare, show or release (see --help)' >&2; return 2 ;;
  esac
  case "$id" in ''|*[!A-Za-z0-9._-]*) echo 'error: a valid task id is required' >&2; return 2 ;; esac
  [ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME/state" ] || {
    echo 'error: explicit FM_HOME with an existing state directory is required' >&2; return 2;
  }
  home=$(cd "$FM_HOME" && pwd -P) || return 1
  state=${FM_STATE_OVERRIDE:-$home/state}
  record="$state/$id.approval-wait"
  shift 2
  while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || return 2
    case "$1" in
      --key) key=$2 ;;
      --expected-record) expected=$2 ;;
      --instruction-file) instruction=$2 ;;
      --instruction-sha256) digest=$2 ;;
      --release-file) release=$2 ;;
      *) echo "error: unknown argument $1" >&2; return 2 ;;
    esac
    shift 2
  done
  if [ "$cmd" = show ]; then
    [ -f "$record" ] && [ ! -L "$record" ] || return 1
    cat "$record"
    return
  fi
  if [ "$cmd" = declare ]; then
    [ -n "$expected" ] && [ -z "$digest$release" ] || return 2
    case "$key" in ''|*[!A-Za-z0-9._-]*) echo 'error: an exact open decision key is required' >&2; return 2 ;; esac
  else
    [ -z "$expected$instruction$key" ] && [ "${#digest}" -eq 64 ] || return 2
    instruction=$release
  fi
  case "$instruction" in /*) ;; *) echo 'error: an absolute instruction file is required' >&2; return 2 ;; esac
  [ -f "$instruction" ] && [ -r "$instruction" ] && [ -s "$instruction" ] && [ ! -L "$instruction" ] || {
    echo 'error: instruction must be a nonempty readable regular file' >&2; return 1;
  }
  hash=$(shasum -a 256 "$instruction") || return 1
  hash=${hash%% *}
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_APPROVAL_WAIT_BIN/fm-wake-lib.sh"
  lock="$state/.control-$id.lock"
  fm_lock_acquire_wait_bounded "$lock" 30 || return 1
  FM_APPROVAL_WAIT_LOCK=$lock
  trap 'fm_lock_release "$FM_APPROVAL_WAIT_LOCK" >/dev/null 2>&1 || true' EXIT
  if [ "$cmd" = declare ]; then
    [ -f "$state/$id.meta" ] && [ ! -L "$state/$id.meta" ] \
      && [ "$(cat "$state/$id.meta")" = "$expected" ] || {
      echo 'error: worker metadata changed; approval wait was not declared' >&2; return 1;
    }
    # shellcheck source=bin/fm-classify-lib.sh
    . "$FM_APPROVAL_WAIT_BIN/fm-classify-lib.sh"
    open=$(status_open_decisions "$state/$id.status") || return 1
    _fm_open_set_has "$open" "$key" || {
      echo 'error: the exact approval decision key is not open; nothing was declared' >&2; return 1;
    }
    if ! fm_approval_wait_admit "$state" "$id"; then
      if ! { [ -f "$record" ] && [ ! -L "$record" ] \
        && jq -e --arg task "$id" --arg home "$home" --arg hash "$hash" --arg key "$key" \
          '.schema=="fm-approval-wait.v1" and .task==$task and .home==$home
            and .instruction_sha256==$hash and .decision_key==$key' "$record" >/dev/null; }; then
        echo 'error: an existing approval wait must be reconciled or explicitly released' >&2; return 1
      fi
      return 0
    fi
    expected=$(printf '%s' "$expected" | shasum -a 256) || return 1
    tmp="$record.tmp.$$"
    if ! jq -n --arg task "$id" --arg home "$home" --arg instruction "$instruction" \
      --arg hash "$hash" --arg key "$key" --arg meta "${expected%% *}" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{schema:"fm-approval-wait.v1",task:$task,home:$home,decision_key:$key,instruction_file:$instruction,
        instruction_sha256:$hash,metadata_sha256:$meta,declared:$at}' > "$tmp"; then
      rm -f "$tmp"; return 1
    fi
    mv "$tmp" "$record" || { rm -f "$tmp"; return 1; }
  else
    if ! { [ -f "$record" ] && [ ! -L "$record" ] \
      && jq -e --arg task "$id" --arg home "$home" --arg digest "$digest" --arg hash "$hash" \
        '.schema=="fm-approval-wait.v1" and .task==$task and .home==$home
          and .instruction_sha256==$digest and .instruction_sha256!=$hash' "$record" >/dev/null; }; then
      echo 'error: release must match this home/task/original instruction and supply a distinct release instruction' >&2; return 1
    fi
    mkdir -p "$state/approval-waits" || return 1
    stamp="$(date -u +%Y%m%dT%H%M%SZ).$$.$RANDOM"
    archive="$state/approval-waits/$id.$stamp.json"
    jq --arg file "$release" --arg hash "$hash" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '. + {released:$at,release_file:$file,release_sha256:$hash}' "$record" > "$archive" || return 1
    rm "$record" || return 1
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  fm_approval_wait_main "$@"
fi
