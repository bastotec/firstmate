"use strict";Object.defineProperty(exports, "__esModule", { value: true });exports.registerFirstmateTool = registerFirstmateTool;


// Public Pi event-bus boundary for native-harness adapters. FirstMate owns the
// operational message allowlist and these tools; the adapter owns transport.
// Discovery is synchronous: emit { register(tool), allowMessageType(type) } on
// firstmate:native-tools. Only explicitly registered FirstMate controls cross
// this boundary, with the SAME execute callback and ownership checks as Pi.
// The native adapter supplies its current ExtensionContext when executing.
// Pi owns subscription cleanup with the extension runtime, including reload.
function registerFirstmateTool(
pi,
tool)
{
  pi.registerTool?.(tool);
  pi.events?.on?.("firstmate:native-tools", (request) => {
    if (!request || typeof request !== "object") return;
    const discovery = request;



    if (typeof discovery.register === "function") {
      discovery.register({
        name: tool.name,
        description: tool.description,
        inputSchema: tool.parameters,
        execute: tool.execute
      });
    }
    if (typeof discovery.allowMessageType === "function") {
      for (const type of ["firstmate-sessionstart-nudge", "fm-branch-merge", "fm-branch-process"]) {
        discovery.allowMessageType(type);
      }
    }
  });
} /* v9-ef918cc2908d5e5a */
