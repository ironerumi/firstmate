# Firstmate Fork Maintenance

Vocabulary for maintaining this repo as a long-lived fork of `kunchenguid/firstmate` with continuous upstream merges. Fleet/domain terminology (crewmate, captain, secondmate, ...) is owned by `AGENTS.md`; this glossary covers only the fork-maintenance context.

## Language

**Divergence budget**:
The merge-conflict cost a fork-side change adds to future upstream merges. Spent only by edits to upstream-owned files; measured by that file's upstream churn.
_Avoid_: fork delta (total line count — new files inflate it without costing anything)

**Hot file**:
An upstream-owned file with high upstream churn, where any fork edit becomes a recurring conflict surface.

**Fork-added surface**:
A file or directory that exists only in the fork. Git auto-merges around it, so changes here spend no divergence budget.

**Emission-based instruction**:
A contract that a script deterministically writes into the artifact it governs (e.g. a scaffolder appending a Definition-of-done block). Reaches its audience without anyone remembering it.

**Recall-based instruction**:
A contract recorded as prose that an agent must remember to apply (rules files, captain preferences, skill text). The channel that fails silently under pressure.
_Avoid_: "documented" as a synonym for "enforced"

**Upstream seed**:
Filing a fork-side improvement as an upstream PR so the fork can drop its copy if upstream merges. A bet on upstream responsiveness, not a delivery path.
