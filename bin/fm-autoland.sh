#!/usr/bin/env bash
# fm-autoland.sh - land green PRs as soon as they are ready, then deploy them.
#
# Usage:
#   fm-autoland.sh [check]               one watcher tick (what the armed shim runs)
#   fm-autoland.sh arm                   write and register state/autoland.check.sh
#   fm-autoland.sh disarm                remove the shim and its trust binding
#   fm-autoland.sh status                print repos, authority, deploy records, last report
#   fm-autoland.sh deploy <hook> [--approved]
#                                        run one post-merge hook now, in the foreground
#   fm-autoland.sh deploy-run <hook> <oid>
#                                        internal: the detached runner a tick starts
#   fm-autoland.sh --help
#
# A zero-token watcher check. bin/fm-watch.sh runs the armed shim every
# FM_AUTOLAND_INTERVAL seconds (default 90) between its full check sweeps, and
# turns the one line this prints into a `check:` wake. A tick prints nothing
# when nothing needs the supervisor.
#
# Configuration is the home's private config/autoland.json (schema and the
# post-merge hook contract: docs/configuration.md "Auto-land"). Each entry names
# one GitHub repository and where its standing merge authority comes from:
# "project" ties it to that data/projects.md entry, which must carry +yolo at
# tick time (fm-project-mode.sh), and "authority" cites a captain ruling that
# grants it outright. An entry with "hook" also gets post-merge deployment.
#
# Each tick makes one GraphQL call: a search for open PRs authored by the
# authenticated account in the configured owners, plus every hooked repository's
# default-branch head. Only fleet-authored PRs into a configured repository's
# default branch are considered.
#
# Landing. A PR merges when it is not a draft, GitHub reports it MERGEABLE and
# not BLOCKED, BEHIND, or DIRTY, every check on its head is green
# (fm_pr_github_checks_not_green in bin/fm-pr-lib.sh; at least one check must
# exist), no hold label is set, and - for an entry with "attestation": true or
# a registered no-mistakes/no-mistakes-prod-only project - its no-mistakes
# attestation is bound to the current head with review, test,
# and document finished and its stated risk is at or under "max_risk" (default
# low). A PR owned by a task in this home merges through bin/fm-pr-merge.sh, so
# captain holds, away posture, and merge records apply unchanged; any other PR
# is re-read live and merged with gh pinned to the verified head. Pending or red
# checks are left to the PR's owner and stay silent. A green PR that cannot
# land - a draft, a stale or incomplete attestation, a risk above the cap, a
# hold label, conflicts, a required review, a refused merge - produces one
# "green PR not landing: <url> because <reason>" line, repeated only when its
# head or reason changes or after FM_AUTOLAND_RENOTIFY seconds (default 21600).
# Merges stop starting once FM_AUTOLAND_MERGE_BUDGET seconds (default 12) of
# merge work after the query/deploy scan are spent; the rest land next tick.
# Each complete merge operation is also bounded to
# the time remaining before FM_CHECK_TIMEOUT minus three seconds.
# A Pi supervision branch's watcher
# (FM_SUPERVISION_ACTOR=branch) skips the tick, because merging is main-owned.
#
# Deploying. For a hooked entry whose default-branch head differs from the
# commit recorded in state/autoland/<hook>.deployed, the tick starts a detached
# runner (its own session, so the watcher's per-check process-group kill cannot
# reach it). That covers merges made here, by a person, or by anyone else. The
# runner refreshes the project's clone through bin/fm-fleet-sync.sh when this
# home has one, then runs config/post-merge/<hook>.sh <oid> under
# FM_AUTOLAND_HOOK_TIMEOUT (default 1800). Exit 0 records the commit as
# deployed, exit 75 records a deferral that later ticks retry every
# FM_AUTOLAND_DEFER_RETRY seconds (default 300), and anything else records a
# failure that is reported once and not retried until the head moves or an
# operator runs `deploy`. The hook's last output line is its summary; its full
# output is state/autoland/<hook>.log. One runner per hook at a time
# (state/autoland/<hook>.lock).
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG="$CONFIG_DIR/autoland.json"
HOOK_DIR="$CONFIG_DIR/post-merge"
AL="$STATE/autoland"
CHECK_ID=autoland
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
MAX_LINE=600

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

num_or() {  # <value> <default>
  case "$1" in ''|*[!0-9]*|0) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}

RENOTIFY=$(num_or "${FM_AUTOLAND_RENOTIFY:-}" 21600)
MERGE_BUDGET=$(num_or "${FM_AUTOLAND_MERGE_BUDGET:-}" 12)
HOOK_TIMEOUT=$(num_or "${FM_AUTOLAND_HOOK_TIMEOUT:-}" 1800)
DEFER_RETRY=$(num_or "${FM_AUTOLAND_DEFER_RETRY:-}" 300)
QUERY_TIMEOUT=$(num_or "${FM_AUTOLAND_QUERY_TIMEOUT:-}" 15)

MSGS=
NOTIFY_KEYS=
MERGE_DEADLINE=0

add_msg() {
  MSGS="${MSGS:+$MSGS; }$1"
}

