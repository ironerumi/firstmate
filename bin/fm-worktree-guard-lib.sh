#!/usr/bin/env bash
# fm-worktree-guard-lib.sh - the single decision owner for the worktree-isolation
# guard: does this command destroy something OUTSIDE the worker's own worktree?
#
# The hazard is a measured incident, not a hypothesis: a worker removed a SIBLING
# task's worktree and wiped its unlanded work. Every brief already forbade that
# in prose, which is not a control. The detection, by contrast, is fully
# deterministic - when the command runs, the worker's own worktree root
# (state/<id>.meta `worktree=`) and the resolved target path are both known - so
# this is a 0/1 refusal rather than a judgment call.
#
# This file owns the decision only. bin/fm-worktree-guard-shim.sh and
# bin/fm-nm-guard-shim.sh are the transports that reach the worker's commands,
# and docs/worktree-guard.md is the complete human-readable contract.
#
# It is a guard, not a sandbox. Its threat model is a worker's mistake under
# pressure - the same threat model as firstmate's other seatbelts - so an
# absolute path handed to a program the guard does not front is an accepted
# non-goal, and every failure to establish the worker's own root allows the
# command rather than refusing work.
#
# Public interface:
#   fm_worktree_guard_enforce <tool> [argv...]
#       The whole guard for one invocation: resolves this task's root from the
#       durable record, decides, renders one refusal and exits 3, or returns 0.
#   fm_worktree_guard_decide <tool> <root> <cwd> [argv...]
#       Pure decision. Prints "allow" or "deny<TAB><code><TAB><reason>".
#   fm_worktree_guard_load
#       Resolves this task's root and its derived state sidecar allowances into
#       globals.
#
# Environment:
#   FM_WORKTREE_GUARD_META   path to this task's state/<id>.meta; ABSENT MEANS
#                            INERT, which is what keeps the guard off the
#                            firstmate primary and off every secondmate home.
#   FM_WORKTREE_GUARD_ALLOW=1     the deliberate escape (docs/worktree-guard.md).
#   FM_WORKTREE_GUARD_TEMP_ROOTS  colon-separated override of the OS temp
#                            namespace treated as unprotected scratch.

_FM_WORKTREE_GUARD_LIB_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P) || _FM_WORKTREE_GUARD_LIB_DIR=
if [ -n "$_FM_WORKTREE_GUARD_LIB_DIR" ] && [ -f "$_FM_WORKTREE_GUARD_LIB_DIR/fm-timeout-lib.sh" ]; then
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$_FM_WORKTREE_GUARD_LIB_DIR/fm-timeout-lib.sh"
fi
if [ -n "$_FM_WORKTREE_GUARD_LIB_DIR" ] && [ -f "$_FM_WORKTREE_GUARD_LIB_DIR/fm-guard-refusal-lib.sh" ]; then
  # shellcheck source=bin/fm-guard-refusal-lib.sh
  . "$_FM_WORKTREE_GUARD_LIB_DIR/fm-guard-refusal-lib.sh"
fi

# Colon-separated temp namespace. Unlanded work never lives here - firstmate
# puts each task's own scratch under /tmp/fm-<id> - and refusing an ordinary
# `rm` of a scratch file would make the guard something workers route around,
# which costs more than the class it would catch. Each entry's macOS /private
# alias is matched lexically alongside it, so no resolution fork is needed.
FM_WORKTREE_GUARD_TEMP_DEFAULT="${TMPDIR:-}:/tmp:/var/tmp:/var/folders"

# Globals published by fm_worktree_guard_load and fm_worktree_guard_normalize.
# They are set rather than echoed because both run inside the hot path of every
# guarded command, where a command substitution is a fork the guard does not
# need to pay for.
FM_WORKTREE_GUARD_ROOT=
FM_WORKTREE_GUARD_ROOT_LEXICAL=
FM_WORKTREE_GUARD_STATE_STATUS=
FM_WORKTREE_GUARD_STATE_STATUS_LEXICAL=
FM_WORKTREE_GUARD_STATE_INBOX=
FM_WORKTREE_GUARD_STATE_INBOX_LEXICAL=
FM_WORKTREE_GUARD_STATE_KEEPWARM=
FM_WORKTREE_GUARD_STATE_KEEPWARM_LEXICAL=
FM_WORKTREE_GUARD_TASKTMP=
FM_WORKTREE_GUARD_TASKTMP_LEXICAL=
FM_WORKTREE_GUARD_GITDIR=
FM_WORKTREE_GUARD_GITDIR_LEXICAL=
FM_WORKTREE_GUARD_PATH=
FM_WORKTREE_GUARD_MOVE_DESTINATION=
FM_WORKTREE_GUARD_MOVE_NO_TARGET_DIRECTORY=0
FM_WORKTREE_GUARD_MOVE_STRIP_TRAILING_SLASHES=0
FM_WORKTREE_GUARD_GIT_REPOSITORY=
FM_WORKTREE_GUARD_GIT_ACTION=
FM_WORKTREE_GUARD_GIT_PREFIX=()
FM_WORKTREE_GUARD_GIT_ARGUMENTS=()

