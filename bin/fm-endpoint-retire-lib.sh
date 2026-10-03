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
#   skipped: <why>      nothing was touched: not a ship, not on herdr, the worker's
#                       latest status is not `done`, or the exit was refused
# It returns 1 only for `failed: ...`, where the close could not be confirmed and
# no marker was written; the endpoint may still exist, so no record claims it gone.
#
# Herdr only, because a retired endpoint must stay reclaimable: when the PR needs
# more work, `bin/fm-control.sh <id> relaunch` rebinds the task to a fresh endpoint
# in its recorded worktree, and only herdr can prove an endpoint absent
# (fm_control_endpoint_absence_verdict owns that argument). Every other backend
# keeps its endpoint exactly as before.
#
# Only the endpoint goes. The worktree, branch, brief, status log, steering inbox,
# armed poll, and every other task record stay untouched, and bin/fm-teardown.sh
# after landing already accepts a pane that is gone (its herdr presence gate passes
# on a confirmed-absent pane). A relaunch drops the marker with the rest of the
# endpoint identity it rewrites (preserve_relaunch_meta in bin/fm-spawn.sh).
#
# FM_ENDPOINT_RETIRE_CONTROL_BIN lets tests stand in for the control plane.

# shellcheck source=bin/fm-backend.sh
. "$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)/fm-backend.sh"

fm_endpoint_retire() {  # <home> <state-dir> <id>
  local home=$1 state=$2 id=$3 meta kind backend target last control out lock tmp line
  meta="$state/$id.meta"
  [ -f "$meta" ] || { echo "skipped: no task record"; return 0; }
  kind=$(fm_meta_get "$meta" kind)
  [ -z "$kind" ] || [ "$kind" = ship ] || { echo "skipped: a $kind keeps its endpoint"; return 0; }
  [ -z "$(fm_meta_get "$meta" endpoint_retired)" ] || { echo "already-retired"; return 0; }
  backend=$(fm_backend_of_meta "$meta")
  [ "$backend" = herdr ] || { echo "skipped: backend $backend cannot reclaim a retired endpoint"; return 0; }
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || { echo "skipped: no endpoint recorded"; return 0; }
  last=$(last_status_line "$state/$id.status")
  [ "$(status_line_verb "$last")" = "done" ] \
    || { echo "skipped: the worker's latest status is not done"; return 0; }

  control=${FM_ENDPOINT_RETIRE_CONTROL_BIN:-$SCRIPT_DIR/fm-control.sh}
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$state" "$control" "$id" exit 2>&1) \
    || { echo "skipped: the worker did not exit cleanly: $(printf '%s' "$out" | tail -1)"; return 0; }

  fm_backend_source herdr || { echo "failed: herdr adapter could not be loaded"; return 1; }
  fm_backend_kill herdr "$target" >/dev/null 2>&1 || true
  fm_backend_herdr_endpoint_confirmed_gone "$target" \
    || { echo "failed: endpoint $target is not confirmed gone after its close"; return 1; }

  lock=$(fm_meta_lock_path "$meta") || { echo "failed: task record lock unavailable"; return 1; }
  fm_lock_acquire_wait "$lock" || { echo "failed: task record lock unavailable"; return 1; }
  tmp=$(mktemp "$state/.fm-retire-meta.XXXXXX") || { fm_lock_release "$lock"; echo "failed: task record could not be rewritten"; return 1; }
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
