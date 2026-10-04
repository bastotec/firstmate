# Managed primary setup

The opt-in managed launcher, [`bin/fm-primary.py`](../bin/fm-primary.py), owns a primary child launched through the existing stream agent.
It does not adopt a primary launched directly from the README, infer a profile from a process name, or create task metadata for a primary.
Existing unregistered sessions receive `unregistered_primary` until the operator ends that session normally and starts a new managed session.
This is a separate launch choice, not a retroactive ownership claim.

## Supported launch profiles

The bounded profiles are `deck`, `pi`, and `pi-signed`.
The selected executable, model, prompt, driver and allowlisted environment are captured at launch and replayed on restart.
Pi-signed remains its own explicit executable boundary; an unavailable signed wrapper is refused rather than replaced with Pi.
Only Deck has an execution-bound native-steering receiver in this managed path.
Pi and Pi-signed explicitly refuse native steering without PTY fallback.
Other adapters are not supported by this launcher and are never inferred from labels or running processes.
The launcher header owns exact profile fields, control arguments and registration mechanics.

## Start a managed primary

Use a Firstmate home prepared through the ordinary installation procedure and a running stream hub configured as described in [the stream backend guide](stream-backend.md).
The publisher credential file contains the plain publish token, not the hub's `publish:<token>` definition line.
The hub must grant that token the publish class.
Deck also requires `jq` and its normal gateway credentials.
Stop any existing primary for this home normally before proceeding; do not abandon unlanded work or use this setup to kill a different session.
Do not perform this migration as a test against a live fleet.

Run the owner in a dedicated terminal or an operator-managed service:

```sh
python3 bin/fm-primary.py launch \
  --home /absolute/path/to/firstmate-home \
  --machine workstation --label primary-main \
  --hub http://127.0.0.1:7717 \
  --token-file /absolute/path/to/publish-token \
  --adapter deck --model codex/gpt-6.1-sol \
  --prompt 'Read AGENTS.md and take the helm as the primary firstmate.'
```

The owner stays in the foreground, creates its own PTY child, registers the actual endpoint with the hub, and hosts the existing publisher.
Deck's stable home driver executes the ordinary startup digest once and hosts watcher turns; it identifies the session as a managed primary, not as a secondmate.
Pi profiles use their ordinary primary integration and do not substitute Deck's watcher protocol.
The normal home session lock still protects supervision ownership.

The owner creates `state/primary-owner/registration.json` with mode `0600` inside a private directory.
It records the exact home, machine, label, endpoint generation, execution id, status path and captured launch profile, plus its private socket capability.
Each execution's status and receiver state live below `state/primary-owner/executions/<execution-id>/`, separate from fleet task ids and task `.meta` files.
Treat the registration as host-private: it can contain credential environment values and must not be copied into browser state, committed, or printed as a public discovery payload.

## Host discovery and control

The authorized host can obtain the same registry binding shape used for an owner target:

```sh
python3 bin/fm-primary.py discover --home /absolute/path/to/firstmate-home
```

Its JSON row contains `machine`, `label`, `fm_home`, `task_id: null`, and the host-only `primary_registration` path.
Keep that path on the host; the browser selects only the machine/label identity, never an executable, home path, capability, PID or arbitrary argv.
The host integration must preserve registry uniqueness and same-origin authorization before dispatching to this owner.
UI routing integration is a separate required acceptance surface; discovery output alone does not make an unmodified host router support primary lifecycle.

For a direct host control call, read the current execution id privately and bind the request to it:

```sh
HOME_PATH=/absolute/path/to/firstmate-home
EXECUTION_ID=$(python3 -c 'import json, pathlib, sys; print(json.loads((pathlib.Path(sys.argv[1]) / "state/primary-owner/registration.json").read_text())["execution_id"])' "$HOME_PATH")
python3 bin/fm-primary.py control --home "$HOME_PATH" \
  --execution-id "$EXECUTION_ID" interrupt
```

`exit` stops only the owned primary child and keeps the manager capability available for a later `relaunch` or `recover-missing`.
`relaunch` drains the old publisher before replaying the captured profile into a new session and endpoint generation.
`recover-missing` refuses a running child and only replaces a child that this owner knows has ended.
Refresh discovery and the execution id after a replacement; stale-generation requests are refused.
Restart is a new conversation from the original prompt, not inferred resumption of an arbitrary process.

Deck native steering binds the execution id and retains the receiver's application semantics:

```sh
python3 bin/fm-primary.py control --home "$HOME_PATH" \
  --execution-id "$EXECUTION_ID" steer \
  --order-id guidance-001 --text 'Keep this change within the authorized scope.'
```

A `pending` result is not evidence of application.
Repeat the same order id and exact text to reconcile the original Deck turn's handled proof; do not mint a new id to retry an unconfirmed steer.
An inactive receiver, unsupported adapter or stale execution is never replaced by PTY typing.
An unconfirmed lifecycle reply requires inspecting the registration and actual owner state before retrying, because the original request may have acted.

## Owner lifetime and refusals

A second launcher for the same home refuses duplicate registration, even when the retained record's owner is unreachable.
A missing or crashed owner is `primary_owner_unreachable`, not permission to signal a recorded PID, adopt a child or overwrite its registration.
This bounded implementation does not recover a dead manager by reconstructing ownership from process tables.
Investigate a retained unknown-owner record before any explicit operator cleanup; neither launcher nor control auto-removes it.
Sending SIGTERM or SIGINT to the launcher itself requests a clean shutdown of its own child and retires only its own registration.
The normal primary `exit` action deliberately does not stop the manager.

## Verification and outstanding acceptance

[`tests/fm-primary.test.sh`](../tests/fm-primary.test.sh) exercises the runnable launcher against a real isolated stream hub, PTY and standby harness executables.
It proves genuine endpoint registration, private discovery shape, exact profile replay, owned-child interrupt/exit/relaunch/recover-missing, stale-execution refusal, duplicate and unregistered refusals, native Deck application and unsupported-adapter refusal.
Only bootstrap/watcher infrastructure is stubbed inside a throwaway home; no live-fleet endpoint is controlled.
Run it with `bin/fm-test-run.sh tests/fm-primary.test.sh`.

This is the primary-control successor to task `fm-ui-host-control-primary-coverage` and [PR65](https://github.com/bastotec/firstmate/pull/65), whose scope is bounded discovery only.
The acceptance criterion is “Delegate and implement the minimal primary lifecycle and execution-bound native-steering support before treating this requirement as complete”.
The broader requirement remains open until host UI integration and its end-to-end acceptance test are implemented and validated; these owner-level guarantees alone are not a claim that the UI requirement is complete.