# Deny reason text, keyed by code. One owner; the transports only render it.
fm_worktree_guard_reason() { # <code> <target>
  local escape='if firstmate has authorized this exact command, re-run it with FM_WORKTREE_GUARD_ALLOW=1 in front of it'
  case "$1" in
    worktree-escape-delete)
      printf 'deleting "%s" would destroy a path OUTSIDE this task%s own worktree, which is exactly how a sibling task loses unlanded work. Work inside your own worktree; %s.' "$2" "'s" "$escape"
      ;;
    worktree-escape-move)
      printf 'moving to or from "%s" would take a path OUTSIDE this task%s own worktree away from where it is. Work inside your own worktree; %s.' "$2" "'s" "$escape"
      ;;
    worktree-remove)
      printf 'removing the worktree "%s" is firstmate%s cleanup path, not a worker%s: it deletes a checkout whose work no one has landed, and the shared repository record with it. Report the task done and let firstmate clean up; %s.' "$2" "'s" "'s" "$escape"
      ;;
    worktree-prune)
      printf 'pruning worktree records in "%s" rewrites the SHARED repository administration every sibling task depends on, so a sibling whose checkout is momentarily unreadable loses its registration. Use --dry-run to inspect; %s.' "$2" "$escape"
      ;;
    git-skip-hooks)
      printf 'skipping git hooks with "%s" is refused in a fleet pane: the Git hooks are Firstmate setup owned by the spawn, not the worker, and a hook that fails is a defect to report rather than route around. Report it with a blocked status line and let firstmate fix it; %s.' "$2" "$escape"
      ;;
    worktree-pool)
      printf 'returning, destroying, or pruning pool worktrees is firstmate%s cleanup path, not a worker%s: it terminates the checkout holding this task%s unlanded work and frees the lease. Report the task done and let firstmate clean up; %s.' "'s" "'s" "'s" "$escape"
      ;;
  esac
}

