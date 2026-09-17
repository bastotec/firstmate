// Run the hub's shipped viewer script under a minimal DOM shim and feed it the
// event-stream records a real subscription delivers, so the page's decoding is
// asserted through the document the hub actually serves rather than by reading
// its source.
//
// Usage: node stream-viewer-harness.mjs <viewer.html> <base64-frame>...
// Prints what the viewer put on screen after those frames.
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");
const frames = process.argv.slice(3);

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this._text = "";
    this.disabled = false;
    this.placeholder = "";
    this.value = "";
    this.scrollTop = 0;
    this.scrollHeight = 0;
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { this.children.push(n); return n; }
  get firstChild() { return this.children[0] || null; }
  set innerHTML(v) { this._html = v; this.children = [new Node("p")]; }
  get innerHTML() { return this._html || ""; }
  setAttribute() {}
  addEventListener(name, fn) { (this.listeners ||= {})[name] = fn; }
}

const byId = new Map();
globalThis.document = {
  createElement: (tag) => new Node(tag),
  createTextNode: (text) => {
    const n = new Node("#text");
    n.textContent = text;
    return n;
  },
  getElementById: (id) => {
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};
globalThis.location = { hash: "#viewer-token" };
globalThis.window = {};
// One worker in the fleet, so the page renders something to select. The
// capture fetch answers empty: this harness is about what the live stream
// renders, not what the page starts from.
globalThis.fetch = () => Promise.resolve({
  ok: true,
  json: () => Promise.resolve({
    tasks: [{endpoint_id: "a".repeat(32), machine: "box-a", label: "worker",
             closed_at: null, state_age_secs: 1}],
    machines: [{machine: "box-a", reachable: true, silent_for_secs: 0}],
  }),
  text: () => Promise.resolve(""),
});

let opened = null;
globalThis.EventSource = class {
  constructor(url) { this.url = url; opened = this; }
  close() {}
};

const script = html.slice(html.indexOf("<script>") + "<script>".length,
                          html.lastIndexOf("</script>"));
new Function(script)();

// select() is reached the way the page reaches it: by clicking the endpoint
// the viewer itself rendered into the list.
const list = byId.get("list");
const out = byId.get("out");
await new Promise((resolve) => setTimeout(resolve, 0));
await new Promise((resolve) => setTimeout(resolve, 0));
const button = list.children.find((c) => c.className === "ep");
if (!button) {
  console.log("[harness] the viewer rendered no endpoint to select: " +
              (list.firstChild ? list.firstChild.textContent : list.innerHTML));
  process.exit(1);
}
button.listeners.click();
if (!opened) {
  console.log("[harness] the viewer opened no event stream");
  process.exit(1);
}
out.textContent = "";
for (const b64 of frames) {
  opened.onmessage({data: JSON.stringify({offset: 0, machine: "box-a", b64: b64})});
}
process.stdout.write(out.textContent);
process.exit(0);
