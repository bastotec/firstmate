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
  run_route "$parent" FM_MATE_ROUTE_SEND_BIN="$send" FM_MATE_ROUTE_MAX_TRIES=2 || fail "router pass failed"
  [ -f "$parent/state/mate-mail/pending/dave@$corr.msg" ] || fail "a first failure should stay queued"
  run_route "$parent" FM_MATE_ROUTE_SEND_BIN="$send" FM_MATE_ROUTE_MAX_TRIES=2 || fail "router pass failed"
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
  steer="$parent/steer"
  mkdir -p "$steer"
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

test_local_mate_queues_in_parent_spool
test_primary_publication_is_not_repeated
test_interrupted_bookkeeping_completes_once
test_remote_ingest_diverts_wire_line_to_spool
test_deck_wakes_idle_mate_on_peer_message
test_remote_wire_line_round_trips
test_router_delivers_tagged_without_reply_tracking
test_unknown_target_is_refused_and_bounced
test_blocked_bridge_is_refused
test_failing_delivery_retries_then_fails
test_refusals_and_idempotent_spool
test_fm_send_from_mate_needs_corr
