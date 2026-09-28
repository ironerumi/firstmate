#!/usr/bin/env bash
# Register a direct Firstmate-repo ship executed by the primary session so the
# ordinary PR recording, guarded merge, and cleanup paths have a task identity.
# This is for ad-hoc implementation sessions only; crew work remains registered
# by bin/fm-spawn.sh, whose metadata write is deliberately unchanged.
#
# The registered meta has no worker endpoint or isolated worktree. kind=adhoc is
# the cleanup contract: bin/fm-teardown.sh removes only this task's volatile
# records and never kills an endpoint, removes a worktree, or refreshes a clone.
# Registration is explicit and create-only. It shares fm-spawn.sh's per-task
# creation lock and refuses to overwrite any existing metadata.
#
# Usage: fm-task-register.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"

usage() {
  echo "usage: fm-task-register.sh <task-id>" >&2
}

if [ "$#" -ne 1 ]; then
  usage
  exit 2
fi
ID=$1
fm_task_id_creation_valid "$ID" || {
  echo "error: invalid task id" >&2
  exit 2
}
fm_refuse_if_gate_agent

[ -d "$FM_ROOT" ] || {
  echo "error: firstmate code root is unavailable" >&2
  exit 1
}
[ -d "$FM_HOME" ] && [ ! -L "$FM_HOME" ] || {
  echo "error: firstmate home is unavailable" >&2
  exit 1
}
mkdir -p "$STATE"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || {
  echo "error: task state directory is unavailable" >&2
  exit 1
}

PROJECT=$(cd "$FM_ROOT" && pwd -P)
HOME_PATH=$(cd "$FM_HOME" && pwd -P)
read -r MODE YOLO <<EOF
$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-project-mode.sh" "$(basename "$PROJECT")")
EOF

TASK_SET_LOCK=$(fm_task_set_lock_path "$STATE") || {
  echo "error: could not resolve the task-set lock for $STATE" >&2
  exit 1
}
if ! fm_lock_try_acquire "$TASK_SET_LOCK"; then
  echo "error: this home's task set is locked by another operation; refusing to register task $ID" >&2
  exit 1
fi
TASK_SET_LOCK_HELD=1
LOCK="$STATE/.spawn-$ID.lock"
if ! fm_lock_try_acquire "$LOCK"; then
  fm_lock_release "$TASK_SET_LOCK" || true
  TASK_SET_LOCK_HELD=0
  echo "error: another task registration or spawn is already creating task $ID" >&2
  exit 1
fi
TMP=
cleanup() {
  [ -z "$TMP" ] || rm -f -- "$TMP"
  fm_lock_release "$LOCK" || true
  if [ "${TASK_SET_LOCK_HELD:-0}" = 1 ]; then
    TASK_SET_LOCK_HELD=0
    fm_lock_release "$TASK_SET_LOCK" || true
  fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

META="$STATE/$ID.meta"
if [ -e "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata already exists" >&2
  exit 1
fi
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-impl-concurrency-guard.sh" "$STATE" "$PROJECT" "$ID"

old_umask=$(umask)
umask 077
TMP=$(mktemp "$STATE/.fm-task-register.XXXXXX")
umask "$old_umask"
{
  echo "window="
  echo "worktree="
  echo "project=$PROJECT"
  echo "harness=adhoc"
  echo "kind=adhoc"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
  echo "tasktmp="
  echo "model=default"
  echo "effort=default"
  echo "home=$HOME_PATH"
} > "$TMP"
chmod 0600 "$TMP"

# A hard-link publication is atomic and refuses an existing destination. The
# temporary name is then removed so fm-pr-check.sh sees the required link count
# of exactly one before it records the PR.
if ! ln "$TMP" "$META"; then
  echo "error: task metadata already exists" >&2
  exit 1
fi
rm -f -- "$TMP"
TMP=
printf 'registered: state/%s.meta\n' "$ID"
