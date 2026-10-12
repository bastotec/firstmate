#!/usr/bin/env bash
# tests/fm-watch-triage.test.sh - wake triage, part 1: the pure classifier
# predicates, then no-verb signal, turn-end and status-note wakes through a real
# bin/fm-watch.sh (absorbed when the crew is provably working, surfaced when not).
# Shared fixtures and the suite overview: tests/watch-triage-helpers.sh.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

test_status_span_actionable_classifier() {
  local dir state offset
  dir=$(make_case classify-signal); state="$dir/state"
  printf 'working: step 1\nworking: step 2\n' > "$state/a.status"
  status_span_has_actionable "$state/a.status" 0 && fail "benign working: span classified actionable"
  printf 'working: x\nneeds-decision: pick A or B\n' > "$state/b.status"
  status_span_has_actionable "$state/b.status" 0 || fail "captain-relevant span classified benign"
  # A failure and a merge result are captain-relevant and must always wake.
  printf 'failed: build broke on main\n' > "$state/d.status"
  status_span_has_actionable "$state/d.status" 0 || fail "a failed: line was not actionable"
  printf 'merged\n' > "$state/e.status"
  status_span_has_actionable "$state/e.status" 0 || fail "a legacy merged line was not actionable"
  # An offset past the whole log has nothing left to classify: an event already
  # classified must not re-fire on the next append.
  offset=$(size_of "$state/b.status")
  status_span_has_actionable "$state/b.status" "$offset" \
    && fail "an already-classified needs-decision re-fired from its own end offset"
  printf 'working: tidying up\n' >> "$state/b.status"
  status_span_has_actionable "$state/b.status" "$offset" \
    && fail "a routine append after a classified decision was classified actionable"
  # An unusable offset (absent, malformed, or past a truncated log) reads the
  # whole file rather than losing the events it cannot account for.
  status_span_has_actionable "$state/b.status" "" || fail "an empty offset did not read the whole log"
  status_span_has_actionable "$state/b.status" "not-a-number" || fail "a malformed offset did not read the whole log"
  status_span_has_actionable "$state/b.status" 99999 || fail "an offset past the log did not read the whole log"
  pass "status_span_has_actionable: benign absorbed, captain events surfaced, classified events not re-fired"
}

# The reported bug, at the classifier: an actionable event followed by a ROUTINE
# append must stay actionable, and must be reported as ITSELF rather than as the
# routine line that happens to sit last.
test_status_span_survives_a_later_routine_append() {
  local dir state event
  dir=$(make_case classify-masked); state="$dir/state"
  printf 'working: setup\nneeds-decision: pick A or B\nworking: still tidying the branch\n' \
    > "$state/mask.status"
  status_span_has_actionable "$state/mask.status" 0 \
    || fail "a needs-decision hidden behind a later working: line was classified routine"
  event=$(status_span_first_actionable "$state/mask.status" 0)
  [ "$event" = "needs-decision: pick A or B" ] \
    || fail "the span reported '$event' instead of the decision it found"
  # The captain-reported shape: a finished release/install reported as done and
  # then followed by routine cleanup chatter must still reach the captain.
  printf 'working: publishing\ndone: release 1.4.0 published and installed\nworking: cleaning the build dir\nnote: cache pruned\n' \
    > "$state/release.status"
  status_span_has_actionable "$state/release.status" 0 \
    || fail "a done: completion hidden behind later routine appends was classified routine"
  event=$(status_span_first_actionable "$state/release.status" 0)
  [ "$event" = "done: release 1.4.0 published and installed" ] \
    || fail "the span reported '$event' instead of the completion it found"
  # A blocker is the away-mode shape of the same masking.
  printf 'blocked: cannot reach the release host\npaused: waiting for release access\n' \
    > "$state/blocked.status"
  status_span_has_actionable "$state/blocked.status" 0 \
    || fail "a blocked: event hidden behind a current wait was classified routine"
  pass "an actionable event is not hidden by later routine appends, and is named as itself"
}

# Closure is the one thing that may retire an event inside a span, and only
# through status_open_decisions' own open/closed rule.
test_status_span_respects_decision_closure() {
  local dir state event open
  dir=$(make_case classify-closure); state="$dir/state"
  printf 'needs-decision [key=api]: pick A or B\nresolved [key=api]: took A\n' > "$state/closed.status"
  status_span_has_actionable "$state/closed.status" 0 \
    && fail "a decision the same span already closed was still classified actionable"
  # Reopening the SAME key after a close must survive: the close belongs to the
  # earlier opening, not to the one that came after it.
  printf 'needs-decision [key=api]: pick A or B\nresolved [key=api]: took A\nneeds-decision: [key=api] pick A or B\n' \
    > "$state/reopened.status"
  event=$(status_span_first_actionable "$state/reopened.status" 0) \
    || fail "a decision reopened under a key that was closed earlier was classified routine"
  [ "$event" = "needs-decision: [key=api] pick A or B" ] \
    || fail "the reopened key surfaced its closed opening instead of the live reopening: $event"
  # A terminal event is never retired by a later closure line.
  printf 'failed: build broke on main\nresolved [key=api]: unrelated\n' > "$state/term.status"
  status_span_has_actionable "$state/term.status" 0 \
    || fail "a failed: event was retired by an unrelated closure"
  # A live decision must survive a NEWER closure that belongs to another key.
  printf 'needs-decision [key=api]: pick A or B\nneeds-decision [key=db]: pick a store\nresolved [key=db]: took sqlite\n' \
    > "$state/two.status"
  event=$(status_span_first_actionable "$state/two.status" 0) \
    || fail "a still-open decision was retired by a newer closure under another key"
  [ "$event" = "needs-decision [key=api]: pick A or B" ] \
    || fail "the span reported '$event' instead of the decision still open"
  printf 'needs-decision [key=pending-reply-x]: unrelated request\nworking: awaiting reconciliation\n' \
    > "$state/rejected-reserved.status"
  event=$(status_span_first_actionable "$state/rejected-reserved.status" 0) \
    || fail "a rejected reserved-key request was silently dropped"
  [ "$event" = "reconciliation-required: needs-decision [key=pending-reply-x]: unrelated request" ] \
    || fail "a rejected reserved-key request was not labeled for reconciliation: $event"
  open=$(status_open_decisions "$state/rejected-reserved.status")
  [ -z "$open" ] \
    || fail "span classification treated a rejected reserved-key request as an open decision: $open"
  pass "span classification retires closed decisions and surfaces rejected transitions for reconciliation"
}

