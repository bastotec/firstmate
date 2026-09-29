#!/usr/bin/env bash
# Opt-in credentialed Pi continuity regression on a private tmux socket and
# isolated project/home state. It uses the existing shared Pi auth store without
# copying credentials and pins the captain-approved openai-codex model.
# FM_PI_LIVE_RENDER_ONLY=1 selects the supervision-tool rendering case only;
# FM_PI_RENDER_EVIDENCE_DIR retains terminal captures and the live HTML export.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_PI_LIVE_RENDER_ONLY:-0}" = 1 ]; then
  fm_live_gate opt-in FM_PI_LIVE_E2E pi tmux npm node jq
else
  fm_live_gate opt-in FM_PI_LIVE_E2E pi tmux
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset NO_MISTAKES_GATE

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

TMUX=$(command -v tmux)
SOCKET="fm-pi-live-e2e-$$"
SOCKET_FLAG=-L
if [ "${FM_PI_LIVE_RENDER_ONLY:-0}" = 1 ]; then
  # Relative Unix socket avoids sockaddr_un's path limit in long gate paths.
  SOCKET=".pi-render-$$.sock"
  SOCKET_FLAG=-S
fi
SESSION=pi-live-e2e
LAB="$ROOT/.pi-live-e2e.$$"
PROJECT="$LAB/project"
AHOY_PROJECT="$LAB/ahoy-project"
HOME_DIR="$LAB/fmhome"
PI_VERSION=$(pi --version)
# shellcheck source=/dev/null
. "$ROOT/bin/fm-operational-input.sh"
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
LEGACY_START='Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
LEGACY_AWAY=$'\xE2\x81\xA3Supervisor escalate (1 event(s)): done: legacy rollout'
MARKER_NEAR_MISS=$'\xE2\x81\xA3Captain note: this invisible separator is intentional.'
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
START_NEAR_MISS='Captain quote: Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions.'
fm_operational_input_encode watcher "CURRENT_AHOY_WATCHER_BODY" CURRENT_WATCHER \
  || fail "could not construct current Ahoy watcher fixture"
QUOTED_CURRENT="Captain quote: $CURRENT_WATCHER"
ASCII_ONLY='FIRSTMATE_OP: v1 watcher: captain-authored text'

capture() {
  "$TMUX" "$SOCKET_FLAG" "$SOCKET" capture-pane -p -t "$SESSION" -S -600 2>/dev/null || true
}

wait_for_text() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    if capture | grep -Fq "$expected"; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

wait_for_exact_line() {
  local expected=$1 attempts=${2:-120} i=0
  while [ "$i" -lt "$attempts" ]; do
    if capture | grep -Fxq " $expected"; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  capture >&2
  return 1
}

lab_pid_is_safe() {
  local pid=$1 command
  command=$(ps -p "$pid" -o command= 2>/dev/null || true)
  case "$command" in
    *"$LAB"*) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup() {
  local pid_file watcher_pid arm_pid
  pid_file=$(find "$HOME_DIR/state" -maxdepth 3 -type f -name pid 2>/dev/null | head -1 || true)
  watcher_pid=
  arm_pid=
  if [ -n "$pid_file" ]; then
    watcher_pid=$(sed -n '1p' "$pid_file" 2>/dev/null || true)
    arm_pid=$(ps -p "$watcher_pid" -o ppid= 2>/dev/null | tr -d ' ' || true)
  fi
  "$TMUX" "$SOCKET_FLAG" "$SOCKET" kill-server 2>/dev/null || true
  sleep 0.1
  if [ -n "$watcher_pid" ] && lab_pid_is_safe "$watcher_pid"; then
    kill -TERM "$watcher_pid" 2>/dev/null || true
  fi
  if [ -n "$arm_pid" ] && lab_pid_is_safe "$arm_pid"; then
    kill -TERM "$arm_pid" 2>/dev/null || true
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT

send_prompt() {
  local prompt=$1
  "$TMUX" "$SOCKET_FLAG" "$SOCKET" send-keys -t "$SESSION" -l "$prompt"
  "$TMUX" "$SOCKET_FLAG" "$SOCKET" send-keys -t "$SESSION" Enter
}

wait_pid_dead() {
  local pid=$1 i=0
  while [ "$i" -lt 50 ]; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

run_ahoy_case() {
  local label=$1 preceding=$2 expected=$3 out status=0
  out=$(
    cd "$PROJECT" &&
      pi --print --approve --no-session --no-context-files --no-extensions \
        --no-skills --skill .agents/skills --tools read \
        --model openai-codex/gpt-5.6-sol --thinking low \
        "$preceding" "/ahoy"
  ) || status=$?
  [ "$status" -eq 0 ] || fail "Pi Ahoy $label case exited $status: $out"
  case "$expected" in
    bearings)
      printf '%s\n' "$out" | grep -Fq "AHOY_BEARINGS_BRANCH" \
        || fail "Pi Ahoy $label case did not take Bearings: $out"
      ;;
    boundary)
      printf '%s\n' "$out" | grep -Fq "AHOY_BEARINGS_BRANCH" \
        && fail "Pi Ahoy $label near miss was treated as operational: $out"
      ;;
  esac
}

