#!/usr/bin/env bash
# Live A/B repro of bastotec/firstmate#4559 against a REAL tmux server on a
# private socket. Same ~1117-byte launch command, same busy pane, two senders:
#   A: the pre-fix path  -> plain `tmux send-keys -t <T> -l "$LAUNCH"`
#   B: the shipped path  -> fm_backend_tmux_send_literal (readiness gate)
# The worker itself writes the marker, so "marker present" means a worker ran.
set -u
ROOT=$1
REAL_TMUX=$(command -v tmux)
SOCKET="fm-repro-$$"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-repro.XXXXXX")
SHIM=$(mktemp -d "${TMPDIR:-/tmp}/fm-repro-shim.XXXXXX")
cleanup() { "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true; rm -rf "$TMP" "$SHIM"; }
trap cleanup EXIT
cat > "$SHIM/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM/tmux"
PATH="$SHIM:$PATH"; export PATH
. "$ROOT/bin/fm-backend.sh"; fm_backend_source tmux

S=repro
tmux new-session -d -s "$S" -x 200 -y 50

probe_mode() {
  local tty out
  tty=$(tmux display-message -p -t "$1" '#{pane_tty}' 2>/dev/null) || { printf unknown; return 0; }
  out=$(stty -f "$tty" -a 2>/dev/null) || out=$(stty -F "$tty" -a 2>/dev/null) || { printf unknown; return 0; }
  out=" $(printf '%s' "$out" | tr '\n;,' '   ') "
  case "$out" in *' -icanon '*) printf raw;; *' icanon '*) printf canonical;; *) printf unknown;; esac
}

busy_pane() {
  local w=$1 secs=$2 i=0
  tmux new-window -d -t "$S" -n "$w" "/bin/bash --noprofile --norc -i"
  while [ $i -lt 100 ]; do [ "$(probe_mode "$S:$w")" = raw ] && break; sleep 0.05; i=$((i+1)); done
  tmux send-keys -t "$S:$w" -l "sleep $secs"; tmux send-keys -t "$S:$w" Enter
  i=0
  while [ $i -lt 100 ]; do [ "$(probe_mode "$S:$w")" = canonical ] && return 0; sleep 0.05; i=$((i+1)); done
  echo "fixture never went canonical"; exit 9
}

mk_cmd() {  # <marker> <payload-file>  -> ~1117-byte launch command
  local marker=$1 pf=$2 payload
  payload=$(awk 'BEGIN{s="";while(length(s)<1040)s=s "abcdefghij";print substr(s,1,1040)}')
  printf '%s' "$payload" > "$pf.expected"
  printf "( printf '%%s' '%s' > '%s'; printf 'started\\n' > '%s' ) &" "$payload" "$pf" "$marker"
}

wait_marker() { local i=0; while [ $i -lt 60 ]; do [ -s "$1" ] && return 0; sleep 0.1; i=$((i+1)); done; return 1; }

echo "tmux: $("$REAL_TMUX" -V)   host: $(uname -srm)"
echo

# ---- A: pre-fix ungated send ------------------------------------------------
mkdir -p "$TMP/a"
CMD=$(mk_cmd "$TMP/a/marker" "$TMP/a/payload")
echo "launch command length: ${#CMD} bytes (report says ~1117)"
echo
echo "== A: pre-fix path (plain tmux send-keys -l, no readiness gate) =="
busy_pane a 2
echo "   pane tty line discipline at send time: $(probe_mode "$S:a")"
tmux send-keys -t "$S:a" -l "$CMD"; tmux send-keys -t "$S:a" Enter
if wait_marker "$TMP/a/marker"; then echo "   RESULT: worker started (marker written)"; else echo "   RESULT: NO WORKER STARTED - the command vanished silently"; fi
echo "   pane after the busy command finished, as an operator would see it:"
sleep 2.5
tmux capture-pane -p -t "$S:a" | grep -v '^$' | tail -4 | sed 's/^/     | /'
echo

# ---- B: shipped gated send --------------------------------------------------
mkdir -p "$TMP/b"
CMD=$(mk_cmd "$TMP/b/marker" "$TMP/b/payload")
echo "== B: shipped path (fm_backend_tmux_send_literal, readiness gate) =="
busy_pane b 2
echo "   pane tty line discipline at send time: $(probe_mode "$S:b")"
st=0; fm_backend_tmux_send_literal "$S:b" "$CMD" || st=$?
echo "   gated send returned status $st"
fm_backend_tmux_send_key "$S:b" Enter
if wait_marker "$TMP/b/marker"; then echo "   RESULT: worker started (marker written by the launched process)"; else echo "   RESULT: NO WORKER STARTED"; fi
if cmp -s "$TMP/b/payload" "$TMP/b/payload.expected"; then echo "   RESULT: worker received the command byte-identical to what was sent"; else echo "   RESULT: payload differs"; fi