# ---------------------------------------------------------------------------
# Notification memory: one "<epoch>\t<key>" line per reported item.

notified_recent() {  # <key> <window-seconds; 0 = forever>
  local key=$1 window=$2 line epoch k t
  [ -f "$AL/notified" ] || return 1
  t=$(date +%s)
  while IFS= read -r line; do
    epoch=${line%%$'\t'*}
    k=${line#*$'\t'}
    [ "$k" = "$key" ] || continue
    if [ "$window" -eq 0 ] || [ $((t - epoch)) -lt "$window" ]; then
      return 0
    fi
  done < "$AL/notified"
  return 1
}

notified_record() {  # <key>
  local tmp
  tmp=$(mktemp "$AL/.notified.XXXXXX") || return 1
  {
    [ -f "$AL/notified" ] && awk -F '\t' -v k="$1" '$2 != k' "$AL/notified" | tail -n 499
    printf '%s\t%s\n' "$(date +%s)" "$1"
  } > "$tmp" && mv -f -- "$tmp" "$AL/notified"
}

notify() {  # <key> <window> <message>
  notified_recent "$1" "$2" && return 0
  add_msg "$3"
  NOTIFY_KEYS="${NOTIFY_KEYS:+$NOTIFY_KEYS
}$1"
}

# ---------------------------------------------------------------------------
# Configuration.

CONFIG_ERROR=

# Fields are joined with the unit separator (US, \037), never a tab: a tab is
# IFS whitespace, so `read` would collapse an empty field into its neighbour.
US=$'\037'

