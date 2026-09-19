#!/usr/bin/env bash
# tests/remote-herdr-fixture.sh - the stateful herdr CLI fixture the remote
# second-mate suites install on their fake remote host.
#
# A remote second mate always launches on the Herdr backend
# (docs/remote-secondmates.md), so a remote-route test needs a herdr CLI on the
# remote code root's own bin directory. This fixture models the workspace, tab,
# pane, and agent facts bin/backends/herdr.sh actually reads, backed by a JSON
# state file mutated with real jq, using the same verified herdr behaviors as
# tests/fm-backend-herdr.test.sh's stateful fake: workspace create seeds one
# default tab and returns its tab and root pane in the same response, closing a
# tab's only pane closes the tab, and agent get reports agent_not_found for a
# pane no agent has registered on.
#
# Beyond that it models the pane IO a real launch performs. A pane reports a
# registered agent once anything has been typed into it, and submitting starts
# one turn: the next agent read reports working and the pane settles back to
# idle, which is the native transition the adapter confirms a submit with.
#
# Usage:
#   . "$(dirname "${BASH_SOURCE[0]}")/remote-herdr-fixture.sh"
#   install_remote_herdr_fixture <remote-root> <state-file> <log-file> \
#     <send-fail-flag> <socket-path>
#
# A submitted launch line also starts a real stand-in agent process, because a
# remote launch proves its replacement by process identity: argv[0] is the
# harness word the line names, its arguments carry the Claude permission flag
# the line carries, `pane process-info` reports it as the pane's foreground
# process, a pane close hangs it up, and it exits on its own once <state-file>
# is gone. The stand-in's pid is `.agents[<pane>]` in the state file.
#
# Every invocation is appended verbatim to <log-file>, so a test reads back what
# the remote pane received. Creating <send-fail-flag> makes every pane write
# fail, which is how a test simulates an endpoint that cannot be reached, and
# creating "<send-fail-flag>.close" makes every pane close fail with the pane
# left standing, which is how a test simulates a close no read can confirm.
# Creating "<send-fail-flag>.bare" starts later stand-ins without the permission
# flag, the shape of a session some other launcher resumed, and creating
# "<send-fail-flag>.survive" lets a stand-in outlive its pane's close.

install_remote_herdr_fixture() { # <remote-root> <state> <log> <send-fail> <socket>
  local remote_root=$1 state=$2 log=$3 send_fail=$4 socket=$5 script="$1/bin/herdr"
  mkdir -p "$remote_root/bin"
  cat > "$script" <<SH
#!/usr/bin/env bash
set -u
STATE='$state'
LOG='$log'
SEND_FAIL='$send_fail'
CLOSE_FAIL='$send_fail.close'
BARE_AGENT='$send_fail.bare'
SURVIVE_CLOSE='$send_fail.survive'
SOCKET='$socket'
SH
  cat >> "$script" <<'SH'
printf '%s\n' "$*" >> "$LOG"
jq_state() { jq "$@" "$STATE"; }
save() { tmp="$STATE.tmp.$$"; cat > "$tmp" && mv "$tmp" "$STATE"; }
agent_pid() { jq -r --arg p "$1" '.agents[$p] // empty' "$STATE"; }
agent_live() { local pid; pid=$(agent_pid "$1"); [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }
# start_agent <pane>: the stand-in for the harness the pane's submitted line names.
start_agent() {
  local p=$1 text harness='' word prev='' pid
  local -a flags=() words=()
  agent_live "$p" && return 0
  text=$(jq -r --arg p "$p" '.text[$p] // empty' "$STATE")
  read -r -d '' -a words <<< "$text" || true
  for word in ${words[@]+"${words[@]}"}; do
    case "${word##*/}" in
      claude|codex|opencode|pi|pi-signed|grok|kimi|cursor-agent) [ -n "$harness" ] || harness=${word##*/} ;;
    esac
    if [ ! -f "$BARE_AGENT" ]; then
      case "$word" in --dangerously-skip-permissions) flags+=("$word") ;; esac
      [ "$prev" != --permission-mode ] || flags+=(--permission-mode "$word")
    fi
    prev=$word
  done
  [ -n "$harness" ] || return 0
  # Its own session with default hang-up handling, as a real Herdr server's pane
  # child has: a remote job waits for its whole process group and runs with
  # SIGHUP ignored, so a stand-in left inside it would hold every launch open
  # until the job times out and would outlive its pane's close.
  perl -MPOSIX -e '$SIG{HUP} = $SIG{TERM} = "DEFAULT"; POSIX::setsid(); my $h = shift;
    exec { "/bin/sh" } $h, "-c", shift, $h, @ARGV' \
    "$harness" 'trap "exit 0" HUP TERM; while [ -e "$1" ]; do sleep 1 & wait $!; done' \
    "$STATE" ${flags[@]+"${flags[@]}"} </dev/null >/dev/null 2>&1 &
  pid=$!
  jq_state --arg p "$p" --argjson pid "$pid" '.agents[$p] = $pid' | save
}
ws=""; label=""; cwd=""; pane=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) ws=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
    --cwd) cwd=${args[$((i+1))]:-} ;;
    --pane) pane=${args[$((i+1))]:-} ;;
  esac
