#!/usr/bin/env bash
# Peer messages between second mates (bin/fm-mate-mail-lib.sh).
#
# Pins, hermetically (fake stream hub, no real agent):
#   1. A local mate queues straight into the parent home's spool.
#   2. A remote mate queues one wire line on its parent channel, and the wire
#      line round-trips newlines, tabs and backslashes through the spool.
#   3. The router delivers to a mate through fm-send --from-mate: the record is
#      tagged with the sender, carries no from-firstmate mark, creates no
#      pending reply, and the first mate's log gets one delivered line.
#   4. Unknown targets and blocked bridges are refused, bounced to the sender,
#      logged, and queue a check wake; nothing is dropped silently.
#   5. A failing delivery stays queued, then fails for good after the limit.
#   6. Workers, main homes and self-sends are refused; spooling is idempotent.
#   7. fm-send --from-mate needs a fire-and-forget corr.
#   8. An idle Deck mate wakes on a peer message, with the captain-wake retry.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-mate-mail-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-operational-input.sh"

TMP_ROOT=$(fm_test_tmproot fm-mate-mail)
MATE_SEND="$ROOT/bin/fm-mate-send.sh"
ROUTE="$ROOT/bin/fm-mate-route.sh"

record_body() {  # <record-path>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1"
}

# A parent home with recorded secondmates <ids...> on the fake stream hub, and
# a local mate home for each. Prints the parent home.
make_fleet() {  # <name> <ids...>
  local parent="$TMP_ROOT/$1-$RANDOM" id fb
  shift
  mkdir -p "$parent/state" "$parent/fakebin"
  fb="$parent/fakebin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fb/sleep"; chmod +x "$fb/sleep"
  for id in "$@"; do
    mkdir -p "$parent/homes/$id/state"
    fm_test_stream_secondmate_meta "$parent/state/$id.meta" "$parent/homes/$id" alpha echo "$parent/send.log"
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" \
      > "$parent/homes/$id/.fm-secondmate-parent"
    printf '%s\n' "$id" > "$parent/homes/$id/.fm-secondmate-home"
  done
  printf '%s\n' "$parent"
}

run_route() {  # <parent> [env...]
  local parent=$1; shift
  env PATH="$parent/fakebin:$PATH" FM_ROOT_OVERRIDE="$parent" FM_HOME="$parent" \
    FM_SEND_LOG="$parent/send.log" FM_SEND_SETTLE=0 "$@" "$ROUTE" run 2>/dev/null
}

mate_send() {  # <parent> <mate> <args...>
  local parent=$1 mate=$2; shift 2
  FM_HOME="$parent/homes/$mate" FM_TASK_ID='' "$MATE_SEND" "$@"
}

test_local_mate_queues_in_parent_spool() {
  local parent out rec
  parent=$(make_fleet local dave cadia)
  out=$(mate_send "$parent" dave cadia "is the build green?") || fail "a local mate should queue"
  case "$out" in "queued: corr="[a-f0-9]*" to=cadia") ;; *) fail "unexpected queue output: $out" ;; esac
  rec=$(find "$parent/state/mate-mail/pending" -name "dave@*.msg" | head -1)
  [ -n "$rec" ] || fail "no spool record in the parent home"
  fm_mate_mail_read "$rec" || fail "spool record does not parse"
  [ "$FM_MM_FROM/$FM_MM_TO/$FM_MM_TEXT" = "dave/cadia/is the build green?" ] \
    || fail "spool fields wrong: $FM_MM_FROM/$FM_MM_TO/$FM_MM_TEXT"
  pass "fm-mate-send: a local mate queues straight into the parent home's spool"
}

test_remote_wire_line_round_trips() {
  local home="$TMP_ROOT/remote-$RANDOM" line state="$TMP_ROOT/remote-parent-$RANDOM/state" text rc
  mkdir -p "$home/state" "$state"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=mac\n' > "$home/.fm-secondmate-parent"
  printf 'dave\n' > "$home/.fm-secondmate-home"
  text=$'two\nlines\twith a \\ backslash: and colon'
  FM_HOME="$home" "$MATE_SEND" primary --reply-to 0123456789abcdef "$text" >/dev/null \
    || fail "a remote mate should queue on its parent channel"
  [ "$(wc -l < "$home/state/parent-replies.status" | tr -d ' ')" = 1 ] || fail "expected exactly one wire line"
  line=$(cat "$home/state/parent-replies.status")
  fm_mate_mail_is_line "$line" || fail "the channel line is not a wire line: $line"
  fm_mate_mail_spool_line "$state" dave "$line"; rc=$?
  expect_code 0 "$rc" "a wire line should spool"
  fm_mate_mail_spool_line "$state" dave "$line"; rc=$?
  expect_code 1 "$rc" "a replayed wire line is a duplicate"
  fm_mate_mail_read "$(ls "$state/mate-mail/pending/"dave@*.msg)" || fail "spooled wire line does not parse"
  [ "$FM_MM_TEXT" = "$text" ] || fail "text did not round-trip: $(printf '%s' "$FM_MM_TEXT" | od -c)"
  [ "$FM_MM_TO/$FM_MM_RE" = primary/0123456789abcdef ] || fail "target or re lost: $FM_MM_TO/$FM_MM_RE"
  pass "fm-mate-send: a remote mate's wire line round-trips through the spool exactly once"
}

test_router_delivers_tagged_without_reply_tracking() {
  local parent corr rec body
  parent=$(make_fleet deliver dave cadia)
  corr=$(mate_send "$parent" dave cadia "can you take the flaky test?" | sed -n 's/.*corr=\([a-f0-9]*\).*/\1/p')
  run_route "$parent" || fail "router pass failed"
  rec="$parent/state/cadia.inbox/001.msg"
  [ -f "$rec" ] || fail "no inbox record delivered to cadia"
  body=$(record_body "$rec")
  case "$body" in
    "[fm-from-mate:dave]"$'\xE2\x81\xA3'"corr=$corr "*"can you take the flaky test?") ;;
    *) fail "delivered body is not tagged from dave: $body" ;;
  esac
  case "$body" in *'bin/fm-mate-send.sh <sender> --reply-to <corr> "<text>"'*) ;;
    *) fail "secondmate reply instruction is wrong: $body" ;; esac
  case "$body" in *"$FM_FROMFIRST_LABEL"*) fail "a peer message must not carry the from-firstmate mark" ;; esac
  grep -q '^delivery=fire-and-forget$' "$rec" || fail "a peer message is fire-and-forget"
  [ -z "$(ls -A "$parent/state/pending-replies" 2>/dev/null)" ] || fail "a peer message must not create a pending reply"
  [ -f "$parent/state/mate-mail/delivered/dave@$corr.msg" ] || fail "spool record not moved to delivered/"
  grep -q "\"outcome\": \"delivered\"" "$parent/state/mate-messages.log" || fail "no delivered log line"
  grep -q "\"from\": \"dave\", \"to\": \"cadia\"" "$parent/state/mate-messages.log" || fail "log line lacks from/to"
  [ ! -s "$parent/state/.wake-queue" ] || fail "a delivered peer message must not wake the first mate"
  run_route "$parent" || fail "second router pass failed"
  [ ! -e "$parent/state/cadia.inbox/002.msg" ] || fail "a routed message must not be delivered twice"
  pass "fm-mate-route: delivers tagged, fire-and-forget, logged, with no reply tracking or wake"
}

