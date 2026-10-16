#!/usr/bin/env bash
# Tell the captain something on his phone: a notice record his Fleet app shows and the
# Mac's Fleet feed pushes through firstmate's ntfy server.
#
# Usage:
#   fm-notify.sh [--urgent] [--title <title>] [--link <https-url>] <body...>
#   fm-notify.sh [--urgent] [--title <title>] [--link <https-url>] -      (body on stdin)
#
# Writes one notice to this home's state/notices/<id>.json (staged as .<id>.json.<hex> and
# renamed into place), id nt-YYYYMMDDTHHMMSS-xxxxxx:
#   {"version":1,"id","title","body","urgent":bool,"quiet":bool,"created":"<UTC>Z","link":<https|null>}
# The Fleet feed reads every home's notices, remote ones included, attributes each to its
# mate, and pushes it to his phone once (title = the mate's name, the link opens that
# mate's chat); the ntfy token never leaves the Mac. Decision cards reach him that way
# already, so never send a notice for an open decision.
#
# Use it only for what he would want to hear about now: a long task he asked to be told
# about finished, a result is ready, or a blocker. --urgent is for blockers and things that
# cannot wait: it rings at high priority even in quiet hours. Never for routine progress.
#
# Guards, per home:
#   - duplicate: the same title and body within 30 minutes is not sent again
#     (`notice=duplicate: <id>`, exit 0);
#   - rate limit: at most 6 notices an hour, 12 counting urgent ones
#     (`notice=limited: ...`, exit 3, nothing written);
#   - quiet hours: config/notify-quiet holds `HH:MM-HH:MM` in this machine's local time
#     (default 22:00-08:00; `off` disables). A non-urgent notice sent then is kept with
#     quiet: true, shown in the app but not pushed.
# Notices older than seven days are removed. Prints `notice=<id> push|quiet`.
# FM_NOTIFY_NOW (epoch seconds) fixes the clock for tests. Usage errors exit 2.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

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
import calendar, json, os, re, secrets, sys, time
E = os.environ
now = float(E.get("FM_NOTIFY_NOW") or time.time())
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
with open(tmp, "w") as f:
    json.dump(rec, f)
os.chmod(tmp, 0o644)
os.rename(tmp, os.path.join(d, nid + ".json"))
print("notice=%s %s" % (nid, "quiet" if quiet else "push"))
'
