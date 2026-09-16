#!/usr/bin/env bash
# Live driver: publish a remote secondmate home with the real product
# (bin/fm-remote-home-seed.sh) over the deterministic SSH boundary, then read the
# charter that actually lands on that host and act on it as the mate would.
set -u
ROOT=${ROOT:?}
EVID=${EVID:?}
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-charter.XXXXXX") || exit 1
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
PARENT="$TMP_ROOT/parent"
REMOTE_ROOT="$TMP_ROOT/remote-root"
REMOTE_HOME="$TMP_ROOT/remote-home"
FAKEBIN="$TMP_ROOT/fake"
mkdir -p "$PARENT/data" "$PARENT/state" "$PARENT/config" "$PARENT/projects" "$REMOTE_ROOT" "$FAKEBIN"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

( cd "$ROOT" && tar --exclude=.git --exclude=.no-mistakes --exclude=data --exclude=state --exclude=config -cf - . ) \
  | ( cd "$REMOTE_ROOT" && tar -xf - )
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" config user.email test@example.com
git -C "$REMOTE_ROOT" config user.name Test
git -C "$REMOTE_ROOT" add .
git -C "$REMOTE_ROOT" commit -qm 'remote fixture root'
git init -q --bare "$TMP_ROOT/firstmate-origin.git"
git -C "$REMOTE_ROOT" remote add origin "file://$TMP_ROOT/firstmate-origin.git"
git -C "$REMOTE_ROOT" push -q -u origin main
git --git-dir="$TMP_ROOT/firstmate-origin.git" symbolic-ref HEAD refs/heads/main

git init -q --bare "$TMP_ROOT/alpha.git"
git -C "$PARENT/projects" init -q -b main alpha
git -C "$PARENT/projects/alpha" config user.email test@example.com
git -C "$PARENT/projects/alpha" config user.name Test
printf 'alpha\n' > "$PARENT/projects/alpha/README.md"
git -C "$PARENT/projects/alpha" add README.md
git -C "$PARENT/projects/alpha" commit -qm init
git -C "$PARENT/projects/alpha" remote add origin "file://$TMP_ROOT/alpha.git"
git -C "$PARENT/projects/alpha" push -q -u origin main
printf -- '- alpha [direct-PR] - alpha project (added 2026-08-02)\n' > "$PARENT/data/projects.md"
printf 'codex\n' > "$PARENT/config/secondmate-harness"
printf 'tmux\n' > "$PARENT/config/backend"
printf 'primary harness defaults\n' > "$PARENT/config/crew-harness"

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1; entry=$2; shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
cd "$FM_FAKE_REMOTE_CWD" || exit 93
argv_b64=$4
command_name=$(perl -MMIME::Base64=decode_base64 -e 'my @a=split(/\0/,decode_base64($ARGV[0])); print $a[0];' "$argv_b64")
if [ "$command_name" = fm-remote-doctor.sh ]; then
  printf 'check herdr=ok: /usr/bin/herdr\n'
  printf 'ok: remote second-mate readiness confirmed on this host\n'
  exit 0
fi
exec "$FM_FAKE_REMOTE_ENTRYPOINT" "$@"
SH
chmod +x "$FAKEBIN/fake-ssh"

FM_SECONDMATE_CHARTER='Own iOS delivery on the build Mac.' \
FM_SECONDMATE_SCOPE='iOS implementation and Xcode validation' \
FM_HOME="$PARENT" \
FM_ROOT_OVERRIDE="$REMOTE_ROOT" \
FM_SSH_BIN="$FAKEBIN/fake-ssh" \
FM_FAKE_REMOTE_ENTRYPOINT="$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" \
FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/remote-jobs" \
FM_FAKE_REMOTE_CWD="$TMP_ROOT" \
  "$ROOT/bin/fm-remote-home-seed.sh" ios remote-mac "$REMOTE_ROOT" "$REMOTE_HOME" alpha \
  > "$EVID/seed.out" 2>&1
