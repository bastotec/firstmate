#!/usr/bin/env bash
# tests/fm-stream-bridge-rust.test.sh - parity proof for the Rust bridge port
# (crates/fm-stream-bridge) against the Python reference (bin/fm-stream-bridge.py).
#
# The port's spec is the reference's OBSERVED BEHAVIOUR, so every case runs
# BOTH binaries over the same input and compares:
#   - `translate` over recorded hub traffic: stdout must be byte-identical,
#     because the NDJSON feed is consumed byte-for-byte downstream;
#   - refusals and usage errors: exit status and stderr must be byte-identical
#     where the message is deterministic (transport-level detail is not);
#   - `snapshot` and `serve` against a REAL disposable hub on an ephemeral
#     loopback port, where the two clocks are inherently process-local, so the
#     comparison drops only the clock object and holds every other byte to
#     identity;
#   - `compare` against a stand-in crew-state script, never the live fleet.
#
# This test never touches the host's shared live hub on 127.0.0.1:7717: every
# hub it starts binds 127.0.0.1 with --port 0 and its own token file, and the
# ambient stream configuration is unset so nothing can leak into a case.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v cargo >/dev/null 2>&1 || { echo "skip: cargo not found (required by the Rust stream port)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required by the stream backend)"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found (required by the stream backend)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the stream backend)"; exit 0; }

# Ambient stream configuration must not leak into a parity case: the reference
# reads these, and a stray FM_HOME would redirect compare's default home.
unset FM_STREAM_HUB FM_STREAM_TOKEN FM_STREAM_TOKEN_FILE FM_HOME
# argparse rewraps its help to the terminal width, and the port pins the
# reference's default 80-column layout, so hold both to it.
COLUMNS=80
export COLUMNS

TMP_ROOT=$(fm_test_tmproot fm-stream-bridge-rust-tests)
HUB="$ROOT/bin/fm-stream-hub.py"
BRIDGE="$ROOT/bin/fm-stream-bridge.py"
RUST_BRIDGE="$ROOT/target/debug/fm-stream-bridge"
PUBLISH_TOKEN="pub-$$"
VIEW_TOKEN="view-$$"
CONTROL_TOKEN="ctl-$$"
CASE_DIR=""
URL=""
HUB_PID=""
RUN=$$

cleanup_helpers() {
  fm_test_reap_helper_pids
}
trap 'cleanup_helpers; fm_test_cleanup' EXIT INT TERM

# Build the port once, locked to the committed Cargo.lock so the binary under
# test is the one a clean checkout builds.
( cd "$ROOT" && cargo build -p fm-stream-bridge --locked --quiet ) \
  || fail "cargo build of the Rust bridge failed"

# run_both <stdin-file|-> <args...>: run both bridges over the same input and
# record their stdout, stderr, and exit status for the parity assertions.
run_both() {
  local stdin=$1
  shift
  python3 "$BRIDGE" "$@" <"$stdin" >"$TMP_ROOT/py.out" 2>"$TMP_ROOT/py.err"
  PY_CODE=$?
  "$RUST_BRIDGE" "$@" <"$stdin" >"$TMP_ROOT/rs.out" 2>"$TMP_ROOT/rs.err"
  RS_CODE=$?
}

# assert_parity <label>: both sides exited the same way, printed the same
# stdout bytes, and printed the same stderr bytes.
assert_parity() {
  local label=$1
  assert_equals "$PY_CODE" "$RS_CODE" "$label: exit status should match the reference"
  cmp -s "$TMP_ROOT/py.out" "$TMP_ROOT/rs.out" \
    || fail "$label: stdout differs from the reference: $(diff "$TMP_ROOT/py.out" "$TMP_ROOT/rs.out" | head -5)"
  cmp -s "$TMP_ROOT/py.err" "$TMP_ROOT/rs.err" \
    || fail "$label: stderr differs from the reference: $(diff "$TMP_ROOT/py.err" "$TMP_ROOT/rs.err" | head -5)"
}

