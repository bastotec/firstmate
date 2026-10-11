#!/usr/bin/env bash
# Create a persistent second mate in one scripted order: charter, seed, launch.
#
# Usage:
#   fm-secondmate-create.sh plan|apply <id> --charter <text> --scope <text> [--host <ssh-alias> --root <remote-code-root> --home <remote-home>] {<project>[=<origin-url>]...|--no-projects}
#
# This is the deterministic entry point for an order that names a new second
# mate (for example one sent from a UI and confirmed by the captain). It never
# reimplements provisioning; it composes the existing owners in order:
#   1. fm-brief.sh <id> --secondmate ... with FM_SECONDMATE_CHARTER and
#      FM_SECONDMATE_SCOPE, which writes the charter brief
#   2. fm-home-seed.sh <id> - ...  (local placement, a leased worktree home)
#      or fm-remote-home-seed.sh <id> <alias> <root> <home> ...  (remote placement)
#   3. fm-spawn.sh <id> --secondmate
# Those scripts own every provisioning rule; this script only validates the
# order up front and runs the steps.
#
# plan is read-only. It validates everything it can without side effects:
# the id is a lowercase slug with no route, charter, or task record yet; the
# charter and scope are non-empty single lines; a host alias is a plain
# [A-Za-z0-9._-] name not starting with "-"; the remote root and home are
# absolute, separate, and non-overlapping; every project is registered in
# data/projects.md and not local-only. A local placement needs each project
# cloned under projects/ and refuses "=<origin-url>"; a remote placement needs
# either "=<origin-url>" or a clone here whose origin is read by the seed.
#
# apply re-runs the same validation, then runs the steps in order and stops at
# the first failure. Step output is relayed to stderr so stdout stays the line
# protocol. The seed scripts roll themselves back; when step 2 fails with a
# known outcome this script also removes the charter brief step 1 wrote, so the
# same order can simply be sent again. A remote seed exiting 255 means unknown
# completion and keeps the brief for same-route reconciliation. A failed
# launch (step 3) leaves the seeded home and route in place; relaunch it with
# the printed step 3 command.
#
# Line protocol on stdout, one fact per line, stable for script consumers:
#   action=plan|apply
#   id=<id>
#   placement=local|remote
#   host=<ssh-alias>                          (remote only)
#   root=<remote-code-root>                   (remote only)
#   home=<remote-home>|leased-worktree
#   charter=<text>
#   scope=<text>
#   project=<name> origin=<url|from-clone>    (one per project; none with --no-projects)
#   projects=none                             (--no-projects only)
#   step=<n> <exact shell command it will run>   (only when nothing was refused)
#   refuse: <plain reason>                    (one per refusal; exit 1)
#   ran step=<n>                              (apply only)
#   failed step=<n>: <plain reason>           (apply only; exit 1)
#   done id=<id>                              (apply only; exit 0)
# Usage errors exit 2.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-project-origin-lib.sh
. "$SCRIPT_DIR/fm-project-origin-lib.sh"

usage() { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# Quote one word for the printed command so it can be pasted into a shell.
shq() {
  case $1 in
    '' ) printf "''" ;;
    *[!A-Za-z0-9._/:=@%+,-]*) printf "'%s'" "${1//\'/\'\\\'\'}" ;;
    *) printf '%s' "$1" ;;
  esac
}
render() { # <argv...>; leading NAME=value words render as shell assignments
  local out='' word assignments=1
  for word in "$@"; do
    if [ "$assignments" -eq 1 ] && [[ "$word" =~ ^[A-Z_][A-Z0-9_]*= ]]; then
      out="$out${out:+ }${word%%=*}=$(shq "${word#*=}")"
    else
      assignments=0
      out="$out${out:+ }$(shq "$word")"
    fi
  done
  printf '%s' "$out"
}

[ "$#" -ge 2 ] || usage
ACTION=$1
ID=$2
shift 2
case "$ACTION" in plan|apply) ;; *) usage ;; esac

CHARTER=
CHARTER_SET=0
SCOPE=
SCOPE_SET=0
HOST=
ROOT_PATH=
HOME_PATH=
NO_PROJECTS=0
PROJECT_ARGS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --charter|--scope|--host|--root|--home)
      [ "$#" -ge 2 ] || usage
      case "$1" in
        --charter) CHARTER=$2; CHARTER_SET=1 ;;
        --scope) SCOPE=$2; SCOPE_SET=1 ;;
        --host) HOST=$2 ;;
        --root) ROOT_PATH=$2 ;;
        --home) HOME_PATH=$2 ;;
      esac
      shift 2
      ;;
    --no-projects) NO_PROJECTS=1; shift ;;
    --*) usage ;;
    *) PROJECT_ARGS+=("$1"); shift ;;
  esac
done
[ "$CHARTER_SET" -eq 1 ] && [ "$SCOPE_SET" -eq 1 ] || usage

