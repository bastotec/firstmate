"use strict";Object.defineProperty(exports, "__esModule", { value: true });exports.FIRSTMATE_SYNTHETIC_PRESENTATION_TYPE = exports.FIRSTMATE_SYNTHETIC_KINDS = exports.FIRSTMATE_CALM_PRESENTATION_EVENT = exports.CALM_TRANSCRIPT_CLASSES = void 0;exports.calmPresentationHides = calmPresentationHides;exports.calmPresentationIsActive = calmPresentationIsActive;exports.calmTranscriptClassIsVisible = calmTranscriptClassIsVisible;exports.registerFirstmateSyntheticPresentation = registerFirstmateSyntheticPresentation;exports.setCalmPresentation = setCalmPresentation;exports.setCalmStockExportRendering = setCalmStockExportRendering;var _piCodingAgent = await jitiImport("@earendil-works/pi-coding-agent");




const CALM_TRANSCRIPT_CLASSES = exports.CALM_TRANSCRIPT_CLASSES = [
"genuine-user-prompt",
"genuine-agent-response",
"assistant-working-note",
"assistant-thinking",
"assistant-tool-call",
"tool-result",
"tool-image",
"user-bash",
"skill-invocation",
"custom-message",
"custom-entry",
"compaction-summary",
"branch-summary",
"working-status",
"command-status",
"system-notice",
"cache-notice",
"project-trust-warning",
"synthetic-user",
"synthetic-assistant",
"unknown"];




// Calm is on or off. "assistant-working-note" is deliberately absent from the allowlist:
// Calm hides mid-turn assistant working notes, keeping the genuine final reply.
const CALM_VISIBLE_CLASSES = new Set([
"genuine-user-prompt",
"genuine-agent-response",
"working-status"]
);

// Legacy session entries from Calm versions before 2026-07-23 retain this
// presentation type. New operational input stays user-role and is never rerouted.
const FIRSTMATE_SYNTHETIC_PRESENTATION_TYPE = exports.FIRSTMATE_SYNTHETIC_PRESENTATION_TYPE = "firstmate-synthetic-input-presentation";
const FIRSTMATE_CALM_PRESENTATION_EVENT = exports.FIRSTMATE_CALM_PRESENTATION_EVENT = "firstmate:calm-presentation";






const FIRSTMATE_SYNTHETIC_KINDS = exports.FIRSTMATE_SYNTHETIC_KINDS = [
"session-start",
"watcher",
"turn-end-guard",
"away-supervisor",
"from-firstmate",
"launch-brief",
"legacy-operational"];








let calm = false;
let stockExportRendering = false;

function calmTranscriptClassIsVisible(itemClass) {
  return CALM_VISIBLE_CLASSES.has(itemClass);
}

function setCalmPresentation(active) {
  calm = active;
}

function setCalmStockExportRendering(active) {
  stockExportRendering = active;
}

function calmPresentationIsActive() {
  return calm;
}

function calmPresentationHides(itemClass) {
  return calm && !stockExportRendering && !calmTranscriptClassIsVisible(itemClass);
}

function registerFirstmateSyntheticPresentation(pi) {
  pi.registerEntryRenderer(
    FIRSTMATE_SYNTHETIC_PRESENTATION_TYPE,
    (entry) => {
      if (calmPresentationHides("synthetic-user")) return undefined;
      const data = entry.data;
      if (!data || typeof data.content !== "string") return undefined;
      return new _piCodingAgent.UserMessageComponent(data.content, (0, _piCodingAgent.getMarkdownTheme)());
    }
  );
} /* v9-42eb12fcabf51b39 */