test_malformed_seen_signature_reads_the_whole_log() {
  local dir state f marker offset
  dir=$(make_case malformed-seen); state="$dir/state"; f="$state/task.status"
  printf 'needs-decision: choose the release target\nworking: cleanup\n' > "$f"
  marker="$state/.seen-task_status"
  printf '40' > "$marker"
  offset=$(bash -c '. "$1"; fm_wake_signal_seen_size "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$state" "$f")
  [ "$offset" = 0 ] \
    || fail "a digits-only malformed seen signature was accepted as an offset"
  status_span_has_actionable "$f" "$offset" \
    || fail "a malformed seen signature skipped the actionable start of the log"
  pass "a malformed seen signature causes the whole status log to be classified"
}

test_stale_is_terminal_classifier() {
  local dir state
  dir=$(make_case classify-stale); state="$dir/state"
  printf 'done: ready in branch fm/x\n' > "$state/term.status"
  stale_is_terminal "sess:fm-term" "$state" || fail "terminal stale status not classified terminal"
  fm_write_meta "$state/stream-term.meta" "window=hub-a1b2:0123abcd" "backend=stream"
  printf 'done: ready in branch fm/stream\n' > "$state/stream-term.status"
  stale_is_terminal "hub-a1b2:0123abcd" "$state" || fail "terminal stream stale status not resolved through metadata"
  printf 'working: compiling\n' > "$state/nonterm.status"
  stale_is_terminal "sess:fm-nonterm" "$state" && fail "non-terminal stale classified terminal"
  stale_is_terminal "sess:fm-missing" "$state" && fail "stale with no status classified terminal"
  pass "stale_is_terminal: terminal status surfaces, non-terminal and no-status are benign"
}

test_classifier_primitives() {
  local dir state open activity
  dir=$(make_case classify-primitives); state="$dir/state"
  printf 'working: a\n\ndone: b\n\n' > "$state/x.status"
  [ "$(last_status_line "$state/x.status")" = "done: b" ] || fail "last_status_line did not return the last non-blank line"
  status_is_captain_relevant "done: b" || fail "done: not recognized as captain-relevant"
  status_is_captain_relevant "needs-decision [key=q1]: b" || fail "keyed needs-decision not recognized as captain-relevant"
  status_is_captain_relevant "working: b" && fail "working: wrongly recognized as captain-relevant"
  # Incident regression: free-text "merged" inside a nonterminal working: line must
  # not become captain-relevant (AFK false-terminal path).
  status_is_captain_relevant \
    "working: stage 2 setup complete on PR #74 exact source branch rebased onto merged #76; task dates preserved" \
    && fail "working: ... merged #N wrongly recognized as captain-relevant"
  status_is_captain_relevant "working: rebased onto predecessor #76" \
    && fail "working: predecessor prose wrongly recognized as captain-relevant"
  status_is_captain_relevant "working: PR ready checks green merged ready in branch" \
    && fail "working: free-text tokens wrongly recognized as captain-relevant"
  status_is_captain_relevant "done: PR https://x/pull/76 checks green" \
    || fail "genuine done: checks green not captain-relevant"
  status_is_terminal_verb "done: PR https://x/pull/76 checks green" \
    || fail "done: not a terminal verb"
  status_is_terminal_verb "working: rebased onto merged #76" \
    && fail "working: wrongly classed as terminal verb"
  status_is_captain_relevant "merged" || fail "legacy bare merged free-text not captain-relevant"
  status_is_captain_relevant "PR ready https://x/pull/2" \
    || fail "legacy bare PR ready free-text not captain-relevant"
  [ "$(window_to_task "sess:fm-fix-login-k3")" = "fix-login-k3" ] || fail "window_to_task did not strip session+fm- prefix"
  fm_write_meta "$state/stream-task.meta" "window=hub-a1b2:4567cdef" "backend=stream"
  [ "$(window_to_task "hub-a1b2:4567cdef" "$state")" = "stream-task" ] || fail "window_to_task did not resolve opaque backend target through metadata"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "custom-verb: x" || fail "FM_CAPTAIN_RE override not honored"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "done: x" && fail "FM_CAPTAIN_RE override did not replace the default verb set"
  FM_CAPTAIN_RE='merged|custom-verb:' status_is_captain_relevant "working: rebased onto merged #76" \
    && fail "FM_CAPTAIN_RE override bypassed working: suppression"
  FM_CAPTAIN_RE='checks green|custom-verb:' status_is_captain_relevant "paused: checks green pending approval" \
    && fail "FM_CAPTAIN_RE override bypassed paused: suppression"
  FM_CAPTAIN_RE='custom-verb:' status_is_captain_relevant "custom-verb: x" \
    || fail "nonterminal suppression weakened custom bare-line behavior"
  printf 'needs-decision: should docs mention [key=prose]?\nneeds-decision [key=q1]: real choice\nresolved: docs still mention [key=q1]\nneeds-decision [key=bad key]: malformed\n' > "$state/keys.status"
  open=$(status_open_decisions "$state/keys.status")
  printf '%s' "$open" | grep -F $'q1\t' >/dev/null \
    || fail "a key token in resolved note prose closed the keyed decision"
  printf '%s' "$open" | grep -F $'prose\t' >/dev/null \
    && fail "a key token in note prose changed the decision key"
  printf '%s' "$open" | grep -F $'bad key\t' >/dev/null \
    && fail "an invalid key slug entered the open-decision set"
  cat > "$state/activity.status" <<'EOF'
working [key=phase7]: Phase 7 started
working [key=phase6]: Phase 6 started
working [key=legal]: reviewing legal dependency
done [key=phase6]: Phase 6 completed
resolved [key=phase7]: Phase 7 completed and moved to Done
paused [key=legal]: awaiting external counsel
resolved [key=legal]: legal item returned to the queue
working [key=phase8]: Phase 8 started
EOF
  activity=$(status_open_activities "$state/activity.status")
  printf '%s' "$activity" | grep -F $'phase8\tworking\tPhase 8 started' >/dev/null \
    || fail "the current keyed working phase was not retained"
  printf '%s' "$activity" | grep -F $'phase7\t' >/dev/null \
    && fail "a keyed resolved event did not close the older working phase"
  printf '%s' "$activity" | grep -F $'phase6\t' >/dev/null \
    && fail "a same-key terminal event did not supersede the older working phase"
  printf '%s' "$activity" | grep -F $'legal\t' >/dev/null \
    && fail "a keyed resolved event did not close the declared pause"
  printf 'working: legacy start\ndone: legacy completion\n' > "$state/legacy-activity.status"
  [ -z "$(status_open_activities "$state/legacy-activity.status")" ] \
    || fail "a legacy terminal event did not supersede the default working phase"
  pass "classifier primitives: keyed decisions and activity phases, captain relevance, window-to-task, and overrides"
}

# crew_is_provably_working: the absorb-only-when-provably-working predicate. It is
# benign (absorb) ONLY when fm-crew-state.sh reports the crew as working from an
# actively-running pipeline step (source run-step) or a busy pane (source pane);
# everything else - a stale working: status-log line, a finished/parked/failed run,
# an unknown/torn-down crew, or an empty id - is NOT provable, so it surfaces. The
# fake fm-crew-state.sh (FM_CREW_STATE_BIN) returns a canned verdict per case.
test_crew_is_provably_working_classifier() {
  local dir fakebin
  dir=$(make_case provably-working); fakebin="$dir/fakebin"
  # Point the predicate at this case's hermetic fake and drive its verdict per case.
  # export marks the var for the fake subprocess; it is unset again at the end so it
  # cannot leak into a later test (every behavioral test sets its own verdict anyway).
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  crew_is_provably_working a || fail "active run-step not treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  crew_is_provably_working a || fail "busy pane not treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling'
  ! crew_is_provably_working a || fail "stale status-log working: treated as provably working"
  FM_FAKE_CREW_STATE='state: done · source: run-step · checks green'
  ! crew_is_provably_working a || fail "finished run treated as provably working"
  FM_FAKE_CREW_STATE='state: parked · source: run-step · parked at review'
  ! crew_is_provably_working a || fail "parked run treated as provably working"
  FM_FAKE_CREW_STATE='state: failed · source: run-step · run failed'
  ! crew_is_provably_working a || fail "failed run treated as provably working"
  FM_FAKE_CREW_STATE='state: unknown · source: none · worktree gone'
  ! crew_is_provably_working a || fail "unknown crew treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: run-step · x'
  ! crew_is_provably_working "" || fail "empty id treated as provably working"
  unset FM_FAKE_CREW_STATE
  pass "crew_is_provably_working: only working+run-step/pane is provable; idle/finished/parked/failed/unknown surface"
}

# status_is_paused: the shared pause verb test both consumers read (so neither
# hardcodes the literal). Matches only the verb before the first colon, so a reason
# that merely mentions "paused" does not false-match, and a genuine blocker stays a
# blocker.
test_status_is_paused_classifier() {
  status_is_paused 'paused: holding for the upstream release' || fail "paused verb not recognized"
  status_is_paused '  paused:   waiting on a rate-limit reset' || fail "leading-space paused verb not recognized"
  status_is_paused 'blocked: the build is paused upstream' && fail "a blocked line mentioning paused false-matched"
  status_is_paused 'working: paused the animation loop' && fail "a working line mentioning paused false-matched"
  status_is_paused 'done: shipped' && fail "done classified as paused"
  status_is_paused '' && fail "empty line classified as paused"
  # A pause is deliberately NOT captain-relevant: it is a stop-nagging signal, not
  # work to keep surfacing.
  status_is_captain_relevant 'paused: holding for the upstream release' && fail "paused is captain-relevant (should not be)"
  status_is_paused_or_captain_held 'paused: holding for the upstream release' \
    || fail "declared pause not recognized by the bounded-idle classifier"
  status_is_paused_or_captain_held 'captain-held [key=route]: tracked by task-decision-route' \
    || fail "captain-held transfer not recognized by the bounded-idle classifier"
  status_is_paused_or_captain_held 'resolved [key=route]: captain answered' \
    && fail "resolved decision remained classed as captain-held"
  # The two declarations share one cadence but block on different humans, so the
  # combined predicate cannot be the only discriminator: a recheck has to know which
  # verb it is naming.
  status_is_captain_held 'captain-held [key=route]: tracked by task-decision-route' \
    || fail "captain-held verb not recognized"
  status_is_captain_held 'paused: holding for the upstream release' \
    && fail "a declared pause matched the captain-held verb"
  status_is_captain_held 'working: the captain-held backlog item is next' \
    && fail "a working line mentioning captain-held false-matched"
  status_is_captain_held '' && fail "empty line classified as captain-held"
  pass "status_is_paused: only the leading paused verb matches, paused is not captain-relevant, and the two declared-wait verbs stay separable"
}

# crew_absorb_class: the single fm-crew-state.sh read that returns BOTH absorb
# reasons - working (active run/busy pane), paused (declared external wait), or none
# (surface it) - so the watcher's stale path gets both for one bounded call.
# crew_is_paused delegates to it exactly as crew_is_provably_working does.
test_crew_absorb_class_classifier() {
  local dir fakebin state FM_STATE_OVERRIDE
  dir=$(make_case absorb-class); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE
  # crew_done_pr_url reads the task's own meta through FM_STATE_OVERRIDE, so the
  # done cases below point that read at this case's state dir.
  export FM_STATE_OVERRIDE="$state"
  FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  [ "$(crew_absorb_class a)" = working ] || fail "active run-step not classed working"
  FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  [ "$(crew_absorb_class a)" = working ] || fail "busy pane not classed working"
  FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting upstream'
  [ "$(crew_absorb_class a)" = paused ] || fail "declared pause not classed paused"
  crew_is_paused a || fail "crew_is_paused did not recognize a paused verdict"
  ! crew_is_provably_working a || fail "a paused crew was treated as provably working"
  FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling'
  [ "$(crew_absorb_class a)" = none ] || fail "stale working: status-log classed absorbable"
  FM_FAKE_CREW_STATE='state: unknown · source: none · worktree gone'
  [ "$(crew_absorb_class a)" = none ] || fail "unknown crew classed absorbable"
  ! crew_is_paused a || fail "unknown crew classed paused"
  [ "$(crew_absorb_class "")" = none ] || fail "empty id not classed none"
  # A done verdict is absorbable ONLY while a recorded PR makes the quiet pane
  # a delivery awaiting its merge authority; without that record a crew merely
  # reporting done keeps the ordinary surface-it alarm.
  FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review'
  printf 'pr=https://github.com/acme/widget/pull/7\n' > "$state/a.meta"
  [ "$(crew_absorb_class a)" = "done" ] || fail "done with a recorded PR not classed done"
  crew_is_held_for_merge a || fail "crew_is_held_for_merge did not recognize a held-for-merge crew"
  ! crew_is_provably_working a || fail "a held-for-merge crew was treated as provably working"
  ! crew_is_paused a || fail "a held-for-merge crew was treated as paused"
  printf 'pr=https://gitlab.example/acme/group/widget/-/merge_requests/9\n' > "$state/a.meta"
  [ "$(crew_absorb_class a)" = "done" ] || fail "done with a recorded gitlab PR not classed done"
  printf 'pr=not-a-url\n' > "$state/a.meta"
  [ "$(crew_absorb_class a)" = none ] || fail "done with a malformed PR record classed absorbable"
  rm -f "$state/a.meta"
  [ "$(crew_absorb_class a)" = none ] || fail "done without a PR record classed absorbable"
  unset FM_FAKE_CREW_STATE
  pass "crew_absorb_class: working/paused/done/none from one read, done gated on a recorded PR"
}

# The wedge detector's third liveness input: writes inside the crew's own recorded
# worktree. Every negative outcome must report "no evidence" so the caller keeps
# its existing escalation schedule, and a supervisor-side git read (which touches
# .git, never tracked files) must not be able to fake a positive.
test_crew_worktree_written_since_classifier() {
  local dir state anchor wt home statedir_wt
  dir=$(make_case classify-worktree-writes); state="$dir/state"
  anchor="$state/anchor"; wt="$dir/wt"; home="$dir/mate-home"; statedir_wt="$dir/wt-with-state"
  mkdir -p "$wt/src" "$wt/.git/objects"
  printf 'old\n' > "$wt/src/existing.c"
  set_mtime "$(( $(date +%s) - 300 ))" "$wt/src/existing.c"
  : > "$anchor"
  set_mtime "$(( $(date +%s) - 120 ))" "$anchor"

  # No recorded worktree at all: absence of evidence, never a positive.
  printf 'window=%s\nbackend=stream\nkind=ship\n' "$(stream_window "$state" a)" > "$state/a.meta"
  ! crew_worktree_written_since a "$state" "$anchor" \
    || fail "a task with no recorded worktree reported write evidence"
  # Recorded but gone (torn down): still no evidence.
  printf 'window=%s\nbackend=stream\nkind=ship\nworktree=%s\n' "$(stream_window "$state" b)" "$dir/missing" > "$state/b.meta"
  ! crew_worktree_written_since b "$state" "$anchor" \
    || fail "a torn-down worktree reported write evidence"
  # Present, but nothing written since the anchor.
  printf 'window=%s\nbackend=stream\nkind=ship\nworktree=%s\n' "$(stream_window "$state" c)" "$wt" > "$state/c.meta"
  ! crew_worktree_written_since c "$state" "$anchor" \
    || fail "a quiet worktree reported write evidence"
  # A missing anchor cannot be compared against: no evidence.
  ! crew_worktree_written_since c "$state" "$state/absent-anchor" \
    || fail "a missing anchor reported write evidence"
  # Only .git churn (what firstmate's own read-only git commands touch): pruned.
  printf 'pack\n' > "$wt/.git/objects/fresh"
  printf 'ref\n' > "$wt/.git/index"
  ! crew_worktree_written_since c "$state" "$anchor" \
    || fail ".git churn alone reported write evidence (a supervisor read could fake liveness)"
  # A real file written after the anchor: positive evidence.
  printf 'new\n' > "$wt/src/new.c"
  crew_worktree_written_since c "$state" "$anchor" \
    || fail "a file written after the anchor was not reported as write evidence"
  # An empty id is never evidence.
  ! crew_worktree_written_since "" "$state" "$anchor" || fail "an empty id reported write evidence"

  # A secondmate records a provisioned firstmate home, not a code tree, and such a
  # home supervises itself: its own watcher beacon, pane hashes, and heartbeats keep
  # its state/ churning whether or not the mate produced anything.
  mkdir -p "$home/state"
  printf 'sm-classify-1\n' > "$home/.fm-secondmate-home"
  printf 'beat\n' > "$home/state/.last-watcher-beat"
  printf 'window=remote:sm\nbackend=stream\nkind=secondmate\nworktree=%s\n' "$home" > "$state/sm.meta"
  ! crew_worktree_written_since sm "$state" "$anchor" \
    || fail "a secondmate's own home supervision churn reported crew write evidence"
  # The home marker alone is enough, even when the record does not say secondmate.
  printf 'window=%s\nbackend=stream\nkind=ship\nworktree=%s\n' "$(stream_window "$state" sm2)" "$home" > "$state/sm2.meta"
  ! crew_worktree_written_since sm2 "$state" "$anchor" \
    || fail "a marked firstmate home reported crew write evidence"
  # But an ordinary worktree that merely holds a directory named state is real
  # work: only the home is excluded, never a source directory of that name.
  mkdir -p "$statedir_wt/state"
  printf 'machine\n' > "$statedir_wt/state/machine.go"
  printf 'window=%s\nbackend=stream\nkind=ship\nworktree=%s\n' "$(stream_window "$state" d)" "$statedir_wt" > "$state/d.meta"
  crew_worktree_written_since d "$state" "$anchor" \
    || fail "a source directory named state was hidden from the write probe"
  pass "crew_worktree_written_since: real writes are evidence; no worktree, no anchor, quiet trees, .git churn and a mate's own home are not"
}

# FM_WORKTREE_WRITE_PRUNE is a skip list, so clearing it skips nothing and is the
# obvious way to widen the probe to the whole depth-bounded tree. An empty list must
# therefore widen the walk rather than report no evidence at all, which would
# quietly cost the wedge detector its third liveness input on a home that cleared
# the knob to get more coverage, not less.
test_empty_write_prune_widens_the_probe() {
  local dir state anchor wt saved
  dir=$(make_case classify-empty-write-prune); state="$dir/state"
  anchor="$state/anchor"; wt="$dir/wt"
  mkdir -p "$wt/src" "$wt/.git"
  : > "$anchor"
  set_mtime "$(( $(date +%s) - 120 ))" "$anchor"
  printf 'window=%s\nbackend=stream\nkind=ship\nworktree=%s\n' "$(stream_window "$state" e)" "$wt" > "$state/e.meta"
  saved=$FM_WORKTREE_WRITE_PRUNE
  FM_WORKTREE_WRITE_PRUNE=''
  # A quiet tree is still no evidence, so the caller's schedule is untouched.
  ! crew_worktree_written_since e "$state" "$anchor" \
    || fail "an empty prune list reported write evidence for a quiet worktree"
  printf 'new\n' > "$wt/src/new.c"
  crew_worktree_written_since e "$state" "$anchor" \
    || fail "an empty prune list disabled the probe instead of widening it"
  # Widened means nothing is skipped, including what the default list prunes.
  set_mtime "$(( $(date +%s) - 900 ))" "$wt/src/new.c"
  printf 'pack\n' > "$wt/.git/index"
  crew_worktree_written_since e "$state" "$anchor" \
    || fail "an empty prune list still skipped a directory the default list prunes"
  # Restoring the default prunes .git again, so a supervisor's own read-only git
  # command still cannot fake liveness.
  FM_WORKTREE_WRITE_PRUNE=$saved
  ! crew_worktree_written_since e "$state" "$anchor" \
    || fail "the default prune list stopped keeping .git out of the probe"
  pass "an empty FM_WORKTREE_WRITE_PRUNE widens the probe to the whole depth-bounded tree instead of disabling it"
}

# The same widening, reached the way a home actually configures it: through the
# process ENVIRONMENT, not an in-process assignment made after the library was
# sourced. An empty exported value must survive as empty, because defaulting it with
# the colon form reads "explicitly cleared" as "never set" and hands the default skip
# list straight back to the one home that asked for a wider walk.
# shellcheck disable=SC2016 # single quotes are deliberate: the library path, state dir, and anchor expand inside the bash -c child, not here
test_empty_write_prune_from_the_environment_widens_the_probe() {
  local dir state anchor wt
  dir=$(make_case classify-empty-write-prune-env); state="$dir/state"
  anchor="$state/anchor"; wt="$dir/wt"
  mkdir -p "$wt/.git/objects"
  : > "$anchor"
  set_mtime "$(( $(date +%s) - 120 ))" "$anchor"
  printf 'window=%s\nbackend=stream\nkind=ship\nworktree=%s\n' "$(stream_window "$state" wenv)" "$wt" > "$state/wenv.meta"
  # The one thing written since the anchor sits exactly where the DEFAULT list prunes.
  printf 'pack\n' > "$wt/.git/objects/fresh"
  env -u FM_WORKTREE_WRITE_PRUNE \
    bash -c '. "$1"; crew_worktree_written_since wenv "$2" "$3"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$state" "$anchor" \
    && fail "the default skip list let .git churn count as write evidence"
  FM_WORKTREE_WRITE_PRUNE='' \
    bash -c '. "$1"; crew_worktree_written_since wenv "$2" "$3"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$state" "$anchor" \
    || fail "an empty FM_WORKTREE_WRITE_PRUNE in the environment fell back to the default skip list instead of widening the probe"
  pass "an empty FM_WORKTREE_WRITE_PRUNE exported into the environment prunes nothing, widening the probe"
}

# The probe's walk runs synchronously inside the poll that was about to escalate, so
# it must be wall-clock bounded: -xdev keeps it out of a nested mount, but a worktree
# root that is ITSELF on a hung mount would otherwise stall the very supervisor that
# exists to notice a wedge. A fake find that never returns in time stands in for that
# mount. Hitting the bound must read as NO evidence, exactly like every other
# negative outcome, so the caller's escalation schedule is untouched.
test_worktree_write_probe_is_wall_clock_bounded() {
  local dir state anchor wt slowbin fastbin started elapsed
  dir=$(make_case classify-write-probe-bound); state="$dir/state"
  anchor="$state/anchor"; wt="$dir/wt"; slowbin="$dir/slowbin"; fastbin="$dir/fastbin"
  mkdir -p "$wt/src" "$slowbin" "$fastbin"
  : > "$anchor"
  set_mtime "$(( $(date +%s) - 120 ))" "$anchor"
  printf 'window=%s\nbackend=stream\nkind=ship\nworktree=%s\n' "$(stream_window "$state" slow)" "$wt" > "$state/slow.meta"
  # Both stand-ins report the same hit; only one of them takes longer than the bound
  # to do it, so the prompt one shows what a positive outcome looks like and the
  # bounded assertion below cannot pass merely because the fake failed.
  cat > "$fastbin/find" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$1/hit"
SH
  cat > "$slowbin/find" <<'SH'
#!/usr/bin/env bash
set -u
sleep 30
printf '%s\n' "$1/hit"
SH
  chmod +x "$fastbin/find" "$slowbin/find"
  PATH="$fastbin:$PATH" \
    bash -c '. "$1"; crew_worktree_written_since slow "$2" "$3"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$state" "$anchor" \
    || fail "a walk that reported a hit inside its bound was not read as write evidence"
  started=$(date +%s)
  PATH="$slowbin:$PATH" FM_WORKTREE_WRITE_TIMEOUT=1 \
    bash -c '. "$1"; crew_worktree_written_since slow "$2" "$3"' _ \
    "$ROOT/bin/fm-classify-lib.sh" "$state" "$anchor" \
    && fail "a walk that outlived its bound was reported as write evidence"
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 10 ] \
    || fail "the worktree write probe was not wall-clock bounded: one walk held the caller for ${elapsed}s"
  pass "the worktree write probe is wall-clock bounded, and hitting the bound reads as no write evidence"
}

