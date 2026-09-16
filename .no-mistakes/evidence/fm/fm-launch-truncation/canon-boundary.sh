#!/usr/bin/env bash
set -u
RT=$(command -v tmux); S="fm-bnd-$$"; TMP=$(mktemp -d)
trap '"$RT" -L "$S" kill-server >/dev/null 2>&1; rm -rf "$TMP"' EXIT
T(){ "$RT" -L "$S" "$@"; }
T new-session -d -s s -x 200 -y 50
mode(){ local tty out; tty=$(T display-message -p -t "$1" '#{pane_tty}'); out=$(stty -f "$tty" -a 2>/dev/null); out=" $(printf '%s' "$out"|tr '\n;,' '   ') "
 case "$out" in *' -icanon '*) printf raw;; *' icanon '*) printf canonical;; *) printf unknown;; esac; }
try(){ # <total-bytes> -> LANDED|LOST
  local n=$1 w="w$n-$RANDOM" marker="$TMP/$n.$RANDOM" pad cmd i=0
  T new-window -d -t s -n "$w" "/bin/bash --noprofile --norc -i" >/dev/null
  while [ $i -lt 100 ]; do [ "$(mode "s:$w")" = raw ] && break; sleep 0.05; i=$((i+1)); done
  T send-keys -t "s:$w" -l "sleep 4"; T send-keys -t "s:$w" Enter
  i=0; while [ $i -lt 100 ]; do [ "$(mode "s:$w")" = canonical ] && break; sleep 0.05; i=$((i+1)); done
  cmd="( : ; printf 'y' > '$marker' ) & #"
  pad=$(awk -v n=$((n - ${#cmd})) 'BEGIN{s="";while(length(s)<n)s=s "x";print substr(s,1,n)}')
  cmd="$cmd$pad"
  T send-keys -t "s:$w" -l "$cmd"; T send-keys -t "s:$w" Enter
  i=0; while [ $i -lt 80 ]; do [ -s "$marker" ] && { printf 'LANDED'; T kill-window -t "s:$w" 2>/dev/null; return; }; sleep 0.1; i=$((i+1)); done
  printf 'LOST'; T kill-window -t "s:$w" 2>/dev/null
}
for n in 1000 1023 1024 1025 1097 1200 1238 1400 2000; do
  printf '%5d bytes: %s %s %s\n' "$n" "$(try $n)" "$(try $n)" "$(try $n)"
done
