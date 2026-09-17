#!/usr/bin/env bash
# bin/backends/stream.sh - the stream session-provider adapter (EXPERIMENTAL).
#
# The fleet keeps ONE hub (bin/fm-stream-hub.py). Each task's pseudoterminal is
# owned by a thin agent (bin/fm-stream-agent.py) on the machine that runs it,
# publishing to that hub. This adapter is firstmate's half: it creates, steers,
# reads, classifies, and closes endpoints through the hub's HTTP API, and never
# talks to a worker machine directly.
# docs/stream-backend.md owns setup, security, and limits.
#
# Session provider ONLY, exactly like herdr/zellij/cmux: Treehouse still owns
# the task worktree.
#
# Target string shape: "<hub-tag>:<endpoint-id>".
#   hub-tag     - a stable, colon-free identity for the hub an endpoint was
#                 created on, derived from its base URL (see
#                 fm_backend_stream_hub_tag).
#   endpoint-id - the hub's own 32-hex durable endpoint id.
# The tag keeps an endpoint addressable only through the hub it actually lives
# on: a target recorded against one hub refuses to operate against a different
# configured one instead of silently addressing a same-named endpoint
# elsewhere. Splitting on the FIRST colon stays trivially correct because
# neither half can contain one.
#
# Explicit-only: stream is never auto-detected. An endpoint is reachable from
# any machine that can reach the hub, so "firstmate happens to be running
# inside one" is not a signal that exists, and inventing one would route tasks
# to a hub nobody chose.

# Shared composer-content classifier (empty|pending|unknown, and the fleet-wide
# dead-shell-vs-agent-composer rule). Owned by bin/fm-composer-lib.sh, reused by
# every backend so the decision cannot drift.
# shellcheck source=bin/fm-composer-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-composer-lib.sh"
# Backend-neutral harness-process identity, shared with the tmux and herdr
# adapters so all three mean the same thing by agent, shell, and other.
# shellcheck source=bin/fm-agent-process-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../fm-agent-process-lib.sh"

# The wire protocol this adapter implements. A hub announcing anything else is
# refused loudly rather than driven on guessed routes.
FM_BACKEND_STREAM_PROTOCOL=2
FM_BACKEND_STREAM_DEFAULT_URL="http://127.0.0.1:7717"
FM_BACKEND_STREAM_AGENT_BIN="$(dirname -- "${BASH_SOURCE[0]}")/../fm-stream-agent.py"

# How long a 404 has to keep being the answer before it counts as `missing`.
# A hub that restarted has forgotten every endpoint until each agent registers
# itself again, so a verdict taken inside that window is about the hub rather
# than the worker.
#
# The number is derived from both ends, and both matter.
#   Lower bound - what it has to outlast. An agent discovers the hub forgot it
#   only by publishing, and an idle worker publishes nothing but its state
#   heartbeat, which at shipped defaults is every 5s (bin/fm-stream-agent.py's
#   --state-interval default, capped by the hub's state_max_age_secs/3). Add
#   the registration round trip it then makes: ~5s before the endpoint is back.
#   Upper bound - what it has to fit inside. Callers bound this classifier:
#   fm-fleet-snapshot.sh gives 10s to a whole crew-state read, of which this
#   probe is one part, so a torn-down endpoint has to reach `missing` well
#   within that rather than timing the caller out and folding to unknown.
# 6s clears the first and leaves ~4s of the second for everything else a
# crew-state read does. A recovery slower than that is not free: fm-watch.sh
# treats `missing` like `dead` and escalates the pending steer, and an
# escalated record is one fm_task_inbox_due_action stays quiet about, so that
# steer leaves the delivery ladder rather than being rung again. Which is the
# cost this window is sized to avoid paying, not one it hands on to a retry.
FM_BACKEND_STREAM_MISSING_GRACE_SECS=6

# The last HTTP status fm_backend_stream_api saw. Initialised at source time so
# an error path that runs before any request - a missing token, an unreachable
# hub - can report it without tripping `set -u` in a caller.
: "${FM_BACKEND_STREAM_HTTP_CODE:=000}"

fm_backend_stream_config_dir() {
  printf '%s' "${FM_CONFIG_OVERRIDE:-${FM_HOME:-$FM_ROOT}/config}"
}

