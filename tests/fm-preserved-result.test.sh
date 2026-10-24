#!/usr/bin/env bash
# Behavior contract: original dirty allocation and knowledge completion survive
# endpoint retirement, failures, retries, and ordinary cleanup/dispatch consumers.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
unset FMX_PAIRING_TOKEN FM_PUBLIC_FOLLOWUP_PRIMARY_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE
fm_git_identity
TMP_ROOT=$(fm_test_tmproot fm-preserved-result)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
REAL_TREEHOUSE=$(command -v treehouse || true)
mkdir -p "$TMP_ROOT/fakebin"
# Portable admission uses a version stub; the optional installed-tool contract
# below exercises the actual Treehouse allocator and sweeps on fixtures only.
printf '#!/usr/bin/env bash\nprintf "v2.3.0\\n"\n' > "$TMP_ROOT/fakebin/treehouse"
chmod +x "$TMP_ROOT/fakebin/treehouse"
cat > "$TMP_ROOT/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'runs --limit 200')
    [ ! -f "$FM_RETIRE_TEST_CASE/nm-ledger-fail" ] || exit 1
    [ ! -f "$FM_RETIRE_TEST_CASE/nm-ledger" ] || cat "$FM_RETIRE_TEST_CASE/nm-ledger"
    ;;
  'axi status')
    [ ! -f "$FM_RETIRE_TEST_CASE/nm-status-fail" ] || exit 1
    if [ -f "$FM_RETIRE_TEST_CASE/nm-status" ]; then
      cat "$FM_RETIRE_TEST_CASE/nm-status"
    else
      printf 'run:\n  id: "01FIXTURE"\n  branch: %s\n  status: completed\n  outcome: passed\n  head: "%s"\n' \
        "$(git symbolic-ref --short HEAD)" "$(git rev-parse HEAD)"
    fi
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$TMP_ROOT/fakebin/no-mistakes"
export PATH="$TMP_ROOT/fakebin:$PATH"
RETIRE="$ROOT/bin/fm-retire-endpoint.sh"

make_case() {
  local name=$1
  C="$TMP_ROOT/$name"
  H="$C/home"
  W="$C/pool/1/project"
  mkdir -p "$H/state" "$H/data" "$H/config" "$C/project" "$C/pool/1"
  git -C "$C/project" init -q
  git -C "$C/project" commit --allow-empty -qm initial
  git -C "$C/project" worktree add -qb "original-$name" "$W"
  printf 'original\n' > "$W/source"
  git -C "$W" add source
  git -C "$W" commit -qm original
  printf 'second\n' > "$W/second"
  git -C "$W" add second
  git -C "$W" commit -qm second
  printf 'dirty\n' >> "$W/source"
  printf 'staged\n' > "$W/staged"
  git -C "$W" add staged
  printf 'scratch artifact\n' > "$W/artifact"
  printf 'ignored\n' > "$W/ignored"
  printf 'ignored\n' > "$W/.gitignore"
  printf '{"unknown":"retain","worktrees":[{"name":"1","path":"%s","owner_pid":0}]}\n' "$W" > "$C/pool/treehouse-state.json"
  printf 'task=finite\nhome=%s\n' "$H" > "$C/pool/1/.fm-slot-owner"
  fm_test_stream_task "$H/state" finite > "$H/state/finite.meta"
  target=$(sed -n 's/^window=//p' "$H/state/finite.meta")
  printf 'kind=ship\nmode=no-mistakes\nspawn_gen=original\nproject=%s\nworktree=%s\n' "$C/project" "$W" >> "$H/state/finite.meta"
  printf 'Inconclusive diagnosis; not a shipped fix.\n' > "$C/result.md"
  python3 - "$C" "$H" "$W" <<'PY'
import pathlib,sys,hashlib,json,subprocess
c,h,w=map(pathlib.Path,sys.argv[1:])
a=dict(task='finite',spawn_gen='original',meta_sha256=hashlib.sha256((h/'state/finite.meta').read_bytes()).hexdigest(),head=subprocess.check_output(['git','-C',str(w),'rev-parse','HEAD']).decode().strip(),outcome='diagnosis',accepted_by='owning-mate',summary='Inconclusive; no product repair claimed',result=str(c/'result.md'),result_sha256=hashlib.sha256((c/'result.md').read_bytes()).hexdigest())
a['allocation']=json.loads((c/'pool/treehouse-state.json').read_text())['worktrees'][0]
(c/'acceptance.json').write_text(json.dumps(a))
PY
  cp "$H/state/finite.meta" "$C/before.meta"
  git -C "$W" show-ref > "$C/before.refs"
  git -C "$W" rev-list --all > "$C/before.commits"
  git -C "$W" status --porcelain=v1 --untracked-files=all > "$C/before.status"
}
run_retirement() {
  FM_RETIRE_TEST_CASE="$C" FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" "$RETIRE" --accepted-result "$C/acceptance.json" finite
}
assert_preserved() {
  git -C "$W" show-ref > "$C/after.refs"
  git -C "$W" rev-list --all > "$C/after.commits"
  git -C "$W" status --porcelain=v1 --untracked-files=all > "$C/after.status"
  for item in refs commits status; do cmp "$C/before.$item" "$C/after.$item" || fail "original $item changed"; done
  [ "$(cat "$W/artifact")" = 'scratch artifact' ] || fail 'source artifact changed'
  [ "$(cat "$W/ignored")" = ignored ] || fail 'ignored artifact changed'
  [ "$(cat "$W/source")" = $'original\ndirty' ] || fail 'dirty content changed'
  [ "$(cat "$C/pool/1/.fm-slot-owner")" = "$(printf 'task=finite\nhome=%s' "$H")" ] || fail 'allocation claim changed'
}
expect_refusal() {
  if run_retirement > "$C/out" 2>&1; then fail "unexpected retirement success"; fi
  [ -f "$H/state/finite.meta" ] || fail 'refusal removed original record'
  cmp "$H/state/finite.meta" "$C/before.meta" || fail 'refusal rewrote original record'
  assert_preserved
}

