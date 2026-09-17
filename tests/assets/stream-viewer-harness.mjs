// Run the hub's shipped viewer script under a minimal DOM shim and feed it the
// event-stream records a real subscription delivers, so the page's decoding is
// asserted through the document the hub actually serves rather than by reading
// its source.
//
// Usage: node stream-viewer-harness.mjs <viewer.html> frames <base64-frame>...
//        node stream-viewer-harness.mjs <viewer.html> capture-refused
//        node stream-viewer-harness.mjs <viewer.html> send-then-switch
//        node stream-viewer-harness.mjs <viewer.html> send-then-reselect
// "frames" prints what the viewer put on screen after those frames.
// "capture-refused" answers the transcript fetch with a refusal and prints the
// pane. "send-then-switch" leaves a send in flight, selects the closed second
// worker, lets the send resolve, and prints whether the box is enabled;
// "send-then-reselect" does the same while the worker that closes is the one
// the send was typed into, which is the same contradiction reached from the
// other side.
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");
const mode = process.argv[3];
const frames = process.argv.slice(4);

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
const TASKS = [
  {endpoint_id: "a".repeat(32), machine: "box-a", label: "worker",
   closed_at: null, state_age_secs: 1},
  {endpoint_id: "b".repeat(32), machine: "box-a", label: "retired",
   closed_at: 1, state_age_secs: 1},
];
let inputResolve = null;
globalThis.fetch = (url) => {
  if (url.indexOf("/capture") !== -1 && mode === "capture-refused") {
    return Promise.resolve({
      ok: false,
      status: 404,
      text: () => Promise.resolve(
        '{"error": "no_such_endpoint", "message": "no endpoint", "ok": false}'),
      json: () => Promise.resolve({error: "no_such_endpoint", ok: false}),
    });
  }
  if (url.indexOf("/input") !== -1) {
    // Held open so the test can click another worker while it is in flight.
    return new Promise((resolve) => {
      inputResolve = () => resolve({ok: true, json: () => Promise.resolve({ok: true})});
    });
  }
  return Promise.resolve({
    ok: true,
    json: () => Promise.resolve({
      tasks: TASKS,
      machines: [{machine: "box-a", reachable: true, silent_for_secs: 0}],
    }),
    text: () => Promise.resolve(""),
  });
};

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
const line = byId.get("line");
const form = byId.get("form");
const settle = () => new Promise((resolve) => setTimeout(resolve, 0));
await settle();
await settle();
const buttons = list.children.filter((c) => c.className === "ep");
if (!buttons.length) {
  console.log("[harness] the viewer rendered no endpoint to select: " +
              (list.firstChild ? list.firstChild.textContent : list.innerHTML));
  process.exit(1);
}
buttons[0].listeners.click();
await settle();
await settle();

if (mode === "capture-refused") {
  process.stdout.write(out.textContent);
  process.exit(0);
}

if (mode === "send-then-reselect") {
  line.value = "echo hello";
  form.listeners.submit({preventDefault: () => {}});
  await settle();
  // The worker the send went to closes, and the operator picks it again.
  TASKS[0].closed_at = 1;
  buttons[0].listeners.click();
  await settle();
  if (inputResolve) { inputResolve(); }
  await settle();
  await settle();
  process.stdout.write(line.disabled ? "send box disabled" : "send box enabled");
  process.exit(0);
}

if (mode === "send-then-switch") {
  line.value = "echo hello";
  form.listeners.submit({preventDefault: () => {}});
  await settle();
  // The operator picks the closed worker while that send is still in flight.
  buttons[1].listeners.click();
  await settle();
  if (inputResolve) { inputResolve(); }
  await settle();
  await settle();
  process.stdout.write(line.disabled ? "send box disabled" : "send box enabled");
  process.exit(0);
}

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
