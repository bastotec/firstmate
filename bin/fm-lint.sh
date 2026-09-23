#!/usr/bin/env bash
# fm-lint.sh - the single owner of firstmate's lint definition.
#
# Canonical roots: bin/*.sh, bin/backends/*.sh, tests/*.sh.
# ShellCheck uses its pinned version, default severity, --norc and full extended
# analysis. Explicit paths and full/affected modes keep --external-sources and
# every finding code. Tests may bound imported production analysis with their
# source=/dev/null directives; each production module remains a canonical root.
# Without explicit paths, always check backend purity and GitHub workflows too.
#
# Selection:
#   --full: all canonical roots, including on pushes to main.
#   --changed <base>: changed shells and transitive referencing roots since the
#     merge-base, including working edits, deletions and both sides of renames.
#     CI supplies the PR base SHA with full checkout history. Missing history or
#     an unreadable graph falls back to full lint. Filename references are
#     conservative (including comments/commands); unresolved sources widen the
#     set, and changes to this owner's implementation/data select all roots.
#   No mode: full in CI, on main, or without a merge-base against origin/main
#     (else main); otherwise the existing local changed-files-only pass, without
#     source following and excluding SC1091, SC2034, SC2153 and SC2329.
#   Explicit paths: exactly those roots, no workflow check.
#   --fast: local-only, disables extended analysis but preserves source following.
# Empty selections skip ShellCheck but still check backend purity and workflows.
# Backend purity rejects direct Beads CLI use in core bin/ and bin/backends/.
#
# Scheduling: one fresh process per root. Default concurrency is detected CPUs;
# --jobs / FM_LINT_JOBS can lower it. FM_LINT_MEMORY_MIB defaults to 6144 MiB
# and is an ADMISSION BUDGET for scheduling waves, not a process memory limit
# and not a claim that any root's heap is bounded: no kernel or RTS cap is
# applied to ShellCheck, and a root whose real RSS exceeds its reservation or
# the whole budget still runs, alone, and can still be killed by an external
# memory watchdog. bin/fm-lint-memory.tsv holds measured per-root RSS in KiB,
# bound to a conservative source-closure SHA-256. Reservations pad measured RSS
# by 50 percent plus 64 MiB. Roots with no usable measurement (zero
# reservation), stale source graphs, or reservations above the budget are
# UNKNOWN to the planner: an unknown reservation never silently means "the
# whole budget is available" - it means the root runs alone in its own wave,
# whatever the configured budget. Reservations above 3072 MiB are heavy: at
# most one heavy root is admitted per wave, alongside light roots only if the
# CPU and memory reservations fit. This remains true on machines with many CPUs
# or a larger configured budget.
# Refresh by timing each --full --list-files root separately with
# Command: shellcheck --norc --external-sources -- "$root" (clear SHELLCHECK_OPTS).
# Use /usr/bin/time -lp on macOS or -v on Linux, converting RSS to KiB, and join
# it to `perl bin/fm-lint-plan.pl fingerprints '' <roots...>` output under the
# version header. Never bind new fingerprints to unmeasured changed closures.
# Diagnostics and first nonzero exit selection retain input-root order.
#
# --telemetry / FM_LINT_TELEMETRY writes a TSV snapshot of identity, detected
# resources, reservations, wall/CPU/max RSS and competing ShellCheck processes.
# RSS maxima summed across roots are NOT a simultaneous aggregate memory peak.
# Local measurements do not predict runner RSS; CI prints its own snapshot.
#
# Usage:
#   fm-lint.sh                         lint the context-selected file set
#   fm-lint.sh --full                  full canonical lint
#   fm-lint.sh --changed <base>        source-aware affected-root lint
#   fm-lint.sh --fast [path]...         local lint without extended analysis
#   fm-lint.sh <path>...                lint explicit roots
#   fm-lint.sh --jobs <count> [path]... lower CPU concurrency
#   fm-lint.sh --telemetry <path> ...   write a quiet metrics snapshot
#   fm-lint.sh --required-version      print the ShellCheck pin
#   fm-lint.sh --list-files            print the selected roots without linting
#   fm-lint.sh --help                  print this usage
set -u

REQUIRED_SHELLCHECK=0.11.0
# Cross-file codes that need --external-sources. Local changed-file mode
# cannot judge them, so they stay CI-only.
LOCAL_NOX_EXCLUDE=SC1091,SC2034,SC2153,SC2329
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$SELF_DIR/fm-lint.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd -P)"
cd "$ROOT" || exit 1

FM_LINT_WORKER_SHELLCHECK_PID=
# shellcheck disable=SC2329 # Registered by the private worker's signal traps.
fm_lint_worker_stop() {
  [ -n "$FM_LINT_WORKER_SHELLCHECK_PID" ] || return 0
  kill "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null || true
  wait "$FM_LINT_WORKER_SHELLCHECK_PID" 2>/dev/null || true
  FM_LINT_WORKER_SHELLCHECK_PID=
}