test_router_preserves_option_shaped_text() {
  local parent corr text body expected rc
  parent=$(make_fleet option-text dave cadia)
  env PATH="$parent/fakebin:$PATH" FM_ROOT_OVERRIDE="$parent" FM_HOME="$parent" FM_SEND_LOG="$parent/send.log" \
    "$ROOT/bin/fm-send.sh" cadia --from-mate dave --fire-and-forget 0123456789abcdef --key Enter >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "an unbounded --key is still an option, not peer text"
  [ ! -e "$parent/state/cadia.inbox/001.msg" ] || fail "a refused key send must not enqueue"
  for text in "--resolve-key=build is the flag you need" "--resolve-key build" \
    "--fire-and-forget 0123456789abcdef" "--fire-and-forget=0123456789abcdef" \
    "--from-mate cadia" "--from-captain" "--correction" "--key Enter" "--"; do
    parent=$(make_fleet option-text dave cadia)
    corr=$(mate_send "$parent" dave cadia "$text" | sed -n 's/.*corr=\([a-f0-9]*\).*/\1/p')
    [ -n "$corr" ] || fail "option-shaped text must be accepted by the sender"
    run_route "$parent" >/dev/null || fail "router pass failed"
    [ -f "$parent/state/cadia.inbox/001.msg" ] || fail "option-shaped text was not delivered: $text"
    body=$(record_body "$parent/state/cadia.inbox/001.msg")
    fm_message_mark_from_mate dave "$corr" "$text" expected secondmate || fail "could not build expected carrier"
    [ "$body" = "$expected" ] || fail "option-shaped peer text was changed: $body"
    [ -f "$parent/state/mate-mail/delivered/dave@$corr.msg" ] || fail "option-shaped text was left pending"
    [ "$(fm_mate_mail_logged "$parent/state" dave "$corr")" = delivered ] || fail "option-shaped text was not logged as delivered"
    [ -z "$(ls -A "$parent/state/pending-replies" 2>/dev/null)" ] || fail "peer text must not arm a pending reply"
    [ ! -s "$parent/state/.wake-queue" ] || fail "delivered peer text must not wake the first mate"
    run_route "$parent" >/dev/null || fail "second router pass failed"
    [ ! -e "$parent/state/cadia.inbox/002.msg" ] || fail "option-shaped text was delivered twice"
  done
  pass "fm-mate-route: option-shaped peer text stays opaque through fm-send"
}

test_unknown_target_is_refused_and_bounced() {
  local parent corr body
  parent=$(make_fleet unknown dave cadia)
  corr=$(mate_send "$parent" dave nobody "hello?" | sed -n 's/.*corr=\([a-f0-9]*\).*/\1/p')
  run_route "$parent" || fail "router pass failed"
  [ -f "$parent/state/mate-mail/refused/dave@$corr.msg" ] || fail "unknown target not refused"
  body=$(record_body "$parent/state/dave.inbox/001.msg")
  case "$body" in *"corr=$corr to nobody was refused: there is no second mate named nobody"*"cadia"*) ;;
    *) fail "the sender was not told: $body" ;; esac
  grep -q "mate-mail:$corr" "$parent/state/.wake-queue" || fail "a refused message should queue a check wake"
  grep -q '"outcome": "refused"' "$parent/state/mate-messages.log" || fail "no refused log line"
  pass "fm-mate-route: an unknown target is refused, bounced, logged, and woken"
}

test_blocked_bridge_is_refused() {
  local parent corr bridge
  parent=$(make_fleet bridge dave cadia)
  printf 'remote_host=workload\n' >> "$parent/state/cadia.meta"
  bridge="$parent/fakebin/bridge"
  # shellcheck disable=SC2016 # the stub expands its own arguments
  printf '#!/usr/bin/env bash\necho "$*" >> "%s/bridge.calls"\n[ "$1" = check ] && { echo "deny: workload does not allow messages"; exit 1; }\nexit 0\n' "$parent" > "$bridge"
  chmod +x "$bridge"
  corr=$(mate_send "$parent" dave cadia "ping" | sed -n 's/.*corr=\([a-f0-9]*\).*/\1/p')
  run_route "$parent" FM_MATE_ROUTE_BRIDGE_BIN="$bridge" || fail "router pass failed"
  [ -f "$parent/state/mate-mail/refused/dave@$corr.msg" ] || fail "blocked bridge not refused"
  grep -q '^block workload messages' "$parent/bridge.calls" || fail "the refusal should record the approval request"
  grep -q 'bridge-blocked: workload does not allow messages' "$parent/state/mate-messages.log" || fail "reason not logged"
  pass "fm-mate-route: a bridge without messages refuses and asks the captain"
}

test_failing_delivery_retries_then_fails() {
  local parent corr send
  parent=$(make_fleet retry dave cadia)
  send="$parent/fakebin/send-fail"
  # shellcheck disable=SC2016 # the stub expands its own arguments
  printf '#!/usr/bin/env bash\n[ "$1" = dave ] && exit 0\necho "error: transport lost" >&2\nexit 1\n' > "$send"
  chmod +x "$send"
  corr=$(mate_send "$parent" dave cadia "ping" | sed -n 's/.*corr=\([a-f0-9]*\).*/\1/p')
  run_route "$parent" FM_MATE_ROUTE_SEND_BIN="$send" || fail "router pass failed"
  [ -f "$parent/state/mate-mail/pending/dave@$corr.msg" ] || fail "a first failure should stay queued"
  printf '9 %s\n' "$(date +%s)" > "$parent/state/mate-mail/pending/dave@$corr.tries"
  run_route "$parent" FM_MATE_ROUTE_SEND_BIN="$send" || fail "router pass failed"
  [ -f "$parent/state/mate-mail/failed/dave@$corr.msg" ] || fail "exhausted retries should fail the message"
  grep -q 'delivery kept failing (error: transport lost)' "$parent/state/mate-messages.log" || fail "failure reason not logged"
  pass "fm-mate-route: a failing delivery retries, then fails for good with the reason"
}

test_refusals_and_idempotent_spool() {
  local parent rc state="$TMP_ROOT/idem-$RANDOM"
  parent=$(make_fleet refuse dave cadia)
  mate_send "$parent" dave dave "me" >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "a mate cannot message itself"
  printf 'kind=ship\n' > "$parent/homes/dave/state/w1.meta"
  FM_HOME="$parent/homes/dave" FM_TASK_ID=w1 "$MATE_SEND" cadia "hi" >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "a worker cannot message other mates"
  FM_HOME="$parent" "$MATE_SEND" cadia "hi" >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "the main home uses fm-send"
  mkdir -p "$state"
  fm_mate_mail_spool "$state" dave cadia 0123456789abcdef '' "x"; rc=$?
  expect_code 0 "$rc" "first spool"
  fm_mate_mail_spool "$state" dave cadia 0123456789abcdef '' "x"; rc=$?
  expect_code 1 "$rc" "same sender and corr is a duplicate"
  pass "fm-mate-send: self, worker and main-home sends are refused; spooling is idempotent"
}

test_fm_send_from_mate_needs_corr() {
  local parent rc
  parent=$(make_fleet fmsend dave cadia)
  env PATH="$parent/fakebin:$PATH" FM_ROOT_OVERRIDE="$parent" FM_HOME="$parent" FM_SEND_LOG="$parent/send.log" \
    "$ROOT/bin/fm-send.sh" cadia --from-mate dave "hi" >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "--from-mate without --fire-and-forget is refused"
  [ ! -e "$parent/state/cadia.inbox/001.msg" ] || fail "a refused --from-mate send must not enqueue"
  pass "fm-send: --from-mate needs a fire-and-forget corr"
}