# assert_parity_status_and_stdout <label>: exit status and stdout compared,
# stderr only checked nonempty-or-empty alike (for messages whose middle is
# transport detail the two clients word differently).
assert_parity_status_and_stdout() {
  local label=$1
  assert_equals "$PY_CODE" "$RS_CODE" "$label: exit status should match the reference"
  cmp -s "$TMP_ROOT/py.out" "$TMP_ROOT/rs.out" \
    || fail "$label: stdout differs from the reference: $(diff "$TMP_ROOT/py.out" "$TMP_ROOT/rs.out" | head -5)"
  if [ -s "$TMP_ROOT/py.err" ] && [ ! -s "$TMP_ROOT/rs.err" ]; then
    fail "$label: the reference reported on stderr but the port stayed silent"
  fi
  if [ -s "$TMP_ROOT/rs.err" ] && [ ! -s "$TMP_ROOT/py.err" ]; then
    fail "$label: the port reported on stderr but the reference stayed silent"
  fi
}

# assert_parity_beyond_clocks <label>: exit status and record count match,
# and every byte of the records matches once the two process-local clocks
# are dropped - the strongest comparison two processes can reach on live
# polls.
assert_parity_beyond_clocks() {
  local label=$1
  assert_equals "$PY_CODE" "$RS_CODE" "$label: exit status should match the reference"
  assert_equals "$(wc -l <"$TMP_ROOT/py.out" | tr -d ' ')" "$(wc -l <"$TMP_ROOT/rs.out" | tr -d ' ')" \
    "$label: the record count should match the reference"
  cmp -s <(normalized "$TMP_ROOT/py.out") <(normalized "$TMP_ROOT/rs.out") \
    || fail "$label: records differ beyond the clocks: $(diff <(normalized "$TMP_ROOT/py.out") <(normalized "$TMP_ROOT/rs.out") | head -5)"
}