fm_lint_worker() {  # <manifest> <output-dir> <shard-index>
  local manifest=$1 output_dir=$2 shard_index=$3 tab index path output invocation_rc rc=0
  local -a roots shellcheck_args
  roots=()
  tab=$(printf '\t')
  while IFS="$tab" read -r index path || [ -n "${index:-}${path:-}" ]; do
    [ -n "${index:-}" ] || continue
    roots+=("$path")
  done < "$manifest"
  output="$output_dir/shard.$shard_index"
  if [ "${#roots[@]}" -gt 0 ]; then
    trap 'fm_lint_worker_stop; exit 129' HUP
    trap 'fm_lint_worker_stop; exit 130' INT
    trap 'fm_lint_worker_stop; exit 143' TERM
    shellcheck_args=(--norc)
    if [ "${FM_LINT_INTERNAL_FOLLOW_SOURCES:-1}" -eq 1 ]; then
      shellcheck_args+=(--external-sources)
    fi
    if [ -n "${FM_LINT_INTERNAL_EXCLUDE:-}" ]; then
      shellcheck_args+=(--exclude="$FM_LINT_INTERNAL_EXCLUDE")
    fi
    if [ "${FM_LINT_INTERNAL_FAST:-0}" -eq 1 ]; then
      shellcheck_args+=(--extended-analysis=false)
    fi
    : > "$output.out"
    if [ "${FM_LINT_INTERNAL_FOLLOW_SOURCES:-1}" -eq 1 ]; then
      "$FM_LINT_SHELLCHECK" "${shellcheck_args[@]}" -- "${roots[@]}" >> "$output.out" 2>&1 &
      FM_LINT_WORKER_SHELLCHECK_PID=$!
      wait "$FM_LINT_WORKER_SHELLCHECK_PID" || rc=$?
      FM_LINT_WORKER_SHELLCHECK_PID=
    else
      for path in "${roots[@]}"; do
        invocation_rc=0
        "$FM_LINT_SHELLCHECK" "${shellcheck_args[@]}" -- "$path" >> "$output.out" 2>&1 &
        FM_LINT_WORKER_SHELLCHECK_PID=$!
        wait "$FM_LINT_WORKER_SHELLCHECK_PID" || invocation_rc=$?
        FM_LINT_WORKER_SHELLCHECK_PID=
        if [ "$rc" -eq 0 ] && [ "$invocation_rc" -ne 0 ]; then
          rc=$invocation_rc
        fi
      done
    fi
    trap - HUP INT TERM
  else
    : > "$output.out"
  fi
  printf '%s\n' "$rc" > "$output.rc"
  return "$rc"
}

# Private subprocess mode used only by the bounded parent above.
if [ "${1:-}" = "--internal-worker" ]; then
  [ "${FM_LINT_INTERNAL:-}" = 1 ] || {
    printf 'fm-lint.sh: --internal-worker is private to the lint owner.\n' >&2
    exit 2
  }
  [ "$#" -eq 4 ] && [ -n "${FM_LINT_SHELLCHECK:-}" ] || exit 2
  fm_lint_worker "$2" "$3" "$4"
  exit $?
fi

if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_SHELLCHECK"
  exit 0
fi

fm_lint_usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$SELF"
}

# Default no-args lint also validates GitHub workflows. Explicit paths stay a
# ShellCheck-only override so callers can target one shell root.
fm_lint_run_workflows() {
  [ "$EXPLICIT_PATHS" -eq 0 ] || return 0
  "$SELF_DIR/fm-lint-workflows.sh"
}