fm_backend_stream_config_line() {  # <config-file-name>
  local file
  file="$(fm_backend_stream_config_dir)/$1"
  [ -f "$file" ] || return 1
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    printf '%s' "$line"
    return 0
  done < "$file"
  return 1
}

# fm_backend_stream_hub_url: FM_STREAM_HUB, then config/stream-hub, then a hub
# this home started itself, then the localhost default. The value is used
# exactly as configured, scheme included, so pointing this home at a hub behind
# a TLS terminator is a config change and needs no change here.
#
# The locally started hub ranks below both configured sources and above the
# default only. It exists because `hub start --port N` otherwise left every
# other command resolving the default port: the hub was up, and `status`, `web`,
# and every task command reported it down. Reading the port the hub actually
# bound is strictly better than assuming one, and a home pointed at the fleet's
# hub still wins through its own configuration.
fm_backend_stream_hub_url() {
  local url ready host port
  if [ -n "${FM_STREAM_HUB:-}" ]; then
    url=$FM_STREAM_HUB
  elif url=$(fm_backend_stream_config_line stream-hub); then
    :
  elif ready="${FM_STATE_OVERRIDE:-${FM_HOME:-$FM_ROOT}/state}/.stream-hub.ready" \
    && [ -s "$ready" ] \
    && read -r host port < "$ready" \
    && [ -n "${host:-}" ] && [ -n "${port:-}" ]; then
    url="http://$host:$port"
  else
    url=$FM_BACKEND_STREAM_DEFAULT_URL
  fi
  case "$url" in
    http://*|https://*) ;;
    *)
      echo "error: backend=stream hub URL '$url' must start with http:// or https://" >&2
      return 1
      ;;
  esac
  printf '%s' "${url%/}"
}

# fm_backend_stream_hub_tag: the colon-free endpoint-target half derived from a
# hub URL. Scheme is dropped and every character outside the endpoint-atom
# alphabet becomes '-', so "http://hub.example:7717" tags as
# "hub.example-7717" and passes fm_backend_endpoint_atom_valid.
fm_backend_stream_hub_tag() {  # [url]
  local url=${1:-}
  [ -n "$url" ] || url=$(fm_backend_stream_hub_url) || return 1
  url=${url#http://}
  url=${url#https://}
  url=${url%/}
  printf '%s' "$url" | tr -c 'A-Za-z0-9._-' '-'
}

# fm_backend_stream_token: the bearer token. Absent is a refusal, never an
# unauthenticated call: a hub can start a process on any machine that publishes
# to it, so an adapter that quietly dropped the credential would be asking a
# stranger's hub to do it.
fm_backend_stream_token() {
  local token
  if [ -n "${FM_STREAM_TOKEN:-}" ]; then
    printf '%s' "$FM_STREAM_TOKEN"
    return 0
  fi
  if token=$(fm_backend_stream_config_line stream-token); then
    printf '%s' "$token"
    return 0
  fi
  echo "error: backend=stream needs a hub token; set FM_STREAM_TOKEN or create $(fm_backend_stream_config_dir)/stream-token (bin/fm-stream.sh token --ensure)" >&2
  return 1
}

fm_backend_stream_tool_check() {
  local tool
  for tool in curl jq python3; do
    command -v "$tool" >/dev/null 2>&1 || {
      echo "error: backend=stream selected but '$tool' is not installed" >&2
      return 1
    }
  done
  [ -f "$FM_BACKEND_STREAM_AGENT_BIN" ] || {
    echo "error: backend=stream selected but the agent $FM_BACKEND_STREAM_AGENT_BIN is missing" >&2
    return 1
  }
}

# fm_backend_stream_api: one authenticated hub call.
#
# The bearer token is handed to curl through a --config file on a process
# substitution descriptor, never as an argument: /proc/<pid>/cmdline is
# world-readable on Linux, so a -H "Authorization: ..." would publish the
# credential to every local user for the life of the call.
#
# Prints the response body and reports the outcome in its EXIT STATUS, not only
# in a global: almost every caller reads the body through a command
# substitution, and a variable set inside that subshell never reaches the
# caller.
#
#   0  2xx
#   1  unreachable, or a precondition (URL, token) that stopped the request
#   2  401/403
#   3  404
#   4  any other HTTP error
#
# FM_BACKEND_STREAM_HTTP_CODE still carries the exact code for a direct,
# non-subshell caller. It is set to 000 BEFORE the preconditions, so a caller
# whose error path reports the code still has one when no request was made.
fm_backend_stream_api() {  # <method> <path> [json-body]
  local method=$1 path=$2 body=${3:-} url token raw code out
  FM_BACKEND_STREAM_HTTP_CODE=000
  url=$(fm_backend_stream_hub_url) || return 1
  token=$(fm_backend_stream_token) || return 1
  if [ -n "$body" ]; then
    raw=$(printf '%s' "$body" | curl -sS -m "${FM_STREAM_HTTP_TIMEOUT:-30}" \
      --config <(printf 'header = "Authorization: Bearer %s"\n' "$token") \
      -X "$method" -H 'Content-Type: application/json' --data-binary @- \
      -w '\n%{http_code}' "$url$path" 2>/dev/null) || return 1
  else
    raw=$(curl -sS -m "${FM_STREAM_HTTP_TIMEOUT:-30}" \
      --config <(printf 'header = "Authorization: Bearer %s"\n' "$token") \
      -X "$method" -w '\n%{http_code}' "$url$path" 2>/dev/null) || return 1
  fi
  code=${raw##*$'\n'}
  out=${raw%$'\n'*}
  FM_BACKEND_STREAM_HTTP_CODE=$code
  printf '%s' "$out"
  case "$code" in
    2??) return 0 ;;
    401|403) return 2 ;;
    404) return 3 ;;
    000|'') return 1 ;;
    *) return 4 ;;
  esac
}