start_hub() {
  local name=$1 ready waited=0 host port pid
  cleanup_helpers
  CASE_DIR="$TMP_ROOT/$name"
  mkdir -p "$CASE_DIR"
  printf 'publish:%s\nsubscribe,control:%s\n%s\n' \
    "$PUBLISH_TOKEN" "$CONTROL_TOKEN" "$VIEW_TOKEN" > "$CASE_DIR/tokens"
  printf '%s\n' "$VIEW_TOKEN" > "$CASE_DIR/view-token"
  printf '%s\n' "$PUBLISH_TOKEN" > "$CASE_DIR/publish-token"
  chmod 600 "$CASE_DIR/tokens" "$CASE_DIR/view-token" "$CASE_DIR/publish-token"
  ready="$CASE_DIR/ready"
  python3 "$HUB" serve --bind 127.0.0.1 --port 0 \
    --token-file "$CASE_DIR/tokens" --ready-file "$ready" > "$CASE_DIR/log" 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true
  fm_test_track_helper_pid "$pid"
  HUB_PID=$pid
  while [ "$waited" -lt 100 ]; do
    [ -s "$ready" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$ready" ] || fail "hub did not report ready for case $name: $(cat "$CASE_DIR/log" 2>/dev/null)"
  read -r host port < "$ready"
  URL="http://$host:$port"
}

publish() {  # <method> <path> <body>
  curl -sS -m 30 -X "$1" -H "Authorization: Bearer $PUBLISH_TOKEN" \
    -H 'Content-Type: application/json' --data-binary "$3" -o /dev/null \
    -w '%{http_code}' "$URL$2" 2>/dev/null
}

new_id() {
  python3 -c 'import os; print(os.urandom(16).hex())'
}

register() {  # <endpoint-id> <machine> <label>
  local code
  code=$(publish POST /v1/agent/endpoints "$(jq -nc --arg id "$1" --arg m "$2" --arg l "$3" \
    '{endpoint_id: $id, machine: $m, label: $l, cwd: "/tmp"}')")
  assert_equals "$code" 201 "endpoint $3 should register"
}

close_endpoint() {  # <endpoint-id> <machine> <exit-code-json>
  local code
  code=$(publish POST /v1/agent/frames "$(jq -nc --arg id "$1" --arg m "$2" --argjson c "$3" \
    '{machine: $m, frames: [{endpoint_id: $id, closed: true, exit_code: $c}]}')")
  assert_equals "$code" 200 "the owning agent should close its record"
}

# normalized <feed>: the feed with only the two process-local clocks removed;
# every other byte is comparable between two processes.
normalized() {
  jq -c 'del(.clock.producer_monotonic_ms, .clock.hub_arrival_ms)' "$1"
}

test_recorded_traffic_is_byte_identical() {
  local feed="$TMP_ROOT/recorded.ndjson"
  {
    # A fleet at one instant: open, hub-forced, agent-reported exits of every
    # shape the hub can carry, one label on two machines.
    jq -nc '{at_ms: 0, received_ms: 0, listing: {ok: true, tasks: [
      {endpoint_id: "0123456789abcdef0123456789abcdef", machine: "box-a", label: "task-open", closed_by: null, exit_code: null},
      {endpoint_id: "11111111111111111111111111111111", machine: "box-a", label: "task-forced", closed_by: "hub", exit_code: null},
      {endpoint_id: "22222222222222222222222222222222", machine: "box-b", label: "task-open", closed_by: "agent", exit_code: 0}]}}'
    # The same fleet later: a signal exit, a close with no code, a failing
    # exit, and float clocks that render differently across encoders.
    jq -nc '{at_ms: 500.5, received_ms: 499, listing: {ok: true, tasks: [
      {endpoint_id: "0123456789abcdef0123456789abcdef", machine: "box-a", label: "task-open", closed_by: null, exit_code: null},
      {endpoint_id: "33333333333333333333333333333333", machine: "box-a", label: "task-signal", closed_by: "agent", exit_code: -15},
      {endpoint_id: "44444444444444444444444444444444", machine: "box-c", label: "task-nocode", closed_by: "agent", exit_code: null},
      {endpoint_id: "55555555555555555555555555555555", machine: "box-c", label: "task-failing", closed_by: "agent", exit_code: 3}]}}'
    # A relaunch: the new endpoint supersedes the old one for the same leaf,
    # keeping the leaf's first-insertion position and one rising sequence.
    jq -nc '{at_ms: 1000, listing: {tasks: [
      {endpoint_id: "66666666666666666666666666666666", machine: "box-a", label: "task-open", closed_by: "agent", exit_code: 2},
      {endpoint_id: "77777777777777777777777777777777", machine: "box-a", label: "task-open", closed_by: null, exit_code: null}]}}'
    # The hub dropped a leaf entirely: it is simply not emitted again.
    jq -nc '{at_ms: 1500, listing: {tasks: [
      {endpoint_id: "77777777777777777777777777777777", machine: "box-a", label: "task-open", closed_by: null, exit_code: null}]}}'
    # Records the hub itself would have refused to register are not leaves,
    # and unknown fields on real ones are ignored, not copied.
    jq -nc '{at_ms: 2000, listing: {tasks: [
      {endpoint_id: "not-an-id", machine: "m", label: "bad"},
      {endpoint_id: "88888888888888888888888888888888", machine: "bad machine", label: "x"},
      {endpoint_id: "99999999999999999999999999999999", machine: "m", label: "ok", extra: "ignored", cols: 200}]}}'
    # An empty fleet still ticks, emitting nothing.
    jq -nc '{at_ms: 2500, listing: {tasks: []}}'
    # Clock renderings that separate JSON encoders: scientific notation
    # thresholds, integer-valued floats, and a negative zero (hand-written,
    # because jq normalizes -0.0 away).
    printf '%s\n' \
      '{"at_ms": 0.00001, "received_ms": 0.000009, "listing": {"tasks": [{"endpoint_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "machine": "m", "label": "t", "closed_by": null}]}}' \
      '{"at_ms": 1e16, "listing": {"tasks": [{"endpoint_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "machine": "m", "label": "t", "closed_by": null}]}}' \
      '{"at_ms": 5, "listing": {"tasks": [{"endpoint_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "machine": "m", "label": "t", "closed_by": null}]}}' \
      '{"at_ms": -0.0, "listing": {"tasks": [{"endpoint_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "machine": "m", "label": "t", "closed_by": null}]}}' \
      '{"at_ms": 1789829165998.0, "received_ms": 1789829165997.25, "listing": {"tasks": [{"endpoint_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "machine": "m", "label": "t", "closed_by": null}]}}'
  } > "$feed"
  run_both "$feed" translate --fleet-id fleet-t --epoch 7
  assert_parity "recorded traffic"
  assert_equals "$(wc -l <"$TMP_ROOT/py.out" | tr -d ' ')" 15 \
    "the battery should emit 15 records"
  # A fleet identity outside ASCII pins the \\uXXXX escaping byte-for-byte.
  run_both "$feed" translate --fleet-id "flotte-é-中文" --epoch 7
  assert_parity "recorded traffic with a non-ASCII fleet id"
  run_both "$feed" translate
  assert_parity "recorded traffic with default fleet and epoch 0"
  run_both /dev/null translate
  assert_parity "an empty recording"
  pass "bridge-rust: recorded hub traffic replays byte-identically"
}