# signal_crew_provably_working: a no-verb "signal:" wake is benign ONLY when EVERY
# task it references is provably working; if any crew has stopped, or no task can be
# resolved, it surfaces. Files map to ids by stripping .status / .turn-ended.
test_signal_crew_provably_working_classifier() {
  local dir fakebin state
  dir=$(make_case signal-provably-working); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  export FM_FAKE_CREW_STATE_a='state: working · source: run-step · running'
  export FM_FAKE_CREW_STATE_b='state: done · source: run-step · run passed'
  signal_crew_provably_working "$state/a.status" "$state/a.turn-ended" \
    || fail "a single provably-working crew (status+turn-end) was not benign"
  ! signal_crew_provably_working "$state/a.status" "$state/b.turn-ended" \
    || fail "a coalesced batch including a stopped crew was treated as benign"
  ! signal_crew_provably_working "$state/b.turn-ended" \
    || fail "a stopped crew's bare turn-end was treated as benign"
  ! signal_crew_provably_working "$state/a.meta" \
    || fail "a non-signal file resolved to a benign verdict"
  ! signal_crew_provably_working \
    || fail "an empty signal file list was treated as benign"
  unset FM_FAKE_CREW_STATE_a FM_FAKE_CREW_STATE_b
  pass "signal_crew_provably_working: benign only when every referenced crew is provably working"
}

