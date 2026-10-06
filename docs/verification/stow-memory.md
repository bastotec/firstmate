# Startup-memory `/stow` verification

Audience: maintainer verification.

This record supports the active guarantee that Firstmate can discover and JIT-load a user-owned local skill excluded through the clone's `.git/info/exclude`.
The internal [`stow` skill](../../.agents/skills/stow/SKILL.md) owns tiering, curation, archival, offload, and completion-receipt behavior.
[`docs/configuration.md`](../configuration.md) owns the current operator-facing startup-memory setting and estimate.

## Git-excluded local skill discovery and loading

The internal skill's offload destination relies on the harness discovering and JIT-loading a skill directory whose path is listed in the clone's local `.git/info/exclude`.
Deck reads the worktree's `.agents/skills` itself, as recorded in the [Deck harness reference](../../.agents/skills/harness-adapters/references/harness/deck.md).

The 2026-08-08 check that established this ran on a harness that is no longer supported, so it is not evidence for Deck.
No Deck run of the check is recorded yet.

The check's method carries over, with the probe placed under `.agents/skills/`, where Deck looks.
In a disposable scratch repository, create `.agents/skills/excluded-probe/SKILL.md` whose body, below the frontmatter, holds a unique sentinel token, and append `.agents/skills/excluded-probe/` to `.git/info/exclude`.
`git check-ignore -v .agents/skills/excluded-probe/SKILL.md` must name the local exclude rule.
A fresh session asked to load the skill named `excluded-probe` and reply with only the sentinel must return it exactly.
The sentinel sits only in the body, so returning it proves the session loaded the excluded skill rather than merely seeing its indexed name or description.
