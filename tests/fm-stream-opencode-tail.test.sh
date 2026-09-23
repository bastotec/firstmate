#!/usr/bin/env bash
# tests/fm-stream-opencode-tail.test.sh - tests for the opencode session-tail
# adapter (bin/fm-stream-opencode-tail.py) and the shared tail publisher it
# imports (bin/fm_stream_tail_lib.py).
#
# These run a REAL hub over a real loopback socket for every lifecycle
# property - registration, state reads, rejoin after a hub restart, kill
# delivery, the status return channel - and a recording stub hub for the wire
# record shape itself: the exact state frames and command acknowledgements the
# adapter publishes, asserted frame by frame.
#
# opencode's session storage is reproduced from this host's own documentation
# of it (the SQLite schema the opencode-history skill and its live consumers
# query): a session table, a message table whose data column is JSON, usage
# records being exactly the messages that carry a tokens object.
#
# Every case gets its own hub on an ephemeral port, and FM_STREAM_HUB and
# FM_STREAM_TOKEN are unset so ambient config can never leak into a case.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required by the stream hub)"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found (required by the stream backend)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by these tests)"; exit 0; }

unset FM_STREAM_HUB FM_STREAM_TOKEN OPENCODE_DB || true

TMP_ROOT=$(fm_test_tmproot fm-stream-opencode-tail-tests)
HUB="$ROOT/bin/fm-stream-hub.py"
TAIL="$ROOT/bin/fm-stream-opencode-tail.py"
STUB="$TMP_ROOT/stub-hub.py"
FIXTURE="$TMP_ROOT/ocfixture.py"
PUBLISH_TOKEN="pub-$$"
VIEW_TOKEN="view-$$"
URL=""
HUB_PID=""
HUB_READY=""
CASE_DIR=""
ADAPTER_PID=""

cleanup_helpers() {
  fm_test_reap_helper_pids
  [ -n "$ADAPTER_PID" ] && kill "$ADAPTER_PID" 2>/dev/null
  wait "$ADAPTER_PID" 2>/dev/null
  ADAPTER_PID=""
}
trap 'cleanup_helpers; fm_test_cleanup' EXIT INT TERM

# --- the recording stub hub -------------------------------------------------
#
# Implements exactly the agent routes the adapter calls, recording every
# registration, frame, and acknowledgement to JSONL files the cases assert
# against. Commands are served from a queue file, one JSON object per line,
# and delivered once.
cat > "$STUB" <<'PY'
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer

out_dir = sys.argv[1]
port = int(sys.argv[2])

