# Phase 1 — targeted suite run (keep-warm removal / upstream revert)

Branch fm/keepwarm-to-plugin, base 372914a → target 17d23e2.
Command: `bin/fm-test-run.sh --jobs 1 --per-script-timeout-secs 300 <suites>`

Narrowed set = changed test scripts in the diff + existing `tests/<name>.test.sh`
for changed `bin/<name>.sh`. Deleted suite (fm-claude-keepwarm-selfwake.test.sh)
cannot run. fm-teardown (long, 4–18m) was deferred to last and not started
because minute 12 was reached (no new suite after minute 12). fm-procevent
deferred (known to stop at its setsid-dependent test on macOS; CI covers).

## Outcome
| suite | result | duration | note |
|---|---|---|---|
| tests/fm-operational-input.test.sh | PASS | 9.7s | keep-warm kind removed from FM_OPERATIONAL_KINDS |
| tests/fm-turnend-guard.test.sh | PASS | 91.8s | tracked Stop entries 8→7 grok-inert |
| tests/fm-spawn-claude-attribution.test.sh | PASS | 13.1s | no keep-warm Stop hook / cadence injection |
| tests/fm-worker-role-inert.test.sh | PASS | 4.1s | keep-warm stand-down removed; Pi turn-end worker-inert test restored & passing |
| tests/fm-pr-check-security.test.sh | TIME BOUND | 300.2s (exit 124) | hit per-script bound, terminated; CI covers |
| tests/fm-test-run.test.sh | TIME BOUND | 300.2s (exit 124) | hit per-script bound, terminated; CI covers |

FM_TEST_SUMMARY total=6 failed=2 skipped_gate=0. Both "failures" are exit=124
per-script-timeout terminations, not assertion failures — reported untested
(time bound) per the runbook.

No assertion failure was observed in any suite.