seed_rc=$?
echo "seed exit=$seed_rc"
[ "$seed_rc" -eq 0 ] || { cat "$EVID/seed.out"; exit 1; }

cp "$REMOTE_HOME/data/charter.md" "$EVID/remote-charter.md"
cp "$PARENT/data/$(ls "$PARENT/data" | grep -i 'ios' | head -1)" "$EVID/parent-charter.md" 2>/dev/null || \
  cp "$PARENT/data/charters/ios.md" "$EVID/parent-charter.md" 2>/dev/null || true

# Normalize the throwaway fixture paths so the evidence reads as the reported case.
sed -e "s#$REMOTE_HOME#/home/bruno/secondmates/bob-helper#g" \
    -e "s#$PARENT#/Users/bastotecnologia/Projects/firstmate#g" \
    "$EVID/remote-charter.md" > "$EVID/remote-charter.normalized.md"

echo "== inbox section of the charter published on the remote host =="
grep -n -i -B2 -A12 'instruction inbox' "$EVID/remote-charter.normalized.md" | head -60
echo
echo "== every path the published charter names under a state directory =="
grep -o "'[^']*state/[^']*'" "$EVID/remote-charter.normalized.md" | sort -u

echo
echo "== parent-path leakage check =="
if grep -q "$PARENT/state/ios.inbox" "$REMOTE_HOME/data/charter.md"; then
  echo "FAIL: published charter still names the parent inbox $PARENT/state/ios.inbox"
else
  echo "ok: published charter names no parent-home inbox path"
fi

echo
echo "== act on the charter as the mate: write a real steer with the product's own inbox writer, then run the charter's acknowledgement command verbatim =="
INBOX_DIR=$(grep -o "durable message files in '[^']*'" "$REMOTE_HOME/data/charter.md" | head -1 | sed "s/.*in '//; s/'$//")
echo "charter names inbox: $INBOX_DIR"
REC=$(FM_STATE_OVERRIDE="$REMOTE_HOME/state/parent-route" \
  /bin/bash -c '. "$1"; fm_task_inbox_write_idempotent "$2" ios "$3" ""' \
  _ "$REMOTE_ROOT/bin/fm-task-inbox-lib.sh" "$REMOTE_HOME/state/parent-route" 'Run the iOS build and report the result.') \
  || { echo "FAIL: could not write a steering record"; exit 1; }
echo "product delivered the steer to: $REC"
if [ "$(cd "$(dirname "$REC")" && pwd -P)" = "$(cd "$INBOX_DIR" 2>/dev/null && pwd -P)" ]; then
  echo "ok: delivery directory == the directory the charter tells the mate to read"
else
  echo "FAIL: charter names $INBOX_DIR but delivery landed in $(dirname "$REC")"
fi
echo "--- record the mate would read ---"
cat "$REC"

ACK_CMD=$(grep -o '`mv [^`]*`' "$REMOTE_HOME/data/charter.md" | head -1 | sed 's/^`//; s/`$//')
echo "--- acknowledgement command exactly as the charter prints it ---"
printf '%s\n' "$ACK_CMD"
ACK_RUNNABLE=$(printf '%s\n' "$ACK_CMD" | sed "s#/NNN\.msg#/$(basename "$REC")#")
echo "--- running it verbatim (only NNN.msg filled in with the delivered record) ---"
printf '%s\n' "$ACK_RUNNABLE"
if eval "$ACK_RUNNABLE" 2>&1; then
  if [ -f "$INBOX_DIR/handled/$(basename "$REC")" ]; then
    echo "ok: the charter's own acknowledgement command moved the delivered record into handled/"
    ls -1 "$INBOX_DIR/handled/"
  else
    echo "FAIL: mv reported success but the record is not in handled/"
  fi
else
  echo "FAIL: the charter's acknowledgement command is not runnable as printed"
fi
