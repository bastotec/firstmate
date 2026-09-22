// The supervision-branch model chain: which configured model the next branch
// build should use, and how long a model that just failed sits out.
// docs/configuration.md owns the operator-facing file format and behavior.
//
// This file holds only the pure choices - parsing, ordering, and cooldown
// arithmetic - so they stay testable without Pi. The live state (which model
// the current branch was built on, each model's cooldown) and every side
// effect live beside branchModelSelection in fm-branch-supervision.ts.

/** One configured supervision model. */
export interface BranchModelRef {
  provider: string;
  modelId: string;
}

/** A model that failed: when it may be tried again, and its current backoff. */
export interface BranchModelCooldown {
  cooldownMs: number;
  retryNotBefore: number;
}

export const BRANCH_MODEL_COOLDOWN_BASE_MS = 5 * 60 * 1000;
export const BRANCH_MODEL_COOLDOWN_MAX_MS = 60 * 60 * 1000;

export function branchModelLabel(ref: BranchModelRef): string {
  return `${ref.provider}/${ref.modelId}`;
}

/**
 * Parses config/supervision-branch-model: one "<provider>/<model-id>" per
 * line in preference order, split at the FIRST "/" so a provider-qualified
 * model id survives. Blank lines and "#" comments are skipped. Any malformed
 * non-comment line rejects the
 * chain instead of silently selecting around it. Only an empty or comment-only
 * file means no pin.
 */
export function parseBranchModelChain(stored: string): BranchModelRef[] {
  const chain: BranchModelRef[] = [];
  const malformed: Array<{ number: number; line: string }> = [];
  for (const [index, line] of stored.split("\n").entries()) {
    const trimmed = line.trim();
    if (trimmed === "" || trimmed.startsWith("#")) continue;
    const separator = line.indexOf("/");
    if (separator <= 0 || separator >= line.length - 1 || /[\s\u0000-\u001F\u007F]/u.test(line)) {
      malformed.push({ number: index + 1, line });
      continue;
    }
    chain.push({ provider: line.slice(0, separator), modelId: line.slice(separator + 1) });
  }
  if (malformed.length > 0) {
    const first = malformed[0];
    throw new Error(`invalid supervision model line ${first.number}: ${JSON.stringify(first.line)}`);
  }
  return chain;
}

/**
 * The order in which an ordinary build should try the chain: every model that
 * is not cooling down, in preference order. Recovery probes are offered only
 * after the earliest cooldown expires, so ordinary builds never retry a model
 * during its sit-out.
 */
export function orderBranchModelChain(
  chain: readonly BranchModelRef[],
  cooldowns: ReadonlyMap<string, BranchModelCooldown>,
  now: number,
): BranchModelRef[] {
  return chain.filter((ref) => {
    const cooldown = cooldowns.get(branchModelLabel(ref));
    return !cooldown || cooldown.retryNotBefore <= now;
  });
}

/** True when some model other than `failed` is ready to take the next wake. */
export function chainHasReadyAlternative(
  chain: readonly BranchModelRef[],
  cooldowns: ReadonlyMap<string, BranchModelCooldown>,
  failed: string,
  now: number,
): boolean {
  return chain.some((ref) => {
    const label = branchModelLabel(ref);
    if (label === failed) return false;
    const cooldown = cooldowns.get(label);
    return !cooldown || cooldown.retryNotBefore <= now;
  });
}

/** Backoff for a model that just failed: five minutes, doubling to an hour. */
export function nextBranchModelCooldown(previous: BranchModelCooldown | undefined, now: number): BranchModelCooldown {
  const cooldownMs = previous
    ? Math.min(BRANCH_MODEL_COOLDOWN_MAX_MS, previous.cooldownMs * 2)
    : BRANCH_MODEL_COOLDOWN_BASE_MS;
  return { cooldownMs, retryNotBefore: now + cooldownMs };
}

/**
 * True when the live branch should be rebuilt because a model earlier in the
 * chain than the one it runs on is ready again: the way back to the preferred
 * model once its cooldown has passed.
 */
export function chainPrefersEarlierModel(
  chain: readonly BranchModelRef[],
  cooldowns: ReadonlyMap<string, BranchModelCooldown>,
  active: string,
  now: number,
): boolean {
  const activeIndex = chain.findIndex((ref) => branchModelLabel(ref) === active);
  if (activeIndex <= 0) return false;
  return chain.slice(0, activeIndex).some((ref) => {
    const cooldown = cooldowns.get(branchModelLabel(ref));
    return !cooldown || cooldown.retryNotBefore <= now;
  });
}
