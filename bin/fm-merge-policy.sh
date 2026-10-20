#!/usr/bin/env bash
# fm-merge-policy.sh - the captain's per-repository merge policy.
#
# Usage: fm-merge-policy.sh get <owner/repo> [--json]
#        fm-merge-policy.sh set <owner/repo|owner/*|*> <auto|ask|never> [--note <text>] [--by <who>] [--no-push]
#        fm-merge-policy.sh list [--json]
#        fm-merge-policy.sh --help
#
# Policies:
#   auto   merge as soon as the full no-mistakes pipeline has passed and CI is
#          green, through the normal merge path, then deploy per the existing
#          rules; such a PR never becomes a merge decision card;
#   ask    the merge is the captain's decision (one card);
#   never  never merge it; the captain merges it himself.
# Production promotion is separate from merging and always stays the captain's.
#
# The policy lives in the primary home's config/merge-policy.json and reaches
# every second mate home as inherited config through bin/fm-config-push.sh.
# Shape (all keys optional; Fleet Town reads and edits the same file):
#   {"version": 1,
#    "default": "ask",
#    "owners": {"bastotec": "auto", "brunobasto": "auto"},
#    "repos": {"DocanaAI/docana": {"policy": "ask", "set": "2026-10-20T12:00:00Z",
#                                   "by": "captain", "note": "..."}}}
# A repository resolves to its own "repos" entry, else its owner's "owners"
# entry, else "default"; names compare case-insensitively. With no file, or a
# key missing from it, the built-in defaults are the ones shown above: bastotec
# and brunobasto repositories are auto and everything else is ask.
#
# get prints the policy and where it came from ("auto repo", "auto owner
# bastotec", "ask default"), or with --json {"repo","policy","source"}.
# set validates the name and policy, writes the file atomically under
# config/.merge-policy.lock with the entry dated, appends one audit line to
# data/merge-policy.log ("<utc> <who> <name> <old> -> <new> <note>"), and in
# the primary home (data/secondmates.md present) pushes it to the second mate
# homes unless --no-push. "owner/*" sets an owner's entry and "*" the default.
# The writer lock is reclaimed when older than 60 seconds or its recorded PID
# is dead. Merge paths read without locking immediately before each command:
# a policy change cannot stop a merge command already in flight, only later ones.
# list prints the default, owners and repositories. list --json prints
#   {"version":1,"default":..,"owners":{..},"repos":[{"repo","policy",
#    "source":"set|owner|default","by","at":<epoch|null>,"note"}]}
# where repos covers every repository with its own entry plus every one the
# fleet touches: origin remotes of this home's and the local second mate homes'
# project clones, and config/autoland.json repositories. The stored file keeps
# the compact shape above; readers that want every repository use list --json.
#
# Exit: 0 on success, 1 when the file is unreadable or the write fails, 2 on
# invalid use.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DATA_DIR="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
FILE="$CONFIG_DIR/merge-policy.json"
LOCK="$CONFIG_DIR/.merge-policy.lock"
BUILTIN='{"version":1,"default":"ask","owners":{"bastotec":"auto","brunobasto":"auto"},"repos":{}}'

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() { printf 'fm-merge-policy: %s\n' "$*" >&2; exit "${2:-2}"; }

valid_policy() { case "$1" in auto|ask|never) return 0 ;; *) return 1 ;; esac; }

writer_lock_hold() {
  local tries=0 pid mtime age dead
  until mkdir "$LOCK" 2>/dev/null; do
    pid=$(cat "$LOCK/pid" 2>/dev/null || true)
    dead=false
    case "$pid" in
      ''|*[!0-9]*|0) ;;
      *) kill -0 "$pid" 2>/dev/null || dead=true ;;
    esac
    if [ "$(uname)" = Darwin ]; then
      mtime=$(/usr/bin/stat -f %m "$LOCK" 2>/dev/null || true)
    else
      mtime=$(stat -c %Y "$LOCK" 2>/dev/null || true)
    fi
    age=0
    case "$mtime" in ''|*[!0-9]*) ;; *) age=$(( $(date +%s) - mtime )) ;; esac
    if [ "$age" -gt 60 ] || [ "$dead" = true ]; then
      rm -f "$LOCK/pid"
      rmdir "$LOCK" 2>/dev/null || true
    fi
    tries=$((tries + 1))
    [ "$tries" -lt 50 ] || return 1
    sleep 0.1
  done
  printf '%s\n' "$$" > "$LOCK/pid" || { rmdir "$LOCK"; return 1; }
}