test_secondmate_status_signal_never_absorbed_classifier() {
  local dir fakebin state
  dir=$(make_case secondmate-signal-classify); fakebin="$dir/fakebin"; state="$dir/state"
  export FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh"
  # Even PROVABLY working, a secondmate's .status signal is its routed-reply
  # channel and must surface; its bare turn-ended keeps the ordinary absorb.
  export FM_FAKE_CREW_STATE_sm='state: working · source: run-step · running'
  printf 'kind=secondmate\n' > "$state/sm.meta"
  printf 'working: routed reply for the parent\n' > "$state/sm.status"
  ! signal_crew_provably_working "$state/sm.status" \
    || fail "a working secondmate's status signal was treated as absorbable"
  signal_crew_provably_working "$state/sm.turn-ended" \
    || fail "a working secondmate's bare turn-end lost its ordinary absorb"
  # An ordinary crewmate with the same verdict stays absorbable: the rule is
  # keyed on recorded kind, not on task naming or content guessing.
  export FM_FAKE_CREW_STATE_crew='state: working · source: run-step · running'
  printf 'kind=ship\n' > "$state/crew.meta"
  printf 'working: progress\n' > "$state/crew.status"
  signal_crew_provably_working "$state/crew.status" \
    || fail "the secondmate rule leaked onto an ordinary crewmate status"
  unset FM_FAKE_CREW_STATE_sm FM_FAKE_CREW_STATE_crew
  pass "a secondmate's status signal is never absorbed as provably working; crewmates are unaffected"
}

# --- benign wakes are absorbed ONLY when the crew is provably working ---------

test_provably_working_signal_absorbed() {
  local dir state fakebin out status_file pid
  dir=$(make_case provably-working-signal); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # The crew's pipeline is in an actively-running step: positive evidence it is
  # still working, so a no-verb working: signal is absorbed (the original low-churn
  # case during a long validation).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a working: signal whose crew is provably working (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "provably-working signal printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "provably-working signal enqueued a durable wake record"
  [ -s "$state/.seen-task_status" ] || fail "provably-working signal did not advance its .seen-* suppressor"
  [ -e "$state/.last-watcher-beat" ] || fail "watcher beacon was not touched while absorbing"
  reap "$pid"
  pass "a no-verb signal whose crew is provably working is absorbed (no exit, no queue, suppressor advanced, beacon present)"
}

test_turn_ended_provably_working_absorbed() {
  local dir state fakebin out pid
  dir=$(make_case turn-ended-working); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  : > "$state/task.turn-ended"
  # A busy pane is the second form of positive evidence (covers a queued
  # continuation right after the turn-end).
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a turn-end whose crew is provably working (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "provably-working turn-end printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "provably-working turn-end enqueued a durable wake record"
  reap "$pid"
  pass "a bare turn-end whose crew is provably working (busy pane) is absorbed"
}

# --- a no-verb signal whose crew is NOT provably working SURFACES -------------
# This is the swallowed-finish fix: a crew that finished (or stopped and waits)
# reports its final turn-end with no captain-relevant status and no running
# pipeline, so the wake must surface instead of being absorbed.

test_turn_ended_not_working_surfaced() {
  local dir state fakebin out drain_out pid
  dir=$(make_case turn-ended-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  : > "$state/task.turn-ended"
  # No running pipeline, no busy pane: the crew has stopped (e.g. it finished via
  # an interactive menu and wrote no done: status). Default unknown verdict.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a turn-end whose crew is not provably working"
  grep -F "signal: $state/task.turn-ended" "$out" >/dev/null || fail "watcher did not print the surfaced turn-end signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/task.turn-ended" >/dev/null || fail "surfaced turn-end was not queued"
  pass "a bare turn-end whose crew is not provably working is surfaced (the swallowed-finish fix)"
}

# --- bare turn-end, unverifiable harness: pane churn is the third proof --------
# A crew whose semantic busy state is unknown (no record) can never report
# working, so the two proofs above are unreachable for it and EVERY worker turn
# boundary woke firstmate. Pane content that changed since the previous poll
# is harness-independent positive evidence the crew is still executing - the same
# liveness input the stale backbone already trusts - so a bare turn-end from a
# churning pane is benign. The pane going quiet afterwards is still caught by that
# backbone, which is why this widens the proof rather than bounding the wake rate.

# The pane-churn turn-end absorb is opt-in per home, so every case that exercises
# it (whether it expects an absorb or one of the guards that must still surface)
# points the watcher at a case-local config dir holding the flag. A case that must
# NOT have it points at an empty one, so no developer's real config can leak in.
churn_config() {  # <dir> [off]
  local cfg="$1/config"
  mkdir -p "$cfg"
  [ "${2:-}" = off ] || : > "$cfg/turnend-churn-absorb"
  printf '%s\n' "$cfg"
}

# Wait until the watcher records an absorbed wake matching <needle> in its triage
# log. 1 if the watcher exits first (i.e. it surfaced the wake instead), which is
# exactly the unfixed behavior this case exists to catch. Polls the log rather
# than a poll cycle so the assertion lands inside the FIRST poll, long before an
# unchanging fixture pane could reach the stale backbone.
wait_for_absorbed() {  # <state> <pid> <needle>
  local state=$1 pid=$2 needle=$3 i=0
  while [ "$i" -lt 100 ]; do
    grep -Fq "$needle" "$state/.watch-triage.log" 2>/dev/null && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_turn_ended_churning_pane_absorbed() {
  local dir state fakebin out capture_file window key pid
  dir=$(make_case turn-ended-churning); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window=$(stream_window "$state" codexer)
  : > "$state/codexer.turn-ended"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$window" > "$state/codexer.meta"
  printf 'apply_patch: writing bin/thing.sh' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  # The previous poll recorded DIFFERENT pane content, so this poll's capture is
  # churn: the crew rendered output between the two polls.
  printf '%s' "$(hash_text 'reading the brief')" > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  # A crew-state unknown verdict (no semantic busy record), so
  # crew_is_provably_working can never be satisfied.
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown missing)'
  # A slow poll leaves the first cycle's absorb assertion many ticks clear of the
  # stale backbone, which this static fixture pane would otherwise reach.
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_absorbed "$state" "$pid" "absorbed benign signal:" \
    || { reap "$pid"; fail "a bare turn-end from a churning pane was not absorbed: $(cat "$out")"; }
  [ ! -s "$out" ] || fail "an absorbed churning-pane turn-end printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "an absorbed churning-pane turn-end enqueued a durable wake record"
  [ -s "$state/.churn-since-$key" ] \
    || { reap "$pid"; fail "an absorbed churning-pane turn-end did not open a bounded deferral window"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a bare turn-end from a pane that churned since the previous poll is absorbed"
}

test_turn_ended_churn_resets_prior_stale_classification() {
  local dir state fakebin out capture_file window key old_hash active_hash pid i
  dir=$(make_case turn-ended-churn-resets-stale); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window=$(stream_window "$state" codexreturned)
  : > "$state/codexreturned.turn-ended"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$window" > "$state/codexreturned.meta"
  old_hash=$(hash_text 'idle prompt from an earlier turn')
  active_hash=$(hash_text 'rendering a new turn')
  printf 'rendering a new turn' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$old_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s' "$old_hash" > "$state/.stale-$key"
  date +%s > "$state/.stale-since-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown missing)'
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_absorbed "$state" "$pid" "absorbed benign signal:" \
    || { reap "$pid"; fail "a churning turn-end with prior stale state was not absorbed: $(cat "$out")"; }
  i=0
  while [ "$i" -lt 100 ] && [ "$(cat "$state/.hash-$key" 2>/dev/null || true)" != "$active_hash" ]; do
    kill -0 "$pid" 2>/dev/null || { reap "$pid"; fail "watcher exited before recording the active pane"; }
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.hash-$key" 2>/dev/null || true)" = "$active_hash" ] \
    || { reap "$pid"; fail "watcher did not record the active pane after absorbing its turn-end"; }

  # The worker stops on bytes that happened to be stale in an earlier turn.
  # This is a new quiet interval, so it must surface through ordinary staleness
  # instead of inheriting the earlier interval's wedge timer.
  printf 'idle prompt from an earlier turn' > "$capture_file"
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "a stopped pane matching an earlier stale render waited for the wedge timeout"; }
  grep -Fx "stale: $window" "$out" >/dev/null \
    || fail "the returned stale render did not surface through ordinary staleness"
  grep -F "possible wedge" "$out" >/dev/null \
    && fail "the returned stale render inherited the earlier quiet interval's wedge classification"
  unset FM_FAKE_CREW_STATE
  pass "pane churn starts a fresh stale-classification interval before a stopped render returns"
}

test_turn_ended_churn_resets_wedge_state_before_stale_poll() {
  local dir state fakebin out capture_file window key pid
  dir=$(make_case turn-ended-churn-resets-wedge); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window=$(stream_window "$state" codexfreshinterval)
  : > "$state/codexfreshinterval.turn-ended"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$window" > "$state/codexfreshinterval.meta"
  printf 'rendering a new turn' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'idle output from the prior interval')" > "$state/.hash-$key"
  printf '2\n' > "$state/.wedge-escalations-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown missing)'
  stream_capture "$window" "$capture_file"
  # The capture after the first fails, so the churn proof must come from that
  # one read before the stale path is ever reached.
  fm_test_fake_stream_set "$window" '{"capture_fail_after": 1}'
  PATH="$fakebin:$PATH" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_absorbed "$state" "$pid" "absorbed benign signal:" \
    || { reap "$pid"; fail "a churning turn-end was not absorbed before the stale-path capture failed: $(cat "$out")"; }
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || { reap "$pid"; fail "churn retained the prior quiet interval's wedge-escalation count"; }
  [ ! -s "$state/.wake-queue" ] \
    || { reap "$pid"; fail "the absorbed churn fixture queued an unexpected wake"; }
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "pane churn resets prior wedge escalation state before the stale-path poll"
}