fm_backend_stream_api_error() {  # <body>
  local message
  message=$(printf '%s' "$1" | jq -r '.message // .error // empty' 2>/dev/null)
  [ -n "$message" ] || message="HTTP ${FM_BACKEND_STREAM_HTTP_CODE:-000}"
  printf '%s' "$message"
}

# fm_backend_stream_version_check: reachability plus the protocol gate. A
# missing, unreachable, unauthenticated, or protocol-mismatched hub is terminal
# for a stream spawn; firstmate surfaces it as a blocker rather than quietly
# landing the task on another backend.
fm_backend_stream_version_check() {
  local out protocol status=0
  fm_backend_stream_tool_check || return 1
  out=$(fm_backend_stream_api GET /v1/health) || status=$?
  if [ "${status:-0}" -ne 0 ]; then
    case "$status" in
      1)
        echo "error: backend=stream cannot reach the hub at $(fm_backend_stream_hub_url); start it with bin/fm-stream.sh hub start, or point FM_STREAM_HUB at the fleet's hub" >&2
        ;;
      2)
        echo "error: backend=stream was refused by the hub at $(fm_backend_stream_hub_url): the configured token is not accepted, or does not hold the class this call needs" >&2
        ;;
      *)
        echo "error: backend=stream hub health check failed: $(fm_backend_stream_api_error "$out")" >&2
        ;;
    esac
    return 1
  fi
  protocol=$(printf '%s' "$out" | jq -r '.protocol // empty' 2>/dev/null)
  case "$protocol" in
    ''|*[!0-9]*)
      echo "error: backend=stream hub did not report a protocol number; refusing to drive an unknown hub" >&2
      return 1
      ;;
  esac
  [ "$protocol" = "$FM_BACKEND_STREAM_PROTOCOL" ] || {
    echo "error: backend=stream hub speaks protocol $protocol but this firstmate implements $FM_BACKEND_STREAM_PROTOCOL; update both ends" >&2
    return 1
  }
}

# fm_backend_stream_container_ensure: the hub plays the container role the tmux
# session and zellij session play. It is never started implicitly - an endpoint
# outlives the command that made it, and the fleet's hub is a service somebody
# chose to run, not a side effect of a spawn.
fm_backend_stream_container_ensure() {
  fm_backend_stream_version_check || return 1
  fm_backend_stream_hub_tag
}

# fm_backend_stream_machine: this home's name in the fleet. Endpoints are
# grouped by it in the one central view, so it is a readable identity rather
# than an opaque id.
fm_backend_stream_machine() {
  local name
  if [ -n "${FM_STREAM_MACHINE:-}" ]; then
    name=$FM_STREAM_MACHINE
  elif name=$(fm_backend_stream_config_line stream-machine); then
    :
  else
    name=$(hostname 2>/dev/null) || name=unknown
  fi
  printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '-'
}