# Lexical absolutization and normalization against an already-physical cwd, into
# FM_WORKTREE_GUARD_PATH. Empty and "." components are dropped and ".." pops one,
# so `rm -rf ..` resolves to the pool directory holding every sibling worktree
# and is caught. Containment checks resolve the deepest existing parent
# physically after this pass while deliberately leaving the final component
# unresolved to preserve the fronted tool's symlink semantics.
fm_worktree_guard_normalize() { # <path> <cwd>
  local p=$1 cwd=$2 out='' part rest
  case "$p" in
    /*) ;;
    *) p="$cwd/$p" ;;
  esac
  rest=$p
  while [ -n "$rest" ]; do
    part=${rest%%/*}
    if [ "$part" = "$rest" ]; then rest=; else rest=${rest#*/}; fi
    case "$part" in
      ''|.) continue ;;
      ..) out=${out%/*} ;;
      *) out="$out/$part" ;;
    esac
  done
  FM_WORKTREE_GUARD_PATH=${out:-/}
}

# Resolve the deepest existing parent of a normalized target physically while
# preserving the target's final component. Missing parents are re-appended
# lexically in one pass. Any existing parent that cannot be entered is an
# environmental uncertainty and returns non-zero so the caller can fail open.
fm_worktree_guard_resolve_parent() { # <normalized-target>
  local target=$1 parent leaf suffix='' physical
  [ "$target" != / ] || { FM_WORKTREE_GUARD_PATH=/; return 0; }
  parent=${target%/*}
  leaf=${target##*/}
  [ -n "$parent" ] || parent=/
  suffix=$leaf
  while [ ! -d "$parent" ]; do
    if [ -e "$parent" ] || [ -L "$parent" ]; then
      return 1
    fi
    [ "$parent" != / ] || return 1
    leaf=${parent##*/}
    parent=${parent%/*}
    [ -n "$parent" ] || parent=/
    suffix="$leaf/$suffix"
  done
  physical=$( (CDPATH='' cd -P -- "$parent" 2>/dev/null && pwd -P) ) || return 1
  fm_worktree_guard_normalize "$physical/$suffix" /
}

fm_worktree_guard_resolve_directory() { # <normalized-directory>
  local physical
  physical=$( (CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P) ) || return 1
  FM_WORKTREE_GUARD_PATH=$physical
}

# True when <path> is <prefix> itself or lives under it.
fm_worktree_guard_within() { # <path> <prefix>
  [ -n "$2" ] || return 1
  [ "$2" != / ] || return 0
  case "$1" in
    "$2"|"$2"/*) return 0 ;;
  esac
  return 1
}

fm_worktree_guard_within_alias() { # <path> <prefix>
  fm_worktree_guard_within "$1" "$2" && return 0
  case "$1" in
    /private/*) fm_worktree_guard_within "${1#/private}" "$2" ;;
    *) fm_worktree_guard_within "/private$1" "$2" ;;
  esac
}

fm_worktree_guard_same_alias() { # <path> <other>
  [ "$1" = "$2" ] && return 0
  case "$1" in
    /private/*) [ "${1#/private}" = "$2" ] ;;
    *) [ "/private$1" = "$2" ] ;;
  esac
}

# One resolved target's verdict: 0 when it is allowed, 1 when it escapes the
# worker's own worktree. The allowed set is closed and small: the worker's own
# worktree, this task's own private git administration directory, this task's
# own state sidecars (the brief itself tells a worker to `mv` its inbox
# messages into handled/), this task's own keep-warm marker and task-specific
# temp directory, this task's own temp root, and the OS temp namespace.
fm_worktree_guard_target_allowed_by() { # <target> <root> <status> <inbox> <tasktmp> <keepwarm> <gitdir>
  local target=$1 root=$2 status=$3 inbox=$4 tasktmp=$5 keepwarm=$6 gitdir=${7:-} entry spec keepwarm_name keepwarm_tmp
  fm_worktree_guard_within_alias "$target" "$root" && return 0
  [ -z "$gitdir" ] || ! fm_worktree_guard_within_alias "$target" "$gitdir" || return 0
  [ -z "$status" ] || ! fm_worktree_guard_same_alias "$target" "$status" || return 0
  [ -z "$inbox" ] || ! fm_worktree_guard_within_alias "$target" "$inbox" || return 0
  [ -z "$keepwarm" ] || ! fm_worktree_guard_same_alias "$target" "$keepwarm" || return 0
  if [ -n "$keepwarm" ]; then
    keepwarm_name=${keepwarm##*/}
    case "$keepwarm_name" in
      .keepwarm-*)
        keepwarm_tmp="${keepwarm%/*}/.keepwarm-tmp/${keepwarm_name#.keepwarm-}"
        fm_worktree_guard_within_alias "$target" "$keepwarm_tmp" && return 0
        ;;
    esac
  fi
  [ -z "$tasktmp" ] || ! fm_worktree_guard_within_alias "$target" "$tasktmp" || return 0
  spec=${FM_WORKTREE_GUARD_TEMP_ROOTS-$FM_WORKTREE_GUARD_TEMP_DEFAULT}
  local IFS=:
  for entry in $spec; do
    [ -n "$entry" ] || continue
    case "$entry" in
      /*) ;;
      *) continue ;;
    esac
    fm_worktree_guard_normalize "$entry" /
    entry=$FM_WORKTREE_GUARD_PATH
    fm_worktree_guard_within "$target" "$entry" && return 0
    # The macOS /private alias of each entry, so a fixture under $TMPDIR reads
    # the same whether the caller resolved through the alias or not.
    case "$entry" in
      /private/*) fm_worktree_guard_within "$target" "${entry#/private}" && return 0 ;;
      *) fm_worktree_guard_within "$target" "/private$entry" && return 0 ;;
    esac
  done
  return 1
}

fm_worktree_guard_target_allowed() { # <lexically-normalized-target>
  local target=$1 physical
  fm_worktree_guard_target_allowed_by "$target" \
    "$FM_WORKTREE_GUARD_ROOT_LEXICAL" \
    "$FM_WORKTREE_GUARD_STATE_STATUS_LEXICAL" \
    "$FM_WORKTREE_GUARD_STATE_INBOX_LEXICAL" \
    "$FM_WORKTREE_GUARD_TASKTMP_LEXICAL" \
    "$FM_WORKTREE_GUARD_STATE_KEEPWARM_LEXICAL" \
    "$FM_WORKTREE_GUARD_GITDIR_LEXICAL" || return 1

  fm_worktree_guard_resolve_parent "$target" || return 0
  physical=$FM_WORKTREE_GUARD_PATH
  case "$target" in
    "$FM_WORKTREE_GUARD_ROOT_LEXICAL"|\
    "$FM_WORKTREE_GUARD_STATE_STATUS_LEXICAL"|\
    "$FM_WORKTREE_GUARD_STATE_INBOX_LEXICAL"|\
    "$FM_WORKTREE_GUARD_STATE_KEEPWARM_LEXICAL"|\
    "$FM_WORKTREE_GUARD_TASKTMP_LEXICAL"|\
    "$FM_WORKTREE_GUARD_GITDIR_LEXICAL") return 0 ;;
  esac
  fm_worktree_guard_target_allowed_by "$physical" \
    "$FM_WORKTREE_GUARD_ROOT" \
    "$FM_WORKTREE_GUARD_STATE_STATUS" \
    "$FM_WORKTREE_GUARD_STATE_INBOX" \
    "$FM_WORKTREE_GUARD_TASKTMP" \
    "$FM_WORKTREE_GUARD_STATE_KEEPWARM" \
    "$FM_WORKTREE_GUARD_GITDIR"
}

# The spawn-installed busy-tracking hook (bin/fm-busy-event.sh) publishes this
# task's busy record with `mv -f <state>/<id>.busy-state.tmp.<pid>
# <state>/<id>.busy-state` and releases its lock with `rmdir
# <state>/<id>.busy-state.lock`, both in the supervising home's state/. This is
# the whole allowance for them, deliberately not a pattern: only those two exact
# shapes for this task's own id, with <state> taken physically from the record's
# directory. Returns 0 only when the entire command is one of them.
fm_worktree_guard_busy_allowed() { # <tool> <cwd> [argv...]
  local tool=$1 cwd=$2 state id src dst base rest path f
  shift 2
  [ -n "$FM_WORKTREE_GUARD_STATE_STATUS" ] || return 1
  state=${FM_WORKTREE_GUARD_STATE_STATUS%/*}
  id=${FM_WORKTREE_GUARD_STATE_STATUS##*/}
  id=${id%.status}
  [ -n "$id" ] && [ -n "$state" ] || return 1
  case "$tool" in
    mv)
      [ "${1:-}" != -f ] || shift
      [ "$#" -eq 2 ] || return 1
      src=$1 dst=$2
      case "$src" in */) return 1 ;; esac
      case "$dst" in */) return 1 ;; esac
      case "$src" in -*) return 1 ;; esac
      fm_worktree_guard_normalize "$src" "$cwd"
      fm_worktree_guard_resolve_parent "$FM_WORKTREE_GUARD_PATH" || return 1
      src=$FM_WORKTREE_GUARD_PATH
      fm_worktree_guard_normalize "$dst" "$cwd"
      fm_worktree_guard_resolve_parent "$FM_WORKTREE_GUARD_PATH" || return 1
      dst=$FM_WORKTREE_GUARD_PATH
      fm_worktree_guard_same_alias "${src%/*}" "$state" || return 1
      fm_worktree_guard_same_alias "$dst" "$state/$id.busy-state" || return 1
      base=${src##*/}
      case "$base" in
        "$id.busy-state.tmp."?*) rest=${base#"$id.busy-state.tmp."} ;;
        *) return 1 ;;
      esac
      case "$rest" in *[!0-9]*) return 1 ;; esac
      [ ! -d "$dst" ] || return 1
      return 0
      ;;
    rmdir)
      [ "$#" -eq 1 ] || return 1
      path=$1
      case "$path" in */|-*) return 1 ;; esac
      fm_worktree_guard_normalize "$path" "$cwd"
      fm_worktree_guard_resolve_parent "$FM_WORKTREE_GUARD_PATH" || return 1
      path=$FM_WORKTREE_GUARD_PATH
      fm_worktree_guard_same_alias "$path" "$state/$id.busy-state.lock" || return 1
      [ -d "$path" ] && [ ! -L "$path" ] || return 1
      for f in "$path"/* "$path"/.[!.]* "$path"/..?*; do
        if [ -e "$f" ] || [ -L "$f" ]; then return 1; fi
      done
      return 0
      ;;
  esac
  return 1
}

fm_worktree_guard_deny() { # <code> <target>
  printf 'deny\t%s\t%s\n' "$1" "$(fm_worktree_guard_reason "$1" "$2")"
}

# Operands of a coreutils-style remove, into FM_WORKTREE_GUARD_TARGETS.
# Everything that is not option-shaped is a target, with "--" ending option
# parsing. No rm/rmdir/unlink option takes a separate value, so no value can be
# mistaken for a path and no path can be mistaken for a value.
fm_worktree_guard_remove_operands() { # [argv...]
  local endopts=0 a
  FM_WORKTREE_GUARD_TARGETS=()
  for a in "$@"; do
    if [ "$endopts" -eq 0 ]; then
      case "$a" in
        --) endopts=1; continue ;;
        -?*) continue ;;
      esac
    fi
    FM_WORKTREE_GUARD_TARGETS[${#FM_WORKTREE_GUARD_TARGETS[@]}]=$a
  done
}

# Operands of a move, into FM_WORKTREE_GUARD_TARGETS. BOTH sides matter, because
# a move removes the source from where it is and overwrites the destination.
# -t/--target-directory names a destination; -S/--suffix consumes a value that
# is not a path.
fm_worktree_guard_move_operands() { # [argv...]
  local endopts=0 a cluster option explicit_destination=0
  FM_WORKTREE_GUARD_TARGETS=()
  FM_WORKTREE_GUARD_MOVE_DESTINATION=
  FM_WORKTREE_GUARD_MOVE_NO_TARGET_DIRECTORY=0
  FM_WORKTREE_GUARD_MOVE_STRIP_TRAILING_SLASHES=0
  while [ "$#" -gt 0 ]; do
    a=$1
    if [ "$endopts" -eq 0 ]; then
      case "$a" in
        --) endopts=1; shift; continue ;;
        --target-directory)
          [ "$#" -ge 2 ] || return 0
          FM_WORKTREE_GUARD_TARGETS[${#FM_WORKTREE_GUARD_TARGETS[@]}]=$2
          FM_WORKTREE_GUARD_MOVE_DESTINATION=$2
          explicit_destination=1
          shift 2
          continue
          ;;
        --target-directory=*)
          FM_WORKTREE_GUARD_TARGETS[${#FM_WORKTREE_GUARD_TARGETS[@]}]=${a#*=}
          FM_WORKTREE_GUARD_MOVE_DESTINATION=${a#*=}
          explicit_destination=1
          shift
          continue
          ;;
        --no-target-directory)
          FM_WORKTREE_GUARD_MOVE_NO_TARGET_DIRECTORY=1
          shift
          continue
          ;;
        --strip-trailing-slashes)
          FM_WORKTREE_GUARD_MOVE_STRIP_TRAILING_SLASHES=1
          shift
          continue
          ;;
        --suffix)
          [ "$#" -ge 2 ] || return 0
          shift 2
          continue
          ;;
        --suffix=*) shift; continue ;;
        --?*) shift; continue ;;
        -?*)
          cluster=${a#-}
          while [ -n "$cluster" ]; do
            option=${cluster:0:1}
            cluster=${cluster:1}
            case "$option" in
              t)
                if [ -n "$cluster" ]; then
                  FM_WORKTREE_GUARD_TARGETS[${#FM_WORKTREE_GUARD_TARGETS[@]}]=$cluster
                  FM_WORKTREE_GUARD_MOVE_DESTINATION=$cluster
                  explicit_destination=1
                  cluster=
                elif [ "$#" -ge 2 ]; then
                  FM_WORKTREE_GUARD_TARGETS[${#FM_WORKTREE_GUARD_TARGETS[@]}]=$2
                  FM_WORKTREE_GUARD_MOVE_DESTINATION=$2
                  explicit_destination=1
                  shift
                fi
                ;;
              T) FM_WORKTREE_GUARD_MOVE_NO_TARGET_DIRECTORY=1 ;;
              S)
                if [ -n "$cluster" ]; then
                  cluster=
                elif [ "$#" -ge 2 ]; then
                  shift
                fi
                ;;
            esac
          done
          shift
          continue
          ;;
      esac
    fi
    FM_WORKTREE_GUARD_TARGETS[${#FM_WORKTREE_GUARD_TARGETS[@]}]=$a
    shift
  done
  if [ "$explicit_destination" -eq 0 ] && [ "${#FM_WORKTREE_GUARD_TARGETS[@]}" -ge 2 ]; then
    FM_WORKTREE_GUARD_MOVE_DESTINATION=${FM_WORKTREE_GUARD_TARGETS[${#FM_WORKTREE_GUARD_TARGETS[@]}-1]}
  fi
}

# Preserve git's original global prefix and find only an adjacent worktree
# action. Git itself remains the owner of every global option's meaning.
fm_worktree_guard_git_scan() { # [argv...]
  local words=("$@") index
  FM_WORKTREE_GUARD_GIT_PREFIX=()
  FM_WORKTREE_GUARD_GIT_ARGUMENTS=()
  FM_WORKTREE_GUARD_GIT_ACTION=
  index=0
  while [ "$index" -lt "$(( ${#words[@]} - 1 ))" ]; do
    if [ "${words[$index]}" = worktree ]; then
      case "${words[$((index + 1))]}" in
        remove|prune)
          FM_WORKTREE_GUARD_GIT_PREFIX=("${words[@]:0:index}")
          FM_WORKTREE_GUARD_GIT_ACTION=${words[$((index + 1))]}
          FM_WORKTREE_GUARD_GIT_ARGUMENTS=("${words[@]:$((index + 2))}")
          return 0
          ;;
      esac
    fi
    index=$((index + 1))
  done
}

fm_worktree_guard_git_effective_cwd() { # <cwd>
  local cwd=$1 index=0 word
  fm_worktree_guard_normalize "$cwd" /
  cwd=$FM_WORKTREE_GUARD_PATH
  while [ "$index" -lt "${#FM_WORKTREE_GUARD_GIT_PREFIX[@]}" ]; do
    word=${FM_WORKTREE_GUARD_GIT_PREFIX[$index]}
    if [ "$word" = -C ]; then
      index=$((index + 1))
      [ "$index" -lt "${#FM_WORKTREE_GUARD_GIT_PREFIX[@]}" ] || return 1
      fm_worktree_guard_normalize "${FM_WORKTREE_GUARD_GIT_PREFIX[$index]}" "$cwd"
      cwd=$FM_WORKTREE_GUARD_PATH
    fi
    index=$((index + 1))
  done
  FM_WORKTREE_GUARD_PATH=$cwd
}

fm_worktree_guard_git_common_dir() { # <cwd>
  local cwd=$1 output
  [ -n "${FM_WORKTREE_GUARD_REAL_GIT:-}" ] && [ -x "$FM_WORKTREE_GUARD_REAL_GIT" ] || return 1
  declare -F fm_run_timed >/dev/null 2>&1 || return 1
  output=$(CDPATH='' cd -P -- "$cwd" 2>/dev/null && \
    fm_run_timed 2 "$FM_WORKTREE_GUARD_REAL_GIT" \
      ${FM_WORKTREE_GUARD_GIT_PREFIX[@]+"${FM_WORKTREE_GUARD_GIT_PREFIX[@]}"} \
      rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ -n "$output" ] || return 1
  case "$output" in
    *$'\n'*) return 1 ;;
  esac
  fm_worktree_guard_normalize "$output" "${PWD:-/}"
  fm_worktree_guard_resolve_directory "$FM_WORKTREE_GUARD_PATH" || return 1
  FM_WORKTREE_GUARD_GIT_REPOSITORY=$FM_WORKTREE_GUARD_PATH
}

# Prints the hook-skipping flag when this git command line asks git to skip its
# hooks, and returns 0; returns 1 otherwise. Covers --no-verify (and its unique
# abbreviations) on the verbs that run hooks, plus -n where it means --no-verify:
# commit and am. On merge and rebase -n is --no-stat, on cherry-pick and revert
# it is --no-commit, and on push it is --dry-run, so none of those are hook skips.
# Global options are skipped by git's own grammar, and only words that are
# options - not the values of -m/-F/--message/--file/--author/--exec - are inspected.
fm_worktree_guard_git_skip_hooks() { # [argv...]
  local verb='' word endopts=0 cluster ch skip_next=0 short_values
  while [ "$#" -gt 0 ]; do
    word=$1
    shift
    if [ "$skip_next" -eq 1 ]; then skip_next=0; continue; fi
    if [ -z "$verb" ]; then
      case "$word" in
        -C|-c|--git-dir|--work-tree|--namespace|--super-prefix|--config-env|--attr-source) skip_next=1 ;;
        -?*) ;;
        commit|merge|cherry-pick|rebase|revert|am|push) verb=$word ;;
        *) return 1 ;;
      esac
      continue
    fi
    [ "$endopts" -eq 0 ] || continue
    case "$word" in
      --) endopts=1 ;;
      -m|-F|--message|--file|--author|--exec|-x) skip_next=1 ;;
      --no-v|--no-ve|--no-ver|--no-veri|--no-verif|--no-verify)
        printf '%s' "$word"
        return 0
        ;;
      --*) ;;
      -?*)
        case "$verb" in
          commit) short_values=mFCctSu ;;
          am) short_values=pCS ;;
          *) continue ;;
        esac
        cluster=${word#-}
        while [ -n "$cluster" ]; do
          ch=${cluster:0:1}
          cluster=${cluster:1}
          case "$ch" in
            n) printf '%s' "$word"; return 0 ;;
          esac
          case "$short_values" in
            *"$ch"*) break ;;
          esac
        done
        ;;
    esac
  done
  return 1
}

# The no-mistakes pipeline's own gate push is `git push --no-verify -o <option>
# no-mistakes <sha>:refs/heads/<branch>`, run from the task's worktree. It is
# tooling the worker cannot reword, so this is its whole allowance and nothing
# wider: no global options, only --no-verify and push options, the remote named
# exactly no-mistakes whose push URL is a no-mistakes gate repository, and one
# refspec whose destination is this worktree's own current branch. Anything
# else, including --no-verify to any other remote, still refuses. Returns 0 only
# when the entire command is that push; any uncertainty returns 1.
fm_worktree_guard_gate_push_allowed() { # <cwd> [argv...]
  local cwd=$1 word remote='' refspec='' count=0 branch url skip_value=0 seen_no_verify=0
  shift
  [ "${1:-}" = push ] || return 1
  shift
  for word in "$@"; do
    if [ "$skip_value" -eq 1 ]; then skip_value=0; continue; fi
    case "$word" in
      --no-verify) seen_no_verify=1 ;;
      -o|--push-option) skip_value=1 ;;
      --push-option=*) ;;
      -?*) return 1 ;;
      *)
        if [ -z "$remote" ]; then remote=$word; else refspec=$word; count=$((count + 1)); fi
        ;;
    esac
  done
  [ "$skip_value" -eq 0 ] && [ "$seen_no_verify" -eq 1 ] && [ "$remote" = no-mistakes ] && [ "$count" -eq 1 ] || return 1
  case "$refspec" in
    +*|:*|*:) return 1 ;;
    *:refs/heads/?*) ;;
    *) return 1 ;;
  esac
  [ -n "${FM_WORKTREE_GUARD_REAL_GIT:-}" ] && [ -x "$FM_WORKTREE_GUARD_REAL_GIT" ] || return 1
  declare -F fm_run_timed >/dev/null 2>&1 || return 1
  branch=$(CDPATH='' cd -P -- "$cwd" 2>/dev/null && \
    fm_run_timed 2 "$FM_WORKTREE_GUARD_REAL_GIT" symbolic-ref --short -q HEAD 2>/dev/null) || return 1
  [ -n "$branch" ] && [ "${refspec#*:}" = "refs/heads/$branch" ] || return 1
  url=$(CDPATH='' cd -P -- "$cwd" 2>/dev/null && \
    fm_run_timed 2 "$FM_WORKTREE_GUARD_REAL_GIT" remote get-url --push no-mistakes 2>/dev/null) || return 1
  case "$url" in
    /*/.no-mistakes/repos/?*.git) return 0 ;;
  esac
  return 1
}

