"use strict";Object.defineProperty(exports, "__esModule", { value: true });exports.FM_BRANCH_DISPATCH_EVENT = exports.BRANCH_ELIGIBLE_ROWS_FILE = void 0;exports.activateEligibleRowsOwner = activateEligibleRowsOwner;exports.createBranchDispatchOffer = createBranchDispatchOffer;exports.deactivateEligibleRowsOwner = deactivateEligibleRowsOwner;exports.releaseEligibleRowsSnapshot = releaseEligibleRowsSnapshot;exports.scopeForUnreadWake = scopeForUnreadWake;exports.writeEligibleRowsSnapshot = writeEligibleRowsSnapshot;var _nodeFs = await jitiImport("node:fs");
var _fmAsyncExec = await jitiImport("./fm-async-exec.ts");

// Shared wake-dispatch handshake between the Pi watcher extension (the
// dispatcher) and the supervision-branch extension (the handler), carried over
// pi.events so neither extension imports the other.
//
// Contract: the watcher builds one offer per actionable wake and emits it on
// FM_BRANCH_DISPATCH_EVENT. A live, enabled branch extension calls accept()
// SYNCHRONOUSLY inside its handler (the event bus invokes handlers
// synchronously up to their first await), so after emit returns the watcher
// reads `accepted`: true means the branch owns handling the wake, and its
// settlement promise keeps the watcher outcome pending until handling finishes
// or rejects back to the watcher's consumption-acknowledged main path; false
// means no branch took it and the watcher delivers to main exactly as it did
// before the branch existed. Watcher-failure alarms are never offered - only
// main can repair the watcher cycle (fm_watch_arm_pi lives on main).

const FM_BRANCH_DISPATCH_EVENT = exports.FM_BRANCH_DISPATCH_EVENT = "fm-branch-supervision:dispatch";



















































const EMPTY_SCOPE = {
  status: "empty",
  eligible: false,
  projects: [],
  eligibleSeqs: [],
  presentedTaskBySeq: {},
  eligibleTasks: [],
  corrupted: false,
  needsDecisionKeys: [],
  taskByWakeKey: {}
};
const UNSAFE_SCOPE = {
  status: "unsafe",
  eligible: false,
  projects: [],
  eligibleSeqs: [],
  presentedTaskBySeq: {},
  eligibleTasks: [],
  corrupted: true,
  needsDecisionKeys: [],
  taskByWakeKey: {}
};

// scopeForUnreadWake is the single owner of branch-eligibility classification
// (docs/pi-supervision-branch.md "Autonomy"; docs/watcher-continuity.md
// "Per-actor acknowledgement"). bin/fm-wake-drain.sh never reclassifies a row
// itself - it only consumes the exact sequence-number snapshot this function
// (via writeEligibleRowsSnapshot) hands it.
//
// A check-kind row - merge-confirmation polls, Relay mentions, credential/auth
// failures, and every other legitimately main-only class - never vetoes a scan
// in either mode. It is simply excluded from eligibleSeqs and left queued for
// main, which is woken for it on that check's own watcher cycle
// (fm-primary-pi-watch.ts forces every check-kind TRIGGER to main), so nothing
// starves by being left behind.
//
// A signal row whose payload is "needs-decision:"-prefixed, or a stale row
// for a task with an open needs-decision or a current captain-held declaration,
// gets the identical treatment: excluded from eligibleSeqs, never a scan veto,
// and forced to main on its own triggering close (fm-primary-pi-watch.ts's
// offerWakeToBranch). Heartbeat handling remains independent.
//
// That applies to a heartbeat review too, and it is the whole point: a
// heartbeat used to be deferred to main merely because some unrelated check
// row happened to be sitting unread, which put a routine fleet review in the
// captain's chat for a reason that had nothing to do with the fleet. A
// permanently main-owned row is not fleet context the branch is missing, so it
// no longer rides the heartbeat into main (docs/pi-supervision-branch.md
// "Heartbeat routing").
//
// The heartbeat's all-or-nothing contract is unchanged in what it actually
// guarantees: a heartbeat review takes EVERY branch-ownable unread row or none
// of them. An unresolvable signal/stale row (unmapped project) still vetoes the
// whole scan in both modes, because that is a data/metadata problem this
// function cannot safely reason past, not an ordinary main-only event. A row
// this repo's fm_wake_append could never have produced (an unknown kind, or a
// line that fails the structural tab-field check) also still vetoes the whole
// scan - that is queue corruption, not an everyday mixed queue.
function statusLineVerb(line) {
  const beforeColon = line.split(":", 1)[0].split("[", 1)[0].trim();
  const words = beforeColon.split(/\s+/);
  if (!words.some((word) => word.startsWith("corr="))) return beforeColon;
  return words.filter((word, index) => index === 0 || !/^corr=[0-9a-f]{16}$/i.test(word)).join(" ");
}

