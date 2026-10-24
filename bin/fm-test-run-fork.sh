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
    fm-merge-local.test.sh|fm-pr-merge-admin.test.sh|fm-endpoint-retire.test.sh)
      printf '%s\n' pr-forge
      ;;
    fm-wake-autoack.test.sh)
      printf '%s\n' watcher-wake-lock
      ;;
    *)
      return 1
      ;;
  esac
}

# Provisional weights: twice one local macOS `bin/fm-test-run.sh` run of each
# file, until fork CI timing artifacts measure them on Ubuntu. Without them each
# file packs at the 45000 ms default and overfills the serial shards. A reader
# that stops at its first match closes the pipe early, so cat stays quiet.
fm_fork_serial_weight_hints() {
  cat 2>/dev/null <<'HINTS'
tests/fm-brief-repo-guard.test.sh 14000
tests/fm-classify-decision-key-extra.test.sh 1200
tests/fm-endpoint-retire.test.sh 51700
tests/fm-merge-local.test.sh 12400
tests/fm-nm-guard.test.sh 57600
tests/fm-pr-merge-admin.test.sh 38500
tests/fm-spawn-claude-attribution.test.sh 25800
tests/fm-wake-autoack.test.sh 28200
tests/fm-worker-role-inert.test.sh 6100
HINTS
}