fm_worktree_guard_decide_git() { # <cwd> [argv...]
  local cwd=$1 invocation_cwd=$1 repository repository_target flag
  shift
  if flag=$(fm_worktree_guard_git_skip_hooks "$@"); then
    if fm_worktree_guard_gate_push_allowed "$cwd" "$@"; then
      printf 'allow\n'
      return 0
    fi
    fm_worktree_guard_deny git-skip-hooks "$flag"
    return 0
  fi
  fm_worktree_guard_git_scan "$@"
  local action=$FM_WORKTREE_GUARD_GIT_ACTION target='' dryrun=0 word
  [ -n "$action" ] || { printf 'allow\n'; return 0; }
  set -- ${FM_WORKTREE_GUARD_GIT_ARGUMENTS[@]+"${FM_WORKTREE_GUARD_GIT_ARGUMENTS[@]}"}
  for word in "$@"; do
    case "$word" in
      -n|--dry-run) dryrun=1 ;;
      -?*) ;;
      *) [ -n "$target" ] || target=$word ;;
    esac
  done
  [ "$action" != prune ] || [ "$dryrun" -eq 0 ] || { printf 'allow\n'; return 0; }
  fm_worktree_guard_git_effective_cwd "$cwd" || { printf 'allow\n'; return 0; }
  cwd=$FM_WORKTREE_GUARD_PATH
  fm_worktree_guard_git_common_dir "$invocation_cwd" || { printf 'allow\n'; return 0; }
  repository=$FM_WORKTREE_GUARD_GIT_REPOSITORY
  repository_target="$repository/.fm-worktree-guard-child"
  case "$action" in
    remove)
      [ -n "$target" ] || { printf 'allow\n'; return 0; }
      if ! fm_worktree_guard_target_allowed "$repository_target"; then
        fm_worktree_guard_deny worktree-remove "$repository"
        return 0
      fi
      fm_worktree_guard_normalize "$target" "$cwd"
      target=$FM_WORKTREE_GUARD_PATH
      # A worktree the worker created strictly INSIDE its own root is its own
      # business. Its own root is not: that checkout holds this task's unlanded
      # work, and ending it is firstmate's cleanup path.
      if ! fm_worktree_guard_same_alias "$target" "$FM_WORKTREE_GUARD_ROOT_LEXICAL" && \
        ! fm_worktree_guard_same_alias "$target" "$FM_WORKTREE_GUARD_ROOT" && \
        fm_worktree_guard_target_allowed "$target"; then
        printf 'allow\n'
        return 0
      fi
      fm_worktree_guard_deny worktree-remove "$target"
      ;;
    prune)
      # prune names no path: it rewrites the shared administration of whatever
      # repository the command runs against, including the record of every
      # sibling worktree, so git's canonical common directory is judged. Only a
      # repository inside the unprotected scratch namespace - a fixture, never a
      # fleet checkout - is allowed, which is why the worker's own root does not
      # buy a pass here.
      local saved=$FM_WORKTREE_GUARD_ROOT saved_lexical=$FM_WORKTREE_GUARD_ROOT_LEXICAL
      FM_WORKTREE_GUARD_ROOT=
      FM_WORKTREE_GUARD_ROOT_LEXICAL=
      if fm_worktree_guard_target_allowed "$repository_target"; then
        FM_WORKTREE_GUARD_ROOT=$saved
        FM_WORKTREE_GUARD_ROOT_LEXICAL=$saved_lexical
        printf 'allow\n'
        return 0
      fi
      FM_WORKTREE_GUARD_ROOT=$saved
      FM_WORKTREE_GUARD_ROOT_LEXICAL=$saved_lexical
      fm_worktree_guard_deny worktree-prune "$repository"
      ;;
    *) printf 'allow\n' ;;
  esac
}