writer_lock_release() {
  [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] || return 0
  rm -f "$LOCK/pid"
  rmdir "$LOCK"
}

# The effective document: the built-in defaults overlaid with the file.
effective() {
  local doc dir=$CONFIG_DIR
  while [ ! -e "$dir" ] && [ ! -L "$dir" ]; do
    dir=$(dirname "$dir")
  done
  [ -d "$dir" ] && [ -x "$dir" ] || die "$FILE is not readable" 1
  if [ -e "$FILE" ] || [ -L "$FILE" ]; then
    [ -f "$FILE" ] && [ -r "$FILE" ] || die "$FILE is not a readable regular file" 1
    doc=$(jq -c --argjson b "$BUILTIN" '
      if type != "object" then error("not an object") else . end
      | {version: 1,
         default: (.default // $b.default),
         owners: ($b.owners + ((.owners // {}) | with_entries(.key |= ascii_downcase))),
         repos: (.repos // {})}' "$FILE" 2>/dev/null) \
      || die "$FILE is not valid JSON" 1
  else
    doc=$BUILTIN
  fi
  printf '%s' "$doc" | jq -e '
    (.default | IN("auto","ask","never"))
    and ([.owners[]] | all(IN("auto","ask","never")))
    and ([.repos[] | .policy] | all(IN("auto","ask","never")))' >/dev/null 2>&1 \
    || die "$FILE holds a policy other than auto, ask or never" 1
  printf '%s' "$doc"
}

cmd_get() {
  local repo=${1:-} json=0
  [ $# -ge 1 ] || { usage >&2; exit 2; }
  shift
  [ "${1:-}" = --json ] && json=1
  printf '%s' "$repo" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' || die "expected owner/repo, got: $repo"
  local doc
  doc=$(effective) || exit 1
  printf '%s' "$doc" | jq -r --arg r "$repo" --argjson json "$json" '
    ($r | ascii_downcase) as $key
    | ($key | split("/")[0]) as $owner
    | ([.repos | to_entries[] | select(.key | ascii_downcase == $key) | .value.policy] | first) as $rp
    | ([.owners | to_entries[] | select(.key | ascii_downcase == $owner) | .value] | first) as $op
    | (if $rp != null then {policy: $rp, source: "repo"}
       elif $op != null then {policy: $op, source: ("owner " + $owner)}
       else {policy: .default, source: "default"} end) as $res
    | if $json == 1 then ({repo: $r} + $res | tojson) else "\($res.policy) \($res.source)" end'
}

# Repositories the fleet touches: origin remotes of this home's and the local
# second mate homes' project clones, plus config/autoland.json repositories.
touched_repos() {
  local dir meta home url
  {
    for dir in "$FM_HOME"/projects/*/; do
      [ -d "$dir" ] && git -C "$dir" remote get-url origin 2>/dev/null
    done
    for meta in "${FM_STATE_OVERRIDE:-$FM_HOME/state}"/*.meta; do
      [ -f "$meta" ] || continue
      grep -qx 'kind=secondmate' "$meta" 2>/dev/null || continue
      grep -q '^remote_host=.' "$meta" 2>/dev/null && continue
      home=$(sed -n 's/^home=//p' "$meta" | tail -1)
      [ -n "$home" ] || continue
      for dir in "$home"/projects/*/; do
        [ -d "$dir" ] && git -C "$dir" remote get-url origin 2>/dev/null
      done
    done
    [ -f "$CONFIG_DIR/autoland.json" ] && jq -r '.repos[]?.repo // empty' "$CONFIG_DIR/autoland.json" 2>/dev/null
  } | while IFS= read -r url; do
    printf '%s\n' "$url" | sed -nE 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)$#\2#p; /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/p' | sed 's/\.git$//'
  done
}

cmd_list() {
  local doc
  doc=$(effective) || exit 1
  if [ "${1:-}" = --json ]; then
    touched_repos | jq -R . | jq -s --argjson doc "$doc" '
      def epoch: if . == null then null else (try fromdateiso8601 catch null) end;
      ($doc.repos | keys) as $set
      | ([.[], $set[]] | map(select(. != "")) | group_by(ascii_downcase) | map(
          (map(select(. as $n | $set | index($n))) | first) // first)) as $names
      | {version: 1, default: $doc.default, owners: $doc.owners,
         repos: [ $names[] as $r
           | ($r | ascii_downcase) as $key
           | ($key | split("/")[0]) as $owner
           | ([$doc.repos | to_entries[] | select(.key | ascii_downcase == $key) | .value] | first) as $entry
           | ([$doc.owners | to_entries[] | select(.key | ascii_downcase == $owner) | .value] | first) as $op
           | if $entry != null then
               {repo: $r, policy: $entry.policy, source: "set", by: ($entry.by // null),
                at: ($entry.set | epoch), note: ($entry.note // null)}
             elif $op != null then {repo: $r, policy: $op, source: "owner", by: null, at: null, note: null}
             else {repo: $r, policy: $doc.default, source: "default", by: null, at: null, note: null} end ]
           | sort_by(.repo | ascii_downcase)}'
    return
  fi
  printf '%s' "$doc" | jq -r '
    "default \(.default)",
    (.owners | to_entries[] | "owner \(.key)/* \(.value)"),
    (.repos | to_entries[] | "repo \(.key) \(.value.policy)\(if .value.set then " (set \(.value.set))" else "" end)")'
}

cmd_set() {
  local name=${1:-} policy=${2:-} note='' by=${FM_MERGE_POLICY_BY:-firstmate} push=1 kind old now tmp doc
  [ $# -ge 2 ] || { usage >&2; exit 2; }
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --note) [ $# -ge 2 ] || die "--note needs a value"; note=$2; shift 2 ;;
      --by) [ $# -ge 2 ] || die "--by needs a value"; by=$2; shift 2 ;;
      --no-push) push=0; shift ;;
      *) die "unknown option: $1" ;;
    esac
  done
  valid_policy "$policy" || die "policy must be auto, ask or never, got: $policy"
  if [ "$name" = '*' ]; then
    kind=default
  elif printf '%s' "$name" | grep -Eq '^[A-Za-z0-9_.-]+/\*$'; then
    kind=owner
  elif printf '%s' "$name" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
    kind=repo
  else
    die "expected owner/repo, owner/* or *, got: $name"
  fi
  case "$by$note" in *$'\n'*) die "--by and --note must be one line" ;; esac
  mkdir -p "$CONFIG_DIR" "$DATA_DIR" || die "cannot create $CONFIG_DIR" 1
  writer_lock_hold || die "the merge policy could not be locked ($LOCK)" 1
  trap 'writer_lock_release || true' EXIT
  if [ -f "$FILE" ]; then
    doc=$(jq -c '.' "$FILE" 2>/dev/null) || die "$FILE is not valid JSON" 1
  else
    doc=$BUILTIN
  fi
  case "$kind" in
    repo) old=$(cmd_get "$name") || die "$FILE is not readable" 1; old=${old%% *} ;;
    owner) old=$(effective | jq -r --arg o "${name%/*}" '.owners[$o | ascii_downcase] // "unset"') ;;
    default) old=$(printf '%s' "$doc" | jq -r '.default // "ask"') ;;
  esac
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  doc=$(printf '%s' "$doc" | jq --arg kind "$kind" --arg name "$name" --arg p "$policy" \
      --arg now "$now" --arg by "$by" --arg note "$note" '
    .version = 1
    | if $kind == "default" then .default = $p
      elif $kind == "owner" then .owners = ((.owners // {} | with_entries(.key |= ascii_downcase))
        + {($name | split("/")[0] | ascii_downcase): $p})
      else .repos = ((.repos // {})
        | with_entries(select(.key | ascii_downcase != ($name | ascii_downcase)))
        + {($name): ({policy: $p, set: $now, by: $by} + (if $note == "" then {} else {note: $note} end))})
      end') || die "could not update the policy" 1
  tmp=$(mktemp "$FILE.XXXXXX") || die "cannot write $FILE" 1
  if ! { printf '%s\n' "$doc" > "$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$FILE"; }; then
    rm -f "$tmp"
    die "cannot write $FILE" 1
  fi
  printf '%s %s %s %s -> %s %s\n' "$now" "$by" "$name" "$old" "$policy" "$note" >> "$DATA_DIR/merge-policy.log" \
    || die "the policy was written but the audit line could not be appended" 1
  writer_lock_release || true
  trap - EXIT
  printf 'set %s %s -> %s\n' "$name" "$old" "$policy"
  if [ "$push" = 1 ] && [ -f "$DATA_DIR/secondmates.md" ]; then
    FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-config-push.sh" >/dev/null 2>&1 \
      || printf 'warning: pushing the policy to the second mate homes failed; run bin/fm-config-push.sh\n' >&2
  fi
}

case "${1:-}" in
  -h|--help) usage ;;
  get) shift; cmd_get "$@" ;;
  set) shift; cmd_set "$@" ;;
  list) shift; cmd_list "$@" ;;
  *) usage >&2; exit 2 ;;
esac