test_deck_wakes_idle_mate_on_peer_message() {
  local parent newest
  parent=$(make_fleet deck dave cadia)
  mate_send "$parent" dave cadia "wake up" >/dev/null
  run_route "$parent" >/dev/null || fail "router pass failed"
  newest=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from fm_stream_deck import idle_captain_sequence; print(idle_captain_sequence(sys.argv[2], "cadia", 0))' \
    "$ROOT/bin" "$parent/state")
  [ "$newest" = 1 ] || fail "an idle Deck mate should wake on a peer message (got $newest)"
  pass "fm_stream_deck: a peer message wakes an idle Deck mate like a captain message"
}

test_remote_ingest_diverts_wire_line_to_spool() {
  local parent="$TMP_ROOT/ingest-$RANDOM" payload result empty full bytes line rc
  mkdir -p "$parent/state"
  payload="$parent/payload"
  line=$(fm_mate_mail_line 0123456789abcdef cadia '' $'see data/notes.md\nthere\n\n')
  printf 'working: still on it\n%s\n' "$line" > "$payload"
  empty=$(: | shasum -a 256 | awk '{print $1}')
  full=$(shasum -a 256 < "$payload" | awk '{print $1}')
  bytes=$(LC_ALL=C wc -c < "$payload" | tr -d ' ')
  result="$parent/result"
  {
    printf 'schema=fm-remote-delta.v1\nstatus=delta\npath=state/parent-replies.status\n'
    printf 'from_offset=0\nto_offset=%s\nfrom_prefix_sha256=%s\nto_prefix_sha256=%s\n' "$bytes" "$empty" "$full"
    printf 'payload_sha256=%s\npayload_bytes=%s\nreason=\n\n' "$full" "$bytes"
    cat "$payload"
  } > "$result"
  FM_HOME="$parent" "$ROOT/bin/fm-procevent-remote-reply.sh" ingest dave "$result" >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a delta with a peer message should ingest"
  grep -q '^working: still on it$' "$parent/state/dave.status" || fail "the ordinary line was not mirrored"
  grep -q 'mate-message' "$parent/state/dave.status" && fail "a peer message must not enter the status stream"
  fm_mate_mail_read "$parent/state/mate-mail/pending/dave@0123456789abcdef.msg" || fail "the peer message was not spooled"
  [ "$FM_MM_TEXT" = $'see data/notes.md\nthere\n\n' ] || fail "spooled text wrong (trailing newlines must survive): $FM_MM_TEXT"
  [ ! -e "$parent/data/remote-secondmates" ] || fail "a peer message must not fetch documents"
  grep -q 'remote-reply-document' "$parent/state/dave.status" && fail "a peer message must not raise a document escalation"
  pass "fm-procevent-remote-reply: a remote peer message goes to the spool before any document fetch, newlines intact"
}

test_primary_publication_is_not_repeated() {
  local parent corr send steer
  parent=$(make_fleet primary dave cadia)
  python3 "$ROOT/bin/fm_primary_chat.py" prepare --home "$parent" --session A >/dev/null || fail "could not prepare primary session"
  steer="$parent/state/primary-chat/A/steer"
  printf '{"steer_dir": "%s"}\n' "$steer" > "$parent/state/primary-chat.json"
  send="$parent/fakebin/send-primary"
  # The stub publishes like the chat primary, then the pass is interrupted
  # before it can archive the record.
  # shellcheck disable=SC2016 # the stub expands its own arguments
  printf '#!/usr/bin/env bash\nn=$(ls "%s" | wc -l | tr -d " ")\nprintf "%%s" "$2" > "%s/$((n + 1)).msg"\n' "$steer" "$steer" > "$send"
  chmod +x "$send"
  corr=$(mate_send "$parent" dave primary "need a decision on X" | sed -n 's/.*corr=\([a-f0-9]*\).*/\1/p')
  : > "$parent/state/mate-mail/pending/dave@$corr.publishing"
  "$send" primary "[fm-from-mate:dave]$FM_OPERATIONAL_MARK""corr=$corr note"
  run_route "$parent" FM_MATE_ROUTE_SEND_BIN="$send" >/dev/null || fail "router pass failed"
  [ "$(find "$steer" -name '*.msg' | wc -l | tr -d ' ')" = 1 ] || fail "the first mate got the same message twice"
  [ -f "$parent/state/mate-mail/delivered/dave@$corr.msg" ] || fail "an already-published message should close as delivered"
  pass "fm-mate-route: a message already in the first mate's chat is not published again"
}

test_failed_bounces_are_retried_after_archiving() {
  local parent corr send outcome target archive marker body expected_id watcher_pid i
  for outcome in refused failed; do
    parent=$(make_fleet bounce-retry dave cadia)
    send="$parent/fakebin/send-bounce"
    cat > "$send" <<'SH'
#!/usr/bin/env bash
if [ "$1" = dave ]; then
  printf '%s\n' "$3" >> "$FM_HOME/bounce.calls"
  [ -f "$FM_HOME/accept-bounce" ] || exit 1
  exec "${FM_REAL_SEND_BIN:?}" "$@"
fi
exit 1
SH
    chmod +x "$send"
    target=nobody
    [ "$outcome" != failed ] || target=cadia
    corr=$(mate_send "$parent" dave "$target" "please answer" | sed -n 's/.*corr=\([a-f0-9]*\).*/\1/p')
    if [ "$outcome" = failed ]; then
      printf '9 %s\n' "$(date +%s)" > "$parent/state/mate-mail/pending/dave@$corr.tries"
    fi
    run_route "$parent" FM_MATE_ROUTE_SEND_BIN="$send" FM_REAL_SEND_BIN="$ROOT/bin/fm-send.sh" >/dev/null || fail "router pass failed"
    archive="$parent/state/mate-mail/$outcome/dave@$corr.msg"
    marker="${archive%.msg}.bounce"
    [ -f "$archive" ] && [ -f "$marker" ] || fail "failed bounce must remain owed beside the archive"
    [ ! -e "$parent/state/dave.inbox/001.msg" ] || fail "unavailable sender must not receive a bounce"
    mv "$archive" "$parent/state/mate-mail/pending/"
    run_route "$parent" FM_MATE_ROUTE_SEND_BIN="$send" FM_REAL_SEND_BIN="$ROOT/bin/fm-send.sh" >/dev/null || fail "logged recovery failed"
    [ -f "$archive" ] && [ -f "$marker" ] || fail "logged recovery lost the bounce obligation"
    run_route "$parent" FM_MATE_ROUTE_SEND_BIN="$send" FM_REAL_SEND_BIN="$ROOT/bin/fm-send.sh" >/dev/null || fail "offline bounce retry failed"
    [ -f "$marker" ] || fail "a bounce retry failure must keep the obligation"
    [ -z "$(ls -A "$parent/state/mate-mail/pending")" ] || fail "bounce recovery must start with an empty pending queue"
    : > "$parent/accept-bounce"
    touch "$parent/state/.last-secondmate-revive" "$parent/state/.last-idle-sweep" "$parent/state/home-summary.json"
    env FM_ROOT_OVERRIDE="$parent" FM_HOME="$parent" FM_STATE_OVERRIDE="$parent/state" \
      FM_MATE_ROUTE_SEND_BIN="$send" FM_REAL_SEND_BIN="$ROOT/bin/fm-send.sh" \
      FM_SEND_LOG="$parent/send.log" FM_SEND_SETTLE=0 FM_WATCH_HANDLING_SUCCESSOR=1 \
      FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$ROOT/bin/fm-watch.sh" > "$parent/watch.out" 2>&1 &
    watcher_pid=$!
    fm_test_track_helper_pid "$watcher_pid"
    i=0
    while [ "$i" -lt 200 ]; do
      [ ! -e "$marker" ] && [ -f "$parent/state/dave.inbox/001.msg" ] && break
      sleep 0.1
      i=$((i + 1))
    done
    kill "$watcher_pid" 2>/dev/null || true
    wait "$watcher_pid" 2>/dev/null || true
    [ ! -e "$marker" ] || fail "watcher must retry an owed bounce with empty pending/: $(cat "$parent/watch.out")"
    body=$(record_body "$parent/state/dave.inbox/001.msg")
    case "$body" in *"corr=$corr to $target was $outcome:"*) ;; *) fail "wrong recovered bounce: $body" ;; esac
    expected_id=$(printf 'bounce:%s' "$corr" | shasum -a 256 | cut -c1-16)
    [ "$(sort -u "$parent/bounce.calls")" = "$expected_id" ] || fail "bounce retries must preserve delivery id"
    run_route "$parent" FM_MATE_ROUTE_SEND_BIN="$send" FM_REAL_SEND_BIN="$ROOT/bin/fm-send.sh" >/dev/null || fail "final router pass failed"
    [ "$(wc -l < "$parent/bounce.calls" | tr -d ' ')" = 3 ] || fail "settled bounce should not be retried"
    [ ! -e "$parent/state/dave.inbox/002.msg" ] || fail "bounce must be delivered once"
    [ "$(grep -c "\"corr\": \"$corr\"" "$parent/state/mate-messages.log")" = 1 ] || fail "bounce retry duplicated the log"
    [ "$(grep -c "mate-mail:$corr" "$parent/state/.wake-queue")" = 1 ] || fail "bounce retry duplicated the wake"
  done
  pass "fm-mate-route: archived bounces survive logged recovery and retry through the watcher with empty pending/"
}

