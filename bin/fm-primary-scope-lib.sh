#!/usr/bin/env bash
# Shared marker-or-plain-checkout predicate for tracked hooks that must act only
# in a genuine firstmate primary home.
# This file is sourced by hook entrypoints and has no side effects on source.
# fm_primary_root_matches is split out so a caller can confirm primary-home
# identity before its gitignored state dir exists, such as to create it.

# Return 0 when $1 carries a genuine secondmate-home marker.
fm_root_is_secondmate_home() {
  local marker="$1/.fm-secondmate-home" id LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Return 0 when this process runs in a ship or scout worker pane.
# bin/fm-spawn.sh exports FM_TASK_ID into every such pane and into no
# secondmate or primary session, so the environment, not anything the worktree
# holds, decides the role.
fm_is_worker_session() {
  [ -n "${FM_TASK_ID:-}" ]
}

# Return 0 when $1 is a genuine primary root, regardless of whether its state
# dir exists yet. A worker pane is never primary: a pool slot can still carry a
# retired secondmate home's marker and state/, and those must not make it act as
# a home. Otherwise a valid secondmate marker force-includes a linked secondmate
# home, and only a plain checkout is primary, never a linked task worktree.
fm_primary_root_matches() {
  local root=$1 git_dir git_common_dir
  ! fm_is_worker_session || return 1
  if ! fm_root_is_secondmate_home "$root"; then
    git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    git_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    [ "$git_dir" = "$git_common_dir" ] || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
}

# Return 0 when $1 is a genuine primary root whose effective state dir $2
# already exists.
fm_primary_scope_matches() {
  local root=$1 state=$2
  fm_primary_root_matches "$root" && [ -d "$state" ]
}
