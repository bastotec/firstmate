// The one Firstmate-owned Pi input filter for terminal palette responses that
// Pi's 50 ms sequence buffer can split into ordinary editor text.
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const ESC = "\x1b";
const BEL = "\x07";
const OSC_PALETTE_PREFIX = `${ESC}]4;`;
const OSC_PALETTE_FRAGMENT_TIMEOUT_MS = 500;
const OSC_PALETTE_VALUE = String.raw`(?:rgb:[0-9a-f]+\/[0-9a-f]+\/[0-9a-f]+|#[0-9a-f]{6}|#[0-9a-f]{12})`;
const OSC_PALETTE_RESPONSE = new RegExp(
  String.raw`^\x1b\]4;\d+;${OSC_PALETTE_VALUE}(?:;\d+;${OSC_PALETTE_VALUE})*(?:\x07|\x1b\\)$`,
  "i",
);
const OSC_PALETTE_BODY_PREFIX = /^[0-9a-fgr;:/#]*$/i;

type InputForwarder = (data: string) => void;

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
    if (this.pending) {
      this.pending += data;
      this.resolvePending(data);
      return;
    }
    if (OSC_PALETTE_RESPONSE.test(data)) return;
    if (this.isPaletteResponsePrefix(data)) {
      this.pending = data;
      this.scheduleFlush();
      return;
    }
    if (data.startsWith(`${ESC}]4`)) return;
    this.forward(data);
  }

  dispose(): void {
    this.clearTimer();
    this.pending = "";
  }

  private resolvePending(latest: string): void {
    if (OSC_PALETTE_RESPONSE.test(this.pending)) {
      this.clearTimer();
      this.pending = "";
      return;
    }
    const terminated = this.hasControlTerminator(this.pending);
    if (terminated || !this.isPaletteResponsePrefix(this.pending)) {
      this.clearTimer();
      this.pending = "";
      if (!terminated) this.forward(latest);
      return;
    }
    this.scheduleFlush();
  }

  private isPaletteResponsePrefix(data: string): boolean {
    if (data.length >= 2 && OSC_PALETTE_PREFIX.startsWith(data)) return true;
    if (!data.startsWith(OSC_PALETTE_PREFIX)) return false;
    let body = data.slice(OSC_PALETTE_PREFIX.length);
    if (body.endsWith(ESC)) body = body.slice(0, -1);
    return OSC_PALETTE_BODY_PREFIX.test(body);
  }

  private hasControlTerminator(data: string): boolean {
    return data.includes(BEL) || data.includes(`${ESC}\\`);
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
  let forwardCurrent = false;
  let currentInput = "";
  const filter = new PiTerminalResponseInputFilter((data) => {
    if (handlingInput && data === currentInput) forwardCurrent = true;
  });
  const unsubscribe = ctx.ui.onTerminalInput((data) => {
    currentInput = data;
    forwardCurrent = false;
    handlingInput = true;
    try {
      filter.handleInput(data);
    } finally {
      handlingInput = false;
    }
    return forwardCurrent ? undefined : { consume: true };
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
