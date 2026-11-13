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
    fm-spawn-claude-attribution.test.sh|fm-worker-slot-safety.test.sh|fm-worker-pool-safety.test.sh)
      printf '%s\n' backend-dispatch
      ;;
    fm-pr-merge-admin.test.sh)
      printf '%s\n' pr-forge
      ;;
    fm-worker-role-extensions.test.sh|fm-procevent-identity.test.sh)
      printf '%s\n' standalone
      ;;
    fm-doorbell-recovery.test.sh|fm-wake-autoack.test.sh|fm-directory-lock-interleavings.test.sh|\
    fm-directory-lock-recovery.test.sh|fm-directory-lock-node.test.sh|fm-directory-lock-wake-queue.test.sh)
      printf '%s\n' watcher-wake-lock
      ;;
    *)
      return 1
      ;;
  esac
}

# Provisional local macOS weights until fork CI measures them on Ubuntu.
# Brief-guard, nm-guard, merge-admin, directory-lock, doorbell and process-event
# identity hints use the slowest of at least three clean runs plus 10%, rounded
# up to 100 ms.
# Other hints retain their initial local measurements (twice one run for older
# suites). Without hints each file packs at the 45000 ms default and overfills
# the serial shards. A reader that stops at its first match closes the pipe
# early, so cat stays quiet.
fm_fork_serial_weight_hints() {
  cat 2>/dev/null <<'HINTS'
tests/fm-brief-repo-guard.test.sh 5100
tests/fm-classify-decision-key-extra.test.sh 1200
tests/fm-nm-guard.test.sh 38800
tests/fm-pr-merge-admin.test.sh 24100
tests/fm-spawn-claude-attribution.test.sh 25800
tests/fm-wake-autoack.test.sh 28200
tests/fm-worker-role-inert.test.sh 6100
tests/fm-worker-role-extensions.test.sh 578
tests/fm-worker-pool-safety.test.sh 28070
tests/fm-worker-slot-safety.test.sh 10453
tests/fm-session-lock-windows-consumers.test.sh 6299
tests/fm-directory-lock-interleavings.test.sh 23800
tests/fm-directory-lock-recovery.test.sh 27400
tests/fm-directory-lock-node.test.sh 8800
tests/fm-directory-lock-wake-queue.test.sh 10900
tests/fm-procevent-identity.test.sh 34900
tests/fm-doorbell-recovery.test.sh 15200
HINTS
}
