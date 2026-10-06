# Runtime backend verification

Audience: maintainer verification.

This record contains reusable version-scoped evidence for active runtime guarantees.
The backend guides own current setup, safety boundaries, and limitations.
Exact task chronology, branch names, temporary homes, local paths, process ids, thread ids, and delivery transcripts remain in private reports or PR evidence.

## Harness detection

Deck is the only harness, and `bin/fm-harness.sh` reads it from process ancestry alone: a deck host (`fm-deck-chat`, `fm-deck-worker`) or `deck` itself in the parent chain resolves `deck`, and anything else resolves `unknown`.
Environment markers left by removed harnesses are ignored.
The portable regression builds every case from real renamed processes and no installed harness:

```sh
bin/fm-test-run.sh tests/fm-harness-precedence.test.sh
```

## tmux

Foreground-process behavior was verified on 2026-07-07 with tmux 3.6a on macOS.

```sh
tmux new-session -d -s fmtest -n testwin
tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
tmux send-keys -t fmtest:testwin 'sleep 30' Enter
tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
tmux send-keys -t fmtest:testwin C-c
tmux display-message -p -t fmtest:testwin '#{pane_current_command}'
```

Observed output:

```text
zsh
sleep
zsh
```

A persistent parent shell waiting for a child remained reported as the parent process, while a shell that directly execed a simple command changed identity with the process itself.
Pi and pi-signed 0.82.0 were reverified on 2026-07-27 through real isolated `fm-spawn.sh` launches.

### Pane input readiness

A pane only accepts a long typed line while its own program is reading input.
When nothing is reading, the kernel buffers the line itself and discards the whole line past its canonical-mode limit, silently, which is how a ~1117-byte launch command could vanish and leave no worker started.
`fm_tmux_wait_pane_input_ready` (`bin/fm-tmux-lib.sh`) waits for that state instead of measuring the text against a byte count, because the limit is `MAX_CANON` and platforms size it differently.

Verified on 2026-09-15 with tmux 3.6a on macOS (Darwin 25.6.0), typing into a pane whose interactive shell was running `sleep`:

```sh
bin/fm-test-run.sh tests/fm-tmux-long-launch.test.sh
```

Observed output:

```text
ok - fm_backend_tmux_send_literal: a 1634-byte launch command starts a worker on a busy pane
ok - fm_backend_tmux_send_text_submit: a 1634-byte command starts a worker on a busy pane
ok - pane that never becomes ready refuses loudly and names the reason
ok - fm_tmux_wait_pane_input_ready: unreadable tty mode stays permissive
ok - fm_tmux_wait_pane_input_ready: a ready pane returns without spending the budget
```

Measured boundary behind those cases, same host and tmux version: a canonical-mode pane took 1023 payload bytes plus the newline intact and lost the entire line at 1024, while a pane at its prompt took 4088 bytes in one send intact.
The readiness read tries BSD `stty -f` and GNU `stty -F`, so it works on both platforms; the boundary value itself is verified on macOS only, and Linux sizes its own buffer differently.

#### Chunking the send does not fix this

Splitting the text across several `tmux send-keys -l` calls is the obvious fix and it does not work, so do not reach for it again.
The limit applies to the line the kernel accumulates, not to each write, so a canonical-mode pane loses the command whichever way the bytes arrive.
Measured on the same host with the same 1117-byte payload: 400, 200, and 100 bytes per send, each with and without pauses between sends, lost the whole command every time, exactly as the single call did.
Waiting for the pane to read input itself is what makes the send land, which is why the gate waits on readiness rather than reshaping the write.

The other session providers deliver text through their own tool rather than through `tmux send-keys`, and none of them is verified here.
herdr was not exercised because doing so requires driving Herdr lifecycle, which needs the guarded lab; zellij and orca are not installed on this host; cmux was not exercised.

### Agent liveness name sources

The earlier record that every harness is observed under its own `#{pane_current_command}` no longer holds and has been replaced by the per-harness evidence below.
In this macOS run that reading reflected a rewritable process title rather than stable executable identity, so it is now one of two independent name sources rather than the sole basis of a verdict.

The seven primary-capable adapters were relaunched on 2026-08-03 with tmux 3.6a on macOS 26.5.2 arm64, each on a private socket in an isolated lab.

```sh
tmux -L "$socket" new-window -d -t "$session:" -n "$harness" -c "$wt" -- "$bin"
tmux -L "$socket" display-message -p -t "$session:$harness" '#{pane_current_command}'
ps -t "${tty#/dev/}" -o pgid=,tpgid=,comm=      # rows where pgid = tpgid
```

Observed identities, and the resulting verdict:

| Harness | Version | `#{pane_current_command}` | Foreground `comm` | Verdict |
| --- | --- | --- | --- | --- |
| claude | 2.1.220 | `2.1.220` | `claude` | alive |
| codex | codex-cli 0.146.0 | `codex` | `codex` | alive |
| opencode | 1.18.11 | `opencode` | `opencode` | alive |
| pi | 0.82.0 | `pi-launcher` | `pi-signed`, `pi` | alive |
| pi-signed | 0.82.0 | `pi-launcher` | `pi-signed`, `pi` | alive |
| grok | 0.2.118 | `grok-0.2.118-ma` | `grok` | alive |

In that 2026-08-03 run, Claude Code was the only harness whose title did not attribute it; every other adapter was attributed by both sources.
Codex reported `codex-aarch64-a` at 0.145.0 and `codex` at 0.146.0, so these identities move between ordinary patch releases.
That is the evidence for treating any single process name as a surface under vendor control rather than a stable contract.

`#{pane_current_command}` and foreground `ps -o comm=` read different name fields, but which one preserves executable identity is platform-dependent.
On macOS the pane command reflected the rewritable title while the full install path could survive in `ps -o comm=`; in the Linux portable regression those roles reversed for the version-named native executable, with the identifying path retained in argv[0].
The classifier therefore accepts a harness basename first, then an exact harness path component in the full executable path, then the same component in argv[0], without depending on which field carries it on a given platform.

The portable regression is CI-enforced.
The real-harness drift guard spends no model tokens, so under the policy in `.agents/skills/firstmate-coding-guidelines/SKILL.md` it runs by default wherever tmux is installed and reports a capability skip elsewhere; `FM_HARNESS_LIVENESS_DRIFT=1` additionally turns an absent tool into a failure.
Run the live guard after any harness upgrade and before trusting or refreshing the table above:

```sh
FM_HARNESS_LIVENESS_DRIFT=1 bin/fm-test-run.sh tests/fm-harness-liveness-drift-live-e2e.test.sh
```

### 2026-09-06 default-on drift refresh, and the Cursor editor CLI collision

Running the guard with no variable set on macOS 26.5.2 arm64 checked 8 installed harnesses and classified every one `alive`:

```text
# claude 2.1.263 (Claude Code): title='2.1.263' foreground=[/Users/kunchen/.local/bin/claude <defunct> <defunct> ]
# codex codex-cli 0.147.0: title='codex' foreground=[/opt/homebrew/bin/codex ]
# opencode 1.18.29: title='opencode' foreground=[/opt/homebrew/bin/opencode ]
# pi 0.84.4: title='pi-launcher' foreground=[/opt/homebrew/bin/pi-signed .../pi ]
# pi-signed 0.84.4: title='pi-launcher' foreground=[/opt/homebrew/bin/pi-signed .../pi ]
# grok grok 1.0.13 (5e9a58528b76) [stable]: title='grok-1.0.13-mac' foreground=[/Users/kunchen/.local/bin/grok ]
# cursor 2026.09.02-c22c1a3: title='node' foreground=[/Users/kunchen/.local/bin/cursor-agent ]
# muse Muse Code 1.0.3 (1.0.3-R2198.1): title='muse-bin-1.0.3-' foreground=[/Users/kunchen/.local/bin/muse-bin-1.0.3-R2198.1 ]
# checked 8 installed harness(es)
```

The first default-on run failed on Cursor with `LIVENESS DRIFT: cursor unknown is running but classifies 'missing'`, observed title `zsh`.
The classifier was not at fault: the guard resolved the harness through a generic `command -v cursor`, which on a machine that also has the Cursor editor finds `~/.local/bin/cursor` - the editor launcher, not the agent.
That binary exits immediately, leaving a bare shell in the pane.
The guard then used `fm_cursor_resolve_binary` first for `cursor`, so the probe launched `cursor-agent` rather than the editor CLI.
Cursor remains in this guard only for retained process-detection and endpoint-liveness checks; it no longer owns a home session lock or has a supported primary or worker launch path.

Bounded output from the 2026-08-03 run that produced the first table above:

```text
ok - harness liveness: claude 2.1.220 (Claude Code) classifies alive
# claude 2.1.220 (Claude Code): title='2.1.220' foreground=[claude ]
# checked 7 installed harness(es)
```

Installed-wrapper checks:

```sh
basename "$(command -v pi-signed)"
pi-signed --version
pi --version
```

Observed bounded output:

```text
pi-signed
0.82.0
0.82.0
```

### Harness-adapter instruction routing

The retained reference check provides structural evidence, not native-loader proof.
`tests/fm-harness-adapter-references.test.sh` parses the router's declared JSON contract as normalized data and proves every selected reference is readable, which is structural evidence only.
The isolated process and endpoint checks used:

```sh
tmux display-message -p -t "$target" '#{pane_current_command}'
ps -o comm= -p "$wrapper_pid"
ps -o comm= -p "$engine_pid"
FM_HOME="$fixture_home" bin/fm-crew-state.sh "$task_id"
```

Observed bounded shapes:

```text
pi-launcher
.../pi-signed
.../Pi Launcher.app/Contents/Resources/pi/pi
state: done ...
```

Both launches executed a submitted tool instruction and touched the generated `turn_end` marker.
The pi-signed launch retained `harness=pi-signed`, while the plain comparison retained `harness=pi`.
The exact wrapper ancestry was `pi-signed` parent to Pi engine child, and the plain Pi Launcher path also traversed the signed wrapper on this installation.
That shared plain-Pi path is retained as disconfirming evidence against using ancestry as runtime-selection authority.
Firstmate therefore sets the exact `FM_PI_HARNESS` selection marker on both worker launch paths, while an unmarked Pi-family process remains `pi`.
Both recorded runtime identities now classify the exact `pi-launcher` foreground command as `alive`.

Backend applicability was reviewed across every spawn adapter.
Tmux needs the exact `pi-launcher`, `pi-signed`, `pi`, and `Pi` process identities for recovery-grade liveness.
Herdr uses native registered-agent state and needs no process-name branch.
Stream classifies through the same shared process owner.

