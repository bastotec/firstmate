"use strict";Object.defineProperty(exports, "__esModule", { value: true });exports.default = _default;






















var _nodeChild_process = await jitiImport("node:child_process");
var _nodeCrypto = await jitiImport("node:crypto");
var _nodeFs = await jitiImport("node:fs");
var _nodePath = await jitiImport("node:path");
var _nodeUrl = await jitiImport("node:url");

var _piTui = await jitiImport("@earendil-works/pi-tui");
var _typebox = await jitiImport("typebox");
var _fmNativeContract = await jitiImport("./lib/fm-native-contract.ts");
var _fmBranchDispatch = await jitiImport("./lib/fm-branch-dispatch.ts");




var _fmCalmVisibility = await jitiImport("./lib/fm-calm-visibility.ts");




var _fmOperationalInput = await jitiImport("./lib/fm-operational-input.ts"); // Firstmate primary watcher bridge for Pi.
//
// Session-generation ownership (stated once here):
// Pi emits session_shutdown for ordinary same-process replacements (/new, /resume,
// /fork, reload) as well as terminal quit. This extension binds one generation per
// session activation. Only the active live generation may start, stop, rearm, or
// clear the arm child. An owning replacement session_start (or fresh factory bind)
// arms its new generation without a model turn. A replacement handoff carries
// actionable closes that were still pending delivery; its durable state lives at
// state/extensions/pi-primary-watch/session-replacement-actionable.json.
// Terminal quit leaves the final generation stopped so late callbacks cannot rearm.
// Stale callbacks from a prior generation are no-ops against the active replacement.
//
// Delivery versus consumption (stated once here):
// A main follow-up is delivered once Pi accepts it (sendUserMessage resolves).
// The successor pipeline never waits for the model to read it: a follow-up
// queued while main is streaming joins the running run without ever raising
// before_agent_start, so waiting on that event stalls every later close.
// Consumption is tracked only so a replacement can replay a follow-up Pi had
// not consumed. An idle main consumes at before_agent_start; a streaming main
// consumes at the user message_start carrying the exact wake text; either
// event finishes the pending record, and a still-unconsumed record rides the
// replacement handoff.











































function refreshWatchToolShell(
state,
theme,
context)
{
  const background = context.isPartial ?
  (text) => theme.bg("toolPendingBg", text) :
  context.isError ?
  (text) => theme.bg("toolErrorBg", text) :
  (text) => theme.bg("toolSuccessBg", text);
  const shell = state.shell ?? new _piTui.Box(1, 1, background);
  state.shell = shell;
  shell.setBgFn(background);
  shell.clear();
  if (state.call) shell.addChild(state.call);
  if (state.result) shell.addChild(state.result);
  return shell;
}

