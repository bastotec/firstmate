# Live validation: composer-state verify-then-clear exit gate

Branch `fm/fm-deck-composer-state-prove-or-clear` (base 607c5e1b → target 18ae945e).

## Artifacts

- `fm-control-exit-gate-shapes.log` — `FM_LIVE=0 bin/fm-test-run.sh tests/fm-control.test.sh`, exit 0.
  Contains the three exit-gate shapes: idle Deck driver prompt proven empty with no
  clearing keys; an unproven reading verify-then-cleared (deck's C-u then Enter delivered,
  composer returns to provably empty, exit command follows); a gone agent reported
  `already-stopped` with zero bytes typed, including the agent that dies mid-gate.
- `stream-deck-gate-clear-pass-after.log` — `FM_LIVE=0 bin/fm-test-run.sh tests/fm-backend-stream.test.sh`
  with a faithful `setsid` shim (macOS lacks the Linux `setsid` binary; the shim is
  `os.setsid()` + `execvp`, real semantics). A real hub, a real stream agent, a real pty,
  and the real `bin/fm-deck-worker.sh` (fake `deck` model binary, exactly as the suite
  ships it). All four deck cases pass, including `stream: idle Deck exits; genuine
  pending text refuses without stopping the host`, which now also drives the exit gate's
  verified clear end-to-end: partial text is echoed unsubmitted, the gate's exact
  `fm_backend_send_key C-u` then `Enter` pair is delivered, the driver discards the whole
  line carrying the clear byte, the composer re-reads provably empty, and the cleared
  text never becomes a Deck turn.
- `stream-deck-gate-clear-fail-before.log` — same suite with `bin/fm-deck-worker.sh`
  reverted to the base commit (worker restored byte-identical to HEAD afterwards; the
  only lasting worktree change is the focused test segment added to
  `tests/fm-backend-stream.test.sh`). Fails at
  `not ok - the cleared line must be discarded whole, never submitted as a Deck turn`:
  without the worker-side fix the gate's clear concatenates onto the buffered text and
  submits it as a real Deck turn.

## Host flakes (pre-existing, not from this change)

- The stream suite's agent-state classification cases intermittently report
  `ambiguous` on this Mac: the endpoint's interactive `/bin/zsh` startup (this user's
  dotfiles) transiently forks `git version`, `which`, `printf`, `tail` into the pane's
  foreground process group, which the shared classifier correctly folds into
  `ambiguous`. Reproduced identically against the base commit (607c5e1b) with a
  standalone hub/endpoint rig: the failure floats between cases across runs and touches
  no code path this change modifies. The suite is Linux-CI-designed (it requires
  `setsid`).
- `tests/fm-control-herdr-smoke.test.sh` could not run here: its safety harness
  (`bin/fm-herdr-lab.sh`) refuses to provision an isolated lab while the machine's
  default Herdr session is stopped, and starting the captain's live default Herdr
  session is a system-state change outside this worktree's boundary. It stays covered by
  the required real-herdr CI lane.

## Round 2 (target 9bb31643, after the review fixes)

Re-validated on the current target, which adds the review round's product change
(`bin/fm-deck-worker.sh` parked-interrupt repaint removed; clear-byte line
discard and bare-Enter repaint kept) and the committed test repins
(`tests/fm-control-relaunch.test.sh`, `tests/fm-control-herdr-smoke.test.sh`,
plus the stream gate-clear segment now committed as 9bb31643).

- `round2-fm-control-suite-head.log` — `FM_LIVE=0 bin/fm-test-run.sh tests/fm-control.test.sh`
  at HEAD, exit 0. The three exit-gate shapes pass on the post-review worker.
- `round2-stream-suite-head.log` — `FM_LIVE=0 bin/fm-test-run.sh tests/fm-backend-stream.test.sh`
  at HEAD with the same faithful `setsid` shim (real hub, real stream agent, real
  pty, real `bin/fm-deck-worker.sh`; fake `deck` model binary exactly as the suite
  ships it). All four deck cases pass, including the secondmate case that now pins
  BOTH the review round's contract (interrupt of a parked pane with partial input
  keeps the composer reading `pending`; exit still refuses on it) and the gate's
  verified C-u+Enter clear consumed by the real driver. The run then stops at the
  documented pre-existing macOS agent-state flake (`a bare shell endpoint should
  classify as dead (expected 'ambiguous', got 'dead')`), unchanged from round 1
  and untouched by this diff.
