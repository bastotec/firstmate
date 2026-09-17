# Adversarial drives

## A. The custody gate must not suppress the rebase it exists to direct

The emitted contract says: "Never rebase while the pipeline owns the branch: ... and no run on the branch means it is yours to rewrite."
Driving the real custody library (bin/fm-nm-run-lib.sh) with the three axi-status shapes a worker meets:
```
NORUN     branch_sync.state=<absent>         pipeline-owns-branch=NO  => worker may rebase: yes
OWNED     branch_sync.state=pipeline_owned   pipeline-owns-branch=YES => worker may rebase: NO
RETURNED  branch_sync.state=worker_owned     pipeline-owns-branch=NO  => worker may rebase: yes
```

A worker mid-implementation (no run on its branch) is free to rebase - the defect a prior round introduced and this change reverses.

## B. No serializing bias anywhere in the emitted worker contract
```
$ grep -niE 'wait for|hold until|block(ed)? (on|until)|do not start|pause until|serialize' <generated ship brief>
1:You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.
116:After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append `done: PR {url} checks green` and stop. You are finished.

(both hits are pre-existing lines unrelated to concurrent work: the crewmate preamble and the CI-ready return point)
```

## C. The notice channel the section names actually delivers

Firstmate enqueues an overlap notice into the exact inbox path the generated brief prints, and the worker's documented list/read/ack loop runs:
```
$ inbox path printed in the generated brief:
'/tmp/fm-xw-drive.jX1KUu/home/state/live-direct-PR.inbox'

$ firstmate enqueues the overlap notice

$ worker lists the inbox
/tmp/fm-xw-drive.jX1KUu/home/state/live-direct-PR.inbox/001.msg

$ worker reads the message
Other work in flight: task fm/auth-refresh is rewriting bin/fm-auth.sh and tests/fm-auth.test.sh, the same files your task touches. Keep going; rebase once it lands.
$ worker acknowledges by moving it to handled/ -> unhandled queue is now empty: []
```

## D. Fail-before / pass-after
```
$ target tests/fm-brief.test.sh run against the base tree (823f8e76):
not ok - brief-xw-nomistakes: ship brief lost the concurrent-work section   (rc=1)

$ same test against cf0038d0 and e8624511 (the pre-fix rounds):
not ok - brief-xw-nomistakes: concurrent-work section no longer bars a rebase of a pipeline-owned branch

$ against the target tree (f062e85c):
ok - fm-brief.sh: ship briefs carry the cross-worker awareness contract, scouts and charters do not
```