config_entries() {  # prints repo US project US authority US method US attestation US max_risk US hook
  CONFIG_ERROR=
  if [ ! -f "$CONFIG" ]; then
    CONFIG_ERROR="config/autoland.json is missing"
    return 1
  fi
  if ! jq -e '
      (.repos | type == "array" and length > 0)
      and (.repos | all(.[];
        type == "object"
        and (.repo | type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"))
        and (((.project // null) | type == "string") or ((.authority // null) | type == "string"))
        and ((.project // "") | test("^[A-Za-z0-9_.-]*$"))
        and ((.method // "squash") | IN("squash", "merge", "rebase"))
        and ((.max_risk // "low") | IN("low", "medium", "high"))
        and ((.attestation // false) | type == "boolean")
        and ((.hook // "") | test("^([a-z0-9][a-z0-9._-]*)?$"))))
      and ([.repos[].repo | ascii_downcase] | length == (unique | length))
      and ([.repos[].hook // "" | select(. != "")] | length == (unique | length))
    ' "$CONFIG" >/dev/null 2>&1; then
    CONFIG_ERROR="config/autoland.json is not valid (see docs/configuration.md \"Auto-land\")"
    return 1
  fi
  jq -r '.repos[] | [.repo, (.project // ""), (.authority // ""), (.method // "squash"),
    ((.attestation // false) | tostring), (.max_risk // "low"), (.hook // "")] | join("\u001f")' "$CONFIG"
}

# 0 when the entry carries standing merge authority right now.
entry_authorized() {  # <project> <authority>
  local project=$1 authority=$2 posture
  [ -n "$authority" ] && return 0
  [ -n "$project" ] || return 1
  posture=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-project-mode.sh" "$project" 2>/dev/null) || return 1
  [ "${posture##* }" = on ]
}

entry_attestation() {
  local project=$1 configured=$2 posture
  if [ "$configured" = true ]; then
    printf 'true\n'
    return
  fi
  if [ -n "$project" ]; then
    posture=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-project-mode.sh" --raw "$project" 2>/dev/null) || posture='no-mistakes off'
    case "${posture%% *}" in
      direct-PR|local-only) ;;
      *) printf 'true\n'; return ;;
    esac
  fi
  printf 'false\n'
}

risk_rank() {
  case "$1" in none|low) echo 1 ;; medium) echo 2 ;; high) echo 3 ;; *) echo 9 ;; esac
}

# ---------------------------------------------------------------------------
# The one GraphQL call per tick.

# shellcheck disable=SC2016  # GraphQL variables, not shell expansions.
build_query() {  # <entries-file>; prints the query text
  local i=0 repo owner name
  printf '%s\n' 'query($q: String!) {' \
    '  search(query: $q, type: ISSUE, first: 100) { nodes { ... on PullRequest {' \
    '    url isDraft mergeable mergeStateStatus headRefOid baseRefName body' \
    '    repository { nameWithOwner defaultBranchRef { name } }' \
    '    labels(first: 20) { nodes { name } }' \
    '    commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) { nodes {' \
    '      __typename' \
    '      ... on CheckRun { name status conclusion startedAt }' \
    '      ... on StatusContext { context state }' \
    '    } } } } } }' \
    '  } } }'
  while IFS=$US read -r repo _ _ _ _ _ hook; do
    [ -n "$hook" ] || continue
    owner=${repo%%/*}
    name=${repo#*/}
    printf '  r%s: repository(owner: "%s", name: "%s") { nameWithOwner defaultBranchRef { target { oid } } }\n' \
      "$i" "$owner" "$name"
    i=$((i + 1))
  done < "$1"
  printf '}\n'
}

search_string() {  # <entries-file>
  local owners
  owners=$(cut -d "$US" -f1 "$1" | cut -d/ -f1 | sort -fu | sed 's/^/user:/' | tr '\n' ' ')
  printf 'is:pr is:open archived:false author:@me %s\n' "${owners% }"
}

# Normalize one search node (or a live `gh pr view` object) into the record the
# landing decision reads. The attestation and risk come from the PR body that
# no-mistakes writes.
# shellcheck disable=SC2016  # jq program text.
PR_JQ='
  def attest($head):
    try (
    ([(.body // "") | scan("<!-- no-mistakes-pipeline-attestation:v1 (\\{.*?\\}) -->")] | last) as $m
    | if $m == null then "missing"
      else ($m[0] | fromjson) as $j
      | if ($j | type) != "object" then "unreadable"
        elif ($j.head_sha // "") != $head then "stale:" + (($j.head_sha // "none")[0:7])
        else ([$j.steps[]? | {(.step): .status}] | add // {}) as $s
        | if ($s.review // "") != "completed" then "incomplete:review " + ($s.review // "missing")
          elif (($s.test // "") | IN("completed", "skipped") | not) then "incomplete:test " + ($s.test // "missing")
          elif ($s.document // "") != "completed" then "incomplete:document " + ($s.document // "missing")
          else "ok" end
        end
      end) catch "unreadable";
  def risk:
    (((.body // "") | capture("## Risk Assessment[ \t]*\r?\n[ \t\r\n]*(?<r>[^\n]*)")? | .r) // null) as $r
    | if $r == null then "none"
      else ($r | capture("^\\s*(?:\\S+\\s+)?(?<l>Low|Medium|High)\\b")? | .l | ascii_downcase) // "unknown"
      end;
  . as $pr
  | {
      url,
      repo: (.repository.nameWithOwner // ""),
      default: (.repository.defaultBranchRef.name // ""),
      base: (.baseRefName // ""),
      head: (.headRefOid // ""),
      draft: (.isDraft | tostring),
      mergeable: (.mergeable // ""),
      merge_state: (.mergeStateStatus // ""),
      labels: ([(if (.labels | type) == "object" then .labels.nodes else .labels end // [])[]?.name] | join(",")),
      attest: attest(.headRefOid // ""),
      risk: risk,
      rollup: (if has("statusCheckRollup") then .statusCheckRollup
               else .commits.nodes[0].commit.statusCheckRollup.contexts.nodes end // [])
    }'

hold_label() {  # <csv labels>; prints the first hold label
  printf '%s\n' "$1" | tr ',' '\n' \
    | grep -iE '^(do[- ]?not[- ]?merge|hold|on[- ]hold|wip|blocked|security|destructive|breaking([- ]change)?)$' \
    | head -n 1
}

# Decide one normalized PR. Sets VERDICT (merge|hold|skip) and REASON.
VERDICT=
REASON=
decide() {  # <record-json> <attestation> <max_risk>
  local rec=$1 need_attest=$2 max_risk=$3 fields head draft mergeable mstate attest risk labels red count lbl
  VERDICT=skip
  REASON=
  fields=$(printf '%s' "$rec" | jq -r '[.head, .draft, .mergeable, .merge_state, .attest, .risk, (.rollup | length | tostring), .labels] | join("\u001f")') || return 0
  IFS=$US read -r head draft mergeable mstate attest risk count labels <<EOF
$fields
EOF
  red=$(fm_pr_github_checks_not_green "$(printf '%s' "$rec" | jq -c '{statusCheckRollup: .rollup}')") || return 0
  if [ -n "$red" ]; then
    return 0   # pending or failing checks belong to the PR's owner
  fi
  if [ "$count" -eq 0 ]; then
    VERDICT=hold
    REASON="no CI checks are reported on its head"
    return 0
  fi
  if [ "$draft" = true ]; then
    VERDICT=hold
    REASON="it is still a draft"
    return 0
  fi
  if [ "$need_attest" = true ] && [ "$attest" != ok ]; then
    VERDICT=hold
    case "$attest" in
      missing) REASON="it carries no no-mistakes attestation" ;;
      unreadable) REASON="its no-mistakes attestation cannot be read" ;;
      stale:*) REASON="its no-mistakes attestation is for ${attest#stale:}, not the current head $(short "$head")" ;;
      incomplete:*) REASON="its no-mistakes attestation shows ${attest#incomplete:}" ;;
      *) REASON="its no-mistakes attestation is $attest" ;;
    esac
    return 0
  fi
  if [ "$need_attest" = true ] && [ "$risk" = none ]; then
    VERDICT=hold
    REASON="its no-mistakes risk assessment is missing"
    return 0
  fi
  if [ "$(risk_rank "$risk")" -gt "$(risk_rank "$max_risk")" ]; then
    VERDICT=hold
    REASON="no-mistakes rated it $risk risk (auto-merge cap: $max_risk)"
    return 0
  fi
  lbl=$(hold_label "$labels")
  if [ -n "$lbl" ]; then
    VERDICT=hold
    REASON="it is labelled $lbl"
    return 0
  fi
  case "$mergeable:$mstate" in
    CONFLICTING:*|*:DIRTY) VERDICT=hold; REASON="it has merge conflicts with its base" ;;
    UNKNOWN:*|*:UNKNOWN|:*) VERDICT=skip ;;
    *:BEHIND) VERDICT=hold; REASON="its branch is behind the base and the repository requires it to be up to date" ;;
    *:BLOCKED) VERDICT=hold; REASON="GitHub reports it blocked by a branch rule such as a required review" ;;
    MERGEABLE:CLEAN|MERGEABLE:HAS_HOOKS|MERGEABLE:UNSTABLE) VERDICT=merge ;;
    *) VERDICT=hold; REASON="GitHub reports mergeable=$mergeable, state=$mstate" ;;
  esac
}

TASK_PR_ID=
TASK_PR_URL=
task_for_pr() {  # <url>; sets TASK_PR_ID and TASK_PR_URL for the owning task in this home
  local m repo number recorded
  TASK_PR_ID=
  TASK_PR_URL=
  fm_pr_url_parse "$1" && [ "$FM_PR_PROVIDER" = github ] || return 1
  repo=$(printf '%s/%s' "$FM_PR_OWNER" "$FM_PR_REPO" | tr '[:upper:]' '[:lower:]')
  number=$FM_PR_NUMBER
  for m in "$STATE"/*.meta; do
    [ -f "$m" ] || continue
    recorded=$(grep '^pr=' "$m" | tail -n 1 | cut -d= -f2-)
    fm_pr_url_parse "$recorded" && [ "$FM_PR_PROVIDER" = github ] || continue
    if [ "$FM_PR_NUMBER" = "$number" ] && [ "$(printf '%s/%s' "$FM_PR_OWNER" "$FM_PR_REPO" | tr '[:upper:]' '[:lower:]')" = "$repo" ]; then
      TASK_PR_ID=$(basename "$m" .meta)
      TASK_PR_URL=$recorded
      return 0
    fi
  done
  return 1
}

MERGE_ERROR=
MERGE_RESULT=
merge_pr() {  # <url> <head> <method> <attestation> <max_risk> <base>
  local remaining out rc=0
  MERGE_ERROR=
  MERGE_RESULT=
  remaining=$((MERGE_DEADLINE - SECONDS))
  [ "$remaining" -ge 2 ] || return 2
  out=$(fm_run_timed "$remaining" env FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-autoland.sh" merge-run "$@" 2>&1) || rc=$?
  case "$rc" in
    0) MERGE_RESULT=merged; return 0 ;;
    3) MERGE_RESULT=queued; return 0 ;;
  esac
  if [ "$rc" -eq 124 ]; then
    MERGE_ERROR="the merge operation timed out before the check deadline"
  else
    MERGE_ERROR=${out:-"the merge operation refused it"}
  fi
  return 1
}

merge_attempt() {  # <url> <head> <method> <attestation> <max_risk> <base>
  local url=$1 head=$2 method=$3 need_attest=$4 max_risk=$5 base=$6 out live rec state queue owned=false
  MERGE_ERROR=
  if ! live=$(gh pr view "$url" \
      --json url,state,isDraft,mergeable,mergeStateStatus,headRefOid,baseRefName,body,labels,statusCheckRollup 2>/dev/null); then
    MERGE_ERROR="its live state could not be read before merging"
    return 1
  fi
  state=$(printf '%s' "$live" | jq -r '.state // ""')
  [ "$state" = OPEN ] || { MERGE_ERROR="it is $state, not open"; return 1; }
  rec=$(printf '%s' "$live" | jq -c "$PR_JQ") || { MERGE_ERROR="its live state could not be parsed"; return 1; }
  if [ "$(printf '%s' "$rec" | jq -r .head)" != "$head" ]; then
    MERGE_ERROR="its head moved while it was being checked"
    return 1
  fi
  if [ "$(printf '%s' "$rec" | jq -r .base)" != "$base" ]; then
    MERGE_ERROR="its base branch changed while it was being checked"
    return 1
  fi
  decide "$rec" "$need_attest" "$max_risk"
  if [ "$VERDICT" != merge ]; then
    MERGE_ERROR=${REASON:-"its live checks are no longer all green"}
    return 1
  fi
  if task_for_pr "$url"; then
    if ! out=$(FM_HOME="$FM_HOME" FM_PR_MERGE_EXPECT_HEAD="$head" FM_PR_MERGE_EXPECT_BASE="$base" "$SCRIPT_DIR/fm-pr-merge.sh" "$TASK_PR_ID" "$TASK_PR_URL" -- "--$method" 2>&1); then
      MERGE_ERROR=$(printf '%s\n' "$out" | grep -m1 -E '^error:|refus' | sed 's/^error: //')
      [ -n "$MERGE_ERROR" ] || MERGE_ERROR="bin/fm-pr-merge.sh refused it"
      return 1
    fi
    owned=true
  elif ! out=$(gh pr merge "$url" "--$method" --match-head-commit "$head" 2>&1); then
    MERGE_ERROR="gh refused the merge: $(printf '%s\n' "$out" | head -n 1)"
    return 1
  fi
  state=$(gh pr view "$url" --json state -q .state 2>/dev/null || true)
  [ "$state" != MERGED ] || return 0
  if [ "$owned" = true ] && [ "$state" = OPEN ]; then
    queue=$(gh api graphql \
      -f "query=query(\$owner:String!,\$repo:String!,\$number:Int!){repository(owner:\$owner,name:\$repo){pullRequest(number:\$number){isInMergeQueue}}}" \
      -F "owner=$FM_PR_OWNER" -F "repo=$FM_PR_REPO" -F "number=$FM_PR_NUMBER" \
      --jq '.data.repository.pullRequest.isInMergeQueue' 2>/dev/null || true)
    [ "$queue" != true ] || return 3
  fi
  MERGE_ERROR="gh accepted the merge but the PR reads as ${state:-unreadable}"
  return 1
}

# ---------------------------------------------------------------------------
# Deploy records and the hook runner.

result_read() {  # <hook>; sets R_STATUS R_OID R_EPOCH R_SUMMARY
  R_STATUS=''
  R_OID=''
  R_EPOCH=0
  R_SUMMARY=''
  [ -f "$AL/$1.result" ] || return 1
  IFS=$'\t' read -r R_STATUS R_OID R_EPOCH R_SUMMARY < "$AL/$1.result" || true
  case "$R_EPOCH" in ''|*[!0-9]*) R_EPOCH=0 ;; esac
  return 0
}

result_write() {  # <hook> <status> <oid> <summary>
  local tmp summary
  summary=$(printf '%s' "$4" | tr '\t\n' '  ')
  fm_cap_line_var "$summary" 200
  tmp=$(mktemp "$AL/.result.XXXXXX") || return 1
  printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$(date +%s)" "$FM_LINE_CAP_LINE" > "$tmp" && mv -f -- "$tmp" "$AL/$1.result"
}

deployed_read() {  # <hook>
  local oid
  oid=$(head -n 1 "$AL/$1.deployed" 2>/dev/null || true)
  fm_pr_head_valid "$oid" && printf '%s\n' "$oid"
  return 0
}

lock_alive() {  # <hook>
  local pid
  pid=$(cat "$AL/$1.lock/pid" 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

lock_take() {  # <hook>
  local d="$AL/$1.lock" guard="$AL/$1.lock.guard" tmp stale rc=1
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_lock_try_acquire "$guard" || return 1
  if lock_alive "$1"; then
    fm_lock_release "$guard"
    return 1
  fi
  if [ -e "$d" ] || [ -L "$d" ]; then
    stale=$(mktemp -d "$AL/.$1.stale.XXXXXX") || { fm_lock_release "$guard"; return 1; }
    if ! mv -- "$d" "$stale/lock"; then
      rmdir "$stale"
      fm_lock_release "$guard"
      return 1
    fi
    rm -rf -- "$stale"
  fi
  tmp=$(mktemp -d "$AL/.$1.lock.XXXXXX") || { fm_lock_release "$guard"; return 1; }
  if printf '%s\n' "$$" > "$tmp/pid" && mv -- "$tmp" "$d"; then
    rc=0
  else
    rm -rf -- "$tmp"
  fi
  fm_lock_release "$guard"
  return "$rc"
}

lock_drop() {
  local d="$AL/$1.lock" guard="$AL/$1.lock.guard" pid
  fm_lock_acquire_wait_bounded "$guard" 2 || return 1
  pid=$(cat "$d/pid" 2>/dev/null || true)
  if [ "$pid" = "$$" ]; then
    rm -f -- "$d/pid"
    rmdir "$d"
  fi
  fm_lock_release "$guard"
}

hook_file_valid() {  # <path>
  local mode
  [ -f "$1" ] && [ -x "$1" ] || return 1
  mode=$(fm_pr_file_mode "$1") || return 1
  # Not writable by group or others.
  case "$mode" in *[2367]?|*[2367]) return 1 ;; esac
  return 0
}

entry_for_hook() {  # <hook>; sets E_REPO E_PROJECT
  local repo project hook
  E_REPO=''
  E_PROJECT=''
  while IFS=$US read -r repo project _ _ _ _ hook; do
    if [ "$hook" = "$1" ]; then
      E_REPO=$repo
      E_PROJECT=$project
      return 0
    fi
  done < <(config_entries 2>/dev/null)
  return 1
}

# Run one hook for one commit; the caller already decided it is due.
# Returns the hook's classification: 0 deployed, 75 deferred, 3 busy, 1 failed.
run_hook() {  # <hook> <oid> <approved 0|1>
  local hook=$1 oid=$2 approved=$3 file log rc summary deployed sync_rc
  mkdir -p "$AL" || return 1
  entry_for_hook "$hook" || { result_write "$hook" failed "$oid" "no config/autoland.json entry names hook $hook"; return 1; }
  lock_take "$hook" || return 3
  file="$HOOK_DIR/$hook.sh"
  log="$AL/$hook.log"
  [ -f "$log" ] && mv -f -- "$log" "$log.prev"
  deployed=$(deployed_read "$hook")
  result_write "$hook" running "$oid" "started"
  {
    printf '== %s autoland deploy %s %s (previously %s)\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$hook" "$oid" "${deployed:-unrecorded}"
    if [ -n "$E_PROJECT" ] && [ -d "$FM_HOME/projects/$E_PROJECT" ]; then
      sync_rc=0
      fm_run_timed 300 env FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-fleet-sync.sh" "$E_PROJECT" 2>&1 || sync_rc=$?
      case "$sync_rc" in
        0) ;;
        124) printf 'fleet sync of projects/%s timed out after 300s (continuing)\n' "$E_PROJECT" ;;
        *) printf 'fleet sync of projects/%s failed (continuing)\n' "$E_PROJECT" ;;
      esac
    fi
  } >> "$log" 2>&1
  if ! hook_file_valid "$file"; then
    result_write "$hook" failed "$oid" "config/post-merge/$hook.sh is missing, not executable, or writable by others"
    lock_drop "$hook"
    return 1
  fi
  rc=0
  ( cd "$AL" && fm_run_timed "$HOOK_TIMEOUT" env FM_HOME="$FM_HOME" FM_AUTOLAND_REPO="$E_REPO" \
      FM_AUTOLAND_CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)" \
      FM_AUTOLAND_TARGET="$oid" FM_AUTOLAND_DEPLOYED="$deployed" FM_AUTOLAND_APPROVED="$approved" \
      "$file" "$oid" ) >> "$log" 2>&1 < /dev/null || rc=$?
  summary=$(grep -v '^[[:space:]]*$' "$log" | tail -n 1)
  case "$rc" in
    0)
      printf '%s\n' "$oid" > "$AL/$hook.deployed.tmp" && mv -f -- "$AL/$hook.deployed.tmp" "$AL/$hook.deployed"
      result_write "$hook" deployed "$oid" "${summary:-done}"
      ;;
    75)
      result_write "$hook" deferred "$oid" "${summary:-deferred}"
      ;;
    124)
      result_write "$hook" failed "$oid" "timed out after ${HOOK_TIMEOUT}s: ${summary:-no output}"
      rc=1
      ;;
    *)
      result_write "$hook" failed "$oid" "exit $rc: ${summary:-no output}"
      rc=1
      ;;
  esac
  lock_drop "$hook"
  return "$rc"
}

spawn_runner() {  # <hook> <oid>
  # A new session, so the watcher's process-group kill after this check
  # returns cannot reach the runner.
  FM_HOME="$FM_HOME" perl -e 'use POSIX (); my $pid = fork; exit 0 if $pid; exit 1 unless defined $pid; POSIX::setsid(); open STDIN, "<", "/dev/null"; open STDOUT, ">", "/dev/null"; open STDERR, ">", "/dev/null"; exec @ARGV or exit 127' \
    "$SCRIPT_DIR/fm-autoland.sh" deploy-run "$1" "$2"
}

short() { printf '%s' "${1:0:7}"; }

tick_deploys() {  # <entries-file> <response-file>
  local i=0 repo project hook oid deployed
  while IFS=$US read -r repo project _ _ _ _ hook; do
    [ -n "$hook" ] || continue
    oid=$(jq -r --arg k "r$i" '.data[$k].defaultBranchRef.target.oid // ""' "$2")
    i=$((i + 1))
    if result_read "$hook"; then
      if [ "$R_STATUS" = running ] && lock_take "$hook"; then
        if result_read "$hook" && [ "$R_STATUS" = running ]; then
          result_write "$hook" failed "$R_OID" "the deploy runner stopped before finishing"
        fi
        lock_drop "$hook"
        result_read "$hook"
      fi
      case "$R_STATUS" in
        deployed) notify "deploy|$hook|$R_OID|deployed" 0 "deployed $hook $(short "$R_OID"): $R_SUMMARY" ;;
        deferred) notify "deploy|$hook|$R_OID|deferred" 0 "deploy of $hook $(short "$R_OID") deferred: $R_SUMMARY" ;;
        failed) notify "deploy|$hook|$R_OID|failed|$R_EPOCH" 0 "deploy of $hook $(short "$R_OID") FAILED: $R_SUMMARY (log state/autoland/$hook.log; retry bin/fm-autoland.sh deploy $hook)" ;;
      esac
    fi
    fm_pr_head_valid "$oid" || continue
    deployed=$(deployed_read "$hook")
    [ "$oid" = "$deployed" ] && continue
    lock_alive "$hook" && continue
    if result_read "$hook" && [ "$R_OID" = "$oid" ]; then
      case "$R_STATUS" in
        failed) continue ;;
        deferred) [ $(($(date +%s) - R_EPOCH)) -ge "$DEFER_RETRY" ] || continue ;;
      esac
    fi
    spawn_runner "$hook" "$oid" || add_msg "could not start the $hook deploy runner"
  done < "$1"
}

# ---------------------------------------------------------------------------
# One tick.

action_check() {
  local entries resp check_timeout
  check_timeout=$(num_or "${FM_CHECK_TIMEOUT:-}" 30)
  MERGE_DEADLINE=$((SECONDS + check_timeout - 3))
  # Merging is main-owned (bin/fm-lease-lib.sh); a Pi supervision branch's
  # watcher leaves auto-land to main's.
  [ "${FM_SUPERVISION_ACTOR:-main}" = branch ] && return 0
  mkdir -p "$AL" || return 1
  entries=$(mktemp "$AL/.entries.XXXXXX") || return 1
  resp=$(mktemp "$AL/.response.XXXXXX") || { rm -f -- "$entries"; return 1; }
  tick "$entries" "$resp"
  rm -f -- "$entries" "$resp"
  emit
}

tick() {  # <entries-file> <response-file>
  local entries=$1 resp=$2 query search err rc nodes rec url repo head base entry project authority method attest max_risk hook started tick_epoch
  if ! config_entries > "$entries"; then
    notify "config|$CONFIG_ERROR" "$RENOTIFY" "autoland is armed but $CONFIG_ERROR"
    return 0
  fi
  query=$(build_query "$entries")
  search=$(search_string "$entries")
  rc=0
  err=$(fm_run_timed "$QUERY_TIMEOUT" gh api graphql -f query="$query" -f q="$search" 2>&1 > "$resp") || rc=$?
  if [ "$rc" -ne 0 ] || ! jq -e '.data.search.nodes | type == "array"' "$resp" >/dev/null 2>&1; then
    [ "$rc" -eq 124 ] && err="no answer within ${QUERY_TIMEOUT}s"
    err=$(printf '%s\n' "$err" | head -n 1)
    # Transient API trouble is retried every tick; it is only worth a wake once
    # it has persisted for an hour.
    if [ ! -f "$AL/query-failing-since" ]; then
      date +%s > "$AL/query-failing-since"
    elif [ $(($(date +%s) - $(cat "$AL/query-failing-since" 2>/dev/null || date +%s))) -ge 3600 ]; then
      notify "query-failing" "$RENOTIFY" "autoland cannot read GitHub for over an hour: ${err:-unreadable response}"
    fi
    return 0
  fi
  rm -f -- "$AL/query-failing-since"

  tick_deploys "$entries" "$resp"

  started=$SECONDS
  tick_epoch=$(( $(date +%s) / $(num_or "${FM_AUTOLAND_INTERVAL:-}" 90) ))
  nodes=$(jq -c --argjson tick "$tick_epoch" "[.data.search.nodes[] | select(.url) | $PR_JQ]"'
    | length as $n
    | if $n == 0 then empty
      else ($tick % $n) as $start | (.[$start:] + .[:$start])[] end' "$resp")
  while IFS= read -r rec; do
    [ -n "$rec" ] || continue
    url=$(printf '%s' "$rec" | jq -r .url)
    repo=$(printf '%s' "$rec" | jq -r .repo)
    head=$(printf '%s' "$rec" | jq -r .head)
    base=$(printf '%s' "$rec" | jq -r .base)
    entry=$(awk -F "$US" -v r="$repo" 'tolower($1) == tolower(r)' "$entries" | head -n 1)
    [ -n "$entry" ] || continue
    IFS=$US read -r _ project authority method attest max_risk hook <<EOF
$entry
EOF
    [ "$(printf '%s' "$rec" | jq -r '.base == .default')" = true ] || continue
    entry_authorized "$project" "$authority" || continue
    attest=$(entry_attestation "$project" "$attest")
    decide "$rec" "$attest" "$max_risk"
    case "$VERDICT" in
      hold)
        notify "hold|$url|$head|$REASON" "$RENOTIFY" "green PR not landing: $url because $REASON"
        ;;
      merge)
        if [ $((SECONDS - started)) -ge "$MERGE_BUDGET" ] || [ $((MERGE_DEADLINE - SECONDS)) -lt 2 ]; then
          continue
        fi
        if merge_pr "$url" "$head" "$method" "$attest" "$max_risk" "$base"; then
          if [ "$MERGE_RESULT" = queued ]; then
            notify "queued|$url|$head" 0 "queued $url in GitHub's merge queue"
          else
            notify "merged|$url" 0 "merged $url${hook:+ (deploy follows)}"
          fi
        else
          notify "hold|$url|$head|$MERGE_ERROR" "$RENOTIFY" "green PR not landing: $url because $MERGE_ERROR"
        fi
        ;;
    esac
  done <<EOF
$nodes
EOF
}

emit() {
  local key
  [ -n "$MSGS" ] || return 0
  printf '%s autoland: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MSGS" >> "$AL/report.log" 2>/dev/null || true
  tail -n 200 "$AL/report.log" > "$AL/.report.tmp" 2>/dev/null && mv -f -- "$AL/.report.tmp" "$AL/report.log"
  fm_cap_line_var "autoland: $MSGS" "$MAX_LINE"
  if [ "$FM_LINE_CAP_LINE" != "autoland: $MSGS" ]; then
    printf '%s (full: bin/fm-autoland.sh status)\n' "$FM_LINE_CAP_LINE" || return 1
  else
    printf '%s\n' "$FM_LINE_CAP_LINE" || return 1
  fi
  while IFS= read -r key; do
    [ -z "$key" ] || notified_record "$key" || true
  done <<EOF
$NOTIFY_KEYS
EOF
}

# ---------------------------------------------------------------------------
# Operator commands.

action_deploy() {  # <hook> [--approved]
  local hook=${1:-} approved=0 oid rc
  [ -n "$hook" ] || { printf 'fm-autoland: deploy needs a hook name\n' >&2; return 2; }
  [ "${2:-}" = --approved ] && approved=1
  if ! entry_for_hook "$hook"; then
    printf 'fm-autoland: no config/autoland.json entry has hook "%s"\n' "$hook" >&2
    return 2
  fi
  oid=$(fm_run_timed 15 gh api "repos/$E_REPO/commits/HEAD" --jq .sha 2>/dev/null || true)
  fm_pr_head_valid "$oid" || { printf 'fm-autoland: cannot read the default-branch head of %s\n' "$E_REPO" >&2; return 1; }
  rc=0
  run_hook "$hook" "$oid" "$approved" || rc=$?
  if [ "$rc" -eq 3 ]; then
    printf 'fm-autoland: a %s deploy is already running\n' "$hook" >&2
    return 1
  fi
  result_read "$hook"
  printf '%s %s %s: %s\n' "$hook" "$R_STATUS" "$(short "$R_OID")" "$R_SUMMARY" || return 1
  printf 'log: %s\n' "$AL/$hook.log" || return 1
  # The operator is looking at this outcome now, so later ticks do not repeat it.
  case "$R_STATUS" in
    failed) notified_record "deploy|$hook|$R_OID|failed|$R_EPOCH" || true ;;
    *) notified_record "deploy|$hook|$R_OID|$R_STATUS" || true ;;
  esac
  [ "$rc" -eq 0 ] || [ "$rc" -eq 75 ]
}

action_status() {
  local repo project authority method attest max_risk hook auth
  if ! config_entries > /dev/null 2>&1; then
    config_entries >/dev/null 2>&1
    printf 'config: %s\n' "${CONFIG_ERROR:-unreadable}"
  else
    while IFS=$US read -r repo project authority method attest max_risk hook; do
      if entry_authorized "$project" "$authority"; then auth=merges; else auth="no merge authority (project $project is not +yolo)"; fi
      attest=$(entry_attestation "$project" "$attest")
      printf '%s: %s; method=%s attestation=%s max_risk=%s hook=%s\n' \
        "$repo" "$auth" "$method" "$attest" "$max_risk" "${hook:-none}"
      if [ -n "$hook" ]; then
        printf '  deployed: %s\n' "$(deployed_read "$hook" || true)"
        if result_read "$hook"; then
          printf '  last run: %s %s at %s: %s\n' "$R_STATUS" "$(short "$R_OID")" "$R_EPOCH" "$R_SUMMARY"
        fi
      fi
    done < <(config_entries)
  fi
  if fm_custom_check_registered "$STATE" "$CHECK_ID" 2>/dev/null; then
    printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  else
    printf 'not armed\n'
  fi
  if [ -f "$AL/report.log" ]; then
    printf 'recent reports:\n'
    tail -n 10 "$AL/report.log"
  fi
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-autoland.sh - auto-land check shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-autoland.sh") check"
}

action_arm() {
  local home want device tmp
  mkdir -p "$STATE" || return 1
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
    printf 'fm-autoland: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
    return 1
  }
  want=$(shim_content "$home")
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -d "$STATE" ] && [ ! -L "$STATE" ] && [ -n "$device" ] || return 1
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device"; then
    printf 'fm-autoland: %s is not a regular file\n' "$CHECK_SHIM" >&2
    return 1
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-autoland-check.XXXXXX") || return 1
  if ! printf '%s\n' "$want" > "$tmp" || ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    printf 'fm-autoland: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  # An unbound shim is rejected by the watcher on every sweep, so a failed
  # registration leaves no shim behind.
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
    printf 'fm-autoland: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  [ -f "$CONFIG" ] || printf 'fm-autoland: note: %s does not exist yet; ticks report that until it does\n' "$CONFIG" >&2
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  status) action_status ;;
  deploy) shift; action_deploy "$@" ;;
  merge-run)
    [ "$#" -eq 7 ] && fm_pr_head_valid "$3" || exit 2
    shift
    merge_rc=0
    merge_attempt "$@" || merge_rc=$?
    case "$merge_rc" in
      0|3) ;;
      *) printf '%s\n' "$MERGE_ERROR" ;;
    esac
    exit "$merge_rc"
    ;;
  deploy-run)
    if [ "$#" -ne 3 ] || ! fm_pr_head_valid "$3"; then
      printf 'fm-autoland: deploy-run <hook> <oid>\n' >&2
      exit 2
    fi
    run_hook "$2" "$3" 0
    ;;
  -h|--help) usage ;;
  *) printf 'fm-autoland: unknown action: %s\n' "$1" >&2; usage >&2; exit 2 ;;
esac
