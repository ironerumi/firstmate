# no-mistakes respond enforcement machinery

This fork does not build enforcement machinery around `no-mistakes axi respond` text composition — no respond-wrapping helper, no guard funnel refusing raw `--instructions`/`--add-finding`, no rerun finding-diff checker — while the current prose mitigation holds.

## Why this is out of scope

Two hazards motivated the request (issue #20): backticked spans in inline `--instructions` text being command-substituted away by the crewmate's shell, and error-severity findings silently vanishing when a non-deterministic review reruns on the same head.

The backtick hazard already has a landed mitigation: `AGENTS.md` requires all `--instructions`/`--add-finding` text to be passed as `"$(cat <file>)"` from a written file (merged 2026-08-14, after the single measured incident, which predates it), and the same rule ships in the no-mistakes skill text crews load. Each hazard has exactly one measured occurrence, and the vanished-finding case was caught by the operator.

Building the mechanism anyway was rejected because:

- **The guard cannot detect the corruption.** The validation-owner guard is a PATH shim (`bin/shims/no-mistakes` → `fm-nm-guard-shim.sh`), deliberately harness-agnostic so one mechanism covers every harness without per-harness hooks. A shim sees argv *after* shell evaluation, when corrupted inline text and clean file-mediated text are indistinguishable. The only enforceable shim rule is a blunt funnel — refuse *all* direct `--instructions` usage and require a helper (helper bypasses via an env marker before exec'ing the real binary). That is feasible without any per-harness hook wiring, but it would contradict and churn the just-landed `"$(cat <file>)"` rule, and it punishes the compliant form to catch a hazard observed once.
- **Per-harness composition-time hooks** (Claude Code PreToolUse + a Pi extension + one per remaining harness) would detect the raw text before evaluation, but break the repo's one-mechanism-covers-all-harnesses guard design for marginal gain.
- **The rerun finding-diff checker** couples the fork to the private schema of `~/.no-mistakes/state.sqlite` (`runs.head_sha`, `step_results.findings_json` — both confirmed present today) for a failure observed once. If it recurs, the next occurrence should inform the design (standalone read-only checker vs respond-wrapper) rather than guessing now.

## Reconsider when

Either tripwire fires:

- Backtick/inline corruption of respond text recurs *despite* the landed `"$(cat <file>)"` rule — prose has then demonstrably failed and the shim-funnel design above is the pre-derived next step.
- A finding vanishes on a same-head rerun again — build the rerun diff, choosing its shape from how the recurrence actually presented.

## Prior requests

- #20 — "fm-nm-respond helper: file-based gate text, rerun finding diff, guard funnel"