The [Composer classification matrix](#composer-classification-matrix) retains the dated live evidence; `tests/fm-composer-lib.test.sh` and `tests/fm-composer-ghost.test.sh` provide current portable shape coverage.
OpenCode 1.18.4 busy-queue behavior remains pinned by `tests/fm-tmux-submit-busy.test.sh` and `tests/fm-composer-lib.test.sh`.
Herdr's Claude idle-native submit confirmation is pinned by `tests/fm-backend-herdr.test.sh` and refreshed by `FM_HERDR_SUBMIT_CONFIRM_LIVE=1 tests/fm-herdr-submit-confirm-live-e2e.test.sh`.

### Cleanup endpoint identity

The cleanup identity boundary was validated on 2026-07-28 with tmux 3.6a and metadata fixtures for every supported backend.

```sh
tests/fm-teardown-endpoint-safety.test.sh
tests/fm-teardown.test.sh
tests/fm-backend-herdr.test.sh
```

Bounded output from the incident regression:

```text
ok - fm-teardown: missing, empty, malformed, ambiguous, and task-mismatched endpoints refuse before every mutation or runtime call
ok - cleanup identity: valid tmux, Herdr, Zellij, Orca, and cmux records validate while every empty backend target refuses
ok - tmux backend: direct empty target returns nonzero without invoking tmux
ok - process cleanup: creation-time PID identity removes only the exact child and preserves the control child
ok - fm-teardown: dedicated-socket invalid cleanup preserves target/control and valid cleanup removes only the exact target
```

The dedicated tmux cell removed ambient tmux variables, required a socket-bound wrapper, kept one target and one independent control window, and proved the wrapper was not called for invalid metadata or a direct empty target.
Valid cleanup removed only the exact task-bound target and left the control window live.
The current metadata-only validation covers tmux, Herdr, and stream before backend dispatch, and refuses records on the removed Zellij, Orca, and cmux backends.
`tests/fm-teardown-endpoint-safety.test.sh` now validates tmux and Herdr records and pins refusal of a removed-backend record; `tests/fm-backend-stream.test.sh` covers stream endpoint identity.
Pi, pi-signed, and Deck share that backend cleanup boundary; their harness-specific wiring is cleaned only after it, so no harness needs a separate endpoint parser.

### Endpoint kill confirmation

`fm_backend_kill` in `bin/fm-backend.sh` owns the contract; this records what each adapter can actually prove, because a backend that cannot prove a kill landed must say so rather than be treated as confirmed by omission.

- tmux confirms from a successful `list-windows` inventory that omits the exact window, and from a definitive missing-session or no-server answer.
  Every other inventory failure is unconfirmed: `kill-window` exits nonzero for an already-gone window exactly as it does for an unreachable server, so its own status is never the verdict.
- Herdr confirms from `pane get`'s structured `pane_not_found`, read under the same presentation lock the close ran under.
  A refused lock, an unreachable server, a still-present pane, and an unparseable answer are unconfirmed.
  The focus-safe close path writes its own diagnostics - a repositioned workspace it could not confirm removed, for instance - and the kill captures them so they cannot be mistaken for its verdict: an unconfirmed kill folds them into its single refusal line, and a confirmed one reports them after the close has already been proved.
- stream confirms only from the endpoint's own agent, either a record it closed after watching the worker exit or a kill the hub reports it took.
  A hub that cannot answer, a record the hub closed by itself, and a target tagged for a different hub are unconfirmed - the last of those names a real worker this home simply cannot reach ([stream-backend.md](../stream-backend.md)).
  A target that is not an endpoint address at all is unsupported rather than unconfirmed: no worker was ever named and no hub was reached, so there is no answer about one to report.
  An answer that cannot be read is unconfirmed too: a label mismatch needs a label the hub actually returned, and a kill needs an explicit `delivered: true`, because a body that does not parse is not either of those values.
  An endpoint the hub has no record of is unconfirmed too, and is reported with its own reason: the task table is rebuilt by the agents that register into it, so a restarted hub serves that answer for every live endpoint until its agents re-register.
  Automatic re-registration may later restore the endpoint, but until it does absence remains unconfirmed; [When the hub restarts](../stream-backend.md#when-the-hub-restarts) owns the recovery behavior.
  A record no backend can ever answer for is retired only by `bin/fm-retire-endpoint.sh`, which a human runs against named task ids and which records that assertion - who made it and when - before anything is removed.

Verified on 2026-09-17 with tmux 3.6 on Linux 7.0.0.
The tmux verdict comes from tmux's own output, so it is proven against a real server rather than a stub: the unconfirmed case makes the real socket unreadable, which fails both the close and the follow-up inventory the one way that cannot tell a removed window from an unreachable server, and then asserts the window is still there.

```sh
bin/fm-test-run.sh tests/fm-backend-tmux-smoke.test.sh tests/fm-teardown-endpoint-safety.test.sh
```

Observed output, bounded to the kill-contract cases:

```text
ok - real tmux: a kill whose server cannot be read reports unconfirmed and leaves the window running
ok - real tmux: kill reports gone for the window it removed and for one already absent, and unsupported for a backend with no implementation
ok - fm-teardown: an unconfirmed endpoint kill keeps every durable record, while an already-absent endpoint and a confirmed kill both stay successful
```

The cleanup case runs against the same real tmux server and suppresses only the close, reproducing a backend that accepts a close and performs none - the shape the former cmux adapter documented.
It asserts the window really did survive before asserting the records did, so the refusal cannot go vacuous.

Each adapter's own answer is pinned beside it, against the real hub and real agents for stream and against each backend's canned protocol responses for the rest:

```sh
bin/fm-test-run.sh tests/fm-backend-herdr.test.sh tests/fm-backend-stream.test.sh
```

Observed output, bounded to the kill-contract cases:

```text
ok - fm_backend_herdr_kill: an unavailable session lock defers the pane close and reports it unconfirmed
ok - fm_backend_herdr_kill: the repositioning path still reports exactly one relayable reason
ok - fm_backend_herdr_kill: a close that failed and one that left the pane standing both report unconfirmed
ok - stream: only a close the endpoint's own agent reported counts as a stop
ok - stream: a kill the hub cannot answer is reported as unconfirmed
ok - stream: an unaddressable target reports whether a worker was ever named
```

One unrelated case in the Herdr suite needs a real long-running binary reachable under the name `pi`, because it symlinks `sleep` under that name and a multi-call coreutils build dispatches on `argv[0]` and refuses with `unknown program 'pi'`.
On such a build the suite stops at that case before reaching its kill cases, and running them on their own does not help; the run above supplied a single-purpose `sleep` earlier on `PATH` so the whole suite executes.
That replacement must accept fractional seconds, since poll loops elsewhere in the suites use them.

The pending-close record carries the same distinction, because cleanup publishes it BEFORE it touches the endpoint, and session start replays such a record by removing the task record and closing the row.
It is therefore published already stamped unconfirmed - at that moment nothing has proved the worker stopped, so every refusal between the publish and the endpoint gate inherits the stamp - and cleared only once that gate has passed, which is what keeps a cleanup interrupted after a proven kill replayable instead of a permanent hold.
A clear that fails stops the cleanup before any record is removed, because carrying on would leave a marker still carrying the refusal with no task record behind it, a state neither replay nor a rerun can resolve; the records stay and a rerun finishes the close.
`bin/fm-retire-endpoint.sh` publishes its own close stamped confirmed, because the operator's recorded assertion is the proof on that path.

```sh
bin/fm-test-run.sh tests/fm-backlog-atomicity.test.sh
```

```text
ok - completion marks a pending close whose worker could not be proved stopped, and recovery honours it
ok - a refusal before the kill leaves its pending close unconfirmed, and replay honours it
ok - an interrupt after a proven kill still replays its close
ok - a pending close that could not be cleared keeps every record for a rerun
ok - a retirement leaves a close session start can finish
ok - session start refuses to replay a close whose worker was never proved stopped
ok - session start still finishes an ordinary interrupted cleanup
```

Two of those cases are what keep the refusal from becoming a permanent hold: a cleanup interrupted after a proven kill still replays, and so does the identical record without the stamp, so an ordinary interrupted cleanup is finished rather than stranded.
The herdr repositioning case and these pending-close cases were observed on 2026-09-18; the tmux run remains the 2026-09-17 one dated above.

## Composer classification matrix

The shared composer classifier (`bin/fm-composer-lib.sh`, `fm_composer_classify_screen`) owns every composer shape fleet-wide; each backend contributes only a capture and a capability descriptor.
The live half of that guarantee was verified on 2026-08-10 from an already-trusted checkout at the branch's final validated head, against every installed harness then covered by the empty-composer matrix on tmux 3.6a, macOS arm64, on an isolated private socket, with no prompt submitted to any harness.
An earlier untrusted-worktree run left Claude, Grok, and Muse unverified because the guard treats first-launch trust dialogs as an unreadable-composer state and never confirms them; this trusted-checkout rerun supersedes those missing results.

```sh
FM_COMPOSER_MATRIX_LIVE=1 tests/fm-composer-matrix-live-e2e.test.sh
```

Observed output:

```text
ok - claude (2.1.227 (Claude Code)): real idle composer classifies empty
ok - codex (codex-cli 0.146.0): real idle composer classifies empty
ok - opencode (1.14.46): real idle composer classifies empty
ok - pi (0.84.0): real idle composer classifies empty
ok - grok (grok 1.0.0 (3cd0d0cbcebe)): real idle composer classifies empty
# harness absent, not verified here: kimi
ok - muse (Muse Code 0.1.0 (0.1.0-R708.1)): real idle composer classifies empty
ok - strict posture live: a blank shell row classifies unknown and injection defers
ok - zellij (zellij 0.44.0): unrelated pane change never confirms delivery (verdict: unknown)
ok - live composer-matrix guard verified 8 live surface(s)
```

All six installed harnesses' real idle composers reached a proven `empty` (Claude auto-updated to 2.1.227 between the audit and this rerun, so the shipped classifier is proven against the newer release as well), including Pi through the tmux foreground-process identity probe, Grok through the titled-bottom-border tolerance, and OpenCode through the left-bar shape; Codex and OpenCode first parked on vendor update-available modals that the strict classifier correctly refused until the guard's single non-submitting Escape dismissed them.
The strict blank-row posture held live (a blank shell row deferred injection), and a zellij pane changing for reasons unrelated to submission never confirmed a delivery, replacing the retired content-diff heuristic's false positive.
Kimi was not installed on the verification machine; its bordered shape was covered by the then-current portable byte-capture regressions, which were removed with the Kimi worker adapter.
The live matrix guard was also removed, so this table and its command are dated evidence, not refresh instructions; `tests/fm-composer-lib.test.sh` still pins the retained shapes portably.
The 2026-08-23 steering-inbox doorbell run observed grok 1.0.5's idle composer classifying `unknown` (and sometimes pending-family), never `empty`.
Issue #3436's recorded idle capture reproduced the cause on 2026-09-14: Grok 1.0.5 renders the titled bottom border three columns wider than its aligned top and content rows, so the cursorless Herdr profile rejected the otherwise complete box as ambiguous.
The classifier now accepts only that exact three-column overhang (`FM_COMPOSER_GROK_TITLE_OVERHANG` in `bin/fm-composer-lib.sh`) carrying a typed `Grok <model> (<effort>)` title; the portable regressions feed the real capture through both the shared Herdr capability profile and `fm_backend_herdr_composer_state`, and prove idle is `empty`, typed content is `pending`, and an unrecognized oversized title remains `unknown`.
The 2026-09-14 change was not live-verified against Grok; the retired matrix command cannot refresh it, so the retained capture establishes only the measured rendering, not later releases.
This closes only #3436's idle-composer-misclassification symptom (Grok/Herdr composer read `unknown` instead of `empty`, blocking away-mode injection). The issue's second symptom - a leftover watcher never yielding and never being taken over or refused at AFK start - is unrelated to composer classification and is tracked separately in #2270, where #3436's reproduction serves as corroborating evidence.


`zellij action dump-screen --pane-id <id> --ansi` was verified at zellij 0.44.0 to preserve ANSI styling (real Claude Code rendered inside a zellij pane dumped `ESC[m` `❯` U+00A0 for its idle composer row), which was the capability the former zellij composer classifier read.

### 2026-09-15 codex-cli 0.154.0 idle starfield and status footer through Herdr

Verified on 2026-09-15 on macOS arm64 (Darwin 25.5.0) against codex-cli 0.154.0 (model gpt-6-astra, fast mode) running as a Codex second mate inside a Herdr pane, read through Herdr's ANSI capture with its exact capability descriptor (`styled=1`, `cursor=0`, `identity=1`, `rows=20`).
Idle, codex 0.154 animates a braille starfield on the row above its bold `›` prompt row, on the `›` row behind the SGR-2 dim `Ask Codex to do anything` placeholder, and on the row below it, then draws a status footer reading `gpt-6-astra high fast · ~/Projects/purser · Launch Purser desk brief`.
The starfield cells are truecolor greys whose luminance runs from roughly 66 to 165, so the cells above the 128 ghost ceiling survive ghost stripping, and the footer is bright, non-blank, and carries no structural edge.

The capture is a read-only `herdr pane read <pane> --format ansi` of the live pane; its 20-row tail is fed to the shared classifier with the descriptor above:

```sh
herdr pane read w4Z:p2 --format ansi > codex-0.154-idle-herdr.ansi
bash -c '. bin/fm-composer-lib.sh
  caps=$(printf "styled=1\ncursor=0\nidentity=1\nrows=20")
  fm_composer_classify_screen "$caps" "$(tail -n 20 codex-0.154-idle-herdr.ansi)"'
```

Observed output on the same capture before the fix (`bin/fm-composer-lib.sh` at b85e28b5) and then after it:

```text
pending
empty
```

Before the fix the bare `›` shape extended its wrap region over the two rows beneath the glyph (`kind=bare first=17 last=19` within the 20-row tail), read the surviving starfield cells and the footer as wrapped typed input, and answered `pending`.
The steering doorbell (`fm_task_inbox_ring` in `bin/fm-task-inbox-lib.sh`) defers on exactly that verdict, so every ring for the pane was recorded as skipped and the marked request was reported as a missed delivery.
After the fix, braille-only rows bound the wrap region (the status footer sits beneath the starfield row, so the region never reaches it), starfield cells behind the placeholder are stripped from the glyph row, and the same capture reads `empty` under the Herdr and Zellij styled profiles and with a tmux cursor on the glyph row, while a plain (`styled=0`) capture still reads `unknown`, never `pending`.
A second read-only capture of the same pane, taken during the fix with a bright starfield cell drawn between the `›` and the placeholder, read `pending` before and `empty` after as well.
`test_matrix_codex_idle_starfield_furniture` in `tests/fm-composer-lib.test.sh` carries both samples byte-for-byte, the divergence (the same screen with letters in place of the starfield reads `pending`), and the over-stripping negatives (wrapped typed input, braille mixed with text, a typed row with a middle dot, and the footer or a starfield row alone).

The live guard that refreshed this entry, `tests/fm-composer-codex-idle-live-e2e.test.sh`, was removed with the Codex worker adapter; the Herdr capture above is this entry's live evidence.

## Steering-inbox doorbell

The steering channel's one behavioral assumption - a real worker agent follows the constant self-describing doorbell line (list the inbox, read and act on its records in numeric order, then `mv` each into `handled/`) - was verified on 2026-08-23 against every installed verified harness, on tmux 3.6a, macOS arm64, on an isolated private socket, driving the REAL `bin/fm-send.sh` end to end (durable record plus doorbell, with one mid-wait re-ring playing the watcher's role).

```sh
FM_SEND_INBOX_LIVE_E2E=1 tests/fm-send-inbox-doorbell-live-e2e.test.sh
```

Observed output (combined across the full run and the grok rerun after the advisory-skip narrowing landed):

```text
ok - claude (2.1.241 (Claude Code)): the doorbell reached a real worker, which acted and acked with the mv
ok - codex (codex-cli 0.147.0): the doorbell reached a real worker, which acted and acked with the mv
ok - opencode (1.18.21): the doorbell reached a real worker, which acted and acked with the mv
ok - pi (0.84.1): the doorbell reached a real worker, which acted and acked with the mv
# grok (grok 1.0.5 (5115b46bc909) [stable]): idle composer never classified empty; proceeding as production does (advisory check skips only on pending)
ok - grok (grok 1.0.5 (5115b46bc909) [stable]): the doorbell reached a real worker, which acted and acked with the mv
# harness absent, not verified here: kimi
ok - muse (Muse Code 0.2.1 (0.2.1-R1215.1)): the doorbell reached a real worker, which acted and acked with the mv
```

All six installed harnesses honored the doorbell contract with real model turns: each listed the inbox named by the doorbell, read its record, executed the instruction inside it, and acknowledged with the atomic `mv`.
Two findings from the run shaped the shipped behavior: an OpenCode vendor update modal swallowed the first doorbell and the single re-ring recovered it, which is exactly the watcher ladder's job; and grok 1.0.5's idle composer never classifies `empty` (a classifier drift recorded in [Composer classification matrix](#composer-classification-matrix), not verified against later Grok releases), which is why the ring's advisory pre-check skips only on an exact proven `pending` verdict - a doorbell into an ambiguous composer is a recoverable constant line, while skipping on ambiguity would starve steering for any harness the classifier cannot positively identify.
Kimi was not installed on the verification machine, and its worker receive path has since been removed; the portable ladder and enqueue regressions in `tests/fm-task-inbox.test.sh` and `tests/fm-send-inbox.test.sh` still cover the harness-independent contract.
The live doorbell guard now covers Pi and pi-signed only; it is their refresh command after an upgrade, reports an absent harness explicitly, and refuses a run that verified nothing.
[Deck verification](deck.md) owns the Deck worker evidence.

## Herdr

The compatibility floor is protocol 14.
The whole real-Herdr lane's latest active verification uses both Herdr 0.7.4 protocol 16 and Herdr 0.8.0 protocol 19 on macOS aarch64, while focused Herdr 0.7.5 protocol 17, earlier protocol-16, protocol-14, and 0.7.3 evidence is retained where it defines current behavior or fallbacks.
Protocol 17 keeps every protocol-16 feature gate satisfied; the event and workspace-move floors remain 16.
Default-on presentation projection has its own floor at Herdr 0.8.0, protocol 19, verified below.

Core read-only probes:

```sh
herdr --version
herdr status --json | jq -c '{client:.client.protocol,server:.server.protocol}'
herdr api schema --json | jq -c '.schemas.subscription_event["$defs"].SubscriptionEventKind.enum'
```

Observed protocol-16 compatibility shapes:

```text
herdr 0.7.5
{"client":17,"server":17}
["pane.output_matched","pane.agent_status_changed","pane.scroll_changed"]
```

The CLI matrix was checked directly:

| Guarantee | Command shape | Result |
| --- | --- | --- |
| Explicit session routing | `herdr <verb> ... --session <name>` | Reached the named session even while another server was running. |
| Literal send | `herdr pane send-text <pane> <text> --session <name>` | Left text unsubmitted until Enter. |
| Keys | `herdr pane send-keys <pane> enter|escape|ctrl+c --session <name>` | Enter and Escape worked; Ctrl-C interrupted foreground work. |
| Capture | `herdr pane read <pane> --source recent --lines N` | Small N could return empty below viewport height; a 200-line request plus local trim was stable. |
| Native state | `herdr agent get <pane>` | Working and done transitions were visible on some harnesses; live Claude Code 2.1.236 on Herdr 0.8.0 kept `agent_status=idle` for an entire landed turn, including a multi-second tool call, so submit confirmation falls through to the shared composer verdict. Native `busy` remains positive activity evidence, while native `idle` cannot close a turn and the adapter's semantic lifecycle decides worker state. |
| Restart | guarded named-session stop then start | Workspace, tab, pane, and labels persisted; the agent process and registration did not. |
| Close | `herdr pane close <pane> --session <name>` | The exact one-pane task tab closed; closing a final tab could remove the workspace. |

All destructive verification used `bin/fm-herdr-lab.sh` with a non-default `fm-lab-` name and a byte-identical default-session tripwire.
No ambient `herdr server stop` command is a supported test operation.

### Deck native mid-turn steering over stream

The initial same-turn correction check was verified on 2026-09-29 on macOS with Python 3.9.6 and Deck 0.1.0 built from the merged native-steering interface in `bastotec/deck`.
The isolated live guard exercised the real Bridge command adapter, authenticated loopback hub, PTY agent, Deck driver, and model turn; `bin/fm_stream_deck.py` owns the receiver mechanics.
Run the guard with a Deck build whose `run --help` advertises `--steer-dir`:

```sh
FM_DECK_LIVE=1 bin/fm-test-run.sh tests/fm-stream-deck-live-e2e.test.sh
```

`FM_DECK_LIVE_BINARY` selects a non-default Deck build for the same guard; the version string alone is insufficient because builds reporting `deck 0.1.0` can lack `--steer-dir`.
The guard inherits gateway configuration by reference and isolates Deck state and all hub, agent, and worker records in its test lab.
The current guard extends that check through seven live receiver scenarios: original-turn reservation and duplicate reconciliation, storage-failure recovery without successor delivery, delayed destructive takes, independent result-post retries, byte-exact CRLF/carriage-return/Unicode persistence, retained-agent compatibility with native-only size limits, and Bridge course correction with unchanged turn evidence.
It emits per-scenario JSON evidence before this success marker:

```text
PASS all seven native live receiver scenarios
```

The portable application regressions run with `bin/fm-test-run.sh tests/fm-stream-deck.test.sh`.
Current operator behavior and supported limits are owned by [`../stream-backend.md`](../stream-backend.md#command-path).

### Deck endpoint recovery (shim-based)

Verified on 2026-09-23, re-verified on 2026-09-24 on macOS with the repository's real Deck driver, busy-state writer, and OS processes, a shimmed Herdr protocol-14 CLI, and a shimmed model endpoint; this is not a local live-Herdr or live-model result.
`bin/backends/herdr.sh` owns the Deck-only recovery classifier; `bin/fm-agent-process-lib.sh` remains the process-identity owner.

```sh
bin/fm-test-run.sh tests/fm-deck-harness.test.sh tests/fm-backend-herdr.test.sh
```

Observed output:

```text
...
ok - Herdr Deck recovery proves driver identity; dead and non-Deck paths remain conservative
ok - Herdr Deck recovery attributes a live driver across a spaced code root and state root
ok - the steering doorbell rings a live remote Deck driver and skips an absent one
...
fm-deck-harness: all cases passed
FM_TEST_SUMMARY total=2 failed=0 skipped_gate=0 duration_ms=590179
```

The regression checks an absent driver before a live one, busy and idle evidence, replacement on the same pane, exact task attribution, unreadable process and pane inventories, stale busy/progress records after exit, and a live crewmate endpoint beside an absent one of every kind.
The spaced-path case launches the same real driver under a code root and a state root whose paths hold a space, and the shimmed report carries the argv array the live process really presents - read from `/proc/<pid>/cmdline` where the platform exposes one, written from the same argument array the launch used where it does not - so it proves the boundary-preserving match rather than a fixture's opinion; against a whitespace-split `ps` line the same live mate read `unreadable`.
The non-Deck registry path is deliberately unchanged, while every Deck endpoint - ship, scout, or second mate - is classified from its own driver rather than from a registry that cannot know Deck.

Parent-route creation was also verified on 2026-09-23 and re-verified on 2026-09-24 through the real remote-control script against shimmed Herdr, with an ambient `umask 002`:

```sh
bin/fm-test-run.sh tests/fm-remote-secondmate-replacement.test.sh
```

Observed output:

```text
ok - parent-route creation is private under umask 002 and accepted by Deck safe status I/O
...
ok - a launch reconciles a pre-existing 0775 parent-route root to a mode Deck accepts
ok - a relaunch reconciles a pre-existing 0775 parent-route root to a mode Deck accepts
not run - foreign-owner refusal requires chown privilege
ok - the reconcile refuses a symlink, a foreign-owned root, and a non-directory, naming each
ok - a symlinked or relocated parent-route data root still launches
ok - a GNU-shaped stat on PATH cannot poison the parent-route owner read
ok - a working remote Deck mate reads alive to the control plane and survives a launch
...
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0 duration_ms=226041
```

The test asserts mode `0700` and writes and reads a status record through `bin/fm-state-io.py`, the same descriptor-bound boundary used by the Deck driver.
The reconcile runs at both lifecycle boundaries that start an agent - launch and relaunch - and is scoped to the state root the driver validates: the data root keeps its `umask 077` creation, and a launch over a relocated data root still succeeds without tightening it.
The owner read uses the repository's `uname` stat dispatch rather than a collapsed `stat -f || stat -c` fallback, and a GNU-shaped `stat` shadowing `PATH` - which answers `-f` with a filesystem dump and exit 0, the shape recorded in issue #2837 - still reconciles the root to `0700`.

### fm-remote server birth and login-keychain access

Measured 2026-09-09 on macOS 26 (Darwin 25.6.0) aarch64 with Claude Code 2.1.266 and Herdr 0.9.0, the guarantee behind `bin/fm-remote-herdr-guard.sh` and the doctor's `herdr-server` check: login-keychain access follows the audit session a process was born into, never the launch shape or the shell.

Same user, same `HOME`, same login keychain item, three births, probed with `launchctl managername`, `getaudit_addr` (a compiled probe), `security find-generic-password -a "$USER" -w -s "Claude Code-credentials"` (output withheld), and `claude auth status`:

| Birth | `managername` | audit session | `security ... -w` | `claude auth status` |
| --- | --- | --- | --- | --- |
| `gui/501` LaunchAgent, bare `ProgramArguments`, `launchctl bootstrap` + `kickstart -k` mid-session | Aqua | asid 100038 (the `gui/501` asid), `HAS_GRAPHIC_ACCESS HAS_TTY HAS_CONSOLE_ACCESS HAS_AUTHENTICATED` | exit 0 | `loggedIn: true` |
| `gui/501` LaunchAgent, `zsh -l -c 'exec ...'`, same reload | Aqua | asid 100038, same flags | exit 0 | `loggedIn: true` |
| `user/501` LaunchAgent (`LimitLoadToSessionType=Background`), same reload | Background | asid 100056, flags `0x0` | exit 36 `User interaction is not allowed.`, item metadata still readable | `loggedIn: false`, `authMethod: none` |

Claude Code 2.1.266 maps that exit 36 (and 44) to "no keychain data" and reads `~/.claude/.credentials.json` instead; with a stale file it prints `Failed to authenticate: OAuth session expired and could not be refreshed` (interactive: `Login expired · Please run /login`).

Candidate birth markers were read with `ps -Eww -o command= -p <pid>` for own-uid processes, noting that macOS hides the environment of Apple platform binaries such as `/bin/sleep` and that a herdr server is never one.

```text
launchd-born herdr server (child of launchd, gui/501):  XPC_SERVICE_NAME=org.nix-community.home.herdr-server  no SSH_*
SSH-born herdr server (child of `herdr --session fm-remote remote-client-bridge` under `sshd-session: user@notty`):  SSH_CLIENT=... SSH_CONNECTION=...  no XPC_SERVICE_NAME
```

`XPC_SERVICE_NAME` identifies a launchd label but does not identify its domain, because the Background `user/501` job also carried that variable while lacking keychain access.
The owner classifier therefore accepts that label only when `launchctl print gui/<uid>/<label>` identifies the owner pid or the label is loaded in `gui/<uid>` but not `user/<uid>`.
`XPC_SERVICE_NAME=0`, including a value inherited by a herdr live-handoff child, remains unknown.
`FM_REMOTE_JOB_ACTIVE=1` proves the Aqua worker only when `dev.firstmate.remote-job` is loaded in `gui/<uid>` but not `user/<uid>`.

The SSH-born row was read on the remote host whose `dev.firstmate.herdr.fm-remote` job showed `state = spawn scheduled`, `runs = 239`, `last exit code = 1` and a log repeating `error: herdr server is already running`: herdr's remote attach had started the session's server as its own child before the login session existed, and launchd's copy lost the socket on every retry.
`pgrep -f` did not list the herdr server's argv on macOS; `lsof -U -a -c herdr -F pn` named the socket owner.

A separate foreground-supervision check ran on 2026-09-09 on macOS 26 (Darwin 25.6.0) with Herdr 0.9.0 using the throwaway Aqua launch agent `dev.fm-rca.herdr-fg`.
Its `ProgramArguments` ran `/run/current-system/sw/bin/zsh -l -c "exec /etc/profiles/per-user/kunchen/bin/herdr server --session fm-lab-fg-90381-18985"`, with `KeepAlive={SuccessfulExit=false}` and `ThrottleInterval=10`, after `launchctl bootstrap gui/501 <plist>` and `launchctl kickstart -k gui/501/dev.fm-rca.herdr-fg`.
`launchctl print gui/501/dev.fm-rca.herdr-fg` reported `state = running` and `pid = 4806`.
`lsof -U -a -c herdr -F pn` named pid 4806 as the owner of `~/.config/herdr/sessions/fm-lab-fg-90381-18985/herdr.sock`.
`ps -o pid,ppid,command -p 4806` reported `4806 1 /etc/profiles/per-user/kunchen/bin/herdr server --session fm-lab-fg-90381-18985`, and its environment carried `XPC_SERVICE_NAME=dev.fm-rca.herdr-fg`.
No other herdr process existed for that session, and after 15 seconds the job remained running with pid 4806.
After a guarded `herdr session stop`, the job reported `state = not running` and `last exit code = 0`, and it stayed at rest through the throttle interval.
A second `launchctl kickstart -k gui/501/dev.fm-rca.herdr-fg` started pid 45574, which was also the new socket owner.
This proves that `herdr server` remains in the foreground as the launchd job, so the guard's final `exec` supplies the intended supervision and the earlier server that survived `launchctl bootout` was the unrelated SSH-bridge-born process.

`bin/fm-test-run.sh tests/fm-remote-herdr-guard.test.sh` pins the resulting decision table against real marker-carrying processes, and `tests/fm-remote-doctor.test.sh` pins the doctor's verdicts on the same markers.

### Client selection

Measured 2026-09-08 on a macOS aarch64 host running a Herdr 0.9.0 server (protocol 22) for the `fm-remote` session while `~/.local/bin/herdr` still held the self-updated 0.8.2 client (protocol 20) ahead of the Nix-managed 0.9.0 client on the remote-job `PATH`.

```sh
~/.local/bin/herdr --version
~/.local/bin/herdr pane get wCY:p2 --session fm-remote; echo "rc=$?"
~/.local/bin/herdr status --json --session fm-remote | jq -c '{c:.client.protocol,s:{running:.server.running,protocol:.server.protocol,compatible:.server.compatible}}'
herdr status --json --session fm-remote | jq -c '{c:.client.protocol,s:{running:.server.running,protocol:.server.protocol,compatible:.server.compatible}}'
```

```text
herdr 0.8.2
{"id":"cli:pane:get","error":{"code":"protocol_mismatch","message":"client protocol 20 is older than server protocol 22; upgrade the Herdr client before using this command"}}
rc=1
{"c":20,"s":{"running":true,"protocol":22,"compatible":false}}
{"c":22,"s":{"running":true,"protocol":22,"compatible":true}}
```

The refusal is a JSON error on stderr with exit 1 and empty stdout, and both client generations report `.server.compatible` and `.server.protocol` per named session, which is what the selection in `bin/backends/herdr.sh` reads.
`tests/fm-backend-herdr.test.sh` pins the bypass, same-process same-session caching, cross-session isolation, forced reselection, and both status shapes against fakes; `tests/fm-backend-herdr-smoke.test.sh` refreshes the real status normalization against the installed binary's running lab server.

### Submit confirmation

Measured 2026-08-19 against Herdr 0.8.0 and Claude Code 2.1.236 in an isolated `fm-lab-` session.

`herdr agent get` reported `agent_status=idle` on every sample across a landed one-word turn and an 8-second `sleep` tool call, while the pane rendered `Pontificating…` then `Sock-hopping… (11s · ↓ 234 tokens)`.
`fm_backend_herdr_send_text_submit` therefore cannot treat native idle as proof of a swallow.
The portable regressions in `tests/fm-backend-herdr.test.sh` and `tests/fm-composer-lib.test.sh` pin the verdicts: native idle plus a cleared composer is delivery, proven pending plus idle is a swallow, and proven pending plus a generating busy signal is a queued Enter.
Refresh the live Claude proof with:

```sh
FM_HERDR_SUBMIT_CONFIRM_LIVE=1 tests/fm-herdr-submit-confirm-live-e2e.test.sh
```

Observed 2026-08-19:

```text
ok - live Herdr submit confirm: Claude Code (2.1.236 (Claude Code)) on herdr 0.8.0 reports empty for a landed idle steer
```

### Prune and respawn

The real label-collision reproduction is owned by:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-prune-safety-e2e.test.sh
```

Observed guarantee: a pre-existing captain-owned workspace with a seed-shaped tab was adopted for routing but its tab was never eligible for prune because the current create call did not return that seed id.

Restart-husk replacement is owned by:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-respawn-idem-e2e.test.sh
```

Observed guarantee: a restored no-agent tab was replaced create-before-close, while a registered live agent caused refusal.

### Launcher workspace placement

Herdr exports its pane identity into every process it manages, checked on 2026-07-30 against Herdr 0.7.5 protocol 17 inside a guarded lab pane:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh
"$HERDR_LAB_HELPER" run "$LAB" pane run "$PANE" "sh -c 'env | grep ^HERDR | sort > /tmp/env.txt'"
```

```text
HERDR_ENV=1
HERDR_PANE_ID=w1:p1
HERDR_SESSION=fm-lab-fm-herdr-env-pro-65961-25535
HERDR_SOCKET_PATH=/Users/kunchen/.config/herdr/sessions/fm-lab-fm-herdr-env-pro-65961-25535/herdr.sock
HERDR_TAB_ID=w1:t1
HERDR_WORKSPACE_ID=w1
```

This complete injection shape is verified only for Herdr 0.7.5.
Firstmate requires both `HERDR_PANE_ID` and `HERDR_SOCKET_PATH` before accepting claimed launcher ancestry.

`pane get` reports the pane's current owning tab and workspace, which is what placement resolves from; the injected `HERDR_TAB_ID` and `HERDR_WORKSPACE_ID` are creation-time snapshots and are not read as current identity:

```sh
"$HERDR_LAB_HELPER" run "$LAB" pane get w1:p1 | jq -c '.result.pane | {pane_id,tab_id,workspace_id}'
```

```text
{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"}
```

Placement is owned by:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-launcher-workspace-e2e.test.sh
```

Observed guarantees on 2026-07-30 against Herdr 0.7.5 protocol 17:

```text
ok - real herdr E2E: with one 'firstmate' workspace and no herdr parent, a crewmate still lands in this home's own workspace without stealing focus
ok - real herdr E2E: the normal unique-label path is unchanged when the launcher's own pane identifies the workspace
ok - real herdr E2E: presentation spaces still create the isolated child workspace and bind it under the launcher's exact parent, without stealing focus
ok - real herdr E2E: with two 'firstmate' workspaces, a worker spawned from inside the second one lands in that exact workspace
ok - real herdr E2E: the duplicate-labeled sibling workspace is left entirely untouched and focus is preserved
ok - real herdr E2E: with a duplicated home label, a projected worker still hangs off the launcher's exact workspace and the sibling stays untouched
ok - real herdr E2E: an ambiguous home label with no launcher identity refuses before any worker endpoint exists
ok - real herdr E2E: a launcher pane that no longer exists refuses before any worker endpoint exists
ok - real herdr E2E: a secondmate launching its own worker gets the same exact-workspace guarantee, and its same-labeled sibling is untouched
ok - real herdr E2E: a --secondmate launch still stands up that secondmate's own workspace instead of inheriting the launcher's
ok - real herdr E2E: teardown closes only the worker's own pane and leaves the launcher, its workspace, and the same-labeled sibling intact
```

That suite's headline case runs `bin/fm-spawn.sh` inside a real Herdr pane, so the parent identity comes from Herdr's own injection rather than a composed environment.
Cross-session and contradictory bindings are covered deterministically in `tests/fm-backend-herdr.test.sh`, which can script a second server's socket without provisioning one.

### Per-home and presentation topology

Per-home behavior is owned by:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-workspace-per-home-e2e.test.sh
```

Observed guarantee: the primary and secondmate used distinct home workspaces, a child launched by the secondmate stayed in that secondmate workspace, list-live remained home-scoped, and exact cleanup did not affect sibling homes.

The complete projection suite ran on 2026-07-21 against Herdr 0.7.4 protocol 16:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-presentation-e2e.test.sh
```

Observed guarantees included:

```text
ok - real Herdr lab: primary and two secondmate homes each own a top-level contiguous child block
ok - real Herdr lab: concurrent primary/A/B spawns stay session-locked with zero focus drift
ok - real Herdr lab: session lock contention from a secondmate home falls back flat with no journal
ok - real Herdr lab: legacy projection labels and flat secondmate tabs are left unmigrated
ok - real Herdr lab: multi-home exact-pane teardowns restore captain focus without workspace close authority
ok - real Herdr lab validation completed on Herdr 0.7.4 with the default-session tripwire intact
```

The suite also covers lost or failed move responses, restart husks, missing and duplicate tokens, manual renames, concurrent cleanup, and exact focus restoration.

The mandatory projection suite ran again on 2026-07-24 against Herdr 0.7.5 protocol 16:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-presentation-e2e.test.sh
```

Observed restart-reclaim guarantees:

```text
ok - real Herdr lab: Hi Bit and Wheelhouse-style same-identity restarts reclaim one nested space with exact focus and idempotence
ok - real Herdr lab: secondmate restart binding and reclaim stay isolated to the exact child home and parent
ok - real Herdr lab: concurrent cross-home recoveries replace exact husks under one session lock with no focus drift
ok - real Herdr lab: missing, renamed, and duplicate tokens trigger zero destructive or adoptive calls, and live duplicate risk refuses launch
ok - real Herdr lab validation completed on Herdr 0.7.5 with the default-session tripwire intact
```

The projection suite ran again on 2026-08-04 against Herdr 0.8.0 protocol 19 for the default-on flip, where an absent `config/herdr-presentation-spaces` enables the projection and the value `off` opts out; since 2026-08-05 an absent file enables the projection only at or above the 0.8.0 floor recorded under "Presentation version floor" below, and `on` is the explicit opt-in that survives the floor:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-presentation-e2e.test.sh
```

Observed default and opt-out guarantees:

```text
ok - real Herdr lab: an opted-out spawn retains the Stage 1 Herdr command sequence with zero ordering calls
ok - real Herdr lab: a home that configured nothing is projected by default
ok - real Herdr lab: the primary presentation setting inherits into real secondmate homes
ok - real Herdr lab validation completed on Herdr 0.8.0 with the default-session tripwire intact
```

The projected spawn in that run used the historical empty opt-in file, so a home that had already enabled the projection keeps it without any migration step.
One concurrent cross-home recovery case refused under contention on a loaded machine and passed on an immediate rerun; recovery-path presentation lock contention is a deliberate hard refusal rather than a flat fallback, which default-on now makes reachable from any Herdr home.
That run measured the default-on projection on Herdr 0.8.0 only, while the focus-flash regression below was last run on 0.7.5 before the flip, so neither run covered a defective release under default-on projection; the version floor and the focus-flash suite's Part C close that gap.

The restored-shell session-start cleanup ran on 2026-07-24 against Herdr 0.7.5 protocol 17:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-herdr-session-cleanup-e2e.test.sh
```

Observed guarantee: one exact home-local, journal-correlated, one-tab and one-pane childless idle shell was closed after restoration while the exact non-target focus and default fleet session remained unchanged, and a repeat run was a no-op.

### Workspace-removal focus safety

The focus-flash regression ran on 2026-08-05 against both Herdr 0.7.5 protocol 17 and Herdr 0.8.0 protocol 19 on macOS aarch64, with the 0.7.5 run using the pinned upstream release binary first on `PATH`:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-focus-flash-e2e.test.sh
```

Observed output on Herdr 0.7.5:

```text
ok - old path: the explicit last-pane close of a non-focused workspace stole focus (w3	w3:t1 -> w2	w2:t1)
ok - mitigation: every in-operation sample preserved exact focus while the doomed workspace was removed
ok - mitigation: no explicit close and no corrective focus were needed on the defective release
ok - fallback: a doomed pane holding a persistent child exhausts the proof and takes the plain explicit close
ok - fallback on a defective release: a bounded wrong-focus window of 4 samples was fully restored to the anchor
ok - version floor: herdr 0.7.5 protocol 17 remains conservatively below the floor with steal_live=1
ok - version floor: an unconfigured home falls back flat on herdr 0.7.5 and the explicit opt-in still projects
evidence: herdr=0.7.5 protocol=17 steal_live=1 floor_verdict=1 default-session-tripwire=armed
```

Observed output on Herdr 0.8.0:

```text
ok - old path note: this Herdr release preserves focus across the explicit close; continuing with outcome-only assertions
ok - mitigation: every in-operation sample preserved exact focus while the doomed workspace was removed
ok - fallback: a doomed pane holding a persistent child exhausts the proof and takes the plain explicit close
ok - fallback on a focus-preserving release: the plain explicit close preserved exact focus throughout
ok - version floor: herdr 0.8.0 protocol 19 is at or above the floor and preserves focus
ok - version floor: an unconfigured home stays projected on herdr 0.8.0 and the explicit opt-in agrees
evidence: herdr=0.8.0 protocol=19 steal_live=0 floor_verdict=0 default-session-tripwire=armed
```

The same guarded named-lab command passed on 2026-09-03 against Herdr 0.8.2 after this regression joined the required `real-herdr-gated` lane.
It reported `steal_live=0 floor_verdict=0 default-session-tripwire=armed`, with the fleet's default session unchanged before and after.

Part C is the case the suite could not reach before: a doomed pane whose shell holds a persistent background child fails the lone-idle-shell proof on every sample, so the plan takes the plain explicit close, in the geometry where the closing workspace's right neighbour is a spacer rather than the focused anchor.
On 0.7.5 that fallback exposed a bounded four-sample wrong-focus window and restored the anchor exactly; on 0.8.0 the same fallback exposed none, which is why default-on projection is floored at 0.8.0 rather than mitigated further below it.
The suite also cross-checks its own Part A measurement against the floor classifier on whatever release it runs, so a drifted protocol-to-release mapping fails there rather than silently gating on the wrong thing.

### Attached foreground viewer

A pseudo-terminal registers as a Herdr foreground client only when its window grid is non-zero.
`script` and a bare `pty.fork()` from a non-tty parent both start at 0x0, which is why PR #4131 could validate only the detached half of the teardown focus guard and left its four attached-client scenarios untested.
The guarded `viewer start` path fixes the pty at the proven 40-row by 120-column grid, sets that size on the master fd before the fork, and scrubs inherited `HERDR_*` variables, which makes the attached scenarios reachable from a headless runner.

Measured on 2026-09-11 against Herdr 0.9.0 protocol 22 on macOS 26.5.2 aarch64 with Python 3.14.6:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-herdr-attached-viewer-live-e2e.test.sh
```

```text
ok - attached viewer: a pty sized before the fork registers as a real Herdr foreground client
ok - attached viewer: a live client on the target tab refuses the close and keeps the pane
ok - attached viewer: focus moving onto the target between planning and mutation still blocks the close
ok - attached viewer: a close preserves the fresh non-target focus the viewer moved to
ok - attached viewer: the projection seeded-tab prune refuses while a live client watches it
ok - attached viewer: detaching releases the refusal, so the guard tracks the client and not the pointer
```

Both halves of the recipe are load-bearing, and each was measured by removing it from the helper and re-running the guard on the same host and release.
Dropping the `TIOCSWINSZ` call and dropping the environment scrub each left startup reporting `no_foreground_client`, followed by the guard failure:

```text
not ok - could not attach a real foreground Herdr viewer over a sized pty
```

Re-run this guard after every Herdr upgrade.
A release that changed the foreground-client contract, the window-grid requirement, or the nested-viewer refusal would fail here first, and the detached regressions would keep passing while saying nothing about it.

### Presentation version floor

Default-on presentation projection is floored at Herdr 0.8.0.
The floor's structural signal is the selected running server's protocol number, falling back to the client protocol only when that selected session positively reports no running server, and the release mapping was measured on 2026-08-05 by running each pinned upstream macOS aarch64 release asset's own `status --json` through the guarded lab helper:

| Release | Reported version | Protocol | Carries both upstream focus fixes | Floor verdict |
|---|---|---|---|---|
| v0.7.3 | 0.7.3 | 16 | no | below |
| v0.7.4 | 0.7.4 | 16 | no | below |
| v0.7.5 | 0.7.5 | 17 | no | below |
| preview-2026-07-21-0f10e1453a7f | 0.7.5-preview.2026-07-21-0f10e1453a7f | 17 | no | below |
| preview-2026-07-29-44b3adb12552 | 0.7.5-preview.2026-07-29-44b3adb12552 | 18 | yes | below |
| preview-2026-08-04-d78e3d3b5126 | 0.8.0-preview.2026-08-04-d78e3d3b5126 | 19 | yes | above |
| v0.8.0 | 0.8.0 | 19 | yes | above |

No build lacking both fixes reaches protocol 19, and every pre-fix build tops out at 17, so protocol 19 is a safe structural expression of the 0.8.0 floor.
The one post-fix build below it is a preview that still reports a 0.7.5 version, so it is conservatively treated as below the floor, which costs a preview build its projection and never lets an unfixed build through.
The 2026-08-05 named-lab cross-version probe started a server from Herdr 0.7.5 and queried it with the installed 0.8.0 client; status reported client version 0.8.0 protocol 19, server version 0.7.5 protocol 17, server running true, and server compatible false.
That ordinary post-upgrade shape proves the running server owns the focus behavior, so the unconfigured default composes client and selected-server verdicts conservatively and rechecks after server ensure before publishing a journal or creating a workspace.

Refresh this table with the opt-in guard, which re-downloads the pinned assets, verifies their digests, and fails naming any release whose reported version, protocol, or verdict has moved:

```sh
FM_HERDR_VERSION_FLOOR_LIVE_E2E=1 tests/fm-herdr-version-floor-live-e2e.test.sh
```

The classifier itself, the config preference it composes with, and the one-warning-per-release behavior are pinned portably with no Herdr installed:

```sh
tests/fm-backend-herdr.test.sh
```

Observed guarantees: every measured release classifies as the table records; either the protocol or the version signal alone carries an at-or-above verdict, and each divergent pair flips once the carrying signal is removed; client and running selected-session server verdicts compose conservatively, an unreadable server-running state and losing both release signals report indeterminate and fall back flat, the default is rechecked after server ensure before projection publication, an unconfigured home is projected only at or above the floor, an explicit `on`, including the historical empty opt-in file, is honored below it, and the below-floor warning is emitted once per home per detected release rather than once per spawn.

The whole real-Herdr lane was run on 2026-08-05 against both the CI-pinned Herdr 0.7.4 protocol 16, which is below the floor, and Herdr 0.8.0 protocol 19, which is at it:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh bin/fm-test-run.sh --lane real-herdr-gated
```

Both runs reported `family=real-herdr-gated count=11 failed=0`.
The projection suite's unconfigured-home case is release-aware rather than pinned to one outcome, so it proves the projected default on 0.8.0 and the flat fallback with its naming warning on 0.7.4:

```text
ok - real Herdr lab: a home that configured nothing is projected by default on herdr 0.8.0
ok - real Herdr lab: a home that configured nothing falls back flat on below-floor herdr 0.7.4 with one naming warning
```

Every other case in that suite uses an explicit opt-in or opt-out, so the floor leaves them unchanged on both releases.

Direct lab probes on 2026-07-28 established the removal rules the emptying-close plan relies on, each verified with `workspace list` focus reads around one mutation in a guarded `fm-lab-` session:

- An explicit `pane close` that emptied a non-focused workspace moved focus off the focused workspace in both before-focus and after-focus geometries.
- Ending a workspace's lone shell preserved the focused workspace exactly when the dying workspace sat behind it or the focused workspace was last, and moved focus to the focused workspace's right neighbor otherwise.
- The production focus-preserving close in the dangerous geometry repositioned the doomed workspace, ended its proved shell, and left every concurrent focus sample on the exact anchor with no corrective `tab focus` issued.

Two real-hardware conditions were required for the pane-death path to engage and are now encoded in the adapter and its unit fixtures: BSD `ps` reports a login shell's `comm` as `-zsh`, and an idle shell transiently hosts a prompt helper (starship) as a second foreground process immediately after a `workspace.move` relayout, which the bounded settle window absorbs.

The rules match the v0.7.5 tag source (`close_selected_workspace` reassigns focus from the closing workspace's index; `handle_pane_died` only clamps the stale focused index), and the upstream default branch resolves both paths by workspace id (PR #1877, commit `165dca45`, for the explicit close; PR #1912, commit `a979916`, for pane death), so the plan degrades to a harmless reorder-then-remove once a release carries them.

The full projection and restored-shell suites were re-run on 2026-07-28 on Herdr 0.7.5 with the updated close path; the presentation suite completed with `real Herdr lab validation completed on Herdr 0.7.5 with the default-session tripwire intact`, and the restored-shell cleanup guarantee above was unchanged.

The teardown-level record-retention gate was verified on 2026-07-28 with metadata fixtures and a live contending lock holder:

```sh
tests/fm-teardown.test.sh
tests/fm-backend-herdr.test.sh
```

Observed guarantees: a contended presentation lock refused the teardown before the isolated copy was returned, with the task branch, every durable record, and the endpoint intact and no pane close attempted; the retry after the contention cleared returned the copy, closed the pane under the lock, and removed the records; an unknown structured-presence result after an attempted projected close retained the journal and every record with a nonzero exit; and every presence-gate mode accepted only a structured not-found as gone.

The same fixtures verified three further boundaries on 2026-07-29: missing or malformed endpoint identity and an unparseable pane presence refused record removal with everything retained; the SIGKILL escalation re-read the exact pane's process information and refused to signal when a different shell pid owned the pane, falling back to the plain close with the original process untouched; and a reposition whose removal then failed on every path restored the exact original workspace order through a second verified move and reported the close as failed.

The teardown fixture was re-run on 2026-07-31 after extending the same fail-closed boundary through forced secondmate cleanup, including recursive cleanup of a nested secondmate whose Herdr grandchild close remains unconfirmed.

Observed output:

```text
ok - forced secondmate teardown preflights every Herdr child before cleanup mutation
ok - forced secondmate teardown retains Herdr child identity until exact pane disappearance
ok - forced teardown retains a nested secondmate home and its grandchild's Herdr identity when the grandchild close is unconfirmed
```

### Composer and operational input

Real captures verified these active distinctions:

- Claude and Codex use bare `❯` and `›` agent composers.
- Pi uses content between complete separator rows and requires exact native Pi identity.
- Dim or faint suggestion text is ghost content, while normally styled text is pending input.
- Grok dark truecolor placeholders are ghost content, while bright truecolor typed input remains pending.
- A bare shell prompt has no safe agent-composer container and is unknown.
- Codex 0.154's idle braille starfield rows are composer furniture, with the dated Herdr capture in [Composer classification matrix](#composer-classification-matrix).

`tests/fm-composer-ghost.test.sh`, `tests/fm-composer-lib.test.sh`, and the Herdr composer cases pin the exact captured ANSI bytes.
The U+2063 operational and routed-request separators were exercised through a real Pi-on-Herdr path; the byte-exact active regression is:

```sh
FM_SEND_MARKER_HERDR_E2E=1 \
  tests/fm-send-secondmate-marker-herdr-e2e.test.sh
```

### Native blocked event

The protocol-16 event path was measured on 2026-07-11 with Herdr 0.7.3 and Python 3.13:

```sh
HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-backend-herdr-eventwait-smoke.test.sh
```

Observed output:

```text
ok - real herdr: events.subscribe capability gate passes
ok - real herdr: a driven idle->blocked transition returns the blocked record in 0.129s
ok - real herdr: the watcher fast-path enqueues a stale wake naming the task window
```

Polling remained active and is covered as the fallback for capability, connect, subscribe, and repeated reader failure.

### Agent lifecycle control

Herdr is one of the two backends whose recovery-grade agent-state classifier the control plane may trust ([agent-control.md](../agent-control.md)), so its lifecycle gating is measured against the real binary; reverified 2026-08-08 on Herdr 0.8.0, and first measured 2026-08-02 on Herdr 0.7.5 with identical results:

```sh
tests/fm-control-herdr-smoke.test.sh
```

Observed output, refreshed 2026-09-10 on Herdr 0.9.0 after the stale-registration fix (the two stale-registration lines are recorded under "Stale agent registration" below):

```text
ok - real herdr: exit on a pane with no registered agent is idempotent success
ok - real herdr 0.9.0: a gone session reads recoverable while a live pane and a malformed target do not
ok - real herdr: a drifted agent-free shell returns to its worktree and reuses the same endpoint
ok - real herdr: interrupt refuses when herdr's own agent registry reports no agent
ok - real herdr: interrupt delivers the harness's key and proves the agent survived it
ok - real herdr: no control verb removed the endpoint or the task's local copy
ok - real herdr 0.9.0: a registration Herdr keeps after its agent exits reads stale-agent and recovers as dead
ok - real herdr: exit on a pane with a stale registration is idempotent success
ok - real herdr: a stale registration no longer blocks relaunch, and the endpoint and local copy survive
ok - real herdr: an agent that does not stop fails closed instead of being reported as stopped
```

The registry read through `herdr pane report-agent` is the same source `fm_backend_herdr_agent_state` classifies, and since 2026-09-10 that registration counts as an agent only while `pane process-info` shows a harness process behind it, so the guard backs the registration with a real process named like a harness (a symlink to `sleep`) and then stops that process, with no real harness launched.
That command is the guard that refreshes this record; run it after every Herdr upgrade rather than trusting the version above.

For Pi on Herdr 0.9.0, `herdr agent get` reflects whether the agent process remains live; its registration does not persist merely because the pane and parent shell do.
A Pi launched as a child of the pane shell (not via `exec`) that then `/quit`s or is SIGKILL'd leaves the pane and shell in place, and `agent get` returns `agent_not_found`.
A sibling live idle Pi stays `agent=pi` with `agent_status=idle`.
`fm_backend_herdr_pane_agent_state` maps that `agent_not_found` leftover shell to `no-agent` and `fm_backend_herdr_agent_state` maps it to `dead` (relaunch-allowed), while the live idle pane stays `alive`.
`herdr pane get` `.agent_status` can still read `idle` after the occupant is gone; liveness is `agent get`, never that pane field.

```sh
tests/fm-backend-herdr-agent-exit-shell-e2e.test.sh
```

Refresh that live pair after every Herdr upgrade. Observed 2026-09-10 on Herdr 0.9.0 / protocol 22 with Pi 0.82.0 in an isolated `fm-lab-` session:

```text
ok - agent get distinguishes leftover-shell (dead/no-agent) from live idle Pi
ok - pane get agent_status lag cannot keep an exited occupant classified alive
```

### Endpoint recovery classification

Measured 2026-09-10 on macOS aarch64 against Herdr 0.9.0 (protocol 22) in an isolated `fm-lab-` session.

An endpoint recorded in a session whose server is not running cannot be read by any operational call, and `status` is the one command that answers with a body instead of refusing:

```sh
herdr pane get w1:p2 --session fm-lab-never-started
herdr status --json --session fm-lab-never-started | jq -c "{running: .server.running, status: .server.status}"
```

```text
{"id":"cli:pane:get","error":{"code":"server_not_running","message":"no herdr server is running at /Users/kunchen/.config/herdr/sessions/fm-lab-never-started/herdr.sock; run `herdr session attach fm-lab-never-started` to start or attach it"}}
{"running":false,"status":"not_running"}
```

`fm_backend_herdr_agent_state` therefore settles an uninterpretable pane read with `.server.running` rather than with the `server_not_running` error code, which keeps the verdict working across the supported range: the field is present on 0.8.2 protocol 20 and 0.9.0 protocol 22 alike (measured in "Client selection" above), while the code is not.
Only that recovery-grade read is widened; the husk classifier under it stays strict, because it licenses closing panes.
Observed in the lab, in one run:

```text
live agent-free pane                 dead
endpoint in a session with no server missing
malformed target                     unreadable
```

The same run drove `bin/fm-spawn.sh --relaunch` against a real Herdr pane whose shell had been moved outside its recorded worktree: the shell was told once to return, ended in the recorded worktree, and the replacement was launched into the SAME pane, leaving one task tab.

Herdr 0.8.x is not installed on this host, so protocol-20 coverage is structural plus the adapter fixture exercising both response shapes; it is not a live result.
Refresh the live half, which fails naming the installed version, with:

```sh
tests/fm-control-herdr-smoke.test.sh
```

Observed 2026-09-10:

```text
ok - real herdr 0.9.0: a gone session reads recoverable while a live pane and a malformed target do not
ok - real herdr: a drifted agent-free shell returns to its worktree and reuses the same endpoint
```

`tests/fm-backend-herdr.test.sh` pins the logic portably by driving the two signals apart - the same failed pane read yields `missing` under a stopped server and `unreadable` under a running one - and asserts that the husk classifier still refuses on that identical read.
`tests/fm-control-herdr-smoke.test.sh` proves the Herdr-only drift recovery against a real binary in an isolated lab session.
`tests/fm-control-relaunch.test.sh` drives a tmux stub and proves that tmux retains its prior refusal without sending `cd` or any other input to the pane.
The Herdr refusal when a shell accepts the command but does not move is not exercised in this change.

### Stale agent registration

Measured 2026-09-10 on macOS aarch64 against Herdr 0.9.0 (protocol 22) and Pi 0.85.1 in an isolated `fm-lab-` session (upstream issue #4115, duplicates #3639, #3487, #2908, #3545).

Herdr keeps a Pi registration after the Pi process has exited to a shell when a nested interactive shell sits under the pane's top shell, which is the crew shape `treehouse get` leaves behind; a plain `/quit` directly under the top shell, and a `kill -9` of Pi, both released it on this version.
Reproduced in the lab with a nested `zsh` under the pane shell, then `pi` with no prompt, then `/quit`:

```sh
herdr pane run w1:p1 zsh --session "$LAB"; herdr pane run w1:p1 pi --session "$LAB"
herdr agent get w1:p1 --session "$LAB" | jq -c '.result.agent | {agent, agent_status}'
herdr pane process-info --pane w1:p1 --session "$LAB" | jq -c '.result.process_info | {shell_pid, fg: .foreground_process_group_id, procs: [.foreground_processes[] | {pid, name, argv0}]}'
herdr pane send-text w1:p1 '/quit' --session "$LAB"; herdr pane send-keys w1:p1 Enter --session "$LAB"
herdr agent get w1:p1 --session "$LAB" | jq -c '.result.agent | {agent, agent_status}'
herdr pane process-info --pane w1:p1 --session "$LAB" | jq -c '.result.process_info | {shell_pid, fg: .foreground_process_group_id, procs: [.foreground_processes[] | {pid, name, argv0}]}'
```

```text
{"agent":"pi","agent_status":"idle"}
{"shell_pid":87754,"fg":35952,"procs":[{"pid":35952,"name":"node","argv0":"pi"}]}
{"agent":"pi","agent_status":"idle"}
{"shell_pid":87754,"fg":35834,"procs":[{"pid":35834,"name":"zsh","argv0":"zsh"}]}
```

Before the fix `fm_backend_agent_state herdr` read that second state as `alive`, so `bin/fm-control.sh <id> relaunch` and `bin/fm-spawn.sh --relaunch` were refused for as long as the registration lived, which is hours.
The registration is still present after the wait, and Herdr's own `pane report-agent` leaves the same shape behind on any pane, which is what the lifecycle-control guard uses.

Two vendor facts the fix rests on, both read from the outputs above and from `fm_backend_herdr_pane_process_state`'s `pane process-info` parse:

- Pi's process presents with kernel name `node` and argv0 `pi` (its foreground group also carries Pi's child `node` helpers with argv0 such as `npm view ... version`), so a running Pi is attributed by argv[0] exactly as the tmux probe attributes it; a symlink named `claude` to `sleep` presents as name `sleep`, argv0 `claude`.
- Herdr creates the record with its own placeholder `agent_status` of `unknown` the moment it notices Pi, before Pi's extension reports `idle`; that transient reads `unknown` in the pane classifier as it always did, and only a lifecycle status is subject to the process-level proof.

Subcommand presence below the 0.9.0 measurement, checked 2026-09-10 on macOS aarch64 against the pinned upstream release clients fetched from `https://github.com/ogulcancelik/herdr/releases/download/v<version>/herdr-macos-aarch64`:

| Release | sha256 |
|---------|--------|
| 0.7.1 | `16f4653f0491ea1e7d2b46b5b02542f18e1b82e88daaf9e2900572e5bb634df8` |
| 0.7.3 | `b31345392d004ec1f1b2c821e1ad601019fa8385fe1e4c6931321eb58a920773` |
| 0.7.4 | `24992e1625dbdcb18354a59e299e4b263c312400b31396cdc07cd46ed57f24a7` |
| 0.7.5 | `37350546b0012555943b92eaf962665de4e264395baeb44227b8015e8ff5b0d6` |

The command run against each client was `<client> pane --help`, which is client-side, session-independent, and opens no socket, and each printed the line:

```text
process-info  Show pane process information
```

This proves subcommand presence in the client only, not the server response shape, which is measured only on 0.9.0 above.

The live guard that refreshes this record runs by default wherever Herdr and Pi are installed, spends no model token, and fails naming both versions:

```sh
tests/fm-herdr-pi-stale-registration-live-e2e.test.sh
```

Observed 2026-09-10:

```text
# pi 0.85.1 under herdr 0.9.0: registered idle, foreground [{"name":"node","argv0":"node"},{"name":"node","argv0":"node"},{"name":"node","argv0":"rpiv-ask-user-question version"},{"name":"node","argv0":"npm view gentle-engram version"},{"name":"node","argv0":"pi"}]
ok - real herdr 0.9.0 + pi 0.85.1: a running registered pi classifies alive at process level
# herdr 0.9.0 kept the pi registration (idle) after /quit under a nested shell: the stale-registration branch is exercised
ok - real herdr 0.9.0 + pi 0.85.1: the registration left behind by a quit pi reads stale-agent and recovers as dead
```

`tests/fm-control-herdr-smoke.test.sh` proves the same shape through the control plane with no harness launched (the two `stale` lines under "Agent lifecycle control" above): a registration over a real agent-named process reads `alive`, stopping that process makes the pane read `stale-agent` and recover as `dead` while `agent get` still reports the record, `exit` then reports `already-stopped`, and `--relaunch` reuses the same endpoint with the local copy intact.
`tests/fm-backend-herdr.test.sh` pins the logic portably with canned `process-info` bodies over real processes, driving the signals apart: the identical shell-only foreground reads `stale-agent` for a childless shell and `live` when an agent-named process is still a descendant of that shell, a `working`, `done`, or `blocked` record over a shell-only pane reads the same as `idle`, an unreadable process view reads `unknown` and refuses husk closing, a transient prompt helper beside the shell settles into `stale-agent` on the next shell-only sample while a foreground that never settles within the bound still reads `live`, and `busy_state` verifies a `working` record before reporting busy.
`tests/fm-crew-state.test.sh` pins the recovery classifier: a stale registration over a shell-only pane reports agent gone rather than alive or unreachable, and a stale `working` record never reports the pane working.
A stale-registration pane is never a husk: create, reclaim, presentation recovery, and session cleanup keep refusing it, and only recovery reuses it.

### Agent resume on server restart

Observed 2026-09-18 on Linux x86_64 against Herdr 0.9.0, when a host reboot was followed by a start of the named remote-secondmate server.
The shipped default configuration documents the setting and its default:

```sh
herdr --default-config | grep -B3 'resume_agents_on_restore'
```

```text
[session]
# Resume supported AI-agent panes into their native conversation sessions after
# a Herdr server restart. Requires official integrations that report session refs.
# resume_agents_on_restore = true
```

The named session's server log, pids and ids elided, shows the restore and the resumed agents about two seconds later:

```text
INFO herdr::logging: session restore evaluated event="persist.restore" subsystem="persist" outcome="ok" workspaces=10
INFO herdr::logging: pane child spawned event="pane.spawned" subsystem="pane" outcome="ok" pane_id=2 pid=<shell>
INFO herdr::pane: agent changed pane=2 previous_agent=None agent=Some(Claude) process=claude pgid=Some(<agent>)
```

Each resumed Claude agent ran as `claude --resume <session-id>`, a child of `/bin/sh` under the Herdr server, with no permission flag or other Firstmate launch argument.
The only per-server override the 0.9.0 client documents is the environment: `herdr --help` prints `Env:    HERDR_CONFIG_PATH overrides config file path`, and neither `herdr server --help` nor `herdr config --help` offers a flag for the setting.
The Claude permission-posture check was removed with its worker adapter; `tests/fm-remote-secondmate-replacement.test.sh` and `tests/fm-secondmate-liveness.test.sh` now pin the retained worker replacement and liveness boundaries.

### Away-mode transport

The away daemon is no longer launched on Pi; the away posture there is the record `bin/fm-afk-contract.sh` owns.
The Pi/Herdr away posture and return transport was verified on 2026-09-08 against a real Pi primary in an isolated Herdr lab session, Herdr 0.9.0 and Pi 0.82.0:

```sh
FM_AFK_PI_HERDR_E2E=1 HERDR_LAB_HELPER=bin/fm-herdr-lab.sh \
  tests/fm-afk-pi-herdr-return-e2e.test.sh
```

Relevant transport output:

```text
ok - real Pi primary: the away posture is recorded with no daemon launched
ok - real Pi/Herdr: nothing injects into the captain pane under the away posture
evidence: herdr=herdr 0.9.0 pi=0.82.0 target=fm-lab-fm-afk-pi-return-37189-7133:w1:p1 archived-records=2
```

Observed guarantees: `fm-afk-launch.sh start` refused on the Pi primary and `confirm` recorded the posture with no daemon pid, flag, or terminal; a pending real Pi draft was left untouched with nothing submitted into the captain pane; the unmarked return request was recognized as the return, rendered the brief health first, and opened the catch-up gate on the live blocker; resolving the blocker cleared the gate, and a clean re-entry and return left exactly one archived record per away window.
The current catch-up reporting boundary is pinned by `tests/fm-afk-return.test.sh` and the same live entry point: Bearings continues through a pending return catch-up, projects its posture as an action-free warning outside Captain's Call, and drops that warning after the gate clears, while an active away window still refuses.
The fixture captures submitted input through Pi's `input` extension hook, so the lab agent directory needs no provider credentials.
The daemon injection transport into a live composer keeps its coverage in `tests/fm-afk-inject-herdr-e2e.test.sh` for the harnesses that still run the daemon, and the dedicated Herdr daemon workspace topology is covered by `tests/fm-afk-launch.test.sh` and preserves the captain tab's pane count.

## stream

### Portable stream-parity regressions

[`tests/fixtures.sh`](../../tests/fixtures.sh)'s `fm_test_fake_stream` supplies fake fleet endpoints to the real adapter; its header owns setup and helper usage, and [`stream-hub-stub.py`](../../tests/assets/stream-hub-stub.py)'s docstring owns fake-shell behavior.
`tests/fm-test-fixtures.test.sh`, `tests/fm-backend.test.sh`, `tests/fm-send-strict.test.sh`, and `tests/fm-crew-state.test.sh` exercise fixture round trips, spawn metadata, unrecorded explicit-target routing, and busy/idle/missing/unreachable crew reads.
`tests/fm-control-recover-missing.test.sh` covers new-endpoint rebinding, refusal for a local agent with the task's label and owning status path, preservation of unrelated agents, and confirmed versus unconfirmed cleanup after a failed rebind.
`tests/fm-endpoint-rebind-lib.test.sh` pins endpoint-only record replacement and identity refusals; `tests/fm-meta-backfill.test.sh` pins legacy backend backfill, dry-run, idempotency, and classification refusals.
These fake-fleet cases prove integration routing, not real PTY behavior or installed-harness identity.
The local-PID regression in `tests/fm-backend-stream.test.sh` instead runs the real Python hub and agent with a harness-named stand-in process, checks that its reported PID exists locally, and refuses other-machine and unknown-endpoint PID reads.

### Rust hub isolated compatibility

Measured 2026-10-01 on macOS with Rust 1.96.0 and Python 3.9.6 against Hub 2.0.0, protocol 3.
The Rust binary was a debug build; these single-run observations describe an isolated loopback pilot, not a production capacity guarantee or target budget.
The driver measures ready-file startup, `ps -o rss=` resident KiB before frame traffic, and 100 sequential 4096-byte published frames through the HTTP and screen-rendering path.

```sh
bash tests/fm-stream-hub-rust.test.sh
cargo +stable fmt --all --check
cargo +stable clippy -p fm-stream-hub --all-targets --no-deps -- -D warnings
cargo +stable test --workspace --locked
```

Observed parity output:

```text
differential: 165 HTTP/stream observations and Python agent/bridge lifecycle match
measurements: {"python": {"frame_mib_per_second": 0.53, "rss_kib": 22464, "startup_ms": 95.88}, "rust": {"frame_mib_per_second": 0.46, "rss_kib": 5856, "startup_ms": 16.87}}
ok - Rust hub: HTTP, stream, order and Python peer compatibility
```

The hub crate's tests cover expiry boundaries, capability revocation, authoritative close preservation, late-result uncertainty, and an active order whose id is evicted from the bounded journal.
`crates/fm-stream-hub/tests/cli.rs` covers executable-level JSON compatibility, allocation refusals, terminal parameters, live SSE output, and request liveness with idle command polls.
Its deep-command regression checks byte-exact payloads through 200,000 nested arrays, overwritten duplicate-key values, malformed nested-body refusal, and subsequent health/task reads.
`tests/assets/stream-hub-differential.py` checks forwarded command bytes for non-finite numbers, lone surrogates, and deeply nested composites against the Python hub, including `POST status` with `note=[NaN, "\ud800"]`; its Python-peer case also compares the resulting durable status bytes.
The HTTP regressions in `crates/fm-stream-hub/src/main.rs` cover deletion across reap/re-registration and SSE endpoint-incarnation binding.
The differential driver's terminal cases compare Unicode width, ANSI rendering, oversized CSI integers, and OSC/DCS boundaries against the Python reference.
Its native-steering cases compare execution/order-bound `steer` command payloads, refusal without a receiver, and refusal when re-registration changes receiver capabilities.
The existing bridge suite also passes with `FM_TEST_STREAM_HUB_BINARY="$PWD/target/debug/fm-stream-hub" bin/fm-test-run.sh tests/fm-stream-bridge.test.sh`.
A complete hub-suite invocation on this host stops at the existing shell-died-at-birth refusal case documented below, after the earlier HTTP/body, stream, capture, registry, and state-read cases pass against Rust.
The backend suite no longer requires a `setsid` executable; see [the stream prerequisites](../stream-backend.md#prerequisites) for the fallback dependency.
This is not a claim that every stream suite passes on macOS: the existing Rust-bridge HTTPS fixture cannot validate its generated certificate with this host's Python trust store.
The replacement prerequisites are owned by [the stream guide](../stream-backend.md#rust-hub).

### Deck home-host lifecycle

Measured 2026-09-24 on macOS with Bash 3.2.57 and Python 3.14.2 using the portable fixtures, not live model calls.
`FM_LIVE=0 bin/fm-test-run.sh tests/fm-deck-harness.test.sh` exercises the real Deck driver against a shimmed Deck binary; its native PTY regression reports:

```text
ok - Deck idle Ctrl+C stays a signal, not fake input, while partial input remains visible
```

`PATH="<setsid-shim-dir>:$PATH" SHELL=/bin/bash FM_LIVE=0 bin/fm-test-run.sh tests/fm-backend-stream.test.sh` exercises the shared driver, lifecycle control, and durable inbox through the real Python hub and agent.
This host lacks a native `setsid` executable, so the shim performs Python `os.setsid()` followed by `os.execvp()`; native `setsid` and live Deck model calls are not proven by this run.
The lifecycle case reports:

```text
ok - stream: idle Deck exits; genuine pending text refuses without stopping the host
ok - stream: Deck launch, alive classification, durable steering, exit, relaunch and recovery
ok - stream: a restarted hub's registry gap licenses no secondmate respawn
ok - stream: Deck interrupt preserves a usable idle composer for exit
```

This is targeted lifecycle evidence, not a claim that the complete stream suite passes: in that run every other case passed except the existing shell-died-at-birth refusal case, which also fails on the unchanged default branch in this environment.
`tests/fm-stream-agent-kill-safety.test.sh` additionally exercises child SIGINT handling under default and ignored parent dispositions, proving that the child normalization leaves the parent unchanged.