# Backend adapters belong behind tasks-axi. Keep direct Beads CLI invocations
# out of firstmate's core scripts so every configured backend follows the same
# lifecycle path.
fm_lint_run_backend_purity() {
  local findings path canonical
  local -a purity_roots
  purity_roots=()
  if [ "$EXPLICIT_PATHS" -eq 0 ]; then
    purity_roots=(bin/*.sh bin/backends/*.sh)
  else
    for path in "${ROOTS[@]}"; do
      [ -f "$path" ] || continue
      # shellcheck disable=SC2016 # Perl, not the shell, expands $ARGV.
      canonical=$("$PERL_BIN" -MCwd=realpath -e '
        my $resolved = realpath($ARGV[0]);
        exit 1 unless defined $resolved;
        print $resolved;
      ' "$path" 2>/dev/null) || continue
      case "$canonical" in
        "$ROOT"/bin/*.sh|"$ROOT"/bin/backends/*.sh)
          purity_roots+=("$canonical")
          ;;
      esac
    done
  fi
  [ "${#purity_roots[@]}" -gt 0 ] || return 0
  findings=$(LC_ALL=C awk '
    function hex_value(character) {
      return index("0123456789abcdef", tolower(character)) - 1
    }
    function ansi_number(digits, base,    i, value) {
      value=0
      for (i=1; i <= length(digits); i++) value=value * base + hex_value(substr(digits, i, 1))
      return value
    }
    # Non-printable and non-ASCII bytes can never spell the bd command, so a
    # placeholder keeps them from colliding into it.
    function ansi_character(value) {
      if (value < 32 || value > 126) return "?"
      return sprintf("%c", value)
    }
    function invokes_bd(segment) {
      sub(/^[[:space:]]+/, "", segment)
      while (1) {
        previous=segment
        sub(/^(if|then|elif|else|while|until|do)[[:space:]]+/, "", segment)
        sub(/^![[:space:]]+/, "", segment)
        sub(/^(command|exec)[[:space:]]+/, "", segment)
        sub(/^[[:alpha:]_][[:alnum:]_]*=[^[:space:]]+[[:space:]]+/, "", segment)
        if (segment ~ /^env[[:space:]]+/) {
          sub(/^env[[:space:]]+/, "", segment)
          while (1) {
            if (segment ~ /^--[[:space:]]+/) {
              sub(/^--[[:space:]]+/, "", segment)
              break
            }
            if (segment ~ /^(-u|--unset|-C|--chdir|-S|--split-string|--argv0)[[:space:]]+[^[:space:]]+[[:space:]]+/) {
              sub(/^(-u|--unset|-C|--chdir|-S|--split-string|--argv0)[[:space:]]+[^[:space:]]+[[:space:]]+/, "", segment)
              continue
            }
            if (segment ~ /^--(unset|chdir|split-string|argv0)=[^[:space:]]+[[:space:]]+/) {
              sub(/^--(unset|chdir|split-string|argv0)=[^[:space:]]+[[:space:]]+/, "", segment)
              continue
            }
            if (segment ~ /^(-i|--ignore-environment|-0|--null|-v|--debug)[[:space:]]+/) {
              sub(/^(-i|--ignore-environment|-0|--null|-v|--debug)[[:space:]]+/, "", segment)
              continue
            }
            if (segment ~ /^[[:alpha:]_][[:alnum:]_]*=[^[:space:]]+[[:space:]]+/) {
              sub(/^[[:alpha:]_][[:alnum:]_]*=[^[:space:]]+[[:space:]]+/, "", segment)
              continue
            }
            break
          }
        }
        if (segment == previous) break
      }
      command_word=""
      quote=""
      ansi=0
      for (position=1; position <= length(segment); position++) {
        character=substr(segment, position, 1)
        if (quote == "") {
          if (character ~ /[[:space:]]/) break
          if (character == "$" && position < length(segment)) {
            next_character=substr(segment, position + 1, 1)
            if (next_character == "\"" || next_character == sprintf("%c", 39)) {
              position++
              quote=next_character
              ansi=(next_character == sprintf("%c", 39)) ? 1 : 0
              continue
            }
          }
          if (character == "\"" || character == sprintf("%c", 39)) {
            quote=character
            ansi=0
            continue
          }
          if (character == "\\") {
            position++
            if (position > length(segment)) return 0
            character=substr(segment, position, 1)
          }
          command_word=command_word character
          continue
        }
        if (character == quote) {
          quote=""
          ansi=0
          continue
        }
        if (character == "\\" && (quote == "\"" || ansi)) {
          position++
          if (position > length(segment)) return 0
          escape=substr(segment, position, 1)
          if (ansi) {
            # ANSI-C quoting decodes escapes, so an encoded spelling of the
            # command still runs bd and must be decoded here to be caught.
            value=-1
            if (escape == "x" || escape == "u" || escape == "U") {
              max_digits=2
              if (escape == "u") max_digits=4
              if (escape == "U") max_digits=8
              digits=""
              while (length(digits) < max_digits && position < length(segment)) {
                digit=substr(segment, position + 1, 1)
                if (digit !~ /[0-9A-Fa-f]/) break
                digits=digits digit
                position++
              }
              if (digits == "") {
                # An escape prefix with no digits yields the prefix character.
                command_word=command_word escape
                continue
              }
              value=ansi_number(digits, 16)
            } else if (escape ~ /[0-7]/) {
              digits=escape
              while (length(digits) < 3 && position < length(segment)) {
                digit=substr(segment, position + 1, 1)
                if (digit !~ /[0-7]/) break
                digits=digits digit
                position++
              }
              value=ansi_number(digits, 8)
            }
            if (value >= 0) {
              if (value == 0) {
                # NUL truncates the bash word.
                quote=""
                break
              }
              command_word=command_word ansi_character(value)
              continue
            }
            if (escape == "c") {
              # Control characters can never spell the bd command.
              if (position < length(segment)) position++
              command_word=command_word "?"
              continue
            }
            if (escape ~ /^[abeEfnrtv]$/) {
              command_word=command_word "?"
              continue
            }
            # Remaining ANSI-C escapes keep their character, and bash drops
            # the backslash before any other character.
            command_word=command_word escape
            continue
          }
          character=escape
        }
        command_word=command_word character
      }
      if (quote != "") return 0
      return command_word ~ /(^|\/)bd$/
    }
    function split_commands(line, segments,   position, character, quote, current, count) {
      delete segments
      count=0
      current=""
      quote=""
      for (position=1; position <= length(line); position++) {
        character=substr(line, position, 1)
        if (quote != "") {
          current=current character
          if (character == quote) {
            quote=""
          } else if (quote == "\"" && character == "\\") {
            position++
            if (position <= length(line)) current=current substr(line, position, 1)
          }
          continue
        }
        if (character == "\\") {
          current=current character
          position++
          if (position <= length(line)) current=current substr(line, position, 1)
          continue
        }
        if (character == "\"" || character == sprintf("%c", 39)) {
          quote=character
          current=current character
          continue
        }
        if (character ~ /[();|&{}]/) {
          segments[++count]=current
          current=""
          continue
        }
        current=current character
      }
      if (quote != "") return split(line, segments, /[();|&{}]+/)
      segments[++count]=current
      return count
    }
    /^[[:space:]]*#/ { next }
    {
      count=split_commands($0, segments)
      for (i=1; i<=count; i++) {
        if (invokes_bd(segments[i])) {
          print FILENAME ":" FNR ": direct Beads CLI invocation bypasses tasks-axi"
          break
        }
      }
    }
  ' "${purity_roots[@]}")
  [ -z "$findings" ] || {
    printf '%s\n' "$findings" >&2
    return 1
  }
}

# CPU detection is local to the owner, never inferred from a runner label.
CPU_COUNT=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || printf '1')
case "$CPU_COUNT" in ''|*[!0-9]*|0) CPU_COUNT=1 ;; esac
HOST_MEMORY_MIB=unavailable
if [ -r /proc/meminfo ]; then
  HOST_MEMORY_MIB=$(awk '/^MemTotal:/ {printf "%.0f", $2 / 1024}' /proc/meminfo)
elif [ "$(uname)" = Darwin ]; then
  HOST_MEMORY_MIB=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%.0f", $1 / 1048576}')
fi
JOBS=${FM_LINT_JOBS:-$CPU_COUNT}
ADMISSION_BUDGET_MIB=${FM_LINT_MEMORY_MIB:-6144}
TELEMETRY=${FM_LINT_TELEMETRY:-}
SELECTION=auto
CHANGE_BASE=
FAST=0
ANALYSIS_MODE=full
LIST_FILES=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --full)
      SELECTION=full
      shift
      ;;
    --changed)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --changed requires a base commit.\n' >&2; exit 2; }
      SELECTION=affected
      CHANGE_BASE=$2
      shift 2
      ;;
    --jobs)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --jobs requires a positive integer.\n' >&2; exit 2; }
      JOBS=$2
      shift 2
      ;;
    --jobs=*)
      JOBS=${1#*=}
      shift
      ;;
    --telemetry)
      [ "$#" -ge 2 ] || { printf 'fm-lint.sh: --telemetry requires a path.\n' >&2; exit 2; }
      TELEMETRY=$2
      shift 2
      ;;
    --telemetry=*)
      TELEMETRY=${1#*=}
      shift
      ;;
    --fast)
      FAST=1
      ANALYSIS_MODE=fast
      shift
      ;;
    --list-files)
      LIST_FILES=1
      shift
      ;;
    --help|-h)
      fm_lint_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    *) break ;;
  esac
done

case "$JOBS:$ADMISSION_BUDGET_MIB" in
  *[!0-9:]*|:*|*:|0:*|*:0)
    printf 'fm-lint.sh: jobs and FM_LINT_MEMORY_MIB must be positive integers.\n' >&2
    exit 2
    ;;
esac
# Prevent overflow and accidental process storms; an explicit override can use
# fewer CPUs but cannot request more than the detected host provides.
[ "${#JOBS}" -le 6 ] && [ "${#ADMISSION_BUDGET_MIB}" -le 7 ] || exit 2
JOBS=$((10#$JOBS))
ADMISSION_BUDGET_MIB=$((10#$ADMISSION_BUDGET_MIB))
[ "$JOBS" -gt 0 ] && [ "$ADMISSION_BUDGET_MIB" -gt 0 ] || exit 2
[ "$JOBS" -le "$CPU_COUNT" ] || JOBS=$CPU_COUNT

if [ "$FAST" -eq 1 ] && { [ "${GITHUB_ACTIONS:-}" = true ] || [ "${CI:-}" = true ]; }; then
  printf 'fm-lint.sh: --fast is local-only; CI uses full ShellCheck analysis.\n' >&2
  exit 2
fi

# fm_lint_changed_base_ref prints the ref to diff the working branch against:
# the local origin/main tracking ref when present, else local main. Returns
# nonzero when neither is resolvable, which the caller treats as "no
# merge-base found" and falls back to a full lint.
fm_lint_changed_base_ref() {
  if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
    printf 'origin/main\n'
    return 0
  fi
  if git rev-parse --verify -q main >/dev/null 2>&1; then
    printf 'main\n'
    return 0
  fi
  return 1
}

# fm_lint_is_canonical_root tests membership in the canonical set (a direct
# *.sh child of bin/, bin/backends/, or tests/) without the shell case
# statement's non-pathname wildcard matching a path separator by accident.
fm_lint_is_canonical_root() {
  local path=$1 dir base
  case "$path" in
    */*) dir=${path%/*}; base=${path##*/} ;;
    *) dir=; base=$path ;;
  esac
  case "$base" in
    *.sh) : ;;
    *) return 1 ;;
  esac
  case "$dir" in
    bin|bin/backends|tests) return 0 ;;
    *) return 1 ;;
  esac
}