test_primary_session_change_retains_publication_evidence() {
  local parent corr send old_steer new_steer sub body
  for sub in pending handled rejected; do
    parent=$(make_fleet primary-session dave cadia)
    send="$parent/fakebin/send-primary"
    cat > "$send" <<'SH'
#!/usr/bin/env bash
python3 - "${FM_TEST_BIN_DIR:?}" "$FM_HOME" "$2" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from fm_primary_chat import publish_body, read_record
publish_body(Path(read_record(sys.argv[2])['steer_dir']), sys.argv[3])
PY
SH
    chmod +x "$send"
    python3 "$ROOT/bin/fm_primary_chat.py" prepare --home "$parent" --session A >/dev/null || fail "could not prepare session A"
    python3 "$ROOT/bin/fm_primary_chat.py" record write --home "$parent" --session A --host-pid "$$" || fail "could not record session A"
    old_steer="$parent/state/primary-chat/A/steer"
    corr=$(mate_send "$parent" dave primary "help with the dependency" | sed -n 's/.*corr=\([a-f0-9]*\).*/\1/p')
    mkdir "$parent/state/mate-messages.log"
    run_route "$parent" FM_MATE_ROUTE_SEND_BIN="$send" FM_TEST_BIN_DIR="$ROOT/bin" >/dev/null || fail "publication pass failed"
    [ -f "$old_steer/1.msg" ] || fail "message was not published in session A"
    body=$(cat "$old_steer/1.msg")
    case "$body" in *'bin/fm-send.sh <sender> "<text>"'*) ;; *) fail "primary reply instruction is wrong: $body" ;; esac
    case "$body" in *'bin/fm-mate-send.sh'*) fail "primary must not be told to use the secondmate send command" ;; esac
    [ -f "$parent/state/mate-mail/pending/dave@$corr.msg" ] || fail "logging failure must leave publication pending"
    if [ "$sub" != pending ]; then
      mkdir "$old_steer/$sub"
      mv "$old_steer/1.msg" "$old_steer/$sub/"
    fi
    python3 "$ROOT/bin/fm_primary_chat.py" prepare --home "$parent" --session B >/dev/null || fail "could not prepare session B"
    python3 "$ROOT/bin/fm_primary_chat.py" record write --home "$parent" --session B --host-pid "$$" || fail "could not record session B"
    new_steer="$parent/state/primary-chat/B/steer"
    rmdir "$parent/state/mate-messages.log"
    run_route "$parent" FM_MATE_ROUTE_SEND_BIN="$send" FM_TEST_BIN_DIR="$ROOT/bin" >/dev/null || fail "publication recovery failed"
    [ ! -e "$new_steer/1.msg" ] || fail "session change duplicated publication from $sub"
    [ "$(find "$parent/state/primary-chat" -name '*.msg' | wc -l | tr -d ' ')" = 1 ] || fail "session change must retain exactly one publication"
    [ -f "$parent/state/mate-mail/delivered/dave@$corr.msg" ] || fail "prior publication was not archived"
    [ "$(fm_mate_mail_logged "$parent/state" dave "$corr")" = delivered ] || fail "prior publication was not logged"
  done
  pass "fm-mate-route: retained sessions prevent duplicate primary publication and carry primary reply instructions"
}

test_interrupted_bookkeeping_completes_once() {
  local parent corr
  parent=$(make_fleet resume dave cadia)
  corr=$(mate_send "$parent" dave nobody "x" | sed -n 's/.*corr=\([a-f0-9]*\).*/\1/p')
  run_route "$parent" >/dev/null || fail "router pass failed"
  # Simulate a pass that logged and woke, then died before archiving.
  mv "$parent/state/mate-mail/refused/dave@$corr.msg" "$parent/state/mate-mail/pending/"
  run_route "$parent" >/dev/null || fail "router pass failed"
  [ -f "$parent/state/mate-mail/refused/dave@$corr.msg" ] || fail "the record should be archived under its logged outcome"
  [ "$(grep -c "\"corr\": \"$corr\"" "$parent/state/mate-messages.log")" = 1 ] || fail "the message was logged twice"
  [ "$(grep -c "mate-mail:$corr" "$parent/state/.wake-queue")" = 1 ] || fail "the first mate was woken twice"
  pass "fm-mate-route: an interrupted pass finishes its bookkeeping without repeating it"
}