run_ahoy_transcript_regressions() {
  mkdir -p "$PROJECT/.agents/skills/ahoy" "$PROJECT/.agents/skills/bearings"
  cp "$ROOT/.agents/skills/ahoy/SKILL.md" "$PROJECT/.agents/skills/ahoy/SKILL.md"
  # shellcheck disable=SC2016 # Backticks are literal prompt markup.
  printf '%s\n' \
    '---' \
    'name: bearings' \
    'description: Test-only Bearings branch sentinel.' \
    '---' \
    '' \
    '# bearings' \
    '' \
    'Respond exactly `AHOY_BEARINGS_BRANCH`.' \
    > "$PROJECT/.agents/skills/bearings/SKILL.md"

  run_ahoy_case legacy-start "$LEGACY_START" bearings
  run_ahoy_case legacy-away "$LEGACY_AWAY" bearings
  run_ahoy_case marker-near-miss "$MARKER_NEAR_MISS" boundary
  run_ahoy_case startup-near-miss "$START_NEAR_MISS" boundary
  run_ahoy_case quoted-current "$QUOTED_CURRENT" boundary
  run_ahoy_case ascii-only "$ASCII_ONLY" boundary
}

run_native_ahoy_regressions() {
  local first_home="$LAB/pi-ahoy-first-home"
  local later_home="$LAB/pi-ahoy-later-home"
  local first_out later_out

  mkdir -p \
    "$AHOY_PROJECT/.pi/extensions/lib" \
    "$AHOY_PROJECT/.agents/skills/ahoy" \
    "$AHOY_PROJECT/.agents/skills/bearings" \
    "$AHOY_PROJECT/bin" \
    "$first_home/state" "$first_home/config" \
    "$later_home/state" "$later_home/config"
  git init -q "$AHOY_PROJECT"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$AHOY_PROJECT/.pi/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$AHOY_PROJECT/.pi/extensions/lib/"
  cp \
    "$ROOT/bin/fm-sessionstart-nudge.sh" \
    "$ROOT/bin/fm-primary-scope-lib.sh" \
    "$ROOT/bin/fm-gate-refuse-lib.sh" \
    "$ROOT/bin/fm-operational-input.sh" \
    "$AHOY_PROJECT/bin/"
  cp "$ROOT/.agents/skills/ahoy/SKILL.md" "$AHOY_PROJECT/.agents/skills/ahoy/SKILL.md"
  chmod +x "$AHOY_PROJECT/bin/fm-sessionstart-nudge.sh"
  # shellcheck disable=SC2016 # Variables expand in the generated script, not this test shell.
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -u' \
    'file="${FM_HOME:?}/state/session-start-count"' \
    'count=0' \
    '[ ! -f "$file" ] || count=$(sed -n "1p" "$file")' \
    'count=$((count + 1))' \
    'printf "%s\n" "$count" > "$file"' \
    'printf "SESSION_START_DONE count=%s\n" "$count"' \
    > "$AHOY_PROJECT/bin/fm-session-start.sh"
  chmod +x "$AHOY_PROJECT/bin/fm-session-start.sh"
  # shellcheck disable=SC2016 # Backticks are literal prompt markup.
  printf '%s\n' \
    '---' \
    'name: bearings' \
    'description: Test-only Bearings branch sentinel.' \
    '---' \
    '' \
    '# bearings' \
    '' \
    'Respond exactly `AHOY_BEARINGS_BRANCH`.' \
    > "$AHOY_PROJECT/.agents/skills/bearings/SKILL.md"
  # shellcheck disable=SC2016 # Backticks are literal prompt markup.
  printf '%s\n' \
    '# Native Pi Ahoy regression fixture' \
    '' \
    'Run `bin/fm-session-start.sh` exactly once at session start.' \
    > "$AHOY_PROJECT/AGENTS.md"

  first_out=$(
    cd "$AHOY_PROJECT" &&
      FM_HOME="$first_home" pi --print --approve --no-session --no-context-files --no-extensions \
        -e .pi/extensions/fm-primary-turnend-guard.ts \
        --no-skills --skill .agents/skills \
        --model openai-codex/gpt-5.6-sol --thinking low \
        "/ahoy"
  )
  printf '%s\n' "$first_out" | grep -Fq "AHOY_BEARINGS_BRANCH" \
    || fail "Pi native first-message Ahoy did not take Bearings: $first_out"
  [ "$(sed -n '1p' "$first_home/state/session-start-count")" = 1 ] \
    || fail "Pi native first-message Ahoy did not preserve one session-start execution"

  later_out=$(
    cd "$AHOY_PROJECT" &&
      FM_HOME="$later_home" pi --print --approve --no-session --no-context-files --no-extensions \
        -e .pi/extensions/fm-primary-turnend-guard.ts \
        --no-skills --skill .agents/skills \
        --model openai-codex/gpt-5.6-sol --thinking low \
        "Respond exactly PRIOR_BOUNDARY_ACK." "/ahoy"
  )
  printf '%s\n' "$later_out" | grep -Fq "PRIOR_BOUNDARY_ACK" \
    || fail "Pi native later-message setup did not preserve the genuine captain boundary: $later_out"
  printf '%s\n' "$later_out" | grep -Fq "AHOY_BEARINGS_BRANCH" \
    && fail "Pi native later-message Ahoy gathered Bearings: $later_out"
  [ "$(sed -n '1p' "$later_home/state/session-start-count")" = 1 ] \
    || fail "Pi native later-message Ahoy reran session start"
}

