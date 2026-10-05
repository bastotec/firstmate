// Shared Firstmate-owned filter for OSC 4 palette and OSC 10/11 default-color
// responses that Pi's 50 ms sequence buffer can split into ordinary editor text.
// Only an ESC-] leading candidate is withheld, for at most 500 ms from its
// initial callback; printable RGB-looking drafts outside a candidate pass through.
// Even a short prefix and command can share one preflush callback: discard only
// the valid control prefix, then recover key-event boundaries from the first
// divergent byte so /quit or /new and Enter cannot become one editor event.
// Complete replies reach the native color consumer through the startup guard;
// the session UI backstop consumes them, and expired candidates are discarded.
// A color-grammar keystroke arriving during that candidate window is intentionally
// absorbed; firstmate-launched workers have no concurrent human typing, and
// preserving split terminal replies wins.
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { ProcessTerminal, StdinBuffer } from "@earendil-works/pi-tui";

const ESC = "\x1b";
const OSC_COLOR_PREFIXES = [`${ESC}]4;`, `${ESC}]10;`, `${ESC}]11;`];
const STARTUP_GUARD = Symbol.for("firstmate.pi-terminal-response-input-guard");
const OSC_PALETTE_FRAGMENT_TIMEOUT_MS = 500;
const OSC_PALETTE_RESPONSE = new RegExp(
  String.raw`^\x1b\](?:4;\d+|1[01]);rgb:[0-9a-f]{1,4}\/[0-9a-f]{1,4}\/[0-9a-f]{1,4}(?:\x07|\x1b\\)$`,
  "i",
);

const isDecimalDigit = (value: string | undefined): boolean =>
  value !== undefined && value >= "0" && value <= "9";
const isHexDigit = (value: string | undefined): boolean =>
  value !== undefined && /^[0-9a-f]$/i.test(value);

type InputForwarder = (data: string, recovered?: boolean) => void;

export class PiTerminalResponseInputFilter {
  private pending = "";
  private timer: ReturnType<typeof setTimeout> | undefined;
  private readonly forward: InputForwarder;
  private readonly timeoutMs: number;
  private readonly response: (data: string) => void;

  constructor(
    forward: InputForwarder,
    timeoutMs = OSC_PALETTE_FRAGMENT_TIMEOUT_MS,
    response: (data: string) => void = () => {},
  ) {
    this.forward = forward;
    this.timeoutMs = timeoutMs;
    this.response = response;
  }

  handleInput(data: string): void {
    if (OSC_PALETTE_RESPONSE.test(data)) {
      this.clearTimer();
      this.pending = "";
      this.response(data);
      return;
    }
    if (this.pending) {
      this.consumePaletteCandidate(this.pending, data);
      return;
    }
    if (this.isPaletteResponsePrefix(data)) {
      this.pending = data;
      this.scheduleFlush();
      return;
    }
    if (data.startsWith(`${ESC}]`)) {
      this.consumePaletteCandidate(`${ESC}]`, data.slice(2));
      if (this.pending) this.scheduleFlush();
      return;
    }
    this.forward(data);
  }

  dispose(): void {
    this.clearTimer();
    this.pending = "";
  }

  private consumePaletteCandidate(candidate: string, data: string): void {
    for (let offset = 0; offset < data.length; offset += 1) {
      const next = candidate + data[offset];
      if (OSC_PALETTE_RESPONSE.test(next)) {
        this.clearTimer();
        this.pending = "";
        this.response(next);
        const remainder = data.slice(offset + 1);
        if (remainder) this.forward(remainder, true);
        return;
      }
      if (this.isPaletteResponsePrefix(next)) {
        candidate = next;
        continue;
      }
      this.clearTimer();
      this.pending = "";
      this.forward(data.slice(offset), true);
      return;
    }
    this.pending = candidate;
  }

