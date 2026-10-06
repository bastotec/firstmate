#!/usr/bin/env bash
# fm-busy-lib.sh - the ONE owner of firstmate's semantic busy-state contract.
#
# Design source: the captain-approved semantic busy-state redesign
# (2026-07-28): each harness adapter reports turn lifecycle through a
# machine-readable semantic source it owns, classification always exposes
# which source produced it, and missing, malformed, stale, unsupported, or
# unverified semantic data is UNKNOWN - never idle. Endpoint death is the only
# process-level override and yields dead, never busy. Child processes, CPU,
# process sleep state, marker mtimes, and the old global UI-regex OR are not
# state signals here; state/<id>.turn-ended files remain wake NOTIFICATIONS
# owned by the watcher, not current-state truth.
#
# Record file: state/<id>.busy-state - exactly one line, atomically replaced
# by bin/fm-busy-event.sh (the only writer):
#
#   v1 gen=<token> seq=<uint> state=<busy|idle|unknown> source=<token> event=<token> ts=<epoch>
#
# Gen sidecar: state/<id>.busy-gen - one token minted when the task's busy
# wiring is armed (fm-spawn, or a documented recovery re-arm). Every event
# must present the current gen; an event or record carrying any other gen is
# a stale incarnation and is rejected (written events) or classified unknown
# (read records). seq is a strictly increasing integer per gen, advanced
# under the writer's lock, so an out-of-order apply can never regress a
# newer record.
#
# Semantic sources written by adapters (fm_busy_sources_for_harness owns the
# per-harness trust table; a record whose source is not trusted for the
# task's recorded harness classifies unknown, so one adapter's writer can
# never classify another adapter):
#   pi-ext           Pi/pi-signed per-task extension (agent_start/agent_settled)
#   deck-wrapper     bin/fm-deck-worker.sh, which starts and ends every Deck
#                    turn itself (turn-start opens; turn-end, turn-failed,
#                    interrupted, and session-end close)
# Firstmate-owned sources accepted for every converted adapter:
#   fm-spawn         the launch-brief turn seeded at spawn
#   fm-interrupt     a firstmate-owned interrupt idle event
#   fm-recovery      a documented recovery reset after relaunch
# Classifier-only sources (never written into a record):
#   endpoint-gone, herdr-native, missing, malformed, gen-mismatch,
#   source-mismatch, no-target
#
# Classification (fm_busy_classify): busy | idle | unknown | dead, always
# with the producing source as the second token. Precedence:
#   1. dead endpoint (fm_busy_classify_live only) -> dead endpoint-gone
#   2. a valid, gen-matching, source-trusted record -> its state and source
#   3. no record at all: herdr's native busy verdict is trusted as busy
#      (generation state is sufficient for busy, not for idle), then
#      unknown missing
#   4. malformed, stale, or untrusted records -> unknown, never a fallback
# The delivery guards in bin/fm-composer-lib.sh match rendered footers for
# submit acknowledgement and away-mode supervisor injection only; neither is a
# recorded worker state source.
#
# Sourcing: set -u and set -e safe; no subshell-unfriendly globals.

FM_BUSY_LIB_VERSION=v1

fm_busy_record_path() {  # <state-dir> <id>
  printf '%s/%s.busy-state' "$1" "$2"
}

fm_busy_gen_path() {  # <state-dir> <id>
  printf '%s/%s.busy-gen' "$1" "$2"
}

# fm_busy_token_valid: conservative token charset shared by gen, source, and
# event fields. Anything else is malformed.
fm_busy_token_valid() {  # <value>
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# fm_busy_current_gen: the task's armed gen token, or failure when the busy
# contract has never been armed for this task.
fm_busy_current_gen() {  # <state-dir> <id>
  local gen_file gen
  gen_file=$(fm_busy_gen_path "$1" "$2")
  [ -f "$gen_file" ] || return 1
  IFS= read -r gen < "$gen_file" 2>/dev/null || gen=
  fm_busy_token_valid "$gen" || return 1
  printf '%s' "$gen"
}

# fm_busy_sources_for_harness: the semantic sources trusted to classify a
# task recorded with <harness>. One line, space-separated, possibly empty.
# The firstmate-owned sources are appended for every converted adapter.
fm_busy_sources_for_harness() {  # <harness>
  local adapter=
  case "${1:-}" in
    deck) adapter=deck-wrapper ;;
    pi|pi-signed) adapter=pi-ext ;;
    *) printf ''; return 0 ;;
  esac
  printf '%s fm-spawn fm-interrupt fm-recovery' "$adapter"
}