REFUSALS=()
refuse() { REFUSALS+=("$1"); }
single_line() { case "$1" in *$'\n'*|*$'\r'*) return 1 ;; esac; }

# Identity.
case "$ID" in
  [a-z0-9]*) case "$ID" in *[!a-z0-9-]*) refuse "id must be a lowercase slug of a-z, 0-9 and -: $ID" ;; esac ;;
  *) refuse "id must be a lowercase slug of a-z, 0-9 and -: $ID" ;;
esac
if [ -f "$DATA/secondmates.md" ] && grep -E "^- $ID( |$)" "$DATA/secondmates.md" >/dev/null 2>&1; then
  refuse "a second mate named $ID is already registered"
fi
if [ -e "$DATA/$ID/brief.md" ]; then
  refuse "a charter or task brief for $ID already exists at data/$ID/brief.md"
fi
if [ -e "$STATE/$ID.meta" ]; then
  refuse "a task or second mate record for $ID already exists"
fi

# Charter and scope.
[ -n "$CHARTER" ] || refuse "charter is empty"
single_line "$CHARTER" || refuse "charter must be a single line"
[ -n "$SCOPE" ] || refuse "scope is empty"
single_line "$SCOPE" || refuse "scope must be a single line"

# Placement.
PLACEMENT=local
if [ -n "$HOST$ROOT_PATH$HOME_PATH" ]; then
  PLACEMENT=remote
  if [ -z "$HOST" ] || [ -z "$ROOT_PATH" ] || [ -z "$HOME_PATH" ]; then
    refuse "a remote placement needs --host, --root and --home together"
  fi
  case "$HOST" in
    '') ;;
    -*|*[!A-Za-z0-9._-]*) refuse "host must be a plain ssh config alias of A-Z, a-z, 0-9, ., _ and -, not starting with -: $HOST" ;;
  esac
  for path in "$ROOT_PATH" "$HOME_PATH"; do
    [ -n "$path" ] || continue
    case "$path" in /*) ;; *) refuse "remote root and home must be absolute paths: $path"; continue ;; esac
    case "$path" in *';'*|*')'*|*$'\n'*|*$'\r'*|*$'\t'*) refuse "remote path contains a registry delimiter or control character: $path" ;; esac
    case "/$path/" in */../*|*/./*) refuse "remote path contains . or .. components: $path" ;; esac
    case "$path" in *'//'*) refuse "remote path contains an empty component: $path" ;; esac
  done
  if [ -n "$ROOT_PATH" ] && [ -n "$HOME_PATH" ]; then
    root_norm=${ROOT_PATH%/}
    home_norm=${HOME_PATH%/}
    if [ "$root_norm" = "$home_norm" ]; then
      refuse "remote root and home must be separate directories"
    else
      case "$home_norm/" in "$root_norm/"*) refuse "remote home must not be inside the remote code root" ;; esac
      case "$root_norm/" in "$home_norm/"*) refuse "remote code root must not be inside the remote home" ;; esac
    fi
  fi
fi

# Projects.
PROJECT_NAMES=()
PROJECT_ORIGINS=()
if [ "$NO_PROJECTS" -eq 1 ] && [ "${#PROJECT_ARGS[@]}" -gt 0 ]; then
  refuse "--no-projects cannot be combined with project names"
fi
if [ "$NO_PROJECTS" -eq 0 ] && [ "${#PROJECT_ARGS[@]}" -eq 0 ]; then
  refuse "name at least one project or pass --no-projects"
fi
for arg in "${PROJECT_ARGS[@]+"${PROJECT_ARGS[@]}"}"; do
  name=${arg%%=*}
  origin=
  case "$arg" in *=*) origin=${arg#*=} ;; esac
  case "$name" in
    ''|*[!A-Za-z0-9._-]*) refuse "invalid project name: $name"; continue ;;
  esac
  registry_line=$(awk -v p="$name" '$1 == "-" && $2 == p { print; exit }' "$DATA/projects.md" 2>/dev/null || true)
  if [ -z "$registry_line" ]; then
    refuse "project $name is not registered in data/projects.md"
  else
    mode=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-project-mode.sh" "$name" 2>/dev/null | awk '{print $1}')
    [ "$mode" != local-only ] || refuse "project $name is local-only and stays with the main first mate"
  fi
  if [ "$PLACEMENT" = local ]; then
    [ -z "$origin" ] || refuse "a local second mate clones $name from this home; drop =$origin"
    [ -d "$PROJECTS/$name/.git" ] || refuse "project $name is not cloned in this home, which a local second mate clones from"
  elif [ -n "$origin" ]; then
    fm_project_origin_safe "$origin" || refuse "project $name origin is not an accepted clone URL: $origin"
  else
    clone_origin=
    [ -d "$PROJECTS/$name/.git" ] && clone_origin=$(git -C "$PROJECTS/$name" remote get-url origin 2>/dev/null || true)
    [ -n "$clone_origin" ] || refuse "project $name has no clone here to read its origin from; pass $name=<origin-url>"
  fi
  PROJECT_NAMES+=("$name")
  PROJECT_ORIGINS+=("$origin")
done

# Facts.
printf 'action=%s\n' "$ACTION"
printf 'id=%s\n' "$ID"
printf 'placement=%s\n' "$PLACEMENT"
if [ "$PLACEMENT" = remote ]; then
  printf 'host=%s\n' "$HOST"
  printf 'root=%s\n' "$ROOT_PATH"
  printf 'home=%s\n' "$HOME_PATH"
else
  printf 'home=leased-worktree\n'
fi
printf 'charter=%s\n' "$(printf '%s' "$CHARTER" | tr '\r\n' '  ')"
printf 'scope=%s\n' "$(printf '%s' "$SCOPE" | tr '\r\n' '  ')"
if [ "$NO_PROJECTS" -eq 1 ]; then
  printf 'projects=none\n'
fi
i=0
for name in "${PROJECT_NAMES[@]+"${PROJECT_NAMES[@]}"}"; do
  printf 'project=%s origin=%s\n' "$name" "${PROJECT_ORIGINS[$i]:-from-clone}"
  i=$((i + 1))
done

if [ "${#REFUSALS[@]}" -gt 0 ]; then
  for reason in "${REFUSALS[@]}"; do printf 'refuse: %s\n' "$reason"; done
  exit 1
fi

# Steps, as argv arrays so the printed command and the run command are one.
if [ "$NO_PROJECTS" -eq 1 ]; then
  BRIEF_PROJECTS=(--no-projects)
  SEED_PROJECTS=(--no-projects)
else
  BRIEF_PROJECTS=("${PROJECT_NAMES[@]}")
  SEED_PROJECTS=("${PROJECT_ARGS[@]}")
fi
STEP1=(env "FM_SECONDMATE_CHARTER=$CHARTER" "FM_SECONDMATE_SCOPE=$SCOPE" bin/fm-brief.sh "$ID" --secondmate "${BRIEF_PROJECTS[@]}")
if [ "$PLACEMENT" = remote ]; then
  STEP2=(bin/fm-remote-home-seed.sh "$ID" "$HOST" "$ROOT_PATH" "$HOME_PATH" "${SEED_PROJECTS[@]}")
else
  STEP2=(bin/fm-home-seed.sh "$ID" - "${SEED_PROJECTS[@]}")
fi
STEP3=(bin/fm-spawn.sh "$ID" --secondmate)
printf 'step=1 %s\n' "$(render "${STEP1[@]:1}")"
printf 'step=2 %s\n' "$(render "${STEP2[@]}")"
printf 'step=3 %s\n' "$(render "${STEP3[@]}")"

[ "$ACTION" = apply ] || exit 0

OUT=$(mktemp "${TMPDIR:-/tmp}/fm-secondmate-create.XXXXXX")
trap 'rm -f -- "$OUT"' EXIT

# Echo the plain reason a failed step gave: its last error line, else its last line.
step_reason() {
  local line
  line=$(grep -E '^(error|refuse|refused|fatal)[: ]' "$OUT" | tail -n 1 || true)
  [ -n "$line" ] || line=$(grep -v '^[[:space:]]*$' "$OUT" | tail -n 1 || true)
  line=${line#error: }
  [ -n "$line" ] || line="exited $1 with no output"
  printf '%s' "$line"
}

run_step() { # <argv...>; the bin/ path is resolved against this checkout
  local rc
  local -a argv=("$@")
  if [ "${argv[0]}" = env ]; then
    argv[3]="$SCRIPT_DIR/${argv[3]#bin/}"
  else
    argv[0]="$SCRIPT_DIR/${argv[0]#bin/}"
  fi
  set +e
  "${argv[@]}" > "$OUT" 2>&1 < /dev/null
  rc=$?
  set -e
  cat "$OUT" >&2
  STEP_RC=$rc
  [ "$rc" -eq 0 ]
}

remove_own_brief() {
  rm -f -- "$DATA/$ID/brief.md"
  rmdir -- "$DATA/$ID" 2>/dev/null || true
}

STEP_RC=0
if ! run_step "${STEP1[@]}"; then
  printf 'failed step=1: %s\n' "$(step_reason "$STEP_RC")"
  exit 1
fi
printf 'ran step=1\n'
if ! run_step "${STEP2[@]}"; then
  reason=$(step_reason "$STEP_RC")
  if [ "$STEP_RC" -eq 255 ]; then
    reason="$reason (completion unknown; the charter and route are kept, send the same order again to reconcile)"
  else
    remove_own_brief
  fi
  printf 'failed step=2: %s\n' "$reason"
  exit 1
fi
printf 'ran step=2\n'
if ! run_step "${STEP3[@]}"; then
  printf 'failed step=3: %s (the home is seeded; relaunch with: %s)\n' "$(step_reason "$STEP_RC")" "$(render "${STEP3[@]}")"
  exit 1
fi
printf 'ran step=3\n'
printf 'done id=%s\n' "$ID"
