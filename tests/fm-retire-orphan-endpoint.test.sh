#!/usr/bin/env bash
# tests/fm-retire-orphan-endpoint.test.sh - bin/fm-retire-endpoint.sh --orphan
# and --list-orphans close a live stream endpoint whose task record is gone,
# only when the endpoint is provably this home's, nothing runs or is pending
# behind it, and no unlanded work is tied to it.
#
# The hub is a small stub that serves the endpoint reads and the kill the
# command makes and logs every close, so each case can assert exactly which
# endpoints were closed. Scratch homes stand in for the owning and the other
# home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for tool in python3 curl jq git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

TMP_ROOT=$(fm_test_tmproot fm-retire-orphan)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
TOKEN="orphan-token-$$"
MACHINE=box-test
HUB_DIR="$TMP_ROOT/hub"
mkdir -p "$HUB_DIR"
printf '{}\n' > "$HUB_DIR/endpoints.json"
: > "$HUB_DIR/deletes.log"

cat > "$HUB_DIR/stub.py" <<'PY'
import fcntl, json, os, re, subprocess, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

root, token = sys.argv[1], sys.argv[2]
db = os.path.join(root, "endpoints.json")

def load():
    with open(db) as f:
        return json.load(f)

def save(data):
    tmp = db + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    os.replace(tmp, db)

def describe(eid, e):
    return {"endpoint_id": eid, "machine": e["machine"], "label": e["label"],
            "cwd": e["cwd"], "closed_at": e.get("closed_at"), "closed_by": e.get("closed_by")}

class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def reply(self, code, body):
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)
    def authed(self):
        if self.headers.get("Authorization") != "Bearer " + token:
            self.reply(401, {"error": "unauthorized"})
            return False
        return True
    def do_GET(self):
        if not self.authed():
            return
        data = load()
        if self.path == "/v1/tasks":
            return self.reply(200, {"tasks": [describe(k, v) for k, v in data.items()]})
        m = re.fullmatch(r"/v1/tasks/([0-9a-f]+)(/processes|/cwd)?", self.path)
        if not m or m.group(1) not in data:
            return self.reply(404, {"error": "no_such_endpoint"})
        eid, tail, e = m.group(1), m.group(2), data[m.group(1)]
        if not tail:
            return self.reply(200, {"task": describe(eid, e)})
        body = {"ok": True, "endpoint_id": eid, "machine": e["machine"], "stale": False,
                "closed": bool(e.get("closed_at")), "closed_by": e.get("closed_by"), "alive": True}
        if tail == "/processes":
            body["foreground"] = [{"pid": 1, "name": n, "argv0": n, "args": n} for n in e["foreground"]]
        else:
            if e.get("cwd_hook"):
                hook = e.pop("cwd_hook")
                save(data)
                subprocess.run(hook, check=True, stdout=subprocess.DEVNULL)
            body["cwd"] = e["live_cwd"]
        return self.reply(200, body)
    def do_DELETE(self):
        if not self.authed():
            return
        data = load()
        m = re.fullmatch(r"/v1/tasks/([0-9a-f]+)", self.path)
        if not m or m.group(1) not in data:
            return self.reply(404, {"error": "no_such_endpoint"})
        if data[m.group(1)].get("lifecycle_lock"):
            with open(data[m.group(1)]["lifecycle_lock"], "a") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    pass
                else:
                    return self.reply(409, {"error": "close_without_lifecycle_lock"})
        if data[m.group(1)].get("inbox_writer"):
            result = subprocess.run(data[m.group(1)]["inbox_writer"],
                env=dict(os.environ, FM_TASK_INBOX_LOCK_WAIT_SECS='0'),
                capture_output=True, text=True)
            if result.returncode != 1:
                return self.reply(409, {"error": "close_without_inbox_lock"})
        data[m.group(1)]["closed_at"] = 1.0
        data[m.group(1)]["closed_by"] = "agent"
        save(data)
        with open(os.path.join(root, "deletes.log"), "a") as f:
            f.write(m.group(1) + "\n")
        return self.reply(200, {"ok": True, "closed": m.group(1), "delivered": True})

server = ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(os.path.join(root, "ready.tmp"), "w") as f:
    f.write(str(server.server_address[1]))
os.replace(os.path.join(root, "ready.tmp"), os.path.join(root, "ready"))
server.serve_forever()
PY

python3 "$HUB_DIR/stub.py" "$HUB_DIR" "$TOKEN" >/dev/null 2>&1 &
fm_test_track_helper_pid "$!"
for _ in $(seq 1 100); do
  [ -s "$HUB_DIR/ready" ] && break
  sleep 0.1
done
[ -s "$HUB_DIR/ready" ] || fail "the stub hub did not start"
URL="http://127.0.0.1:$(cat "$HUB_DIR/ready")"

new_eid() {
  python3 -c 'import os; print(os.urandom(16).hex())'
}

# add_endpoint <eid> <label> <hub-cwd> <live-cwd> <foreground...>
add_endpoint() {
  local eid=$1 label=$2 cwd=$3 live=$4
  shift 4
  python3 - "$HUB_DIR/endpoints.json" "$eid" "$label" "$MACHINE" "$cwd" "$live" "$@" <<'PY'
import json, sys
path, eid, label, machine, cwd, live, *fg = sys.argv[1:]
data = json.load(open(path))
data[eid] = {"label": label, "machine": machine, "cwd": cwd, "live_cwd": live, "foreground": fg}
json.dump(data, open(path, "w"))
PY
}

endpoint_option() {
  python3 - "$HUB_DIR/endpoints.json" "$1" "$2" "${@:3}" <<'PY'
import json, sys
path, eid, key, *values = sys.argv[1:]
data = json.load(open(path))
data[eid][key] = values if key in ('cwd_hook', 'inbox_writer') else values[0]
json.dump(data, open(path, 'w'))
PY
}

new_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config"
  printf '%s\n' "$home"
}

# deck_record <home> <id> <eid> <active:true|false>
deck_record() {
  mkdir -p "$1/state/$2.inbox/deck-$3"
  printf '{"turn": "t", "supported": true, "active": %s}\n' "$4" > "$1/state/$2.inbox/deck-$3/active.json"
}

orphan() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STREAM_HUB="$URL" FM_STREAM_TOKEN="$TOKEN" FM_STREAM_MACHINE="$MACHINE" \
    "$ROOT/bin/fm-retire-endpoint.sh" "$@"
}

was_closed() {
  grep -Fxq -- "$1" "$HUB_DIR/deletes.log"
}

# A project with a fetched origin and a clean linked worktree, so landed work
# reads as landed.
PROJECT="$TMP_ROOT/project"
fm_git_worktree "$PROJECT" "$TMP_ROOT/wt-clean" task-clean
git -C "$PROJECT" fetch -q origin
CLEAN_WT="$TMP_ROOT/wt-clean"

HOME_A=$(new_home home-a)
HOME_B=$(new_home home-b)

# --- 1. the owned leftover closes -------------------------------------------
E1=$(new_eid)
add_endpoint "$E1" fm-owned "$PROJECT" "$CLEAN_WT" /bin/zsh
deck_record "$HOME_A" owned "$E1" false
listed=$(orphan "$HOME_A" --list-orphans) || fail "--list-orphans failed"
assert_contains "$listed" "owned	$E1" "--list-orphans names the owned leftover"
out=$(orphan "$HOME_A" --orphan owned 2>&1) || fail "the owned leftover was refused: $out"
was_closed "$E1" || fail "the owned leftover was not closed on the hub"
assert_grep "basis=orphan-endpoint" "$HOME_A/state/endpoint-retirements.log" "the close is logged with its basis"
assert_grep "evidence=home-record:owned.inbox/deck-$E1" "$HOME_A/state/endpoint-retirements.log" "the log names the ownership evidence"
assert_grep "worktrees=$CLEAN_WT" "$HOME_A/state/endpoint-retirements.log" "the log names the judged worktree"
assert_present "$HOME_A/state/owned.inbox/deck-$E1" "closing touches no home file"
listed=$(orphan "$HOME_A" --list-orphans) || fail "--list-orphans failed after the close"
assert_not_contains "$listed" "$E1" "a closed endpoint is no longer listed"
pass "the owned leftover closes, logged with its evidence"

