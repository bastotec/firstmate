---
name: harness-adapters
description: >-
  Agent-only reference for firstmate harness operations.
  Use before spawning or recovering a crewmate or secondmate, handling a trust dialog, sending a harness-specific skill invocation, interrupting or exiting an agent, resuming an exited agent, or verifying a new harness adapter.
  Contains verified worker facts for pi, pi-signed, and deck.
user-invocable: false
metadata:
  internal: true
---

# harness-adapters

This is the one skill, trigger, and routing owner for harness-specific Firstmate operations.
Load this router first, then the references selected by the Operation-to-reference matrix below.
When an action spans rows, load the union once rather than every reference.
Files under `references/` are resources of this skill, not additional catalogued skills.

## Path contract

The skill directory is the directory containing this `SKILL.md`.
Resolve on-demand reference links and relative links to their executable, documentation, or sibling-skill owners against the skill directory, including links named by a nested reference.
Operational paths keep the context named by their owner: `config/` and active-home settings belong to the active Firstmate home, `state/` belongs to that home, and project settings such as `.claude/settings.json` belong to the target project.

## Non-negotiable safety

Never dispatch a crewmate or secondmate on an unverified adapter.
If `config/crew-harness` or `config/secondmate-harness` names one, tell the captain under `../../../AGENTS.md` section 9 that the requested worker runtime is not verified, use firstmate's own runtime only if it is a verified worker runtime, and ask only whether to verify the requested runtime for future work.
If no verified worker runtime is resolved, ask for one under the supported-worker boundary in `../../../docs/configuration.md` rather than treating a supported primary as a supported worker.
When a verified fallback exists, do not pause current work for that future-verification choice.

On `unknown`, ask the captain instead of guessing.
A current captain override beats detection, while a per-task override governs only that dispatch.
For recovery and control, use the exact `harness=` in `state/<id>.meta`; never infer it from a model or provider.

Deliver task lifecycle actions only through `../../../bin/fm-control.sh <task-id> interrupt|exit|relaunch|recover-missing`.
[Managed primary setup](../../../docs/managed-primary.md) owns the separate opt-in primary control path.
Never type an interrupt key or exit command through `fm-send`, where routing-marked lifecycle text becomes chat.
Trust handling is complete only when inspection proves the target started processing its instructions; delivery success alone is not proof.

## Detection

`../../../bin/fm-harness.sh` prints firstmate's own harness from verified environment markers and process ancestry, and owns how they combine.
A marker names its harness, but a structural ancestor of a different harness outranks it, because a marker is ordinary environment state a child or a multiplexer can retain while ancestry is what proves who owns the process tree.
Only `FM_PI_HARNESS=pi-signed` at the launch boundary together with `PI_CODING_AGENT=true` selects Pi-signed; shared unmarked launcher ancestry remains Pi.
`../../../bin/fm-spawn.sh` owns worker marker establishment, while the README launch command owns the signed-primary boundary.
`../../../bin/fm-harness.sh crew` resolves `config/crew-harness`, where absent or `default` means firstmate's own harness.
`../../../bin/fm-harness.sh secondmate` resolves `config/secondmate-harness` -> `config/crew-harness` -> firstmate's own harness.
`../../../bin/fm-spawn.sh` re-resolves on every spawn, and an explicit per-spawn argument wins for that spawn.
A new adapter's verified marker and command name must land in `../../../bin/fm-harness.sh`.

## Operation-to-reference matrix

For worker operations, every emitted plan appends the selected or recorded harness reference after the named common references.
The `harness-adapter-routing-v1` object is the machine-readable and human-visible worker selection contract: choose the operation, choose the scenario within it, then append the selected harness reference.
The `primary` operation also applies to primary-only harnesses without a `harnesses` entry; load its common reference alone in that case.
`default` is the normal scenario when no narrower scenario applies.
A new tool remains undispatchable until the `verify` plan, its harness entry, every named owner, and the live checks land.

```json harness-adapter-routing-v1
{
  "operations": {
    "start": {
      "default": ["references/common/dispatch.md", "references/common/model-and-effort.md"],
      "trust-dialog": ["references/common/control-and-recovery.md"]
    },
    "trust": {"default": ["references/common/control-and-recovery.md"]},
    "skill": {"default": ["references/common/control-and-recovery.md"]},
    "interrupt": {"default": ["references/common/control-and-recovery.md"]},
    "exit": {"default": ["references/common/control-and-recovery.md"]},
    "resume": {"default": ["references/common/control-and-recovery.md"]},
    "recovery": {
      "default": ["references/common/control-and-recovery.md"],
      "replacement-profile": ["references/common/control-and-recovery.md", "references/common/dispatch.md", "references/common/model-and-effort.md"],
      "secondmate": ["references/common/control-and-recovery.md", "references/common/primary-hooks.md"],
      "replacement-secondmate": ["references/common/control-and-recovery.md", "references/common/dispatch.md", "references/common/model-and-effort.md", "references/common/primary-hooks.md"]
    },
    "primary": {"default": ["references/common/primary-hooks.md"]},
    "model-effort": {
      "default": ["references/common/model-and-effort.md"],
      "configured-profile": ["references/common/model-and-effort.md", "references/common/dispatch.md"]
    },
    "verify": {"default": ["references/common/dispatch.md", "references/common/control-and-recovery.md", "references/common/primary-hooks.md", "references/common/model-and-effort.md"]}
  },
  "harnesses": {
    "pi": "references/harness/pi.md",
    "pi-signed": "references/harness/pi.md",
    "deck": "references/harness/deck.md"
  }
}
```