test_refusals_match_the_reference() {
  local one="$TMP_ROOT/one-line"
  printf 'not json\n' > "$one"
  run_both "$one" translate
  assert_parity "a malformed recording"
  printf '%s\n' '{"at_ms": -1, "listing": {"tasks": []}}' > "$one"
  run_both "$one" translate
  assert_parity "a negative clock"
  printf '%s\n' '{"at_ms": 5, "received_ms": 9, "listing": {"tasks": []}}' > "$one"
  run_both "$one" translate
  assert_parity "a recording received after it was built"
  printf '%s\n' '{"at_ms": 5}' > "$one"
  run_both "$one" translate
  assert_parity "a recording with no listing"
  # Python's parser accepts NaN; both must refuse it as a clock, identically.
  printf '%s\n' '{"at_ms": NaN, "listing": {"tasks": []}}' > "$one"
  run_both "$one" translate
  assert_parity "a NaN clock"
  # A well-formed JSON line that is not an object.
  printf '%s\n' '[1, 2]' > "$one"
  run_both "$one" translate
  assert_parity "a recording that is not an object"
  run_both /dev/null translate --epoch -1
  assert_parity "a negative epoch"
  run_both /dev/null translate --fleet-id ""
  assert_parity "an empty fleet id"
  # The interval refusal fires before the token is even read.
  run_both /dev/null serve --hub http://127.0.0.1:1 --token-file "$TMP_ROOT/no-such-token" --interval-ms 1500
  assert_parity "a tick at the stale threshold"
  # The token-file refusal names the OS's own words for the failure.
  run_both /dev/null snapshot --hub http://127.0.0.1:1 --token-file "$TMP_ROOT/no-such-token"
  assert_parity "an unreadable token file"
  pass "bridge-rust: refusals match the reference's words and exit statuses"
}

# Help and argparse usage presentation vary by Python version; they are not
# wire parity. Operational refusals above remain exact byte comparisons.
test_cli_surface_matches() {
  local sub
  for sub in '' serve snapshot translate compare; do
    if [ -n "$sub" ]; then
      run_both /dev/null "$sub" --help
    else
      run_both /dev/null --help
    fi
    assert_equals "$PY_CODE" 0 "reference help succeeds"
    assert_equals "$RS_CODE" 0 "Rust help succeeds"
    assert_grep 'usage:' "$TMP_ROOT/rs.out" "Rust help describes the CLI"
  done
  run_both /dev/null --protocol
  assert_parity "the protocol probe"
  run_both /dev/null --version --protocol
  assert_parity "protocol beats version"
  run_both /dev/null --version
  assert_equals "$PY_CODE" 0 "reference version succeeds"
  assert_equals "$RS_CODE" 0 "Rust version succeeds"
  run_both /dev/null translate --fleet=example --epo=1_007
  assert_parity "accepted unique flag prefixes and Python integer separators"
  run_both /dev/null compare --h value
  assert_parity "an ambiguous flag prefix"
  run_both /dev/null translate --epoch=9223372036854775808
  assert_equals "$PY_CODE" 0 "the reference accepts arbitrary-precision epochs"
  assert_equals "$RS_CODE" 2 "the port documents and enforces its signed 64-bit epoch limit"
  for sub in '' bogus serve; do
    if [ -n "$sub" ]; then
      run_both /dev/null "$sub"
    else
      run_both /dev/null
    fi
    assert_equals "$PY_CODE" 2 "reference rejects incomplete or invalid command"
    assert_equals "$RS_CODE" 2 "Rust rejects incomplete or invalid command"
    assert_parity_status_and_stdout "command refusal"
  done
  run_both /dev/null translate --epoch abc
  assert_parity "a bad integer"
  run_both /dev/null translate --epoch
  assert_parity "a hungry option"
  run_both /dev/null --nonsense 1 translate
  assert_parity_status_and_stdout "an unknown top-level option"
  run_both /dev/null translate --epoch --fleet-id f
  assert_parity "an option-looking value is not a value"
  run_both /dev/null translate -- extra
  assert_parity "the option terminator inside a subcommand"
  pass "bridge-rust: CLI flags, choices, defaults and exit statuses match"
}

