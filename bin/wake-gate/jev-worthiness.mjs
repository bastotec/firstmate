// Score supervision wake rows for whether they genuinely need a supervisor's
// attention, using Jev (typesafe-ai/jev) through AI SDK 7's experimental_evaluate
// on the Vercel AI Gateway. bin/fm-wake-gate.sh is the only caller and owns every
// policy decision (which rows, threshold, advisory-vs-enforce, caching, the
// deterministic layer that runs first); this helper only turns a wake row's text
// into a probability. It mirrors bin/ask-triage/jev-rank.mjs's contract.
//
// Input: the file named by the first argument (stdin when absent), one wake row
// per line, each pre-formatted by the caller as "kind | key | payload".
// Output (stdout), tab-separated: a first row
//   usage<TAB><calls><TAB><input-tokens><TAB><output-tokens><TAB><ms>
// then one row per input line, in order: the probability that the row NEEDS
// supervisor attention (so a LOW value means mechanical noise the caller may
// absorb), or "-" when that line's call failed and the caller MUST escalate it.
// Failure: one row "error<TAB><reason>" and a nonzero exit.
//
// The key is read at call time from the secrets file (FM_WAKE_GATE_SECRETS,
// default ~/.secrets) under the variable named by FM_WAKE_GATE_KEY_VAR, which has
// no default. The file is parsed, never executed, and the key value is never
// printed. Only each row's text and the fixed question below are sent to the
// vendor. FM_WAKE_GATE_TIMEOUT_MS bounds the whole run (default 6000).
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { pathToFileURL } from 'node:url';

export const MODEL_ID = 'typesafe-ai/jev';
export const MAX_CHARS = 2000;
// Exported so an evaluation harness can measure exactly the question that ships.
// Calibrated conservatively: 'true' is the broad, default side (needs attention)
// so that any ambiguity lands on escalate; only an unambiguous mechanical-noise
// row scores low enough for the caller to absorb. The caller absorbs only at a
// very low threshold and escalates on '-', so the helper never has to be certain.
export const QUESTION = {
  type: 'boolean',
  instructions:
    'This is one supervision wake event from a fleet monitoring system, formatted as "kind | key | payload". ' +
    'Decide whether it genuinely needs a supervisor - a human or an expensive reasoning model - to act on it, ' +
    'or whether it is routine mechanical noise that can be acknowledged with no attention.',
  criteria: {
    true: 'needs supervisor action or judgment: a decision, approval, blocker, failure, error, a merged or ready pull request, a credential need, a security event, or any genuine new state change',
    false: 'routine mechanical noise only: a repeated idle or stale re-ring of an already-stopped task, a no-op re-delivery, an unchanged heartbeat, or a line that only reports progress with nothing to act on',
  },
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
  let input;
  try {
    input = readFileSync(process.argv[2] || 0, 'utf8');
  } catch {
    return fail('bad-input', 2);
  }
  const lines = input.split('\n').filter((l) => l.trim() !== '').map((l) => l.slice(0, MAX_CHARS));
  if (lines.length === 0) {
    process.stdout.write('usage\t0\t0\t0\t0\n');
    return;
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
  const signal = AbortSignal.timeout(Number.isFinite(timeoutMs) && timeoutMs > 0 ? timeoutMs : 6000);
  const started = Date.now();
  const usage = { inputTokens: 0, outputTokens: 0 };
  const results = await Promise.all(
    lines.map(async (state) => {
      try {
        const r = await evaluate({ model, state, questions: { worth: QUESTION }, maxRetries: 0, abortSignal: signal });
        usage.inputTokens += r.usage?.inputTokens ?? 0;
        usage.outputTokens += r.usage?.outputTokens ?? 0;
        const p = r.answers?.worth?.probability;
        return typeof p === 'number' && p >= 0 && p <= 1 ? p : null;
      } catch {
        return null;
      }
    }),
  );
  const rows = [`usage\t${lines.length}\t${usage.inputTokens}\t${usage.outputTokens}\t${Date.now() - started}`];
  for (const p of results) rows.push(p === null ? '-' : p.toFixed(4));
  process.stdout.write(rows.join('\n') + '\n');
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(() => fail('error', 1));
}
