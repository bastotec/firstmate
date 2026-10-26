#!/usr/bin/env bash
# fm-worker-keepalive.sh - wake a worker's mate when the worker stops making progress.
#
# Usage: fm-worker-keepalive.sh scan          (bin/fm-watch.sh runs it detached)
#        fm-worker-keepalive.sh ack-prohibition <task> --episode <since>-<approval_id> --instruction-sha256 <digest>
# ack-prohibition is parent-only reconciliation of one false legacy approval
# escalation under an intact untimed prohibition. It checks current home/task,
# metadata, instruction digest, guard identity and exact stored episode under
# the task control and scan locks; an unrelated parent call refuses. It only
# resolves that keepalive escalation and retains PR clocks, never releases the
# guard, answers the worker decision, edits its instructions or resumes work.
# Read <since> and <approval_id> from state/keepalive/<task>.json; digest is the
# original instruction_sha256 in state/<task>.approval-wait. A stale or invalid
# binding refuses. Repeat acknowledgment of that same episode is idempotent.
#
# bin/fm_worker_keepalive.py's docstring owns what counts as stuck, the wake's
# concrete instruction, when the mate acted, and the one plain escalation line.
set -eu
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
case "${1:-}" in
  ack-prohibition)
    # shellcheck source=bin/fm-gate-refuse-lib.sh
    . "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
    fm_refuse_if_gate_agent
    [[ "${2:-}" =~ ^[A-Za-z0-9._-]+$ ]] && [ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME/state" ] || exit 2
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    lock="${FM_STATE_OVERRIDE:-$FM_HOME/state}/.control-$2.lock"
    fm_lock_acquire_wait_bounded "$lock" 30 || exit 1
    trap 'fm_lock_release "$lock" >/dev/null 2>&1 || true' EXIT
    python3 "$SCRIPT_DIR/fm_worker_keepalive.py" "$@"
    ;;
  scan) exec python3 "$SCRIPT_DIR/fm_worker_keepalive.py" "$@" ;;
  -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0" ;;
  *) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0" >&2; exit 2 ;;
esac
