# Cross-worker awareness - live drive transcript

All output below was produced by running the real scripts in this worktree against an isolated FM_HOME.

## 1. Ship brief carries the section, in every delivery mode
```
$ FM_HOME=<tmp> bin/fm-brief.sh live-no-mistakes acme-app --mode no-mistakes
$ FM_HOME=<tmp> bin/fm-brief.sh live-direct-PR acme-app --mode direct-PR
$ FM_HOME=<tmp> bin/fm-brief.sh live-local-only acme-app --mode local-only

$ section headings of the generated no-mistakes ship brief:
3:# Task
10:# Herdr lifecycle declaration - NOT ENABLED
15:# Setup
25:# Rules
66:# Firstmate instruction inbox
71:# Other work in flight
78:# Project memory
85:# Definition of done

$ the generated section (identical in all three modes):
# Other work in flight
You may not be the only worker on this project.
When other work touches your area, firstmate names that work and what it touches - in the task above, or through the instruction inbox - and tells those workers about you.
That notice is awareness, not a hold: keep going, and rebase onto the updated default branch once the other change lands rather than designing around it, waiting for it, or narrowing your own change to avoid it.
Never rebase while the pipeline owns the branch: after a run, the pipeline's own branch-custody contract decides when ownership returns through `branch_sync.next_action` from structured axi status, and no run on the branch means it is yours to rewrite.
Two edits in one file are an ordinary rebase; a genuine semantic conflict - two changes that cannot both be true - is firstmate's call, so append `needs-decision: {the two changes and why they cannot both hold}` and stop instead of resolving it yourself.

```

## 2. Scout brief and secondmate charter omit it
```
$ scout headings:
3:# Task
10:# Herdr lifecycle declaration - NOT ENABLED
15:# Setup
21:# Rules
58:# Firstmate instruction inbox
63:# Definition of done

$ charter headings:
3:# Charter
6:# Routing scope
9:# Project clones
12:# Operating model
21:# The captain and the parent channel
27:# Requests from the main firstmate
41:# Firstmate instruction inbox
46:# Escalation to main firstmate
64:# Definition of done
```

## 3. A promoted scout receives the byte-identical section
```
$ bin/fm-promote.sh live-promote --mode no-mistakes --yolo off
$ <ran the delivery command promotion printed, against a capturing fm-send.sh>
$ headings of the message the promoted worker actually receives:
3:# Task
18:# Current delivery mode contract
25:# Current ship safety rule
33:# Other work in flight
40:# Definition of done

$ cmp <briefed ship section> <promoted scout section>
(identical)
$ md5:
284edbcd56c42f56d923eee6c066979f
284edbcd56c42f56d923eee6c066979f
```