fm_worktree_guard_decide() { # <tool> <root> <cwd> [argv...]
  local tool=$1 root=$2 cwd=$3
  shift 3
  local code='' target
  # Normalize every boundary the same way targets are normalized, so a path
  # carrying a trailing or doubled slash - which $TMPDIR routinely does - still
  # matches the resolved target it contains.
  fm_worktree_guard_normalize "$root" /
  FM_WORKTREE_GUARD_ROOT_LEXICAL=$FM_WORKTREE_GUARD_PATH
  if fm_worktree_guard_resolve_directory "$FM_WORKTREE_GUARD_ROOT_LEXICAL"; then
    FM_WORKTREE_GUARD_ROOT=$FM_WORKTREE_GUARD_PATH
  else
    FM_WORKTREE_GUARD_ROOT=$FM_WORKTREE_GUARD_ROOT_LEXICAL
  fi
  if [ -n "$FM_WORKTREE_GUARD_TASKTMP" ]; then
    fm_worktree_guard_normalize "$FM_WORKTREE_GUARD_TASKTMP" /
    FM_WORKTREE_GUARD_TASKTMP_LEXICAL=$FM_WORKTREE_GUARD_PATH
    if fm_worktree_guard_resolve_directory "$FM_WORKTREE_GUARD_TASKTMP_LEXICAL"; then
      FM_WORKTREE_GUARD_TASKTMP=$FM_WORKTREE_GUARD_PATH
    else
      FM_WORKTREE_GUARD_TASKTMP=$FM_WORKTREE_GUARD_TASKTMP_LEXICAL
    fi
  fi
  if [ -n "$FM_WORKTREE_GUARD_GITDIR" ]; then
    fm_worktree_guard_normalize "$FM_WORKTREE_GUARD_GITDIR" /
    FM_WORKTREE_GUARD_GITDIR_LEXICAL=$FM_WORKTREE_GUARD_PATH
    if fm_worktree_guard_resolve_directory "$FM_WORKTREE_GUARD_GITDIR_LEXICAL"; then
      FM_WORKTREE_GUARD_GITDIR=$FM_WORKTREE_GUARD_PATH
    else
      FM_WORKTREE_GUARD_GITDIR=$FM_WORKTREE_GUARD_GITDIR_LEXICAL
    fi
  fi
  if [ -n "$FM_WORKTREE_GUARD_STATE_STATUS" ]; then
    fm_worktree_guard_normalize "$FM_WORKTREE_GUARD_STATE_STATUS" /
    FM_WORKTREE_GUARD_STATE_STATUS_LEXICAL=$FM_WORKTREE_GUARD_PATH
    if fm_worktree_guard_resolve_parent "$FM_WORKTREE_GUARD_STATE_STATUS_LEXICAL"; then
      FM_WORKTREE_GUARD_STATE_STATUS=$FM_WORKTREE_GUARD_PATH
    else
      FM_WORKTREE_GUARD_STATE_STATUS=$FM_WORKTREE_GUARD_STATE_STATUS_LEXICAL
    fi
  fi
  if [ -n "$FM_WORKTREE_GUARD_STATE_INBOX" ]; then
    fm_worktree_guard_normalize "$FM_WORKTREE_GUARD_STATE_INBOX" /
    FM_WORKTREE_GUARD_STATE_INBOX_LEXICAL=$FM_WORKTREE_GUARD_PATH
    if fm_worktree_guard_resolve_directory "$FM_WORKTREE_GUARD_STATE_INBOX_LEXICAL"; then
      FM_WORKTREE_GUARD_STATE_INBOX=$FM_WORKTREE_GUARD_PATH
    else
      FM_WORKTREE_GUARD_STATE_INBOX=$FM_WORKTREE_GUARD_STATE_INBOX_LEXICAL
    fi
  fi
  if [ -n "$FM_WORKTREE_GUARD_STATE_KEEPWARM" ]; then
    fm_worktree_guard_normalize "$FM_WORKTREE_GUARD_STATE_KEEPWARM" /
    FM_WORKTREE_GUARD_STATE_KEEPWARM_LEXICAL=$FM_WORKTREE_GUARD_PATH
    if fm_worktree_guard_resolve_parent "$FM_WORKTREE_GUARD_STATE_KEEPWARM_LEXICAL"; then
      FM_WORKTREE_GUARD_STATE_KEEPWARM=$FM_WORKTREE_GUARD_PATH
    else
      FM_WORKTREE_GUARD_STATE_KEEPWARM=$FM_WORKTREE_GUARD_STATE_KEEPWARM_LEXICAL
    fi
  fi

  case "$tool" in
    rm|rmdir|unlink) code=worktree-escape-delete ;;
    mv) code=worktree-escape-move ;;
    git)
      fm_worktree_guard_decide_git "$cwd" "$@"
      return 0
      ;;
    treehouse)
      # The pool commands that end a worktree's life. get, enter, and status are
      # untouched.
      case "${1:-}" in
        return|destroy|prune) fm_worktree_guard_deny worktree-pool "" ;;
        *) printf 'allow\n' ;;
      esac
      return 0
      ;;
    *) printf 'allow\n'; return 0 ;;
  esac

  case "$tool" in
    mv|rmdir)
      if fm_worktree_guard_busy_allowed "$tool" "$cwd" "$@"; then
        printf 'allow\n'
        return 0
      fi
      ;;
  esac

  if [ "$code" = worktree-escape-move ]; then
    fm_worktree_guard_move_operands "$@"
  else
    fm_worktree_guard_remove_operands "$@"
  fi
  local resolved check_target destination
  if [ "$code" = worktree-escape-move ] && [ -n "$FM_WORKTREE_GUARD_MOVE_DESTINATION" ]; then
    fm_worktree_guard_normalize "$FM_WORKTREE_GUARD_MOVE_DESTINATION" "$cwd"
    destination=$FM_WORKTREE_GUARD_PATH
  else
    destination=
  fi
  for target in ${FM_WORKTREE_GUARD_TARGETS[@]+"${FM_WORKTREE_GUARD_TARGETS[@]}"}; do
    [ -n "$target" ] || continue
    fm_worktree_guard_normalize "$target" "$cwd"
    resolved=$FM_WORKTREE_GUARD_PATH
    check_target=$resolved
    if [ "$code" = worktree-escape-move ] && \
      [ "$FM_WORKTREE_GUARD_MOVE_NO_TARGET_DIRECTORY" -eq 0 ] && \
      [ "$resolved" = "$destination" ] && [ -d "$resolved" ]; then
      check_target="$resolved/.fm-worktree-guard-child"
    elif [ "$code" = worktree-escape-move ] && \
      [ "$FM_WORKTREE_GUARD_MOVE_STRIP_TRAILING_SLASHES" -eq 0 ] && \
      [ "$resolved" != "$destination" ]; then
      case "$target" in
        */) check_target="$resolved/.fm-worktree-guard-child" ;;
      esac
    elif [ "$tool" = rm ] || [ "$tool" = rmdir ]; then
      case "$target" in
        */) check_target="$resolved/.fm-worktree-guard-child" ;;
      esac
    fi
    if ! fm_worktree_guard_target_allowed "$check_target"; then
      fm_worktree_guard_deny "$code" "$resolved"
      return 0
    fi
  done
  printf 'allow\n'
}