# fm_backend_stream_create_task: start the LOCAL agent that will own this task's
# pseudoterminal, and echo "<tag> <endpoint-id>" once it has registered.
#
# The agent is started here, on this machine, precisely because a pty must live
# where its process runs. <status-path> and <cwd> are handed to that local agent
# and never sent to the hub, which is what lets a worker on any machine report
# into its own home's records.
fm_backend_stream_create_task() {  # <label> <cwd> [status-path]
  local label=$1 cwd=$2 status_path=${3:-} tag machine ready endpoint token_file agent_log reason
  tag=$(fm_backend_stream_hub_tag) || return 1
  machine=$(fm_backend_stream_machine) || return 1
  ready=$(mktemp "${TMPDIR:-/tmp}/fm-stream-ready.XXXXXX") || return 1
  token_file=$(mktemp "${TMPDIR:-/tmp}/fm-stream-tok.XXXXXX") || { rm -f "$ready"; return 1; }
  agent_log=$(mktemp "${TMPDIR:-/tmp}/fm-stream-agent.XXXXXX") || { rm -f "$ready" "$token_file"; return 1; }
  chmod 600 "$token_file"
  fm_backend_stream_token > "$token_file" || { rm -f "$ready" "$token_file" "$agent_log"; return 1; }
  # The agent's own refusal - the shell's error text when an endpoint's process
  # cannot start - is the only account of why a spawn failed, so it is kept
  # rather than discarded into /dev/null. The credential still reaches the agent
  # through a file, never a command line.
  (
    setsid python3 "$FM_BACKEND_STREAM_AGENT_BIN" serve \
      --hub "$(fm_backend_stream_hub_url)" \
      --token-file "$token_file" \
      --machine "$machine" \
      --label "$label" \
      --cwd "$cwd" \
      --status-path "$status_path" \
      --ready-file "$ready" \
      >"$agent_log" 2>&1 < /dev/null &
  )
  local waited=0
  while [ "$waited" -lt 150 ]; do
    [ -s "$ready" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  if [ ! -s "$ready" ]; then
    reason=$(tail -n 1 "$agent_log" 2>/dev/null)
    rm -f "$ready" "$token_file" "$agent_log"
    # Nothing is closed from here. An attempt that registered before giving up
    # closes its OWN endpoint id, which only the agent knows; matching by
    # machine and label instead would eventually find a healthy worker another
    # home registered under the same name and kill it.
    if [ -n "$reason" ]; then
      echo "error: the stream agent refused to start an endpoint for '$label': $reason" >&2
    else
      echo "error: the stream agent did not register an endpoint for '$label' within 15s" >&2
    fi
    return 1
  fi
  read -r _ endpoint < "$ready"
  rm -f "$ready" "$token_file" "$agent_log"
  case "$endpoint" in
    ''|*[!0-9a-f]*)
      echo "error: the stream agent did not return a durable endpoint id for '$label'" >&2
      return 1
      ;;
  esac
  printf '%s %s' "$tag" "$endpoint"
}

# fm_backend_stream_parse_target: split "<tag>:<endpoint>" and prove the tag
# names the hub this process is configured for. Sets FM_BACKEND_STREAM_TAG and
# FM_BACKEND_STREAM_ENDPOINT on success.
fm_backend_stream_parse_target() {  # <target>
  local target=$1 tag endpoint configured
  FM_BACKEND_STREAM_TAG=
  FM_BACKEND_STREAM_ENDPOINT=
  case "$target" in
    *:*) ;;
    *) echo "error: malformed stream target '$target' (expected <hub-tag>:<endpoint-id>)" >&2; return 1 ;;
  esac
  tag=${target%%:*}
  endpoint=${target#*:}
  case "$endpoint" in
    *:*|'') echo "error: malformed stream target '$target' (expected <hub-tag>:<endpoint-id>)" >&2; return 1 ;;
  esac
  case "$endpoint" in
    *[!0-9a-f]*) echo "error: malformed stream endpoint id in '$target'" >&2; return 1 ;;
  esac
  [ -n "$tag" ] || { echo "error: malformed stream target '$target' (empty hub tag)" >&2; return 1; }
  configured=$(fm_backend_stream_hub_tag) || return 1
  [ "$tag" = "$configured" ] || {
    echo "error: endpoint '$target' belongs to hub '$tag' but this home is configured for '$configured'; refusing to address a different hub" >&2
    return 1
  }
  # shellcheck disable=SC2034 # Output global consumed by sourcing callers.
  FM_BACKEND_STREAM_TAG=$tag
  # shellcheck disable=SC2034 # Output global consumed by sourcing callers.
  FM_BACKEND_STREAM_ENDPOINT=$endpoint
}