# Focused rendering probe; shares this rig's private terminal and cleanup, but
# never launches a worker, secondmate, watcher, or credential-refresh command.
run_outcome_rendering_regression() {
  local package_dir agent_dir auth_dir evidence pane attempt
  package_dir=${FM_PI_PACKAGE_DIR:-"$(npm root -g)/@earendil-works/pi-coding-agent"}
  agent_dir="$LAB/agent-dir"
  auth_dir=${PI_CODING_AGENT_DIR:-"$HOME/.pi/agent"}
  evidence=${FM_PI_RENDER_EVIDENCE_DIR:-"$LAB/evidence"}
  mkdir -p "$PROJECT/.pi/extensions" "$HOME_DIR/state" "$HOME_DIR/config" "$agent_dir" "$evidence"
  cp -R "$ROOT/.pi/extensions/lib" "$PROJECT/.pi/extensions/"
  cp "$ROOT/.pi/extensions/fm-calm.ts" "$ROOT/.pi/extensions/fm-branch-supervision.ts" "$PROJECT/.pi/extensions/"
  cp -R "$ROOT/bin" "$PROJECT/bin"
  printf 'off\n' > "$HOME_DIR/config/calm"
  printf '0\n' > "$HOME_DIR/state/.branch-outcomes-processed"
  # More than Pi's collapsed preview: only expansion should expose the tail.
  local index
  for index in {1..12}; do
    FM_HOME="$HOME_DIR" "$ROOT/bin/fm-branch-outcome.sh" append --task render-probe --verdict routine \
      --summary "$(printf 'LIVE_OUTCOME_%02d' "$index")" >/dev/null
  done
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-branch-outcome.sh" append --task render-probe --verdict captain \
    --summary LIVE_CAPTAIN_PROCESSED >/dev/null

  # Read the existing credentials and model configuration by reference. The
  # vendor read-only store refuses refreshes instead of writing shared auth.
  # All other CLI state (settings, cache, session, trust) belongs to this lab.
  cat > "$LAB/readonly-cli.mjs" <<'JS'
import { pathToFileURL } from "node:url";
const pkg = process.env.FM_PI_PACKAGE_DIR;
const { ModelRuntime } = await import(pathToFileURL(`${pkg}/dist/core/model-runtime.js`).href);
const { ReadOnlyAuthStorage } = await import(pathToFileURL(`${pkg}/dist/core/auth-storage.js`).href);
const create = ModelRuntime.create.bind(ModelRuntime);
ModelRuntime.create = (options = {}) => create({
  ...options,
  credentials: new ReadOnlyAuthStorage(`${process.env.FM_PI_AUTH_DIR}/auth.json`),
  modelsPath: `${process.env.FM_PI_AUTH_DIR}/models.json`,
  allowModelNetwork: false,
});
await import(pathToFileURL(`${pkg}/dist/cli.js`).href);
JS
  cat > "$PROJECT/.pi/extensions/render-probe.ts" <<'TS'
import { appendFileSync, writeFileSync } from "node:fs";
import { VERSION } from "@earendil-works/pi-coding-agent";
import branch from "./fm-branch-supervision.ts";
export default function (pi) {
  const log = (record) => appendFileSync(`${process.env.FM_PI_RENDER_EVIDENCE_DIR}/events.jsonl`, `${JSON.stringify(record)}\n`);
  let exporting = false;
  pi.events.on("firstmate:calm-presentation", (state) => { exporting = state.stockExportRendering; });
  pi.on("session_start", (_event, ctx) => {
    writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
    log({ type: "model", version: VERSION, provider: ctx.model?.provider, model: ctx.model?.id });
  });
  // Pi swallows renderer exceptions; observe the real registered callbacks
  // without replacing their components or manufacturing tool results.
  branch({ ...pi, registerTool(tool) {
    for (const slot of ["renderCall", "renderResult"]) {
      const render = tool[slot];
      if (!render) continue;
      tool[slot] = (...args) => {
        try {
          const result = render(...args);
          log({ type: "render", tool: tool.name, slot, exporting });
          return result;
        } catch (error) {
          log({ type: "render-error", tool: tool.name, slot, exporting, message: String(error) });
          throw error;
        }
      };
    }
    pi.registerTool(tool);
  } });
  pi.on("tool_call", (event) => { log({ type: "tool_call", tool: event.toolName, args: event.input }); });
  pi.on("tool_result", (event) => { log({ type: "tool_result", tool: event.toolName, content: event.content, isError: event.isError }); });
}
TS
  : > "$evidence/events.jsonl"
  : > "$evidence/terminal-write.log"
  "$TMUX" "$SOCKET_FLAG" "$SOCKET" new-session -d -x 100 -y 160 -s "$SESSION" -c "$PROJECT" \
    "env FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' PI_CODING_AGENT_DIR='$agent_dir' FM_PI_AUTH_DIR='$auth_dir' FM_PI_PACKAGE_DIR='$package_dir' FM_PI_RENDER_EVIDENCE_DIR='$evidence' PI_OFFLINE=1 PI_TELEMETRY=0 PI_TUI_WRITE_LOG='$evidence/terminal-write.log' node '$LAB/readonly-cli.mjs' --approve --session-dir '$LAB/sessions' --no-context-files --no-extensions --no-skills --no-prompt-templates --no-themes -e .pi/extensions/fm-calm.ts -e .pi/extensions/render-probe.ts --tools fm_branch_outcomes,fm_branch_processed --model openai-codex/gpt-5.6-sol --thinking low --tui-mode regular --append-system-prompt 'This is an isolated primary-session rendering test. For each supervision processing request, call fm_branch_outcomes with recent 1, then fm_branch_processed through the highest listed sequence. Do not repeat the outcome text in your reply. Finish with PRIMARY_RENDER_ACK.'; rc=\$?; printf 'PI_EXIT=%s\n' \"\$rc\"; sleep 300"

  wait_for_text "PRIMARY_RENDER_ACK" 240 || fail "primary Pi did not complete the live outcome processing request"
  wait_for_text "processed through seq 13" 60 || fail "live acknowledgement result was not rendered"
  [ "$(< "$HOME_DIR/state/.branch-outcomes-processed")" = 13 ] || fail "live model did not acknowledge the durable captain outcome"
  send_prompt "Call fm_branch_outcomes with recent 20, then reply exactly PRIMARY_OUTCOMES_ACK without repeating any outcome text."
  wait_for_exact_line "PRIMARY_OUTCOMES_ACK" 240 || fail "primary Pi did not execute the outcome read"
  capture > "$evidence/collapsed.txt"
  "$TMUX" "$SOCKET_FLAG" "$SOCKET" capture-pane -ep -t "$SESSION" -S -600 > "$evidence/collapsed.ansi"
  pane=$(capture)
  # The separate captain entry is always complete; inspect only the read row.
  pane=${pane##*fm_branch_outcomes}
  printf '%s\n' "$pane" | grep -Fq "to expand" || fail "Calm-off result lacked Pi's expansion hint"
  printf '%s\n' "$pane" | grep -Fq '"seq":12' && fail "collapsed tool preview exposed its tail"
  "$TMUX" "$SOCKET_FLAG" "$SOCKET" send-keys -t "$SESSION" C-o
  wait_for_text '"seq":12' 60 || fail "expanded tool result did not arrive"
  capture > "$evidence/expanded.txt"
  "$TMUX" "$SOCKET_FLAG" "$SOCKET" capture-pane -ep -t "$SESSION" -S -600 > "$evidence/expanded.ansi"
  pane=$(capture)
  pane=${pane##*fm_branch_outcomes}
  printf '%s\n' "$pane" | grep -Fq '"seq":12' || fail "expanding the real tool row did not reveal its tail"

  send_prompt "/calm"
  for attempt in {1..60}; do
    "$TMUX" "$SOCKET_FLAG" "$SOCKET" capture-pane -p -t "$SESSION" > "$evidence/calm.txt"
    if ! grep -Eq '"seq":12|^ fm_branch_outcomes$|processed through seq 13' "$evidence/calm.txt"; then
      break
    fi
    sleep 0.5
  done
  grep -Fq '"seq":12' "$evidence/calm.txt" && fail "Calm left the outcome tool result visible"
  grep -Fxq ' fm_branch_outcomes' "$evidence/calm.txt" && fail "Calm left the outcome tool call visible"
  grep -Fq "processed through seq 13" "$evidence/calm.txt" && fail "Calm left the acknowledgement row visible"
  send_prompt "/export $evidence/session.html"
  wait_for_text "Session exported to:" 60 || fail "live Pi did not export its session"
  [ -s "$evidence/session.html" ] || fail "live session HTML was not created"
  send_prompt "/calm"
  wait_for_text "processed through seq 13" 60 || fail "Calm-off did not restore acknowledgement rendering"
  wait_for_text '"seq":12' 60 || fail "Calm-off did not restore outcome rendering"
  capture > "$evidence/restored.txt"
  send_prompt "/quit"
  wait_for_text "PI_EXIT=0" 60 || fail "rendering probe did not exit cleanly"

  # Assert the serialized session/export interfaces, not implementation text.
  FM_PI_RENDER_EVIDENCE_DIR="$evidence" node --input-type=module <<'JS'
import { readFileSync } from "node:fs";
const root = process.env.FM_PI_RENDER_EVIDENCE_DIR;
const events = readFileSync(`${root}/events.jsonl`, "utf8").trim().split("\n").map(JSON.parse);
const model = events.find((event) => event.type === "model");
if (model?.provider !== "openai-codex" || model?.model !== "gpt-5.6-sol") throw new Error(`unexpected actual model: ${JSON.stringify(model)}`);
for (const tool of ["fm_branch_outcomes", "fm_branch_processed"]) {
  if (!events.some((event) => event.type === "tool_call" && event.tool === tool)) throw new Error(`model never called ${tool}`);
  if (!events.some((event) => event.type === "tool_result" && event.tool === tool && !event.isError)) throw new Error(`no successful live result for ${tool}`);
  for (const slot of ["renderCall", "renderResult"]) {
    if (!events.some((event) => event.type === "render" && event.tool === tool && event.slot === slot && !event.exporting)) throw new Error(`live ${tool} ${slot} never succeeded`);
  }
}
const unexpected = events.filter((event) => event.type === "render-error" && !(event.exporting && event.message === "Error: Use Pi stock export rendering"));
if (unexpected.length) throw new Error(`renderer exception fallback: ${JSON.stringify(unexpected)}`);
const html = readFileSync(`${root}/session.html`, "utf8");
const match = html.match(/<script id="session-data" type="application\/json">([^<]+)<\/script>/);
if (!match) throw new Error("export did not contain Pi's session-data interface");
const exported = JSON.parse(Buffer.from(match[1], "base64").toString("utf8"));
const messages = exported.entries.filter((entry) => entry.type === "message").map((entry) => entry.message);
for (const tool of ["fm_branch_outcomes", "fm_branch_processed"]) {
  if (!messages.some((message) => message.role === "toolResult" && message.toolName === tool && !message.isError)) throw new Error(`HTML export lost real ${tool} result`);
}
if (!messages.some((message) => message.role === "assistant" && message.provider === model.provider && message.model === model.model && message.content.some((part) => part.type === "toolCall"))) throw new Error("export did not retain real tool calls from the selected model");
console.log(`ok - Pi ${model.version} live primary rendering, expansion, acknowledgement, Calm toggle and HTML export (${model.provider}/${model.model})`);
JS
}

if [ "${FM_PI_LIVE_RENDER_ONLY:-0}" = 1 ]; then
  run_outcome_rendering_regression
  exit $?
fi

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
run_ahoy_transcript_regressions
run_native_ahoy_regressions
mkdir -p "$PROJECT/.pi/extensions/lib"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$PROJECT/.pi/extensions/fm-calm.ts"
cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$PROJECT/.pi/extensions/fm-primary-pi-watch.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-assistant-layout.ts" "$PROJECT/.pi/extensions/lib/fm-calm-assistant-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-operational-user-layout.ts" "$PROJECT/.pi/extensions/lib/fm-calm-operational-user-layout.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$PROJECT/.pi/extensions/lib/fm-calm-visibility.ts"
cp "$ROOT/.pi/extensions/lib/fm-calm-working-ship.ts" "$PROJECT/.pi/extensions/lib/fm-calm-working-ship.ts"
cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$PROJECT/.pi/extensions/lib/fm-branch-dispatch.ts"
cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$PROJECT/.pi/extensions/lib/fm-native-contract.ts"
cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$PROJECT/.pi/extensions/lib/fm-async-exec.ts"
cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$PROJECT/.pi/extensions/lib/fm-operational-input.ts"
cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$PROJECT/.pi/extensions/fm-primary-turnend-guard.ts"
cp "$ROOT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-watch-arm.sh"
cp "$ROOT/bin/fm-operational-input.sh" "$PROJECT/bin/fm-operational-input.sh"
cp "$ROOT/bin/fm-supervision-instructions.sh" "$PROJECT/bin/fm-supervision-instructions.sh"
chmod +x "$PROJECT/bin/fm-operational-input.sh"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"

"$TMUX" "$SOCKET_FLAG" "$SOCKET" new-session -d -s "$SESSION" -c "$PROJECT" \
  "env FM_HOME='$HOME_DIR' FM_ROOT_OVERRIDE='$PROJECT' FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=600 bash -lc 'printf \"%s\\n\" \"\$\$\" > \"\$FM_HOME/state/.lock\"; pi --approve --no-session --no-context-files --no-extensions -e .pi/extensions/fm-calm.ts -e .pi/extensions/fm-primary-turnend-guard.ts -e .pi/extensions/fm-primary-pi-watch.ts --model openai-codex/gpt-5.6-sol --thinking low; rc=\$?; printf \"PI_EXIT=%s\\n\" \"\$rc\"; sleep 300'"

i=0
while [ "$i" -lt 120 ]; do
  [ -f "$HOME_DIR/state/.pi-turnend-extension-loaded" ] && [ -f "$HOME_DIR/state/.pi-watch-extension-loaded" ] && break
  sleep 0.5
  i=$((i + 1))
done
[ -f "$HOME_DIR/state/.pi-turnend-extension-loaded" ] || fail "Pi turn-end extension did not load"
[ -f "$HOME_DIR/state/.pi-watch-extension-loaded" ] || fail "Pi watcher extension did not load"
wait_for_text "(openai-codex)" 120 || fail "Pi did not reach its ready composer"
sleep 1

send_prompt "/calm"
sleep 0.2
send_prompt "Reply exactly CALM_LIVE_WORKING_VISIBLE"
i=0
while [ "$i" -lt 240 ]; do
  pane=$(capture)
  if printf '%s\n' "$pane" | grep -Fq '╲▁▁▁╱'; then
    break
  fi
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$pane" | grep -Fq '╲▁▁▁╱' \
  || fail "Calm did not show the working ship on the credentialed provider path"
printf '%s\n' "$pane" | grep -Fq "Working..." \
  && fail "Calm left Pi's stock working row visible on the credentialed provider path"
wait_for_exact_line "CALM_LIVE_WORKING_VISIBLE" 120 \
  || fail "Pi did not settle the Calm working-ship provider probe"
pane=$(capture)
printf '%s\n' "$pane" | grep -Fq '╲▁▁▁╱' \
  && fail "Calm left the working ship on screen after the run settled"
printf '%s\n' "$pane" | grep -Fq "calm transcript" \
  && fail "Calm added a persistent Calm status row on the credentialed provider path"
send_prompt "/calm"
sleep 0.2

: > "$HOME_DIR/state/pi-e2e.meta"
send_prompt "Start supervision with fm_watch_arm_pi and never use bash to arm supervision. After the watcher wake arrives, run bin/fm-wake-drain.sh and reply exactly HANDLED."
wait_for_text "watcher: started Pi extension arm child 1" || fail "Pi did not render the initial watcher tool result"

printf 'done: pi live e2e watcher fire\n' > "$HOME_DIR/state/pi-e2e.status"
i=0
while [ "$i" -lt 240 ]; do
  grep -Eq 'reason=actionable-signal.*successor=started:[0-9]+' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null && break
  sleep 0.5
  i=$((i + 1))
done
grep -Eq 'reason=actionable-signal.*successor=started:[0-9]+' "$HOME_DIR/state/.watch-cycle-exits.log" 2>/dev/null \
  || fail "Pi extension did not start and ledger-link a successor after the actionable close"
wait_for_exact_line "HANDLED" 120 || fail "Pi did not drain and settle after its extension-owned successor started"

pane=$(capture)
guard_count=$(printf '%s\n' "$pane" | grep -Fc "TURN WOULD END BLIND - supervision is off." || true)
[ "$guard_count" -eq 0 ] || fail "successor was not protecting Pi before its next turn end (guard count $guard_count)"
foreground_arm='$ bin/fm-watch-arm.sh'
if printf '%s\n' "$pane" | grep -Fq "$foreground_arm"; then
  fail "Pi used a foreground bash watcher arm"
fi
arm_tool_result_count=$(printf '%s\n' "$pane" | grep -Ec 'watcher: (started|unchanged|not armed|read-only)' || true)
[ "$arm_tool_result_count" -eq 1 ] || fail "Pi model re-armed from memory instead of the extension (tool-result count $arm_tool_result_count)"

pid_file=$(find "$HOME_DIR/state" -maxdepth 3 -type f -name pid | head -1)
[ -n "$pid_file" ] || fail "re-armed watcher pid was not recorded"
watcher_pid=$(sed -n '1p' "$pid_file")
arm_pid=$(ps -p "$watcher_pid" -o ppid= | tr -d ' ')
[ -n "$arm_pid" ] || fail "re-armed watcher parent was not live"

"$TMUX" "$SOCKET_FLAG" "$SOCKET" send-keys -t "$SESSION" -l '/quit'
sleep 1
"$TMUX" "$SOCKET_FLAG" "$SOCKET" send-keys -t "$SESSION" Enter
wait_for_text "PI_EXIT=0" 60 || fail "Pi did not exit cleanly"
wait_pid_dead "$watcher_pid" || fail "watcher child survived clean Pi exit"
wait_pid_dead "$arm_pid" || fail "arm child survived clean Pi exit"

printf 'ok - Pi %s live E2E covered the Calm working ship, Ahoy first/later messages, legacy transcripts, near misses, and watcher continuity\n' "$PI_VERSION"
