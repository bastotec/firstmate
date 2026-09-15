# Live validation of `fm-control.sh <id> recover-missing`

Everything here was driven against a **real tmux server** on a private socket
(`tmux -L`), with the real `bin/fm-control.sh` and the real `bin/fm-spawn.sh`
launch handoff. No tmux stub. The only stand-in is the harness binary itself:
a `claude` on PATH that rewrites argv[0] so the pane's foreground process is
named `claude`, which is exactly what the tmux liveness probe reads.

| file | what it shows |
| --- | --- |
| `live-recover-missing.sh` / `.log` | The motivating rescue end to end: a live endpoint refuses, a missing WINDOW is recreated and relaunched, a gone SESSION is recreated and relaunched, and the dirty-copy / absent-copy / runtime-switch refusals change nothing. Includes the recreated pane's `capture-pane` and the launched agent's argv. |
| `live-recover-guards.sh` / `.log` | The two guards the main transcript does not cover: a Treehouse pool slot reassigned to another task refuses with the record byte-identical (and the same task's own claim recovers), and a secondmate whose configured pin says `codex` still comes back on its recorded `claude / opus / xhigh`. |
| `live-recover-launch-failure.log` | An unplanned real failure that exercised the rollback message this change added: the launch handoff failed after the terminal was already back, and the operator was told no agent was ever stopped, where the work is preserved, and to retry with `relaunch`. |
| `recover-missing-suite.log` | The repository's own targeted suite, `tests/fm-control-recover-missing.test.sh`. |