fm_busy_source_trusted() {  # <harness> <source>
  local trusted
  trusted=$(fm_busy_sources_for_harness "$1")
  case " $trusted " in
    *" $2 "*) return 0 ;;
  esac
  return 1
}

# fm_busy_record_read: parse and validate state/<id>.busy-state against the
# armed gen. Prints "<state> <source> <event> <seq>" for a valid record.
# Non-zero returns name the reason on stdout instead:
#   missing      no record file (or no armed gen and no record)
#   malformed    unparseable line, bad tokens, or a missing armed gen for an
#                existing record
#   gen-mismatch a record from a stale incarnation
fm_busy_record_read() {  # <state-dir> <id>
  local state=$1 id=$2 rec gen line extra ver f
  local r_gen='' r_seq='' r_state='' r_source='' r_event='' r_ts=''
  rec=$(fm_busy_record_path "$state" "$id")
  if [ ! -f "$rec" ]; then
    printf 'missing'
    return 1
  fi
  if ! gen=$(fm_busy_current_gen "$state" "$id"); then
    # A record without an armed gen has no incarnation to bind to.
    printf 'malformed'
    return 1
  fi
  # shellcheck disable=SC2034 # extra exists only to prove the record is one line
  { IFS= read -r line && ! IFS= read -r extra; } < "$rec" 2>/dev/null || {
    printf 'malformed'
    return 1
  }
  # `read -a` rather than `set --`: it never glob-expands a field and never
  # touches the caller's positional parameters or shell options.
  local -a fields
  IFS=' ' read -r -a fields <<< "$line"
  ver=${fields[0]:-}
  [ "$ver" = "$FM_BUSY_LIB_VERSION" ] || { printf 'malformed'; return 1; }
  for f in "${fields[@]:1}"; do
    case "$f" in
      gen=*) r_gen=${f#gen=} ;;
      seq=*) r_seq=${f#seq=} ;;
      state=*) r_state=${f#state=} ;;
      source=*) r_source=${f#source=} ;;
      event=*) r_event=${f#event=} ;;
      ts=*) r_ts=${f#ts=} ;;
      *) printf 'malformed'; return 1 ;;
    esac
  done
  fm_busy_token_valid "$r_gen" || { printf 'malformed'; return 1; }
  fm_busy_token_valid "$r_source" || { printf 'malformed'; return 1; }
  fm_busy_token_valid "$r_event" || { printf 'malformed'; return 1; }
  case "$r_seq" in ''|*[!0-9]*) printf 'malformed'; return 1 ;; esac
  case "$r_ts" in ''|*[!0-9]*) printf 'malformed'; return 1 ;; esac
  case "$r_state" in busy|idle|unknown) : ;; *) printf 'malformed'; return 1 ;; esac
  if [ "$r_gen" != "$gen" ]; then
    printf 'gen-mismatch'
    return 1
  fi
  printf '%s %s %s %s' "$r_state" "$r_source" "$r_event" "$r_seq"
}

# A Deck submit can be correlated only from the wrapper's idle prompt state.
# A busy baseline may belong to an older turn with input already queued behind
# it, so its eventual next start cannot acknowledge the Enter being sent now.
fm_busy_deck_delivery_baseline() {
  local record state source _event seq
  record=$(fm_busy_record_read "$1" "$2") || return 1
  read -r state source _event seq <<< "$record"
  [ "$state" = idle ] && [ "$source" = deck-wrapper ] || return 1
  printf '%s' "$seq"
}

