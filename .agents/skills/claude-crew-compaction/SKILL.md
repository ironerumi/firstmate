---
name: claude-crew-compaction
description: >-
  Agent-only SOP for proactively compacting a Claude crewmate before its context runs out, because Claude auto-compaction is disabled in this environment.
  Use when a live Claude crewmate's displayed remaining context reads below 50%, and for the mandatory post-compaction resume nudge and verification that follow.
user-invocable: false
metadata:
  internal: true
---

# claude-crew-compaction

This skill is the single owner of the below-50% proactive-compaction trigger, its safe timing, and the handoff/compact/resume sequence for a Claude crewmate.
`AGENTS.md` section 8's Claude context stub keeps only the trigger condition and the non-negotiable safety facts inline; this skill owns the rest.
Scope is ordinary `harness=claude` crewmates and direct workers this home owns; never send these commands to a worker on another harness.
This SOP does not apply to a secondmate endpoint: a secondmate is a firstmate in its own home whose continuity is its home state, backlog, and armed supervision cycle, and whose recovery is owned by `secondmate-provisioning`.
A secondmate home applies this SOP independently to its own ordinary Claude workers.

## Why this exists

Claude auto-compaction is disabled in this environment, so nothing else keeps a Claude worker's context from running out.
A low reading is therefore never harmless and is never dismissed as ordinary auto-compact, unlike non-Claude harnesses, which auto-compact on their own (`stuck-crewmate-recovery`).
Claude also does not auto-resume after `/compact`: the conversation goes quiet until firstmate explicitly nudges it, so a successful `/compact` response alone is not completion.

## Reading remaining context

No verified harness fact exposes a grep-able "context: N%" string for Claude the way `bin/fm-spawn.sh`'s Kimi delivery check does.
Read the bounded observable signal instead: peek the pane and read Claude's own displayed remaining-context indicator.
Treat that reading, not a guess or an elapsed-turns heuristic, as the below-50% trigger.
If a future verified deterministic reader is wired for this, record it here and in `harness-adapters` rather than duplicating the fact.

## Away-mode limitation

The check runs only in model-owned supervision, on the `heartbeat:` wake step of `AGENTS.md` section 8.
While away mode is active the daemon owns supervision and self-handles heartbeat wakes with zero firstmate context, so it cannot read a pane's remaining-context indicator; this coverage gap is a known limitation, not something this skill closes.
Do not expand the daemon for it.
When model-owned supervision resumes - after the away-mode return owner's catch-up gate clears - inspect every live Claude worker's remaining context promptly, before dispatching new work to any of them.

## Safe timing

Never start this sequence mid-stage.
Wait for the worker's current bounded stage or tool action to finish - its busy-state contract (`bin/fm-busy-lib.sh`) going idle is the concrete signal - before sending anything.
Never compact during an active no-mistakes action, an active gate response, a commit, a push, or another ownership-sensitive transition; those are governed by `AGENTS.md`'s Validate section and must not be interrupted.
If the worker is mid one of these when the low reading is first observed, hold the trigger open and re-check at the next safe boundary rather than dropping it.

## Sequence

Send every command in this sequence with `FM_HOME=<this-firstmate-home> bin/fm-send.sh <window> '<command>'` from an active firstmate session, unless `FM_HOME` is already set to the active firstmate home; sending from the wrong home is a real failure mode.

Never send these back-to-back.
Before each send, the worker's previous command must have completed and its prompt must be ready: peek the pane and confirm the composer is empty and idle, exactly as `harness-adapters`' submission-acknowledgement hazards require.

1. At a safe boundary, send bare `/handoff`.
   A bare invocation is what auto-detects the active plan document; a non-keyword first argument would be read as a target filepath and write a new file instead.
2. Wait for that turn to finish, then capture the absolute plan-document path the command reports back.
3. With the prompt ready again, send `/compact`.
4. Wait until compaction has settled and the prompt is ready, then send `/handoff resume <absolute-plan-document-path>` using the exact path captured in step 2.
   This step is mandatory, not optional: Claude does not automatically resume after compaction, so skipping it leaves the worker silently idle.
5. Verify the worker actually continued the same work: peek the pane and confirm it is progressing the same task identity and the same bounded stage that was open before compaction, cross-checked against current reconciled worker state from `bin/fm-crew-state.sh`.
   That evidence is authoritative on its own.
   A `/compact` response alone, a `/handoff resume` send that reports success, or a busy-state reading is not proof of resumption.
   Busy state is corroboration only here: the Claude busy-state contract is hook-bracketed (`UserPromptSubmit` opens a turn, `Stop`, `StopFailure`, and `SessionEnd` close it), and whether a built-in `/compact` brackets a turn symmetrically is not live-verified the way the other claude facts in `harness-adapters` are, so it can read running while the worker sits idle.
   If it is ever live-verified, record it in `harness-adapters` and treat it as evidence here.

Treat steps 1-5 as one atomic supervision action: do not consider the low-context trigger resolved, and do not report the worker as supervised again, until step 5 has confirmed resumption.

## Not stuck-worker recovery

A low context reading is not wedging, and this SOP is not `stuck-crewmate-recovery`.
Do not exit or relaunch a Claude worker solely for a low context reading; use this sequence in place of that escalation.
If the worker is also genuinely wedged (looping, unresponsive, repeating the same obstacle) independent of context, use `stuck-crewmate-recovery` instead.
