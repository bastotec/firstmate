// Read one spoken transcript with Jev (typesafe-ai/jev) through AI SDK 7's
// experimental_evaluate on the Vercel AI Gateway. bin/fm_voice_gate.py is the
// only caller and owns every policy decision (the routing rule, its thresholds,
// fail-open, shadow versus act, and the bookkeeping); this helper only turns
// one transcript into four answers, asked together in one request.
//
// The question set is the measured relay-shaped set: the four questions, this
// wording, and this order are what the per-decision cost was measured on, so
// the shipped call stays comparable with that measurement. Ask every question
// in one call (fan-out), never a chain.
//
// Input: the file named by the first argument (stdin when absent), one JSON
// object {"utterance": "<transcript>"}.
// Output (stdout), tab-separated: a first row
//   usage<TAB><calls><TAB><input-tokens><TAB><output-tokens><TAB><ms>
// then one row
//   answers<TAB><intent><TAB><needs_records><TAB><hand_over><TAB><answerable_fast>
// where intent is one of status_query, real_work, smalltalk, question, unclear
// and the other three are probabilities. Failure: one row "error<TAB><reason>"
// and a nonzero exit; the caller routes the turn to the heavy model.
//
// The key is read at call time from the secrets file (FM_VOICE_GATE_SECRETS,
// default ~/.secrets) under the variable named by FM_VOICE_GATE_KEY_VAR, which
// has no default. The file is parsed, never executed, and the key value is
// never printed. Only the transcript and the fixed questions below are sent to
// the vendor.
//
// FM_VOICE_GATE_TIMEOUT_MS bounds the call and has NO default: the deadline
// belongs to the caller's one turn budget, so this helper refuses to run
// without it rather than inventing a number of its own.
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { pathToFileURL } from 'node:url';

export const MODEL_ID = 'typesafe-ai/jev';
export const MAX_UTTERANCE_CHARS = 2000;
export const INTENTS = ['status_query', 'real_work', 'smalltalk', 'question', 'unclear'];

const boolean = (question, whenTrue, whenFalse) => ({
  type: 'boolean',
  instructions: { question, inspect: '`text`' },
  criteria: { true: whenTrue, false: whenFalse },
});

// Exported so an evaluation harness measures exactly the questions that ship.
// Each is one literal judgment; the caller combines them in code.
export const QUESTIONS = {
  intent: {
    type: 'choice',
    instructions: { question: 'What kind of thing did the speaker say?', inspect: '`text`' },
    criteria: {
      status_query: 'asking how things are going, what is in flight, what is waiting on them, or whether anything is ready to review',
      real_work: 'asking for actual work: something that would change code, open a pull request, investigate a bug, or start a job',
      smalltalk: 'greeting, thanks, or chatting',
      question: 'a general question that is not about the records and not work',
      unclear: 'garbled or makes no sense',
    },
  },
  needs_records: boolean(
    'Does answering this require reading the first mate\'s records (fleet status)?',
    { what: 'It asks about work, in-flight jobs, decisions, or reviews' },
    { what: 'It can be answered without any record lookup' },
  ),
  hand_over: boolean(
    'Is this a request for real work that must be queued for the first mate rather than answered aloud?',
    { what: 'Change code, open a PR, investigate, start a job, fix something' },
    { what: 'Status questions, smalltalk, or general knowledge' },
  ),
  answerable_fast: boolean(
    'Could this be answered with one short scripted line without any model or record read?',
    { what: 'A greeting, thanks, or fixed phrase' },
    { what: 'Anything needing facts, records, or work' },
  ),
};

function fail(reason, code) {
  process.stdout.write(`error\t${reason}\n`);
  process.exitCode = code;
}

function readKey() {
  const name = process.env.FM_VOICE_GATE_KEY_VAR || '';
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) return '';
  const path = process.env.FM_VOICE_GATE_SECRETS || `${homedir()}/.secrets`;
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
  let utterance;
  try {
    const parsed = JSON.parse(readFileSync(process.argv[2] || 0, 'utf8'));
    utterance = String(parsed.utterance ?? '').slice(0, MAX_UTTERANCE_CHARS);
  } catch {
    return fail('bad-input', 2);
  }

  const apiKey = readKey();
  if (!apiKey) return fail('no-key', 3);

  const timeoutMs = Number.parseInt(process.env.FM_VOICE_GATE_TIMEOUT_MS || '', 10);
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) return fail('no-timeout', 2);

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
  const abortSignal = AbortSignal.timeout(timeoutMs);
  const started = Date.now();
  let r;
  try {
    r = await evaluate({
      model, state: { text: utterance }, questions: QUESTIONS,
      maxRetries: 0, abortSignal,
    });
  } catch {
    return fail('call-failed', 5);
  }
  const intent = r.answers?.intent?.choice;
  const probs = ['needs_records', 'hand_over', 'answerable_fast']
    .map((k) => r.answers?.[k]?.probability);
  if (!INTENTS.includes(intent)
    || !probs.every((p) => typeof p === 'number' && p >= 0 && p <= 1)) {
    return fail('bad-answer', 6);
  }
  process.stdout.write(
    `usage\t1\t${r.usage?.inputTokens ?? 0}\t${r.usage?.outputTokens ?? 0}\t${Date.now() - started}\n` +
      `answers\t${intent}\t${probs.map((p) => p.toFixed(4)).join('\t')}\n`,
  );
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(() => fail('error', 1));
}