E1B=$(new_eid)
add_endpoint "$E1B" fm-agentproof "$PROJECT" "$CLEAN_WT" /bin/zsh
python3 -c 'import time; time.sleep(120)' fm-stream-agent serve --hub "$URL" --token-file /dev/null \
  --machine "$MACHINE" --label fm-agentproof --cwd "$PROJECT" \
  --status-path "$HOME_A/state/agentproof.status" --ready-file /dev/null &
fm_test_track_helper_pid "$!"
listed=$(orphan "$HOME_A" --list-orphans) || fail "--list-orphans failed"
assert_not_contains "$listed" "$E1B" "a local process without an endpoint record is not listed"
rc=0
out=$(orphan "$HOME_A" --orphan agentproof --endpoint "$E1B" 2>&1) || rc=$?
expect_code 1 "$rc" "a local process without an endpoint record"
assert_contains "$out" "a matching label alone is not ownership" "the unbound process cannot prove ownership"
was_closed "$E1B" && fail "an endpoint proved only by launch arguments was closed"
pass "a local agent carrying this home's status path without a deck record is refused"

# --- 2. another home's endpoint is refused ----------------------------------
E2=$(new_eid)
add_endpoint "$E2" fm-theirs "$PROJECT" "$CLEAN_WT" /bin/zsh
deck_record "$HOME_B" theirs "$E2" false
rc=0
out=$(orphan "$HOME_A" --orphan theirs --endpoint "$E2" 2>&1) || rc=$?
expect_code 1 "$rc" "another home's endpoint"
assert_contains "$out" "a matching label alone is not ownership" "the refusal says why"
rc=0
out=$(orphan "$HOME_A" --orphan theirs 2>&1) || rc=$?
expect_code 1 "$rc" "another home's endpoint found by label"
was_closed "$E2" && fail "another home's endpoint was closed"
listed=$(orphan "$HOME_A" --list-orphans) || fail "--list-orphans failed"
assert_not_contains "$listed" "$E2" "another home's endpoint is not listed"
pass "another home's endpoint is refused"

# --- 3. a name match alone is refused ---------------------------------------
E3=$(new_eid)
add_endpoint "$E3" fm-namesake "$PROJECT" "$CLEAN_WT" /bin/zsh
: > "$HOME_A/state/namesake.status"
rc=0
out=$(orphan "$HOME_A" --orphan namesake 2>&1) || rc=$?
expect_code 1 "$rc" "a name match alone"
assert_contains "$out" "a matching label alone is not ownership" "the refusal names the missing proof"
# A deck record for a DIFFERENT endpoint id does not prove this one.
deck_record "$HOME_A" namesake "$(new_eid)" false
rc=0
orphan "$HOME_A" --orphan namesake --endpoint "$E3" >/dev/null 2>&1 || rc=$?
expect_code 1 "$rc" "evidence for another endpoint id"
was_closed "$E3" && fail "a name-matched endpoint was closed"
pass "a name match alone is refused"

# --- 4. an endpoint with unlanded work is refused ---------------------------
git -C "$PROJECT" worktree add -q -b task-ahead "$TMP_ROOT/wt-ahead"
git -C "$TMP_ROOT/wt-ahead" -c user.name=T -c user.email=t@example.invalid \
  commit -q --allow-empty -m unlanded
E4=$(new_eid)
add_endpoint "$E4" fm-ahead "$PROJECT" "$TMP_ROOT/wt-ahead" /bin/zsh
deck_record "$HOME_A" ahead "$E4" false
rc=0
out=$(orphan "$HOME_A" --orphan ahead 2>&1) || rc=$?
expect_code 1 "$rc" "unlanded commits"
assert_contains "$out" "has not landed" "the refusal names the unlanded commit"