fm_busy_deck_delivery_started() {
  local record state source event seq baseline=$3
  case "$baseline" in ''|*[!0-9]*) return 1 ;; esac
  record=$(fm_busy_record_read "$1" "$2") || return 1
  read -r state source event seq <<< "$record"
  [ "$state" = busy ] && [ "$source" = deck-wrapper ] \
    && [ "$event" = turn-start ] && [ "$seq" -eq $((baseline + 1)) ]
}

# fm_busy_classify: semantic classification for a task whose endpoint the
# caller has already established as present. Prints "<verdict> <source>":
# busy|idle|unknown plus the producing source (see header). Never probes
# process state. <tail40> is accepted for caller compatibility; no remaining
# adapter classifies from rendered output.
fm_busy_classify() {  # <backend> <target> <harness> <id> <state-dir> [tail40]
  local backend=$1 target=$2 harness=$3 id=$4 state=$5 tail40=${6-}
  local out rc r_state r_source native
  : "$tail40"
  out=$(fm_busy_record_read "$state" "$id") && rc=0 || rc=$?
  if [ "$rc" = 0 ]; then
    r_state=${out%% *}
    out=${out#* }
    r_source=${out%% *}
    if fm_busy_source_trusted "$harness" "$r_source"; then
      printf '%s %s' "$r_state" "$r_source"
    else
      printf 'unknown source-mismatch'
    fi
    return 0
  fi
  case "$out" in
    malformed|gen-mismatch)
      printf 'unknown %s' "$out"
      return 0
      ;;
  esac
  # No record at all. A native herdr busy verdict is semantic enough to trust
  # for BUSY (streaming means a turn is running); native idle is narrower
  # than turn state (a long foreground tool call reads idle) and stays
  # unknown here.
  if [ "$backend" = herdr ] && command -v fm_backend_busy_state >/dev/null 2>&1; then
    native=$(fm_backend_busy_state "$backend" "$target" 2>/dev/null || true)
    if [ "$native" = busy ]; then
      printf 'busy herdr-native'
      return 0
    fi
  fi
  printf 'unknown missing'
}

# fm_busy_classify_live: fm_busy_classify behind the one process-level
# override - a gone endpoint is dead, never busy. Requires fm-backend.sh to
# be sourced for fm_backend_target_exists.
fm_busy_classify_live() {  # <backend> <target> <harness> <id> <state-dir> [expected-label]
  local backend=$1 target=$2 harness=$3 id=$4 state=$5 label=${6-}
  if [ -z "$target" ]; then
    printf 'unknown no-target'
    return 0
  fi
  if ! fm_backend_target_exists "$backend" "$target" "$label" 2>/dev/null; then
    printf 'dead endpoint-gone'
    return 0
  fi
  fm_busy_classify "$backend" "$target" "$harness" "$id" "$state"
}

# fm_busy_classify_meta: classify a task from its recorded metadata, so every
# consumer resolves backend, target, and harness the same way instead of
# re-deriving them. Requires fm-backend.sh to be sourced. <tail40> is
# optional pre-captured plain output, accepted for caller compatibility.
fm_busy_classify_meta() {  # <meta-file> <id> <state-dir> [tail40]
  local meta=$1 id=$2 state=$3 tail40=${4-} backend target harness
  [ -f "$meta" ] || { printf 'unknown missing'; return 0; }
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  harness=$(fm_meta_get "$meta" harness)
  if [ -z "$target" ]; then
    printf 'unknown no-target'
    return 0
  fi
  fm_busy_classify "$backend" "$target" "$harness" "$id" "$state" "$tail40"
}

# fm_busy_is_busy: boolean view for callers that only gate on provable
# activity. 0 iff the classification verdict is exactly busy; idle, unknown,
# and dead all return 1, so an unknown can never be silently promoted to
# either boolean pole - callers that must distinguish idle from unknown read
# the full classification instead.
fm_busy_is_busy() {  # <backend> <target> <harness> <id> <state-dir> [tail40]
  local verdict
  verdict=$(fm_busy_classify "$@")
  [ "${verdict%% *}" = busy ]
}
