#!/usr/bin/env bash
# fm-worker-env-lib.sh - the single owner of the environment bin/fm-spawn.sh puts
# in a fleet worker's pane for the git hooks and the guard shims.
#
# bin/fm-spawn.sh sends what these functions print, and tests/fm-nm-guard.test.sh
# evals the same output rather than a hand-built copy that could drift from it.
#
# Public interface (each prints one shell `export` statement on stdout):
#   fm_worker_hooks_export_line <hooks-dir>
#       Points git at the spawn-installed core.hooksPath for this launch.
#   fm_worker_guard_export_line <state-dir> <task-id> <firstmate-bin-dir>
#       Puts the guard shims first on PATH and binds them to this task's status
#       file and durable record.

fm_worker_env_quote() { # <value>
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

fm_worker_hooks_export_line() { # <hooks-dir>
  printf 'export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=%s' \
    "$(fm_worker_env_quote "$1")"
}

fm_worker_guard_export_line() { # <state-dir> <task-id> <firstmate-bin-dir>
  # shellcheck disable=SC2016 # $PATH must reach the pane unexpanded.
  printf 'export FM_NM_GUARD_STATUS=%s PATH=%s:$PATH' \
    "$(fm_worker_env_quote "$1/$2.status")" \
    "$(fm_worker_env_quote "$3/shims")"
}
