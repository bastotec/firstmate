#!/usr/bin/env bash
# fm-ci-infra.sh - tell a CI failure that never ran apart from a code failure.
#
# Usage: fm-ci-infra.sh classify <github-pr-url>
#        fm-ci-infra.sh classify-json <file|->
#        fm-ci-infra.sh --help
#
# A GitHub Actions job can fail without running a single step: the account's
# payments failed or its spending limit was reached, or no runner matches the
# job's labels. GitHub then reports the check as failed, and a reviewer that
# only sees "CI check failing" treats it as a code failure and asks for a
# decision. This command classifies every failed check of a pull request:
#
#   infra  the job ran zero steps, or one of its annotations says it was not
#          started, names billing, payments or a spending limit, or says no
#          runner matched or was available;
#   code   anything else that failed.
#
# An infra failure is never a decision for the captain: the worker or mate
# fixes it and re-runs. The fix depends on the repository, and the command
# prints it: a private repository moves the failing workflow to
# `runs-on: [self-hosted, linux, workload]` (a virtualenv instead of
# actions/setup-python), and a public repository keeps hosted runners and is
# re-run. bin/fm-dod-lib.sh's act-within-scope section owns that rule.
#
# classify reads the pull request's head commit, its failed check runs, each
# check's annotations, and for GitHub Actions jobs the job's steps, through gh.
# classify-json applies the same classification to a JSON document, so the
# rules can be exercised without the network:
#   {"repo_private": true,
#    "checks": [{"name": "verify", "steps": 0,
#                "annotations": ["The job was not started because ..."]}]}
#
# Output: one line per failed check, "infra <name>: <reason>" or
# "code <name>", then "verdict: infra|code|none" and, for infra, one "fix:" line.
# Exit: 0 when every failed check is infra, 1 when any is code, 3 when nothing
# failed, 2 on invalid use or when GitHub cannot be read.
set -u

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

# The classification itself: stdin is the classify-json document.
classify_doc() {
  jq -r '
    def infra_reason:
      ( [ .annotations[]? | tostring
          | select(test("not started|payments? (have |has )?failed|spending limit|billing|no runner|runner matching|waiting for a runner|could not find any runner"; "i")) ]
        | first ) as $note
      | if $note != null then ($note | gsub("\\s+"; " ") | .[0:160])
        elif (.steps // null) == 0 then "the job ran zero steps"
        else null end;
    (.checks // []) as $checks
    | ($checks | map(. + {reason: infra_reason})) as $rows
    | ($rows[] | if .reason != null then "infra \(.name): \(.reason)" else "code \(.name)" end),
      (if ($rows | length) == 0 then "verdict: none"
       elif all($rows[]; .reason != null) then
         "verdict: infra",
         (if .repo_private == true then
            "fix: private repository - switch the failing workflow to runs-on: [self-hosted, linux, workload] (a virtualenv instead of actions/setup-python), then re-run"
          else
            "fix: public repository - keep hosted runners and re-run once billing or runner capacity is back"
          end)
       else "verdict: code" end)
  '
}

exit_for() {  # <classification output>
  case "$(printf '%s\n' "$1" | sed -n 's/^verdict: //p')" in
    infra) return 0 ;;
    code) return 1 ;;
    none) return 3 ;;
    *) return 2 ;;
  esac
}

# Builds the classify-json document for a GitHub pull request URL.
fetch_doc() {  # <pr-url>
  local url=$1 repo number head private checks rows id name app steps notes
  case "$url" in
    https://github.com/*/*/pull/[0-9]*) ;;
    *) echo "error: expected a GitHub pull request URL, got: $url" >&2; return 2 ;;
  esac
  repo=$(printf '%s' "$url" | sed -E 's#^https://github.com/([^/]+/[^/]+)/pull/.*#\1#')
  number=$(printf '%s' "$url" | sed -E 's#.*/pull/([0-9]+).*#\1#')
  head=$(gh api "repos/$repo/pulls/$number" --jq .head.sha 2>/dev/null) || { echo "error: cannot read $url" >&2; return 2; }
  private=$(gh api "repos/$repo" --jq .private 2>/dev/null) || { echo "error: cannot read $repo" >&2; return 2; }
  checks=$(gh api --paginate "repos/$repo/commits/$head/check-runs?per_page=100" \
    --jq '.check_runs[] | select(.conclusion == "failure" or .conclusion == "startup_failure" or .conclusion == "timed_out")
          | [.id, .name, .app.slug] | @tsv' 2>/dev/null) || { echo "error: cannot read the checks of $url" >&2; return 2; }
  rows='[]'
  while IFS=$'\t' read -r id name app; do
    [ -n "$id" ] || continue
    notes=$(gh api "repos/$repo/check-runs/$id/annotations" --jq '[.[].message]' 2>/dev/null) || notes='[]'
    steps=null
    if [ "$app" = github-actions ]; then
      steps=$(gh api "repos/$repo/actions/jobs/$id" --jq '.steps | length' 2>/dev/null) || steps=null
    fi
    rows=$(jq -c --arg name "$name" --argjson steps "${steps:-null}" --argjson notes "$notes" \
      '. + [{name: $name, steps: $steps, annotations: $notes}]' <<<"$rows")
  done <<<"$checks"
  jq -n --argjson private "$private" --argjson checks "$rows" '{repo_private: $private, checks: $checks}'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  classify)
    [ $# -eq 2 ] || { usage >&2; exit 2; }
    doc=$(fetch_doc "$2") || exit 2
    out=$(printf '%s' "$doc" | classify_doc) || exit 2
    ;;
  classify-json)
    [ $# -eq 2 ] || { usage >&2; exit 2; }
    if [ "$2" = - ]; then doc=$(cat); else doc=$(cat "$2") || exit 2; fi
    out=$(printf '%s' "$doc" | classify_doc) || { echo "error: unreadable classification input" >&2; exit 2; }
    ;;
  *) usage >&2; exit 2 ;;
esac
printf '%s\n' "$out"
exit_for "$out"