test_a_real_hubs_listing_replays_identically() {
  start_hub replay
  local open finished forced relaunched body feed
  open=$(new_id); finished=$(new_id); forced=$(new_id); relaunched=$(new_id)
  register "$open" box-a "open-$RUN"
  register "$finished" box-b "finished-$RUN"
  register "$forced" box-a "forced-$RUN"
  close_endpoint "$finished" box-b 0
  close_endpoint "$forced" box-a 2
  register "$relaunched" box-a "relaunched-$RUN"
  # The hub's actual /v1/tasks answer, captured verbatim and replayed through
  # both translators with fixed clocks: byte parity over real hub state.
  body=$(curl -sS -m 5 -H "Authorization: Bearer $VIEW_TOKEN" "$URL/v1/tasks")
  feed="$CASE_DIR/real-recording.ndjson"
  jq -nc --argjson listing "$body" '{at_ms: 1234.5, received_ms: 1000, listing: $listing}' > "$feed"
  run_both "$feed" translate --fleet-id fleet-real --epoch 42
  assert_parity "the real hub's listing"
  assert_equals "$(jq -r --arg l "box-a/relaunched-$RUN" 'select(.identity.leaf_worker_id == $l) | .identity.execution_id' "$TMP_ROOT/rs.out")" \
    "$relaunched" "the newest endpoint should win for a relaunched leaf"
  pass "bridge-rust: a real hub's listing replays byte-identically"
}