git -C "$PROJECT" worktree add -q -b task-dirty "$TMP_ROOT/wt-dirty"
printf 'edit\n' > "$TMP_ROOT/wt-dirty/scratch.txt"
E4B=$(new_eid)
add_endpoint "$E4B" fm-dirty "$PROJECT" "$TMP_ROOT/wt-dirty" /bin/zsh
deck_record "$HOME_A" dirty "$E4B" false
rc=0
out=$(orphan "$HOME_A" --orphan dirty 2>&1) || rc=$?
expect_code 1 "$rc" "uncommitted work"
assert_contains "$out" "uncommitted changes" "the refusal names the uncommitted change"

# A worktree whose slot claim names the task counts even when the endpoint
# itself sits in the primary clone.
POOL="$TMP_ROOT/pool"
mkdir -p "$POOL/7"
printf '{}\n' > "$POOL/treehouse-state.json"
git -C "$PROJECT" worktree add -q -b task-slot "$POOL/7/project"
printf 'task=slotted\nhome=%s\n' "$HOME_A" > "$POOL/7/.fm-slot-owner"
printf 'edit\n' > "$POOL/7/project/scratch.txt"
E4C=$(new_eid)
add_endpoint "$E4C" fm-slotted "$PROJECT" "$PROJECT" /bin/zsh
deck_record "$HOME_A" slotted "$E4C" false
rc=0
out=$(orphan "$HOME_A" --orphan slotted 2>&1) || rc=$?
expect_code 1 "$rc" "a claimed slot with uncommitted work"
assert_contains "$out" "its slot claim names slotted" "the refusal names the claimed slot"
for e in "$E4" "$E4B" "$E4C"; do
  was_closed "$e" && fail "an endpoint with unlanded work was closed"
done
pass "an endpoint with unlanded or uncommitted work is refused"

BROKEN_PROJECT="$TMP_ROOT/broken-project"
BROKEN_WT="$TMP_ROOT/broken-wt"
fm_git_worktree "$BROKEN_PROJECT" "$BROKEN_WT" task-broken
printf 'edit\n' > "$BROKEN_WT/scratch.txt"
mv "$BROKEN_PROJECT" "$TMP_ROOT/moved-project"
EBROKEN=$(new_eid)
add_endpoint "$EBROKEN" fm-broken "$BROKEN_PROJECT" "$BROKEN_WT" /bin/zsh
deck_record "$HOME_A" broken "$EBROKEN" false
rc=0
out=$(orphan "$HOME_A" --orphan broken 2>&1) || rc=$?
expect_code 1 "$rc" "a worktree with a broken Git pointer"
assert_contains "$out" "Git cannot classify" "the broken worktree is not treated as a non-repository"
was_closed "$EBROKEN" && fail "a broken worktree's endpoint was closed"

GITBIN=$(fm_fakebin "$TMP_ROOT/gitbin")
REAL_GIT=$(command -v git)
cat > "$GITBIN/git" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" ${FM_TEST_GIT_FAIL_STAGE:-no-failure} "*) exit 1 ;;
esac
exec "$FM_TEST_REAL_GIT" "$@"
SH
chmod +x "$GITBIN/git"
for stage in 'worktree list' '--is-inside-work-tree' '--show-toplevel' '--git-dir' '--git-common-dir'; do
  EDISCOVERY=$(new_eid)
  add_endpoint "$EDISCOVERY" fm-discovery "$PROJECT" "$CLEAN_WT" /bin/zsh
  deck_record "$HOME_A" discovery "$EDISCOVERY" false
  rc=0
  out=$(PATH="$GITBIN:$PATH" FM_TEST_REAL_GIT="$REAL_GIT" FM_TEST_GIT_FAIL_STAGE="$stage" \
    orphan "$HOME_A" --orphan discovery --endpoint "$EDISCOVERY" 2>&1) || rc=$?
  expect_code 1 "$rc" "Git discovery failure: $stage"
  assert_contains "$out" "Git cannot" "the discovery failure has a plain reason"
  was_closed "$EDISCOVERY" && fail "an endpoint was closed despite Git failure: $stage"
done

