# Agent lifecycle control plane

Firstmate talks to a running agent two ways, and they are not the same channel.

The **data plane** is [`bin/fm-send.sh`](../bin/fm-send.sh): conversational text for the agent to read.
For a `kind=secondmate` target it always prepends the from-firstmate routing marker, because a secondmate is itself a firstmate and its reply must come back through the status path rather than a chat nobody reads.

The **control plane** is [`bin/fm-control.sh`](../bin/fm-control.sh): allowlisted lifecycle verbs addressed to an exact task id.

The split exists because the data plane's marking is exactly right for a message and exactly wrong for a lifecycle command.
A routing-marked `/quit` arrives as ordinary chat - `[fm-from-firstmate] /quit` - which the agent reasons about instead of executing.
The failure repeated across harnesses and homes, and the workaround (remember to use an unmarked send for agent-control commands, and improvise the right key or command per harness) lived only in agent prose, so it failed again every time a session did not happen to recall it.

## What the control plane owns

`bin/fm-control-lib.sh` is the single executable owner of three capability tables, with no side effects, so it can be read as a contract:

- The **verb allowlist**: `interrupt`, `exit`, `relaunch`, `recover-missing`.
  There is no arbitrary-text and no generic raw-key entry point.
  A caller either names an allowlisted verb or is refused.
- **Per-harness mechanics**: the key that cancels a running turn, how many times it must be delivered, whether the composer needs clearing afterwards, the command that exits the agent, and which task kinds the adapter is verified to run.
  These were previously carried only in the [`harness-adapters`](../.agents/skills/harness-adapters/SKILL.md) skill's tool references, which now point here.
- **Per-backend capability**: which named keys a runtime backend can deliver, and whether it has a recovery-grade agent-state classifier able to prove an agent stopped or its endpoint gone.

A raw-command spawn records the command's basename as `harness=`.
`fm_control_harness_family` accepts only exact supported adapter names; [Fail-closed boundaries](#fail-closed-boundaries) owns the refusal for every other recorded value.

## Primary sessions

The primary runs under the Deck chat host, [`bin/fm-deck-chat.sh`](../bin/fm-deck-chat.sh), which owns its own lifecycle; `fm-spawn.sh` and `fm-control.sh` remain task-only.
`tests/fm-ui-host-control.test.sh` pins the honest refusal boundary for primary lifecycle and steering targets and exact captain-call decision bindings.

## Verbs

The remaining sections describe task control through `fm-control.sh`.

| Verb | Effect | Postcondition |
| --- | --- | --- |
| `interrupt` | Deliver the harness's verified interrupt sequence while leaving the agent running. | Delivery succeeds while the endpoint still exists and the agent is still alive where the backend can classify that; no supported adapter supplies a cancellation acknowledgement, so the result reports `cancel=unconfirmed`. |
| `exit` | Stop the agent, preserving the endpoint, the worktree, and every uncommitted change. | The backend's recovery-grade classifier reports the agent gone. Deck additionally requires the task-bound residual-driver proof owned by its [adapter reference](../.agents/skills/harness-adapters/references/harness/deck.md). Already-stopped is idempotent success. |
| `relaunch` | Replace the running agent with a new one in the same endpoint and worktree, on the exact recorded adapter or an explicitly chosen harness, model, and effort. | The new agent is alive on the recorded endpoint, and the durable record names the harness that is actually running. |
| `recover-missing` | Restore a terminal for a task whose endpoint reads `missing` using the backend-specific recovery below, then hand the launch to `fm-spawn.sh --relaunch` on the recorded profile or an explicitly named replacement with the same precedence and axis-reset semantics as `relaunch`. | The endpoint reads `missing`, the backend-specific ownership guard passes, the recorded local copy remains available and task-owned, and the new agent is alive on the endpoint now named by the record. |

An exit that delivers lifecycle input but cannot prove the agent stopped fails with `exit=unconfirmed`, reports the observed agent state and any interrupt cancellation claim, and never claims that nothing changed.
Interrupt never rewrites busy state as proof of its own success.

No supported adapter puts the cancelled prompt back into its composer, so no clear follows the interrupt key; the interrupt postcondition is endpoint survival, not a proven composer reading.

`exit` runs a verify-then-clear composer gate before typing the exit command.
A proven `empty` verdict passes immediately and a proven `pending` verdict refuses by naming the pending text, so real typed input is preserved instead of being concatenated.
Any state the fleet cannot prove (`unknown`, `pending-unproven`, or an unreadable read) never refuses structurally: the gate delivers the harness's verified composer clear (`bin/fm-control-lib.sh`'s `fm_control_composer_clear_keys`), re-reads the state, and retries on a bounded budget before typing the exit command anyway, because restart and relaunch must never stay blocked on a composer state the fleet cannot prove.
An agent found gone during that gate is reported stopped instead, since a dead endpoint is a respawn question for `relaunch` or `recover-missing`, not a composer question.