# fm_backend_stream_target_ready: the endpoint exists on the configured hub and,
# when an expected label is given, is the one that carries it. The label check
# keeps a recycled or mistaken endpoint id from being steered as this task.
#
# This probe answers from the first reply and takes no grace window, because
# its callers - capture, current-path, input - need an answer now and ask again
# when refused. So its 404 can be transient: the hub's registry is in memory,
# and after a hub restart every endpoint is unknown until its agent registers
# again seconds later. Never treat a 404 here as authoritative absence; the
# settled answer to that question is fm_backend_stream_agent_state's `missing`,
# which is the verdict that outlasts the re-registration window.
fm_backend_stream_target_ready() {  # <target> [expected-label]
  local target=$1 expected=${2:-} out label
  fm_backend_stream_parse_target "$target" >/dev/null 2>&1 || return 1
  out=$(fm_backend_stream_api GET "/v1/tasks/$FM_BACKEND_STREAM_ENDPOINT" 2>/dev/null) || return 1
  [ -n "$expected" ] || return 0
  label=$(printf '%s' "$out" | jq -r '.task.label // empty' 2>/dev/null)
  [ "$label" = "$expected" ]
}

fm_backend_stream_capture() {  # <target> <lines> [expected-label]
  local target=$1 lines=${2:-40} expected=${3:-}
  fm_backend_stream_target_ready "$target" "$expected" || return 1
  fm_backend_stream_api GET "/v1/tasks/$FM_BACKEND_STREAM_ENDPOINT/capture?lines=$lines"
}

# fm_backend_stream_current_path: the endpoint's live foreground working
# directory, the same question tmux answers with #{pane_current_path}. The
# owning agent reads it from a running process, so spawn-time worktree
# discovery needs no marker probe of the kind zellij and cmux require for their
# creation-time-frozen values.
fm_backend_stream_current_path() {  # <target> [expected-label]
  local target=$1 expected=${2:-} out path stale
  fm_backend_stream_target_ready "$target" "$expected" || return 1
  out=$(fm_backend_stream_api GET "/v1/tasks/$FM_BACKEND_STREAM_ENDPOINT/cwd") || return 1
  stale=$(printf '%s' "$out" | jq -r '.stale // empty' 2>/dev/null)
  [ "$stale" = true ] && return 1
  path=$(printf '%s' "$out" | jq -r '.cwd // empty' 2>/dev/null)
  [ -n "$path" ] || return 1
  printf '%s' "$path"
}

fm_backend_stream_input() {  # <target> <json-payload> [expected-label]
  local target=$1 payload=$2 expected=${3:-} out
  fm_backend_stream_target_ready "$target" "$expected" || return 1
  if ! out=$(fm_backend_stream_api POST "/v1/tasks/$FM_BACKEND_STREAM_ENDPOINT/input" "$payload"); then
    # The hub only answers 200 once the OWNING AGENT has acknowledged, so this
    # refusal means the text did not reach the worker - which is exactly what
    # fm-send needs in order to refuse rather than report a lost steer.
    echo "error: stream input to '$target' was not delivered: $(fm_backend_stream_api_error "$out")" >&2
    return 1
  fi
}

# Literal text, no submission - the fleet-wide "type, then Enter separately"
# contract every adapter follows.
fm_backend_stream_send_literal() {  # <target> <text> [expected-label]
  local target=$1 text=$2 expected=${3:-} payload
  payload=$(jq -nc --arg text "$text" '{text: $text}') || return 1
  fm_backend_stream_input "$target" "$payload" "$expected"
}

