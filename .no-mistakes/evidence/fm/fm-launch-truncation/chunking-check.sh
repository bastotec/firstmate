#!/usr/bin/env bash
# Adversarial check of the one claim this change makes AGAINST the incident
# report: that splitting the send into ~400-byte chunks does not rescue a busy
# pane, and that the hand-verified success was an idle pane, not the split.
#
# Same fixture for every row - a fresh window running an interactive bash made
# busy with `sleep 4`, one real 1238-byte command whose own prefix writes the
# marker. The padding sits after a `#`, so even a PARTIAL delivery would still
# run the prefix and report LANDED; only a whole-line discard reports LOST.
set -u
RT=$(command -v tmux); S="fm-chunk-$$"; TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-chunk.XXXXXX")
trap '"$RT" -L "$S" kill-server >/dev/null 2>&1; rm -rf "$TMP"' EXIT
T(){ "$RT" -L "$S" "$@"; }
T new-session -d -s s -x 200 -y 50
mode(){ local tty out; tty=$(T display-message -p -t "$1" '#{pane_tty}'); out=$(stty -f "$tty" -a 2>/dev/null)
  out=" $(printf '%s' "$out"|tr '\n;,' '   ') "
  case "$out" in *' -icanon '*) printf raw;; *' icanon '*) printf canonical;; *) printf unknown;; esac; }

TOTAL=1238   # the reported launch command size band
try(){ # <chunk-bytes> <pause?> <busy?> -> LANDED|LOST
  local chunk=$1 pause=$2 busyp=$3
  local w="c$RANDOM" marker="$TMP/m$RANDOM" cmd pad off i=0
  T new-window -d -t s -n "$w" "/bin/bash --noprofile --norc -i" >/dev/null
  while [ $i -lt 100 ]; do [ "$(mode "s:$w")" = raw ] && break; sleep 0.05; i=$((i+1)); done
  if [ "$busyp" = yes ]; then
    T send-keys -t "s:$w" -l "sleep 4"; T send-keys -t "s:$w" Enter
    i=0; while [ $i -lt 100 ]; do [ "$(mode "s:$w")" = canonical ] && break; sleep 0.05; i=$((i+1)); done
    [ "$(mode "s:$w")" = canonical ] || { printf 'FIXTURE-NOT-BUSY'; return; }
  fi
  cmd="( : ; printf 'y' > '$marker' ) & #"
  pad=$(awk -v n=$((TOTAL - ${#cmd})) 'BEGIN{s="";while(length(s)<n)s=s "x";print substr(s,1,n)}')
  cmd="$cmd$pad"
  off=0
  while [ $off -lt ${#cmd} ]; do
    T send-keys -t "s:$w" -l "${cmd:$off:$chunk}"
    off=$((off+chunk)); [ "$pause" = yes ] && sleep 0.05
  done
  T send-keys -t "s:$w" Enter
  i=0; while [ $i -lt 90 ]; do [ -s "$marker" ] && { printf 'LANDED'; T kill-window -t "s:$w" 2>/dev/null; return; }; sleep 0.1; i=$((i+1)); done
  printf 'LOST'; T kill-window -t "s:$w" 2>/dev/null
}

echo "tmux $("$RT" -V) on $(uname -srm); one ${TOTAL}-byte command, three repeats per row"
echo
printf '%-48s %s\n' "pane state / send shape" "result x3"
printf '%-48s %s\n' "------------------------------------------------" "---------"
printf '%-48s %s %s %s\n' "busy pane, one send (the reported failure)"   "$(try 99999 no yes)" "$(try 99999 no yes)" "$(try 99999 no yes)"
printf '%-48s %s %s %s\n' "busy pane, 400-byte chunks (the claimed fix)" "$(try 400 no yes)" "$(try 400 no yes)" "$(try 400 no yes)"
printf '%-48s %s %s %s\n' "busy pane, 400-byte chunks with pauses"       "$(try 400 yes yes)" "$(try 400 yes yes)" "$(try 400 yes yes)"
printf '%-48s %s %s %s\n' "busy pane, 200-byte chunks"                   "$(try 200 yes yes)" "$(try 200 yes yes)" "$(try 200 yes yes)"
printf '%-48s %s %s %s\n' "busy pane, 100-byte chunks"                   "$(try 100 yes yes)" "$(try 100 yes yes)" "$(try 100 yes yes)"
printf '%-48s %s %s %s\n' "IDLE pane, one send (what the report measured)" "$(try 99999 no no)" "$(try 99999 no no)" "$(try 99999 no no)"