# The safety half: the same unverifiable harness, the same fixture, but the pane
# has NOT changed since the previous poll. There is no positive evidence, so the
# wake must still surface - a stopped worker is exactly what the turn-end marker
# earns its keep detecting, and widening the proof must not cost that.
test_turn_ended_still_pane_surfaced() {
  local dir state fakebin out drain_out capture_file window key pid
  dir=$(make_case turn-ended-still); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window=$(stream_window "$state" codexstopped)
  : > "$state/codexstopped.turn-ended"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$window" > "$state/codexstopped.meta"
  printf 'apply_patch: writing bin/thing.sh' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  # The previous poll recorded THIS pane content: nothing rendered since.
  printf '%s' "$(hash_text 'apply_patch: writing bin/thing.sh')" > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown missing)'
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a bare turn-end from an unchanged pane"
  grep -F "signal: $state/codexstopped.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the surfaced still-pane turn-end signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the still-pane turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/codexstopped.turn-ended" >/dev/null \
    || fail "surfaced still-pane turn-end was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a bare turn-end from a pane unchanged since the previous poll still surfaces"
}

test_turn_ended_malformed_prior_hash_surfaced() {
  local dir state fakebin out drain_out capture_file window key pid
  dir=$(make_case turn-ended-malformed-hash); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window=$(stream_window "$state" codexmalformed)
  : > "$state/codexmalformed.turn-ended"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$window" > "$state/codexmalformed.meta"
  printf 'stopped after rendering this' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf 'x' > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown missing)'
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher absorbed a turn-end backed by a malformed prior hash"
  grep -F "signal: $state/codexmalformed.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the surfaced malformed-hash turn-end"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the malformed-hash turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/codexmalformed.turn-ended" >/dev/null \
    || fail "malformed-hash turn-end was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a bare turn-end backed by a malformed prior hash surfaces"
}

test_turn_ended_trailing_newline_prior_hash_surfaced() {
  local dir state fakebin out drain_out capture_file window key pid
  dir=$(make_case turn-ended-newline-hash); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window=$(stream_window "$state" codexnewline)
  : > "$state/codexnewline.turn-ended"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$window" > "$state/codexnewline.meta"
  printf 'rendered after the prior poll' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s\n' "$(hash_text 'the previous render')" > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown missing)'
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher absorbed a turn-end backed by a newline-terminated prior hash"
  grep -F "signal: $state/codexnewline.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the surfaced newline-hash turn-end"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the newline-hash turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/codexnewline.turn-ended" >/dev/null \
    || fail "newline-hash turn-end was not queued"
  [ ! -e "$state/.churn-since-$key" ] \
    || fail "a newline-terminated prior hash opened a deferral window"
  unset FM_FAKE_CREW_STATE
  pass "a bare turn-end backed by a newline-terminated prior hash surfaces"
}

test_secondmate_turn_ended_churning_pane_surfaced() {
  local dir state fakebin out drain_out capture_file window key pid
  dir=$(make_case secondmate-turn-ended-churning); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window=$(stream_window "$state" mate)
  : > "$state/mate.turn-ended"
  printf 'window=%s\nbackend=stream\nkind=secondmate\nharness=deck\n' "$window" > "$state/mate.meta"
  printf 'working on the next routed item' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'waiting for work')" > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable'
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a churning secondmate turn-end"
  grep -F "signal: $state/mate.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the surfaced churning secondmate turn-end"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the churning secondmate turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/mate.turn-ended" >/dev/null \
    || fail "churning secondmate turn-end was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a churning secondmate turn-end surfaces without a stale resurface path"
}

test_turn_ended_colliding_window_key_surfaced() {
  local dir state fakebin out drain_out capture_file window colliding key pid
  dir=$(make_case turn-ended-colliding-key); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  # A second target whose window key sanitizes to the same string.
  window=$(stream_window "$state" a.b); colliding=$(printf '%s' "$window" | tr '.' '_')
  : > "$state/a.b.turn-ended"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$window" > "$state/a.b.meta"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$colliding" > "$state/a_b.meta"
  printf 'rendered after the prior poll' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'the other window pane')" > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown missing)'
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a turn-end with an ambiguous pane marker"
  grep -F "signal: $state/a.b.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the surfaced ambiguous-marker turn-end"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the ambiguous-marker turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/a.b.turn-ended" >/dev/null \
    || fail "ambiguous-marker turn-end was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a turn-end whose marker key matches another recorded endpoint surfaces"
}

test_turn_ended_duplicate_endpoint_records_surfaced() {
  local dir state fakebin out drain_out capture_file window key pid
  dir=$(make_case turn-ended-duplicate-endpoint); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window=$(stream_window "$state" shared)
  : > "$state/first.turn-ended"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$window" > "$state/first.meta"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$window" > "$state/second.meta"
  printf 'rendered after the prior poll' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'the previous render')" > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown missing)'
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher absorbed a turn-end shared by two endpoint records"
  grep -F "signal: $state/first.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the surfaced duplicate-endpoint turn-end"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the duplicate-endpoint turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/first.turn-ended" >/dev/null \
    || fail "duplicate-endpoint turn-end was not queued"
  [ ! -e "$state/.churn-since-$key" ] \
    || fail "duplicate endpoint records opened a deferral window"
  unset FM_FAKE_CREW_STATE
  pass "two metadata records sharing one endpoint make churn evidence ambiguous"
}