# The shared key vocabulary, and nothing beyond it: bin/fm-control-lib.sh is the
# owner of which keys a backend may claim, and a key with no spelling there is
# unreachable through every firstmate path.
fm_backend_stream_normalize_key() {  # <key>
  case "$1" in
    Enter|enter|C-m) printf 'Enter' ;;
    Escape|escape|Esc|esc) printf 'Escape' ;;
    C-c|ctrl+c|Ctrl-c|Ctrl-C) printf 'C-c' ;;
    C-u|ctrl+u|Ctrl-u|Ctrl-U) printf 'C-u' ;;
    *) return 1 ;;
  esac
}

fm_backend_stream_send_key() {  # <target> <key> [expected-label]
  local target=$1 key=$2 expected=${3:-} normalized payload
  normalized=$(fm_backend_stream_normalize_key "$key") || {
    echo "error: stream cannot deliver key '$key'" >&2
    return 1
  }
  payload=$(jq -nc --arg key "$normalized" '{keys: [$key]}') || return 1
  fm_backend_stream_input "$target" "$payload" "$expected"
}

fm_backend_stream_send_text_line() {  # <target> <text> [expected-label]
  local target=$1 text=$2 expected=${3:-} payload
  payload=$(jq -nc --arg text "$text" '{text: $text, submit: true}') || return 1
  fm_backend_stream_input "$target" "$payload" "$expected"
}

fm_backend_stream_composer_capture() {  # <target> [expected-label] -> "<cursor-row>\n<screen>"
  local target=$1 expected=${2:-} out cursor screen
  fm_backend_stream_target_ready "$target" "$expected" || return 1
  out=$(fm_backend_stream_api GET "/v1/tasks/$FM_BACKEND_STREAM_ENDPOINT/screen?format=ansi") || return 1
  cursor=$(printf '%s' "$out" | jq -r '.cursor_row // empty' 2>/dev/null)
  case "$cursor" in
    ''|*[!0-9]*) cursor=0 ;;
  esac
  screen=$(printf '%s' "$out" | jq -r '.screen // empty' 2>/dev/null)
  # The cursor row and the screen are packed as "<cursor>\n|<screen>". The bar
  # opens the screen half and is what survives: a caller reads this through a
  # command substitution, which strips every trailing newline, so an all-blank
  # screen would otherwise arrive as the cursor digits alone and each composer
  # verdict on a blank endpoint would be read off them.
  printf '%s\n|%s\n' "$cursor" "$screen"
}

# fm_backend_stream_composer_caps: static capability facts, not logic (see the
# capability model in bin/fm-composer-lib.sh).
#   styled=1  the hub renders SGR runs back into the screen it returns.
#   cursor=1  the hub reports the real cursor row of that same screen, so the
#             shape CONTAINING the cursor selects the composer, exactly as it
#             does on tmux.
#   identity=0 there is no native agent-state probe; the agent reports the
#             processes on the pseudoterminal, which is liveness, not the
#             idle/working verdict Pi's blank separated composer would need.
fm_backend_stream_composer_caps() {
  printf 'styled=1\ncursor=1\nidentity=0\nrows=0\n'
}