test_wake_survives_failed_logging_and_queue_consumption() {
  local parent corr send record target outcome marker
  for target in nobody primary; do
    parent=$(make_fleet wake-resume dave cadia)
    send="$parent/fakebin/send-no-primary"
    printf '#!/usr/bin/env bash\nexit 3\n' > "$send"
    chmod +x "$send"
    corr=$(mate_send "$parent" dave "$target" "remember this" | sed -n 's/.*corr=\([a-f0-9]*\).*/\1/p')
    record="$parent/state/mate-mail/pending/dave@$corr.msg"
    marker="${record%.msg}.woken-undelivered"
    [ "$target" != primary ] || marker="${record%.msg}.woken-delivered"
    mkdir "$parent/state/mate-messages.log"
    run_route "$parent" FM_MATE_ROUTE_SEND_BIN="$send" >/dev/null || fail "router pass failed"
    [ -f "$record" ] || fail "logging failure must keep the message pending"
    [ -f "$marker" ] || fail "successful wake needs a durable marker"
    [ "$(grep -c "mate-mail:$corr" "$parent/state/.wake-queue")" = 1 ] || fail "expected one wake before logging"
    rm "$marker"
    run_route "$parent" FM_MATE_ROUTE_SEND_BIN="$send" >/dev/null || fail "router pass failed"
    [ -f "$marker" ] || fail "a queued wake must recover its marker"
    [ "$(grep -c "mate-mail:$corr" "$parent/state/.wake-queue")" = 1 ] || fail "queued wake was repeated"
    : > "$parent/state/.wake-queue"
    rmdir "$parent/state/mate-messages.log"
    run_route "$parent" FM_MATE_ROUTE_SEND_BIN="$send" >/dev/null || fail "router pass failed"
    [ ! -s "$parent/state/.wake-queue" ] || fail "an already-consumed wake was repeated"
    [ "$(cat "$parent/state/.wake-queue.seq")" = 1 ] || fail "retry allocated another wake sequence"
    [ ! -e "$marker" ] || fail "terminalization must remove the wake marker"
    outcome=refused
    [ "$target" != primary ] || outcome=delivered
    [ -f "$parent/state/mate-mail/$outcome/dave@$corr.msg" ] || fail "record was not archived after logging recovered"
    [ "$(fm_mate_mail_logged "$parent/state" dave "$corr")" = "$outcome" ] || fail "terminal outcome not logged"
  done
  pass "fm-mate-route: refused and primary wakes survive logging failure without duplication"
}

test_failed_primary_bookkeeping_never_becomes_delivery() {
  local parent corr send record body pass_number
  parent=$(make_fleet failed-primary dave cadia)
  send="$parent/fakebin/send-primary-fail"
  cat > "$send" <<'SH'
#!/usr/bin/env bash
if [ "$1" = primary ] || [ "$1" = supervisor ]; then
  printf 'attempt\n' >> "$FM_HOME/primary.calls"
  if [ -f "$FM_HOME/accept-primary" ]; then
    printf '%s' "$2" > "$FM_HOME/primary.published"
    exit 0
  fi
  exit 1
fi
exec "${FM_REAL_SEND_BIN:?}" "$@"
SH
  chmod +x "$send"
  corr=$(mate_send "$parent" dave primary "the primary never received this" | sed -n 's/.*corr=\([a-f0-9]*\).*/\1/p')
  record="$parent/state/mate-mail/pending/dave@$corr.msg"
  mkdir "$parent/state/mate-messages.log"
  for pass_number in 1 2 3 4 5 6 7 8 9 10; do
    run_route "$parent" FM_MATE_ROUTE_SEND_BIN="$send" FM_REAL_SEND_BIN="$ROOT/bin/fm-send.sh" >/dev/null \
      || fail "router pass $pass_number failed"
  done
  [ -f "$record" ] || fail "failed logging must leave the message pending"
  [ -f "${record%.msg}.woken-undelivered" ] || fail "failure notification must have its own wake marker"
  [ ! -e "${record%.msg}.woken-delivered" ] || fail "failure notification is not delivery"
  body=$(record_body "$parent/state/dave.inbox/001.msg")
  case "$body" in *"corr=$corr to primary was failed: delivery kept failing"*) ;; *) fail "failure was not bounced: $body" ;; esac
  [ "$(grep -c "mate-mail:$corr" "$parent/state/.wake-queue")" = 1 ] || fail "failure must queue one notification"
  rmdir "$parent/state/mate-messages.log"
  : > "$parent/accept-primary"
  run_route "$parent" FM_MATE_ROUTE_SEND_BIN="$send" FM_REAL_SEND_BIN="$ROOT/bin/fm-send.sh" >/dev/null \
    || fail "router recovery pass failed"
  [ -f "$parent/state/mate-mail/failed/dave@$corr.msg" ] || fail "failure must remain failed after logging recovers"
  [ ! -e "$parent/state/mate-mail/delivered/dave@$corr.msg" ] || fail "failure must not be archived as delivery"
  [ "$(fm_mate_mail_logged "$parent/state" dave "$corr")" = failed ] || fail "failure outcome must be preserved"
  [ "$(wc -l < "$parent/primary.calls" | tr -d ' ')" = 10 ] || fail "terminal failure must not retry primary publication"
  [ ! -e "$parent/primary.published" ] || fail "terminal bookkeeping must not publish a failed message"
  [ ! -e "$parent/state/dave.inbox/002.msg" ] || fail "failure bounce must not be repeated"
  [ "$(grep -c "mate-mail:$corr" "$parent/state/.wake-queue")" = 1 ] || fail "failure notification must not be repeated"
  [ ! -e "${record%.msg}.woken-undelivered" ] || fail "archiving must remove the failure wake marker"
  [ ! -e "${record%.msg}.undelivered" ] || fail "archiving must remove unfinished terminal bookkeeping"
  python3 - "$parent/state/mate-messages.log" "$corr" <<'PY' || fail "failure oversight record was not preserved"
import json, sys
with open(sys.argv[1]) as log:
    rows = [json.loads(line) for line in log]
assert len(rows) == 1
assert rows[0]["corr"] == sys.argv[2]
assert rows[0]["outcome"] == "failed"
assert rows[0]["reason"] == "delivery kept failing (the first mate's chat did not accept it)"
assert rows[0]["text"] == "the primary never received this"
PY
  pass "fm-mate-route: interrupted primary failure stays failed without retrying publication"
}

test_split_home_keeps_a_peer_message_for_a_restarting_conversation() {
  local parent corr send record
  parent=$(make_fleet split-primary dave cadia)
  mkdir -p "$parent/config"; : > "$parent/config/primary-split"
  send="$parent/fakebin/send-primary-down"
  cat > "$send" <<'SH'
#!/usr/bin/env bash
if [ "$1" = primary ]; then
  printf 'attempt\n' >> "$FM_HOME/primary.calls"
  [ -f "$FM_HOME/conversation-up" ] || exit 3
  printf '%s' "$2" > "$FM_HOME/primary.published"
  exit 0
fi
exec "${FM_REAL_SEND_BIN:?}" "$@"
SH
  chmod +x "$send"
  corr=$(mate_send "$parent" dave primary "for the conversation" | sed -n 's/.*corr=\([a-f0-9]*\).*/\1/p')
  record="$parent/state/mate-mail/pending/dave@$corr.msg"
  run_route "$parent" FM_MATE_ROUTE_SEND_BIN="$send" FM_REAL_SEND_BIN="$ROOT/bin/fm-send.sh" >/dev/null \
    || fail "router pass failed"
  [ -f "$record" ] || fail "a message for a restarting conversation must stay pending"
  [ ! -e "${record%.msg}.woken-delivered" ] || fail "it must not be flattened into a supervisor wake"
  : > "$parent/conversation-up"
  run_route "$parent" FM_MATE_ROUTE_SEND_BIN="$send" FM_REAL_SEND_BIN="$ROOT/bin/fm-send.sh" >/dev/null \
    || fail "router recovery pass failed"
  assert_contains "$(cat "$parent/primary.published")" "for the conversation" "the conversation gets the message once it is back"
  pass "fm-mate-route: a split home keeps a peer message for its restarting conversation"
}

