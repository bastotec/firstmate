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
 * model id survives. Blank lines and "#" comments are skipped, a repeated
 * model keeps its first position, and a line that is not a model reference is
 * ignored rather than poisoning the models around it.
 */
export function parseBranchModelChain(stored: string): BranchModelRef[] {
  const chain: BranchModelRef[] = [];
  const seen = new Set<string>();
  for (const raw of stored.split("\n")) {
    const line = raw.trim();
    if (line === "" || line.startsWith("#")) continue;
    const separator = line.indexOf("/");
    if (separator <= 0 || separator >= line.length - 1) continue;
    if (seen.has(line)) continue;
    seen.add(line);
    chain.push({ provider: line.slice(0, separator), modelId: line.slice(separator + 1) });
  }
  return chain;
}

/**
 * The order in which a build should try the chain: every model that is not
 * cooling down, in preference order, then the cooling ones soonest-ready
 * first. The cooling tail is what lets a recovery probe try something when
 * every model has failed, instead of refusing to build.
 */
export function orderBranchModelChain(
  chain: readonly BranchModelRef[],
  cooldowns: ReadonlyMap<string, BranchModelCooldown>,
  now: number,
): BranchModelRef[] {
  const ready: BranchModelRef[] = [];
  const cooling: BranchModelRef[] = [];
  for (const ref of chain) {
    const cooldown = cooldowns.get(branchModelLabel(ref));
    if (cooldown && cooldown.retryNotBefore > now) cooling.push(ref);
    else ready.push(ref);
  }
  cooling.sort(
    (a, b) => cooldowns.get(branchModelLabel(a))!.retryNotBefore - cooldowns.get(branchModelLabel(b))!.retryNotBefore,
  );
  return [...ready, ...cooling];
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