test_turn_ended_mixed_positive_evidence_batch_absorbed() {
  local dir state fakebin out capture_file first_window second_window first_key second_key pid
  dir=$(make_case turn-ended-mixed-evidence); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  first_window=$(stream_window "$state" first); second_window=$(stream_window "$state" second)
  : > "$state/first.turn-ended"
  : > "$state/second.turn-ended"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$first_window" > "$state/first.meta"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$second_window" > "$state/second.meta"
  printf 'second task rendered after the prior poll' > "$capture_file"
  first_key=$(printf '%s' "$first_window" | tr ':/.' '___')
  second_key=$(printf '%s' "$second_window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'first task static pane')" > "$state/.hash-$first_key"
  printf '%s' "$(hash_text 'second task previous render')" > "$state/.hash-$second_key"
  printf '0\n' > "$state/.count-$first_key"
  printf '0\n' > "$state/.count-$second_key"
  export FM_FAKE_CREW_STATE_first='state: working · source: run-step · running'
  export FM_FAKE_CREW_STATE_second='state: unknown · source: pane · harness state unavailable (unknown missing)'
  # The authoritatively working first task's screen must never be read.
  fm_test_fake_stream_set "$first_window" '{"fail_capture": true}'
  stream_capture "$second_window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_absorbed "$state" "$pid" "absorbed benign signal:" \
    || { reap "$pid"; fail "a mixed authoritative-and-churn batch was not absorbed: $(cat "$out")"; }
  [ ! -s "$out" ] || fail "an absorbed mixed-evidence batch printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "an absorbed mixed-evidence batch enqueued a durable wake record"
  [ ! -e "$state/.churn-since-$first_key" ] \
    || fail "an authoritatively working task opened a pane-churn deadline"
  [ -s "$state/.churn-since-$second_key" ] \
    || fail "the churn-proven task did not open its bounded deferral window"
  reap "$pid"
  unset FM_FAKE_CREW_STATE_first FM_FAKE_CREW_STATE_second
  pass "a batch may satisfy positive evidence independently per task"
}

test_turn_ended_mixed_positive_evidence_batch_default_off() {
  local dir state fakebin out drain_out capture_file first_window second_window first_key second_key pid
  dir=$(make_case turn-ended-mixed-evidence-off); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  first_window=$(stream_window "$state" firstoff); second_window=$(stream_window "$state" secondoff)
  : > "$state/firstoff.turn-ended"
  : > "$state/secondoff.turn-ended"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$first_window" > "$state/firstoff.meta"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$second_window" > "$state/secondoff.meta"
  printf 'second task rendered after the prior poll' > "$capture_file"
  first_key=$(printf '%s' "$first_window" | tr ':/.' '___')
  second_key=$(printf '%s' "$second_window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'first task static pane')" > "$state/.hash-$first_key"
  printf '%s' "$(hash_text 'second task previous render')" > "$state/.hash-$second_key"
  printf '0\n' > "$state/.count-$first_key"
  printf '0\n' > "$state/.count-$second_key"
  export FM_FAKE_CREW_STATE_firstoff='state: working · source: run-step · running'
  export FM_FAKE_CREW_STATE_secondoff='state: unknown · source: pane · harness state unavailable (unknown missing)'
  stream_capture "$first_window" "$capture_file"
  stream_capture "$second_window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir" off)" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher absorbed a mixed-evidence batch without the opt-in flag"
  grep -F "$state/firstoff.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the first default-off turn-end"
  grep -F "$state/secondoff.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the second default-off turn-end"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the default-off mixed-evidence batch failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/firstoff.turn-ended" >/dev/null \
    || fail "the first default-off turn-end was not queued"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/secondoff.turn-ended" >/dev/null \
    || fail "the second default-off turn-end was not queued"
  [ ! -e "$state/.churn-since-$first_key" ] && [ ! -e "$state/.churn-since-$second_key" ] \
    || fail "the default-off mixed-evidence batch opened a deferral window"
  unset FM_FAKE_CREW_STATE_firstoff FM_FAKE_CREW_STATE_secondoff
  pass "per-task evidence composition stays off until the home opts in"
}

test_status_and_turn_end_batch_never_uses_churn_evidence() {
  local dir state fakebin out drain_out capture_file first_window second_window second_key pid
  dir=$(make_case status-and-turn-ended-churn); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  first_window=$(stream_window "$state" firststatus); second_window=$(stream_window "$state" secondturn)
  printf 'working: authoritative task still running\n' > "$state/firststatus.status"
  : > "$state/secondturn.turn-ended"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$first_window" > "$state/firststatus.meta"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$second_window" > "$state/secondturn.meta"
  printf 'second task rendered after the prior poll' > "$capture_file"
  second_key=$(printf '%s' "$second_window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'second task previous render')" > "$state/.hash-$second_key"
  printf '0\n' > "$state/.count-$second_key"
  export FM_FAKE_CREW_STATE_firststatus='state: working · source: run-step · running'
  export FM_FAKE_CREW_STATE_secondturn='state: unknown · source: pane · harness state unavailable (unknown missing)'
  stream_capture "$first_window" "$capture_file"
  stream_capture "$second_window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher absorbed a status-and-turn-end batch on churn evidence"
  grep -F "$state/firststatus.status" "$out" >/dev/null \
    || fail "watcher did not print the status file from the surfaced mixed batch"
  grep -F "$state/secondturn.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the turn-end from the surfaced mixed batch"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the surfaced status-and-turn-end batch failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/firststatus.status" >/dev/null \
    || fail "the status file from the surfaced mixed batch was not queued"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/secondturn.turn-ended" >/dev/null \
    || fail "the turn-end from the surfaced mixed batch was not queued"
  [ ! -e "$state/.churn-since-$second_key" ] \
    || fail "a status-bearing batch opened a pane-churn deadline"
  unset FM_FAKE_CREW_STATE_firststatus FM_FAKE_CREW_STATE_secondturn
  pass "a status-bearing batch never falls through to pane-churn evidence"
}

# The opt-in half. Pane churn infers execution from rendered bytes rather than
# from a verdict the harness vouches for, so a home that has not asked for it must
# see exactly the pre-change triage: the same churning fixture that absorbs above
# surfaces here purely because the flag is absent.
test_turn_ended_churn_absorb_off_by_default() {
  local dir state fakebin out drain_out capture_file window key pid
  dir=$(make_case turn-ended-churn-default-off); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window=$(stream_window "$state" codexdefault)
  : > "$state/codexdefault.turn-ended"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$window" > "$state/codexdefault.meta"
  printf 'apply_patch: writing bin/thing.sh' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'reading the brief')" > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown missing)'
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir" off)" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher absorbed a churning turn-end without the opt-in flag"
  grep -F "signal: $state/codexdefault.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the surfaced default-off churning turn-end"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the default-off churning turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/codexdefault.turn-ended" >/dev/null \
    || fail "default-off churning turn-end was not queued"
  [ ! -e "$state/.churn-since-$key" ] \
    || fail "the default-off path opened a bounded deferral window"
  unset FM_FAKE_CREW_STATE
  pass "pane-churn turn-end absorb is off until a home opts in"
}

# The bound. Churn and pane staleness read the same pane, so a pane that renders
# continuously (a clock, a spinner, a harness that leaves a background renderer
# alive after its agent yields) never reaches the staleness backbone's two
# identical hashes either. Without a bound on the churn absorb a worker that had
# genuinely stopped behind such a renderer would have no path left to surface at
# all, so an exhausted deferral window must surface and restart.
test_turn_ended_churn_absorb_bounded() {
  local dir state fakebin out drain_out capture_file window key pid
  dir=$(make_case turn-ended-churn-bounded); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window=$(stream_window "$state" codexclock)
  : > "$state/codexclock.turn-ended"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$window" > "$state/codexclock.meta"
  printf 'a background renderer that never stops' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'the previous frame')" > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  # This endpoint has already been riding churn evidence longer than the bound.
  printf '%s' "$(( $(date +%s) - 600 ))" > "$state/.churn-since-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown missing)'
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" FM_TURNEND_CHURN_ABSORB_SECS=60 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 \
    || fail "a perpetually churning pane deferred its turn-end past the absorb bound"
  grep -F "signal: $state/codexclock.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the turn-end surfaced by the exhausted absorb bound"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the bounded churn turn-end failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/codexclock.turn-ended" >/dev/null \
    || fail "the turn-end surfaced by the exhausted absorb bound was not queued"
  [ ! -e "$state/.churn-since-$key" ] \
    || fail "an exhausted deferral window was not restarted after surfacing"
  unset FM_FAKE_CREW_STATE
  pass "a perpetually churning pane surfaces once its bounded deferral window is spent"
}

test_turn_ended_churn_timer_write_failure_surfaced() {
  local dir state fakebin out drain_out capture_file window key pid
  dir=$(make_case turn-ended-churn-timer-write-failure); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window=$(stream_window "$state" codextimer)
  : > "$state/codextimer.turn-ended"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$window" > "$state/codextimer.meta"
  printf 'rendered after the previous poll' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'the previous render')" > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  mkdir "$state/.churn-since-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown missing)'
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher absorbed a churning turn-end without recording its deadline"
  grep -F "signal: $state/codextimer.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the turn-end whose churn deadline could not be recorded"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the failed churn deadline write failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/codextimer.turn-ended" >/dev/null \
    || fail "turn-end with an unrecordable churn deadline was not queued"
  unset FM_FAKE_CREW_STATE
  pass "an unrecordable pane-churn deadline surfaces the turn-end"
}

test_turn_ended_invalid_churn_bound_surfaced() {
  local dir state fakebin out drain_out capture_file window key pid
  dir=$(make_case turn-ended-invalid-churn-bound); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window=$(stream_window "$state" codexbound)
  : > "$state/codexbound.turn-ended"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$window" > "$state/codexbound.meta"
  printf 'rendered after the previous poll' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'the previous render')" > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown missing)'
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" FM_TURNEND_CHURN_ABSORB_SECS=bogus \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a turn-end with an invalid churn bound"
  grep -F "signal: $state/codexbound.turn-ended" "$out" >/dev/null \
    || fail "watcher terminated before printing the invalid-bound turn-end"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the invalid churn bound failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/codexbound.turn-ended" >/dev/null \
    || fail "turn-end with an invalid churn bound was not queued"
  [ ! -e "$state/.churn-since-$key" ] \
    || fail "an invalid churn bound opened a deferral window"
  unset FM_FAKE_CREW_STATE
  pass "an invalid pane-churn bound surfaces the turn-end"
}

test_turn_ended_oversized_churn_bound_surfaced() {
  local dir state fakebin out drain_out capture_file window key pid
  dir=$(make_case turn-ended-oversized-churn-bound); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window=$(stream_window "$state" codexoversized)
  : > "$state/codexoversized.turn-ended"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$window" > "$state/codexoversized.meta"
  printf 'rendered after the previous poll' > "$capture_file"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'the previous render')" > "$state/.hash-$key"
  printf '0\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown missing)'
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" FM_TURNEND_CHURN_ABSORB_SECS=999999999999999999999999999999999999 \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a turn-end with an oversized churn bound"
  grep -F "signal: $state/codexoversized.turn-ended" "$out" >/dev/null \
    || fail "watcher terminated before printing the oversized-bound turn-end"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the oversized churn bound failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/codexoversized.turn-ended" >/dev/null \
    || fail "turn-end with an oversized churn bound was not queued"
  [ ! -e "$state/.churn-since-$key" ] \
    || fail "an oversized churn bound opened a deferral window"
  unset FM_FAKE_CREW_STATE
  pass "an oversized pane-churn bound surfaces the turn-end"
}

test_turn_ended_invalid_churn_deadline_surfaced() {
  local variant value dir state fakebin out drain_out capture_file window key marker pid
  for variant in empty leading-zero nonnumeric future overflow; do
    dir=$(make_case "turn-ended-invalid-churn-deadline-$variant")
    state="$dir/state"; fakebin="$dir/fakebin"
    out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
    window=$(stream_window "$state" codexdeadline)
    : > "$state/codexdeadline.turn-ended"
    printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$window" > "$state/codexdeadline.meta"
    printf 'rendered after the previous poll' > "$capture_file"
    key=$(printf '%s' "$window" | tr ':/.' '___')
    marker="$state/.churn-since-$key"
    printf '%s' "$(hash_text 'the previous render')" > "$state/.hash-$key"
    printf '0\n' > "$state/.count-$key"
    case "$variant" in
      empty)        value='' ;;
      leading-zero) value=09 ;;
      nonnumeric)   value=bogus ;;
      future)       value=$(( $(date +%s) + 600 )) ;;
      overflow)     value=999999999999999999999999999999999999 ;;
    esac
    printf '%s' "$value" > "$marker"
    export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown missing)'
    stream_capture "$window" "$capture_file"
    PATH="$fakebin:$PATH" \
      FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>/dev/null &
    pid=$!
    wait_for_exit "$pid" 100 || fail "watcher did not surface a turn-end with a $variant churn deadline"
    grep -F "signal: $state/codexdeadline.turn-ended" "$out" >/dev/null \
      || fail "watcher terminated before printing the $variant-deadline turn-end"
    FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
      || fail "drain after the $variant churn deadline failed"
    grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/codexdeadline.turn-ended" >/dev/null \
      || fail "turn-end with a $variant churn deadline was not queued"
    [ "$(cat "$marker")" = "$value" ] \
      || fail "the $variant churn deadline was rewritten"
  done
  unset FM_FAKE_CREW_STATE
  pass "invalid existing pane-churn deadlines surface without mutation"
}

