# Model and effort

Load this with the selected tool reference before choosing, validating, or changing either axis.
Add `references/common/dispatch.md` for configured profile precedence.

## Axes and precedence

`../../../bin/fm-spawn.sh` accepts concrete `--harness`, `--model`, and `--effort` values selected at intake; scripts never parse natural-language dispatch rules.
The tool reference records verified flags, accepted values, omission behavior, and discovery.

Effort precedence is a per-task captain instruction, then applicable dispatch profile or secondmate pin, then the fallback below.
Never replace either higher-precedence value.
Use the fallback only when neither specifies effort.

Use `low` for well-understood work with an explicit bounded path and `xhigh` for ambiguous investigation or design.
Choose intermediate levels as complexity, uncertainty, blast radius, or open-ended reasoning rises.
If an adapter lacks `xhigh`, cap at its highest supported non-`max` level rather than silently omitting the intent.
Never select `max` through this fallback; only an explicit per-task or standing captain preference permits it.

Deck's no-effort refusal is owned by `../../../bin/fm-spawn.sh` and `references/harness/deck.md`; never silently omit a requested effort.

## Harness and provider identity

Harness identity is independent of model provider.
`harness=deck` with `model=xai/grok-*` is Deck using xAI, not standalone Grok Build, and does not require Grok CLI login.

No script resolves credential provenance for you.
Establish it from the tool's discovery surface and `quota-axi auth --json` per-provider sources, and show the reasoning rather than inferring it from a name.

## Discovery

Treat model and provider knowledge as current discovery, not a permanent namespace or mapping.
Use the selected tool reference's authoritative surface in the current authenticated environment because availability changes by version, account, and configuration.

For an unfamiliar namespace, establish support and provider identity from that harness's CLI help, model listing, or current documentation.
An account-reaching listing that omits a model is concrete unsupported evidence; block the candidate and quote it.
An unreachable surface establishes nothing; report uncertainty instead of a verdict.
