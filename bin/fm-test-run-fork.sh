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
    fm-brief-repo-guard.test.sh|fm-nm-guard.test.sh|fm-classify-decision-key-extra.test.sh)
      printf '%s\n' pure-contract-unit
      ;;
    fm-spawn-claude-attribution.test.sh)
      printf '%s\n' backend-dispatch
      ;;
    fm-merge-local.test.sh|fm-pr-merge-admin.test.sh|fm-task-register.test.sh|fm-endpoint-retire.test.sh)
      printf '%s\n' pr-forge
      ;;
    fm-wake-autoack.test.sh|fm-task-inbox-ladder.test.sh)
      printf '%s\n' watcher-wake-lock
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
  # A caller that has found its hint stops reading, and with SIGPIPE ignored the
  # builtin reports the closed pipe on every such lookup. The reader already has
  # what it wanted, so the write error carries no information.
  printf '%s\n' 'tests/fm-claude-keepwarm-selfwake.test.sh 18000' 2>/dev/null || true
}