fm_backend_stream_composer_state() {  # <target> [expected-label] -> empty|pending|pending-unproven|unknown
  local raw cursor screen verdict
  raw=$(fm_backend_stream_composer_capture "$1" "${2:-}") || { printf 'unknown'; return 0; }
  cursor=${raw%%$'\n'*}
  screen=${raw#*$'\n'}
  screen=${screen#|}
  verdict=$(fm_composer_classify_screen "$(fm_backend_stream_composer_caps)" "$screen" "$cursor")
  [ "$verdict" != need-identity ] || verdict=unknown
  printf '%s' "$verdict"
}

# fm_backend_stream_send_text_submit: type <text> once, then drive the shared
# verify-and-retry-Enter loop against the shared composer verdict, so a
# slash-command popup placeholder fill gets its required second Enter without
# ever retyping the message.
fm_backend_stream_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [expected-label]
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 expected=${6:-}
  fm_backend_stream_send_literal "$target" "$text" "$expected" || { printf 'send-failed'; return 0; }
  sleep "$settle"
  fm_composer_submit_retry_core fm_backend_stream_send_key fm_backend_stream_composer_state \
    "$target" "$retries" "$sleep_s" "$expected"
}

# fm_backend_stream_agent_state: the recovery-grade classifier. See
# bin/fm-backend.sh's fm_backend_agent_state for the shared vocabulary.
#
#   missing    the hub answered and has no such endpoint (404), and went on
#              saying so for long enough that no agent is still coming back.
#   dead       the owning agent POSITIVELY reported the process gone, or a
#              foreground group that is nothing but shells.
#   alive      a verified harness is in that reported foreground group.
#   ambiguous  the foreground group holds a process no identity surface can
#              attribute.
#   unreadable the hub could not be reached, contradicted itself, or - and this
#              is the case relaying adds - the owning agent has gone quiet, so
#              the last state frame is too old to act on.
#
# That last case is the whole difference between a central hub and a local
# broker. A partitioned agent and a dead worker look identical from here, and
# only one of them authorizes recovery, so a stale reading is `unreadable` and
# NEVER `dead`. The hub marks staleness; this refuses to classify past it -
# except where the hub holds the agent's own report that the worker exited,
# which is a recorded event rather than a reading and never goes stale.
#
# Identity is classified HERE, from the records the agent published, not on the
# hub or the agent: that keeps one owner (bin/fm-agent-process-lib.sh) for what
# a process name means, so every backend gives the same verdict.
fm_backend_stream_agent_state() {  # <target>
  local target=$1 out stale alive count classified seen=0 shell_seen=0 other_seen=0
  local index name argv0 args status=0 waited=0
  fm_backend_stream_parse_target "$target" >/dev/null 2>&1 || { printf 'unreadable'; return 0; }
  # A 404 is no longer a settled answer on its own. The hub keeps its endpoint
  # registry in memory, so a hub that restarted has no such endpoint for anyone
  # until each agent registers itself again - which happens within seconds and
  # without an operator. Reporting `missing` from the first 404 is what drops a
  # pending steer for a worker that is about to be back, so it has to keep
  # being the answer before it counts as one. A hub that really has forgotten
  # an endpoint says so every time and still reaches `missing`, just later.
  while :; do
    status=0
    out=$(fm_backend_stream_api GET "/v1/tasks/$FM_BACKEND_STREAM_ENDPOINT/processes" 2>/dev/null) || status=$?
    [ "$status" -eq 3 ] || break
    [ "$waited" -lt "$FM_BACKEND_STREAM_MISSING_GRACE_SECS" ] || break
    waited=$((waited + 1))
    sleep 1
  done
  if [ "$status" -ne 0 ]; then
    case "$status" in
      3) printf 'missing' ;;
      *) printf 'unreadable' ;;
    esac
    return 0
  fi
  # Staleness governs live READINGS, not recorded facts. A close the endpoint's
  # OWN agent reported is that agent watching the worker exit and carrying its
  # exit code back - an event that already happened, which no amount of elapsed
  # silence makes less true. So it answers before the freshness gate. A close
  # the hub made by itself is an unacknowledged kill and says nothing about the
  # worker, which is why only `agent` counts here, exactly as the kill path
  # already requires.
  case "$(printf '%s' "$out" | jq -r '.closed_by // empty' 2>/dev/null)" in
    agent) printf 'dead'; return 0 ;;
  esac
  stale=$(printf '%s' "$out" | jq -r '.stale' 2>/dev/null)
  case "$stale" in
    false) ;;
    true) printf 'unreadable'; return 0 ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  alive=$(printf '%s' "$out" | jq -r '.alive' 2>/dev/null)
  case "$alive" in
    true) ;;
    false) printf 'dead'; return 0 ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  count=$(printf '%s' "$out" | jq -r '.foreground | length' 2>/dev/null)
  case "$count" in
    ''|*[!0-9]*) printf 'unreadable'; return 0 ;;
  esac
  index=0
  while [ "$index" -lt "$count" ]; do
    name=$(printf '%s' "$out" | jq -r --argjson i "$index" '.foreground[$i].name // ""' 2>/dev/null)
    argv0=$(printf '%s' "$out" | jq -r --argjson i "$index" '.foreground[$i].argv0 // ""' 2>/dev/null)
    args=$(printf '%s' "$out" | jq -r --argjson i "$index" '.foreground[$i].args // ""' 2>/dev/null)
    index=$((index + 1))
    [ -n "$name$argv0$args" ] || continue
    seen=1
    # No pid is ever passed to the classifier. The process belongs to whichever
    # machine published it, so a local pid read here would describe a stranger
    # - and unlike the previous per-machine design, the hub is never guaranteed
    # to be the same machine as the worker.
    classified=$(fm_agent_process_classify "$name" "$argv0" "$args" "")
    case "$classified" in
      agent) printf 'alive'; return 0 ;;
      shell) shell_seen=1 ;;
      *) other_seen=1 ;;
    esac
  done
  if [ "$seen" -eq 0 ] || [ "$other_seen" -eq 1 ]; then
    printf 'ambiguous'
    return 0
  fi
  if [ "$shell_seen" -eq 1 ]; then
    printf 'dead'
    return 0
  fi
  printf 'ambiguous'
}

