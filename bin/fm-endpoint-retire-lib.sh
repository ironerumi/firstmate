#!/usr/bin/env bash
# Retire a done-but-unmerged ship's worker endpoint, so only its armed merge poll
# waits. A merge can wait unboundedly on the captain or an upstream review, and a
# quiet worker pane that long is a standing source of stale wakes with nothing to
# act on; the worker has finished, so the pane carries nothing.
#
# Sourced by bin/fm-pr-check.sh and called once, after the merge poll is armed:
# arming is the trigger because it is the one moment firstmate has accepted the
# worker's ready report for a named head AND a durable poll exists to carry the
# wait, so retiring any earlier could leave nothing waiting on the PR.
#
# fm_endpoint_retire <home> <state-dir> <id> prints exactly one line and returns
# 0 for every outcome that leaves the task in a coherent state:
#   retired: ...        the agent exited through `bin/fm-control.sh <id> exit`, the
#                       endpoint was closed and confirmed gone, and the task record
#                       now carries endpoint_retired=<epoch>
#   already-retired     the record already carries that marker
#   skipped: <why>      nothing was touched: not a ship, the worker's latest
#                       status is not `done`, the endpoint changed, or the exit
#                       was refused
# It returns 1 only for `failed: ...`, where the close could not be confirmed and
# no marker was written; the endpoint may still exist, so no record claims it gone.
#
# Only the endpoint goes. The worktree, branch, brief, status log, steering inbox,
# armed poll, and every other task record stay untouched. A relaunch drops the
# marker with the rest of the endpoint identity it rewrites
# (preserve_relaunch_meta in bin/fm-spawn.sh).
#
# FM_ENDPOINT_RETIRE_CONTROL_BIN lets tests stand in for the control plane.

# shellcheck source=bin/fm-backend.sh
. "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-backend.sh"
. "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-control-lib.sh"

fm_endpoint_retire() {  # <home> <state-dir> <id>
  local home=$1 state=$2 id=$3 meta kind backend target last control out lock tmp line
  local tab_id expected_label snapshot original_backend original_target original_spawn_gen spawn_gen
  meta="$state/$id.meta"
  [ -f "$meta" ] || { echo "skipped: no task record"; return 0; }
  snapshot=$(awk -F= '
    {
      value=substr($0, index($0, "=") + 1)
      if ($1 == "backend") backend=value
      else if ($1 == "window") window=value
      else if ($1 == "terminal") terminal=value
      else if ($1 == "spawn_gen") spawn_gen=value
    }
    END {
      if (backend == "") backend="tmux"
      target=(backend == "orca" ? terminal : window)
      printf "%s\t%s\t%s\n", backend, target, spawn_gen
    }
  ' "$meta" 2>/dev/null) || { echo "failed: task record identity unavailable"; return 1; }
  IFS=$'\t' read -r original_backend original_target original_spawn_gen <<< "$snapshot"
  if [ -z "$original_backend" ] || [ -z "$original_target" ] || [ -z "$original_spawn_gen" ]; then
    echo "skipped: task record endpoint identity is incomplete"
    return 0
  fi
  lock=$(fm_meta_lock_path "$meta") || { echo "failed: task record lock unavailable"; return 1; }
  fm_lock_acquire_wait "$lock" || {
    echo "failed: task record lock unavailable"
    return 1
  }
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  spawn_gen=$(fm_meta_get "$meta" spawn_gen)
  if [ "$backend" != "$original_backend" ] || [ "$target" != "$original_target" ] || [ "$spawn_gen" != "$original_spawn_gen" ]; then
    fm_lock_release "$lock"
    echo "skipped: endpoint changed while waiting for its lifecycle lock"
    return 0
  fi
  kind=$(fm_meta_get "$meta" kind)
  if [ -n "$kind" ] && [ "$kind" != ship ]; then
    fm_lock_release "$lock"
    echo "skipped: a $kind keeps its endpoint"
    return 0
  fi
  if [ -n "$(fm_meta_get "$meta" endpoint_retired)" ]; then
    fm_lock_release "$lock"
    echo "already-retired"
    return 0
  fi
  if ! fm_control_backend_state_verified "$backend"; then
    fm_lock_release "$lock"
    echo "skipped: backend $backend is not recovery-grade"
    return 0
  fi
  if [ -z "$target" ]; then
    fm_lock_release "$lock"
    echo "skipped: no endpoint recorded"
    return 0
  fi
  last=$(last_status_line "$state/$id.status")
  if [ "$(status_line_verb "$last")" != "done" ]; then
    fm_lock_release "$lock"
    echo "skipped: the worker's latest status is not done"
    return 0
  fi

  fm_lock_release "$lock"
  control=${FM_ENDPOINT_RETIRE_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    "$control" "$id" exit 2>&1) || {
      echo "skipped: the worker did not exit cleanly: $(printf '%s' "$out" | tail -1)"
      return 0
    }
  fm_lock_acquire_wait "$lock" || {
    echo "failed: task record lock unavailable after the worker exited"
    return 1
  }
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  spawn_gen=$(fm_meta_get "$meta" spawn_gen)
  if [ "$backend" != "$original_backend" ] || [ "$target" != "$original_target" ] || [ "$spawn_gen" != "$original_spawn_gen" ]; then
    fm_lock_release "$lock"
    echo "skipped: endpoint changed after the worker exited"
    return 0
  fi

  tab_id=$(fm_meta_get "$meta" zellij_tab_id)
  expected_label="fm-$id"
  fm_backend_kill "$backend" "$target" "$tab_id" "$expected_label" >/dev/null 2>&1 || {
    fm_lock_release "$lock"
    echo "failed: endpoint $target is not confirmed gone after its close"
    return 1
  }
  if [ "$backend" = herdr ] && ! fm_backend_herdr_endpoint_confirmed_gone "$target"; then
    fm_lock_release "$lock"
    echo "failed: endpoint $target is not confirmed gone after its close"
    return 1
  fi

  tmp=$(mktemp "$state/.fm-retire-meta.XXXXXX") || {
    fm_lock_release "$lock"
    echo "failed: task record could not be rewritten"
    return 1
  }
  {
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in endpoint_retired=*) ;; *) printf '%s\n' "$line" ;; esac
    done < "$meta"
    printf 'endpoint_retired=%s\n' "$(date +%s)"
  } > "$tmp"
  if ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$meta"; then
    rm -f -- "$tmp"
    fm_lock_release "$lock"
    echo "failed: task record could not be rewritten"
    return 1
  fi
  fm_lock_release "$lock"
  echo "retired: worker exited and endpoint $target closed; only the merge poll waits"
}
