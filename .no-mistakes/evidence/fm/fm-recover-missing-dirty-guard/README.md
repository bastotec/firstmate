# Live drive: `recover-missing` on a local copy with uncommitted changes

Every transcript here is the real `bin/fm-control.sh` run against a **real tmux
server** on a private socket, a **real git worktree** holding real uncommitted
work, and the real `bin/fm-spawn.sh --relaunch` launch handoff. The only
stand-in is the harness binary itself: a compiled executable named `claude`
that sleeps, so the pane's foreground process classifies as a live agent
without starting a real agent in the fixture worktree.

| file | scenario | result |
| --- | --- | --- |
| `s1-window-gone.txt` | mid-work copy (modified + untracked + staged), tmux window gone, base branch moved on | recovered, exit 0, copy byte-identical, `worktree_dirty=yes` |
| `s2-server-gone.txt` | the reported sequence: the whole terminal server dies; `relaunch` refuses first | session and window recreated, agent relaunched, copy byte-identical |
| `s3-before-fix.txt` | same as s1, driven against the pre-fix tool (`f659839`) | reproduces the report: `worktree ... has uncommitted changes; refusing to recover rather than cleaning it`, exit 1 |
| `s4-guards.txt` | adversarial: dead endpoint, live agent, absent local copy - all on a dirty copy | each still refuses; record, instructions and the dirty copy unchanged |
| `s4d-pool.txt` | adversarial: dirty copy is a Treehouse slot another task claims, then its own | refuses on the other task's claim, recovers on its own with the dirt intact |
