#!/usr/bin/env bash
# Merge a task's PR after recording pr= and any available pr_head= through
# bin/fm-pr-check.sh, so teardown can verify landed work after squash merges.
# The full canonical GitHub PR URL is parsed by bin/fm-pr-lib.sh and the derived
# owner/repository and PR number are passed to the merge command as separate
# arguments.
#
# Merge method defaults to --squash when the caller passes none of --squash,
# --merge, --rebase, or --method after the optional -- separator. Extra args
# must not include --repo or -R because the repository comes only from the URL.
#
# Admin override: the exact token --admin after -- is the one captain-authorized
# branch-protection override. It routes this single merge through plain
# `gh pr merge` because the installed gh-axi does not forward --admin; every
# other merge, with any other flags, continues through gh-axi unchanged, and
# this script is the sole owner of that direct-gh exception. --admin is never
# implied by yolo or green CI alone: firstmate passes it only under captain
# authority to override branch protection - an explicit per-PR authorization or
# an explicit standing captain preference for routine admin merges - and only
# when review is complete, CI is green, and the required-review/branch-protection
# rule is the sole blocker (AGENTS.md section 7 owns the full merge-only scope).
# Near-miss spellings (--admin=...) are refused rather than silently forwarded
# without admin effect.
#
# A successful merge also clears the task's captain hold, but only when that
# hold's recorded reason is the merge-wait reason owned by
# bin/fm-merge-wait-lib.sh; any other captain hold survives the merge.
# Usage: fm-pr-merge.sh <task-id> <pr-url> [-- <extra pr merge args>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 2 ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
# bin/fm-pr-lib.sh parses GitLab merge request URLs so the watcher can follow
# them, but this path still addresses only GitHub by owner/repository. The
# provider check holds that refusal exactly as it was until merge parity lands.
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL" \
  || [ "$FM_PR_PROVIDER" != github ]; then
  echo "error: invalid PR merge request" >&2
  exit 2
fi
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
shift 2
[ "${1:-}" = "--" ] && shift

caller_has_merge_method() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --squash|--merge|--rebase|--method|--method=*) return 0 ;;
    esac
  done
  return 1
}

reject_repo_overrides() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --repo|--repo=*|-R|-R?*)
        echo "error: extra merge arguments must not override the repository" >&2
        return 1
        ;;
    esac
  done
}

# Only the exact --admin token is the captain-authorized admin override (see
# header); near-miss spellings are refused so an intended override can never be
# silently forwarded to gh-axi and dropped without admin effect.
reject_admin_variants() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --admin=*)
        echo "error: pass exactly --admin for a captain-authorized admin merge" >&2
        return 1
        ;;
    esac
  done
}

caller_has_admin() {
  local arg
  for arg in "$@"; do
    [ "$arg" = --admin ] && return 0
  done
  return 1
}

reject_repo_overrides "$@" || exit 1
reject_admin_variants "$@" || exit 1

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

"$SCRIPT_DIR/fm-pr-check.sh" "$ID" "$URL"
grep -qxF "pr=$URL" "$META" || {
  echo "error: PR metadata recording failed" >&2
  exit 1
}

merge_args=()
if ! caller_has_merge_method "$@"; then
  merge_args=(--squash)
fi

merge_cli=gh-axi
if caller_has_admin "$@"; then
  merge_cli=gh
fi
"$merge_cli" pr merge "$PR_NUMBER" --repo "$PR_OWNER/$PR_REPO" "${merge_args[@]+"${merge_args[@]}"}" "$@"

# The work landed, so a captain hold that recorded the wait for THIS merge is
# answered, and clearing it here is what keeps that durable record honest rather
# than accumulating resolved waits. It runs only after the merge succeeded, and
# only for a hold whose recorded reason is that merge wait: a captain-reserved
# post-merge release or operational step is held the same way and must survive
# the merge that precedes it. bin/fm-merge-wait-lib.sh owns both the reason that
# identifies a merge wait and the test above.
if [ -f "$SCRIPT_DIR/fm-merge-wait-lib.sh" ]; then
  # shellcheck source=bin/fm-merge-wait-lib.sh
  . "$SCRIPT_DIR/fm-merge-wait-lib.sh"
  if fm_merge_wait_hold_is_merge_wait "$FM_HOME" "$ID"; then
    (cd "$FM_HOME" && tasks-axi unhold "$ID" >/dev/null 2>&1) || true
  fi
fi
