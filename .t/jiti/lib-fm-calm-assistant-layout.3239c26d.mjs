"use strict";Object.defineProperty(exports, "__esModule", { value: true });exports.installCalmAssistantLayout = installCalmAssistantLayout;








var PiCodingAgent = _interopRequireWildcard(await jitiImport("@earendil-works/pi-coding-agent"));
var _fmCalmVisibility = await jitiImport("./fm-calm-visibility.ts");function _interopRequireWildcard(e, t) {if ("function" == typeof WeakMap) var r = new WeakMap(),n = new WeakMap();return (_interopRequireWildcard = function (e, t) {if (!t && e && e.__esModule) return e;var o,i,f = { __proto__: null, default: e };if (null === e || "object" != typeof e && "function" != typeof e) return f;if (o = t ? n : r) {if (o.has(e)) return o.get(e);o.set(e, f);}for (const t in e) "default" !== t && {}.hasOwnProperty.call(e, t) && ((i = (o = Object.defineProperty) && Object.getOwnPropertyDescriptor(e, t)) && (i.get || i.set) ? o(f, t, i) : f[t] = e[t]);return f;})(e, t);} // Verified against Pi 0.81.1 and 0.82.0, which export AssistantMessageComponent with an
// updateContent method. installCalmAssistantLayout() probes that exact method and throws
// if it is missing; fm-calm.ts catches that and skips only this adapter with a diagnostic
// instead of blocking Calm or Pi.
// This layout removes collapsed thinking and the mid-turn assistant text blocks
// classified as "assistant-working-note" from a shallow presentation copy. The message
// itself, model context, session storage, and export rendering are never touched.
// ./fm-calm-visibility.ts owns which classes Calm hides.







// A mid-turn assistant message is one the model did not end its response with: Pi's
// agent loop runs its tool calls and then issues another assistant message. stopReason
// is intrinsic to each message and is already set while the message streams, so this
// layout never has to ask whether the turn ended. It stays "pending" until the tool
// call materializes, which is why a working note is briefly visible before it
// collapses; suppressing pending text would also stop a genuine reply from streaming.
function isMidTurnAssistantMessage(message) {
  if (message.stopReason === "toolUse") return true;
  return (
    message.stopReason === "length" &&
    message.content.some((block) => block.type === "toolCall"));

}

// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_ASSISTANT_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-assistant-layout:pi-0.81.1"
);

function installCalmAssistantLayout() {
  const registry = globalThis;


  const hidesThinking = () => (0, _fmCalmVisibility.calmPresentationHides)("assistant-thinking");
  const hidesWorkingNote = () => (0, _fmCalmVisibility.calmPresentationHides)("assistant-working-note");
  const installed = registry[CALM_ASSISTANT_LAYOUT_PATCH];
  if (installed) {
    installed.hidesThinking = hidesThinking;
    installed.hidesWorkingNote = hidesWorkingNote;
    return;
  }

  const patch = { hidesThinking, hidesWorkingNote };
  const AssistantMessageComponent = PiCodingAgent.AssistantMessageComponent;
  if (typeof AssistantMessageComponent !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent");
  }
  const originalUpdateContent = AssistantMessageComponent.prototype.updateContent;
  if (typeof originalUpdateContent !== "function") {
    throw new Error("Firstmate Calm requires Pi AssistantMessageComponent.updateContent");
  }

  AssistantMessageComponent.prototype.updateContent = function (
  message)
  {
    const state = this;
    const hideThinking =
    state.hiddenThinkingLabel === "" &&
    state.hideThinkingBlock &&
    patch.hidesThinking();
    const hideWorkingNote =
    patch.hidesWorkingNote() && isMidTurnAssistantMessage(message);
    const presentationMessage =
    hideThinking || hideWorkingNote ?
    {
      ...message,
      content: message.content.filter(
        (block) =>
        !(hideThinking && block.type === "thinking") &&
        !(hideWorkingNote && block.type === "text")
      )
    } :
    message;

    originalUpdateContent.call(this, presentationMessage);
    if (presentationMessage !== message) state.lastMessage = message;
  };

  registry[CALM_ASSISTANT_LAYOUT_PATCH] = patch;
} /* v9-8e66dea4e77e8280 */