fm_backend_stream_kill() {  # <target> [unused] [expected-label]
  local target=$1 expected=${3:-} task out
  fm_backend_stream_parse_target "$target" >/dev/null 2>&1 || return 0
  # One read answers both questions this needs: whose task this id names, and
  # whether the hub already watched the worker go. A read that FAILS answers
  # neither, so it is reported rather than taken for a stop - a hub that cannot
  # be reached, or that forgot an endpoint it stopped hearing from, knows
  # nothing about whether that worker is still running.
  task=$(fm_backend_stream_api GET "/v1/tasks/$FM_BACKEND_STREAM_ENDPOINT" 2>/dev/null) || {
    echo "error: the stream hub could not say what $FM_BACKEND_STREAM_ENDPOINT is;" \
         "the worker may still be running" >&2
    return 1
  }
  if [ -n "$expected" ]; then
    # A mismatched label means the id names something other than this task, so
    # closing it would destroy a stranger's endpoint.
    [ "$(printf '%s' "$task" | jq -r '.task.label // empty' 2>/dev/null)" = "$expected" ] || return 0
  fi
  # An endpoint its own agent closed is the one confirmed stop there is: that
  # agent watched the worker exit and carried its exit code back. A record the
  # hub closed by itself says nothing about the process.
  [ "$(printf '%s' "$task" | jq -r '.task.closed_by // empty' 2>/dev/null)" = agent ] && return 0
  out=$(fm_backend_stream_api DELETE "/v1/tasks/$FM_BACKEND_STREAM_ENDPOINT" 2>/dev/null) || {
    echo "error: the stream hub refused or never answered the kill for" \
         "$FM_BACKEND_STREAM_ENDPOINT; the worker may still be running" >&2
    return 1
  }
  # The hub answers whether the owning agent actually took the kill. A record
  # it closed on its own says nothing about the worker's process, and reporting
  # that as a stop would let a task be treated as gone while it still runs.
  case "$(printf '%s' "$out" | jq -r '.delivered' 2>/dev/null)" in
    false)
      echo "error: the stream hub closed its record for $FM_BACKEND_STREAM_ENDPOINT," \
           "but its agent never acknowledged the kill; the worker may still be running" >&2
      return 1
      ;;
  esac
}

# fm_backend_stream_report_status: the status return channel (lifecycle point
# 5). The hub routes it to the owning agent, which appends one ordinary status
# line to the record it registered - on its own machine. The path never crosses
# the network, which is why a worker anywhere reports into firstmate's ordinary
# state/<id>.status lifecycle record exactly like a local one.
fm_backend_stream_report_status() {  # <target> <state> <note>
  local target=$1 state=$2 note=$3 payload out
  fm_backend_stream_parse_target "$target" >/dev/null 2>&1 || return 1
  payload=$(jq -nc --arg state "$state" --arg note "$note" '{state: $state, note: $note}') || return 1
  if ! out=$(fm_backend_stream_api POST "/v1/tasks/$FM_BACKEND_STREAM_ENDPOINT/status" "$payload"); then
    echo "error: stream status for '$target' was not recorded: $(fm_backend_stream_api_error "$out")" >&2
    return 1
  fi
}

fm_backend_stream_list_live() {
  local out
  out=$(fm_backend_stream_api GET /v1/tasks) || return 1
  printf '%s' "$out" | jq -r '.tasks[]? | select(.closed_at == null) | "\(.machine)\t\(.label)\t\(.endpoint_id)"' 2>/dev/null
}
