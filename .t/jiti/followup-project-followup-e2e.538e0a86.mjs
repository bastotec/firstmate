"use strict";Object.defineProperty(exports, "__esModule", { value: true });exports.default = _default;var _piAi = await jitiImport("@earendil-works/pi-ai");




var _fmOperationalInput = await jitiImport("./.pi/extensions/lib/fm-operational-input.ts");

let phase = "idle";
let label = "";
let adjacent = false;
let latestInputRole;

const EXACT_WATCHER_INPUT =
"\u2063FIRSTMATE_OP: v1 watcher: FIRSTMATE WATCHER WAKE: signal: /home/fixture/github/kunchenguid/firstmate/state/oss-triage-t4.status\n\n" +
"Run bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.";

function monitorInput(suffix) {
  if (label === "exact_watcher" && suffix === "ONE") return EXACT_WATCHER_INPUT;
  if (label === "legacy_away" && suffix === "ONE") {
    return "\u2063Supervisor escalate (LEGACY_AWAY_E2E)";
  }
  return (0, _fmOperationalInput.encodeFirstmateOperationalInput)("watcher", `MONITOR_${label}_${suffix}`);
}

function contentText(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content.
  filter((item) =>
  typeof item === "object" && item !== null &&
  item.type === "text" &&
  typeof item.text === "string").
  map((item) => item.text).
  join("\n");
}

function _default(pi) {
  pi.on("message_start", (event) => {
    if (event.message.role === "user" || event.message.role === "custom") {
      latestInputRole = event.message.role;
    }
    if (event.message.role !== "assistant" || phase !== "captain") return;
    phase = "monitor";
    pi.sendUserMessage(monitorInput("ONE"), { deliverAs: "followUp" });
    if (adjacent) {
      pi.sendUserMessage(monitorInput("TWO"), { deliverAs: "followUp" });
    }
  });

  pi.registerProvider("followup-e2e", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "test-only",
    api: "followup-e2e-api",
    models: [{
      id: "deterministic",
      name: "Deterministic operational follow-up regression",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 4096,
      maxTokens: 128
    }],
    streamSimple(model, context) {
      const stream = (0, _piAi.createAssistantMessageEventStream)();
      const allUserText = context.messages.
      filter((message) => message.role === "user").
      map((message) => contentText(message.content)).
      join("\n");
      const responseText = latestInputRole === "custom" ?
      `CAPTAIN_ANSWER_${label}` :
      allUserText.includes(monitorInput("ONE")) ?
      adjacent && allUserText.includes(monitorInput("TWO")) ?
      `MONITOR_HANDLED_${label}_ONE_TWO` :
      `MONITOR_HANDLED_${label}_ONE` :
      `CAPTAIN_ANSWER_${label}`;
      const output = {
        role: "assistant",
        content: [],
        api: model.api,
        provider: model.provider,
        model: model.id,
        usage: {
          input: 0,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 }
        },
        stopReason: "stop",
        timestamp: Date.now()
      };
      queueMicrotask(() => {
        stream.push({ type: "start", partial: output });
        const block = { type: "text", text: responseText };
        output.content.push(block);
        stream.push({ type: "text_start", contentIndex: 0, partial: output });
        stream.push({ type: "text_delta", contentIndex: 0, delta: responseText, partial: output });
        stream.push({ type: "text_end", contentIndex: 0, content: responseText, partial: output });
        stream.push({ type: "done", reason: "stop", message: output });
        stream.end();
      });
      return stream;
    }
  });

  pi.registerCommand("followup-e2e", {
    description: "Run one captain prompt followed by typed monitoring input.",
    handler: async (args, ctx) => {
      const [nextLabel, shape] = args.trim().split(/\s+/);
      if (!nextLabel) throw new Error("missing follow-up E2E label");
      const model = ctx.modelRegistry.find("followup-e2e", "deterministic");
      if (!model || !(await pi.setModel(model))) throw new Error("follow-up E2E model unavailable");
      label = nextLabel;
      adjacent = shape === "adjacent";
      phase = "captain";
      pi.sendUserMessage(`CAPTAIN_PROMPT_${label}`);
    }
  });
} /* v9-21d8f79977f96b05 */
