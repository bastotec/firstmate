// Score plain progress status lines for a politely-phrased ask, using Jev
// (typesafe-ai/jev) through AI SDK 7's experimental_evaluate on the Vercel AI
// Gateway. bin/fm-ask-triage.sh is the only caller and owns every policy
// decision (which lines, threshold, caching, presentation); this helper only
// turns line text into probabilities.
//
// Input: the file named by the first argument (stdin when absent), one
// status line per line.
// Output (stdout), tab-separated: a first row
//   usage<TAB><calls><TAB><input-tokens><TAB><output-tokens><TAB><ms>
// then one row per input line, in order: the probability that the line asks
// the supervisor for something, or "-" when that line's call failed and the
// caller must treat it as unflagged.
// Failure: one row "error<TAB><reason>" and a nonzero exit.
//
// The key is read at call time from the secrets file (FM_ASK_TRIAGE_SECRETS,
// default ~/.secrets) under the variable named by FM_ASK_TRIAGE_KEY_VAR, which
// has no default. The file is parsed, never executed, and the key
// value is never printed. Only each line's text and the fixed question below
// are sent to the vendor.
// FM_ASK_TRIAGE_TIMEOUT_MS bounds the whole run (default 4000).
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';

const MODEL_ID = 'typesafe-ai/jev';
const QUESTION = {
  type: 'boolean',
  instructions:
    'This is a progress update a worker agent wrote to the supervisor that manages it. ' +
    'Does the update ask the supervisor for something - a decision, an approval, a preference, or a reply - ' +
    'even when the ask is polite, hedged, conditional, or optional?',
  criteria: {
    true: 'asks the supervisor to decide, approve, choose, confirm, or reply, however softly or conditionally it is phrased',
    false: 'only reports progress, results, or next steps and needs no reply from the supervisor',
  },
};

function fail(reason, code) {
  process.stdout.write(`error\t${reason}\n`);
  process.exitCode = code;
}

function readKey() {
  const name = process.env.FM_ASK_TRIAGE_KEY_VAR || '';
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) return '';
  const path = process.env.FM_ASK_TRIAGE_SECRETS || `${homedir()}/.secrets`;
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
  const timeoutMs = Number.parseInt(process.env.FM_ASK_TRIAGE_TIMEOUT_MS || '4000', 10);
  let input;
  try {
    input = readFileSync(process.argv[2] || 0, 'utf8');
  } catch {
    return fail('bad-input', 2);
  }
  const lines = input.split('\n').filter((l) => l.trim() !== '');
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
  const signal = AbortSignal.timeout(Number.isFinite(timeoutMs) && timeoutMs > 0 ? timeoutMs : 4000);
  const started = Date.now();
  const usage = { inputTokens: 0, outputTokens: 0 };
  // One call per line, all in flight together: each line is judged on its own
  // text only, and the pass costs one round trip of latency.
  const results = await Promise.all(
    lines.map(async (state) => {
      try {
        const r = await evaluate({ model, state, questions: { ask: QUESTION }, maxRetries: 0, abortSignal: signal });
        usage.inputTokens += r.usage?.inputTokens ?? 0;
        usage.outputTokens += r.usage?.outputTokens ?? 0;
        const p = r.answers?.ask?.probability;
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

main().catch(() => fail('error', 1));