assert_admission_refused() {
  local reason=$1 endpoint
  expect_refusal
  assert_contains "$(cat "$C/out")" "$reason" 'wrong admission refusal'
  [ ! -e "$H/state/finite.preserved-result" ] || fail 'refusal prepared retention'
  [ ! -e "$H/data/finite/preserved-result" ] || fail 'refusal published evidence'
  [ "$(jq -r '.worktrees[0].leased // false' "$C/pool/treehouse-state.json")" = false ] || fail 'refusal leased allocation'
  endpoint=$(fm_test_fake_stream_endpoints | jq --arg e "${target##*:}" '.endpoints[] | select(.endpoint_id == $e)')
  [ -n "$endpoint" ] && [ "$(printf '%s' "$endpoint" | jq -r '.closed_by // empty')" = '' ] || fail 'refusal stopped endpoint'
}

for validation in pipeline-owned matching-live ledger-live status-failure ledger-failure status-error partial unbound foreign-branch; do
  make_case "validation-$validation"
  missing_head=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  if git -C "$W" cat-file -e "$missing_head" 2>/dev/null; then fail 'fixture gate head exists locally'; fi
  branch=$(git -C "$W" symbolic-ref --short HEAD)
  printf 'running %s %.8s 2026-08-01 10:00\n' "$branch" "$missing_head" > "$C/nm-ledger"
  printf 'run:\n  id: "01ACTIVE"\n  branch: %s\n  status: running\n  head: "%s"\nbranch_sync:\n  state: pipeline_owned\n' \
    "$branch" "$missing_head" > "$C/nm-status"
  reason='finish or abort the original validation run'
  case "$validation" in
    pipeline-owned) ;;
    matching-live)
      printf 'run:\n  id: "01ACTIVE"\n  branch: %s\n  status: running\n  head: "%s"\n' \
        "$branch" "$(git -C "$W" rev-parse HEAD)" > "$C/nm-status"
      ;;
    ledger-live)
      printf 'running %s %s 2026-08-01 10:00\n' "$branch" "$(git -C "$W" rev-parse --short HEAD)" > "$C/nm-ledger"
      rm "$C/nm-status"
      ;;
    *)
      reason='cannot establish validation run ownership'
      case "$validation" in
        status-failure) touch "$C/nm-status-fail" ;;
        ledger-failure) touch "$C/nm-ledger-fail" ;;
        status-error) printf 'error: daemon unavailable\n' > "$C/nm-status" ;;
        partial) printf 'run:\n  id: "PARTIAL"\n' > "$C/nm-status" ;;
        unbound)
          printf 'run:\n  branch: %s\n  status: running\n  head: "%s"\n' "$branch" "$missing_head" > "$C/nm-status"
          ;;
        foreign-branch) printf 'run:\n  branch: foreign\n  status: running\n' > "$C/nm-status" ;;
      esac
      ;;
  esac
  assert_admission_refused "$reason"
  pass "validation $validation refuses before endpoint or allocation mutation"
done