function decisionKey(line) {
  const colon = line.indexOf(":");
  const beforeColon = colon < 0 ? line : line.slice(0, colon);
  const beforeMatch = beforeColon.match(/\[key=([^\]]*)\]/);
  const noteMatch = beforeMatch || colon < 0 ? null : line.slice(colon + 1).trimStart().match(/^\[key=([^\]]*)\]/);
  const key = (beforeMatch ?? noteMatch)?.[1] ?? "default";
  return /^[A-Za-z0-9._-]+$/.test(key) ? key : null;
}

function statusLineNote(line) {
  const colon = line.indexOf(":");
  if (colon < 0) return line;
  const note = line.slice(colon + 1).trimStart();
  if (/\[key=[^\]]*\]/.test(line.slice(0, colon))) return note;
  const match = note.match(/^\[key=([A-Za-z0-9._-]+)\]/);
  return match ? note.slice(match[0].length).trimStart() : note;
}







const staleDecisionCache = new Map();

function statusFileVersion(path) {
  try {
    const stat = (0, _nodeFs.lstatSync)(path);
    if (stat.isSymbolicLink()) throw new Error("status path is a symbolic link");
    return `${stat.dev}:${stat.ino}:${stat.size}:${stat.mtimeMs}:${stat.ctimeMs}`;
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}

function hasOpenNeedsDecision(
lines,
resolveVerb,
heldVerb,
reservedPrefixes)
{
  const open = new Map();
  for (const line of lines) {
    const verb = statusLineVerb(line);
    if (!["needs-decision", "blocked", resolveVerb, heldVerb].includes(verb)) continue;
    const key = decisionKey(line);
    if (!key) continue;
    const note = statusLineNote(line);
    const reservedPrefix = reservedPrefixes.find((prefix) => key.startsWith(prefix));
    if (reservedPrefix && !(note.startsWith(reservedPrefix) && note.slice(reservedPrefix.length).includes(":"))) continue;
    if (verb === "needs-decision" || verb === "blocked") open.set(key, verb);else
    open.delete(key);
  }
  return [...open.values()].includes("needs-decision");
}

function scopeForUnreadWake(state, heartbeat) {
  let queue = "";
  try {
    queue = (0, _nodeFs.readFileSync)(`${state}/.wake-queue`, "utf8");
  } catch {
    return UNSAFE_SCOPE;
  }

  const rows = queue.split(/\r?\n/).filter((line) => line.length > 0);
  if (rows.length === 0) return EMPTY_SCOPE;

  const projects = new Set();
  const metadata = new Map();
  // The task id behind each key a signal or stale row may carry: the task id
  // itself, or the endpoint its metadata records.
  const taskByKey = new Map();
  try {
    for (const name of (0, _nodeFs.readdirSync)(state)) {
      if (!name.endsWith(".meta")) continue;
      const task = name.slice(0, -5);
      const fields = (0, _nodeFs.readFileSync)(`${state}/${name}`, "utf8").split(/\r?\n/);
      const project = fields.find((line) => line.startsWith("project="))?.slice(8) ?? "";
      const window = fields.find((line) => line.startsWith("window="))?.slice(7) ?? "";
      if (project) {
        metadata.set(task, project);
        taskByKey.set(task, task);
        taskByKey.set(`${task}.status`, task);
        taskByKey.set(`${task}.turn-ended`, task);
        if (window) {
          metadata.set(window, project);
          taskByKey.set(window, task);
        }
      }
    }
  } catch {
    return UNSAFE_SCOPE;
  }

  const eligibleSeqs = [];
  const presentedRowsByKey = new Map();
  const needsDecisionKeys = [];
  const staleDecisionOwnership = new Map();
  const resolveVerb = process.env.FM_CLASSIFY_RESOLVE_VERB || "resolved";
  const heldVerb = process.env.FM_CLASSIFY_CAPTAIN_HELD_VERB || "captain-held";
  const reservedPrefixes = (process.env.FM_CLASSIFY_RESERVED_KEY_PREFIXES || "pending-reply-").
  split(/\s+/).
  filter(Boolean);
  const decisionConfig = `${resolveVerb}\0${heldVerb}\0${reservedPrefixes.join("\0")}`;
  for (const line of rows) {
    const fields = line.split("\t");
    if (fields.length < 5 || !/^[0-9]+$/.test(fields[1])) return UNSAFE_SCOPE;
    const seq = fields[1];
    const kind = fields[2];
    const key = fields[3];
    if (kind === "heartbeat") {
      if (heartbeat) {
        eligibleSeqs.push(seq);
        presentedRowsByKey.set("heartbeat", { seq, task: null, project: "" });
      }
      continue;
    }
    if (kind === "check") {
      // Always main-owned, in every mode: excluded from what the branch may
      // claim, never a reason to reject the rest of the queue and never a
      // reason to send an otherwise-eligible heartbeat review to main.
      continue;
    }
    let project = "";
    let task = "";
    if (kind === "signal") {
      const payload = fields[4] ?? "";
      if (/^needs-decision:/.test(payload)) {
        // Main-owned exactly like a check-kind row above: a needs-decision
        // status append surfaced through the actionable signal path is
        // excluded from what the branch may claim without vetoing the scan
        // (docs/pi-supervision-branch.md "Autonomy").
        needsDecisionKeys.push(key);
        continue;
      }
      task = key.replace(/\.(?:status|turn-ended)$/, "");
      project = metadata.get(task) ?? "";
    } else if (kind === "stale") {
      task = taskByKey.get(key) ?? taskByKey.get(key.replace(/^fm-/, "")) ?? "";
      project = metadata.get(key) ?? metadata.get(key.replace(/^fm-/, "")) ?? "";
      if (task) {
        const statusPath = `${state}/${task}.status`;
        if (!staleDecisionOwnership.has(statusPath)) {
          let version;
          try {
            version = statusFileVersion(statusPath);
          } catch {
            return UNSAFE_SCOPE;
          }
          let decisionOwned = false;
          if (version) {
            const cached = staleDecisionCache.get(statusPath);
            if (cached?.version === version && cached.config === decisionConfig) {
              decisionOwned = cached.decisionOwned;
            } else {
              let statusLines;
              try {
                statusLines = (0, _nodeFs.readFileSync)(statusPath, "utf8").split(/\r?\n/).filter((line) => /\S/.test(line));
                if (statusFileVersion(statusPath) !== version) return UNSAFE_SCOPE;
              } catch {
                return UNSAFE_SCOPE;
              }
              decisionOwned = hasOpenNeedsDecision(statusLines, resolveVerb, heldVerb, reservedPrefixes) ||
              statusLineVerb(statusLines.at(-1) ?? "") === heldVerb;
              staleDecisionCache.set(statusPath, { version, config: decisionConfig, decisionOwned });
              if (staleDecisionCache.size > 512) {
                staleDecisionCache.delete(staleDecisionCache.keys().next().value);
              }
            }
          } else {
            staleDecisionCache.delete(statusPath);
          }
          staleDecisionOwnership.set(statusPath, decisionOwned);
        }
        if (staleDecisionOwnership.get(statusPath)) {
          needsDecisionKeys.push(key);
          continue;
        }
      }
    } else {
      // A kind fm_wake_append never emits: structural corruption, not an
      // ordinary main-only row.
      return UNSAFE_SCOPE;
    }
    if (!project || !task) return UNSAFE_SCOPE;
    eligibleSeqs.push(seq);
    presentedRowsByKey.set(`${kind}\0${key}`, { seq, task, project });
  }
  const presentedRows = [...presentedRowsByKey.values()];
  const presentedTaskBySeq = Object.fromEntries(presentedRows.map(({ seq, task }) => [seq, task]));
  const eligibleTasks = new Set();
  for (const { task, project } of presentedRows) {
    if (project) projects.add(project);
    if (task) eligibleTasks.add(task);
  }
  const eligible = eligibleSeqs.length > 0;
  // Reached only after every row passed classification without a veto. A scan
  // that ends up ineligible simply found nothing the branch may claim - a
  // queue of purely main-only content, not a fault. (Before check rows stopped
  // vetoing a heartbeat, this point was unreachable for a heartbeat with an
  // empty eligible set, so reading eligibility off the claim set rather than
  // off the heartbeat flag changes no pre-existing outcome and keeps a
  // heartbeat from being offered with nothing to hand over.)
  return {
    status: eligible ? "safe" : "unsafe",
    eligible,
    projects: [...projects],
    eligibleSeqs,
    presentedTaskBySeq,
    eligibleTasks: [...eligibleTasks],
    corrupted: false,
    needsDecisionKeys,
    taskByWakeKey: Object.fromEntries(taskByKey)
  };
}

// The exact state-relative filename bin/fm-wake-drain.sh reads for a
// FM_SUPERVISION_ACTOR=branch drain or ack (its header is the single owner of
// the consume-side contract). Written atomically, immediately before every
// branch prompt, by writeEligibleRowsSnapshot below.
const BRANCH_ELIGIBLE_ROWS_FILE = exports.BRANCH_ELIGIBLE_ROWS_FILE = ".branch-eligible-rows";

// Atomically publish the exact row set a branch turn may drain and
// acknowledge. One sequence number per line - an opaque handoff, never
// reclassified by the consumer. A main-owned result means the competing main
// turn won the queue-lock claim and already owns presentation; error means no
// actor acquired the requested rows.


// Awaited rather than synchronous because every caller runs on the Pi thread
// that draws the captain's TUI (lib/fm-async-exec.ts). The grant script itself
// is unchanged, and so is each result: a null status still means the script
// could not be run at all.
async function runGrantScript(
state,
grantScript,
args)
{
  const result = await (0, _fmAsyncExec.runCommandAsync)("bash", [grantScript, ...args], {
    env: {
      ...process.env,
      FM_STATE_OVERRIDE: state,
      FM_WAKE_QUEUE: `${state}/.wake-queue`,
      FM_WAKE_QUEUE_LOCK: `${state}/.wake-queue.lock`
    }
  });
  return result.status;
}

async function activateEligibleRowsOwner(
state,
grantScript,
ownerPid,
generation)
{
  return (await runGrantScript(state, grantScript, ["activate", String(ownerPid), generation])) === 0;
}

async function writeEligibleRowsSnapshot(
state,
seqs,
grantScript,
generation)
{
  if (seqs.length === 0 || seqs.some((seq) => !/^[0-9]+$/.test(seq))) return "error";
  const status = await runGrantScript(state, grantScript, ["publish", generation, ...seqs]);
  if (status === 0) return "published";
  if (status === 3) return "main-owned";
  return "error";
}

async function releaseEligibleRowsSnapshot(
state,
grantScript,
generation)
{
  return (await runGrantScript(state, grantScript, ["release", generation])) === 0;
}

async function deactivateEligibleRowsOwner(
state,
grantScript,
ownerPid,
generation)
{
  return (await runGrantScript(state, grantScript, ["deactivate", String(ownerPid), generation])) === 0;
}



















function createBranchDispatchOffer(
message,
projects = [],
heartbeat = false,
eligible = false)
{
  const offer = {
    message,
    projects: [...projects],
    heartbeat,
    eligible,
    accepted: false,
    settlement: Promise.resolve(),
    accept(settlement = Promise.resolve()) {
      offer.accepted = true;
      offer.settlement = settlement;
    }
  };
  return offer;
} /* v9-d6fabc158ee76646 */
