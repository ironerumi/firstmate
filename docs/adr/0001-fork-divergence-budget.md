# Fork divergence is budgeted on upstream-owned hot files; fork-added surfaces are free

This repo is a fork of `kunchenguid/firstmate` that merges upstream continuously (measured 2026-08-16: 35 ahead / 9 behind, merge-base one day old). Merge pain comes exclusively from overlapping edits to upstream-owned files — and churn is extreme where it matters: `AGENTS.md` saw 188 upstream commits in 60 days, `bin/fm-brief.sh` 35 (22 of them in its Definition-of-done heredoc region alone). New files never conflict.

**Decision**: divergence is budgeted per upstream-owned file, weighted by its upstream churn; fork-added files and directories are free. Fork behavior therefore ships preferentially as fork-added surfaces (new `bin/` scripts, fork-added `.agents/skills/`, wrapper scripts that call upstream tooling unchanged) rather than as edits to hot upstream files. Prose additions to `AGENTS.md` are the most expensive change in the repo and are rationed accordingly.

Two corollaries:

- **Crew-facing contracts must be emission-based, not recall-based.** A contract that must reach a crewmate's brief is appended deterministically by a fork-added wrapper around the upstream scaffolder — never left as prose an agent must remember to paste, and never patched into the upstream scaffolder's own heredocs (see churn numbers above).
- **Upstream-seed universal improvements, but never wait on them.** Changes with nothing fork-specific may additionally be filed as upstream PRs so the fork copy can be deleted if merged. Upstream is currently unresponsive to this fork's asks (PRs/issues open since 2026-07 without response), so seeding is a bet, not a delivery path.

**Considered and rejected**: patching hot upstream files directly (recurring conflicts on every merge); carrying crew-facing contracts in `data/captain.md`/`learnings.md` (zero divergence but recall-based and home-local — right surface for captain preferences and per-home deviations, wrong for gate contracts and shared SOPs, which the repo's own architecture assigns to tracked files).