make_case no-validation-run
branch=$(git -C "$W" symbolic-ref --short HEAD)
printf 'branch: %s\nhelp[1]:\n  No run on this branch\n' "$branch" > "$C/nm-status"
run_retirement
assert_preserved
pass 'branch with no validation run can accept a finite result'

make_case unresolved-parent
printf 'mate\n' > "$H/.fm-secondmate-home"
printf 'invalid parent record\n' > "$H/.fm-secondmate-parent"
assert_admission_refused 'cannot resolve allocation lock'
pass 'invalid delegated parent refuses before endpoint retirement'

if command -v tasks-axi >/dev/null 2>&1; then
  for public_home in main delegated; do
    make_case "public-$public_home"
    P=$H
    work_home=main
    if [ "$public_home" = delegated ]; then
      P="$C/primary"
      work_home=secondmate:mate
      mkdir -p "$P/state" "$P/data" "$P/config"
      printf 'mate\n' > "$H/.fm-secondmate-home"
      printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$P" > "$H/.fm-secondmate-parent"
      printf 'kind=secondmate\nhome=%s\n' "$H" > "$P/state/mate.meta"
      printf -- '- mate - synthetic (home: %s; scope: synthetic; projects: ; added 2026-08-01)\n' "$H" > "$P/data/secondmates.md"
    fi
    printf 'FMX_PAIRING_TOKEN=test-token\n' > "$P/.env"
    cp "$ROOT/.tasks.toml" "$P/.tasks.toml"
    printf '## In flight\n\n## Queued\n\n## Done\n' > "$P/data/backlog.md"
    printf '%s\n' '{"request_id":"req-finite","platform":"x","context_binding":{"version":"ctx1","value":"ctx1_finite"},"public_safe_summary":"finish the diagnosis","received_at":"2026-07-30T10:00:00Z","followup_expires_at":"2099-10-01T00:00:00Z","reservation_expires_at":"2099-10-01T00:00:00Z"}' > "$P/request.json"
    printf '%s\n' '{"type":"report-ready","project":"firstmate","required_deliverables":["report_path"],"completion_policy":"all-required"}' > "$P/expected.json"
    jq -nc --arg h "$work_home" '{relation_id:"rel-finite",work_ref:{home_id:$h,task_id:"finite"},role:"fulfills",required:true,generation:1}' > "$P/relation.json"
    (
      cd "$P"
      if [ "$public_home" = main ]; then
        tasks-axi add finite 'Accepted diagnosis; no fix shipped' >/dev/null
        tasks-axi start finite >/dev/null
      fi
      tasks-axi public-followup add pf-finite --request-context-file request.json \
        --purpose promised-final --expected-final-file expected.json --expires-at 2099-10-01T00:00:00Z >/dev/null
      tasks-axi public-followup bind-work pf-finite --relation-file relation.json >/dev/null
    )
    FM_HOME="$P" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-public-followup.sh" register pf-finite \
      --relation rel-finite --work-home "$work_home" --work-id finite --generation 1 >/dev/null
    cp "$P/data/backlog.md" "$C/public-backlog.before"
    assert_admission_refused 'still owes a public reply'
    assert_contains "$(cat "$C/out")" 'pending-work' 'pending public commitment was not inspected'
    cmp "$C/public-backlog.before" "$P/data/backlog.md"
    if [ "$public_home" = delegated ]; then
      printf 'kind=secondmate\nhome=%s\n' "$C/not-the-child" > "$P/state/mate.meta"
      assert_admission_refused 'cannot resolve the primary home'
      printf 'kind=secondmate\nhome=%s\n' "$H" > "$P/state/mate.meta"
    fi
    (cd "$P" && tasks-axi public-followup waive pf-finite --reason 'synthetic test approval' --approved-by captain >/dev/null)
    run_retirement
    assert_preserved
    [ ! -e "$H/state/finite.meta" ] || fail 'settled public commitment blocked retirement'
    pass "$public_home pending public commitment refuses until reconciled through its owner"
  done
fi

