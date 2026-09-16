# The "Firstmate instruction inbox" section of the charter published on the remote host

Produced by driving the real product: `bin/fm-remote-home-seed.sh ios remote-mac <remote-root> <remote-home> alpha`
over the deterministic SSH boundary, then reading `<remote-home>/data/charter.md` — the file the remote
second mate actually opens. Fixture paths are rewritten to the reported case (`/home/bruno/secondmates/bob-helper`
for the remote home, `/Users/bastotecnologia/Projects/firstmate` for the parent) so the lines read as reported.

## Before — base `8b10b61` (the reported defect)

```
# Firstmate instruction inbox
Firstmate steers you through durable message files in '/Users/bastotecnologia/Projects/firstmate/state/ios.inbox'.
When a terminal message says an instruction is waiting there ... acknowledge each handled message by moving it: `mv '/Users/bastotecnologia/Projects/firstmate/state/ios.inbox'/NNN.msg '/Users/bastotecnologia/Projects/firstmate/state/ios.inbox'/handled/`.
```

The inbox is the PARENT Mac's state path. It does not exist on the remote host, and it is not where steers land.
(The parent-replies path in the same charter rendered as `'"/home/bruno/.../parent-replies.status"'` — stray quotes.)

## Intermediate — `69e15dc` (inbox rewritten, but bash 3.2 left stray quotes)

```
Firstmate steers you through durable message files in '"/home/bruno/secondmates/bob-helper/state/parent-route/ios.inbox"'.
... `mv '"/home/bruno/.../ios.inbox"'/NNN.msg '"/home/bruno/.../ios.inbox"'/handled/`.
```

Still not the real directory, and the `mv` would target a literally double-quoted name.

## After — target `4f9b4a1`

```
# Firstmate instruction inbox
Firstmate steers you through durable message files in '/home/bruno/secondmates/bob-helper/state/parent-route/ios.inbox'.
When a terminal message says an instruction is waiting there - and at any natural checkpoint when you are unsure - list '/home/bruno/secondmates/bob-helper/state/parent-route/ios.inbox'/*.msg, read and act on each message in numeric order, then acknowledge each handled message by moving it: `mv '/home/bruno/secondmates/bob-helper/state/parent-route/ios.inbox'/NNN.msg '/home/bruno/secondmates/bob-helper/state/parent-route/ios.inbox'/handled/`.
```

Every state path the published charter names now lives on the remote host:

```
'/home/bruno/secondmates/bob-helper/state/parent-replies.status'
'/home/bruno/secondmates/bob-helper/state/parent-route/ios.inbox'
```

## Acted on as the mate would

A steer written by the product's own inbox writer landed in
`<remote-home>/state/parent-route/ios.inbox/001.msg` — the same directory the charter names — and the
charter's own acknowledgement command, run verbatim with only `NNN.msg` filled in, moved it into `handled/`.
Full transcript: `live-drive.log`. Pre-fix transcripts: `before-after-inbox-path.log`, `guard-fails-before-fix.log`.
