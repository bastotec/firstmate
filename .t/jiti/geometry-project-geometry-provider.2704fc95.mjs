"use strict";Object.defineProperty(exports, "__esModule", { value: true });exports.default = _default;var _piAi = await jitiImport("@earendil-works/pi-ai");








function _default(pi) {
  const faux = (0, _piAi.createFauxCore)({
    api: "calm-geometry-e2e-api",
    provider: "calm-geometry-e2e",
    models: [{
      id: "deterministic",
      name: "Calm hidden-block geometry E2E",
      reasoning: true,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 4096,
      maxTokens: 128
    }],
    tokenSize: { min: 1, max: 1 }
  });
  faux.setResponses([
  (0, _piAi.fauxAssistantMessage)([
  (0, _piAi.fauxThinking)("CALM_GEOMETRY_THINKING_ONE"),
  (0, _piAi.fauxToolCall)("read", { path: "probe-one.txt" }, { id: "calm_geometry_read_one" })],
  { stopReason: "toolUse" }),
  (0, _piAi.fauxAssistantMessage)([
  (0, _piAi.fauxThinking)("CALM_GEOMETRY_THINKING_TWO"),
  (0, _piAi.fauxToolCall)("read", { path: "probe-two.txt" }, { id: "calm_geometry_read_two" })],
  { stopReason: "toolUse" }),
  (0, _piAi.fauxAssistantMessage)([
  (0, _piAi.fauxThinking)("CALM_GEOMETRY_FINAL_THINKING"),
  (0, _piAi.fauxText)("CALM_GEOMETRY_FINAL\n\n- visible row one\n- visible row two")]
  )]
  );
  pi.registerProvider("calm-geometry-e2e", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "test-only",
    api: faux.api,
    models: faux.models,
    streamSimple: faux.streamSimple
  });
  pi.registerCommand("calm-geometry-e2e", {
    description: "Select the deterministic Calm hidden-block geometry model.",
    handler: async (_args, ctx) => {
      const model = ctx.modelRegistry.find("calm-geometry-e2e", "deterministic");
      if (!model || !(await pi.setModel(model))) {
        throw new Error("Calm hidden-block geometry model unavailable");
      }
    }
  });
} /* v9-e29fb92ad3f1fa60 */