done
case "${1:-} ${2:-}" in
  "status --json")
    printf '{"client":{"version":"0.7.5","protocol":16},"server":{"running":true,"protocol":16,"compatible":true}}\n' ;;
  "server "*|"server") : ;;
  "workspace list") jq_state '{result:{workspaces:.workspaces}}' ;;
  "workspace create")
    n=$(jq_state -r '.next'); wsid="w$n"; dn=$((n + 1))
    jq_state --arg wsid "$wsid" --arg wlabel "$label" --arg cwd "$cwd" \
      --arg tabid "$wsid:t$dn" --arg paneid "$wsid:p$dn" \
      '.workspaces += [{workspace_id:$wsid, label:$wlabel, cwd:$cwd}]
       | .tabs += [{tab_id:$tabid, label:"1", workspace_id:$wsid, pane_id:$paneid}]
       | .next = (.next + 2)' | save
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"},"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' \
      "$wsid" "$label" "$wsid:t$dn" "$wsid:p$dn"
    ;;
  "tab list") jq_state --arg w "$ws" '{result:{tabs:[.tabs[]|select(.workspace_id==$w)]}}' ;;
  "tab create")
    n=$(jq_state -r '.next'); tabid="$ws:t$n"; paneid="$ws:p$n"
    jq_state --arg w "$ws" --arg wlabel "$label" --arg cwd "$cwd" --arg tabid "$tabid" --arg paneid "$paneid" \
      '.tabs += [{tab_id:$tabid, label:$wlabel, workspace_id:$w, pane_id:$paneid, cwd:$cwd}]
       | .next = (.next + 1)' | save
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$tabid" "$paneid"
    ;;
  "tab close")
    jq_state --arg t "${3:-}" '.tabs |= [.[]|select(.tab_id != $t)]' | save ;;
  "pane list")
    jq_state --arg w "$ws" '{result:{panes:[.tabs[]|select(.workspace_id==$w)|{pane_id:.pane_id, tab_id:.tab_id}]}}' ;;
  "pane get")
    pane=${3:-}
    if [ "$(jq_state -r --arg p "$pane" '[.tabs[]|select(.pane_id==$p)]|length')" = 0 ]; then
      printf '{"error":{"code":"pane_not_found","message":"%s"}}\n' "$pane"
    else
      printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "$pane"
    fi
    ;;
  "pane close")
    [ ! -f "$CLOSE_FAIL" ] || exit 1
    if [ ! -f "$SURVIVE_CLOSE" ] && pid=$(agent_pid "${3:-}") && [ -n "$pid" ]; then
      kill -HUP "$pid" 2>/dev/null || true
    fi
    jq_state --arg p "${3:-}" \
      '.tabs |= [.[]|select(.pane_id != $p)]
       | .typed |= with_entries(select(.key != $p))
       | .working |= with_entries(select(.key != $p))
       | .text |= with_entries(select(.key != $p))
       | .agents |= with_entries(select(.key != $p))' | save ;;
  "pane send-text")
    [ ! -f "$SEND_FAIL" ] || exit 1
    jq_state --arg p "${3:-}" --arg t "${4:-}" '.typed[$p] = true | .text[$p] = $t' | save ;;
  "pane send-keys")
    [ ! -f "$SEND_FAIL" ] || exit 1
    jq_state --arg p "${3:-}" '.typed[$p] = true | .working[$p] = true' | save
    [ "${4:-}" != enter ] || start_agent "${3:-}" ;;
  "pane read") printf '\n' ;;
  "pane process-info")
    if agent_live "$pane"; then
      pid=$(agent_pid "$pane")
      name=$(ps -p "$pid" -o args= 2>/dev/null | awk '{ print $1 }')
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"%s","argv0":"%s","argv":["%s"],"cmdline":"%s"}]}}}\n' \
        "$pane" "$pid" "$pid" "$pid" "$name" "$name" "$name" "$name"
    else
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"codex","argv0":"codex","argv":["codex"],"cmdline":"codex"}]}}}\n' \
        "$pane" "$$" "$$" "$$"
    fi ;;
  "agent get")
    pane=${3:-}
    if [ "$(jq_state -r --arg p "$pane" '.working[$p] // false')" = true ]; then
      jq_state --arg p "$pane" '.working |= with_entries(select(.key != $p))' | save
      printf '{"result":{"agent":{"agent_status":"working"}}}\n'
    elif [ "$(jq_state -r --arg p "$pane" '.typed[$p] // false')" = true ]; then
      printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
    else
      printf '{"error":{"code":"agent_not_found","message":"%s"}}\n' "$pane"
    fi
    ;;
  "session list"*)
    printf '{"sessions":[{"name":"default","running":true,"socket_path":"%s"},{"name":"fm-remote","running":true,"socket_path":"%s"}]}\n' "$SOCKET" "$SOCKET" ;;
esac
exit 0
SH
  chmod +x "$script"
  reset_remote_herdr_fixture "$state"
}

# reset_remote_herdr_fixture <state>: return the fake host to "no workspaces,
# tabs, or panes", which is what a test means by "the previous endpoint is gone".
reset_remote_herdr_fixture() { # <state>
  local pid
  if [ -f "$1" ]; then
    for pid in $(jq -r '.agents // {} | .[]' "$1" 2>/dev/null); do
      kill -HUP "$pid" 2>/dev/null || true
    done
  fi
  printf '{"next":1,"workspaces":[],"tabs":[],"typed":{},"working":{},"text":{},"agents":{}}\n' > "$1"
}
