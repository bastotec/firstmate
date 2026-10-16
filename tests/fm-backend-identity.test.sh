#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-backend-identity-tests)
meta="$TMP_ROOT/task.meta"

for shape in missing empty; do
  fm_write_meta "$meta" "window=firstmate:fm-task" "project=project" \
    "worktree_reassigned_by=other"
  if [ "$shape" = empty ]; then
    printf 'worktree=\n' >> "$meta"
  fi
  for opt_in in unset '' 0; do
    out=$(bash -eu -c '
      . "$1/bin/fm-backend.sh"
      unset FM_BACKEND_VALIDATE_REASSIGNMENT_CANDIDATE
      if [ "$3" != unset ]; then
        FM_BACKEND_VALIDATE_REASSIGNMENT_CANDIDATE=$3
      fi
      if fm_backend_validate_task_endpoint "$2" task; then
        exit 7
      else
        rc=$?
        [ "$rc" -eq 1 ] || exit 8
      fi
      printf "caller continued\n"
    ' _ "$ROOT" "$meta" "$opt_in" 2>&1) \
      || fail "validator aborted caller for $shape worktree with opt-in '$opt_in': $out"
    assert_contains "$out" "REFUSED: task task has a missing, empty, or ambiguous worktree identity" \
      "validator did not refuse $shape worktree"
    assert_contains "$out" "caller continued" "validator terminated the caller"
  done
done

pass "endpoint validation refuses missing or empty worktree without aborting unset-opt-in callers"

for shape in missing empty duplicate; do
  fm_write_meta "$meta" "window=firstmate:fm-task" "project=project" \
    "worktree_reassigned_by=other"
  case "$shape" in
    empty) printf 'worktree=\n' >> "$meta" ;;
    duplicate) printf 'worktree=\nworktree=\n' >> "$meta" ;;
  esac
  bash -eu -c '
    . "$1/bin/fm-backend.sh"
    FM_BACKEND_VALIDATE_REASSIGNMENT_CANDIDATE=1
    if fm_backend_validate_task_endpoint "$2" task; then
      [ "$3" = missing ] || exit 1
      [ "$FM_BACKEND_VALIDATED_REASSIGNED_TO" = other ] || exit 1
    else
      [ "$3" != missing ] || exit 1
    fi
  ' _ "$ROOT" "$meta" "$shape" \
    || fail "reassignment candidate validation mishandled $shape worktree"
done

pass "reassignment candidate validation requires an absent worktree field"
