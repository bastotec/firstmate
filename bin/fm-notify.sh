#!/usr/bin/env bash
# Write a captain notice for the external Fleet Town app and phone-push feed.
# This command publishes a local record, not a delivery receipt.
#
# Usage:
#   fm-notify.sh [--urgent] [--title <title>] [--link <https-url>] <body...>
#   fm-notify.sh [--urgent] [--title <title>] [--link <https-url>] -      (body on stdin)
#
# Notice contents remain owner-only (mode 0600) from staging through publication.
# Writes one notice to this home's state/notices/<id>.json (staged as .<id>.json.<hex> and
# renamed into place), id nt-YYYYMMDDTHHMMSS-xxxxxx:
#   {"version":1,"id","title","body","urgent":bool,"quiet":bool,"created":"<UTC>Z","link":<https|null>}
# Fleet Town's separate feed integration must read each home's notices (including remote
# homes), attribute them to the mate, and push once with the mate's name as title and its
# chat as the destination; urgent notices request high priority even in quiet hours.
# This script never contacts ntfy or reads its token, which stays on the primary Mac.
# `push` below means eligible for that feed, not confirmed delivery.
# The primary home's ntfy configuration is catalogued in docs/configuration.md.
# AGENTS.md section 9 owns when to notify and the parent-channel reporting requirement.
#
# Guards, per home (scan, cleanup and publication serialized by notices/.lock):
#   - workers: fm-worker-guard-lib.sh refuses a marked worker of this home before any
#     notification state is created (exit 3); escalate through the supervising mate;
#   - duplicate: title and body, after whitespace folding and lowercasing, match a notice
#     within 30 minutes (`notice=duplicate: <id>`, exit 0), regardless of urgency or link;
#   - rate limit: at most 6 non-urgent notices and 12 total notices in a rolling hour
#     (`notice=limited: ...`, exit 3, no new notice published);
#   - quiet hours: config/notify-quiet holds `HH:MM-HH:MM` in this machine's local time
#     (default 22:00-08:00; `off` disables). A non-urgent notice sent then is kept with
#     quiet: true for app display without a phone push. Urgent notices bypass quiet hours.
# Valid input is sanitized and truncated to 120 title and 1000 body characters; --link
# must be HTTPS. Notices older than seven days are removed during a valid send attempt.
# Prints `notice=<id> push|quiet` when a new record is published.
# FM_NOTIFY_NOW (epoch seconds) fixes the clock for tests. Usage errors exit 2.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-worker-guard-lib.sh
. "$SCRIPT_DIR/fm-worker-guard-lib.sh"
fm_worker_guard_refuse "$STATE" "send a captain notification"

usage() { sed -n '5,7p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

urgent=0 title='' link=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --urgent) urgent=1; shift ;;
    --title) [ "$#" -ge 2 ] || usage; title=$2; shift 2 ;;
    --link) [ "$#" -ge 2 ] || usage; link=$2; shift 2 ;;
    --) shift; break ;;
    -) break ;;
    -*) usage ;;
    *) break ;;
  esac
done
[ "$#" -ge 1 ] || usage
if [ "$1" = - ]; then body=$(cat); else body="$*"; fi

quiet_spec=22:00-08:00
[ ! -f "$CONFIG/notify-quiet" ] || quiet_spec=$(head -n 1 "$CONFIG/notify-quiet" | tr -d '[:space:]')

FM_NOTIFY_URGENT=$urgent FM_NOTIFY_TITLE=$title FM_NOTIFY_LINK=$link FM_NOTIFY_BODY=$body \
FM_NOTIFY_QUIET=$quiet_spec FM_NOTIFY_DIR="$STATE/notices" exec python3 -c '
import calendar, fcntl, json, os, re, secrets, sys, time
E = os.environ
d = E["FM_NOTIFY_DIR"]
urgent = E["FM_NOTIFY_URGENT"] == "1"
ctl = re.compile(r"[\x00-\x09\x0b-\x1f\x7f]")
title = ctl.sub(" ", E["FM_NOTIFY_TITLE"]).replace("\n", " ").strip()[:120]
body = ctl.sub(" ", E["FM_NOTIFY_BODY"]).strip()[:1000]
link = E["FM_NOTIFY_LINK"].strip()
if not body:
    print("notice=refused: the notice needs a body"); sys.exit(2)
if link and not re.fullmatch(r"https://[^\s\x00-\x1f\x7f]{1,292}", link):
    print("notice=refused: --link must be a plain https link"); sys.exit(2)
os.makedirs(d, mode=0o755, exist_ok=True)
lock = open(os.path.join(d, ".lock"), "a")
fcntl.flock(lock, fcntl.LOCK_EX)
now = float(E.get("FM_NOTIFY_NOW") or time.time())
mine = []
for n in os.listdir(d):
    if not re.fullmatch(r"nt-\d{8}T\d{6}-[0-9a-f]{6}\.json", n):
        continue
    p = os.path.join(d, n)
    try:
        r = json.load(open(p))
        t = calendar.timegm(time.strptime(r["created"], "%Y-%m-%dT%H:%M:%SZ"))
    except Exception:
        continue
    if t < now - 7 * 86400:
        try: os.unlink(p)
        except OSError: pass
        continue
    mine.append((t, r))
norm = lambda s: " ".join(s.split()).lower()
for t, r in mine:
    if t >= now - 1800 and norm(r.get("title", "")) == norm(title) and norm(r.get("body", "")) == norm(body):
        print("notice=duplicate: " + r["id"]); sys.exit(0)
hour = [r for t, r in mine if t >= now - 3600]
plain = [r for r in hour if not r.get("urgent")]
if len(hour) >= 12 or (not urgent and len(plain) >= 6):
    print("notice=limited: %d notices in the last hour; say it in one, or wait" % len(hour)); sys.exit(3)
def quiet_now(spec):
    if spec in ("", "off"):
        return False
    m = re.fullmatch(r"(\d\d):(\d\d)-(\d\d):(\d\d)", spec)
    if not m:
        return False
    a = int(m.group(1)) * 60 + int(m.group(2)); b = int(m.group(3)) * 60 + int(m.group(4))
    lt = time.localtime(now); x = lt.tm_hour * 60 + lt.tm_min
    return (a <= x < b) if a <= b else (x >= a or x < b)
quiet = (not urgent) and quiet_now(E["FM_NOTIFY_QUIET"])
nid = "nt-" + time.strftime("%Y%m%dT%H%M%S", time.gmtime(now)) + "-" + secrets.token_hex(3)
rec = {"version": 1, "id": nid, "title": title, "body": body, "urgent": urgent, "quiet": quiet,
       "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)), "link": link or None}
tmp = os.path.join(d, ".%s.json.%s" % (nid, secrets.token_hex(4)))
with os.fdopen(os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as f:
    json.dump(rec, f)
os.rename(tmp, os.path.join(d, nid + ".json"))
print("notice=%s %s" % (nid, "quiet" if quiet else "push"))
'