  private isPaletteResponsePrefix(data: string): boolean {
    if (data.length >= 2 && OSC_COLOR_PREFIXES.some((prefix) => prefix.startsWith(data))) {
      return true;
    }
    const prefix = OSC_COLOR_PREFIXES.find((value) => data.startsWith(value));
    if (!prefix) return false;

    let offset = prefix.length;
    if (prefix === OSC_COLOR_PREFIXES[0]) {
      const indexStart = offset;
      while (isDecimalDigit(data[offset])) offset += 1;
      if (offset === data.length) return true;
      if (offset === indexStart || data[offset] !== ";") return false;
      offset += 1;
    }

    for (const expected of "rgb:") {
      if (offset === data.length) return true;
      if (data[offset]?.toLowerCase() !== expected) return false;
      offset += 1;
    }

    for (let component = 0; component < 3; component += 1) {
      const componentStart = offset;
      while (offset - componentStart < 4 && isHexDigit(data[offset])) {
        offset += 1;
      }
      if (offset === data.length) return true;
      if (offset === componentStart) return false;
      if (component < 2) {
        if (data[offset] !== "/") return false;
        offset += 1;
        continue;
      }
      if (data[offset] === "\x07") return offset + 1 === data.length;
      if (data[offset] !== ESC) return false;
      offset += 1;
      if (offset === data.length) return true;
      return data[offset] === "\\" && offset + 1 === data.length;
    }
    return false;
  }

  private scheduleFlush(): void {
    this.clearTimer();
    this.timer = setTimeout(() => this.flush(), this.timeoutMs);
  }

  private clearTimer(): void {
    if (this.timer === undefined) return;
    clearTimeout(this.timer);
    this.timer = undefined;
  }

  private flush(): void {
    this.clearTimer();
    this.pending = "";
  }
}

export function installPiTerminalResponseInputGuard(ctx: ExtensionContext): () => void {
  if (ctx.mode !== "tui") return () => {};
  let handlingInput = false;
  let forwardedInput: string | undefined;
  const filter = new PiTerminalResponseInputFilter((data, recovered = false) => {
    if (!handlingInput) return;
    const submitOffset = recovered ? data.indexOf("\r") : -1;
    if (submitOffset === -1) {
      forwardedInput = data;
      return;
    }
    const text = data.slice(0, submitOffset);
    const remainder = data.slice(submitOffset + 1);
    if (text) ctx.ui.pasteToEditor(text);
    if (remainder) queueMicrotask(() => ctx.ui.pasteToEditor(remainder));
    forwardedInput = "\r";
  });
  const unsubscribe = ctx.ui.onTerminalInput((data) => {
    forwardedInput = undefined;
    handlingInput = true;
    try {
      filter.handleInput(data);
    } finally {
      handlingInput = false;
    }
    return forwardedInput === undefined ? { consume: true } : { data: forwardedInput };
  });
  return () => {
    filter.dispose();
    unsubscribe();
  };
}

// Install before ProcessTerminal.start and its startup color queries, not only
// at session_start. Terminal ownership survives /new, /reload, /resume, and
// /fork: session_shutdown retires only the UI backstop, while terminal stop
// retires the native candidate. The shared symbol prevents stacking wrappers
// when extensions reload without restarting the TUI.
function installPiStartupTerminalResponseInputGuard(): void {
  const prototype = ProcessTerminal.prototype as ProcessTerminal & { [STARTUP_GUARD]?: boolean };
  if (prototype[STARTUP_GUARD]) return;
  const start = prototype.start;
  const stop = prototype.stop;
  const filters = new Map<ProcessTerminal, PiTerminalResponseInputFilter>();
  const guardedStart: typeof start = function (this: ProcessTerminal, onInput, onResize) {
    filters.get(this)?.dispose();
    const filter = new PiTerminalResponseInputFilter((data, recovered = false) => {
      if (!recovered) {
        onInput(data);
        return;
      }
      const keys = new StdinBuffer();
      keys.on("data", onInput);
      keys.on("paste", (text) => onInput(`${ESC}[200~${text}${ESC}[201~`));
      try {
        keys.process(data);
        for (const key of keys.flush()) onInput(key);
      } finally {
        keys.destroy();
      }
    }, OSC_PALETTE_FRAGMENT_TIMEOUT_MS, onInput);
    filters.set(this, filter);
    start.call(this, (data) => filter.handleInput(data), onResize);
  };
  prototype.start = guardedStart;
  prototype.stop = function (this: ProcessTerminal) {
    try {
      stop.call(this);
    } finally {
      filters.get(this)?.dispose();
      filters.delete(this);
    }
  };
  prototype[STARTUP_GUARD] = true;
}

export default function registerPiTerminalResponseInputGuard(pi: ExtensionAPI): void {
  installPiStartupTerminalResponseInputGuard();
  let dispose = () => {};
  pi.on("session_start", (_event, ctx) => {
    dispose();
    dispose = installPiTerminalResponseInputGuard(ctx);
  });
  pi.on("session_shutdown", () => {
    dispose();
  });
}