EMISSING=$(new_eid)
add_endpoint "$EMISSING" fm-missingcwd "$TMP_ROOT/missing-project" "$CLEAN_WT" /bin/zsh
deck_record "$HOME_A" missingcwd "$EMISSING" false
rc=0
out=$(orphan "$HOME_A" --orphan missingcwd 2>&1) || rc=$?
expect_code 1 "$rc" "an unavailable registered directory"
assert_contains "$out" "cannot be inspected" "the unavailable registered directory is refused"
was_closed "$EMISSING" && fail "an unavailable registered directory's endpoint was closed"

NONREPO="$TMP_ROOT/nonrepo"
mkdir -p "$NONREPO"
ENONREPO=$(new_eid)
add_endpoint "$ENONREPO" fm-nonrepo "$NONREPO" "$NONREPO" /bin/zsh
deck_record "$HOME_A" nonrepo "$ENONREPO" false
out=$(orphan "$HOME_A" --orphan nonrepo 2>&1) || fail "a plain non-repository directory was refused: $out"
was_closed "$ENONREPO" || fail "a plain non-repository endpoint was not closed"
pass "worktree discovery refuses broken, missing and failed Git reads but permits a non-repository"

# A finished scout's own worktree is scratch, as cleanup treats it: a done
# scout row with its report closes over scratch files, and the same scratch
# without the report is still refused.
if command -v tasks-axi >/dev/null 2>&1; then
  printf '%s\n' 'backend = "markdown"' '' '[markdown]' 'path = "data/backlog.md"' > "$HOME_A/.tasks.toml"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$HOME_A/data/backlog.md"
  for scout in scouted unreported; do
    tasks-axi add "$scout" "scout $scout" --kind scout --start --file "$HOME_A/data/backlog.md" >/dev/null
    tasks-axi "done" "$scout" --file "$HOME_A/data/backlog.md" >/dev/null
    git -C "$PROJECT" worktree add -q --detach "$TMP_ROOT/wt-$scout"
    mkdir -p "$TMP_ROOT/wt-$scout/.scratch"
    printf 'notes\n' > "$TMP_ROOT/wt-$scout/.scratch/run.log"
  done
  mkdir -p "$HOME_A/data/scouted"
  printf '# Report\n' > "$HOME_A/data/scouted/report.md"
  E4D=$(new_eid)
  add_endpoint "$E4D" fm-scouted "$PROJECT" "$TMP_ROOT/wt-scouted" /bin/zsh
  deck_record "$HOME_A" scouted "$E4D" false
  out=$(orphan "$HOME_A" --orphan scouted 2>&1) || fail "a finished scout's scratch was refused: $out"
  was_closed "$E4D" || fail "a finished scout's leftover was not closed"
  assert_grep "$TMP_ROOT/wt-scouted(finished-scout-scratch)" "$HOME_A/state/endpoint-retirements.log" \
    "the log marks the scout worktree as scratch"
  E4E=$(new_eid)
  add_endpoint "$E4E" fm-unreported "$PROJECT" "$TMP_ROOT/wt-unreported" /bin/zsh
  deck_record "$HOME_A" unreported "$E4E" false
  rc=0
  orphan "$HOME_A" --orphan unreported >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a scout without its report"
  was_closed "$E4E" && fail "a scout without its report was closed"
  pass "a finished scout's scratch closes; without its report it is refused"
else
  pass "skipped the finished-scout case (tasks-axi is not installed)"
fi

# --- 5. a live busy agent is refused ----------------------------------------
E5=$(new_eid)
add_endpoint "$E5" fm-busy "$PROJECT" "$CLEAN_WT" claude
deck_record "$HOME_A" busy "$E5" true
rc=0
out=$(orphan "$HOME_A" --orphan busy 2>&1) || rc=$?
expect_code 1 "$rc" "a busy agent"
assert_contains "$out" "busy" "the refusal says the agent is busy"

E5B=$(new_eid)
add_endpoint "$E5B" fm-pending "$PROJECT" "$CLEAN_WT" claude
deck_record "$HOME_A" pending "$E5B" false
printf 'steer\n--\nbody\n' > "$HOME_A/state/pending.inbox/001.msg"
rc=0
out=$(orphan "$HOME_A" --orphan pending 2>&1) || rc=$?
expect_code 1 "$rc" "an idle agent with a pending message"
assert_contains "$out" "unhandled message" "the refusal names the pending message"
was_closed "$E5" && fail "a busy agent's endpoint was closed"
was_closed "$E5B" && fail "an agent with pending work was closed"

