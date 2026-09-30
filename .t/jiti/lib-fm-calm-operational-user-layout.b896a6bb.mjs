"use strict";Object.defineProperty(exports, "__esModule", { value: true });exports.installCalmOperationalUserLayout = installCalmOperationalUserLayout;





var PiCodingAgent = _interopRequireWildcard(await jitiImport("@earendil-works/pi-coding-agent"));
var _fmCalmVisibility = await jitiImport("./fm-calm-visibility.ts");
var _fmOperationalInput = await jitiImport("./fm-operational-input.ts");function _interopRequireWildcard(e, t) {if ("function" == typeof WeakMap) var r = new WeakMap(),n = new WeakMap();return (_interopRequireWildcard = function (e, t) {if (!t && e && e.__esModule) return e;var o,i,f = { __proto__: null, default: e };if (null === e || "object" != typeof e && "function" != typeof e) return f;if (o = t ? n : r) {if (o.has(e)) return o.get(e);o.set(e, f);}for (const t in e) "default" !== t && {}.hasOwnProperty.call(e, t) && ((i = (o = Object.defineProperty) && Object.getOwnPropertyDescriptor(e, t)) && (i.get || i.set) ? o(f, t, i) : f[t] = e[t]);return f;})(e, t);} // Verified against Pi 0.81.1 and 0.82.0, which add the ordinary-user spacer and row
// together via InteractiveMode.addMessageToChat. This adapter probes that exact method
// and throws if it is missing; fm-calm.ts catches that and skips only this adapter with a
// diagnostic instead of blocking Calm or Pi. It changes only that presentation and never
// message delivery.





























// Keep the introduction-version symbol stable so a compatible upgrade cannot
// double-patch a live process.
const CALM_OPERATIONAL_USER_LAYOUT_PATCH = Symbol.for(
  "firstmate:calm-operational-user-layout:pi-0.81.1"
);
const LEGACY_CALM_OPERATIONAL_PREFIX = "\u2063Supervisor escalate (";

function contentIsTextOnly(content) {
  if (typeof content === "string") return true;
  if (!Array.isArray(content) || content.length === 0) return false;
  return content.every(
    (block) =>
    typeof block === "object" &&
    block !== null &&
    block.type === "text" &&
    typeof block.text === "string"
  );
}

function installCalmOperationalUserLayout() {
  const registry = globalThis;


  const hidesOperationalInput = () => (0, _fmCalmVisibility.calmPresentationHides)("synthetic-user");
  const isOperationalInput = (text) => {
    if (!text.includes("\u2063")) return false;
    return (
      (0, _fmOperationalInput.classifyFirstmateCurrentOperationalText)(text) !== undefined ||
      text.startsWith(LEGACY_CALM_OPERATIONAL_PREFIX));

  };
  const installed = registry[CALM_OPERATIONAL_USER_LAYOUT_PATCH];
  if (installed) {
    installed.hidesOperationalInput = hidesOperationalInput;
    installed.isOperationalInput = isOperationalInput;
    return;
  }

  const patch = {
    hidesOperationalInput,
    isOperationalInput
  };
  const InteractiveMode = PiCodingAgent.InteractiveMode;
  if (typeof InteractiveMode !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode");
  }
  const prototype = InteractiveMode.prototype;
  const originalAddMessageToChat = prototype.addMessageToChat;
  if (typeof originalAddMessageToChat !== "function") {
    throw new Error("Firstmate Calm requires Pi InteractiveMode.addMessageToChat");
  }

  const UserMessageComponent = PiCodingAgent.UserMessageComponent;
  if (typeof UserMessageComponent !== "function") {
    throw new Error("Firstmate Calm requires Pi UserMessageComponent");
  }
  class CalmOperationalUserMessageComponent extends UserMessageComponent {
    hasLeadingSpacer;

    constructor(
    text,
    markdownTheme,
    outputPad,
    hasLeadingSpacer)
    {
      super(text, markdownTheme, outputPad);
      this.hasLeadingSpacer = hasLeadingSpacer;
    }

    render(width) {
      if (patch.hidesOperationalInput()) return [];
      const lines = super.render(width);
      return this.hasLeadingSpacer ? ["", ...lines] : lines;
    }
  }

  prototype.addMessageToChat = function (
  message,
  options)
  {
    if (message.role !== "user" || !contentIsTextOnly(message.content)) {
      originalAddMessageToChat.call(this, message, options);
      return;
    }

    const text = this.getUserMessageText(message);
    if (!text || !patch.isOperationalInput(text)) {
      originalAddMessageToChat.call(this, message, options);
      return;
    }

    const component = new CalmOperationalUserMessageComponent(
      text,
      this.getMarkdownThemeWithSettings(),
      this.outputPad,
      this.chatContainer.children.length > 0
    );
    this.chatContainer.addChild(component);
    if (options?.populateHistory) this.editor.addToHistory?.(text);
  };

  registry[CALM_OPERATIONAL_USER_LAYOUT_PATCH] = patch;
} /* v9-1d60f5e1f779dc32 */