test_turn_ended_surfaced_batch_opens_no_partial_deadline() {
  local dir state fakebin out drain_out capture_file first_window second_window first_key second_key pid
  dir=$(make_case turn-ended-no-partial-churn-deadline); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  first_window=$(stream_window "$state" codexfirst); second_window=$(stream_window "$state" codexsecond)
  : > "$state/first.turn-ended"
  : > "$state/second.turn-ended"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$first_window" > "$state/first.meta"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$second_window" > "$state/second.meta"
  printf 'rendered after the previous poll' > "$capture_file"
  first_key=$(printf '%s' "$first_window" | tr ':/.' '___')
  second_key=$(printf '%s' "$second_window" | tr ':/.' '___')
  printf '%s' "$(hash_text 'first previous render')" > "$state/.hash-$first_key"
  printf '%s' "$(hash_text 'second previous render')" > "$state/.hash-$second_key"
  printf '0\n' > "$state/.count-$first_key"
  printf '0\n' > "$state/.count-$second_key"
  printf 'bogus' > "$state/.churn-since-$second_key"
  export FM_FAKE_CREW_STATE='state: unknown · source: pane · harness state unavailable (unknown missing)'
  stream_capture "$first_window" "$capture_file"
  stream_capture "$second_window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_CONFIG_OVERRIDE="$(churn_config "$dir")" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=3 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher absorbed a batch containing an invalid churn deadline"
  grep -F "$state/first.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the first turn-end from the surfaced batch"
  grep -F "$state/second.turn-ended" "$out" >/dev/null \
    || fail "watcher did not print the second turn-end from the surfaced batch"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null \
    || fail "drain after the surfaced churn batch failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/first.turn-ended" >/dev/null \
    || fail "the first turn-end from the surfaced batch was not queued"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/second.turn-ended" >/dev/null \
    || fail "the second turn-end from the surfaced batch was not queued"
  [ ! -e "$state/.churn-since-$first_key" ] \
    || fail "a surfaced batch opened a partial churn deadline"
  [ "$(cat "$state/.churn-since-$second_key")" = bogus ] \
    || fail "the invalid churn deadline in a surfaced batch was rewritten"
  unset FM_FAKE_CREW_STATE
  pass "a surfaced batch opens no partial pane-churn deadline"
}

test_working_note_not_working_surfaced() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case working-note-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # A non-no-mistakes crew (no run) whose pane went idle: fm-crew-state falls back
  # to the stale working: status-log line. That is NOT positive evidence, so the
  # wake must surface - these users must never be left hanging.
  export FM_FAKE_CREW_STATE='state: working · source: status-log · working: compiling step 2'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a working: note whose crew has no running pipeline and an idle pane"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the surfaced working: signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced working: note failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "surfaced working: note was not queued"
  [ -s "$state/.seen-task_status" ] || fail "surfaced working: note did not advance its .seen-* suppressor"
  pass "a no-verb working: note whose crew is idle with no running pipeline is surfaced"
}

test_secondmate_status_note_surfaced_despite_busy_agent() {
  local dir state fakebin out drain_out pid
  dir=$(make_case secondmate-note-surfaced); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  printf 'kind=secondmate\n' > "$state/mate.meta"
  printf 'working: routed reply landed in the parent stream\n' > "$state/mate.status"
  # Busy evidence that would absorb an ordinary crewmate's no-verb note must
  # not absorb a secondmate's: its status stream is the routed-reply channel.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · running'
  FM_CONFIG_OVERRIDE="$(churn_config "$dir")" watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher absorbed a busy secondmate's routed status note"
  grep -F "signal: $state/mate.status" "$out" >/dev/null \
    || fail "watcher did not print the surfaced secondmate note"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the surfaced note failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$state/mate.status" >/dev/null \
    || fail "surfaced secondmate note was not queued"
  pass "a secondmate's status note surfaces even while its own agent is busy"
}

test_self_announced_close_does_not_rewake_but_next_note_does() {
  local dir state fakebin out status_file pid rc
  dir=$(make_case self-close-quiet); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'needs-decision [key=k1]: pick one\n' > "$status_file"
  prime_status_seen "$state" "$status_file" || fail "could not prime the announced baseline"
  # The home's own bookkeeping close, written through the guarded
  # self-announced append this home's answerers use.
  rc=0
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_wake_status_append_self_announced "$2" "$3" "resolved [key=k1]: answered: closed by this home"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state" "$status_file" || rc=$?
  [ "$rc" -eq 0 ] || fail "the bookkeeping close was not self-announced (rc=$rc)"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · idle worker'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "the home's own bookkeeping close re-woke its own watcher: $(cat "$out")"
  fi
  [ ! -s "$out" ] || { reap "$pid"; fail "self-announced close printed a wake reason: $(cat "$out")"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "self-announced close enqueued a durable wake"; }
  # A later, different note on the SAME task still wakes: dedup is keyed on the
  # exact announced bytes, never on task identity.
  printf 'needs-decision [key=k2]: a genuinely new decision\n' >> "$status_file"
  wait_for_exit "$pid" 100 || fail "a later different note after a self-announced close was swallowed"
  grep -F "signal: $status_file" "$out" >/dev/null \
    || fail "the later note did not surface as a signal"
  pass "a self-announced close never wakes its own home, and the next real note still does"
}

# --- actionable wakes are surfaced (queue + exit) ---------------------------

test_actionable_signal_surfaced() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case actionable-signal); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: setup\nneeds-decision: pick A or B\n' > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not exit for an actionable needs-decision signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the actionable signal reason"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the actionable signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "actionable signal was not queued"
  [ -s "$state/.hb-surfaced-task" ] || fail "actionable signal did not record the surfaced marker"
  pass "captain-relevant signal is surfaced (queue + exit) and marked surfaced"
}

# A needs-decision status append surfaced through this actionable signal path
# is marked decision-owned in its row payload. The row still queues as an
# ordinary signal-kind wake; the away daemon tells it apart from a routine
# signal by this payload marker, not by kind.
test_needs_decision_signal_payload_marked_for_branch_exclusion() {
  local dir state fakebin out status_file pid
  dir=$(make_case needs-decision-payload); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: setup\nneeds-decision: pick A or B\n' > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not exit for an actionable needs-decision signal"
  grep -F "$(printf 'signal\ttask.status\tneeds-decision:')" "$state/.wake-queue" >/dev/null \
    || fail "a needs-decision signal row was not payload-marked for branch exclusion: $(cat "$state/.wake-queue")"
  pass "a needs-decision signal row's queued payload is marked needs-decision: for branch exclusion"
}

# A needs-decision whose key transition was rejected by the reserved-key
# vocabulary is reported as a "reconciliation-required: " wrapped event
# (fm-classify-lib.sh's status_span_first_actionable_record), but it is still a
# needs-decision signal that this path routes directly to main - the payload
# marker must not be fooled by that wrapper.
test_needs_decision_reconciliation_required_still_marked() {
  local dir state fakebin out status_file pid
  dir=$(make_case needs-decision-reconciliation); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'needs-decision [key=pending-reply-x]: unrelated request\nworking: awaiting reconciliation\n' \
    > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not exit for a rejected-reserved-key needs-decision"
  grep -F "$(printf 'signal\ttask.status\tneeds-decision:')" "$state/.wake-queue" >/dev/null \
    || fail "a reconciliation-required needs-decision row was not payload-marked for branch exclusion: $(cat "$state/.wake-queue")"
  pass "a reconciliation-required needs-decision row's queued payload is still marked needs-decision:"
}

# A captain-held declaration is itself actionable. Positive evidence that the
# crew is still working must not absorb the signal before its main-only marker
# can be delivered.
test_captain_held_signal_payload_marked_for_branch_exclusion() {
  local dir state fakebin out status_file pid
  dir=$(make_case captain-held-signal-payload); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'captain-held [key=route]: awaiting the captain\n' > "$status_file"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · still wrapping up'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher absorbed a captain-held signal while the crew was still working"
  grep -F "signal: $status_file" "$out" >/dev/null \
    || fail "a captain-held signal changed its wake reason: $(cat "$out")"
  grep -F "$(printf 'signal\ttask.status\tneeds-decision:')" "$state/.wake-queue" >/dev/null \
    || fail "a captain-held signal was not payload-marked for branch exclusion: $(cat "$state/.wake-queue")"
  pass "a captain-held signal stays actionable while the crew is still working"
}

test_pending_reply_escalation_signal_payload_marked_for_branch_exclusion() {
  local dir state fakebin out status_file pid corr
  dir=$(make_case pending-reply-escalation-payload); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  status_file="$state/task.status"
  corr=0123456789abcdef
  printf 'blocked [key=pending-reply-%s]: pending-reply-missed: task=task pending-reply-id=%s request=finish report\n' \
    "$corr" "$corr" > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not exit for a pending-reply escalation"
  grep -F "$(printf 'signal\ttask.status\tneeds-decision:')" "$state/.wake-queue" >/dev/null \
    || fail "a pending-reply escalation was not payload-marked for branch exclusion: $(cat "$state/.wake-queue")"
  pass "a pending-reply second-mate escalation is marked for main-only routing"
}

test_ordinary_blocked_signal_payload_remains_branch_eligible() {
  local dir state fakebin out status_file pid
  dir=$(make_case ordinary-blocked-payload); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'blocked [key=dependency]: waiting for an upstream release\n' > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not exit for an ordinary blocked event"
  grep -F "$(printf 'signal\ttask.status\tsignal:')" "$state/.wake-queue" >/dev/null \
    || fail "an ordinary blocked event lost its ordinary signal payload: $(cat "$state/.wake-queue")"
  if grep -F "$(printf 'signal\ttask.status\tneeds-decision:')" "$state/.wake-queue" >/dev/null; then
    fail "an ordinary blocked event was marked as a second-mate escalation"
  fi
  pass "an ordinary blocked event keeps the ordinary signal payload"
}

