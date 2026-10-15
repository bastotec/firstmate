// Score one fleet-dreaming harness proposal with Jev (typesafe-ai/jev): is it
// concrete, does its evidence support it, and is it worth a worker's time?
// bin/fm_dream.py's triage step is the only caller and owns the threshold and
// what happens with the answers; this helper only turns one proposal into three
// independent probabilities, asked together in one request. It shares the
// pinned runtime of jev-stale.mjs (npm ci --prefix bin/wake-gate --omit=dev)
// and its key reader (readKey: FM_WAKE_GATE_KEY_VAR names the variable in
// FM_WAKE_GATE_SECRETS, default ~/.secrets; parsed, never executed or printed).
//
// Input (stdin): {"title", "repo", "why", "fix", "evidence": ["..."]}.
// Output, tab-separated: a `usage` row as jev-stale.mjs prints it, then
//   answers<TAB><concrete><TAB><evidence_supports><TAB><worth_fixing>
// Failure: one row "error<TAB><reason>" and a nonzero exit.
import { readFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { readKey } from './jev-stale.mjs';

export const MODEL_ID = 'typesafe-ai/jev';

const about = (question, whenTrue, whenFalse) => ({
  type: 'boolean',
  instructions: { question, inspect: '`proposal`' },
  criteria: { true: whenTrue, false: whenFalse },
});

export const QUESTIONS = {
  concrete: about(
    'Does `proposal` name a specific change in a specific place that a developer could start on today?',
    { what: 'A named script, function, default, check or file, and what to change in it' },
    { what: 'A vague wish, a general theme, or a request to investigate without a target' },
  ),
  evidence_supports: about(
    "Do the `proposal`'s evidence lines show the problem it claims actually happened?",
    { what: 'Error text, a failed run, a slow command with its time, or a repeated correction that matches the claim' },
    { what: 'The evidence is unrelated, missing, or shows a one-off with no cost' },
  ),
  worth_fixing: about(
    "Is fixing `proposal` worth a worker's time compared with leaving it?",
    { what: 'It cost real time, failed work, wasted quota, or captain attention, and is likely to recur' },
    { what: 'Cosmetic, already rare, or the fix costs more than the problem' },
  ),
};

function fail(reason, code) {
  process.stdout.write(`error\t${reason}\n`);
  process.exitCode = code;
}

async function main() {
  let proposal;
  try {
    const p = JSON.parse(readFileSync(0, 'utf8'));
    proposal = {
      title: String(p.title ?? '').slice(0, 200),
      repo: String(p.repo ?? '').slice(0, 60),
      why: String(p.why ?? '').slice(0, 400),
      fix: String(p.fix ?? '').slice(0, 600),
      evidence: (Array.isArray(p.evidence) ? p.evidence : []).slice(0, 4).map((e) => String(e).slice(0, 300)),
    };
    if (!proposal.title) return fail('bad-input', 2);
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
  if (typeof evaluate !== 'function' || typeof createGateway !== 'function') return fail('no-runtime', 4);
  const model = createGateway({ apiKey }).evaluationModel(MODEL_ID);
  const started = Date.now();
  let r;
  try {
    r = await evaluate({ model, state: { proposal }, questions: QUESTIONS, maxRetries: 0,
      abortSignal: AbortSignal.timeout(10000) });
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
