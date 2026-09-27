// The one Firstmate-owned Pi input filter for terminal palette responses that
// Pi's 50 ms sequence buffer can split into ordinary editor text.
// A palette-grammar keystroke arriving during the 500 ms candidate window is
// intentionally absorbed with that candidate; firstmate-launched workers have
// no concurrent human typing, and preserving split terminal replies wins.
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const ESC = "\x1b";
const OSC_PALETTE_PREFIX = `${ESC}]4;`;
const OSC_PALETTE_FRAGMENT_TIMEOUT_MS = 500;
const OSC_PALETTE_RESPONSE = new RegExp(
  String.raw`^\x1b\]4;\d+;rgb:[0-9a-f]{1,4}\/[0-9a-f]{1,4}\/[0-9a-f]{1,4}(?:\x07|\x1b\\)$`,
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

  constructor(
    forward: InputForwarder,
    timeoutMs = OSC_PALETTE_FRAGMENT_TIMEOUT_MS,
  ) {
    this.forward = forward;
    this.timeoutMs = timeoutMs;
  }

  handleInput(data: string): void {
    if (OSC_PALETTE_RESPONSE.test(data)) {
      this.clearTimer();
      this.pending = "";
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
    if (data.startsWith(`${ESC}]4`)) {
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
    if (data.length < OSC_PALETTE_PREFIX.length) {
      return data.length >= 2 && OSC_PALETTE_PREFIX.startsWith(data);
    }
    if (!data.startsWith(OSC_PALETTE_PREFIX)) return false;

    let offset = OSC_PALETTE_PREFIX.length;
    const indexStart = offset;
    while (isDecimalDigit(data[offset])) offset += 1;
    if (offset === data.length) return true;
    if (offset === indexStart || data[offset] !== ";") return false;
    offset += 1;

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

export default function registerPiTerminalResponseInputGuard(pi: ExtensionAPI): void {
  let dispose = () => {};
  pi.on("session_start", (_event, ctx) => {
    dispose();
    dispose = installPiTerminalResponseInputGuard(ctx);
  });
  pi.on("session_shutdown", () => dispose());
}
