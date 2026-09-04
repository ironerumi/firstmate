#!/usr/bin/env bash
# fm-task-adhoc-lib.sh - the metadata-only cleanup contract for a direct
# primary-session ship (kind=adhoc).
#
# Usage: . bin/fm-task-adhoc-lib.sh (from bin/fm-teardown.sh)
#
# Why this exists. A direct primary-session ship registered by
# bin/fm-task-register.sh has no worker endpoint and no isolated worktree: the
# primary session itself does the work in the firstmate home, so teardown must
# remove only volatile task records and never kill an endpoint, remove a
# worktree, refresh a clone, or emit a backlog reminder. The register script
# owns the metadata shape; this library owns reading that shape safely at
# cleanup time.
#
# The contract. An adhoc record deliberately records empty window, worktree,
# and tasktmp values, so fm_backend_validate_task_endpoint can never pass for
# it. validate_adhoc_task_record is the equivalent metadata-only authorization:
# it admits only exactly what bin/fm-task-register.sh writes, so a drifted or
# forged kind=adhoc record cannot skip endpoint validation and still reach the
# branch deletion and worktree return that teardown performs.
# bin/fm-teardown.sh dispatches on fm_task_adhoc_is_record at its first
# cleanup authorization gate and consults validate_adhoc_task_record before
# that gate can pass; the remaining kind=adhoc exclusions in teardown are the
# no-endpoint, no-worktree, no-clone consequences of the same shape.
#
# Nothing here writes. Every refusal preserves the task's durable records.
set -u

# 0 when the recorded kind is exactly adhoc: the shape bin/fm-task-register.sh
# creates. Anything else - a missing, empty, or ambiguous kind - is a normal
# task and takes the standard endpoint-validation path.
fm_task_adhoc_is_record() {  # <meta-file>
  local kind
  kind=$(fm_backend_meta_exact_value "$1" kind 2>/dev/null) || kind=
  [ "$kind" = adhoc ]
}

# The metadata-only authorization for the adhoc shape. It admits only exactly
# what bin/fm-task-register.sh writes: a regular (never a symlink) metadata
# file, a valid task id, harness=adhoc, a well-formed project identity, and
# empty window, worktree, and tasktmp values. A drifted or forged kind=adhoc
# record that fails any of these is refused with the task's durable state
# preserved, so it can never skip endpoint validation and still reach the
# branch deletion and worktree return that teardown performs.
validate_adhoc_task_record() {  # <meta-file> <task-id>
  local meta=$1 id=$2 harness project key
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    echo "REFUSED: task $id has no regular endpoint metadata at $meta; preserving task state." >&2
    return 1
  }
  case "$id" in ''|*[!A-Za-z0-9._-]*)
    echo "REFUSED: task endpoint identity has an invalid task id; preserving task state." >&2
    return 1
    ;;
  esac
  harness=$(fm_backend_meta_exact_value "$meta" harness) || harness=
  [ "$harness" = adhoc ] || {
    echo "REFUSED: task $id has a missing, ambiguous, or non-ad-hoc harness identity; preserving task state." >&2
    return 1
  }
  project=$(fm_backend_meta_exact_value "$meta" project) || {
    echo "REFUSED: task $id has a missing, empty, or ambiguous project identity; preserving task state." >&2
    return 1
  }
  case "$project" in *$'\r'*|*$'\t'*)
    echo "REFUSED: task $id has malformed endpoint metadata; preserving task state." >&2
    return 1
    ;;
  esac
  for key in window worktree tasktmp; do
    if grep -q "^$key=." "$meta" 2>/dev/null; then
      echo "REFUSED: ad-hoc task $id records a non-empty $key it must not own; preserving task state." >&2
      return 1
    fi
  done
}