make_case success
fm_test_fake_stream_foreground "$target" deck
run_retirement
assert_preserved
[ ! -e "$H/state/finite.meta" ] || fail 'confirmed endpoint left live record'
cmp "$C/before.meta" "$H/data/finite/preserved-result/original.meta"
cmp "$C/result.md" "$H/data/finite/preserved-result/result.md"
[ "$(jq -r '.phase' "$H/data/finite/preserved-result/receipt.json")" = completed ] || fail 'missing completion'
[ "$(jq -r '.worktrees[0].leased' "$C/pool/treehouse-state.json")" = true ] || fail 'allocation not leased'
[ "$(fm_test_fake_stream_endpoints | jq -r --arg e "${target##*:}" '.endpoints[] | select(.endpoint_id == $e) | .closed_by')" = agent ] || fail 'endpoint did not confirm stop'
run_retirement
assert_preserved
if FM_HOME="$H" "$ROOT/bin/fm-teardown.sh" finite --force > "$C/cleanup" 2>&1; then fail 'ordinary force cleanup released retained allocation'; fi
if FM_HOME="$H" "$RETIRE" --finished finite > "$C/cleanup" 2>&1; then fail 'automatic retirement accepted retained allocation'; fi
if FM_HOME="$H" "$ROOT/bin/fm-control.sh" finite recover-missing > "$C/control" 2>&1; then fail 'recovery resumed retained work'; fi
pass 'accepted knowledge closes a confirmed live endpoint, preserves original dirty bytes/history/claim and converges on retry'

for mutation in wrong-task wrong-head wrong-result wrong-incarnation allocation-change wrong-slot foreign-lease missing-endpoint foreign-endpoint unconfirmed; do
  make_case "$mutation"
  case "$mutation" in
    wrong-task) jq '.task="other"' "$C/acceptance.json" > "$C/change"; mv "$C/change" "$C/acceptance.json" ;;
    wrong-head) jq '.head="deadbeef"' "$C/acceptance.json" > "$C/change"; mv "$C/change" "$C/acceptance.json" ;;
    wrong-result) printf 'changed' >> "$C/result.md" ;;
    wrong-incarnation) jq '.spawn_gen="replacement"' "$C/acceptance.json" > "$C/change"; mv "$C/change" "$C/acceptance.json" ;;
    allocation-change) jq '.worktrees[0].owner_pid=123' "$C/pool/treehouse-state.json" > "$C/change"; mv "$C/change" "$C/pool/treehouse-state.json" ;;
    missing-endpoint) fm_test_fake_stream_set "$target" '{"forget":true}' ;;
    foreign-endpoint)
      fm_test_fake_stream_set "$target" '{"forget":true}'
      curl -fsS -m 10 --config <(printf 'header = "Authorization: Bearer %s"\n' "$FM_STREAM_TOKEN") \
        -X POST -H 'Content-Type: application/json' --data-binary \
        "$(jq -nc --arg e "${target##*:}" --arg c "$W" '{endpoint_id:$e,machine:"fake-box",label:"fm-other",cwd:$c,replace_label:true}')" \
        "$FM_TEST_STREAM_URL/v1/agent/endpoints" >/dev/null
      ;;
    wrong-slot) printf 'task=other\nhome=%s\n' "$H" > "$C/pool/1/.fm-slot-owner" ;;
    foreign-lease) jq '.worktrees[0] += {leased:true,lease_id:"foreign",lease_holder:"other"}' "$C/pool/treehouse-state.json" > "$C/change"; mv "$C/change" "$C/pool/treehouse-state.json" ;;
    unconfirmed) fm_test_fake_stream_set "$target" '{"kill_undelivered":true}' ;;
  esac
  if [ "$mutation" = wrong-slot ]; then
    if run_retirement > "$C/out" 2>&1; then fail 'wrong slot accepted'; fi
    cmp "$C/before.meta" "$H/state/finite.meta"
    continue
  fi
  expect_refusal
  if [ "$mutation" = unconfirmed ]; then
    [ -f "$H/state/finite.preserved-result" ] || fail 'failed stop lost retention marker'
    fm_test_fake_stream_set "$target" '{"closed_by":"agent"}'
    run_retirement
    assert_preserved
  fi
  pass "$mutation refuses safely; unconfirmed stop can restart from preserved evidence"
done

# A prepared journal survives a process exit before endpoint stop.
make_case interrupted
python3 "$ROOT/bin/fm_preserved_result.py" prepare "$H/state" "$H/data" finite "$C/acceptance.json" "$H/state/finite.meta"
run_retirement
assert_preserved
pass 'prepared retention journal survives a process restart before endpoint stop'

# The existing fused journal recovers a confirmed stop followed by a failed
# backlog mutation, including the window after live metadata has been removed.
if command -v tasks-axi >/dev/null 2>&1; then
  make_case backlog
  real_tasks=$(command -v tasks-axi)
  printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n' > "$H/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$H/data/backlog.md"
  tasks-axi add finite 'Accepted inconclusive diagnosis, not code shipped' --file "$H/data/backlog.md" >/dev/null
  tasks-axi start finite --file "$H/data/backlog.md" >/dev/null
  mkdir "$C/failing-bin"
  cat > "$C/failing-bin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = done ] && [ ! -f "$C/allow-done" ]; then
  echo 'synthetic post-stop backlog failure' >&2
  exit 1