E5C=$(new_eid)
add_endpoint "$E5C" fm-idle "$PROJECT" "$CLEAN_WT" claude
deck_record "$HOME_A" idle "$E5C" false
endpoint_option "$E5C" lifecycle_lock "$HOME_A/state/idle.inbox/deck-$E5C/.lifecycle.lock"
endpoint_option "$E5C" inbox_writer bash -c \
  'STATE=$2; . "$1"; fm_task_inbox_write "$2" "$3" "new work"' inbox-writer \
  "$ROOT/bin/fm-task-inbox-lib.sh" "$HOME_A/state" idle
out=$(orphan "$HOME_A" --orphan idle 2>&1) || fail "an idle agent with nothing pending was refused: $out"
was_closed "$E5C" || fail "an idle agent's leftover was not closed"
assert_grep "agent=alive-idle" "$HOME_A/state/endpoint-retirements.log" "the log records the idle agent"
assert_absent "$HOME_A/state/idle.inbox/001.msg" "inbox publication was blocked across the close"
pass "a live busy agent is refused, an idle one with nothing pending closes"

ERACE=$(new_eid)
add_endpoint "$ERACE" fm-turnrace "$PROJECT" "$CLEAN_WT" /bin/zsh
deck_record "$HOME_A" turnrace "$ERACE" false
endpoint_option "$ERACE" cwd_hook python3 "$ROOT/bin/fm_stream_deck.py" start \
  "$HOME_A/state" turnrace "$ERACE" racing-turn true
rc=0
out=$(orphan "$HOME_A" --orphan turnrace 2>&1) || rc=$?
expect_code 1 "$rc" "a turn starting during worktree discovery"
assert_contains "$out" "busy" "the final check observes the new turn"
was_closed "$ERACE" && fail "a worker starting a turn after the initial check was closed"
assert_equals "true" "$(jq -r .active "$HOME_A/state/turnrace.inbox/deck-$ERACE/active.json")" \
  "the real Deck driver started the competing turn"

EMSGRACE=$(new_eid)
add_endpoint "$EMSGRACE" fm-msgrace "$PROJECT" "$CLEAN_WT" claude
deck_record "$HOME_A" msgrace "$EMSGRACE" false
endpoint_option "$EMSGRACE" cwd_hook bash -c \
  'STATE=$2; . "$1"; fm_task_inbox_write "$2" "$3" "new work"' inbox-writer \
  "$ROOT/bin/fm-task-inbox-lib.sh" "$HOME_A/state" msgrace
rc=0
out=$(orphan "$HOME_A" --orphan msgrace 2>&1) || rc=$?
expect_code 1 "$rc" "a message arriving during worktree discovery"
assert_contains "$out" "unhandled message" "the final check observes the new message"
was_closed "$EMSGRACE" && fail "an endpoint receiving new work after the initial check was closed"
assert_present "$HOME_A/state/msgrace.inbox/001.msg" "the real inbox writer published the message"

ELOCKED=$(new_eid)
add_endpoint "$ELOCKED" fm-locked "$PROJECT" "$CLEAN_WT" claude
deck_record "$HOME_A" locked "$ELOCKED" false
python3 - "$HOME_A/state/locked.inbox/deck-$ELOCKED/.lifecycle.lock" \
  "$ROOT/bin/fm-retire-endpoint.sh" "$URL" "$TOKEN" "$MACHINE" "$HOME_A" <<'PY'
