#!/usr/bin/env bash
# Refuse a second implementation task for one repository in the same firstmate
# home, so at most ONE ship can be in flight per repository at a time.
#
# Why this is mechanical rather than a prose cap: GitHub's merge queue is not
# available on this fleet's plan (Team private repositories), so two open PRs on
# one repository cannot be ordered.
# The second PR goes behind the moment the first merges and re-runs CI for
# nothing, which is pure wasted compute; one at a time per repository removes
# that collision by construction instead of asking an agent to remember a cap.
#
# Usage: fm-impl-concurrency-guard.sh <state-dir> <project-dir> <task-id> <mode>
#   Exit 0 - the repository is free for this implementation task.
#   Exit 1 - refused; stderr names the task(s) already in flight.
#   Exit 2 - usage or argument error.
#
# The caller is bin/fm-spawn.sh's pre-flight pass, which invokes this for a fresh
# ship spawn and passes that task's resolved delivery mode, so this script owns
# the whole trigger rule.
# Only a spawn that will open a PR is screened (mode no-mistakes or direct-PR);
# every other mode exits 0 immediately, so the call site stays one line and a
# local-only ship, which opens no PR, is never refused here.
#
# "In flight" is the presence of another ship task record for the same project in
# <state-dir>: bin/fm-teardown.sh removes that record only after landing is
# confirmed, so the record covers an agent still implementing, a validation run
# still working, an open PR held for merge, and a finished agent whose PR has not
# landed yet. A record carrying no kind= is read as ship, the same default
# bin/fm-spawn.sh applies to a legacy record. kind=scout (read-only, no PR) and
# kind=secondmate (not an implementation task) never block, and a project's own
# other repositories never block each other.
# <task-id> is excluded from the scan, so the same task re-checking itself (a
# relaunch) is never its own blocker.
# Both sides are compared as physical paths, because one home can reach a clone
# through a symlinked path.
#
# FM_ALLOW_CONCURRENT_IMPL=1 is the deliberate escape hatch for the rare
# authorized exception, the same shape as the other spawn-time guards
# (docs/worktree-guard.md).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh" # fm_meta_get is the one owner of the meta key/value read

case "${1:-}" in
  -h | --help)
    sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac
if [ "$#" -ne 4 ]; then
  echo "usage: fm-impl-concurrency-guard.sh <state-dir> <project-dir> <task-id> <mode>" >&2
  exit 2
fi

STATE_DIR=$1
PROJECT=$2
OWN_ID=$3
MODE=$4

case "$MODE" in
  no-mistakes | direct-PR) ;;
  *) exit 0 ;;
esac
if [ "${FM_ALLOW_CONCURRENT_IMPL:-}" = 1 ]; then
  exit 0
fi
if [ ! -d "$STATE_DIR" ]; then
  echo "error: fm-impl-concurrency-guard.sh: state directory does not exist: $STATE_DIR" >&2
  exit 2
fi

# The physical form of a path, or the path itself when it cannot be resolved, so
# a deleted clone still compares as the string its record holds.
physical_path() { # <path>
  local path=$1 real
  if real=$(cd "$path" 2>/dev/null && pwd -P); then
    printf '%s\n' "$real"
  else
    printf '%s\n' "$path"
  fi
}

PROJECT_REAL=$(physical_path "$PROJECT")
BLOCKERS=
for meta in "$STATE_DIR"/*.meta; do
  [ -f "$meta" ] || continue
  id=$(basename "$meta" .meta)
  [ "$id" != "$OWN_ID" ] || continue
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  [ "$kind" = ship ] || continue
  project=$(fm_meta_get "$meta" project)
  [ -n "$project" ] || continue
  [ "$(physical_path "$project")" = "$PROJECT_REAL" ] || continue
  BLOCKERS="${BLOCKERS:+$BLOCKERS, }$id"
done
[ -n "$BLOCKERS" ] || exit 0

echo "error: spawn refused: an implementation task is already in flight for $(basename "$PROJECT"): $BLOCKERS; one implementation task per repository runs at a time, so a second PR cannot land behind the first merge and re-run CI. Start $OWN_ID after that task lands (teardown), or re-run this spawn with FM_ALLOW_CONCURRENT_IMPL=1 only if firstmate has deliberately authorized this exact concurrency" >&2
exit 1