test_snapshot_parity_against_the_real_hub() {
  start_hub snapshot
  local open finished forced
  open=$(new_id); finished=$(new_id); forced=$(new_id)
  register "$open" box-a "open-$RUN"
  register "$finished" box-b "finished-$RUN"
  register "$forced" box-a "forced-$RUN"
  close_endpoint "$finished" box-b 0
  close_endpoint "$forced" box-a 2
  run_both /dev/null snapshot --hub "$URL" --token-file "$CASE_DIR/view-token" --fleet-id fleet-s --epoch 42
  assert_parity_beyond_clocks "a snapshot of the real hub"
  # The clocks are process-local; everything else must be identical bytes.
  # The producer clock is taken after the hub answer arrived, in both.
  local bad
  bad=$(jq -r 'select(.clock.producer_monotonic_ms < .clock.hub_arrival_ms) | .identity.leaf_worker_id' "$TMP_ROOT/rs.out" "$TMP_ROOT/py.out")
  assert_equals "$bad" "" "the producer clock should never precede the arrival clock"
  # A credential without the subscribe class is refused, word for word.
  run_both /dev/null snapshot --hub "$URL" --token-file "$CASE_DIR/publish-token"
  assert_parity "a credential without the subscribe class"
  # A hub speaking another protocol is refused, word for word.
  local fake_dir="$CASE_DIR/fake" ready waited=0 host port pid
  mkdir -p "$fake_dir"
  ready="$fake_dir/ready"
  python3 - "$ready" > "$fake_dir/log" 2>&1 <<'PY' &
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        body = json.dumps({"ok": True, "protocol": 99}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
server = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write("%s %d\n" % server.server_address)
server.serve_forever()
PY
  pid=$!
  disown "$pid" 2>/dev/null || true
  fm_test_track_helper_pid "$pid"
  while [ "$waited" -lt 50 ]; do
    [ -s "$ready" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  read -r host port < "$ready"
  run_both /dev/null snapshot --hub "http://$host:$port" --token-file "$CASE_DIR/view-token"
  assert_parity "a hub speaking another protocol"
  # An unreachable hub ends a snapshot with exit 1 on both sides; the exact
  # transport wording is each client's own.
  run_both /dev/null snapshot --hub "http://127.0.0.1:1" --token-file "$CASE_DIR/view-token"
  assert_equals "$PY_CODE" 1 "an unreachable hub should exit 1 for the reference"
  assert_equals "$RS_CODE" 1 "an unreachable hub should exit 1 for the port"
  assert_grep 'cannot reach the hub at' "$TMP_ROOT/rs.err" "the port should name the unreachable hub"
  pass "bridge-rust: snapshots of a real hub match beyond the process-local clocks"
}

test_https_and_redirect_transport_parity() {
  local transport_dir="$TMP_ROOT/transports" ready waited pid host port cert key ca_key csr ext
  cleanup_helpers
  mkdir -p "$transport_dir"
  printf '%s\n' "$VIEW_TOKEN" > "$transport_dir/view-token"
  cat > "$transport_dir/server.py" <<'PY'
import http.server, json, ssl, sys

TASK = {"endpoint_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "machine": "box-a",
        "label": "transport", "closed_by": None, "exit_code": None}

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, payload):
        body = json.dumps(payload, separators=(",", ":")).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if MODE == "redirect" and self.path == "/v1/health":
            self.send_response(302)
            self.send_header("Location", "/actual-health")
            self.end_headers()
        elif MODE == "redirect" and self.path == "/v1/tasks":
            host, port = self.server.server_address
            self.send_response(307)
            self.send_header("Location", "http://%s:%d/actual-tasks" % (host, port))
            self.end_headers()
        elif self.path in ("/v1/health", "/actual-health"):
            self.answer({"ok": True, "protocol": 2})
        elif self.path in ("/v1/tasks", "/actual-tasks"):
            self.answer({"ok": True, "tasks": [TASK]})
        else:
            self.send_error(404)

MODE = sys.argv[2]
server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
if MODE == "https":
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(sys.argv[3], sys.argv[4])
    server.socket = context.wrap_socket(server.socket, server_side=True)
with open(sys.argv[1], "w") as ready:
    ready.write("127.0.0.1 %d\n" % server.server_address[1])
server.serve_forever()
PY

  ready="$transport_dir/redirect-ready"
  python3 "$transport_dir/server.py" "$ready" redirect > "$transport_dir/redirect.log" 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true
  fm_test_track_helper_pid "$pid"
  waited=0
  while [ "$waited" -lt 50 ]; do
    [ -s "$ready" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  read -r host port < "$ready"
  run_both /dev/null snapshot --hub "http://$host:$port" \
    --token-file "$transport_dir/view-token" --epoch 8
  assert_parity_beyond_clocks "a snapshot through relative and absolute redirects"

  if ! command -v openssl >/dev/null 2>&1; then
    echo "skip: HTTPS bridge parity (openssl not found)"
    return
  fi
  cleanup_helpers
  cert="$transport_dir/ca.pem"
  ca_key="$transport_dir/ca-key.pem"
  key="$transport_dir/server-key.pem"
  csr="$transport_dir/server.csr"
  ext="$transport_dir/server.ext"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$ca_key" -out "$cert" -subj '/CN=Bridge test CA' \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign' \
    -addext 'subjectKeyIdentifier=hash' > "$transport_dir/openssl.log" 2>&1 \
    || fail "could not create the disposable HTTPS CA"
  openssl req -newkey rsa:2048 -nodes -keyout "$key" -out "$csr" \
    -subj '/CN=localhost' >> "$transport_dir/openssl.log" 2>&1 \
    || fail "could not create the disposable HTTPS server key"
  printf '%s\n' \
    'subjectAltName=DNS:localhost,IP:127.0.0.1' \
    'basicConstraints=critical,CA:FALSE' \
    'keyUsage=critical,digitalSignature,keyEncipherment' \
    'extendedKeyUsage=serverAuth' \
    'subjectKeyIdentifier=hash' \
    'authorityKeyIdentifier=keyid,issuer' > "$ext"
  openssl x509 -req -in "$csr" -CA "$cert" -CAkey "$ca_key" -CAcreateserial \
    -days 1 -out "$transport_dir/server.pem" -extfile "$ext" \
    >> "$transport_dir/openssl.log" 2>&1 \
    || fail "could not sign the disposable HTTPS server certificate"
  ready="$transport_dir/https-ready"
  python3 "$transport_dir/server.py" "$ready" https "$transport_dir/server.pem" "$key" > "$transport_dir/https.log" 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true
  fm_test_track_helper_pid "$pid"
  waited=0
  while [ "$waited" -lt 50 ]; do
    [ -s "$ready" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  read -r host port < "$ready"
  SSL_CERT_FILE="$cert" python3 "$BRIDGE" snapshot --hub "https://localhost:$port" \
    --token-file "$transport_dir/view-token" --epoch 9 > "$TMP_ROOT/py.out" 2> "$TMP_ROOT/py.err"
  PY_CODE=$?
  SSL_CERT_FILE="$cert" "$RUST_BRIDGE" snapshot --hub "https://localhost:$port" \
    --token-file "$transport_dir/view-token" --epoch 9 > "$TMP_ROOT/rs.out" 2> "$TMP_ROOT/rs.err"
  RS_CODE=$?
  assert_parity_beyond_clocks "a snapshot over HTTPS"
  pass "bridge-rust: HTTPS and redirected hubs match the reference"
}

test_serve_streams_ticks_and_survives_a_hub_outage() {
  start_hub serve
  local endpoint py_out rs_out py_err rs_err waited=0 lines pid
  endpoint=$(new_id)
  register "$endpoint" box-a "serve-$RUN"
  py_out="$CASE_DIR/serve-py.out"; py_err="$CASE_DIR/serve-py.err"
  rs_out="$CASE_DIR/serve-rs.out"; rs_err="$CASE_DIR/serve-rs.err"
  python3 "$BRIDGE" serve --hub "$URL" --token-file "$CASE_DIR/view-token" \
    --interval-ms 100 --epoch 3 > "$py_out" 2> "$py_err" &
  pid=$!
  disown "$pid" 2>/dev/null || true
  fm_test_track_helper_pid "$pid"
  "$RUST_BRIDGE" serve --hub "$URL" --token-file "$CASE_DIR/view-token" \
    --interval-ms 100 --epoch 3 > "$rs_out" 2> "$rs_err" &
  pid=$!
  disown "$pid" 2>/dev/null || true
  fm_test_track_helper_pid "$pid"
  while [ "$waited" -lt 100 ]; do
    lines=$(wc -l < "$rs_out" | tr -d ' ')
    [ "$lines" -ge 3 ] && [ "$(wc -l < "$py_out" | tr -d ' ')" -ge 3 ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ "$lines" -ge 3 ] || fail "the Rust serve should emit a heartbeat every tick: $(cat "$rs_err")"
  cmp -s <(normalized "$py_out" | head -3) <(normalized "$rs_out" | head -3) \
    || fail "serve ticks differ beyond the clocks: $(diff <(normalized "$py_out" | head -3) <(normalized "$rs_out" | head -3))"
  assert_equals "$(jq -r '.sequence' "$rs_out" | head -3 | tr '\n' ' ')" "1 2 3 " \
    "one leaf's sequence should rise by one each tick"
  jq -r '.clock.producer_monotonic_ms' "$rs_out" | head -3 | sort -n -c \
    || fail "the producer clock should never go backwards"
  # The hub goes away: both adapters report it once, emit nothing, and live.
  kill "$HUB_PID" || fail "could not stop this case's hub"
  waited=0
  while [ "$waited" -lt 50 ]; do
    grep -q 'emitting nothing' "$rs_err" && break
    sleep 0.1
    waited=$((waited + 1))
  done
  assert_grep 'emitting nothing' "$rs_err" "an unreachable hub should be reported on stderr"
  assert_grep 'emitting nothing' "$py_err" "the reference should agree the hub is gone"
  local before after
  before=$(wc -l < "$rs_out" | tr -d ' ')
  sleep 0.5
  after=$(wc -l < "$rs_out" | tr -d ' ')
  assert_equals "$after" "$before" "nothing should be emitted while the hub cannot be read"
  # An interrupt is exit 130, from any posture: wait immediately after the
  # signal, before the shell can reap the process and lose its status.
  "$RUST_BRIDGE" serve --hub "http://127.0.0.1:1" --token-file "$CASE_DIR/view-token" \
    --interval-ms 100 > "$TMP_ROOT/int.out" 2> "$TMP_ROOT/int.err" &
  local rust_pid=$!
  sleep 0.4
  kill -INT "$rust_pid" 2>/dev/null
  wait "$rust_pid" 2>/dev/null
  assert_equals "$?" 130 "an interrupted Rust serve should exit 130 like the reference"
  pass "bridge-rust: serve streams like the reference and survives a hub outage"
}

test_a_closed_reader_ends_the_feed() {
  local feed="$TMP_ROOT/big.ndjson" i
  : > "$feed"
  for i in 1 2 3 4 5; do
    jq -nc --argjson n "$i" '{at_ms: ($n * 100), listing: {tasks: [
      {endpoint_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", machine: "m", label: "t1", closed_by: null, exit_code: null},
      {endpoint_id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", machine: "m", label: "t2", closed_by: null, exit_code: null}]}}' >> "$feed"
  done
  # A reader that leaves after the first record must end the feed with exit 0,
  # not a partial record or a traceback.
  bash -c 'python3 "$1" translate --epoch 1 < "$2" | head -1 > "$3"; exit ${PIPESTATUS[0]}' \
    _ "$BRIDGE" "$feed" "$TMP_ROOT/py.head"
  assert_equals "$?" 0 "the reference should end cleanly when the reader leaves"
  bash -c '"$1" translate --epoch 1 < "$2" | head -1 > "$3"; exit ${PIPESTATUS[0]}' \
    _ "$RUST_BRIDGE" "$feed" "$TMP_ROOT/rs.head"
  assert_equals "$?" 0 "the port should end cleanly when the reader leaves"
  cmp -s "$TMP_ROOT/py.head" "$TMP_ROOT/rs.head" \
    || fail "the first record should be identical before the reader leaves"
  pass "bridge-rust: a closed reader ends the feed cleanly on both sides"
}

test_compare_harness_parity() {
  local home feed stub pipe_home padding i
  home="$TMP_ROOT/compare-home"
  mkdir -p "$home/state"
  fm_write_meta "$home/state/t-live.meta" backend=stream \
    stream_endpoint_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  fm_write_meta "$home/state/t-exited.meta" backend=stream \
    stream_endpoint_id=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  fm_write_meta "$home/state/t-conflict.meta" backend=stream \
    stream_endpoint_id=cccccccccccccccccccccccccccccccc
  fm_write_meta "$home/state/t-gone.meta" backend=stream \
    stream_endpoint_id=dddddddddddddddddddddddddddddddd
  fm_write_meta "$home/state/t-tmux.meta" backend=tmux window=firstmate:fm-t-tmux
  stub="$TMP_ROOT/crew-state-stub"
  cat > "$stub" <<'SH'
#!/bin/sh
case "$1" in
  t-live) echo 'state: working · source: pane · busy' ;;
  t-exited) echo 'state: done · source: status-log · finished' ;;
  t-conflict) echo 'state: working · source: pane · busy' ;;
  t-gone) echo 'state: unknown · source: none · endpoint dead' ;;
  *) echo "unexpected task $1" >&2; exit 2 ;;
esac
SH
  chmod +x "$stub"
  feed="$TMP_ROOT/compare-feed.ndjson"
  jq -nc '{at_ms: 1, listing: {tasks: [
      {endpoint_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", machine: "m", label: "t-live", closed_by: null, exit_code: null},
      {endpoint_id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", machine: "m", label: "t-exited", closed_by: "agent", exit_code: 0},
      {endpoint_id: "cccccccccccccccccccccccccccccccc", machine: "m", label: "t-conflict", closed_by: "agent", exit_code: 1}]}}' \
    | python3 "$BRIDGE" translate > "$feed"
  run_both /dev/null compare --home "$home" --feed "$feed" --crew-state "$stub"
  assert_parity "the comparison table"
  run_both /dev/null compare --home "$home"
  assert_parity "compare without a feed source"
  run_both /dev/null compare --home "$home" --feed "$TMP_ROOT/no-such-feed" --crew-state "$stub"
  assert_parity "an unreadable feed"
  pipe_home="$TMP_ROOT/compare-pipe-home"
  mkdir -p "$pipe_home/state"
  padding=$(printf '%0180d' 0 | tr '0' 'x')
  i=0
  while [ "$i" -lt 100 ]; do
    fm_write_meta "$pipe_home/state/pipe-$i-$padding.meta" backend=stream \
      stream_endpoint_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    i=$((i + 1))
  done
  bash -c 'python3 "$1" compare --home "$2" --feed "$3" --crew-state "$4" | head -1 >/dev/null; exit ${PIPESTATUS[0]}' \
    _ "$BRIDGE" "$pipe_home" "$feed" "$stub"
  assert_equals "$?" 0 "the reference compare should end cleanly when its reader leaves"
  bash -c '"$1" compare --home "$2" --feed "$3" --crew-state "$4" | head -1 >/dev/null; exit ${PIPESTATUS[0]}' \
    _ "$RUST_BRIDGE" "$pipe_home" "$feed" "$stub"
  assert_equals "$?" 0 "the Rust compare should end cleanly when its reader leaves"
  rm -f "$home/state/t-conflict.meta" "$home/state/t-gone.meta"
  run_both /dev/null compare --home "$home" --feed "$feed" --crew-state "$stub"
  assert_parity "a passing comparison"
  pass "bridge-rust: the comparison harness answers identically"
}

test_recorded_traffic_is_byte_identical
test_refusals_match_the_reference
test_cli_surface_matches
test_a_real_hubs_listing_replays_identically
test_snapshot_parity_against_the_real_hub
test_https_and_redirect_transport_parity
test_serve_streams_ticks_and_survives_a_hub_outage
test_a_closed_reader_ends_the_feed
test_compare_harness_parity