fi
exec "$real_tasks" "\$@"
SH
  chmod +x "$C/failing-bin/tasks-axi"
  if PATH="$C/failing-bin:$PATH" run_retirement > "$C/failure" 2>&1; then fail 'backlog failure was hidden'; fi
  [ -f "$H/state/finite.backlog-close" ] || fail 'missing replayable close journal'
  assert_preserved
  touch "$C/allow-done"
  PATH="$C/failing-bin:$PATH" run_retirement
  tasks-axi show finite --file "$H/data/backlog.md" --full > "$C/row"
  assert_contains "$(cat "$C/row")" 'done' 'knowledge outcome did not close backlog'
  assert_contains "$(cat "$C/row")" 'data/finite/report.md' 'backlog lost durable result'
  [ ! -e "$H/state/finite.backlog-close" ] || fail 'completion journal did not converge'
  assert_preserved
  pass 'post-stop backlog failure/restart links the knowledge result without claiming code landed'
fi

make_case superseded
jq '.outcome="superseded" | .summary="Obsolete non-equivalent original work; no landing claimed"' "$C/acceptance.json" > "$C/change"
mv "$C/change" "$C/acceptance.json"
run_retirement
assert_preserved
[ "$(jq -r '.outcome' "$H/data/finite/preserved-result/receipt.json")" = superseded ] || fail 'obsolete outcome lost'
pass 'superseded originals retain non-equivalent commits without shipping them'

# Installed-tool integration: a CLEAN, ALREADY LANDED original would otherwise
# be disposable. The durable lease alone must exclude it from reuse and sweeps.
if [ -n "$REAL_TREEHOUSE" ] && [ "$("$REAL_TREEHOUSE" --version)" = v2.3.0 ]; then
  make_case native
  original_w=$W
  printf 'max_trees = 4\n' > "$C/project/treehouse.toml"
  allocated=$(cd "$C/project" && "$REAL_TREEHOUSE" --root "$C/native" get --lease --no-fetch --lease-holder fixture-spare)
  native_pool=$(dirname "$(dirname "$allocated")")
  W="$native_pool/999/project"
  mkdir -p "$(dirname "$W")"
  git -C "$C/project" worktree move "$original_w" "$W"
  cp "$C/pool/1/.fm-slot-owner" "$native_pool/999/.fm-slot-owner"
  git -C "$W" add -f source second staged artifact ignored .gitignore
  git -C "$W" commit -qm 'fixture fully landed'
  git -C "$C/project" merge --ff-only "original-native" >/dev/null
  python3 - "$C" "$H" "$W" "$native_pool" "$original_w" <<'PY'
import pathlib,sys,json,hashlib,subprocess
c,h,w,p,old=map(pathlib.Path,sys.argv[1:])
state=json.loads((p/'treehouse-state.json').read_text())
entry=dict(name='999',path=str(w),owner_pid=0)
state['worktrees'].append(entry)
(p/'treehouse-state.json').write_text(json.dumps(state))
m=h/'state/finite.meta';m.write_text(m.read_text().replace(str(old),str(w)))
a=json.loads((c/'acceptance.json').read_text());a.update(allocation=entry,head=subprocess.check_output(['git','-C',str(w),'rev-parse','HEAD']).decode().strip(),meta_sha256=hashlib.sha256(m.read_bytes()).hexdigest())
(c/'acceptance.json').write_text(json.dumps(a))
PY
  run_retirement
  (cd "$C/project" && "$REAL_TREEHOUSE" --root "$C/native" prune --yes) > "$C/prune"
  [ -d "$W" ] || fail 'native prune removed retained original'
  next=$(cd "$C/project" && "$REAL_TREEHOUSE" --root "$C/native" get --lease --no-fetch --lease-holder fixture-next)
  [ "$next" != "$W" ] || fail 'native allocator reused retained original'
  "$REAL_TREEHOUSE" destroy "$native_pool" --all --yes > "$C/destroy"
  [ -d "$W" ] || fail 'native bulk destroy removed retained original'
  [ "$(git -C "$W" rev-parse HEAD)" = "$(jq -r '.head' "$C/acceptance.json")" ] || fail 'native sweeps changed original head'
  pass 'Treehouse v2.3.0 get, prune and bulk destroy retain even clean already-landed original allocation'
else
  printf 'skip: installed Treehouse v2.3.0 integration unavailable\n'
fi
