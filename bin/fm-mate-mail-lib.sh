#!/usr/bin/env bash
# fm-mate-mail-lib.sh - peer messages between second mates, routed by the first mate.
#
# WHY. The captain's rule (2026-10-13): any second mate may message any other
# second mate, or the first mate, when it chooses to. Remote homes never call
# back to this Mac (the primary pulls their parent channel), so a peer message
# cannot go mate to mate directly. Every message therefore rides the sender's
# existing parent channel up to the primary home, and the primary's router
# (bin/fm-mate-route.sh) delivers it; that script's header owns delivery and
# retry policy. Routing through the primary is also what gives the first mate
# its copy: one log line per message, no relay by the model.
#
# This library owns the wire line, the spool record, and the log. Callers:
#   bin/fm-mate-send.sh            a mate queues one message
#   bin/fm-procevent-remote-reply.sh  diverts a remote mate's wire line to the spool
#   bin/fm-mate-route.sh           delivers, refuses, or fails each spooled message
#
# WIRE LINE (remote route only; a local mate writes the spool record directly):
#   mate-message corr=<16 hex> to=<mate-id|primary> [re=<16 hex>]: <escaped text>
# appended to the mate's own state/parent-replies.status. The text escapes
# backslash as \\, newline as \n and tab as \t, stripping carriage returns,
# so one message is one line.
# Well-formed peer lines are diverted into the spool before ordinary report
# document fetches or status mirroring. A data/*.md pointer in a peer message
# does not fetch, rewrite, or transfer that file to the receiver.
#
# SPOOL (primary home):
#   state/mate-mail/pending/<from>@<corr>.msg    waiting for the router
#   state/mate-mail/{delivered,refused,failed}/  terminal, same name
#   state/mate-mail/pending/<from>@<corr>.tries  "<count> <first-epoch>"
# Pending sidecars with the same <from>@<corr> stem:
#   .publishing          primary publication attempted; check its steering inbox
#   .answer              first successful fm-request answer, atomically kept
#                        for byte-identical delivery retries (fm-mate-route.sh)
#   .woken-delivered     successful no-chat primary delivery wake
#   .woken-undelivered   refused/failed notification wake, never delivery proof
#   .undelivered         terminal outcome and reason, one line each; retry only
#                        that bookkeeping, not delivery
# The router removes these pending sidecars after archiving the message.
# An owed bounce survives beside the archive as:
#   state/mate-mail/{refused,failed}/<from>@<corr>.bounce
# It contains the sender-facing refusal/failure note; successful bounce
# delivery removes it. The watcher also routes when only these obligations
# remain, without requiring a new pending message.
# Record:
#   schema=fm-mate-mail.v1
#   from=<id>  to=<id|primary>  corr=<16 hex>  re=<16 hex or empty>  at=<utc>
#   --
#   <exact text>
# A name already present in any of the four directories is a duplicate, so a
# replayed remote delta never queues the same sender/corr twice.
#
# LOG (primary home): state/mate-messages.log, one complete JSON object per
# terminal message,
#   {at, from, to, corr, re, outcome: delivered|refused|failed, reason, text, sent_at}
# `at` is the log time and `sent_at` is the spool record's original time.
# It is the first mate's oversight copy. Refused/failed outcomes queue one
# `check:` wake keyed mate-mail:<corr>. The router writes the log (and any check
# wake) before archiving a record, at most once per sender/corr, so an
# interrupted pass completes its bookkeeping on retry. Only complete valid
# records count as logged; an incomplete tail is left on its own line before
# the logger appends the complete record.
#
# BRIDGES. The router requires the `messages` flow on the sender's and the
# target's bridge. A remote sender's channel is also pulled under the `reports`
# flow like every other mate report; a denied reports flow already raises the
# captain's bridge request in bin/fm-on.sh, and the message waits queued on the
# remote channel until it is allowed.
#
# Sourced. No side effects on source. Bash 3.2 compatible.