const extensionFile = (0, _nodeUrl.fileURLToPath)("file:///Users/bastotecnologia/.no-mistakes/worktrees/5a1fd3284f12/01M3QB6N5CWNPN7VWK7GRV8GC3/.t/fm-calm-pi-extension.5YdEYC/e2e-project/.pi/extensions/fm-primary-pi-watch.ts");
const extensionDir = (0, _nodePath.dirname)(extensionFile);
const root = (0, _nodePath.resolve)(extensionDir, "../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const fmRoot = process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const config = process.env.FM_CONFIG_OVERRIDE || `${fmHome}/config`;
const armScript = `${fmRoot}/bin/fm-watch-arm.sh`;
const marker = `${state}/.pi-watch-extension-loaded`;
const handoffDir = `${state}/extensions/pi-primary-watch`;
const actionableHandoff = `${handoffDir}/session-replacement-actionable.json`;
const extensionVersion = `sha256:${(0, _nodeCrypto.createHash)("sha256").update((0, _nodeFs.readFileSync)(extensionFile)).digest("hex")}`;
const retryBaseMs = positiveInteger("FM_WATCH_REARM_RETRY_BASE_MS", 250);
const retryMaxMs = positiveInteger("FM_WATCH_REARM_RETRY_MAX_MS", 4000);
const retryLimit = positiveInteger("FM_WATCH_REARM_RETRY_LIMIT", 5);
// 35s on Windows so the budget stays above arm's MSYS confirm default (30s in
// bin/fm-watch-arm.sh): a slow but successful Git Bash cold start must not be
// SIGTERMed mid-confirmation. Conditioned on win32 so other platforms keep 12s.
const armReadyTimeoutMs = positiveInteger(
  "FM_PI_ARM_READY_TIMEOUT_MS",
  process.platform === "win32" ? 35000 : 12000
);
const armRetireTimeoutMs = positiveInteger("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000);
const repairOnlyHint = "call fm_watch_arm_pi again only after a later notification says the cycle is missing, failed, or unhealthy";
const shuttingDownMessage = "watcher: not armed - Pi session is shutting down";

let nextGenerationId = 0;
let nextHandoffId = 0;
let activeGeneration = null;
let replacementHandoff = null;














const replacementCoordinatorGlobal = globalThis;
const replacementCoordinators = replacementCoordinatorGlobal.__firstmatePiWatchReplacements ??= new Map();
function replacementCoordinatorFor(handoff) {
  const existing = replacementCoordinators.get(handoff);
  if (existing) return existing;
  const created = {
    receiver: null,
    pending: [],
    nextTokenId: 0,
    deliveries: new Map()
  };
  replacementCoordinators.set(handoff, created);
  return created;
}
const replacementCoordinator = replacementCoordinatorFor(actionableHandoff);
const armReadiness = new WeakMap();
const armClose = new WeakMap();
// Children the extension itself asked to exit; their close is not a failure
// of the successor and never earns a deferred retry.
const armRetired = new WeakSet();
const armRecovery = new WeakMap();
const armPendingActionable = new WeakMap();

function positiveInteger(name, fallback) {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

function parentPid(pid) {
  const result = (0, _nodeChild_process.spawnSync)("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function pidAlive(pid) {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function lockOwnership() {
  let lockPid = "";
  try {
    lockPid = (0, _nodeFs.readFileSync)(`${state}/.lock`, "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return "owned";
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

function markLoaded() {
  if (lockOwnership() === "other") return;
  (0, _nodeFs.mkdirSync)(state, { recursive: true });
  (0, _nodeFs.writeFileSync)(marker, `${extensionVersion}\n${process.pid}\n`);
}

function actionableLine(output) {
  const lines = output.split(/\r?\n/);
  return lines.find((line) => /^(signal:|stale:|check:|heartbeat($|:))/.test(line)) || "";
}

function completedActionableLine(output) {
  const newline = output.lastIndexOf("\n");
  return newline < 0 ? "" : actionableLine(output.slice(0, newline + 1));
}

// The text Pi carries in a user message_start: sendUserMessage wraps a string
// as one text part, so the joined text parts equal the sent content.
function userMessageText(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  const parts = [];
  for (const part of content) {
    if (
    typeof part === "object" && part !== null &&
    part.type === "text" &&
    typeof part.text === "string")
    {
      parts.push(part.text);
    }
  }
  return parts.join("\n");
}

function nodeErrorCode(error) {
  return typeof error === "object" && error !== null && "code" in error ?
  String(error.code ?? "") :
  "";
}

function createPendingActionable(message, predecessorArmPid) {
  return {
    version: 1,
    token: `${process.pid}-${Date.now()}-${++replacementCoordinator.nextTokenId}`,
    message,
    predecessorArmPid
  };
}

function validatePendingActionable(value) {
  if (
  typeof value !== "object" || value === null ||
  value.version !== 1 ||
  typeof value.token !== "string" ||
  !/^[0-9]+-[0-9]+-[0-9]+$/.test(value.token) ||
  typeof value.message !== "string" ||
  !actionableLine(value.message) ||
  typeof value.predecessorArmPid !== "string" ||
  !/^[0-9]*$/.test(value.predecessorArmPid) ||
  value.delivered !== undefined &&
  value.delivered !== true)
  {
    throw new Error(`invalid Pi replacement actionable handoff at ${actionableHandoff}`);
  }
  return value;
}

function validateReplacementHandoff(value) {
  if (
  typeof value !== "object" || value === null ||
  value.version !== 2 ||
  !Array.isArray(value.pending) ||
  value.pending.length === 0)
  {
    throw new Error(`invalid Pi replacement actionable handoff at ${actionableHandoff}`);
  }
  const pending = value.pending.map(validatePendingActionable);
  if (new Set(pending.map((item) => item.token)).size !== pending.length) {
    throw new Error(`invalid Pi replacement actionable handoff at ${actionableHandoff}`);
  }
  return pending;
}

function writeReplacementHandoff(pending) {
  replacementHandoff = [...pending];
  (0, _nodeFs.mkdirSync)(handoffDir, { recursive: true });
  const temporary = `${actionableHandoff}.tmp-${process.pid}-${++nextHandoffId}`;
  const handoff = { version: 2, pending };
  try {
    (0, _nodeFs.writeFileSync)(temporary, `${JSON.stringify(handoff)}\n`, { mode: 0o600 });
    (0, _nodeFs.renameSync)(temporary, actionableHandoff);
  } catch (error) {
    try {
      (0, _nodeFs.unlinkSync)(temporary);
    } catch {

      // Preserve the original handoff publication error.
    }throw error;
  }
}

function persistReplacementHandoff(pending) {
  if (pending.length === 0) return;
  writeReplacementHandoff(pending);
}

function loadReplacementHandoff() {
  try {
    const pending = validateReplacementHandoff(JSON.parse((0, _nodeFs.readFileSync)(actionableHandoff, "utf8")));
    replacementHandoff = pending;
    return [...pending];
  } catch (error) {
    if (nodeErrorCode(error) === "ENOENT") {
      replacementHandoff = null;
      return [];
    }
    throw error;
  }
}

function mergeReplacementHandoff(pending) {
  let stored = [];
  try {
    stored = validateReplacementHandoff(JSON.parse((0, _nodeFs.readFileSync)(actionableHandoff, "utf8")));
  } catch (error) {
    if (nodeErrorCode(error) !== "ENOENT") throw error;
  }
  if (!stored.some((item) => item.token === pending.token)) stored.push(pending);
  writeReplacementHandoff(stored);
}

function clearReplacementHandoff(pending) {
  try {
    const stored = validateReplacementHandoff(JSON.parse((0, _nodeFs.readFileSync)(actionableHandoff, "utf8")));
    const remaining = stored.filter((item) => item.token !== pending.token);
    if (remaining.length === stored.length) return;
    if (remaining.length > 0) {
      writeReplacementHandoff(remaining);
    } else {
      replacementHandoff = null;
      (0, _nodeFs.unlinkSync)(actionableHandoff);
    }
  } catch (error) {
    if (nodeErrorCode(error) !== "ENOENT") throw error;
  }
}

function classifyClose(stdout, stderr, code, signal) {
  const combined = `${stdout}\n${stderr}`.trim();
  const reason = actionableLine(combined);
  if (reason) return { kind: "actionable", message: reason };
  const healthy = combined.split(/\r?\n/).find((line) => /^watcher: healthy\b/.test(line));
  if (healthy) {
    return {
      kind: "failure",
      message: `watcher: FAILED - Pi extension arm child found an external healthy watcher instead of owning wake delivery\n${healthy}`
    };
  }
  const failed = combined.split(/\r?\n/).find((line) => /^watcher: FAILED/.test(line));
  if (failed) return { kind: "failure", message: failed };
  if (signal) {
    return {
      kind: "failure",
      message: `watcher: FAILED - Pi extension arm child ended from ${signal}${combined ? `\n${combined}` : ""}`
    };
  }
  if (code && code !== 0) {
    return {
      kind: "failure",
      message: `watcher: FAILED - fm-watch-arm.sh exited ${code}${combined ? `\n${combined}` : ""}`
    };
  }
  return {
    kind: "failure",
    message: "watcher: FAILED - Pi extension arm cycle ended without an actionable reason"
  };
}

function createGeneration() {
  return {
    id: ++nextGenerationId,
    stopping: false,
    replacement: false,
    child: null,
    retryTimer: null,
    cleanupTimer: null,
    retryFailures: 0,
    restoring: false,
    seq: 0,
    pendingActionables: [],
    cleanupFailure: "",
    unconsumedWakes: new Map(),
    deferredClose: null
  };
}

function activateGeneration(generation) {
  activeGeneration = generation;
}

function generationIsLive(generation) {
  return activeGeneration === generation && !generation.stopping;
}

function stopGeneration(generation) {
  generation.stopping = true;
  if (generation.retryTimer) clearTimeout(generation.retryTimer);
  if (generation.cleanupTimer) clearTimeout(generation.cleanupTimer);
  generation.retryTimer = null;
  generation.cleanupTimer = null;
  const child = generation.child;
  if (child) child.kill("SIGTERM");
  generation.child = null;
  return child;
}

async function waitForGenerationChildClose(armChild) {
  if (!armChild) return;
  const closed = armClose.get(armChild);
  if (!closed) return;
  await new Promise((resolveWait) => {
    const timer = setTimeout(resolveWait, armRetireTimeoutMs);
    void closed.then(() => {
      clearTimeout(timer);
      resolveWait();
    });
  });
}

async function stopSessionGeneration(generation, replacement) {
  generation.replacement = replacement;
  let persistedTokens = "";
  try {
    if (replacement && generation.pendingActionables.length > 0) {
      persistReplacementHandoff(generation.pendingActionables);
      persistedTokens = generation.pendingActionables.map((pending) => pending.token).join("\n");
    }
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    for (const pending of generation.pendingActionables) {
      if (replacementCoordinator.pending.some((item) => item.token === pending.token)) continue;
      replacementCoordinator.pending.push({
        ...pending,
        message: `${pending.message}\n\nwatcher: FAILED - Pi extension could not persist a replacement-session actionable wake\n${detail}`
      });
    }
    throw error;
  } finally {
    const child = stopGeneration(generation);
    await waitForGenerationChildClose(child);
  }
  const currentTokens = generation.pendingActionables.map((pending) => pending.token).join("\n");
  if (replacement && currentTokens && currentTokens !== persistedTokens) {
    persistReplacementHandoff(generation.pendingActionables);
  }
}

const cleanupOnProcessExit = () => {
  if (activeGeneration) stopGeneration(activeGeneration);
};
process.once("exit", cleanupOnProcessExit);

function _default(pi) {
  let generation = createGeneration();
  activateGeneration(generation);

  let calmPresentation = {
    active: false,
    stockExportRendering: false
  };
  pi.events?.on?.(_fmCalmVisibility.FIRSTMATE_CALM_PRESENTATION_EVENT, (data) => {
    const next = data;
    calmPresentation = {
      active: next.active === true,
      stockExportRendering: next.stockExportRendering === true
    };
  });
  const calmHides = (itemClass) =>
  calmPresentation.active &&
  !calmPresentation.stockExportRendering &&
  !(0, _fmCalmVisibility.calmTranscriptClassIsVisible)(itemClass);

  async function sendWake(
  owner,
  message,
  pending)
  {
    if (!generationIsLive(owner)) return false;
    const content = (0, _fmOperationalInput.encodeFirstmateOperationalInput)(
      "watcher",
      `FIRSTMATE WATCHER WAKE: ${message}\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.`
    );
    if (pending) owner.unconsumedWakes.set(pending.token, { content, pending });
    try {
      await pi.sendUserMessage(content, { deliverAs: "followUp" });
    } catch (error) {
      if (pending) owner.unconsumedWakes.delete(pending.token);
      throw error;
    }
    // Accepted by Pi. A generation replaced while Pi was accepting it may
    // have lost the follow-up with the old session, so report it undelivered
    // and let the replacement replay the still-pending record.
    return generationIsLive(owner);
  }

  // Pi consumed a main follow-up: an idle main at before_agent_start, a
  // streaming main at the user message_start that joins the running run.
  function consumeWake(owner, text) {
    for (const [token, wake] of owner.unconsumedWakes) {
      if (wake.content !== text) continue;
      owner.unconsumedWakes.delete(token);
      wake.pending.delivered = true;
      try {
        finishPendingActionable(owner, wake.pending);
      } catch (error) {
        surfaceCleanupFailure(owner, error);
        schedulePendingCleanup(owner);
      }
      return;
    }
  }

  function confirmHandlingDelivery(recovery)


  {
    try {
      const result = (0, _nodeChild_process.spawnSync)(
        "bash",
        [armScript, "--handling-delivered", recovery.generation, "--watcher-pid", recovery.watcherPid],
        {
          cwd: fmRoot,
          encoding: "utf8",
          env: { ...process.env, FM_HOME: fmHome, FM_STATE_OVERRIDE: state, FM_ROOT_OVERRIDE: fmRoot }
        }
      );
      if (result.status === 0) return { ok: true, detail: "" };
      const stderr = (result.stderr || "").trim();
      return {
        ok: false,
        detail: `watcher: FAILED - handling delivery confirmation was rejected (status=${result.status ?? "none"} generation=${recovery.generation} watcherPid=${recovery.watcherPid})${stderr ? `\n${stderr}` : ""}`
      };
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return {
        ok: false,
        detail: `watcher: FAILED - handling delivery confirmation could not be executed (generation=${recovery.generation} watcherPid=${recovery.watcherPid})\n${message}`
      };
    }
  }

  function confirmHandlingDeliveryWithRetry(
  owner,
  recovery)
  {
    const snapshot = () => {
      const current = owner.child ? armRecovery.get(owner.child) : undefined;
      return current ?? recovery;
    };
    const first = confirmHandlingDelivery(snapshot());
    if (first.ok) return first;
    return confirmHandlingDelivery(snapshot());
  }

  function offerWakeToBranch(message) {
    const heartbeat = /^heartbeat($|:)/.test(message);
    // A check-kind close (merge-confirmation polls, Relay mentions,
    // credential/auth failures, and every other legitimately main-only
    // class - docs/pi-supervision-branch.md) is never routed to the branch
    // even when other currently-unread rows are individually eligible: this
    // watcher cycle's own triggering event stays on main, exactly as before
    // scopeForUnreadWake stopped letting a co-present check row veto the
    // whole scan. That relaxation is what lets an UNRELATED eligible
    // signal/stale row still reach the branch on this cycle; it must never
    // also let a check-kind trigger itself slip past main's delivery.
    const isCheckTrigger = /^check:/.test(message);
    const scope = (0, _fmBranchDispatch.scopeForUnreadWake)(state, heartbeat);
    // A signal close containing a needs-decision status file, or a stale close
    // for a captain-held task, gets the identical main-only treatment as a
    // check-kind trigger. The cross-reference deliberately includes every
    // unread decision row: until that row is read, a later signal or stale
    // trigger for the same task stays on main. Other tasks and heartbeat
    // handling remain independent.
    const triggerKeys = /^signal:/.test(message) ?
    message.
    slice("signal:".length).
    split(/\s+/).
    filter(Boolean).
    map((path) => path.split("/").pop() ?? path) :
    /^stale:/.test(message) ?
    [message.slice("stale:".length).trim().split(/\s+/, 1)[0]].filter(Boolean) :
    [];
    const taskIdentity = (key) =>
    scope.taskByWakeKey[key] ?? scope.taskByWakeKey[key.replace(/^fm-/, "")] ?? key;
    const needsDecisionTasks = new Set(scope.needsDecisionKeys.map(taskIdentity));
    const isNeedsDecisionTrigger = triggerKeys.some((key) => needsDecisionTasks.has(taskIdentity(key)));
    const eligible = !isCheckTrigger && !isNeedsDecisionTrigger && scope.eligible;
    const offer = (0, _fmBranchDispatch.createBranchDispatchOffer)(message, scope.projects, heartbeat, eligible);
    pi.events?.emit?.(_fmBranchDispatch.FM_BRANCH_DISPATCH_EVENT, offer);
    return offer.accepted ? offer.settlement : null;
  }

  async function deliverActionableWake(
  owner,
  message,
  repairFailed,
  pending,
  recovery)
  {
    if (!generationIsLive(owner)) return false;
    if (recovery) {
      const confirmed = confirmHandlingDeliveryWithRetry(owner, recovery);
      if (!confirmed.ok) {
        const watcherPid = recovery.watcherPid;
        if (!pidAlive(watcherPid)) {
          await retireArm(owner.child);
        }
        return await sendWake(owner, `${message}\n\n${confirmed.detail}`, pending);
      }
    }
    if (!repairFailed) {
      const branchDelivery = offerWakeToBranch(message);
      if (branchDelivery) {
        try {
          await branchDelivery;
          return true;
        } catch {}
      }
    }
    return await sendWake(owner, message, pending);
  }

  function surfaceFailure(owner, message) {
    void sendWake(owner, message).catch(() => {

      // Pi owns delivery errors; continuity restoration never waits on prompting.
    });}

  function enqueuePendingActionable(
  owner,
  pending)
  {
    if (owner.pendingActionables.some((item) => item.token === pending.token)) return;
    owner.pendingActionables.push(pending);
    if (owner.stopping && owner.replacement) {
      let replacementPending = pending;
      try {
        mergeReplacementHandoff(pending);
      } catch (error) {
        const detail = error instanceof Error ? error.message : String(error);
        replacementPending = {
          ...pending,
          message: `${pending.message}\n\nwatcher: FAILED - Pi extension could not persist a late replacement-session actionable wake\n${detail}`
        };
      }
      if (replacementCoordinator.receiver) {
        replacementCoordinator.receiver(replacementPending);
      } else if (replacementPending !== pending) {
        replacementCoordinator.pending.push(replacementPending);
      }
    }
  }

  function finishPendingActionable(owner, pending) {
    clearReplacementHandoff(pending);
    const index = owner.pendingActionables.findIndex((item) => item.token === pending.token);
    if (index >= 0) owner.pendingActionables.splice(index, 1);
    owner.cleanupFailure = "";
  }

  function surfaceCleanupFailure(
  owner,
  error)
  {
    const detail = error instanceof Error ? error.message : String(error);
    if (owner.cleanupFailure === detail) return;
    owner.cleanupFailure = detail;
    surfaceFailure(owner, `watcher: FAILED - Pi extension could not clear a delivered replacement-session actionable wake\n${detail}`);
  }

  function schedulePendingCleanup(owner) {
    if (!generationIsLive(owner) || owner.cleanupTimer) return;
    const timer = setTimeout(() => {
      if (owner.cleanupTimer === timer) owner.cleanupTimer = null;
      void processPendingActionables(owner);
    }, retryDelay(1));
    timer.unref();
    owner.cleanupTimer = timer;
  }

  async function processPendingActionables(owner) {
    if (!generationIsLive(owner) || owner.restoring || owner.pendingActionables.length === 0) return;
    owner.restoring = true;
    const attemptedCleanup = new Set();
    try {
      while (generationIsLive(owner) && owner.pendingActionables.length > 0) {
        for (const delivered of owner.pendingActionables.filter((item) => item.delivered && !attemptedCleanup.has(item.token))) {
          attemptedCleanup.add(delivered.token);
          try {
            finishPendingActionable(owner, delivered);
          } catch (error) {
            surfaceCleanupFailure(owner, error);
          }
        }
        // A record Pi has accepted but not consumed is neither redelivered
        // nor finished here: consumption finishes it, replacement replays it.
        const pending = owner.pendingActionables.find(
          (item) => !item.delivered && !owner.unconsumedWakes.has(item.token)
        );
        if (!pending) break;
        const existingClaim = replacementCoordinator.deliveries.get(pending.token);
        if (existingClaim && existingClaim.owner !== owner) {
          const settlement = await existingClaim.settlement;
          if (!generationIsLive(owner)) return;
          if (settlement === "delivered") {
            pending.delivered = true;
            continue;
          }
          if (replacementCoordinator.deliveries.get(pending.token) === existingClaim) {
            replacementCoordinator.deliveries.delete(pending.token);
          }
        }
        let settleClaim = () => {};
        const settlement = new Promise((resolveSettlement) => {
          settleClaim = resolveSettlement;
        });
        const deliveryClaim = { owner, settlement };
        replacementCoordinator.deliveries.set(pending.token, deliveryClaim);
        const releaseClaim = () => {
          if (replacementCoordinator.deliveries.get(pending.token) === deliveryClaim) {
            replacementCoordinator.deliveries.delete(pending.token);
          }
        };
        try {
          // A new restoration supersedes whatever became of the previous
          // successor; only a failure during this delivery is retried after it.
          owner.deferredClose = null;
          const restoration = await restoreAfterActionableClose(owner, pending.predecessorArmPid);
          if (!generationIsLive(owner)) {
            settleClaim("failed");
            releaseClaim();
            return;
          }
          const message = restoration.failure ? `${pending.message}\n\n${restoration.failure}` : pending.message;
          const delivered = await deliverActionableWake(owner, message, Boolean(restoration.failure), pending, restoration.recovery);
          if (!delivered) {
            settleClaim("failed");
            releaseClaim();
            return;
          }
          const awaitingConsumption = owner.unconsumedWakes.has(pending.token);
          if (awaitingConsumption && !generationIsLive(owner)) {
            // Pi accepted the follow-up, then the session was replaced before
            // this continuation ran: the shutdown persisted the still-pending
            // record, so a replacement waiting on this claim must replay it.
            settleClaim("failed");
            releaseClaim();
            return;
          }
          settleClaim("delivered");
          if (!awaitingConsumption) {
            // The branch handled it, or Pi consumed it before this ran.
            pending.delivered = true;
            try {
              finishPendingActionable(owner, pending);
            } catch (error) {
              surfaceCleanupFailure(owner, error);
            }
          }
          releaseClaim();
        } catch (error) {
          settleClaim("failed");
          releaseClaim();
          throw error;
        }
      }
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      surfaceFailure(owner, `watcher: FAILED - Pi extension could not deliver an actionable wake\n${detail}`);
    } finally {
      if (generationIsLive(owner)) {
        owner.restoring = false;
        if (owner.pendingActionables.some((pending) => pending.delivered)) schedulePendingCleanup(owner);
        // No bare arm is launched here. A generation without a child at this
        // point has either delivered a typed restoration failure after its
        // bounded retries, which hands repair to main through fm_watch_arm_pi
        // (one more silent launch past the bound could hold a hung child that
        // the repair call would then report as "unchanged"), or lost a
        // verified successor during the delivery, which takes the ordinary
        // bounded, lock-checked retry it would have taken had the pipeline
        // been idle.
        const deferred = owner.deferredClose;
        owner.deferredClose = null;
        if (deferred && !owner.child && !owner.retryTimer) {
          scheduleRetry(owner, deferred.message, deferred.predecessorArmPid);
        }
      }
    }
  }

  const receiveReplacementActionable = (pending) => {
    if (!generationIsLive(generation)) return;
    enqueuePendingActionable(generation, pending);
    void processPendingActionables(generation);
  };

  function retryDelay(attempt) {
    return Math.min(retryMaxMs, retryBaseMs * 2 ** Math.max(0, attempt - 1));
  }

  function waitForRetry(attempt) {
    return new Promise((resolveRetry) => {
      const timer = setTimeout(resolveRetry, retryDelay(attempt));
      timer.unref();
    });
  }

  function waitForReadiness(armChild) {
    const readiness = armReadiness.get(armChild);
    if (!readiness) return Promise.resolve(false);
    return new Promise((resolveReady) => {
      const timer = setTimeout(() => resolveReady(false), armReadyTimeoutMs);
      timer.unref();
      void readiness.then((ready) => {
        clearTimeout(timer);
        resolveReady(ready);
      });
    });
  }

  async function retireArm(armChild) {
    if (!armChild) return true;
    armRetired.add(armChild);
    armChild.kill("SIGTERM");
    const closed = armClose.get(armChild);
    if (!closed) return false;
    return new Promise((resolveRetired) => {
      const timer = setTimeout(() => resolveRetired(false), armRetireTimeoutMs);
      timer.unref();
      void closed.then(() => {
        clearTimeout(timer);
        resolveRetired(true);
      });
    });
  }

  async function restoreAfterActionableClose(owner, predecessorArmPid)


  {
    let failure = "";
    for (let attempt = 0; attempt <= retryLimit; attempt += 1) {
      if (!generationIsLive(owner)) return { failure: "" };
      const replacement = startArm(owner, predecessorArmPid);
      const successorChild = owner.child;
      if (replacement.ok && successorChild && (await waitForReadiness(successorChild))) {
        return { failure: "", recovery: armRecovery.get(successorChild) };
      }
      if (replacement.ok) {
        failure = "watcher: FAILED - Pi extension could not verify a ready successor watcher";
        if (!(await retireArm(successorChild))) {
          return {
            failure: `${failure}\nwatcher: FAILED - Pi extension could not restore watcher continuity because the unready successor arm did not exit within ${armRetireTimeoutMs}ms`
          };
        }
      } else {
        failure = /(?:read-only|no live session)/.test(replacement.message) ?
        `watcher: FAILED - Pi extension cannot restore continuity because this session no longer owns the lock\n${replacement.message}` :
        `watcher: FAILED - Pi extension could not start the successor watcher cycle\n${replacement.message}`;
        if (/(?:read-only|no live session)/.test(replacement.message)) break;
      }
      if (attempt === retryLimit) break;
      await waitForRetry(attempt + 1);
    }
    return { failure: `${failure}\nwatcher: FAILED - Pi extension could not restore watcher continuity after ${retryLimit} retries` };
  }

  function scheduleRetry(owner, message, predecessorArmPid) {
    if (!generationIsLive(owner) || owner.child || owner.retryTimer) return;
    const ownership = lockOwnership();
    if (ownership !== "owned") {
      surfaceFailure(owner, `watcher: FAILED - Pi extension cannot restore continuity because this session no longer owns the lock\n${message}`);
      return;
    }
    owner.retryFailures += 1;
    if (owner.retryFailures > retryLimit) {
      surfaceFailure(owner, `watcher: FAILED - Pi extension could not restore watcher continuity after ${retryLimit} retries\n${message}`);
      return;
    }
    const timer = setTimeout(() => {
      if (owner.retryTimer === timer) owner.retryTimer = null;
      if (!generationIsLive(owner)) return;
      const result = startArm(owner, predecessorArmPid);
      if (!result.ok) {
        surfaceFailure(owner, `watcher: FAILED - Pi extension could not launch a continuity retry\n${result.message}`);
      }
    }, retryDelay(owner.retryFailures));
    timer.unref();
    owner.retryTimer = timer;
  }

  function startArm(owner, predecessorArmPid = "") {
    if (!generationIsLive(owner)) return { ok: false, message: shuttingDownMessage };
    const ownership = lockOwnership();
    if (ownership === "other") return { ok: false, message: "watcher: read-only - session lock is held by another firstmate session" };
    if (ownership === "missing") {
      return {
        ok: false,
        message: "watcher: not armed - no live session holds the lock; run bin/fm-session-start.sh to reclaim it, then call fm_watch_arm_pi to re-arm"
      };
    }
    markLoaded();
    if (owner.child) {
      return {
        ok: true,
        message: `watcher: unchanged - Pi extension already owns an arm child; no manual re-arm needed; ${repairOnlyHint}`
      };
    }
    if (owner.retryTimer) {
      return {
        ok: true,
        message: `watcher: unchanged - Pi extension already owns a scheduled continuity retry; no manual re-arm needed; ${repairOnlyHint}`
      };
    }
    const id = ++owner.seq;
    const env = {
      ...process.env,
      FM_HOME: fmHome,
      FM_ROOT_OVERRIDE: fmRoot,
      FM_CONFIG_OVERRIDE: config,
      FM_WATCH_ARM_SCRIPT: armScript,
      FM_WATCH_PREDECESSOR_ARM_PID: predecessorArmPid
    };
    const armChild = (0, _nodeChild_process.spawn)("bash", ["-lc", "config_dir=\"${FM_CONFIG_OVERRIDE:-$FM_HOME/config}\"; [ -f \"$config_dir/x-mode.env\" ] && . \"$config_dir/x-mode.env\"; exec \"$FM_WATCH_ARM_SCRIPT\" --restart"], {
      cwd: fmRoot,
      env,
      stdio: ["ignore", "pipe", "pipe"]
    });
    owner.child = armChild;
    let stdout = "";
    let stderr = "";
    let settled = false;
    let readinessSettled = false;
    let verified = false;
    let resolveReadiness = () => {};
    let resolveClosed = () => {};
    const readiness = new Promise((resolveReady) => {
      resolveReadiness = resolveReady;
    });
    armReadiness.set(armChild, readiness);
    const closed = new Promise((resolveClosedChild) => {
      resolveClosed = resolveClosedChild;
    });
    armClose.set(armChild, closed);
    const settleReadiness = (ready) => {
      if (readinessSettled) return;
      readinessSettled = true;
      verified = ready;
      resolveReadiness(ready);
    };
    const observeEstablishedArm = () => {
      const combined = `${stdout}\n${stderr}`;
      const recovery = combined.match(/^watcher: started pid=([0-9]+).* recovery-generation=([A-Za-z0-9._-]+)$/m);
      if (recovery) armRecovery.set(armChild, { watcherPid: recovery[1], generation: recovery[2] });
      if (/^watcher: (?:started|attached)\b/m.test(combined)) {
        settleReadiness(true);
      }
      const reason = completedActionableLine(stdout) || completedActionableLine(stderr);
      if (reason && !armPendingActionable.has(armChild)) {
        const pending = createPendingActionable(reason, String(armChild.pid ?? ""));
        armPendingActionable.set(armChild, pending);
        enqueuePendingActionable(owner, pending);
      }
    };
    const releaseChild = () => {
      if (owner.child === armChild) owner.child = null;
    };
    armChild.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
      observeEstablishedArm();
    });
    armChild.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
      observeEstablishedArm();
    });
    armChild.on("close", (code, signal) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      settleReadiness(false);
      releaseChild();
      const classification = classifyClose(stdout, stderr, code, signal);
      const predecessor = String(armChild.pid ?? "");
      if (classification.kind === "actionable") {
        const pending = armPendingActionable.get(armChild) ?? createPendingActionable(classification.message, predecessor);
        enqueuePendingActionable(owner, pending);
        if (!generationIsLive(owner)) return;
        owner.retryFailures = 0;
        void processPendingActionables(owner);
        return;
      }
      if (!generationIsLive(owner)) return;
      if (owner.restoring) {
        // The pipeline is still delivering the wake this successor was
        // started for. A verified successor that failed on its own keeps its
        // bounded retry for the end of that delivery; an unready child closing
        // here was retired by the restoration itself.
        if (verified && !armRetired.has(armChild)) {
          owner.deferredClose = { message: classification.message, predecessorArmPid: predecessor };
        }
        return;
      }
      scheduleRetry(owner, classification.message, predecessor);
    });
    armChild.on("error", (error) => {
      if (settled) return;
      settled = true;
      resolveClosed();
      settleReadiness(false);
      releaseChild();
      if (!generationIsLive(owner)) return;
      if (owner.restoring) return;
      scheduleRetry(owner, `watcher: FAILED - Pi extension arm child ${id} failed: ${error.message}`, String(armChild.pid ?? ""));
    });
    return {
      ok: true,
      message: `watcher: started Pi extension arm child ${id}; future ordinary re-arms are automatic; ${repairOnlyHint}`
    };
  }

  function activateOwnedWatch(owner) {
    if (!generationIsLive(owner)) return { ok: false, message: shuttingDownMessage };
    if (lockOwnership() !== "owned") return startArm(owner);
    replacementCoordinator.receiver = receiveReplacementActionable;
    let pending = [];
    let loadFailure = "";
    try {
      pending = loadReplacementHandoff();
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      loadFailure = `watcher: FAILED - Pi extension could not load a replacement-session actionable wake\n${detail}`;
    }
    const inProcessPending = replacementCoordinator.pending.splice(0);
    for (const actionable of [...pending, ...inProcessPending]) {
      enqueuePendingActionable(owner, actionable);
    }
    if (owner.pendingActionables.length > 0) {
      if (loadFailure) surfaceFailure(owner, loadFailure);
      const armResult = startArm(owner, owner.pendingActionables[0].predecessorArmPid);
      if (!armResult.ok) {
        surfaceFailure(owner, `watcher: FAILED - Pi extension could not arm before replacement wake delivery\n${armResult.message}`);
      }
      void processPendingActionables(owner);
      return armResult;
    }
    const result = startArm(owner);
    if (loadFailure) surfaceFailure(owner, `${loadFailure}\n${result.message}`);
    return result;
  }

  pi.on?.("before_agent_start", (event) => {
    consumeWake(generation, event.prompt);
  });
  pi.on?.("message_start", (event) => {
    if (event.message.role !== "user") return;
    consumeWake(generation, userMessageText(event.message.content));
  });

  pi.on?.("session_start", async () => {
    if (generation.stopping) generation = createGeneration();
    activateGeneration(generation);
    markLoaded();
    if (lockOwnership() !== "owned") return;
    activateOwnedWatch(generation);
  });
  pi.on?.("session_shutdown", async (event) => {
    const replacement = event.reason === "reload" || event.reason === "new" || event.reason === "resume" || event.reason === "fork";
    if (replacementCoordinator.receiver === receiveReplacementActionable) replacementCoordinator.receiver = null;
    await stopSessionGeneration(generation, replacement);
  });

  pi.registerCommand?.("fm-watch-arm-pi", {
    description: "Arm firstmate watcher supervision through the Pi extension instead of foreground bash.",
    handler: async (_args, ctx) => {
      const result = activateOwnedWatch(generation);
      ctx.ui.notify(result.message, result.ok ? "info" : "warning");
    }
  });

  (0, _fmNativeContract.registerFirstmateTool)(pi, {
    name: "fm_watch_arm_pi",
    label: "Arm firstmate watcher",
    description: "Start the first required Pi watcher cycle, or repair one only after a notification says the cycle is missing, failed, or unhealthy. Do not call after ordinary work or ordinary notifications; the Pi extension re-arms automatically. Never run bin/fm-watch-arm.sh through bash.",
    promptSnippet: "Start the first required Pi watcher cycle or repair a cycle reported missing, failed, or unhealthy; ordinary re-arming is automatic.",
    promptGuidelines: [
    "Call fm_watch_arm_pi only for the first required cycle or after a notification says the cycle is missing, failed, or unhealthy. Do not call it after ordinary work, turn completion, or ordinary signal, stale, check, or heartbeat handling because the Pi extension owns re-arming. Never run bin/fm-watch-arm.sh through bash."],

    parameters: _typebox.Type.Object({}),
    renderShell: "self",
    renderCall: (_args, theme, context) => {
      if (calmHides("assistant-tool-call")) return new _piTui.Container();
      if (calmPresentation.stockExportRendering) {
        return new _piTui.Text(theme.fg("toolTitle", theme.bold("fm_watch_arm_pi")), 0, 0);
      }
      const state = context.state;
      state.call = new _piTui.Text(theme.fg("toolTitle", theme.bold("fm_watch_arm_pi")), 0, 0);
      return refreshWatchToolShell(state, theme, context);
    },
    renderResult: (result, _options, theme, context) => {
      if (calmHides("tool-result")) return new _piTui.Container();
      const output = result.content.
      filter((item) => item.type === "text").
      map((item) => item.text).
      join("\n");
      if (calmPresentation.stockExportRendering) {
        return new _piTui.Text(theme.fg("toolOutput", output), 0, 0);
      }
      const state = context.state;
      state.result = output ?
      new _piTui.Text(theme.fg("toolOutput", output), 0, 0) :
      new _piTui.Container();
      refreshWatchToolShell(state, theme, context);
      return new _piTui.Container();
    },
    execute: async () => {
      const result = activateOwnedWatch(generation);
      return {
        content: [{ type: "text", text: result.message }],
        details: result
      };
    }
  });

  markLoaded();
} /* v9-e35c126488eedcf7 */
