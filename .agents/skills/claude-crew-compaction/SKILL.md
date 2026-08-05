---
name: claude-crew-compaction
description: >-
  Agent-only SOP for proactively compacting a Claude crewmate or secondmate before its context runs out, because Claude auto-compaction is disabled in this environment.
  Use when a live Claude worker's displayed remaining context reads below 50%, and for the mandatory post-compaction resume nudge and verification that follow.
user-invocable: false
metadata:
  internal: true
---

# claude-crew-compaction

This skill is the single owner of the below-50% proactive-compaction trigger, its safe timing, and the handoff/compact/resume sequence for a Claude crewmate or secondmate.
`AGENTS.md` section 8's Claude context stub keeps only the trigger condition and the two non-negotiable facts inline; this skill owns the rest.
Scope is `harness=claude` workers only, crewmate or secondmate alike; never send these commands to a worker on another harness.

## Why this exists

Claude auto-compaction is disabled in this environment, so nothing else keeps a Claude worker's context from running out.
A low reading is therefore never harmless and is never dismissed as ordinary auto-compact, unlike non-Claude harnesses, which auto-compact on their own (`stuck-crewmate-recovery`).
Claude also does not auto-resume after `/compact`: the conversation goes quiet until firstmate explicitly nudges it, so a successful `/compact` response alone is not completion.

## Reading remaining context

No verified harness fact exposes a grep-able "context: N%" string for Claude the way `bin/fm-spawn.sh`'s Kimi delivery check does.
Read the bounded observable signal instead: peek the pane and read Claude's own displayed remaining-context indicator.
Treat that reading, not a guess or an elapsed-turns heuristic, as the below-50% trigger.
If a future verified deterministic reader is wired for this, record it here and in `harness-adapters` rather than duplicating the fact.

## Safe timing

Never start this sequence mid-stage.
Wait for the worker's current bounded stage or tool action to finish - its busy-state contract (`bin/fm-busy-lib.sh`) going idle is the concrete signal - before sending anything.
Never compact during an active no-mistakes action, an active gate response, a commit, a push, or another ownership-sensitive transition; those are governed by `AGENTS.md`'s Validate section and must not be interrupted.
If the worker is mid one of these when the low reading is first observed, hold the trigger open and re-check at the next safe boundary rather than dropping it.

## Sequence

1. At a safe boundary, send `/handoff plan-doc`.
2. Capture the plan-doc path the worker reports back.
3. Send `/compact`.
4. Send `/handoff resume <plan-doc-path>` using the exact path captured in step 2.
   This step is mandatory, not optional: Claude does not automatically resume after compaction, so skipping it leaves the worker silently idle.
5. Verify the same task is actively running again: peek the pane or read its busy-state, and confirm the worker resumed the same task identity rather than sitting idle or starting something else.
   A `/compact` response alone, or a `/handoff resume` send that reports success, is not proof of resumption - confirm the postcondition the same way other submission-acknowledgement hazards are confirmed in `harness-adapters`.

Treat steps 1-5 as one atomic supervision action: do not consider the low-context trigger resolved, and do not report the worker as supervised again, until step 5 has confirmed resumption.

## Not stuck-worker recovery

A low context reading is not wedging, and this SOP is not `stuck-crewmate-recovery`.
Do not exit or relaunch a Claude worker solely for a low context reading; use this sequence in place of that escalation.
If the worker is also genuinely wedged (looping, unresponsive, repeating the same obstacle) independent of context, use `stuck-crewmate-recovery` instead.
