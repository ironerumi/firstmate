#!/usr/bin/env bash
# fm-worktree-guard-shim.sh - the transport for the worktree-isolation guard.
#
# Reached only through the name it is invoked as: bin/shims/{rm,rmdir,unlink,mv,
# treehouse} are symlinks to this file, and bin/fm-spawn.sh puts bin/shims on the
# PATH of the worker's pane before the harness starts. Every harness the fleet
# supports launches inside that pane and every tool call it makes inherits that
# PATH, so ONE mechanism covers claude, codex, opencode, pi, pi-signed, grok,
# kimi, cursor, and muse without a per-harness hook, and ONE launch line covers
# every runtime backend because bin/fm-spawn.sh sends it through the
# backend-agnostic text path. bin/fm-nm-guard-shim.sh carries the same guard for
# `git`, which it already fronts. docs/worktree-guard.md owns the full contract,
# including why this is the transport rather than a PreToolUse hook.
#
# The classification lives in bin/fm-worktree-guard-lib.sh. This file only
# resolves the real tool, asks that owner, and otherwise execs the real tool with
# the arguments it was given, unchanged. Arriving here AFTER the shell has
# expanded the command is the point: the guard judges the paths the tool will
# actually operate on, with the process's real working directory, so a glob, a
# variable, or a relative `..` needs no lexical guesswork.
#
# Exit status 3 with no side effect is a refusal; every other status belongs to
# the real tool.
set -u

FM_WORKTREE_GUARD_TOOL=$(basename -- "$0")
SHIM_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P) || SHIM_DIR=""

# Resolve the library root through the symlink, so the shim works from any PATH.
SELF=$0
if [ -L "$SELF" ]; then
  LINK=$(readlink "$SELF")
  case "$LINK" in
    /*) SELF=$LINK ;;
    *) SELF="$SHIM_DIR/$LINK" ;;
  esac
fi
BIN_DIR=$(CDPATH='' cd -- "$(dirname -- "$SELF")" 2>/dev/null && pwd -P) || BIN_DIR=""

# True when <path>, followed through its whole symlink chain, is one of
# firstmate's guard shims. A wrapper built while guard shims are deliberately on
# PATH can hold a link to a shim link, so one hop is not enough.
fm_worktree_guard_is_guard_shim() { # <path>
  local p=$1 link links=0
  while [ -L "$p" ] && [ "$links" -lt 10 ]; do
    link=$(readlink "$p" 2>/dev/null) || break
    case "$link" in
      /*) p=$link ;;
      *) p="${p%/*}/$link" ;;
    esac
    links=$((links + 1))
  done
  case "$p" in
    *fm-nm-guard-shim.sh|*fm-worktree-guard-shim.sh) return 0 ;;
  esac
  return 1
}

# Minimal PATH walk used before the libraries are known to be loadable, so a
# broken firstmate checkout can never make the tool itself unreachable. It skips
# this shim's own directory, and any OTHER firstmate home's shim of the same
# name: a worker pane already carries one shim directory, so a second one on
# PATH would otherwise have the two shims exec each other instead of reaching
# the real tool. Deliberately a private copy of the same walk in the sibling
# shim: each has to reach its real tool with the other, and its library, absent.
fm_worktree_guard_real_bin() { # <name>
  local name=$1 entry candidate candidate_dir
  local IFS=:
  for entry in ${PATH:-}; do
    [ -n "$entry" ] || entry=.
    candidate="$entry/$name"
    [ -x "$candidate" ] && [ ! -d "$candidate" ] || continue
    if [ -n "$SHIM_DIR" ]; then
      candidate_dir=$(CDPATH='' cd -- "$entry" 2>/dev/null && pwd -P) || continue
      [ "$candidate_dir" != "$SHIM_DIR" ] || continue
    fi
    ! fm_worktree_guard_is_guard_shim "$candidate" || continue
    printf '%s' "$candidate"
    return 0
  done
  # Last resort: the standard system locations, when PATH held no usable
  # candidate at all. A closed PATH built from a captured shim contains no real
  # tool; firstmate's guard regression suite constructs exactly that case.
  # Refusing to run the tool there would make the shim, rather than the guard,
  # the thing that broke the command.
  for entry in /bin /usr/bin /usr/local/bin /opt/homebrew/bin; do
    candidate="$entry/$name"
    [ -x "$candidate" ] && [ ! -d "$candidate" ] || continue
    ! fm_worktree_guard_is_guard_shim "$candidate" || continue
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

exec_real() {
  local real
  real=$(fm_worktree_guard_real_bin "$FM_WORKTREE_GUARD_TOOL") || {
    printf '%s: no %s found on PATH outside firstmate'"'"'s shim directory\n' \
      "$FM_WORKTREE_GUARD_TOOL" "$FM_WORKTREE_GUARD_TOOL" >&2
    exit 127
  }
  # Loop backstop. Another wrapper on PATH can resolve "the real tool" with
  # `command -v` and land back on this shim, and because both sides exec, the
  # two would swap places inside ONE process forever. The mark carries this
  # process's own pid, so a legitimate child process running the same tool is
  # untouched, while a second entry in the same process stops with a
  # diagnosable error instead of hanging the tool.
  if [ "${FM_GUARD_SHIM_MARK:-}" = "$$:$FM_WORKTREE_GUARD_TOOL" ]; then
    printf '%s: refusing an exec loop: another %s wrapper on PATH resolves back to firstmate'"'"'s shim (%s). Resolve the real tool without the shim directory.\n' \
      "$FM_WORKTREE_GUARD_TOOL" "$FM_WORKTREE_GUARD_TOOL" "$real" >&2
    exit 127
  fi
  FM_GUARD_SHIM_MARK="$$:$FM_WORKTREE_GUARD_TOOL"
  export FM_GUARD_SHIM_MARK
  exec "$real" "$@"
}

[ -n "$BIN_DIR" ] && [ -f "$BIN_DIR/fm-worktree-guard-lib.sh" ] || exec_real "$@"
# shellcheck source=bin/fm-worktree-guard-lib.sh
. "$BIN_DIR/fm-worktree-guard-lib.sh"

# Renders one refusal and exits 3, or returns so the real tool runs.
fm_worktree_guard_enforce "$FM_WORKTREE_GUARD_TOOL" "$@"

exec_real "$@"