- `round2-relaunch-suite-head.log` — `FM_LIVE=0 bin/fm-test-run.sh tests/fm-control-relaunch.test.sh`
  at HEAD, exit 0 (all 70 cases), including the repinned
  `an unreadable composer is verify-then-cleared, never a structural refusal`
  and the still-failing-by-design `pending composer text refuses`.
- `round2-deck-harness-suite-head.log` — `FM_LIVE=0 bin/fm-test-run.sh tests/fm-deck-harness.test.sh`
  at HEAD, exit 0; includes `test_idle_interrupt_does_not_echo_fake_input`
  (real worker in a real pty: idle Ctrl+C stays a signal, partial input stays
  visible), the pinned preserve-on-interrupt contract.
- `round2-gate-tests-fail-at-base-bin.log` — with `bin/` reverted to the base
  commit (tests at HEAD), `tests/fm-control.test.sh` fails at
  `deck's verified composer clear must stay the driver-consumed Ctrl+U then Enter pair`
  (`fm_control_composer_clear_keys: command not found`): the gate tests detect the
  removed feature. Worktree restored to HEAD afterwards (verified clean).
- `round2-relaunch-repinned-fails-at-base-bin.log` — same base-`bin/` revert,
  `tests/fm-control-relaunch.test.sh` fails at the repinned case with exactly the
  defect the intent names: `task rl44's composer state is 'unknown', not proven
  empty; refusing to type the /exit exit command` (rc=1, no relaunch). Passes at
  HEAD. This is the fails-before/pass-after proof for the intent's central claim.

Environment note: macOS hosts lack the Linux `setsid` binary the stream backend's
spawn uses; the shim (`os.setsid()` + `execvp`, in $TMPDIR, deleted after the
runs) only supplies that missing host utility. The herdr smoke suite still
cannot run here (default Herdr session stopped; starting it is outside the
worktree boundary) and stays owned by the required real-herdr CI lane.

## Round 3 (re-verification at HEAD 9bb31643)

Same target as round 2; the worktree is clean at 9bb31643 (no further code
changes). All suites re-driven in this round; results identical to round 2:

- `round3-fm-control-suite.log` — `FM_LIVE=0 bin/fm-test-run.sh tests/fm-control.test.sh`,
  exit 0. The three exit-gate shapes pass: idle Deck driver prompt proven empty
  with no clearing keys; verify-then-clear turns an unproven composer back into
  a proven one; a gone agent is distinguished from an unknown composer (respawn,
  not composer clear).
- `round3-relaunch-suite.log` — `FM_LIVE=0 bin/fm-test-run.sh tests/fm-control-relaunch.test.sh`,
  exit 0 (all 70 cases), including `an unreadable composer is verify-then-cleared,
  never a structural refusal` and the still-refusing `pending composer text refuses`.
- `round3-deck-harness-suite.log` — `FM_LIVE=0 bin/fm-test-run.sh tests/fm-deck-harness.test.sh`,
  exit 0, including `Deck idle Ctrl+C stays a signal, not fake input, while
  partial input remains visible` (real worker in a real pty).
- `round3-stream-suite-deck-cases.log` — `FM_LIVE=0 bin/fm-test-run.sh
  tests/fm-backend-stream.test.sh` with the same faithful `setsid` shim (real
  hub, real stream agent, real pty, real `bin/fm-deck-worker.sh`; fake `deck`
  model binary exactly as the suite ships it). All four deck cases pass,
  including `idle Deck exits; genuine pending text refuses without stopping the
  host` (pending preserved through interrupt; the gate's C-u+Enter clear
  discarded whole by the real driver) and `Deck interrupt preserves a usable
  idle composer for exit`. The run then stops at the same documented
  pre-existing macOS agent-state flake as round 2, unchanged and untouched by
  this diff.

The round-1/round-2 fail-before artifacts above remain the authoritative
fails-before/pass-after proofs (base `bin/` revert showed both the stream
gate-clear case and the relaunch case failing at base, passing at HEAD).