CHANGED_MODE=0
EXPLICIT_PATHS=0
FOLLOW_SOURCES=1
EXCLUDE_CODES=
if [ "$#" -gt 0 ]; then
  [ "$SELECTION" = auto ] || { printf 'fm-lint.sh: selection modes do not accept explicit paths.\n' >&2; exit 2; }
  EXPLICIT_PATHS=1
  ROOTS=("$@")
else
  full_lint=1
  if [ "$SELECTION" = auto ] && [ "${GITHUB_ACTIONS:-}" != true ] && [ "${CI:-}" != true ] \
    && command -v git >/dev/null 2>&1 \
    && git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" != main ]; then
    base_ref=$(fm_lint_changed_base_ref) || base_ref=
    merge_base=
    [ -z "$base_ref" ] || merge_base=$(git merge-base "$base_ref" HEAD 2>/dev/null) || merge_base=
    [ -z "$merge_base" ] || full_lint=0
  fi

  if [ "$SELECTION" = affected ]; then
    # Explicit base is supplied as data, never interpolated into a shell command.
    # Missing history or a failed selector falls back to full lint, not an empty pass.
    ROOTS=(bin/*.sh bin/backends/*.sh tests/*.sh)
    base_commit=$(git rev-parse --verify --end-of-options "${CHANGE_BASE}^{commit}" 2>/dev/null) || base_commit=
    merge_base=
    [ -z "$base_commit" ] || merge_base=$(git merge-base "$base_commit" HEAD 2>/dev/null) || merge_base=
    selected=
    if [ -n "$merge_base" ] && selected=$(perl "$SELF_DIR/fm-lint-plan.pl" changed "$merge_base" "${ROOTS[@]}"); then
      ROOTS=()
      while IFS= read -r changed_path; do
        [ -n "$changed_path" ] || continue
        ROOTS+=("$changed_path")
      done <<< "$selected"
      ANALYSIS_MODE=affected
    else
      printf 'fm-lint.sh: changed base/graph unavailable; using full canonical lint.\n' >&2
    fi
  elif [ "$full_lint" -eq 1 ]; then
    ROOTS=(bin/*.sh bin/backends/*.sh tests/*.sh)
  else
    CHANGED_MODE=1
    ROOTS=()
    while IFS= read -r -d '' changed_path; do
      fm_lint_is_canonical_root "$changed_path" || continue
      [ -f "$changed_path" ] || continue
      ROOTS+=("$changed_path")
    done < <(git diff --name-only --diff-filter=ACMR -z "$merge_base" -- 2>/dev/null | LC_ALL=C sort -z)
  fi
fi
if [ "$CHANGED_MODE" -eq 1 ] && [ "$FAST" -eq 0 ]; then
  FOLLOW_SOURCES=0
  EXCLUDE_CODES=$LOCAL_NOX_EXCLUDE
  ANALYSIS_MODE=local
fi
ROOT_COUNT=${#ROOTS[@]}

if [ "$LIST_FILES" -eq 1 ]; then
  [ "$#" -eq 0 ] || {
    printf 'fm-lint.sh: --list-files does not accept explicit paths.\n' >&2
    exit 2
  }
  [ "$ROOT_COUNT" -eq 0 ] || printf '%s\n' "${ROOTS[@]}"
  exit 0
fi

if ! command -v shellcheck >/dev/null 2>&1; then
  printf 'fm-lint.sh: ShellCheck not found; install ShellCheck %s with bin/fm-install-shellcheck.sh <destination-directory> and put that directory on PATH.\n' \
    "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi
unset SHELLCHECK_OPTS
SHELLCHECK_BIN=$(command -v shellcheck)
if ! PERL_BIN=$(command -v perl); then
  printf 'fm-lint.sh: perl is required for bounded worker cleanup.\n' >&2
  exit 127
fi
resolved=$("$SHELLCHECK_BIN" --version | awk '/^version:/ {print $2; exit}')
printf 'fm-lint.sh: ShellCheck %s (pinned %s)\n' "$resolved" "$REQUIRED_SHELLCHECK" >&2
if [ "$resolved" != "$REQUIRED_SHELLCHECK" ]; then
  printf 'fm-lint.sh: ShellCheck %s required for CI parity, found %s. Install %s with bin/fm-install-shellcheck.sh <destination-directory>.\n' \
    "$REQUIRED_SHELLCHECK" "$resolved" "$REQUIRED_SHELLCHECK" >&2
  exit 1
fi
if [ "$FAST" -eq 1 ]; then
  printf 'fm-lint.sh: fast local mode; ShellCheck extended analysis disabled\n' >&2
elif [ "$FOLLOW_SOURCES" -eq 0 ]; then
  printf 'fm-lint.sh: local changed-file mode; ShellCheck source following disabled\n' >&2
else
  printf 'fm-lint.sh: full ShellCheck extended analysis enabled\n' >&2
fi

if [ "$ROOT_COUNT" -eq 0 ]; then
  printf 'fm-lint.sh: no changed lint targets\n'
  overall_rc=0
  fm_lint_run_backend_purity || overall_rc=$?
  fm_lint_run_workflows || overall_rc=$?
  exit "$overall_rc"
fi

if [ -n "$TELEMETRY" ]; then
  telemetry_parent=$(dirname "$TELEMETRY")
  [ -d "$telemetry_parent" ] || {
    printf 'fm-lint.sh: telemetry directory does not exist: %s\n' "$telemetry_parent" >&2
    exit 2
  }
fi

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lint.XXXXXX") || exit 1
ACTIVE_PIDS=()
# shellcheck disable=SC2329 # Registered by the EXIT and signal traps below.
fm_lint_cleanup() {
  local pid
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -TERM -- "-$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -KILL -- "-$pid" 2>/dev/null || true
    kill -KILL "$pid" 2>/dev/null || true
  done
  for pid in "${ACTIVE_PIDS[@]:-}"; do
    [ -n "$pid" ] && wait "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP_ROOT"
}
trap fm_lint_cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

TAB=$(printf '\t')
WEIGHTS="$TMP_ROOT/weights"
OUTPUT_DIR="$TMP_ROOT/output"
mkdir -p "$OUTPUT_DIR"
# One fresh ShellCheck process per root, rather than retaining a whole shard's
# heap. Unknown/stale source graphs reserve the entire budget and run alone.
SHARD_COUNT=$ROOT_COUNT
if ! FM_LINT_PLAN_VERSION="$REQUIRED_SHELLCHECK" "$PERL_BIN" "$SELF_DIR/fm-lint-plan.pl" weights "$SELF_DIR/fm-lint-memory.tsv" "${ROOTS[@]}" > "$TMP_ROOT/measured" 2>/dev/null; then
  : > "$TMP_ROOT/measured"
  for path in "${ROOTS[@]}"; do printf '0\t%s\n' "$path" >> "$TMP_ROOT/measured"; done
fi
worker=0
: > "$WEIGHTS"
while IFS="$TAB" read -r rss path; do
  case "$path" in
    *"$TAB"*|*$'\n'*)
      printf 'fm-lint.sh: paths containing tabs or newlines are not supported.\n' >&2
      exit 2
      ;;
  esac
  # 50 percent headroom plus 64 MiB. Unknown or oversized roots reserve the
  # whole budget; known heavy roots can share only with fitting light roots.
  weight=$(((rss * 3 + 2047) / 2048 + 64))
  heavy=0
  unknown=0
  [ "$weight" -le 3072 ] || heavy=1
  if [ "$rss" -eq 0 ] || [ "$weight" -gt "$ADMISSION_BUDGET_MIB" ]; then
    weight=$ADMISSION_BUDGET_MIB
    heavy=1
    unknown=1
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$weight" "$worker" "$path" "$heavy" "$unknown" >> "$WEIGHTS"
  printf '%s\t%s\n' "$worker" "$path" > "$TMP_ROOT/manifest.$worker"
  worker=$((worker + 1))
done < "$TMP_ROOT/measured"
[ "$worker" -eq "$ROOT_COUNT" ] || { printf 'fm-lint.sh: incomplete memory plan.\n' >&2; exit 2; }
# First-fit decreasing fills spare capacity around long heavy roots without
# ever pairing two heavy roots. Plan waves before launch, independent of timing.
LC_ALL=C sort -t "$TAB" -k1,1nr -k2,2n "$WEIGHTS" > "$WEIGHTS.sorted"
# An unknown or oversized reservation is not a size claim equal to the whole
# budget: it means the root must run alone in its own wave regardless of how
# large the configured budget is, so a light root is never packed beside it on
# the strength of arithmetic that happens to fit.
awk -F '\t' -v jobs="$JOBS" -v budget="$ADMISSION_BUDGET_MIB" '
  {
    wave=0
    while (count[wave] >= jobs || memory[wave] + $1 > budget || (heavy[wave] && $4) || (occupied[wave] && $5)) wave++
    count[wave]++
    memory[wave]+=$1
    heavy[wave]+=$4
    if ($5) occupied[wave]=1
    rows[wave]=rows[wave] wave "\t" $0 "\n"
    if (wave > last) last=wave
  }
  END { for (wave=0; wave<=last; wave++) printf "%s", rows[wave] }
' "$WEIGHTS.sorted" > "$TMP_ROOT/schedule"

fm_lint_shellcheck_count() {
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -x shellcheck 2>/dev/null | wc -l | tr -d '[:space:]'
  else
    printf 'unavailable'
  fi
}

fm_lint_load_average() {
  if [ -r /proc/loadavg ]; then
    awk '{print $1 "/" $2 "/" $3}' /proc/loadavg
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/, ""); print $1 "/" $2 "/" $3}' || printf 'unavailable'
  else
    printf 'unavailable'
  fi
}

fm_lint_aggregate_cpu() {
  ps -A -o %cpu= 2>/dev/null | awk '{sum += $1} END {printf "%.2f", sum + 0}'
}

TELEMETRY_START_EPOCH=0
TELEMETRY_SHELLCHECK_START=unavailable
TELEMETRY_LOAD_START=unavailable
TELEMETRY_CPU_START=unavailable
if [ -n "$TELEMETRY" ]; then
  TELEMETRY_START_EPOCH=$(date +%s)
  TELEMETRY_SHELLCHECK_START=$(fm_lint_shellcheck_count)
  TELEMETRY_LOAD_START=$(fm_lint_load_average)
  TELEMETRY_CPU_START=$(fm_lint_aggregate_cpu)
fi

fm_lint_run_worker() {  # <worker-index>
  local worker_index=$1 manifest timing
  manifest="$TMP_ROOT/manifest.$worker_index"
  timing="$TMP_ROOT/timing.$worker_index"
  if [ -n "$TELEMETRY" ] && [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -lp -o "$timing" \
        env FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_FAST="$FAST" \
        FM_LINT_INTERNAL_FOLLOW_SOURCES="$FOLLOW_SOURCES" FM_LINT_INTERNAL_EXCLUDE="$EXCLUDE_CODES" \
        FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    else
      exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
        /usr/bin/time -f 'wall_seconds=%e\nuser_seconds=%U\nsystem_seconds=%S\nmax_rss_kib=%M' -o "$timing" \
        env FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_FAST="$FAST" \
        FM_LINT_INTERNAL_FOLLOW_SOURCES="$FOLLOW_SOURCES" FM_LINT_INTERNAL_EXCLUDE="$EXCLUDE_CODES" \
        FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" \
        "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
    fi
  else
    [ -z "$TELEMETRY" ] || printf 'timing_unavailable=1\n' > "$timing"
    exec "$PERL_BIN" -e 'setpgrp(0, 0) or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
      env FM_LINT_INTERNAL=1 FM_LINT_INTERNAL_FAST="$FAST" \
      FM_LINT_INTERNAL_FOLLOW_SOURCES="$FOLLOW_SOURCES" FM_LINT_INTERNAL_EXCLUDE="$EXCLUDE_CODES" \
      FM_LINT_SHELLCHECK="$SHELLCHECK_BIN" \
      "${BASH:-bash}" "$SELF" --internal-worker "$manifest" "$OUTPUT_DIR" "$worker_index"
  fi
}

fm_lint_start_worker() {
  fm_lint_run_worker "$1" &
  ACTIVE_PIDS+=("$!")
}

fm_lint_wait_workers() {
  local pid
  while [ "${#ACTIVE_PIDS[@]}" -gt 0 ]; do
    pid=${ACTIVE_PIDS[0]}
    wait "$pid" 2>/dev/null || true
    ACTIVE_PIDS=("${ACTIVE_PIDS[@]:1}")
  done
}

reserved=0
peak_reserved=0
peak_parallel=0
current_wave=0
while IFS="$TAB" read -r wave weight worker path heavy unknown; do
  if [ "$wave" -ne "$current_wave" ]; then
    fm_lint_wait_workers
    reserved=0
    current_wave=$wave
  fi
  fm_lint_start_worker "$worker"
  reserved=$((reserved + weight))
  [ "$reserved" -le "$peak_reserved" ] || peak_reserved=$reserved
  [ "${#ACTIVE_PIDS[@]}" -le "$peak_parallel" ] || peak_parallel=${#ACTIVE_PIDS[@]}
done < "$TMP_ROOT/schedule"
fm_lint_wait_workers

# Replay in canonical/explicit root order and select the first nonzero result.
# Every root runs even after earlier findings.
overall_rc=0
worker=0
while [ "$worker" -lt "$SHARD_COUNT" ]; do
  output="$OUTPUT_DIR/shard.$worker"
  [ ! -f "$output.out" ] || cat "$output.out"
  if [ -f "$output.rc" ]; then
    rc=$(cat "$output.rc" 2>/dev/null || printf '2')
    case "$rc" in ''|*[!0-9]*) rc=2 ;; esac
  else
    printf 'fm-lint.sh: worker produced no result for shard %s.\n' "$worker" >&2
    rc=2
  fi
  if [ "$overall_rc" -eq 0 ] && [ "$rc" -ne 0 ]; then
    overall_rc=$rc
  fi
  worker=$((worker + 1))
done

if [ -n "$TELEMETRY" ]; then
  TELEMETRY_END_EPOCH=$(date +%s)
  TELEMETRY_SHELLCHECK_END=$(fm_lint_shellcheck_count)
  TELEMETRY_LOAD_END=$(fm_lint_load_average)
  TELEMETRY_CPU_END=$(fm_lint_aggregate_cpu)

  direct_lines=$(awk 'END {print NR + 0}' "${ROOTS[@]}" 2>/dev/null || printf 'unavailable')
  direct_bytes=0
  : > "$TMP_ROOT/content-cksums"
  : > "$TMP_ROOT/source-targets"
  source_directives=0
  source_boundaries=0
  for path in "${ROOTS[@]}"; do
    if [ -f "$path" ]; then
      bytes=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]')
      case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
      direct_bytes=$((direct_bytes + bytes))
      cksum "$path" >> "$TMP_ROOT/content-cksums" 2>/dev/null || true
      awk '
        /^[[:space:]]*# shellcheck source=/ {
          target=$0
          sub(/^[[:space:]]*# shellcheck source=/, "", target)
          sub(/[[:space:]].*$/, "", target)
          print target
        }
      ' "$path" >> "$TMP_ROOT/source-targets"
    fi
  done
  source_directives=$(wc -l < "$TMP_ROOT/source-targets" | tr -d '[:space:]')
  source_boundaries=$(grep -c '^/dev/null$' "$TMP_ROOT/source-targets" 2>/dev/null || true)
  case "$source_boundaries" in ''|*[!0-9]*) source_boundaries=0 ;; esac
  if [ "$FOLLOW_SOURCES" -eq 1 ]; then
    source_followed=$((source_directives - source_boundaries))
  else
    source_followed=0
  fi
  source_targets=$(LC_ALL=C sort -u "$TMP_ROOT/source-targets" | wc -l | tr -d '[:space:]')
  content_cksum=$(cksum "$TMP_ROOT/content-cksums" | awk '{print $1 "-" $2}')
  git_head=$(git rev-parse HEAD 2>/dev/null || printf 'unavailable')

  if [ -x /usr/bin/time ]; then
    if [ "$(uname)" = Darwin ]; then
      timing_summary=$(awk '
        /^real / {wall += $2; if ($2 > max_wall) max_wall=$2}
        /^user / {user += $2}
        /^sys / {sys_cpu += $2}
        /maximum resident set size/ {
          rss=$1 / 1024
          rss_sum += rss
          if (rss > max_rss) max_rss=rss
        }
        END {printf "%.2f %.2f %.2f %.0f %.0f %.2f", user, sys_cpu, wall, max_rss, rss_sum, max_wall}
      ' "$TMP_ROOT"/timing.*)
    else
      timing_summary=$(awk -F= '
        $1 == "wall_seconds" {wall += $2; if ($2 > max_wall) max_wall=$2}
        $1 == "user_seconds" {user += $2}
        $1 == "system_seconds" {sys_cpu += $2}
        $1 == "max_rss_kib" {rss_sum += $2; if ($2 > max_rss) max_rss=$2}
        END {printf "%.2f %.2f %.2f %.0f %.0f %.2f", user, sys_cpu, wall, max_rss, rss_sum, max_wall}
      ' "$TMP_ROOT"/timing.*)
    fi
    read -r timing_user timing_system timing_worker_wall max_worker_rss worker_rss_sum max_worker_wall <<EOF
$timing_summary
EOF
  else
    timing_user=unavailable
    timing_system=unavailable
    timing_worker_wall=unavailable
    max_worker_rss=unavailable
    worker_rss_sum=unavailable
    max_worker_wall=unavailable
  fi

  telemetry_tmp="$TMP_ROOT/telemetry.tsv"
  {
    printf 'format\tfm-lint-telemetry-v1\n'
    printf 'git_head\t%s\n' "$git_head"
    printf 'content_cksum\t%s\n' "$content_cksum"
    printf 'shellcheck_version\t%s\n' "$resolved"
    printf 'analysis_mode\t%s\n' "$ANALYSIS_MODE"
    printf 'jobs\t%s\n' "$JOBS"
    printf 'root_count\t%s\n' "$ROOT_COUNT"
    printf 'direct_lines\t%s\n' "$direct_lines"
    printf 'direct_bytes\t%s\n' "$direct_bytes"
    printf 'source_directives\t%s\n' "$source_directives"
    printf 'source_boundary_directives\t%s\n' "$source_boundaries"
    printf 'source_followed_directives\t%s\n' "$source_followed"
    printf 'source_target_count\t%s\n' "$source_targets"
    printf 'detected_cpus\t%s\n' "$CPU_COUNT"
    printf 'host_memory_mib\t%s\n' "$HOST_MEMORY_MIB"
    printf 'admission_budget_mib\t%s\n' "$ADMISSION_BUDGET_MIB"
    printf 'peak_reserved_mib\t%s\n' "$peak_reserved"
    printf 'peak_parallel_roots\t%s\n' "$peak_parallel"
    printf 'wall_seconds\t%s\n' "$((TELEMETRY_END_EPOCH - TELEMETRY_START_EPOCH))"
    printf 'worker_wall_sum_seconds\t%s\n' "$timing_worker_wall"
    printf 'max_worker_wall_seconds\t%s\n' "$max_worker_wall"
    printf 'user_seconds\t%s\n' "$timing_user"
    printf 'system_seconds\t%s\n' "$timing_system"
    printf 'max_worker_rss_kib\t%s\n' "$max_worker_rss"
    printf 'worker_rss_sum_kib\t%s\n' "$worker_rss_sum"
    printf 'shellcheck_processes_start\t%s\n' "$TELEMETRY_SHELLCHECK_START"
    printf 'shellcheck_processes_end\t%s\n' "$TELEMETRY_SHELLCHECK_END"
    printf 'load_average_start\t%s\n' "$TELEMETRY_LOAD_START"
    printf 'load_average_end\t%s\n' "$TELEMETRY_LOAD_END"
    printf 'aggregate_cpu_percent_start\t%s\n' "$TELEMETRY_CPU_START"
    printf 'aggregate_cpu_percent_end\t%s\n' "$TELEMETRY_CPU_END"
    printf 'result_exit\t%s\n' "$overall_rc"
  } > "$telemetry_tmp"
  if ! mv -f "$telemetry_tmp" "$TELEMETRY"; then
    printf 'fm-lint.sh: could not write telemetry to %s.\n' "$TELEMETRY" >&2
    [ "$overall_rc" -ne 0 ] || overall_rc=2
  fi
fi

purity_rc=0
fm_lint_run_backend_purity || purity_rc=$?
if [ "$overall_rc" -eq 0 ] && [ "$purity_rc" -ne 0 ]; then
  overall_rc=$purity_rc
fi

if [ "$overall_rc" -eq 0 ]; then
  fm_lint_run_workflows || overall_rc=$?
else
  fm_lint_run_workflows || true
fi

exit "$overall_rc"
