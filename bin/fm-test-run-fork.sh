# shellcheck shell=bash
# fm-test-run-fork.sh - fork-owned test classification and balance hints.
#
# Usage: sourced by bin/fm-test-run.sh when present. It owns the family mapping
# and the serial-weight hints for the fork's own test files, so the tracked
# runner keeps one hook for them instead of a growing list of fork entries.
#
# fm_fork_family_for_basename <basename>: print the family for a fork test file,
# or return 1 when the name is not one this fork owns.
# fm_fork_serial_weight_hints: print extra `<path> <milliseconds>` hint lines.

fm_fork_family_for_basename() {  # <basename>
  case "$1" in
    fm-brief-repo-guard.test.sh|fm-nm-guard.test.sh|fm-worktree-guard.test.sh|fm-classify-decision-key-extra.test.sh)
      printf '%s\n' pure-contract-unit
      ;;
    fm-spawn-claude-attribution.test.sh)
      printf '%s\n' backend-dispatch
      ;;
    fm-merge-local.test.sh|fm-pr-merge-admin.test.sh|fm-task-register.test.sh)
      printf '%s\n' pr-forge
      ;;
    fm-claude-keepwarm-selfwake.test.sh)
      printf '%s\n' standalone
      ;;
    *)
      return 1
      ;;
  esac
}

fm_fork_serial_weight_hints() {
  printf '%s\n' 'tests/fm-claude-keepwarm-selfwake.test.sh 18000'
}