# This task's own private git administration directory into
# FM_WORKTREE_GUARD_GITDIR, or empty when the root has none. A linked worktree's
# `.git` is a FILE reading `gitdir: <admin>`, and <admin> lives under the primary
# repository's .git/worktrees/, outside the root, holding the per-worktree files
# git and its hooks rewrite (COMMIT_EDITMSG, MERGE_MSG, rebase state). Only a
# directory carrying a linked worktree's own commondir and gitdir markers
# counts, so the shared common directory (objects, refs, every sibling's admin
# directory) is never widened by a `.git` file that points at it. A `.git`
# DIRECTORY is inside the root already and needs no allowance.
fm_worktree_guard_own_gitdir() { # <physical-root>
  local line dir
  FM_WORKTREE_GUARD_GITDIR=
  [ -f "$1/.git" ] || return 0
  IFS= read -r line < "$1/.git" || [ -n "$line" ] || return 0
  case "$line" in
    'gitdir: '?*) dir=${line#gitdir: } ;;
    *) return 0 ;;
  esac
  fm_worktree_guard_normalize "$dir" "$1"
  fm_worktree_guard_resolve_directory "$FM_WORKTREE_GUARD_PATH" || return 0
  dir=$FM_WORKTREE_GUARD_PATH
  [ -f "$dir/commondir" ] && [ -f "$dir/gitdir" ] || return 0
  FM_WORKTREE_GUARD_GITDIR=$dir
}