# Fixed cap: a longer peer message points at a data/*.md file instead.
# shellcheck disable=SC2034 # read by bin/fm-mate-send.sh
FM_MATE_MAIL_MAX_BYTES=4000

fm_mate_mail_id_valid() {  # <id>
  local LC_ALL=C
  case "${1-}" in ''|.*|*/*|*@*|*[!A-Za-z0-9._-]*) return 1 ;; esac
}

fm_mate_mail_corr_valid() {  # <corr>
  printf '%s' "${1-}" | grep -Eq '^[a-f0-9]{16}$'
}

fm_mate_mail_new_corr() {
  LC_ALL=C od -An -N8 -tx1 /dev/urandom | tr -d ' \n'
}

fm_mate_mail_escape() {  # <text>
  printf '%s' "$1" | LC_ALL=C tr -d '\r' | perl -0777 -pe 's/\\/\\\\/g; s/\n/\\n/g; s/\t/\\t/g'
}

fm_mate_mail_unescape() {  # <escaped>
  printf '%s' "$1" | perl -0777 -pe 's/\\(\\|n|t)/$1 eq "n" ? "\n" : $1 eq "t" ? "\t" : "\\"/ge'
}

# Print the wire line for one message.
fm_mate_mail_line() {  # <corr> <to> <re> <text>
  printf 'mate-message corr=%s to=%s%s: %s' "$1" "$2" "${3:+ re=$3}" "$(fm_mate_mail_escape "$4")"
}

# 0 when <line> is a wire line (well formed or not); the router decides the rest.
fm_mate_mail_is_line() {  # <line>
  case "${1-}" in 'mate-message '*) return 0 ;; esac
  return 1
}

# Parse a wire line into FM_MM_CORR, FM_MM_TO, FM_MM_RE, FM_MM_TEXT.
fm_mate_mail_parse_line() {  # <line>
  local line=${1-} head
  FM_MM_CORR='' FM_MM_TO='' FM_MM_RE='' FM_MM_TEXT=''
  case "$line" in 'mate-message '*': '*) ;; *) return 1 ;; esac
  head=${line%%: *}
  # The sentinel keeps trailing newlines that command substitution would strip.
  FM_MM_TEXT=$(fm_mate_mail_unescape "${line#*: }"; printf x)
  FM_MM_TEXT=${FM_MM_TEXT%x}
  FM_MM_CORR=$(printf '%s\n' "$head" | sed -n 's/.* corr=\([a-f0-9]\{16\}\)\( .*\)\{0,1\}$/\1/p')
  FM_MM_TO=$(printf '%s\n' "$head" | sed -n 's/.* to=\([^ ]*\).*/\1/p')
  FM_MM_RE=$(printf '%s\n' "$head" | sed -n 's/.* re=\([a-f0-9]\{16\}\).*/\1/p')
  fm_mate_mail_corr_valid "$FM_MM_CORR" || return 1
  [ "$FM_MM_TO" = primary ] || fm_mate_mail_id_valid "$FM_MM_TO" || return 1
  [ -n "$FM_MM_TEXT" ]
}

fm_mate_mail_dir() {  # <state>
  printf '%s/mate-mail\n' "$1"
}

# Spool one message into <state> (the primary home's state dir).
# Returns 0 spooled, 1 duplicate, 2 malformed, 3 write failed.
fm_mate_mail_spool() {  # <state> <from> <to> <corr> <re> <text>
  local state=$1 from=$2 to=$3 corr=$4 re=$5 text=$6 dir name sub tmp
  fm_mate_mail_id_valid "$from" || return 2
  [ "$to" = primary ] || fm_mate_mail_id_valid "$to" || return 2
  fm_mate_mail_corr_valid "$corr" || return 2
  [ -z "$re" ] || fm_mate_mail_corr_valid "$re" || return 2
  [ -n "$text" ] || return 2
  dir=$(fm_mate_mail_dir "$state")
  name="$from@$corr.msg"
  for sub in pending delivered refused failed; do
    [ ! -e "$dir/$sub/$name" ] || return 1
  done
  mkdir -p "$dir/pending" || return 3
  tmp="$dir/pending/.$name.$$"
  {
    printf 'schema=fm-mate-mail.v1\nfrom=%s\nto=%s\ncorr=%s\nre=%s\nat=%s\n--\n' \
      "$from" "$to" "$corr" "$re" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s' "$text"
  } > "$tmp" || { rm -f "$tmp"; return 3; }
  mv "$tmp" "$dir/pending/$name" || { rm -f "$tmp"; return 3; }
}

