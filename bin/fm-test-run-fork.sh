# shellcheck shell=bash
# fm-test-run-fork.sh - fork-owned test classification and balance hints.
#
# Usage: sourced by bin/fm-test-run.sh when present. It owns the family mapping
# and the serial-weight hints for the fork's own test files, so the tracked
# runner keeps one hook for them instead of a growing list of fork entries.
# Each table holds one line per fork suite, added by the fork commit that adds
# the suite, so dropping that commit drops its lines.
#
# fm_fork_family_for_basename <basename>: print the family for a fork test file,
# or return 1 when the name is not one this fork owns.
# fm_fork_serial_weight_hints: print extra `<path> <milliseconds>` hint lines.

fm_fork_family_for_basename() {  # <basename>
  case "$1" in
    fm-fork-runner-local.test.sh) printf '%s\n' pure-contract-unit ;;
    fm-nm-guard.test.sh) printf '%s\n' pure-contract-unit ;;
    *)
      return 1
      ;;
  esac
}

# Fork suite weights are local macOS measurements until fork CI measures them
# on Ubuntu; newer entries use the slowest of at least three clean runs plus
# 10%, rounded up to 100 ms. Without hints each file packs at the 45000 ms
# default and overfills the serial shards. A reader that stops at its first
# match closes the pipe early, so cat stays quiet.
fm_fork_serial_weight_hints() {
  cat 2>/dev/null <<'HINTS'
tests/fm-fork-runner-local.test.sh 3100
tests/fm-nm-guard.test.sh 38800
HINTS
# Upstream suites upstream has not hinted yet, measured as the slowest successful,
# non-gate-skipped duration_ms in green upstream Ubuntu CI runs 43209319634,
# 43331691300 and 43359484992. They keep the serial shards inside budget once
# the fork suites above add their load; drop a line when upstream hints it.
  cat 2>/dev/null <<'HINTS'
tests/fm-assertions.test.sh 127
tests/fm-fleet-snapshot-contribution-input.test.sh 219
tests/fm-git-push-guard.test.sh 1316
tests/fm-hc-lab.test.sh 776
tests/fm-home-summary-refresh.test.sh 55389
tests/fm-parent-channel-scan-exclusion.test.sh 4468
tests/fm-pipeline-spend.test.sh 3015
tests/fm-project-mode.test.sh 678
tests/fm-record-export-remote-home.test.sh 3914
tests/fm-remote-inherit-generation.test.sh 4874
tests/fm-remote-job-claim-reap.test.sh 3716
tests/fm-remote-job-claim-retention.test.sh 147
tests/fm-review-check.test.sh 1957
tests/fm-send-kiro-confirm.test.sh 1382
HINTS
}