# This task's own worktree root, read from the durable record rather than from
# an exported copy, so a relaunch that moves the task to another checkout is
# followed instead of judged against a stale path. Also publishes the derived
# allowances the decision needs. Returns non-zero when the root cannot
# be established, which is the inert case.
fm_worktree_guard_load() {
  local meta=${FM_WORKTREE_GUARD_META:-} line key value id state_dir root=''
  FM_WORKTREE_GUARD_ROOT=
  FM_WORKTREE_GUARD_ROOT_LEXICAL=
  FM_WORKTREE_GUARD_STATE_STATUS=
  FM_WORKTREE_GUARD_STATE_STATUS_LEXICAL=
  FM_WORKTREE_GUARD_STATE_INBOX=
  FM_WORKTREE_GUARD_STATE_INBOX_LEXICAL=
  FM_WORKTREE_GUARD_STATE_KEEPWARM=
  FM_WORKTREE_GUARD_STATE_KEEPWARM_LEXICAL=
  FM_WORKTREE_GUARD_TASKTMP=
  FM_WORKTREE_GUARD_TASKTMP_LEXICAL=
  FM_WORKTREE_GUARD_GITDIR=
  FM_WORKTREE_GUARD_GITDIR_LEXICAL=
  [ -n "$meta" ] && [ -f "$meta" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *=*) ;;
      *) continue ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      worktree) root=$value ;;
      tasktmp) FM_WORKTREE_GUARD_TASKTMP=$value ;;
      kind)
        # A secondmate runs a fleet of its own: teardown, lease returns, and
        # state cleanup outside its home are its job, so it is never guarded.
        [ "$value" != secondmate ] || return 1
        ;;
    esac
  done < "$meta"
  [ -n "$root" ] || return 1
  FM_WORKTREE_GUARD_ROOT=$(CDPATH='' cd -- "$root" 2>/dev/null && pwd -P) || return 1
  fm_worktree_guard_own_gitdir "$FM_WORKTREE_GUARD_ROOT"
  id=${meta##*/}
  id=${id%.meta}
  state_dir=${meta%/*}
  [ "$state_dir" != "$meta" ] || state_dir=.
  fm_worktree_guard_normalize "$state_dir" "${PWD:-/}"
  state_dir=$FM_WORKTREE_GUARD_PATH
  # Exactly this task's own sidecars: state/<id>.status, state/<id>.inbox/... ,
  # and the Claude keep-warm marker state/.keepwarm-<id> together with its
  # per-task temp directory state/.keepwarm-tmp/<id>/ that the Stop hook writes.
  # A sibling's records, and the fleet-wide records next to them, stay protected.
  if [ -n "$id" ]; then
    FM_WORKTREE_GUARD_STATE_STATUS="$state_dir/$id.status"
    FM_WORKTREE_GUARD_STATE_INBOX="$state_dir/$id.inbox"
    FM_WORKTREE_GUARD_STATE_KEEPWARM="$state_dir/.keepwarm-$id"
  fi
  return 0
}

fm_worktree_guard_render() { # <code> <reason>
  local rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  {
    printf '●%s\n' "$rule"
    printf '●  REFUSED BY FIRSTMATE [%s]\n' "$1"
    printf '●  %s\n' "$2"
    printf '●%s\n' "$rule"
  } >&2
}

# The whole guard for one invocation. Exits 3 on a refusal - the same status the
# validation-owner guard uses for "refused, nothing happened" - and returns 0
# for every other outcome, including every uncertainty.
fm_worktree_guard_enforce() { # <tool> [argv...]
  local tool=$1
  shift
  [ "${FM_WORKTREE_GUARD_ALLOW:-}" != "1" ] || return 0
  fm_worktree_guard_load || return 0
  [ -n "$FM_WORKTREE_GUARD_ROOT" ] || return 0
  local cwd decision code reason rest tab
  cwd=$(pwd -P 2>/dev/null) || return 0
  [ -n "$cwd" ] || return 0
  decision=$(fm_worktree_guard_decide "$tool" "$FM_WORKTREE_GUARD_ROOT" "$cwd" "$@") || return 0
  case "$decision" in
    deny*) ;;
    *) return 0 ;;
  esac
  tab=$(printf '\t')
  rest=${decision#*"$tab"}
  code=${rest%%"$tab"*}
  reason=${rest#*"$tab"}
  [ -n "$code" ] && [ -n "$reason" ] && [ "$reason" != "$rest" ] || return 0
  fm_worktree_guard_render "$code" "$reason"
  # Report before exiting so firstmate learns of the refusal whatever the worker
  # does next. The status record is the task's own, from the spawn export or, in
  # its absence, the one derived from the durable record.
  ! declare -F fm_guard_refusal_report >/dev/null 2>&1 || \
    fm_guard_refusal_report "${FM_NM_GUARD_STATUS:-$FM_WORKTREE_GUARD_STATE_STATUS}" "$tool" "$code"
  exit 3
}
