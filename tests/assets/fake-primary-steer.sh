#!/usr/bin/env bash
# tests/assets/fake-primary-steer.sh - a stand-in for bin/fm-primary-steer.sh
# (the deck-chat primary's steer client), selected through FM_PRIMARY_STEER_BIN.
# It keeps the contract's exit codes and output shapes and is steered by files
# in $FAKE_STEER_DIR:
#   absent        present -> every subcommand exits 3 (no deck-chat primary)
#   state         status's "state" value (default idle)
#   endpoint      status's "endpoint" value (default null)
#   ack           never -> delivered exits 1; reject -> exits 2; else acks (0)
#   seq           last published seq
#   published/N.msg   each published body; calls.log records every call
set -u
dir=${FAKE_STEER_DIR:?FAKE_STEER_DIR is required}
mkdir -p "$dir/published"
printf '%s\n' "$*" >> "$dir/calls.log"
[ ! -e "$dir/absent" ] || exit 3
sub=${1:-}
shift || true
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --home) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]+"${args[@]}"}"
case "$sub" in
  status)
    state=$(cat "$dir/state" 2>/dev/null || printf idle)
    seq=$(cat "$dir/seq" 2>/dev/null || printf 0)
    endpoint=null
    [ ! -s "$dir/endpoint" ] || endpoint="\"$(cat "$dir/endpoint")\""
    printf '{"present":true,"state":"%s","last_event":"idle","last_event_at":0,"acked_seq":%s,"published_seq":%s,"pending":0,"endpoint":%s}\n' \
      "$state" "$seq" "$seq" "$endpoint"
    ;;
  publish)
    file='' text='' kind=other
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --file) file=$2; shift 2 ;;
        --text) text=$2; shift 2 ;;
        --kind) kind=$2; shift 2 ;;
        *) exit 2 ;;
      esac
    done
    seq=$(( $(cat "$dir/seq" 2>/dev/null || printf 0) + 1 ))
    printf '%s\n' "$seq" > "$dir/seq"
    if [ -n "$file" ]; then cat "$file" > "$dir/published/$seq.msg"; else printf '%s\n' "$text" > "$dir/published/$seq.msg"; fi
    printf '%s\n' "$kind" > "$dir/published/$seq.kind"
    printf 'seq=%s\n' "$seq"
    ;;
  delivered)
    case "$(cat "$dir/ack" 2>/dev/null)" in
      never) exit 1 ;;
      reject) exit 2 ;;
    esac
    [ "${1:-0}" -le "$(cat "$dir/seq" 2>/dev/null || printf 0)" ] || exit 1
    ;;
  *) exit 2 ;;
esac
