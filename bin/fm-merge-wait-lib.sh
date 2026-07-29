#!/usr/bin/env bash
# fm-merge-wait-lib.sh - which green PRs are waiting on the captain with nothing
# durable recording that wait.
#
# When a PR is ready and firstmate holds standing merge authority it merges and
# the wait never exists. When the merge instead goes to the captain, the wait is
# real work: it is the largest single block of calendar latency the fleet spends,
# and it lives only in chat unless something durable records it. The durable
# owner already exists - a captain-kind hold on the work item itself
# (`tasks-axi hold <id> --reason "<why>" --kind captain`, AGENTS.md section 10) -
# so this library adds no new record, no polling, and no timing instrumentation.
# It answers one question from state firstmate already writes:
#
#   which tasks have reported a PR, need the captain to merge it, and carry no
#   captain hold saying so?
#
# The readiness signal is the worker's own `done:` line naming a PR, which is
# already durable and already the thing firstmate acts on. Nothing here polls a
# forge, measures how long a PR has been green, or writes a timestamp.
#
# Every uncertainty degrades to "nothing to report": a task with no backlog item
# is skipped rather than reported, because a hold cannot be placed on an item
# that does not exist, and an unusable tasks-axi reports nothing at all. This
# predicate feeds a turn-end block, so a false positive would be far more costly
# than a missed one.

# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-tasks-axi-lib.sh"

fm_merge_wait_meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

fm_merge_wait_show_field() {  # <show-output> <field>
  printf '%s\n' "$1" | sed -n "s/^  $2: //p" | head -1
}

# 0 when the task's own status log reports a PR as ready for a merge decision.
# That is the `done:` line the delivery contract already requires - `done: PR
# <url> checks green` on the pipeline path, `done: PR <url>` on the direct-PR
# path - and it is read as an event, never as current state: a later line that
# reopens the task moves the last line off `done:` and the wait stops counting.
fm_merge_wait_reported_ready() {  # <status-file>
  local status_file=$1 last
  [ -f "$status_file" ] || return 1
  last=$(grep -v '^[[:space:]]*$' "$status_file" 2>/dev/null | tail -1)
  case "$last" in
    done:*PR*) return 0 ;;
    *) return 1 ;;
  esac
}

# 0 when a captain-kind hold already records this task's wait.
fm_merge_wait_recorded() {  # <home> <task-id>
  local home=$1 id=$2 show held hold_kind state
  show=$( (cd "$home" && tasks-axi show "$id" --full) 2>/dev/null) || return 0
  state=$(fm_merge_wait_show_field "$show" state)
  # A task already closed out is not waiting on anything.
  [ "$state" != "done" ] || return 0
  held=$(fm_merge_wait_show_field "$show" held)
  hold_kind=$(fm_merge_wait_show_field "$show" hold_kind)
  [ "$held" = yes ] && [ "$hold_kind" = captain ]
}

# 0 when the task exists as a backlog item this home can hold.
fm_merge_wait_item_exists() {  # <home> <task-id>
  (cd "$1" && tasks-axi show "$2" --full) >/dev/null 2>&1
}

# Task ids whose green PR is waiting on the captain with no durable record of
# that wait, one per line. Empty output means nothing to do.
fm_merge_wait_unrecorded() {  # <state-dir> <home>
  local state_dir=$1 home=$2 meta id backlog_checked=0
  [ -d "$state_dir" ] || return 0
  for meta in "$state_dir"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    [ -n "$(fm_merge_wait_meta_value "$meta" pr)" ] || continue
    # yolo on means firstmate merges under standing authority, so no captain
    # wait exists to record; the escalation this predicate is about is the
    # captain-authority case.
    [ "$(fm_merge_wait_meta_value "$meta" yolo)" != on ] || continue
    case "$(fm_merge_wait_meta_value "$meta" kind)" in
      secondmate) continue ;;
    esac
    fm_merge_wait_reported_ready "$state_dir/$id.status" || continue
    # The backlog probe is several subprocesses, and this predicate runs on the
    # turn-end path, so pay for it only once a candidate actually exists.
    if [ "$backlog_checked" -eq 0 ]; then
      fm_tasks_axi_compatible >/dev/null 2>&1 || return 0
      backlog_checked=1
    fi
    fm_merge_wait_item_exists "$home" "$id" || continue
    fm_merge_wait_recorded "$home" "$id" && continue
    printf '%s\n' "$id"
  done
}

# The one reason string that marks a captain hold as THIS kind of wait. It is a
# single owner rather than a phrase repeated at each surface because landing the
# PR clears a hold that carries it, and must never clear one that does not: a
# captain-reserved post-merge release or operational step is recorded the same
# way and survives the merge, which is what lets a safe merged-but-unreleased
# state land while the reserved step stays a durable captain decision.
FM_MERGE_WAIT_REASON='green PR waiting on the captain to merge'

# The exact command that records one wait, so every surface names the same one.
fm_merge_wait_record_command() {  # <task-id>
  printf 'tasks-axi hold %s --reason "%s" --kind captain' "$1" "$FM_MERGE_WAIT_REASON"
}

# 0 when the task's active captain hold is a merge wait rather than some other
# captain-reserved step. Anything unreadable answers no, so an unrelated hold is
# never cleared by mistake.
fm_merge_wait_hold_is_merge_wait() {  # <home> <task-id>
  local show reason kind
  show=$( (cd "$1" && tasks-axi show "$2" --full) 2>/dev/null) || return 1
  kind=$(fm_merge_wait_show_field "$show" hold_kind)
  [ "$kind" = captain ] || return 1
  reason=$(fm_merge_wait_show_field "$show" hold_reason)
  reason=${reason#\"}
  reason=${reason%\"}
  [ "$reason" = "$FM_MERGE_WAIT_REASON" ]
}
