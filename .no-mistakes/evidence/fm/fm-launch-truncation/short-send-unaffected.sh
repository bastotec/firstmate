#!/usr/bin/env bash
# Guard: the readiness gate must sit ONLY on the launch path. Everyday short
# sends - steering messages, the inbox doorbell, `fm-control.sh exit` - go
# through fm_backend_tmux_send_text_line / fm_tmux_submit_core and must still be
# delivered to a BUSY pane, not refused.
set -u
ROOT=$1
RT=$(command -v tmux); S="fm-short-$$"; TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-short.XXXXXX"); SHIM="$TMP/bin"; mkdir -p "$SHIM"
trap '"$RT" -L "$S" kill-server >/dev/null 2>&1; rm -rf "$TMP"' EXIT
cat > "$SHIM/tmux" <<SH
#!/usr/bin/env bash
exec "$RT" -L "$S" "\$@"
SH
chmod +x "$SHIM/tmux"; PATH="$SHIM:$PATH"; export PATH
. "$ROOT/bin/fm-backend.sh"; fm_backend_source tmux
tmux new-session -d -s s -x 200 -y 50
tmux new-window -d -t s -n w "/bin/bash --noprofile --norc -i"
i=0; while [ $i -lt 100 ]; do
  tty=$(tmux display-message -p -t s:w '#{pane_tty}'); stty -f "$tty" -a 2>/dev/null | tr '\n;,' '   ' | grep -q -- '-icanon' && break
  sleep 0.05; i=$((i+1)); done
tmux send-keys -t s:w -l "sleep 3"; tmux send-keys -t s:w Enter
sleep 0.4
tty=$(tmux display-message -p -t s:w '#{pane_tty}')
echo "pane line discipline while the send is made: $(stty -f "$tty" -a 2>/dev/null | tr '\n;,' '   ' | grep -q -- '-icanon' && echo raw || echo canonical)"
st=0
FM_PANE_READY_TIMEOUT=1 fm_backend_tmux_send_text_line s:w "printf 'short send delivered\n' > $TMP/out" || st=$?
echo "fm_backend_tmux_send_text_line status on a busy pane: $st (0 = not refused)"
i=0; while [ $i -lt 80 ]; do [ -s "$TMP/out" ] && break; sleep 0.1; i=$((i+1)); done
if [ -s "$TMP/out" ]; then echo "result: $(cat "$TMP/out") once the pane freed up"; else echo "result: short send never arrived"; fi