def record(name, obj):
    with open(out_dir + "/" + name, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(obj) + "\n")

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _reply(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/v1/health":
            self._reply(200, {"ok": True, "protocol": 3,
                              "capabilities": ["idempotent_command_results"],
                              "state_max_age_secs": 30})
            return
        if self.path.startswith("/v1/agent/commands"):
            # Hold the poll briefly so a caller with nothing queued does not
            # spin, then hand over (and clear) whatever the case queued.
            time.sleep(0.3)
            commands = []
            try:
                with open(out_dir + "/queue", "r", encoding="utf-8") as fh:
                    lines = [l for l in fh.read().splitlines() if l.strip()]
                commands = [json.loads(l) for l in lines]
            except OSError:
                pass
            if commands:
                with open(out_dir + "/queue", "w", encoding="utf-8") as fh:
                    fh.write("")
            self._reply(200, {"ok": True, "commands": commands})
            return
        self._reply(404, {"error": "no_such_route", "message": self.path})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            self._reply(400, {"error": "bad_json", "message": "malformed body"})
            return
        if self.path == "/v1/agent/endpoints":
            if os.environ.get("STUB_REFUSE_ENDPOINTS"):
                self._reply(401, {"error": "unauthorized",
                                  "message": "this token publishes nothing"})
                return
            # Recorded BEFORE the optional delay, so a case watching the file
            # can act while the adapter still waits on this reply: the window
            # between session resolution and the first storage poll.
            record("registrations", payload)
            time.sleep(float(os.environ.get("STUB_REGISTER_DELAY") or 0))
            self._reply(201, {"ok": True})
            return
        if self.path == "/v1/agent/frames":
            for frame in payload.get("frames") or []:
                record("frames", frame)
            self._reply(200, {"ok": True, "accepted": len(payload.get("frames") or [])})
            return
        if self.path == "/v1/agent/results":
            record("results", payload)
            self._reply(200, {"ok": True})
            return
        self._reply(404, {"error": "no_such_route", "message": self.path})

HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY

# --- the opencode storage fixture -------------------------------------------
#
# Subcommands reproduce the schema opencode itself creates, per the
# documentation and live consumers on this host, so the adapter is tested
# against the real table shapes rather than a parser's echo of itself.
cat > "$FIXTURE" <<'PY'
import json, sqlite3, sys, time

def now():
    return int(time.time() * 1000)

def db(path):
    conn = sqlite3.connect(path)
    return conn

cmd = sys.argv[1]
path = sys.argv[2]
if cmd == "init":
    conn = db(path)
    conn.executescript("""
CREATE TABLE project (id TEXT PRIMARY KEY, worktree TEXT NOT NULL, vcs TEXT,
  name TEXT, icon_url TEXT, icon_color TEXT, time_created INTEGER NOT NULL,
  time_updated INTEGER NOT NULL, time_initialized INTEGER, sandboxes TEXT NOT NULL,
  commands TEXT);
CREATE TABLE session (id TEXT PRIMARY KEY, project_id TEXT NOT NULL,
  parent_id TEXT, slug TEXT NOT NULL, directory TEXT NOT NULL, title TEXT NOT NULL,
  version TEXT NOT NULL, share_url TEXT, summary_additions INTEGER,
  summary_deletions INTEGER, summary_files INTEGER, summary_diffs TEXT, revert TEXT,
  permission TEXT, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL,
  time_compacting INTEGER, time_archived INTEGER, workspace_id TEXT);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
  time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT NOT NULL,
  session_id TEXT NOT NULL, time_created INTEGER NOT NULL,
  time_updated INTEGER NOT NULL, data TEXT NOT NULL);
""")
    conn.commit()
elif cmd == "session":
    # session <sid> <directory> <parent_id or -> <archived 0/1>
    conn = db(path)
    conn.execute(
        "INSERT INTO session (id, project_id, parent_id, slug, directory, title,"
        " version, time_created, time_updated, time_archived)"
        " VALUES (?,?,?,?,?,?,?,?,?,?)",
        (sys.argv[3], "proj_1", None if sys.argv[5] == "-" else sys.argv[5],
         "test-slug", sys.argv[4], "test session", "1.2.0",
         now(), now(), now() if sys.argv[6] == "1" else None))
    conn.commit()
elif cmd == "message":
    # message <mid> <sid> <role> <tokens json or -> <cost>
    conn = db(path)
    data = {"id": sys.argv[3], "sessionID": sys.argv[4], "role": sys.argv[5],
            "time": {"created": now(), "completed": now()}}
    if sys.argv[6] != "-":
        data["tokens"] = json.loads(sys.argv[6])
        data["cost"] = float(sys.argv[7])
    conn.execute(
        "INSERT INTO message (id, session_id, time_created, time_updated, data)"
        " VALUES (?,?,?,?,?)",
        (sys.argv[3], sys.argv[4], now(), now(), json.dumps(data)))
    conn.commit()
elif cmd == "archive":
    conn = db(path)
    conn.execute("UPDATE session SET time_archived = ?, time_updated = ? WHERE id = ?",
                 (now(), now(), sys.argv[3]))
    conn.commit()
elif cmd == "touch":
    conn = db(path)
    conn.execute("UPDATE session SET time_updated = ? WHERE id = ?",
                 (now(), sys.argv[3]))
    conn.commit()
else:
    raise SystemExit("unknown fixture command " + cmd)
PY

fixture() {
  python3 "$FIXTURE" "$@" || fail "fixture $* failed"
}

# --- hub lifecycle helpers (real hub) ----------------------------------------

spawn_hub() {
  local port=$1 waited=0 host bound pid
  HUB_READY="$CASE_DIR/ready"
  rm -f "$HUB_READY"
  python3 "$HUB" serve --bind 127.0.0.1 --port "$port" \
    --token-file "$CASE_DIR/tokens" --ready-file "$HUB_READY" \
    >> "$CASE_DIR/hub-log" 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true
  fm_test_track_helper_pid "$pid"
  while [ "$waited" -lt 150 ]; do
    [ -s "$HUB_READY" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$HUB_READY" ] || fail "hub did not report ready: $(cat "$CASE_DIR/hub-log" 2>/dev/null)"
  read -r host bound < "$HUB_READY"
  URL="http://$host:$bound"
  HUB_PID=$pid
}

start_hub() {
  local name=$1
  cleanup_helpers
  CASE_DIR="$TMP_ROOT/$name"
  mkdir -p "$CASE_DIR"
  printf 'publish:%s\nsubscribe,control:%s\n' "$PUBLISH_TOKEN" "$VIEW_TOKEN" \
    > "$CASE_DIR/tokens"
  chmod 600 "$CASE_DIR/tokens"
  printf '%s\n' "$PUBLISH_TOKEN" > "$CASE_DIR/publish-token"
  chmod 600 "$CASE_DIR/publish-token"
  spawn_hub 0
}

restart_hub() {
  local port=${URL##*:} waited=0
  kill "$HUB_PID" 2>/dev/null
  while [ "$waited" -lt 100 ]; do
    [ -e "$HUB_READY" ] || break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -e "$HUB_READY" ] && fail "the hub did not stop when asked"
  spawn_hub "$port"
}

api() {  # <token> <method> <path> [body]
  local token=$1 method=$2 path=$3 body=${4:-}
  if [ -n "$body" ]; then
    printf '%s' "$body" | curl -sS -m 30 -X "$method" \
      -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
      --data-binary @- "$URL$path"
  else
    curl -sS -m 30 -X "$method" -H "Authorization: Bearer $token" "$URL$path"
  fi
}

# adapter_env <db> <extra hub args...> - run the adapter with the case's hub,
# its publish token, and nothing ambient. Prints the pid; the ready file names
# the endpoint.
start_adapter() {
  local db=$1 hub_url=$2 session=$3 label=$4 dir=$5 extra_status=$6
  : > "$CASE_DIR/ready-file"
  env -u FM_STREAM_HUB -u FM_STREAM_TOKEN -u OPENCODE_DB \
    OPENCODE_DB="$db" \
    "$TAIL" serve --hub "$hub_url" --token-file "$CASE_DIR/publish-token" \
    --machine tailhost --label "$label" --session "$session" \
    --state-interval 0.5 --tail-interval 0.2 --poll-secs 1 \
    ${extra_status:+--status-path "$extra_status"} \
    --ready-file "$CASE_DIR/ready-file" \
    >> "$CASE_DIR/adapter-log" 2>&1 &
  ADAPTER_PID=$!
  fm_test_track_helper_pid "$ADAPTER_PID"
  local waited=0
  while [ "$waited" -lt 100 ]; do
    [ -s "$CASE_DIR/ready-file" ] && return 0
    kill -0 "$ADAPTER_PID" 2>/dev/null || {
      fail "adapter exited during startup: $(cat "$CASE_DIR/adapter-log")"; }
    sleep 0.1
    waited=$((waited + 1))
  done
  fail "adapter never reported ready: $(cat "$CASE_DIR/adapter-log")"
}

endpoint_id() {
  read -r _ ep < "$CASE_DIR/ready-file"
  printf '%s' "$ep"
}

wait_gone() {  # <pid>
  local pid=$1 waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  kill -0 "$pid" 2>/dev/null && fail "process $pid did not exit"
}

frames_of() {  # <stub frames file> - every complete state frame as json lines
  # Heartbeats land while a case reads; an unfinished trailing line is
  # dropped rather than failing the whole read.
  python3 - "$1" <<'PY'
import json, sys
try:
    data = open(sys.argv[1], encoding="utf-8").read()
except OSError:
    sys.exit(0)
for line in data.splitlines():
    try:
        obj = json.loads(line)
    except ValueError:
        continue
    if isinstance(obj, dict) and obj.get("state") is not None:
        print(json.dumps(obj, separators=(",", ":")))
PY
}

# === case 1: argument and storage refusals ===================================

CASE_DIR="$TMP_ROOT/refusals"
mkdir -p "$CASE_DIR"
out=$("$TAIL" serve --hub http://127.0.0.1:1 --label t 2>&1)
case "$out" in
  *"--session or --directory"*) pass "refuses to guess the tailed session" ;;
  *) fail "missing-session refusal said: $out" ;;
esac

"$TAIL" serve --hub http://127.0.0.1:1 --label t --session ses_x \
  --db "$CASE_DIR/nope.db" > "$CASE_DIR/out" 2>&1
code=$?
[ "$code" -ne 0 ] || fail "a missing storage file must refuse, not create one"
grep -q "session storage not found" "$CASE_DIR/out" \
  || fail "missing-storage refusal said: $(cat "$CASE_DIR/out")"
[ -e "$CASE_DIR/nope.db" ] && fail "the adapter created a database it was only asked to read"
pass "refuses a missing storage file without creating one"

# A non-SQLite file that passes the isfile check - the pre-v1.2 JSON storage
# this refusal names - must get the refusal voice, not a Python traceback.
printf '{"sessions":{}}' > "$CASE_DIR/storage.json"
"$TAIL" serve --hub http://127.0.0.1:1 --label t --session ses_x \
  --db "$CASE_DIR/storage.json" > "$CASE_DIR/out3" 2>&1
code=$?
[ "$code" -ne 0 ] || fail "a non-SQLite storage file must refuse"
grep -q "cannot read opencode session storage" "$CASE_DIR/out3" \
  || fail "non-SQLite refusal said: $(cat "$CASE_DIR/out3")"
grep -q "pre-v1.2 JSON storage is not supported" "$CASE_DIR/out3" \
  || fail "non-SQLite refusal did not name the unsupported storage: $(cat "$CASE_DIR/out3")"
if grep -q "Traceback" "$CASE_DIR/out3"; then
  fail "non-SQLite refusal leaked a traceback: $(cat "$CASE_DIR/out3")"
fi
pass "refuses non-SQLite storage in the refusal voice, not a traceback"

fixture init "$CASE_DIR/opencode.db"
"$TAIL" serve --hub http://127.0.0.1:1 --label t --session ses_missing \
  --db "$CASE_DIR/opencode.db" > "$CASE_DIR/out2" 2>&1
code=$?
[ "$code" -ne 0 ] || fail "an unknown session id must refuse"
grep -q "ses_missing" "$CASE_DIR/out2" \
  || fail "unknown-session refusal said: $(cat "$CASE_DIR/out2")"
pass "refuses an unknown session id"

# === case 2: wire record shape against the recording stub ====================

CASE_DIR="$TMP_ROOT/shape"
mkdir -p "$CASE_DIR/stub-out"
DB="$CASE_DIR/opencode.db"
fixture init "$DB"
PROJ="$CASE_DIR/project"
mkdir -p "$PROJ"
fixture session "$DB" ses_main "$PROJ" - 0
# A user message carries no tokens: it must contribute nothing, and counting
# anything from it would be fabrication.
fixture message "$DB" msg_u1 ses_main user - 0

STUB_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
printf 'publish:%s\n' "$PUBLISH_TOKEN" > "$CASE_DIR/publish-token"
chmod 600 "$CASE_DIR/publish-token"
python3 "$STUB" "$CASE_DIR/stub-out" "$STUB_PORT" >> "$CASE_DIR/stub-addr" 2>&1 &
STUB_PID=$!
fm_test_track_helper_pid "$STUB_PID"
waited=0
until curl -sS -m 2 "http://127.0.0.1:$STUB_PORT/v1/health" 2>/dev/null | grep -q '"protocol"'; do
  sleep 0.1
  waited=$((waited + 1))
  [ "$waited" -lt 100 ] || fail "stub hub never came up"
done

start_adapter "$DB" "http://127.0.0.1:$STUB_PORT" ses_main shapetest "$PROJ" ""
FRAMES="$CASE_DIR/stub-out/frames"
sleep 1.2

# Registration shape: one registration, exactly the identity the hub is given.
reg=$(jq -c 'select(.endpoint_id != null)' "$CASE_DIR/stub-out/registrations" | head -1)
[ "$(jq -r '.machine' <<<"$reg")" = "tailhost" ] || fail "registration machine: $reg"
[ "$(jq -r '.label' <<<"$reg")" = "shapetest" ] || fail "registration label: $reg"
[ "$(jq -r '.cwd' <<<"$reg")" = "$PROJ" ] || fail "registration cwd: $reg"
echo "$reg" | jq -e '.endpoint_id | test("^[0-9a-f]{32}$")' >/dev/null \
  || fail "registration endpoint id is not 32 hex: $reg"
pass "registers the fleet/leaf identity in the agent's shape"

# First published state: counters only from real usage records, so a session
# with none publishes zeros as a fact, never an estimate.
first=$(frames_of "$FRAMES" | head -1)
[ "$(jq -r '.state.alive' <<<"$first")" = "true" ] || fail "first frame alive: $first"
[ "$(jq -r '.state.cwd' <<<"$first")" = "$PROJ" ] || fail "first frame cwd: $first"
[ "$(jq -r '.state.seq' <<<"$first")" = "1" ] || fail "first frame seq: $first"
[ "$(jq -r '.state.tail.source' <<<"$first")" = "opencode" ] || fail "first frame source: $first"
[ "$(jq -r '.state.tail.session_id' <<<"$first")" = "ses_main" ] || fail "first frame session: $first"
[ "$(jq -r '.state.tail.usage_records' <<<"$first")" = "0" ] || fail "first frame usage_records: $first"
[ "$(jq -r '.state.tail.tokens.input' <<<"$first")" = "0" ] || fail "first frame tokens: $first"
jq -e '.state.tail.cost == 0' <<<"$first" >/dev/null || fail "first frame cost: $first"
pass "publishes zero counters as a fact, never a fabricated estimate"

# Real usage arrives: cumulative counters follow the records opencode wrote.
fixture message "$DB" msg_a1 ses_main assistant \
  '{"input":100,"output":50,"reasoning":10,"cache":{"read":20,"write":30}}' 0.25
sleep 1.2
after=$(frames_of "$FRAMES" | jq -c 'select(.state.tail.usage_records == 1)' | head -1)
[ -n "$after" ] || fail "no frame published the new usage record: $(frames_of "$FRAMES")"
[ "$(jq -r '.state.tail.tokens.input' <<<"$after")" = "100" ] || fail "usage input: $after"
[ "$(jq -r '.state.tail.tokens.output' <<<"$after")" = "50" ] || fail "usage output: $after"
[ "$(jq -r '.state.tail.tokens.reasoning' <<<"$after")" = "10" ] || fail "usage reasoning: $after"
[ "$(jq -r '.state.tail.tokens.cache_read' <<<"$after")" = "20" ] || fail "usage cache_read: $after"
[ "$(jq -r '.state.tail.tokens.cache_write' <<<"$after")" = "30" ] || fail "usage cache_write: $after"
jq -e '.state.tail.cost == 0.25' <<<"$after" >/dev/null || fail "usage cost: $after"
pass "publishes cumulative counters from real usage records"

# A second record adds to the same totals; the sequence stays monotonic.
fixture message "$DB" msg_a2 ses_main assistant \
  '{"input":30,"output":20,"reasoning":0,"cache":{"read":0,"write":5}}' 0.1
sleep 1.2
after2=$(frames_of "$FRAMES" | jq -c 'select(.state.tail.usage_records == 2)' | head -1)
[ -n "$after2" ] || fail "no frame published the second usage record"
[ "$(jq -r '.state.tail.tokens.input' <<<"$after2")" = "130" ] || fail "cumulative input: $after2"
[ "$(jq -r '.state.tail.tokens.cache_write' <<<"$after2")" = "35" ] || fail "cumulative cache_write: $after2"
jq -e '.state.tail.cost == 0.35' <<<"$after2" >/dev/null || fail "cumulative cost: $after2"
frames_of "$FRAMES" | jq -r '.state.seq' | sort -n -c 2>/dev/null \
  || fail "sequence is not strictly increasing: $(frames_of "$FRAMES" | jq -r '.state.seq' | tr '\n' ' ')"
pass "accumulates cumulatively with a strictly increasing sequence"

# Idle heartbeats keep arriving with unchanged counters.
seq_before=$(frames_of "$FRAMES" | jq -r '.state.seq' | tail -1)
sleep 1.5
seq_after=$(frames_of "$FRAMES" | jq -r '.state.seq' | tail -1)
[ "$seq_after" -gt "$seq_before" ] || fail "no heartbeat arrived while idle ($seq_before -> $seq_after)"
idle=$(frames_of "$FRAMES" | jq -c "select(.state.seq == $seq_after)")
[ "$(jq -r '.state.tail.usage_records' <<<"$idle")" = "2" ] || fail "heartbeat changed usage_records: $idle"
[ "$(jq -r '.state.tail.tokens.input' <<<"$idle")" = "130" ] || fail "heartbeat changed counters: $idle"
pass "heartbeats on a fixed idle cadence with unchanged counters"

# Input is refused - a tail adapter owns no terminal - and the hub is told.
printf '%s\n' '{"command_id":"c-input","kind":"input","payload":{"text":"hi"}}' \
  > "$CASE_DIR/stub-out/queue"
sleep 1.5
result=$(jq -c 'select(.command_id == "c-input")' "$CASE_DIR/stub-out/results")
[ "$(jq -r '.ok' <<<"$result")" = "false" ] || fail "input was not refused: $result"
grep -q "owns no terminal" <<<"$(jq -r '.error' <<<"$result")" \
  || fail "input refusal reason: $result"
pass "refuses input because a tail adapter owns no terminal"

# A restart of the adapter resumes from storage: the first frame of the new
# process already carries the full cumulative totals, cursor-free.
EP1=$(endpoint_id)
kill "$ADAPTER_PID" 2>/dev/null
wait "$ADAPTER_PID" 2>/dev/null
ADAPTER_PID=""
: > "$CASE_DIR/ready-file"
start_adapter "$DB" "http://127.0.0.1:$STUB_PORT" ses_main shapetest "$PROJ" ""
EP2=$(endpoint_id)
[ "$EP1" != "$EP2" ] || fail "a relaunched adapter must be a new execution"
sleep 1.2
resumed=$(frames_of "$FRAMES" | jq -c "select(.state.seq == 1 and (.state.tail.usage_records == 2))" | head -1)
[ -n "$resumed" ] || fail "resumed first frame did not carry the full totals: $(frames_of "$FRAMES" | head -1)"
[ "$(jq -r '.state.tail.tokens.input' <<<"$resumed")" = "130" ] || fail "resumed totals: $resumed"
pass "resumes with full cumulative totals after a restart"

kill "$ADAPTER_PID" 2>/dev/null
wait "$ADAPTER_PID" 2>/dev/null
ADAPTER_PID=""

# === case 3: the real hub - listing, state reads, rejoin, kill, status =======

CASE_DIR="$TMP_ROOT/realhub"
mkdir -p "$CASE_DIR/state"
DB="$CASE_DIR/opencode.db"
PROJ="$CASE_DIR/proj"
mkdir -p "$PROJ"
fixture init "$DB"
fixture session "$DB" ses_live "$PROJ" - 0
fixture message "$DB" msg_r1 ses_live assistant \
  '{"input":11,"output":7,"reasoning":0,"cache":{"read":0,"write":0}}' 0.01

start_hub realhub
start_adapter "$DB" "$URL" ses_live livework "$PROJ" "$CASE_DIR/state/live.status"
EP=$(endpoint_id)

task=$(api "$VIEW_TOKEN" GET "/v1/tasks/$EP")
[ "$(jq -r ".task.label" <<<"$task")" = "livework" ] || fail "listing label: $task"
[ "$(jq -r ".task.machine" <<<"$task")" = "tailhost" ] || fail "listing machine: $task"
pass "lists on the fleet as an ordinary endpoint"

generation=$(api "$VIEW_TOKEN" GET /v1/health | jq -r '.generation')
order_answer=$(api "$VIEW_TOKEN" POST /v1/orders "$(jq -nc --arg id "$EP" \
  --arg generation "$generation" \
  '{leaf_worker_id: "tailhost/livework", execution_id: $id,
    order_id: "tail-read-only", text: "echo MUST-NOT-RUN", submit: true,
    hub_generation: $generation}')")
[ "$(jq -r '.reason' <<<"$order_answer")" = "endpoint_not_orderable" ] \
  || fail "a read-only tail endpoint accepted an order: $order_answer"
[ "$(jq -r '.delivered' <<<"$order_answer")" = "false" ] \
  || fail "the refused tail order was not known undelivered: $order_answer"
pass "keeps read-only tail publishers non-orderable"

cwd_answer=$(api "$VIEW_TOKEN" GET "/v1/tasks/$EP/cwd")
[ "$(jq -r ".cwd" <<<"$cwd_answer")" = "$PROJ" ] || fail "state cwd read: $cwd_answer"
[ "$(jq -r ".alive" <<<"$cwd_answer")" = "true" ] || fail "state alive read: $cwd_answer"
[ "$(jq -r ".stale" <<<"$cwd_answer")" = "false" ] || fail "state read went stale: $cwd_answer"
pass "answers state reads fresh, through the agent's own route"

# A hub restart forgets every endpoint; the adapter must take the SAME id back.
restart_hub
waited=0
until api "$VIEW_TOKEN" GET "/v1/tasks/$EP" 2>/dev/null | jq -e '.task.endpoint_id' >/dev/null 2>&1; do
  sleep 0.3
  waited=$((waited + 1))
  [ "$waited" -lt 60 ] || fail "adapter did not rejoin after the hub restart: $(api "$VIEW_TOKEN" GET /v1/tasks)"
done
cwd_answer=$(api "$VIEW_TOKEN" GET "/v1/tasks/$EP/cwd")
[ "$(jq -r ".stale" <<<"$cwd_answer")" = "false" ] || fail "rejoined endpoint stayed stale: $cwd_answer"
pass "rejoins a restarted hub under the same endpoint id"

# The status return channel: the record is written on this machine.
status_answer=$(api "$VIEW_TOKEN" POST "/v1/tasks/$EP/status" \
  '{"state":"paused","note":"waiting on an upstream release"}')
[ "$(jq -r ".ok" <<<"$status_answer")" = "true" ] || fail "status delivery: $status_answer"
waited=0
until grep -q "paused: waiting on an upstream release" "$CASE_DIR/state/live.status" 2>/dev/null; do
  sleep 0.2
  waited=$((waited + 1))
  [ "$waited" -lt 50 ] || fail "status line never landed: $(cat "$CASE_DIR/state/live.status" 2>/dev/null)"
done
pass "appends status lines through the hub, on the machine that owns the record"

# A kill is delivered and acknowledged: the adapter closes its record out.
kill_answer=$(api "$VIEW_TOKEN" DELETE "/v1/tasks/$EP")
[ "$(jq -r ".delivered" <<<"$kill_answer")" = "true" ] || fail "kill delivery: $kill_answer"
wait_gone "$ADAPTER_PID"
ADAPTER_PID=""
task=$(api "$VIEW_TOKEN" GET "/v1/tasks/$EP")
[ "$(jq -r ".task.closed_by" <<<"$task")" = "agent" ] || fail "close attribution: $task"
[ "$(jq -r ".task.exit_code" <<<"$task")" = "0" ] || fail "close exit code: $task"
pass "acknowledges a kill and closes its own record"

# === case 4: directory resolution and the archived end ======================

CASE_DIR="$TMP_ROOT/resolve"
mkdir -p "$CASE_DIR"
DB="$CASE_DIR/opencode.db"
PROJ="$CASE_DIR/proj"
mkdir -p "$PROJ"
fixture init "$DB"
fixture session "$DB" ses_parent "$PROJ" - 0
fixture session "$DB" ses_child "$PROJ" ses_parent 0
fixture message "$DB" msg_p1 ses_parent assistant \
  '{"input":5,"output":5,"reasoning":0,"cache":{"read":0,"write":0}}' 0.02
# The subagent child is NEWER: newest-main resolution must still pick the parent.
fixture touch "$DB" ses_child
fixture session "$DB" ses_old "$PROJ" - 1
fixture touch "$DB" ses_old

start_hub resolve
# No --session: the adapter resolves from the directory.
: > "$CASE_DIR/ready-file"
env -u FM_STREAM_HUB -u FM_STREAM_TOKEN -u OPENCODE_DB \
  OPENCODE_DB="$DB" \
  "$TAIL" serve --hub "$URL" --token-file "$CASE_DIR/publish-token" \
  --machine tailhost --label dirwork --directory "$PROJ" \
  --state-interval 0.5 --tail-interval 0.2 --poll-secs 1 \
  --ready-file "$CASE_DIR/ready-file" >> "$CASE_DIR/adapter-log" 2>&1 &
ADAPTER_PID=$!
fm_test_track_helper_pid "$ADAPTER_PID"
waited=0
while [ "$waited" -lt 100 ]; do
  [ -s "$CASE_DIR/ready-file" ] && break
  kill -0 "$ADAPTER_PID" 2>/dev/null || fail "adapter exited during startup: $(cat "$CASE_DIR/adapter-log")"
  sleep 0.1
  waited=$((waited + 1))
done
[ -s "$CASE_DIR/ready-file" ] || fail "adapter never reported ready: $(cat "$CASE_DIR/adapter-log")"
EP=$(endpoint_id)
grep -q "tailing session ses_parent" "$CASE_DIR/adapter-log" \
  || fail "directory resolution picked the wrong session: $(grep tailing "$CASE_DIR/adapter-log")"
pass "resolves a directory to its newest MAIN session, never a subagent"

# Archiving the conversation ends the endpoint: the session's end is the
# endpoint's end, reported by the adapter that watched it.
fixture archive "$DB" ses_parent
wait_gone "$ADAPTER_PID"
ADAPTER_PID=""
task=$(api "$VIEW_TOKEN" GET "/v1/tasks/$EP")
[ "$(jq -r ".task.closed_by" <<<"$task")" = "agent" ] || fail "archived close attribution: $task"
pass "closes its endpoint out when opencode archives the session"

# === case 5: the hub refuses the registration ================================

CASE_DIR="$TMP_ROOT/refused"
mkdir -p "$CASE_DIR/stub-out"
DB="$CASE_DIR/opencode.db"
fixture init "$DB"
PROJ="$CASE_DIR/project"
mkdir -p "$PROJ"
fixture session "$DB" ses_reg "$PROJ" - 0

STUB_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
printf 'publish:%s\n' "$PUBLISH_TOKEN" > "$CASE_DIR/publish-token"
chmod 600 "$CASE_DIR/publish-token"
STUB_REFUSE_ENDPOINTS=1 python3 "$STUB" "$CASE_DIR/stub-out" "$STUB_PORT" \
  >> "$CASE_DIR/stub-addr" 2>&1 &
STUB_PID=$!
fm_test_track_helper_pid "$STUB_PID"
waited=0
until curl -sS -m 2 "http://127.0.0.1:$STUB_PORT/v1/health" 2>/dev/null | grep -q '"protocol"'; do
  sleep 0.1
  waited=$((waited + 1))
  [ "$waited" -lt 100 ] || fail "stub hub never came up"
done

# A hub that refuses the registration (a publish token that publishes
# nothing) must end the adapter in its refusal voice, not a traceback.
env -u FM_STREAM_HUB -u FM_STREAM_TOKEN -u OPENCODE_DB \
  "$TAIL" serve --hub "http://127.0.0.1:$STUB_PORT" --token-file "$CASE_DIR/publish-token" \
  --machine tailhost --label refusedwork --session ses_reg --db "$DB" \
  > "$CASE_DIR/adapter-out" 2>&1
code=$?
[ "$code" -ne 0 ] || fail "a refused registration must exit nonzero"
grep -q "hub refused POST /v1/agent/endpoints" "$CASE_DIR/adapter-out" \
  || fail "registration refusal said: $(cat "$CASE_DIR/adapter-out")"
if grep -q "Traceback" "$CASE_DIR/adapter-out"; then
  fail "registration refusal leaked a traceback: $(cat "$CASE_DIR/adapter-out")"
fi
pass "exits in the refusal voice when the hub refuses registration"

# === case 6: storage that has never answered publishes no counters ===========
#
# Storage that resolves at startup but is unreadable by the first poll must
# not publish zeros: usage_records 0 would claim a read proved the session
# holds no usage records.  The frames carry the session id alone until a
# read answers, then converge on the real counters.

CASE_DIR="$TMP_ROOT/deafstorage"
mkdir -p "$CASE_DIR/stub-out"
DB="$CASE_DIR/opencode.db"
fixture init "$DB"
PROJ="$CASE_DIR/project"
mkdir -p "$PROJ"
fixture session "$DB" ses_deaf "$PROJ" - 0
fixture message "$DB" msg_d1 ses_deaf assistant \
  '{"input":7,"output":3,"reasoning":0,"cache":{"read":0,"write":0}}' 0.01

STUB_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
printf 'publish:%s\n' "$PUBLISH_TOKEN" > "$CASE_DIR/publish-token"
chmod 600 "$CASE_DIR/publish-token"
STUB_REGISTER_DELAY=2 python3 "$STUB" "$CASE_DIR/stub-out" "$STUB_PORT" \
  >> "$CASE_DIR/stub-addr" 2>&1 &
STUB_PID=$!
fm_test_track_helper_pid "$STUB_PID"
waited=0
until curl -sS -m 2 "http://127.0.0.1:$STUB_PORT/v1/health" 2>/dev/null | grep -q '"protocol"'; do
  sleep 0.1
  waited=$((waited + 1))
  [ "$waited" -lt 100 ] || fail "stub hub never came up"
done

: > "$CASE_DIR/ready-file"
env -u FM_STREAM_HUB -u FM_STREAM_TOKEN -u OPENCODE_DB \
  OPENCODE_DB="$DB" \
  "$TAIL" serve --hub "http://127.0.0.1:$STUB_PORT" --token-file "$CASE_DIR/publish-token" \
  --machine tailhost --label deafwork --session ses_deaf \
  --state-interval 0.5 --tail-interval 0.2 --poll-secs 1 \
  --ready-file "$CASE_DIR/ready-file" >> "$CASE_DIR/adapter-log" 2>&1 &
ADAPTER_PID=$!
fm_test_track_helper_pid "$ADAPTER_PID"

# The registration reply is the window between session resolution and the
# first storage poll: revoke the read while the adapter waits on it.
waited=0
until [ -s "$CASE_DIR/stub-out/registrations" ]; do
  sleep 0.05
  waited=$((waited + 1))
  [ "$waited" -lt 100 ] || fail "adapter never registered: $(cat "$CASE_DIR/adapter-log")"
done
chmod 000 "$DB"

waited=0
while [ "$waited" -lt 100 ]; do
  [ -s "$CASE_DIR/ready-file" ] && break
  kill -0 "$ADAPTER_PID" 2>/dev/null \
    || fail "adapter exited while storage was unreadable: $(cat "$CASE_DIR/adapter-log")"
  sleep 0.1
  waited=$((waited + 1))
done
[ -s "$CASE_DIR/ready-file" ] || fail "adapter never reported ready: $(cat "$CASE_DIR/adapter-log")"

FRAMES="$CASE_DIR/stub-out/frames"
first=$(frames_of "$FRAMES" | head -1)
[ "$(jq -r '.state.tail.session_id' <<<"$first")" = "ses_deaf" ] \
  || fail "first frame session: $first"
if jq -e '.state.tail | (has("tokens") or has("usage_records") or has("cost"))' \
    <<<"$first" >/dev/null 2>&1; then
  fail "first frame published counters no read backed: $first"
fi
pass "publishes the session alone while storage has never answered"

# Heartbeats keep carrying the session, never counters, while it stays deaf.
sleep 1.2
if frames_of "$FRAMES" | jq -e 'select(.state.tail | has("tokens"))' >/dev/null 2>&1; then
  fail "a frame published counters while storage was unreadable: $(frames_of "$FRAMES" | tail -3)"
fi
hearts=$(frames_of "$FRAMES" | jq -s 'length')
[ "${hearts:-0}" -ge 2 ] || fail "no heartbeats arrived while storage was unreadable"
pass "heartbeats the session alone while storage stays unreadable"

# The moment a read answers, the real counters arrive - converged, not zeros.
chmod 600 "$DB"
waited=0
until frames_of "$FRAMES" | jq -e 'select(.state.tail.usage_records == 1)' >/dev/null 2>&1; do
  sleep 0.2
  waited=$((waited + 1))
  [ "$waited" -lt 50 ] \
    || fail "counters never converged after storage answered: $(frames_of "$FRAMES" | tail -3)"
done
converged=$(frames_of "$FRAMES" | jq -c 'select(.state.tail.usage_records == 1)' | head -1)
[ "$(jq -r '.state.tail.tokens.input' <<<"$converged")" = "7" ] \
  || fail "converged counters: $converged"
pass "converges on the real counters as soon as storage answers"

kill "$ADAPTER_PID" 2>/dev/null
wait "$ADAPTER_PID" 2>/dev/null
ADAPTER_PID=""

cleanup_helpers
echo "all opencode tail adapter tests passed"
