"use strict";Object.defineProperty(exports, "__esModule", { value: true });exports.default = _default;var _piAi = await jitiImport("@earendil-works/pi-ai");




var _fmOperationalInput = await jitiImport("./lib/fm-operational-input.ts");

function _default(pi) {
  pi.registerProvider("calm-e2e", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "test-only",
    api: "calm-e2e-api",
    models: [
    {
      id: "delayed",
      name: "Delayed Calm working-row fixture",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 4096,
      maxTokens: 128
    },
    {
      id: "delayed-boat",
      name: "Long-delay Calm working-ship fixture",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 4096,
      maxTokens: 128
    },
    {
      id: "operational-error",
      name: "Calm gapless operational-row fixture",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 4096,
      maxTokens: 128
    }],

    streamSimple(model, _context, options) {
      const stream = (0, _piAi.createAssistantMessageEventStream)();
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
      void (async () => {
        if (model.id === "operational-error") {
          await new Promise((resolve) => setTimeout(resolve, 25));
          output.stopReason = "error";
          output.errorMessage = "CALM_OPERATIONAL_E2E_ERROR";
          stream.push({ type: "error", reason: "error", error: output });
          stream.end();
          return;
        }
        // Wake as soon as the run is aborted so Escape settles the turn promptly.
        await new Promise((resolve) => {
          const timer = setTimeout(resolve, model.id === "delayed-boat" ? 90000 : 1500);
          options?.signal?.addEventListener(
            "abort",
            () => {
              clearTimeout(timer);
              resolve();
            },
            { once: true }
          );
        });
        if (options?.signal?.aborted) {
          output.stopReason = "aborted";
          stream.push({ type: "error", reason: "aborted", error: output });
          stream.end();
          return;
        }
        stream.push({ type: "start", partial: output });
        const block = { type: "text", text: "" };
        output.content.push(block);
        stream.push({ type: "text_start", contentIndex: 0, partial: output });
        block.text = "CALM_WORKING_E2E_RESPONSE";
        stream.push({ type: "text_delta", contentIndex: 0, delta: block.text, partial: output });
        stream.push({ type: "text_end", contentIndex: 0, content: block.text, partial: output });
        stream.push({ type: "done", reason: "stop", message: output });
        stream.end();
      })();
      return stream;
    }
  });

  pi.registerCommand("calm-diagnostic-e2e", {
    description: "Add the Calm transient diagnostic fixture.",
    handler: async (_args, ctx) => {
      ctx.ui.notify("CALM_TRANSIENT_DIAGNOSTIC", "warning");
    }
  });
  pi.registerCommand("calm-inject-e2e", {
    description: "Inject one current Calm operational kind.",
    handler: async (args, ctx) => {
      const fixtures = new Map([
      ["watcher", "CURRENT_WATCHER_E2E /tmp/active-probe.status"],
      ["turn-end-guard", "CURRENT_TURN_END_E2E"],
      ["away-supervisor", "CURRENT_AWAY_E2E"],
      ["from-firstmate", "corr=0123456789abcdef CURRENT_FROM_FIRSTMATE_E2E"],
      ["launch-brief", "CURRENT_LAUNCH_BRIEF_E2E"]]
      );
      const kind = args.trim();
      const body = fixtures.get(kind);
      if (!body) throw new Error(`unknown current operational kind: ${kind}`);
      const model = ctx.modelRegistry.find("calm-e2e", "operational-error");
      if (!model || !(await pi.setModel(model))) {
        throw new Error("could not select the deterministic Calm operational-error model");
      }
      await pi.sendUserMessage((0, _fmOperationalInput.encodeFirstmateOperationalInput)(kind, body), {
        deliverAs: "followUp"
      });
    }
  });
  pi.registerCommand("calm-boat-e2e", {
    description: "Start the long-delay working-ship fixture.",
    handler: async (_args, ctx) => {
      const model = ctx.modelRegistry.find("calm-e2e", "delayed-boat");
      if (!model || !(await pi.setModel(model))) {
        throw new Error("could not select the long-delay Calm E2E model");
      }
      await pi.sendUserMessage("CALM_BOAT_E2E_PROMPT");
    }
  });
  pi.registerCommand("calm-working-e2e", {
    description: "Start the delayed native Working-row fixture.",
    handler: async (_args, ctx) => {
      const model = ctx.modelRegistry.find("calm-e2e", "delayed");
      if (!model || !(await pi.setModel(model))) {
        throw new Error("could not select the deterministic Calm E2E model");
      }
      await pi.sendUserMessage("CALM_WORKING_E2E_PROMPT");
    }
  });
} /* v9-118f9974d6a62e2c */
