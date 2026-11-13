# Targeted validation

Eight suites completed successfully: fm-nm-guard, fm-test-fixtures, fm-timeout-lib, fm-arm-pretool-check, fm-cd-pretool-check, fm-claude-trust, fm-remote-secondmate-omp, fm-remote-secondmate-parent-binding.

fm-test-run reached the 300-second per-script bound (child exit 124, runner exit 1); classified untested, not an assertion failure, and not rerun. Its earlier executable probe explicitly passed: `runner preserves inherited guard shims for test children`.

Sixteen restored suites were not started because minute 12 had elapsed: fm-wake-drain-outcome-backstop, fm-pr-check-security, fm-inactive-reconcile, fm-watch-arm, fm-bootstrap-network-parallel, fm-backlog-atomicity, fm-backlog-handoff, fm-remote-backlog-handoff, fm-fleet-sync, fm-control-relaunch, fm-remote-herdr-guard, fm-remote-job, fm-secondmate-sync, fm-on, fm-branch-supervision, fm-x-mode.

fm-lint and fm-lint-workflows were deliberately not run because this phase forbids lint/static analysis. The arm and cd suites incidentally invoke their own lint subchecks; these were not separately requested or rerun.

Phase 2 was not started: phase 1 ended at minute 13, beyond its start cutoff. In particular, the real bootstrap canary under an emitted worker environment was not independently rerun. Guard regression did execute real git through a fixture wrapper under that emitted environment and proved explicit guard rebinding still refuses replacement input with exit 3.

Initial --list --changed attempt refused an unmapped transient timer file. That file was immediately removed and --list --changed succeeded. No source changes were made. Final git status was clean. Process inspection found no remaining processes matching the suites or the parent-binding fixture. Parent-binding's successful suite emitted cleanup `Directory not empty` warnings in its retained log.

Detailed command results are in results; each executed suite has a .log and .json timing record. No upstream equivalence pass is claimed for the two user-approved unchanged exceptions, and no complete-suite comparison was performed.
