#!/usr/bin/env bash
# Evidence capture: drives the real bin/fm-deck-worker.sh end-to-end against a
# scripted deck binary (the same pattern tests/fm-deck-harness.test.sh uses) and
# captures the pane output a captain watches.
set -eu
ROOT=/Users/bastotecnologia/.no-mistakes/worktrees/5a1fd3284f12/01M3A7AT0ZGQHW6C8E457A7RB9
EV=/Users/bastotecnologia/.no-mistakes/evidence/01M3A7AT0ZGQHW6C8E457A7RB9
WORKER="$ROOT/bin/fm-deck-worker.sh"
BUSY_EVENT="$ROOT/bin/fm-busy-event.sh"
SCRATCH=$(mktemp -d "$EV/.scratch.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT

make_fake_deck() {  # <dir> <mode: modern|legacy>
  local dir=$1 mode=$2 finish
  mkdir -p "$dir"
  if [ "$mode" = legacy ]; then
    finish='printf "{\"type\":\"run_finished\",\"output\":\"x\",\"turns\":3}\n"'
  else
    finish='printf "{\"type\":\"run_finished\",\"output\":\"x\",\"turns\":3,\"finished_at\":1790269292}\n"'
  fi
  cat > "$dir/deck" <<SH
#!/usr/bin/env bash
prompt=\$2; session=''; gate=''
while [ \$# -gt 0 ]; do
  case \$1 in
    --session) session=\$2; shift 2 ;;
    --hook) case \$2 in pre_complete=*) gate=\${2#pre_complete=} ;; esac; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "\$session" ] || session="s-fake-\$\$"
printf '{"type":"run_started","session":"%s","model":"m"}\n' "\$session"
printf '{"type":"text_delta","text":"echo: %s"}\n' "\$prompt"
printf 'done: wrote evidence\n' >> "\$FM_TEST_STATUS"
[ -z "\$gate" ] || bash -c "\$gate" </dev/null || true
$finish
SH
  chmod +x "$dir/deck"
}

run_worker() {  # <dir> <input> <prompt>
  local dir=$1 input=$2 prompt=$3 gen
  mkdir -p "$dir/state"
  gen=$("$BUSY_EVENT" arm "$dir/state" t1)
  printf '%s' "$input" | FM_TEST_STATUS="$dir/state/t1.status" FM_TEST_EXTERNAL='' \
    FM_TEST_BUSY_EVENT="$BUSY_EVENT" \
    "$WORKER" --id t1 --state "$dir/state" --gen "$gen" \
      --deck "$dir/deck" --model codex/gpt-5.6-luna -- "$prompt" > "$dir/pane.out" 2>&1
}

# Case 1: modern deck binary (run_finished carries finished_at).
d1="$SCRATCH/modern"; make_fake_deck "$d1" modern
run_worker "$d1" $'/quit\n' 'write-status'
cp "$d1/pane.out" "$EV/pane-modern-finished-at.txt"

# Case 2: legacy deck binary (run_finished has no finished_at).
d2="$SCRATCH/legacy"; make_fake_deck "$d2" legacy
run_worker "$d2" $'/quit\n' 'write-status'
cp "$d2/pane.out" "$EV/pane-legacy-no-finished-at.txt"

# Case 3: two turns in one session - idle note after turn 1, finished line after
# turn 2, prompt row still the bare glyph.
d3="$SCRATCH/two-turns"; make_fake_deck "$d3" modern
run_worker "$d3" $'first\nsecond\n/quit\n' 'write-status'
cp "$d3/pane.out" "$EV/pane-two-turns-idle-note.txt"

echo "=== case 1 pane (modern) ==="; cat "$EV/pane-modern-finished-at.txt"; echo
echo "=== case 2 pane (legacy) ==="; cat "$EV/pane-legacy-no-finished-at.txt"; echo
echo "=== case 3 tail (two turns) ==="; tail -8 "$EV/pane-two-turns-idle-note.txt"; echo
