# shellcheck shell=bash
# Shared worktree-tangle guard for the firstmate-on-itself case.
# Usage: . bin/fm-tangle-lib.sh
#
# Firstmate is a treehouse-pooled git repo of itself: crewmate worktrees and
# secondmate homes are all linked `git worktree`s of the same repo, while the
# PRIMARY checkout (the repo root firstmate operates from) is a normal checkout
# on a real branch - normally the default branch, main. The "worktree tangle"
# failure mode is a crewmate spawned to work on firstmate ITSELF branching and
# committing in the primary checkout instead of its own disposable worktree,
# stranding the primary on a feature branch (e.g. fm/readme-restructure-d3).
#
# fm_primary_tangle_branch detects exactly that and nothing else: a NAMED,
# non-default branch checked out in the given root. It is deliberately silent for
# every legitimate state - the primary on its default branch, and detached HEAD,
# which is how every linked worktree and secondmate home legitimately sits on the
# default branch. Detached HEAD on the default is fine; a feature branch in a
# primary checkout is the alarm.

# Resolve the default branch name of the git repo at <dir>: prefer origin/HEAD,
# then fall back to a local main/master. Echoes the name, or returns 1.
fm_default_branch() {
  local dir=$1 ref branch
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}

# Resolve the branch intentionally kept in the primary checkout. A local,
# gitignored config/primary-branch may name an existing local branch; absent or
# invalid config preserves the default-branch behavior. FM_CONFIG_OVERRIDE and
# FM_HOME follow the same home/config precedence as the other local knobs.
fm_primary_expected_branch() {  # <root>
  local root=$1 config_dir configured
  config_dir=${FM_CONFIG_OVERRIDE:-${FM_HOME:-$root}/config}
  if [ -f "$config_dir/primary-branch" ]; then
    IFS= read -r configured < "$config_dir/primary-branch" || true
    if [ -n "$configured" ] \
      && git check-ref-format --branch "$configured" >/dev/null 2>&1 \
      && git -C "$root" show-ref --verify --quiet "refs/heads/$configured"; then
      printf '%s\n' "$configured"
      return 0
    fi
  fi
  fm_default_branch "$root"
}

# If the git checkout at <root> is tangled - on a NAMED branch that is not its
# intentionally configured or default branch - echo the offending branch name and return 0. For every healthy
# state (not a git work tree, detached HEAD, or already on the default branch)
# echo nothing and return 1. Detached HEAD is how linked worktrees and secondmate
# homes legitimately sit, so they never trip this; only a feature branch checked
# out in a primary checkout does.
fm_primary_tangle_branch() {
  local root=$1 cur expected
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  cur=$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$cur" ] || return 1
  expected=$(fm_primary_expected_branch "$root") || return 1
  [ "$cur" = "$expected" ] && return 1
  printf '%s\n' "$cur"
  return 0
}