test_incomplete_log_does_not_finish_bookkeeping() {
  local parent corr record
  parent=$(make_fleet partial-log dave cadia)
  corr=$(mate_send "$parent" dave nobody "the full oversight copy" | sed -n 's/.*corr=\([a-f0-9]*\).*/\1/p')
  printf '{"from": "dave", "corr": "%s", "text": "partial' "$corr" > "$parent/state/mate-messages.log"
  fm_mate_mail_logged "$parent/state" dave "$corr" >/dev/null && fail "a partial JSON append is not a completed record"
  run_route "$parent" >/dev/null || fail "router pass failed"
  [ -f "$parent/state/mate-mail/refused/dave@$corr.msg" ] || fail "a partial log must not turn refusal into delivery"
  [ -f "$parent/state/dave.inbox/001.msg" ] || fail "partial logging must not skip the bounce"
  [ "$(grep -c "mate-mail:$corr" "$parent/state/.wake-queue")" = 1 ] || fail "partial logging must not skip the wake"
  [ "$(fm_mate_mail_logged "$parent/state" dave "$corr")" = refused ] || fail "complete refusal was not logged"
  python3 - "$parent/state/mate-messages.log" "$corr" <<'PY' || fail "oversight record must start on a fresh line"
import json, sys
with open(sys.argv[1]) as log:
    lines = log.readlines()
assert len(lines) == 2
row = json.loads(lines[1])
assert row["corr"] == sys.argv[2]
assert row["outcome"] == "refused"
assert row["text"] == "the full oversight copy"
PY
  record="$parent/state/mate-mail/refused/dave@$corr.msg"
  mv "$record" "$parent/state/mate-mail/pending/"
  run_route "$parent" >/dev/null || fail "router pass failed"
  [ "$(wc -l < "$parent/state/mate-messages.log" | tr -d ' ')" = 2 ] || fail "recovered log was appended twice"
  pass "fm-mate-route: truncated log tails neither finish bookkeeping nor corrupt the retry"
}

test_logged_requires_complete_json_record() {
  local parent corr=0123456789abcdef
  parent=$(make_fleet log-contract dave cadia)
  printf '{"from":"dave","corr":"%s","outcome":"delivered"}\n' "$corr" > "$parent/state/mate-messages.log"
  fm_mate_mail_logged "$parent/state" dave "$corr" >/dev/null && fail "missing oversight fields cannot finish bookkeeping"
  fm_mate_mail_spool "$parent/state" dave cadia "$corr" '' "complete text" || fail "could not spool"
  fm_mate_mail_read "$parent/state/mate-mail/pending/dave@$corr.msg" || fail "could not read spool"
  fm_mate_mail_log "$parent/state" failed "transport lost" || fail "could not log"
  [ "$(fm_mate_mail_logged "$parent/state" dave "$corr")" = failed ] || fail "logger must return the valid outcome"
  fm_mate_mail_logged "$parent/state" cadia "$corr" >/dev/null && fail "log matching must include the sender"
  pass "fm-mate-mail: only complete valid oversight records return their outcome"
}

test_live_router_lock_is_not_stolen() {
  local parent corr lock dead_pid
  parent=$(make_fleet lock dave cadia)
  corr=$(mate_send "$parent" dave cadia "wait for the active router" | sed -n 's/.*corr=\([a-f0-9]*\).*/\1/p')
  lock="$parent/state/mate-mail/.route.lock"
  mkdir "$lock"
  printf '%s\n' "$$" > "$lock/pid"
  touch -t 200001010000 "$lock"
  run_route "$parent" >/dev/null || fail "a busy router should skip its pass"
  [ "$(cat "$lock/pid")" = "$$" ] || fail "live lock owner was replaced"
  [ ! -e "$parent/state/cadia.inbox/001.msg" ] || fail "busy router must not deliver"
  [ -f "$parent/state/mate-mail/pending/dave@$corr.msg" ] || fail "busy router must leave the message queued"
  bash -c 'exit 0' &
  dead_pid=$!
  wait "$dead_pid"
  printf '%s\n' "$dead_pid" > "$lock/pid"
  run_route "$parent" >/dev/null || fail "a dead router lock should be recovered"
  [ -f "$parent/state/cadia.inbox/001.msg" ] || fail "dead-owner recovery must deliver"
  [ ! -e "$lock" ] || fail "router must release its own lock"
  pass "fm-mate-route: old live locks stay held, dead locks are recovered"
}

# A registry line and a published home summary for local mate <id> in <parent>.
seed_report_home() {  # <parent> <id> <shipped-date>
  local parent=$1 id=$2 date=$3 home="$1/homes/$2"
  mkdir -p "$parent/data"
  printf -- '- %s - charter (home: %s; scope: %s things; projects: ; added 2026-10-01)\n' "$id" "$home" "$id" \
    >> "$parent/data/secondmates.md"
  python3 - "$home" "$date" "$id" > "$home/state/home-summary.json" <<'PY'
import json, sys, time
home, date, mid = sys.argv[1:]
w = mid + "-w1"
print(json.dumps({"schema": "fm-secondmate-home-summary.v1", "home": home, "generated": "2026-10-13T00:00:00Z",
  "generated_epoch": int(time.time()), "valid": True,
  "active_children": [{"id": w, "kind": "ship", "state": "working", "name": "Fix the flaky test", "doing": "running tests"}],
  "endpoints": [{"id": w, "state": "working"}, {"id": mid + "-w2", "state": "parked"}, {"id": mid + "-w3", "state": "paused"}],
  "decisions_open": [{"id": mid + "-w2", "key": "api", "verb": "needs-decision", "summary": "Which API shape?", "source": "status"},
                     {"id": mid + "-w2", "key": "db", "verb": "needs-decision", "summary": "Which database?", "source": "status"},
                     {"id": "c1", "key": "c1", "verb": "captain-hold", "summary": "Approve the launch", "source": "backlog"}],
  "holds": [{"id": "h1", "title": "Ship the release", "blocked_by": "w9", "source": "backlog"},
            {"id": mid + "-w2", "title": "Ask about the API", "blocked_by": None, "source": "child-state", "reason": "parked"},
            {"id": mid + "-w3", "title": "Wait for CI", "blocked_by": None, "source": "child-state", "reason": "CI until 18:00Z"}],
  "queued": [{"id": "h1", "title": "Ship the release", "since": "2026-10-12"}],
  "landed": [{"id": "l1", "title": "Adds the cache", "kind": "ship", "pr_url": "https://example.test/pull/7",
              "outcome": "merged", "completion": {"verb": "merged", "date": date}}],
  "omitted": [], "counts": {}, "crew_time": {"since": 1, "intervals": [[w, 1, 2]]}}))
PY
}

