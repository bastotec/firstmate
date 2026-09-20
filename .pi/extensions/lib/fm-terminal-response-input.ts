// The one Firstmate-owned Pi input filter for terminal palette responses that
// Pi's 50 ms sequence buffer can split into ordinary editor text.
// It consumes only a complete OSC 4 response with a structural prefix, valid
// palette grammar, and BEL or ST terminator; every malformed or timed-out
// candidate is replayed byte-for-byte to the editor.
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import type { EditorComponent, TUI } from "@earendil-works/pi-tui";

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
  private readonly onDeferredForward: () => void;
  private readonly timeoutMs: number;

  constructor(
    forward: InputForwarder,
    onDeferredForward: () => void,
    timeoutMs = OSC_PALETTE_FRAGMENT_TIMEOUT_MS,
  ) {
    this.forward = forward;
    this.onDeferredForward = onDeferredForward;
    this.timeoutMs = timeoutMs;
  }

  handleInput(data: string): void {
    if (this.pending) {
      this.pending += data;
      this.resolvePending();
      return;
    }
    if (OSC_PALETTE_RESPONSE.test(data)) return;
    if (this.isPaletteResponsePrefix(data)) {
      this.pending = data;
      this.scheduleFlush();
      return;
    }
    this.forward(data);
  }

  dispose(): void {
    this.clearTimer();
    this.pending = "";
  }

  private resolvePending(): void {
    if (OSC_PALETTE_RESPONSE.test(this.pending)) {
      this.clearTimer();
      this.pending = "";
      return;
    }
    if (this.hasControlTerminator(this.pending) || !this.isPaletteResponsePrefix(this.pending)) {
      this.flush();
      return;
    }
    this.scheduleFlush();
  }

  private isPaletteResponsePrefix(data: string): boolean {
    if (OSC_PALETTE_PREFIX.startsWith(data)) return true;
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
    if (!this.pending) return;
    const pending = this.pending;
    this.pending = "";
    this.forward(pending);
    this.onDeferredForward();
  }
}

type GuardedEditor = EditorComponent & { disposeTerminalResponseFilter: () => void };

function guardEditor(editor: EditorComponent, tui: TUI): GuardedEditor {
  const filter = new PiTerminalResponseInputFilter(
    (data) => editor.handleInput(data),
    () => tui.requestRender(),
  );
  return new Proxy(editor as GuardedEditor, {
    get(target, property, receiver) {
      if (property === "handleInput") return (data: string) => filter.handleInput(data);
      if (property === "disposeTerminalResponseFilter") return () => filter.dispose();
      return Reflect.get(target, property, receiver);
    },
  });
}

export async function installPiTerminalResponseInputGuard(ctx: ExtensionContext): Promise<() => void> {
  if (ctx.mode !== "tui") return () => {};
  const { CustomEditor } = await import("@earendil-works/pi-coding-agent");
  const previous = ctx.ui.getEditorComponent();
  let current: GuardedEditor | undefined;
  ctx.ui.setEditorComponent((tui, theme, keybindings) => {
    current?.disposeTerminalResponseFilter();
    const editor = previous?.(tui, theme, keybindings) ?? new CustomEditor(tui, theme, keybindings);
    current = guardEditor(editor, tui);
    return current;
  });
  return () => {
    current?.disposeTerminalResponseFilter();
    current = undefined;
    ctx.ui.setEditorComponent(previous);
  };
}