# Spool a wire line received from remote mate <from>. Same return codes.
fm_mate_mail_spool_line() {  # <state> <from> <line>
  fm_mate_mail_parse_line "$3" || return 2
  fm_mate_mail_spool "$1" "$2" "$FM_MM_TO" "$FM_MM_CORR" "$FM_MM_RE" "$FM_MM_TEXT"
}

# Read one spool record into FM_MM_FROM, FM_MM_TO, FM_MM_CORR, FM_MM_RE,
# FM_MM_AT and FM_MM_TEXT.
fm_mate_mail_read() {  # <record>
  local f=$1
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  FM_MM_FROM=$(sed -n '1,/^--$/s/^from=//p' "$f")
  FM_MM_TO=$(sed -n '1,/^--$/s/^to=//p' "$f")
  FM_MM_CORR=$(sed -n '1,/^--$/s/^corr=//p' "$f")
  FM_MM_RE=$(sed -n '1,/^--$/s/^re=//p' "$f")
  FM_MM_AT=$(sed -n '1,/^--$/s/^at=//p' "$f")
  FM_MM_TEXT=$(sed '1,/^--$/d' "$f"; printf x)
  FM_MM_TEXT=${FM_MM_TEXT%x}
  [ "$(sed -n 1p "$f")" = schema=fm-mate-mail.v1 ] || return 1
  fm_mate_mail_id_valid "$FM_MM_FROM" && fm_mate_mail_corr_valid "$FM_MM_CORR"
}

# Print the outcome and return 0 for a complete log record for <from>/<corr>.
fm_mate_mail_logged() {  # <state> <from> <corr>
  [ -f "$1/mate-messages.log" ] || return 1
  python3 - "$1/mate-messages.log" "$2" "$3" <<'PY'
import json, sys
keys = ("at", "from", "to", "corr", "re", "outcome", "reason", "text")
with open(sys.argv[1], "rb") as log:
    for line in log:
        try:
            row = json.loads(line)
        except (ValueError, UnicodeDecodeError):
            continue
        if not isinstance(row, dict) or not all(isinstance(row.get(k), str) for k in keys):
            continue
        if row["from"] == sys.argv[2] and row["corr"] == sys.argv[3] and row["outcome"] in ("delivered", "refused", "failed"):
            print(row["outcome"])
            sys.exit(0)
sys.exit(1)
PY
}

# Append one oversight line to <state>/mate-messages.log.
fm_mate_mail_log() {  # <state> <outcome> <reason>  (reads FM_MM_*)
  local state=$1 outcome=$2 reason=$3
  python3 -c '
import json, sys, datetime
keys = ["from", "to", "corr", "re", "outcome", "reason", "text"]
row = {"at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
row.update(dict(zip(keys, sys.argv[2:])))
row["sent_at"] = sys.argv[9]
with open(sys.argv[1], "a+b") as log:
    log.seek(0, 2)
    if log.tell():
        log.seek(-1, 2)
        if log.read(1) != b"\n":
            log.write(b"\n")
    log.write((json.dumps(row, ensure_ascii=False) + "\n").encode("utf-8"))
' "$state/mate-messages.log" "$FM_MM_FROM" "$FM_MM_TO" "$FM_MM_CORR" "$FM_MM_RE" \
    "$outcome" "$reason" "$FM_MM_TEXT" "${FM_MM_AT:-}"
}