test_crew_time_survives_teardown() {
  local state="$TMP_ROOT/crew-$RANDOM" out
  mkdir -p "$state"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" w1 >/dev/null || fail "arm failed"
  "$ROOT/bin/fm-busy-event.sh" apply "$state" w1 idle --current-gen --source deck-wrapper --event turn-end || fail "apply failed"
  "$ROOT/bin/fm-busy-event.sh" retire "$state" w1 --current-gen || fail "retire failed"
  [ "$(cut -f2,3 "$state/crew-time.log" | tr '\t\n' ': ')" = "w1:busy w1:idle w1:retired " ] \
    || fail "crew-time history wrong: $(cat "$state/crew-time.log")"
  printf '100\tw2\tbusy\n130\tw2\tidle\n150\tw2\tbusy\n400\tw2\tretired\n' > "$state/crew-time.log"
  out=$(python3 -c 'import sys,json; sys.path.insert(0, sys.argv[1]); import fm_report as r; print(json.dumps(r.crew_time(sys.argv[2], 1, now=500)["intervals"]))' \
    "$ROOT/bin" "$state")
  [ "$out" = '[["w2", 100, 130], ["w2", 150, 400]]' ] || fail "busy time counts only busy spells and closes at retirement: $out"
  printf '100\tw3\tbusy\n200\tw3\tidle\n200\tw3\tbusy\n' > "$state/crew-time.log"
  out=$(python3 -c 'import sys,json; sys.path.insert(0, sys.argv[1]); import fm_report as r; print(json.dumps(r.crew_time(sys.argv[2], 1, now=300)["intervals"]))' \
    "$ROOT/bin" "$state")
  [ "$out" = '[["w3", 100, 300]]' ] || fail "same-second events must keep their writer order: $out"
  pass "crew time: busy-state events leave a history that outlives the worker"
}

test_report_reads_local_mates_without_their_turns() {
  local parent today json rc
  parent=$(make_fleet report dave cadia)
  today=$(date +%Y-%m-%d)
  seed_report_home "$parent" dave "$today"
  seed_report_home "$parent" cadia 2020-01-01
  json=$(FM_HOME="$parent" "$ROOT/bin/fm-report.sh" dave --json) || fail "a main home should report a local mate"
  printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["schema"] == "fm-report.v1" and d["scope"] == "dave" and d["days"] == 1, d
assert [s["pr"] for s in d["shipped"]] == ["https://example.test/pull/7"], d["shipped"]
assert d["crew"][0]["task"] == "Fix the flaky test", d["crew"]
assert sorted((x["task"], x["what"]) for x in d["waiting"]) == [("c1", "Approve the launch"), ("dave-w2", "Which API shape?"), ("dave-w2", "Which database?"), ("dave-w3", "Wait for CI"), ("h1", "Ship the release")], d["waiting"]
w = {x["task"]: x for x in d["waiting"]}
assert w["c1"]["on"] == "the captain" and w["dave-w2"]["on"] == "dave" and w["h1"]["on"] == "w9", w
assert w["dave-w3"]["on"] == "an external wait: CI until 18:00Z", w["dave-w3"]
assert w["h1"]["since"] == "2026-10-12", w["h1"]
assert [(c["agent"], c["status"]) for c in d["crew"]] == [("dave-w1", "working"), ("dave-w2", "parked"), ("dave-w3", "paused")], d["crew"]
assert "1 working now" in d["headline"], d["headline"]
' || fail "report JSON shape wrong: $json"
  FM_HOME="$parent/homes/cadia" "$ROOT/bin/fm-report.sh" dave | grep -q 'Adds the cache' \
    || fail "a local mate should read a peer's report through the main home's records"
  FM_HOME="$parent" "$ROOT/bin/fm-report.sh" cadia --days 7 --json | grep -q '"shipped": \[\]' \
    || fail "work landed before the window must not count"
  FM_HOME="$parent" "$ROOT/bin/fm-report.sh" nobody >/dev/null 2>&1; rc=$?
  expect_code 1 "$rc" "an unknown mate is refused"
  [ ! -e "$parent/homes/dave/state/dave-w1.inbox" ] && [ -z "$(ls "$parent/state/"*.inbox 2>/dev/null)" ] \
    || fail "reading a report must not message anyone"
  python3 - "$parent/homes/dave/state/home-summary.json" <<'PY'
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d.update(valid=False, reason="in-flight backlog item has no child metadata: x",
         invalidity={"kind": "orphan_in_flight", "ids": ["x"]}, unknown_children=["dave-w9"])
json.dump(d, open(p, "w"))
PY
  FM_HOME="$parent" "$ROOT/bin/fm-report.sh" dave --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert any("child current state unavailable: dave-w9" in g for g in d["gaps"]), d["gaps"]
assert any("no child metadata" in x for x in d["inconsistencies"]), d["inconsistencies"]
' || fail "an unreadable child hid behind a disagreement"
  pass "fm-report: a mate's report comes from records, read-only, from the main or a local mate home"
}

test_report_keeps_independent_waits_and_names_bad_crew_time() {
  local parent json empty
  parent=$(make_fleet report-gaps dave cadia)
  seed_report_home "$parent" dave "$(date +%Y-%m-%d)"
  seed_report_home "$parent" cadia "$(date +%Y-%m-%d)"
  python3 - "$parent/homes/dave/state/home-summary.json" "$parent/homes/cadia/state/home-summary.json" <<'PY'
import json, sys
dave, cadia = sys.argv[1:]
d = json.load(open(dave))
d["decisions_open"] += [{"id": "dave-w3", "key": "ci", "verb": "needs-decision", "summary": "Retry CI?", "source": "status"},
                        {"id": "h1", "key": "h1", "verb": "captain-hold", "summary": "Approve the release", "source": "backlog"},
                        {"id": "dave-w4", "key": "ci", "verb": "needs-decision", "summary": "Retry omitted worker CI?", "source": "status"}]
d["holds"] += [{"id": "dave-w4", "title": "Wait for omitted worker CI", "blocked_by": None, "source": "child-state", "reason": "CI until 18:00Z"}]
json.dump(d, open(dave, "w"))
c = json.load(open(cadia))
c["crew_time"]["intervals"] = [["cadia-w1", 100]]
json.dump(c, open(cadia, "w"))
PY
  json=$(FM_HOME="$parent" "$ROOT/bin/fm-report.sh" dave --json) || fail "report with an open decision on a paused worker failed"
  printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
w = sorted((x["task"], x["what"], x["on"]) for x in d["waiting"])
assert ("dave-w3", "Retry CI?", "dave") in w and ("dave-w3", "Wait for CI", "an external wait: CI until 18:00Z") in w, w
assert ("h1", "Approve the release", "the captain") in w and ("h1", "Ship the release", "w9") in w, w
assert [x for x in w if x[0] == "dave-w4"] == [("dave-w4", "Retry omitted worker CI?", "dave"), ("dave-w4", "Wait for omitted worker CI", "dave")], w
assert not any(c["agent"] == "dave-w4" for c in d["crew"]), d["crew"]
assert [x for x in w if x[0] == "dave-w2"] == [("dave-w2", "Which API shape?", "dave"), ("dave-w2", "Which database?", "dave")], w
' || fail "an open decision must not hide an independent pause or dependency: $json"
  json=$(FM_HOME="$parent" "$ROOT/bin/fm-report.sh" cadia --json) || fail "a malformed crew_time must not abort the report"
  printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert any(g.startswith("cadia: ") for g in d["gaps"]) and d["crew_seconds"] == 0, d["gaps"]
' || fail "a malformed crew_time should name its home in gaps: $json"
  cp "$parent/homes/dave/state/home-summary.json" "$parent/state/home-summary.json"
  mkdir "$parent/state/crew-time.log"
  json=$(FM_HOME="$parent" "$ROOT/bin/fm-report.sh" primary --json) || fail "an unreadable crew log must not abort the report"
  printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert any(g.startswith("first mate: crew time unreadable (state/crew-time.log could not be read") for g in d["gaps"]), d["gaps"]
' || fail "an unreadable crew log should be named in gaps: $json"
  python3 "$ROOT/bin/fm_report.py" crew-time "$parent/state" | grep -q '"error": "state/crew-time.log could not be read' \
    || fail "published crew time should carry the unreadable log"
  empty="$TMP_ROOT/crew-empty-$RANDOM"
  mkdir -p "$empty"
  [ "$(python3 "$ROOT/bin/fm_report.py" crew-time "$empty")" = '{"since": null, "intervals": []}' ] \
    || fail "an absent crew log is an empty history"
  pass "fm-report: open decisions keep independent waits, and bad crew time is a named gap"
}