# A routine (non-needs-decision) captain-relevant event must keep its ordinary
# payload: only a genuine needs-decision gets the exclusion marker.
test_routine_signal_payload_not_marked_needs_decision() {
  local dir state fakebin out status_file pid
  dir=$(make_case routine-signal-payload); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: setup\ndone: migration complete ; needs-decision: documented in follow-up\n' > "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not exit for an actionable done signal"
  grep -F "$(printf 'signal\ttask.status\tneeds-decision:')" "$state/.wake-queue" >/dev/null \
    && fail "a routine done signal was incorrectly payload-marked needs-decision: $(cat "$state/.wake-queue")"
  grep -F "$(printf 'signal\ttask.status\tsignal:')" "$state/.wake-queue" >/dev/null \
    || fail "a routine signal lost its ordinary payload: $(cat "$state/.wake-queue")"
  pass "a routine event containing a needs-decision phrase keeps its ordinary payload, unmarked"
}

# The reported bug, end to end through a real watcher: a crew reports something
# the captain must act on and then keeps appending routine progress, which is
# ordinary while the watcher lingers its signal grace window to coalesce a status
# write with the same turn's turn-end. Classifying only the last line reads the
# batch as routine, and because the crew IS provably working the no-verb fallback
# absorbs it too - the .seen-* suppressor then advances and nothing ever re-reads
# the event, so the work stalls with the captain never told.
test_actionable_signal_survives_a_later_routine_append() {
  local dir state fakebin out drain_out status_file sig pid
  dir=$(make_case actionable-masked); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  # Everything through "working: setup" was already classified, so this asserts
  # the newly appended span, not merely a whole-file re-read.
  printf 'working: setup\n' > "$status_file"
  sig=$(seen_sig "$status_file"); printf '%s' "$sig" > "$state/.seen-task_status"
  printf 'needs-decision: pick A or B\nworking: still tidying the branch\n' >> "$status_file"
  # Positive evidence the crew is still working, so the no-verb fallback cannot
  # rescue the wake: only reading the event itself can surface it.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "watcher absorbed a needs-decision hidden behind a later working: line"; }
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print the actionable signal reason"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the masked signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "the masked actionable signal was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a captain event hidden behind a later routine append is still surfaced (queue + exit)"
}

# The captain-reported completion shape of the same masking, end to end.
test_release_completion_survives_a_later_routine_append() {
  local dir state fakebin out drain_out status_file sig pid
  dir=$(make_case release-masked); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: publishing\n' > "$status_file"
  sig=$(seen_sig "$status_file"); printf '%s' "$sig" > "$state/.seen-task_status"
  printf 'done: release 1.4.0 published and installed\nworking: cleaning the build dir\n' >> "$status_file"
  export FM_FAKE_CREW_STATE='state: working · source: pane · harness busy'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 \
    || { reap "$pid"; fail "watcher absorbed a release/install completion hidden behind later cleanup chatter"; }
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the masked completion failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "the masked completion was not queued"
  unset FM_FAKE_CREW_STATE
  pass "a finished release reported before routine cleanup chatter is still surfaced"
}

# The other direction: the fix must not turn ordinary progress into wakes.
test_routine_appends_after_a_classified_event_stay_absorbed() {
  local dir state fakebin out status_file sig pid
  dir=$(make_case actionable-classified); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  status_file="$state/task.status"
  # The decision is BEHIND the classified position, so only the new routine line
  # is in the span. A supervisor that re-read the whole log would wake again here.
  printf 'working: setup\nneeds-decision: pick A or B\n' > "$status_file"
  sig=$(seen_sig "$status_file"); printf '%s' "$sig" > "$state/.seen-task_status"
  printf 'working: still tidying the branch\n' >> "$status_file"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher re-surfaced a decision it had already classified: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || fail "a routine append after a classified decision enqueued a wake"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a routine append after an already-classified event is absorbed (no re-wake)"
}

test_unreadable_status_reports_once_per_file_state() {
  local dir state fakebin out status_file target marker sig pid
  dir=$(make_case unreadable-status); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; status_file="$state/task.status"; target="$dir/missing-status-target"
  ln -s "$target" "$status_file"
  marker="$state/.seen-task_status"

  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a dangling status symlink was not reported"; }
  grep -Fx "signal: $status_file" "$out" >/dev/null \
    || fail "a dangling status symlink did not use the immediate signal path: $(cat "$out")"
  sig=$(status_observed_signature "$status_file")
  status_presentation_marker_reported_matches "$marker" "$sig" \
    || fail "the unreadable status report did not advance its wake signature"
  [ "$(status_presentation_marker_offset "$marker" "$status_file")" = 0 ] \
    || fail "the unreadable status report advanced its classification position"
  ack_stopped_cycle "$state" || fail "could not acknowledge the first unreadable-status wake"
  touch "$state/.last-check" "$state/.last-heartbeat"

  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_poll_cycle "$state" "$pid" \
    || { reap "$pid"; fail "an unchanged unreadable status reported again after restart: $(cat "$out")"; }
  reap "$pid"

  printf 'blocked: changed target state with a longer path\n' > "$dir/status-target-two-longer"
  ln -snf "$dir/status-target-two-longer" "$status_file"
  target="$dir/status-target-two-longer"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a changed unreadable status did not report again"; }
  [ "$(status_presentation_marker_offset "$marker" "$status_file")" = 0 ] \
    || fail "a changed unreadable status advanced its classification position"
  ack_stopped_cycle "$state" || fail "could not acknowledge the changed unreadable-status wake"

  rm -f "$status_file"
  cp "$target" "$status_file"
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a readable replacement did not surface preserved content"; }
  [ "$(status_presentation_marker_offset "$marker" "$status_file")" = "$(size_of "$status_file")" ] \
    || fail "readable recovery did not classify content written before the failure"
  pass "unreadable status reports are bounded without advancing classification"
}

test_permission_recovery_surfaces_preserved_status() {
  local dir state fakebin out status_file marker before_ident after_ident pid
  dir=$(make_case permission-recovery); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; status_file="$state/task.status"; marker="$state/.seen-task_status"
  printf 'blocked: release approval required\nworking: preserving context\n' > "$status_file"
  before_ident=$(_fm_open_decisions_file_ident "$status_file")
  chmod 000 "$status_file"
  if [ -r "$status_file" ]; then
    chmod 600 "$status_file"
    pass "permission recovery skipped because permissions cannot deny reads"
    return
  fi

  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; chmod 600 "$status_file"; fail "an unreadable regular status was not reported"; }
  [ "$(status_presentation_marker_offset "$marker" "$status_file")" = 0 ] \
    || { chmod 600 "$status_file"; fail "an unreadable regular status advanced its classification position"; }
  ack_stopped_cycle "$state" || { chmod 600 "$status_file"; fail "could not acknowledge the unreadable regular-status wake"; }
  touch "$state/.last-check" "$state/.last-heartbeat"

  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_poll_cycle "$state" "$pid" \
    || { reap "$pid"; chmod 600 "$status_file"; fail "an unchanged unreadable regular status reported again"; }

  chmod 600 "$status_file"
  after_ident=$(_fm_open_decisions_file_ident "$status_file")
  [ "$after_ident" = "$before_ident" ] || { reap "$pid"; fail "the permission-only recovery changed file identity"; }
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "readability recovery did not surface preserved content"; }
  grep -Fx "signal: $status_file" "$out" >/dev/null \
    || fail "readability recovery did not use the actionable signal path: $(cat "$out")"
  [ "$(status_presentation_marker_offset "$marker" "$status_file")" = "$(size_of "$status_file")" ] \
    || fail "readability recovery did not classify from the unadvanced position"
  pass "permission recovery surfaces content from the unadvanced position"
}

test_status_span_actionable_classifier
test_status_span_survives_a_later_routine_append
test_status_span_respects_decision_closure
test_malformed_seen_signature_reads_the_whole_log
test_stale_is_terminal_classifier
test_classifier_primitives
test_crew_is_provably_working_classifier
test_status_is_paused_classifier
test_crew_absorb_class_classifier
test_crew_worktree_written_since_classifier
test_empty_write_prune_widens_the_probe
test_empty_write_prune_from_the_environment_widens_the_probe
test_worktree_write_probe_is_wall_clock_bounded
test_signal_crew_provably_working_classifier
test_secondmate_status_signal_never_absorbed_classifier
test_provably_working_signal_absorbed
test_turn_ended_provably_working_absorbed
test_turn_ended_not_working_surfaced
test_turn_ended_churning_pane_absorbed
test_turn_ended_churn_resets_prior_stale_classification
test_turn_ended_churn_resets_wedge_state_before_stale_poll
test_turn_ended_still_pane_surfaced
test_turn_ended_malformed_prior_hash_surfaced
test_turn_ended_trailing_newline_prior_hash_surfaced
test_secondmate_turn_ended_churning_pane_surfaced
test_turn_ended_colliding_window_key_surfaced
test_turn_ended_duplicate_endpoint_records_surfaced
test_turn_ended_mixed_positive_evidence_batch_absorbed
test_turn_ended_mixed_positive_evidence_batch_default_off
test_status_and_turn_end_batch_never_uses_churn_evidence
test_turn_ended_churn_absorb_off_by_default
test_turn_ended_churn_absorb_bounded
test_turn_ended_churn_timer_write_failure_surfaced
test_turn_ended_invalid_churn_bound_surfaced
test_turn_ended_oversized_churn_bound_surfaced
test_turn_ended_invalid_churn_deadline_surfaced
test_turn_ended_surfaced_batch_opens_no_partial_deadline
test_working_note_not_working_surfaced
test_secondmate_status_note_surfaced_despite_busy_agent
test_self_announced_close_does_not_rewake_but_next_note_does
test_actionable_signal_surfaced
test_needs_decision_signal_payload_marked_for_branch_exclusion
test_needs_decision_reconciliation_required_still_marked
test_captain_held_signal_payload_marked_for_branch_exclusion
test_pending_reply_escalation_signal_payload_marked_for_branch_exclusion
test_ordinary_blocked_signal_payload_remains_branch_eligible
test_routine_signal_payload_not_marked_needs_decision
test_actionable_signal_survives_a_later_routine_append
test_release_completion_survives_a_later_routine_append
test_routine_appends_after_a_classified_event_stay_absorbed
test_unreadable_status_reports_once_per_file_state
test_permission_recovery_surfaces_preserved_status
