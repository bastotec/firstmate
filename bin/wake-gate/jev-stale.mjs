// Read a stuck-worker alarm's evidence with Jev (typesafe-ai/jev) through AI SDK
// 7's experimental_evaluate on the Vercel AI Gateway. bin/fm-wake-gate.sh is the
// only caller and owns every policy decision (which alarms are gate-able, the
// thresholds, the rule that combines the answers, shadow versus enforce, and the
// silence backstop); this helper only turns evidence text into four independent
// probabilities, asked together in one request.
//
// Input: the file named by the first argument (stdin when absent), one JSON
// object {"alarm": "<reason line>", "evidence": [{"command": "...", "output": "..."}]}.
// Output (stdout), tab-separated: a first row
//   usage<TAB><calls><TAB><input-tokens><TAB><output-tokens><TAB><ms>
// then one row
//   answers<TAB><actively_working><TAB><waiting_on_someone><TAB><shows_failure><TAB><finished_idle>
// Failure: one row "error<TAB><reason>" and a nonzero exit; the caller escalates.
//
// The key is read at call time from the secrets file (FM_WAKE_GATE_SECRETS,
// default ~/.secrets) under the variable named by FM_WAKE_GATE_KEY_VAR, which has
// no default. The file is parsed, never executed, and the key value is never
// printed. Only the evidence and the fixed questions below are sent to the vendor.
// FM_WAKE_GATE_TIMEOUT_MS bounds the call (default 6000).
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { pathToFileURL } from 'node:url';

export const MODEL_ID = 'typesafe-ai/jev';
export const MAX_OUTPUT_CHARS = 1500;
export const MAX_EVIDENCE = 4;

const about = (question, whenTrue, whenFalse) => ({
  type: 'boolean',
  instructions: { question, inspect: '`evidence`' },
  criteria: { true: whenTrue, false: whenFalse },
});

// Exported so an evaluation harness measures exactly the questions that ship.
// Each is one literal, one-second judgment; the caller combines them in code.
export const QUESTIONS = {
  actively_working: about(
    'Does `evidence` show the worker or its validation run executing right now?',
    {
      what: 'A run step is running, fixing, or in CI; a tool or test process is executing; output or a log advanced recently; the pane shows a busy spinner or streaming work',
      examples: ['state: working (run-step: test running)', '3 live fm-test-run processes', 'Working (2m 14s)'],
    },
    {
      what: 'Nothing is executing: an idle prompt, an exited agent, a finished or parked run',
      examples: ['state: idle', 'agent exited', 'run step: parked awaiting approval'],
    },
  ),
  waiting_on_someone: about(
    'Does `evidence` show the worker stopped and waiting for an answer, approval, or input?',
    {
      what: 'A question on screen, a permission or trust dialog, a parked approval or fix-review gate, an ask-user finding',
      examples: ['Do you want to proceed? (y/n)', 'awaiting approval', 'needs-decision'],
    },
    { what: 'The worker is not waiting on anyone' },
  ),
  shows_failure: about(
    'Does `evidence` show an error, crash, quota or rate-limit failure, or a dead or missing agent?',
    {
      what: 'Error text, a failed or cancelled run, 429 or quota exhausted, agent exited, endpoint missing, daemon unreachable',
      examples: ['429 Too Many Requests', 'state: failed', 'agent has exited'],
    },
    {
      what: 'No failure is visible',
      not_for: 'Test failures listed inside a test run that is still executing',
    },
  ),
  finished_idle: about(
    'Does `evidence` show the worker finished its work and is idle with a final result reported?',
    {
      what: 'A done line, a ready or merged pull request, a written report, and an idle prompt',
      examples: ['done: PR https://... checks green'],
    },
    { what: 'Work is still under way, or it stopped without a final result' },
  ),
};

function fail(reason, code) {
  process.stdout.write(`error\t${reason}\n`);
  process.exitCode = code;
}

function readKey() {
  const name = process.env.FM_WAKE_GATE_KEY_VAR || '';
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) return '';
  const path = process.env.FM_WAKE_GATE_SECRETS || `${homedir()}/.secrets`;
  let text;
  try {
    text = readFileSync(path, 'utf8');
  } catch {
    return '';
  }
  let value = '';
  for (const raw of text.split('\n')) {
    const m = raw.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!m || m[1] !== name) continue;
    value = m[2].trim().replace(/^(['"])(.*)\1$/, '$2');
  }
  return value;
}

async function main() {
  const timeoutMs = Number.parseInt(process.env.FM_WAKE_GATE_TIMEOUT_MS || '6000', 10);
  let state;
  try {
    const parsed = JSON.parse(readFileSync(process.argv[2] || 0, 'utf8'));
    const evidence = (Array.isArray(parsed.evidence) ? parsed.evidence : [])
      .slice(0, MAX_EVIDENCE)
      .map((e) => ({
        command: String(e?.command ?? '').slice(0, 200),
        output: String(e?.output ?? '').slice(-MAX_OUTPUT_CHARS),
      }))
      .filter((e) => e.output.trim() !== '');
    if (evidence.length === 0) return fail('no-evidence', 2);
    state = { alarm: String(parsed.alarm ?? '').slice(0, 300), evidence };
  } catch {
    return fail('bad-input', 2);
  }

  const apiKey = readKey();
  if (!apiKey) return fail('no-key', 3);

  let evaluate;
  let createGateway;
  try {
    ({ experimental_evaluate: evaluate } = await import('ai'));
    ({ createGateway } = await import('@ai-sdk/gateway'));
  } catch {
    return fail('no-runtime', 4);
  }
  if (typeof evaluate !== 'function' || typeof createGateway !== 'function') {
    return fail('no-runtime', 4);
  }

  const model = createGateway({ apiKey }).evaluationModel(MODEL_ID);
  const abortSignal = AbortSignal.timeout(Number.isFinite(timeoutMs) && timeoutMs > 0 ? timeoutMs : 6000);
  const started = Date.now();
  let r;
  try {
    r = await evaluate({ model, state, questions: QUESTIONS, maxRetries: 0, abortSignal });
  } catch {
    return fail('call-failed', 5);
  }
  const probs = Object.keys(QUESTIONS).map((k) => r.answers?.[k]?.probability);
  if (!probs.every((p) => typeof p === 'number' && p >= 0 && p <= 1)) return fail('bad-answer', 6);
  process.stdout.write(
    `usage\t1\t${r.usage?.inputTokens ?? 0}\t${r.usage?.outputTokens ?? 0}\t${Date.now() - started}\n` +
      `answers\t${probs.map((p) => p.toFixed(4)).join('\t')}\n`,
  );
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(() => fail('error', 1));
}
