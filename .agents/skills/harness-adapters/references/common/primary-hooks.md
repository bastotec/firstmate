# Primary startup and hooks

Load this before changing session startup, turn-end handling, pre-tool protection, watcher supervision, or secondmate integration.
Load the detected primary's worker tool reference only when the router has one; otherwise use the primary owners below.
`../../../README.md` owns primary harness support, independently of worker adapter support.

## Turn end

`../../../docs/turnend-guard.md` owns the "no turn ends blind" contract, hook installation, per-surface blocking behavior, and tradeoffs when a hook cannot block.
`../../../docs/supervision-protocols/` and `../../../bin/fm-supervision-instructions.sh` own harness-specific wake protocols.
Never substitute another harness's wait shape.
`../../../bin/fm-busy-lib.sh` remains the semantic busy owner; a tool reference names only its source and evidence.

Validate any turn-end change against the real harness in a scratch project or throwaway home.
Update its executable or hook owner, any retained tool reference, and `../../../docs/verification/supervision.md` under "Turn-end guard".

## Pre-tool protection

Supported primaries deny watcher-arm anti-patterns before execution, including shell `&`, truncating pipes, bundling, and broad `pkill -f fm-watch`.
`../../../docs/arm-pretool-check.md` owns hook commands, output quirks, and evidence.
Any retained worker tool reference points to that integration owner.
Validate changes against the real harness in a scratch project before trusting them.

## Session start

`../../../AGENTS.md` section 3 remains the behavioral owner.
`../../../docs/sessionstart-nudge.md` owns native tier assignment, transport, source routing, runtime bound, and fail-open behavior.
Read it before changing session-open behavior.
`../../../docs/verification/supervision.md` under "Native session-start delivery" owns active dated evidence.

## Watcher supervision

`../../../bin/fm-session-start.sh` prints exactly one block for the detected primary.
Follow only that rendered protocol.
When changing a watcher adapter, update its file under `../../../docs/supervision-protocols/`, update `../../../docs/turnend-guard.md` if shared idle or turn-end behavior changed, and refresh any retained tool reference.
An identity without a dedicated protocol uses its documented unsupported or unknown boundary; never invent one from a similar TUI.
