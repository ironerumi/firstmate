#!/usr/bin/env bash
# Refuse a second implementation task for one repository in the same firstmate
# home, so at most ONE implementation task can be in flight per repository at a time.
#
# Why this is mechanical rather than a prose cap: GitHub's merge queue is not
# available on this fleet's plan (Team private repositories), so two open PRs on
# one repository cannot be ordered.
# The second PR goes behind the moment the first merges and re-runs CI for
# nothing, which is pure wasted compute; one at a time per repository removes
# that collision by construction instead of asking an agent to remember a cap.
#
# Usage: fm-impl-concurrency-guard.sh <state-dir> <project-dir> <task-id>
#   Exit 0 - the repository is free for this implementation task.
#   Exit 1 - refused; stderr names the task(s) already in flight.
#   Exit 2 - usage or argument error.
#
# The callers are bin/fm-spawn.sh's pre-flight pass for every fresh ship spawn,
# bin/fm-promote.sh for scout promotion, and bin/fm-task-register.sh for direct
# Firstmate-repo ships, so this script owns the whole trigger rule.
#
# "In flight" is the presence of another ship or adhoc task record for the same
# project in <state-dir>: bin/fm-teardown.sh removes that record only after
# landing is confirmed, so the record covers an agent still implementing, a
# validation run still working, an open PR held for merge, and a finished agent
# whose PR has not landed yet. A record carrying no kind= is read as ship, the
# same default bin/fm-spawn.sh applies to a legacy record. kind=adhoc is a direct
# Firstmate implementation record without a worker endpoint, so it counts as a
# ship; kind=scout (read-only, no PR) and kind=secondmate (not an implementation
# task) are the only exemptions, and a project's own other repositories never
# block each other.
# <task-id> is excluded from the scan, so the same task re-checking itself (a
# relaunch) is never its own blocker.
# Repository identity is shared by separate clones of one origin; physical paths
# still distinguish origin-less clones and symlinked paths within one home.
#
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_HOME=${FM_HOME:-}
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh" # fm_meta_get is the one owner of the meta key/value read

case "${1:-}" in
  -h | --help)
    sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac
if [ "$#" -ne 3 ]; then
  echo "usage: fm-impl-concurrency-guard.sh <state-dir> <project-dir> <task-id>" >&2
  exit 2
fi

STATE_DIR=$1
PROJECT=$2
OWN_ID=$3
if [ ! -d "$STATE_DIR" ]; then
  echo "error: fm-impl-concurrency-guard.sh: state directory does not exist: $STATE_DIR" >&2
  exit 2
fi
if [ -n "$GUARD_HOME" ]; then
  FM_HOME=$GUARD_HOME
else
  FM_HOME=$(CDPATH='' cd -- "$STATE_DIR/.." 2>/dev/null && pwd -P) || {
    echo "error: fm-impl-concurrency-guard.sh: home directory cannot be resolved from state directory: $STATE_DIR" >&2
    exit 2
  }
fi
FM_STATE_OVERRIDE=${FM_STATE_OVERRIDE:-$STATE_DIR}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

# This guard deliberately scans THIS home's state directory only. A same-repository
# clone in another home, including a remote or separately cloned secondmate home,
# is a known and documented limitation. Cross-home/cross-machine coordination is
# tracked as a separate follow-up task.
#
# The repository identity lock is preferred; the physical form of a path, or the
# path itself when it cannot be resolved, is the fallback for an unresolvable clone.
physical_path() { # <path>
  local path=$1 real
  if real=$(cd "$path" 2>/dev/null && pwd -P); then
    printf '%s\n' "$real"
  else
    printf '%s\n' "$path"
  fi
}

repository_identity() { # <project-dir>
  local project=$1 lock
  if lock=$(fm_treehouse_project_lock_path "$project" 2>/dev/null); then
    printf 'lock:%s\n' "$lock"
  else
    printf 'path:%s\n' "$(physical_path "$project")"
  fi
}

PROJECT_IDENTITY=$(repository_identity "$PROJECT")
BLOCKERS=
for meta in "$STATE_DIR"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  [ "$id" != "$OWN_ID" ] || continue
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  case "$kind" in
    ship | adhoc) ;;
    *) continue ;;
  esac
  project=$(fm_meta_get "$meta" project)
  [ -n "$project" ] || continue
  [ "$(repository_identity "$project")" = "$PROJECT_IDENTITY" ] || continue
  BLOCKERS="${BLOCKERS:+$BLOCKERS, }$id"
done
[ -n "$BLOCKERS" ] || exit 0

echo "error: spawn refused: an implementation task is already in flight for $(basename "$PROJECT"): $BLOCKERS; one implementation task per repository runs at a time, so a second implementation task cannot land behind the first merge and re-run CI. Start $OWN_ID after that task lands (teardown)" >&2
exit 1