test_fleet_report_reads_power() {
  local parent json
  parent=$(make_fleet fleet dave)
  seed_report_home "$parent" dave "$(date +%Y-%m-%d)"
  mkdir -p "$parent/config"
  printf '{"version": 1, "bridges": {"workload": {"allow": ["reports", "maintenance"], "seeded": false}}}\n' \
    > "$parent/config/bridges.json"
  # The real quota command over a fake ssh transport.
  cat > "$parent/fakebin/ssh" <<'SH'
#!/usr/bin/env bash
case "$*" in *"proxai quotas"*) ;; *) exit 99 ;; esac
printf 'proxai quotas\n\nACCOUNT  STATE  USED  WINDOW  RESETS\nzai\n  personal  OK         77%%  weekly (1/2 credits)                      Oct 14 02:25Z\n'
SH
  chmod +x "$parent/fakebin/ssh"
  json=$(PATH="$parent/fakebin:$PATH" FM_HOME="$parent" "$ROOT/bin/fm-report.sh" fleet --json) \
    || fail "fleet report failed"
  printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["power"] == [{"provider": "zai", "pct_left": 23, "refills_at": "Oct 14 02:25Z", "tightest": "personal weekly (1/2 credits)"}], d["power"]
assert [m["id"] for m in d["mates"]] == ["primary", "dave"], d["mates"]
assert d["mates"][1]["working"] == 1 and d["mates"][1]["crew"] == 3, d["mates"][1]
assert "Tightest power: zai at 23%" in d["summary"], d["summary"]
' || fail "fleet report shape wrong: $json"
  printf '{"version": 1, "bridges": {"workload": {"allow": ["reports"], "seeded": false}}}\n' \
    > "$parent/config/bridges.json"
  PATH="$parent/fakebin:$PATH" FM_HOME="$parent" "$ROOT/bin/fm-report.sh" fleet --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["power"] == [] and "does not allow maintenance" in d["power_error"], (d["power"], d["power_error"])
' || fail "a bridge without maintenance must block the quota read"
  pass "fm-report: the fleet report adds each mate and the power left per provider, behind the bridge"
}

test_remote_report_request_is_answered_in_code() {
  local parent home corr body
  parent=$(make_fleet answer dave)
  seed_report_home "$parent" dave "$(date +%Y-%m-%d)"
  home="$TMP_ROOT/remote-report-$RANDOM"
  mkdir -p "$home/state"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=mac\n' > "$home/.fm-secondmate-parent"
  printf 'dave\n' > "$home/.fm-secondmate-home"
  FM_HOME="$home" "$ROOT/bin/fm-report.sh" dave --days 7 | grep -q '^requested: corr=' \
    || fail "a remote home should queue a report request"
  fm_mate_mail_spool_line "$parent/state" dave "$(cat "$home/state/parent-replies.status")" \
    || fail "the request should spool like a peer message"
  corr=$(sed -n 's/.*corr=\([a-f0-9]\{16\}\).*/\1/p' "$home/state/parent-replies.status")
  run_route "$parent" >/dev/null || fail "router pass failed"
  body=$(record_body "$parent/state/dave.inbox/001.msg")
  case "$body" in *"The report you asked for (corr=$corr)"*"Adds the cache"*) ;;
    *) fail "the report should come back to the requester: $body" ;; esac
  grep -q '"reason": "answered"' "$parent/state/mate-messages.log" || fail "the answer should be logged"
  [ ! -s "$parent/state/.wake-queue" ] || fail "an answered request must not wake the first mate"
  pass "fm-mate-route: a remote mate's report request is answered from records, with no model turn"
}

test_report_answer_is_resent_unchanged_and_failures_explain() {
  local parent send corr
  parent=$(make_fleet answer2 dave)
  seed_report_home "$parent" dave "$(date +%Y-%m-%d)"
  send="$parent/fakebin/send-capture"
  # shellcheck disable=SC2016 # the stub expands its own arguments
  printf '#!/usr/bin/env bash\nprintf "%%s\\n--end--\\n" "${!#}" >> "%s/answers"\n[ -e "%s/ok" ] || { echo "error: transport lost" >&2; exit 1; }\n' "$parent" "$parent" > "$send"
  chmod +x "$send"
  fm_mate_mail_spool "$parent/state" dave primary 1111111111111111 '' "fm-request report scope=dave days=1" || fail "spool failed"
  run_route "$parent" FM_MATE_ROUTE_SEND_BIN="$send" >/dev/null || fail "router pass failed"
  sleep 1
  touch "$parent/ok"
  run_route "$parent" FM_MATE_ROUTE_SEND_BIN="$send" >/dev/null || fail "router pass failed"
  python3 - "$parent/answers" <<'PY' || fail "a retried answer must be byte-identical to the first"
import sys
parts = [p for p in open(sys.argv[1]).read().split("\n--end--\n") if p]
assert len(parts) == 2 and parts[0] == parts[1], len(parts)
PY
  fm_mate_mail_spool "$parent/state" dave primary 2222222222222222 '' "fm-request report scope=nobody days=1" || fail "spool failed"
  printf '9 %s\n' "$(date +%s)" > "$parent/state/mate-mail/pending/dave@2222222222222222.tries"
  run_route "$parent" FM_MATE_ROUTE_SEND_BIN="$send" >/dev/null || fail "router pass failed"
  corr=2222222222222222
  grep "\"corr\": \"$corr\"" "$parent/state/mate-messages.log" | grep -q "no second mate named" \
    || fail "a failed report request should carry the generator's reason: $(cat "$parent/state/mate-messages.log")"
  pass "fm-mate-route: a report answer is resent unchanged, and a failed one says why"
}

test_local_mate_queues_in_parent_spool
test_crew_time_survives_teardown
test_report_reads_local_mates_without_their_turns
test_report_keeps_independent_waits_and_names_bad_crew_time
test_fleet_report_reads_power
test_remote_report_request_is_answered_in_code
test_report_answer_is_resent_unchanged_and_failures_explain
test_failed_bounces_are_retried_after_archiving
test_primary_session_change_retains_publication_evidence
test_wake_survives_failed_logging_and_queue_consumption
test_failed_primary_bookkeeping_never_becomes_delivery
test_split_home_keeps_a_peer_message_for_a_restarting_conversation
test_incomplete_log_does_not_finish_bookkeeping
test_logged_requires_complete_json_record
test_live_router_lock_is_not_stolen
test_primary_publication_is_not_repeated
test_interrupted_bookkeeping_completes_once
test_remote_ingest_diverts_wire_line_to_spool
test_deck_wakes_idle_mate_on_peer_message
test_remote_wire_line_round_trips
test_router_delivers_tagged_without_reply_tracking
test_router_preserves_option_shaped_text
test_unknown_target_is_refused_and_bounced
test_blocked_bridge_is_refused
test_failing_delivery_retries_then_fails
test_refusals_and_idempotent_spool
test_fm_send_from_mate_needs_corr
