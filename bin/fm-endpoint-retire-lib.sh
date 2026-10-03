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

fm_endpoint_retire() {  # <home> <state-dir> <id>
  local home=$1 state=$2 id=$3 meta kind backend target last control out lock tmp line
  local control_lock control_lock_owner tab_id expected_label
  meta="$state/$id.meta"
  [ -f "$meta" ] || { echo "skipped: no task record"; return 0; }
  lock=$(fm_meta_lock_path "$meta") || { echo "failed: task record lock unavailable"; return 1; }
  control_lock="$state/.control-$id.lock"
  fm_lock_acquire_wait "$control_lock" || { echo "failed: lifecycle lock unavailable"; return 1; }
  control_lock_owner=$(cat "$control_lock/pid" 2>/dev/null || true)
  if [ -z "$control_lock_owner" ]; then
    fm_lock_release "$control_lock"
    echo "failed: lifecycle lock owner unavailable"
    return 1
  fi
  fm_lock_acquire_wait "$lock" || {
    fm_lock_release "$control_lock"
    echo "failed: task record lock unavailable"
    return 1
  }
  kind=$(fm_meta_get "$meta" kind)
  if [ -n "$kind" ] && [ "$kind" != ship ]; then
    fm_lock_release "$lock"
    fm_lock_release "$control_lock"
    echo "skipped: a $kind keeps its endpoint"
    return 0
  fi
  if [ -n "$(fm_meta_get "$meta" endpoint_retired)" ]; then
    fm_lock_release "$lock"
    fm_lock_release "$control_lock"
    echo "already-retired"
    return 0
  fi
  backend=$(fm_backend_of_meta "$meta")
  if ! fm_backend_list_contains "$FM_BACKEND_SPAWN" "$backend"; then
    fm_lock_release "$lock"
    fm_lock_release "$control_lock"
    echo "skipped: backend $backend cannot reclaim a retired endpoint"
    return 0
  fi
  target=$(fm_backend_target_of_meta "$meta")
  if [ -z "$target" ]; then
    fm_lock_release "$lock"
    fm_lock_release "$control_lock"
    echo "skipped: no endpoint recorded"
    return 0
  fi
  last=$(last_status_line "$state/$id.status")
  if [ "$(status_line_verb "$last")" != done ]; then
    fm_lock_release "$lock"
    fm_lock_release "$control_lock"
    echo "skipped: the worker's latest status is not done"
    return 0
  fi

  control=${FM_ENDPOINT_RETIRE_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_CONTROL_LOCK_HELD=1 FM_CONTROL_LOCK_OWNER="$control_lock_owner" \
    "$control" "$id" exit 2>&1) || {
      fm_lock_release "$lock"
      fm_lock_release "$control_lock"
      echo "skipped: the worker did not exit cleanly: $(printf '%s' "$out" | tail -1)"
      return 0
    }

  tab_id=$(fm_meta_get "$meta" zellij_tab_id)
  expected_label="fm-$id"
  fm_backend_kill "$backend" "$target" "$tab_id" "$expected_label" >/dev/null 2>&1 || {
    fm_lock_release "$lock"
    fm_lock_release "$control_lock"
    echo "failed: endpoint $target is not confirmed gone after its close"
    return 1
  }
  case "$backend" in
    tmux) ;;
    herdr) fm_backend_herdr_endpoint_confirmed_gone "$target" || {
      fm_lock_release "$lock"
      fm_lock_release "$control_lock"
      echo "failed: endpoint $target is not confirmed gone after its close"
      return 1
    } ;;
    zellij) fm_backend_zellij_endpoint_confirmed_gone "$target" || {
      fm_lock_release "$lock"
      fm_lock_release "$control_lock"
      echo "failed: endpoint $target is not confirmed gone after its close"
      return 1
    } ;;
    orca) fm_backend_orca_endpoint_confirmed_gone "$target" || {
      fm_lock_release "$lock"
      fm_lock_release "$control_lock"
      echo "failed: endpoint $target is not confirmed gone after its close"
      return 1
    } ;;
    cmux) fm_backend_cmux_endpoint_confirmed_gone "$target" || {
      fm_lock_release "$lock"
      fm_lock_release "$control_lock"
      echo "failed: endpoint $target is not confirmed gone after its close"
      return 1
    } ;;
  esac

  tmp=$(mktemp "$state/.fm-retire-meta.XXXXXX") || {
    fm_lock_release "$lock"
    fm_lock_release "$control_lock"
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
    fm_lock_release "$control_lock"
    echo "failed: task record could not be rewritten"
    return 1
  fi
  fm_lock_release "$lock"
  fm_lock_release "$control_lock"
  echo "retired: worker exited and endpoint $target closed; only the merge poll waits"
}
