# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch `fm/ev-local-only`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if `main` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append `done: ready in branch fm/ev-local-only` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local `main` through the guarded fast-forward path.