**Teardown and discard are not verbs and will not become verbs.**
`exit` stops an agent and preserves everything else.
Removing a worktree, independently closing an endpoint, or discarding work stays with [`bin/fm-teardown.sh`](../bin/fm-teardown.sh), which owns the landed-work test.

**`resume` is not a verb.**
Deck's driver starts a new session from the brief on disk.
`relaunch` covers the same need on every adapter, because the brief on disk - not a harness-private session - is the durable instruction.

## Transactional relaunch

`relaunch` and `recover-missing` are the only verbs that change durable records, so each runs as a transaction with a journal at `state/<id>.control-relaunch`, a best-effort copy of the prior record kept beside it for the operator, and a ship or scout's prior instructions preserved when a progress note is appended.
Only the instructions are ever rolled back from those copies; the record copy is never written back over the live record, because every other writer takes the per-task record lock this plane does not hold.

1. **Resolve the profile.**
   An explicit `--harness`, `--model`, or `--effort` wins, and `recover-missing` accepts exactly the same three flags with exactly this precedence - a rescue that names a replacement runtime is one transaction, not a failed recovery followed by a relaunch.
   For local records, a `kind=secondmate` task otherwise re-resolves its durable `config/secondmate-harness` pin, including that file's optional model and effort tokens, exactly as every other respawn does - so setting the pin and relaunching is the ordinary way to move a secondmate's runtime.
   Invalid static harness configuration refuses with the resolver's diagnostic before the existing worker is stopped; only a successful empty resolution may fall back to its recorded harness, and an explicit supported `--harness` bypasses the configured pin.
   A ship or scout keeps the harness already recorded for it, because that harness comes from firstmate's dispatch-profile judgment at intake and must not be silently re-read from configuration.
   A harness change resets model and effort unless they are named too, because a model chosen for one adapter does not transfer to another.
   A harness that has no effort control refuses a named effort: `deck` rejects `--effort` with "deck has no effort control", while an effort recorded for the previous harness is reset to `default` by the harness change and so never makes the rescue refuse itself.
   [Remote placement](remote-secondmates.md#lifecycle-control) owns the primary's remote-profile selection before the host-local transaction begins.
2. **Prove backlog recovery eligibility.**
   When the automatic backlog transition gate applies, an unheld In-flight row is recoverable whether it is unblocked or waiting on a dependency; relaunch preserves that lifecycle state and dependency blocker instead of rerunning `start`.
   An unblocked Queued row can still proceed and moves to In flight at the launch commit, while a dependency-blocked Queued row, any held row, a missing or Done row, and an unreadable row refuse before the old agent is stopped.
   `recover-missing` uses the same predicate before it recreates a terminal.
3. **Safe checkpoint.**
   The recorded worktree must exist and be a worktree root; its head and dirty state are recorded.
   For a `kind=secondmate` task, the home's identity marker must match and its child records must be readable, so a relaunch can never strand child work behind an unreadable home.
   A secondmate's own crewmates run in their own endpoints and outlive its relaunch; the relaunched secondmate reconciles them from its home's durable records at startup.
4. **Record the note.**
   A ship or scout relaunch requires `--note`, because the replacement inherits the local copy but none of the conversation; the note is appended to the instructions it reads.
   A secondmate relaunch does not require one and never rewrites its standing charter.
5. **Stop the old agent** through the `exit` verb, with its postcondition.
6. **Launch the replacement** through its single owner, `bin/fm-spawn.sh --relaunch`, which reuses the recorded worktree and adopts the recorded endpoint, clears the previous harness's per-task wiring, arms a fresh busy generation, rechecks the same backlog recovery eligibility before publication and at the launch commit, and leaves an eligible In-flight row untouched.

Switching harness is therefore one ordinary relaunch rather than a separate mechanism.

### Recovering a missing terminal

`recover-missing` runs the same transaction for a task whose terminal is gone rather than agent-free, which is the one state the control plane's `relaunch` cannot act on: it refuses a missing endpoint.
The [`fm-spawn.sh` header](../bin/fm-spawn.sh) owns the already-stopped launch boundary, including its separate backend-migration path rather than endpoint adoption.
It differs from the steps above in exactly three places.

- No implicit profile. An unqualified `--harness`-less recovery continues the same run on the recorded harness, model, and effort, and nothing is re-resolved from configuration: every identity axis comes from the task's own durable record, so a secondmate whose `config/secondmate-harness` pin has since changed is recovered on the harness, model, and effort it actually recorded.
  Picking the changed pin up is a `relaunch`, which is the verb that deliberately re-resolves it.
  An explicit `--harness`, `--model`, or `--effort` names a replacement profile instead, resolved with the same precedence, axis-reset, and refusal semantics step 1 owns - including the deck effort refusal and the reset of an effort recorded for the previous harness.
  This replacement route applies only when the recorded harness already has verified control mechanics; it cannot rescue a record naming a removed adapter.
  A named replacement is a deliberate choice, never a config re-read, so the same flag never silently picks up a changed secondmate pin.
  Only `--note`/`--note-file` besides, and a ship or scout still requires one for the same reason a relaunch does.
  A held backlog row, a missing local copy, or an ownership conflict refuses exactly as it does for an ordinary recovery, replacement profile or not.
- Two extra preconditions around the checkpoint: the endpoint must read the positively `missing` state, and the recorded local copy must be present and - for a Treehouse pool slot - still claimed by this task.
  Each of those refuses rather than cleaning, reallocating, or repairing anything; no worktree and no pool slot is ever created here.
  Uncommitted changes in that copy are not a precondition at all.
  A task worth recovering is mid-work by definition, so unlanded changes are its normal state, and recovery recreates the terminal beside that work without cleaning, resetting, or stashing any of it.
  The checkpoint still records what it found, so the journal says whether the rescued copy was dirty.
- **No stop step.**
  Step 5 is replaced by restoring a terminal in the recorded worktree using the backend-specific recovery described under [Fail-closed boundaries](#fail-closed-boundaries), then waiting on a bounded budget for the new terminal to hold an agent-free state before step 6 hands it to the same launch owner.
  A login shell that is still running its rc files reads `ambiguous` while each of them owns the pane, and the launch owner takes one un-retried state read that must be `dead`, so the state has to hold rather than merely be observed once.

### Failure and rollback

- A refusal **before** the agent is stopped leaves the durable record and the instructions byte-identical.
- A launch failure **after** the agent is stopped but before replacement-record publication keeps the prior durable record, keeps the progress note so a later recovery still has it, marks the journal `failed:launching`, and reports plainly that no agent is running and where the work is preserved.
- If the launch owner already published the new record but no running agent can be confirmed, the new record is kept: the task is recorded on the new harness with no agent confirmed, which is exactly what recovery reconciles.
  Rewriting it back to the old harness would be a second, worse inaccuracy.
- A `recover-missing` failure while the terminal is being recreated restores the prior instructions byte-exact, because no replacement harness has been launched in that phase.
  A successful endpoint rebind is retained even if settling or handover later fails; the new endpoint's state must be reconciled before retrying with `relaunch`.
  If the rebind itself fails, recovery attempts to close the new endpoint and reports either a confirmed close or an unconfirmed close with the new target for reconciliation; the old metadata binding remains intact.
- A `recover-missing` failure because the new shell never settles to agent-free never claims an agent was stopped: the terminal was recreated, the handover could not be completed, and the pane was just measured as not agent-free, so no bare shell, `dead` endpoint, or ready-to-`relaunch` state is claimed for it.
- A `recover-missing` failure at the launch itself never claims an agent was stopped either, and names the state the operator is now in: the recreated terminal holds a bare shell, so the endpoint reads `dead` rather than `missing` and the verb that retries it is `relaunch`.
  That holds because the durable record is published before the launch command is sent, so reaching this failure means nothing was ever typed into the pane.

## Fail-closed boundaries

- Targeting is exact.
  Only a bare task id with a `state/<id>.meta` record in this home is accepted, and that record must pass the shared endpoint-identity validation.
  A legacy `fm-<id>` window label, an explicit `session:window` endpoint, and a record whose `endpoint_task_id` names another task are all refused.
- A remotely placed secondmate is never driven from this home's own endpoint view.
  Its agent runs on another host, so none of the postconditions this plane verifies could be read for it here; local endpoint validation would refuse the record regardless, because `window=remote:<id>` can never match a local backend's required shape.
  [Remote lifecycle routing](remote-secondmates.md#lifecycle-control) owns its supported primary verbs, readiness gate, and host-to-parent rebinding; the host-local record is ordinary and local, so the transaction's checkpoint, journal, rollback, and postconditions apply there.
- A recorded harness other than exact `deck` is refused before any lifecycle action, including `relaunch` or `recover-missing` with an explicit replacement `--harness`.
  Removed adapters and noncanonical raw-command basenames have no verified control mechanics; an override does not bypass that check, and their records and work remain untouched.
- An adapter that is not verified for this task's kind is refused **before** the running agent is stopped, not after.
  The same table refuses a `recover-missing` before the terminal is recreated, where there is no running agent to stop and nothing has been touched at all.
- A backend that cannot deliver the harness's interrupt key, or the composer clear that key needs, is refused rather than sent a different key.
- `exit`, `relaunch`, and `recover-missing` require a recovery-grade agent-state classifier - stream's, so a record left on a retired backend is refused - because without one the "the agent stopped" or "the endpoint is missing" postcondition cannot be proven.
  Any other backend is refused rather than reported as successful blind.
  On stream a silent agent reads `unreadable` rather than `dead`, so a partition refuses here instead of proving a stop that never happened.
- `recover-missing` brings a terminal back on stream as a NEW endpoint and rebinds the record to it.
  [Stream's lifecycle guide](stream-backend.md#secondmate-lifecycle) owns its new-endpoint recovery and local-agent ownership guard; [Failure and rollback](#failure-and-rollback) above owns failed rebind and handover handling.
- An ambiguous or unreadable endpoint state refuses.
  Only a positively classified state acts.
- `exit`'s composer gate, above, is a fail-closed boundary exactly where the fleet can prove text (`pending` refuses), and `relaunch` inherits it by stopping the old agent through `exit`.
- `fm-spawn --relaunch` independently refuses unless the recorded endpoint is positively agent-free, so a replacement can never join a live agent.
  When the recorded prior harness is Deck, it also requires the adapter's residual-driver proof before arming the new incarnation, including when an operator invokes the already-stopped relaunch boundary directly.
  It also requires the endpoint's shell to be in the recorded worktree and refuses immediately when it is not.

## Capability matrix

Backend capability comes from each adapter's real surface, not from a policy choice.

| Backend | Escape | Enter | Ctrl+C | Ctrl+U | Recovery-grade agent state |
| --- | --- | --- | --- | --- | --- |
| stream | yes | yes | yes | yes | yes |

Per-harness interrupt keys, repeat counts, composer clears, exit commands, and supported task kinds live in `bin/fm-control-lib.sh` and are exercised for every verified worker harness by `tests/fm-control.test.sh`.
The empirical basis for each adapter's value is the `harness-adapters` skill's verification record for that adapter.

## Verification

- `tests/fm-control.test.sh` - the supported-worker adapter contract, the backend capability matrix, exact-id scoping, the closed verb list, the busy, idle, dead, and idempotent lifecycle cases, the exit composer gate's verify-then-clear shapes, and marker non-regression, all against a stubbed session provider.
- `tests/fm-control-relaunch.test.sh` - the relaunch transaction: identity preservation, harness switching, the progress note, checkpoint refusals, backlog recovery that preserves a dependency-blocked In-flight row while refusing blocked Queued and held In-flight rows before stopping the existing worker, rollback after a failed launch, and an already-armed merge poll still authenticating after the record rewrite.
- `tests/fm-control-recover-missing.test.sh` - the missing-terminal recovery: the success path under the recorded handle for both losses (a missing window in a live session, and a whole gone session recreated before it), the live, ambiguous, absent-copy, and pool-slot-ownership refusals leaving the record and instructions byte-identical, a rescue succeeding on a copy full of uncommitted work and leaving every one of those changes byte-identical, the refusal when the session cannot be recreated, the recorded profile surviving a differing configured secondmate pin, the explicit replacement-profile recoveries and their refusals (axis resets, deck from a recorded effort, an explicit deck effort, an unverified harness, a held backlog row, and the failed-handoff rollback that keeps the recorded runtime), removed-adapter records refusing without mutation, a still-starting shell being waited out rather than handed over and the refusal when it never settles, a failed recreation rolling the progress note back while leaving a concurrent write to the durable record in place, and the message after a failed launch handoff.
- [Portable stream-parity regressions](verification/runtime-backends.md#portable-stream-parity-regressions) - stream endpoint rebinding, owning-home agent refusal, and confirmed versus unconfirmed cleanup after a failed rebind.