import fcntl, os, subprocess, sys
path, script, url, token, machine, home = sys.argv[1:]
with open(path, 'a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    env = dict(os.environ, FM_HOME=home, FM_STREAM_HUB=url,
               FM_STREAM_TOKEN=token, FM_STREAM_MACHINE=machine)
    result = subprocess.run([script, '--orphan', 'locked'], env=env,
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 1, result.stderr
    assert 'lifecycle could not be locked' in result.stderr, result.stderr
PY
[ "$?" -eq 0 ] || fail "retirement did not refuse a lifecycle lock held by another process"
was_closed "$ELOCKED" && fail "an endpoint with a competing lifecycle owner was closed"
pass "final checks refuse a new turn, new message and competing lifecycle lock"

# --- 6. a task that still has a record is not a leftover --------------------
E6=$(new_eid)
add_endpoint "$E6" fm-recorded "$PROJECT" "$CLEAN_WT" /bin/zsh
deck_record "$HOME_A" recorded "$E6" false
fm_write_meta "$HOME_A/state/recorded.meta" "kind=ship" "backend=stream"
rc=0
out=$(orphan "$HOME_A" --orphan recorded 2>&1) || rc=$?
expect_code 1 "$rc" "a recorded task"
assert_contains "$out" "fm-teardown.sh" "the refusal points at cleanup"
rc=0
out=$(FM_STREAM_HUB="$URL" FM_STREAM_TOKEN="$TOKEN" "$ROOT/bin/fm-retire-endpoint.sh" --orphan recorded 2>&1) || rc=$?
expect_code 1 "$rc" "an implicit home"
assert_contains "$out" "explicit FM_HOME" "the refusal asks for the owning home"
was_closed "$E6" && fail "a recorded task's endpoint was closed"
pass "a recorded task and an implicit home are refused"

# --- 7. the remote route runs it against the remote home --------------------
# bin/fm-on.sh's remote entrypoint runs the command under an empty environment
# with the remote home's FM_HOME, so the hub settings come from that home's
# config, exactly as on a real remote secondmate.
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME=$(new_home remote-home)
LOCAL_HOME=$(new_home local-home)
mkdir -p "$REMOTE_ROOT"
cp -R "$ROOT/bin" "$REMOTE_ROOT/bin"
printf 'fixture\n' > "$REMOTE_ROOT/AGENTS.md"
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" add AGENTS.md bin
git -C "$REMOTE_ROOT" -c user.name=T -c user.email=t@example.invalid commit -qm fixture
printf '%s\n' "$URL" > "$REMOTE_HOME/config/stream-hub"
printf '%s\n' "$TOKEN" > "$REMOTE_HOME/config/stream-token"
printf '%s\n' "$MACHINE" > "$REMOTE_HOME/config/stream-machine"
printf -- '- far - Remote work (host: remote-box; root: %s; home: %s; scope: remote work; projects: ; added 2026-10-10)\n' \
  "$REMOTE_ROOT" "$REMOTE_HOME" > "$LOCAL_HOME/data/secondmates.md"
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
[ "$1" = remote-box ] || exit 91
[ "$2" = fm-remote-entrypoint.sh ] || exit 92
shift 2
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"
E7=$(new_eid)
add_endpoint "$E7" fm-faraway "$PROJECT" "$CLEAN_WT" /bin/zsh
deck_record "$REMOTE_HOME" faraway "$E7" false
rc=0
out=$(FM_HOME="$LOCAL_HOME" FM_ROOT_OVERRIDE="$REMOTE_ROOT" FM_SSH_BIN="$FAKEBIN/fake-ssh" \
  FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
  FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
  "$ROOT/bin/fm-on.sh" far fm-retire-endpoint.sh --orphan faraway 2>&1) || rc=$?
if [ -f "$TMP_ROOT/remote-jobs/worker.pid" ]; then
  # shellcheck source=bin/fm-remote-job-lib.sh
  . "$ROOT/bin/fm-remote-job-lib.sh"
  FM_REMOTE_JOB_STATE="$TMP_ROOT/remote-jobs"
  fm_remote_job_stop_worker_tree "$(cat "$TMP_ROOT/remote-jobs/worker.pid")" 2>/dev/null || true
fi
expect_code 0 "$rc" "the remote route: $out"
was_closed "$E7" || fail "the remote route did not close the remote home's leftover"
assert_grep "basis=orphan-endpoint" "$REMOTE_HOME/state/endpoint-retirements.log" "the remote home logs the close"
pass "bin/fm-on.sh runs the close against a remote home"
