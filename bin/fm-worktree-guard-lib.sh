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
#       Resolves this task's root and its two derived allowances into globals.
#
# Environment:
#   FM_WORKTREE_GUARD_META   path to this task's state/<id>.meta; ABSENT MEANS
#                            INERT, which is what keeps the guard off the
#                            firstmate primary and off every secondmate home.
#   FM_WORKTREE_GUARD_ALLOW=1     the deliberate escape (docs/worktree-guard.md).
#   FM_WORKTREE_GUARD_TEMP_ROOTS  colon-separated override of the OS temp
#                            namespace treated as unprotected scratch.

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
FM_WORKTREE_GUARD_STATE_PREFIX=
FM_WORKTREE_GUARD_TASKTMP=
FM_WORKTREE_GUARD_PATH=

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
    worktree-pool)
      printf 'returning, destroying, or pruning pool worktrees is firstmate%s cleanup path, not a worker%s: it terminates the checkout holding this task%s unlanded work and frees the lease. Report the task done and let firstmate clean up; %s.' "'s" "'s" "'s" "$escape"
      ;;
  esac
}

# Lexical absolutization and normalization against an already-physical cwd, into
# FM_WORKTREE_GUARD_PATH. No forks and no filesystem reads: empty and "."
# components are dropped and ".." pops one, so `rm -rf ..` resolves to the pool
# directory holding every sibling worktree and is caught. A target reached
# through a symlink outside the root is judged as written, which can only make
# the guard refuse a legitimate command, never allow a destructive one.
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

# True when <path> is <prefix> itself or lives under it.
fm_worktree_guard_within() { # <path> <prefix>
  [ -n "$2" ] || return 1
  [ "$2" != / ] || return 0
  case "$1" in
    "$2"|"$2"/*) return 0 ;;
  esac
  return 1
}

# One resolved target's verdict: 0 when it is allowed, 1 when it escapes the
# worker's own worktree. The allowed set is closed and small: the worker's own
# worktree, this task's own state sidecars (the brief itself tells a worker to
# `mv` its inbox messages into handled/), this task's own temp root, and the OS
# temp namespace.
fm_worktree_guard_target_allowed() { # <resolved-target>
  local target=$1 entry spec
  fm_worktree_guard_within "$target" "$FM_WORKTREE_GUARD_ROOT" && return 0
  if [ -n "$FM_WORKTREE_GUARD_STATE_PREFIX" ]; then
    case "$target" in
      "$FM_WORKTREE_GUARD_STATE_PREFIX"*) return 0 ;;
    esac
  fi
  if [ -n "$FM_WORKTREE_GUARD_TASKTMP" ]; then
    fm_worktree_guard_within "$target" "$FM_WORKTREE_GUARD_TASKTMP" && return 0
  fi
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
  local endopts=0 a
  FM_WORKTREE_GUARD_TARGETS=()
  while [ "$#" -gt 0 ]; do
    a=$1
    if [ "$endopts" -eq 0 ]; then
      case "$a" in
        --) endopts=1; shift; continue ;;
        -t|--target-directory)
          [ "$#" -ge 2 ] || return 0
          FM_WORKTREE_GUARD_TARGETS[${#FM_WORKTREE_GUARD_TARGETS[@]}]=$2
          shift 2
          continue
          ;;
        --target-directory=*)
          FM_WORKTREE_GUARD_TARGETS[${#FM_WORKTREE_GUARD_TARGETS[@]}]=${a#*=}
          shift
          continue
          ;;
        -S|--suffix)
          [ "$#" -ge 2 ] || return 0
          shift 2
          continue
          ;;
        --suffix=*|-?*) shift; continue ;;
      esac
    fi
    FM_WORKTREE_GUARD_TARGETS[${#FM_WORKTREE_GUARD_TARGETS[@]}]=$a
    shift
  done
}

# git's own options before the subcommand. Only -C changes the verdict: it
# rebases every relative path in the rest of the command, and repeated -C
# compose. An option shape this list does not know is skipped rather than read
# as the subcommand, so an unknown git option can never make a `worktree remove`
# parse as something else. Publishes the effective directory in
# FM_WORKTREE_GUARD_PATH and the remaining words in FM_WORKTREE_GUARD_TARGETS.
fm_worktree_guard_git_scan() { # <cwd> [argv...]
  local cwd=$1
  shift
  FM_WORKTREE_GUARD_TARGETS=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -C)
        [ "$#" -ge 2 ] || break
        fm_worktree_guard_normalize "$2" "$cwd"
        cwd=$FM_WORKTREE_GUARD_PATH
        shift 2
        ;;
      -c|--namespace|--git-dir|--work-tree|--exec-path|--super-prefix|--config-env)
        [ "$#" -ge 2 ] || break
        shift 2
        ;;
      --) shift; break ;;
      -?*) shift ;;
      *) break ;;
    esac
  done
  FM_WORKTREE_GUARD_PATH=$cwd
  while [ "$#" -gt 0 ]; do
    FM_WORKTREE_GUARD_TARGETS[${#FM_WORKTREE_GUARD_TARGETS[@]}]=$1
    shift
  done
}

fm_worktree_guard_decide_git() { # <cwd> [argv...]
  local cwd=$1
  shift
  fm_worktree_guard_git_scan "$cwd" "$@"
  cwd=$FM_WORKTREE_GUARD_PATH
  set -- ${FM_WORKTREE_GUARD_TARGETS[@]+"${FM_WORKTREE_GUARD_TARGETS[@]}"}
  [ "${1:-}" = worktree ] || { printf 'allow\n'; return 0; }
  shift
  local action=${1:-} target='' dryrun=0 word
  [ "$#" -eq 0 ] || shift
  for word in "$@"; do
    case "$word" in
      -n|--dry-run) dryrun=1 ;;
      -?*) ;;
      *) [ -n "$target" ] || target=$word ;;
    esac
  done
  case "$action" in
    remove)
      [ -n "$target" ] || { printf 'allow\n'; return 0; }
      fm_worktree_guard_normalize "$target" "$cwd"
      target=$FM_WORKTREE_GUARD_PATH
      # A worktree the worker created strictly INSIDE its own root is its own
      # business. Its own root is not: that checkout holds this task's unlanded
      # work, and ending it is firstmate's cleanup path.
      if [ "$target" != "$FM_WORKTREE_GUARD_ROOT" ] && fm_worktree_guard_target_allowed "$target"; then
        printf 'allow\n'
        return 0
      fi
      fm_worktree_guard_deny worktree-remove "$target"
      ;;
    prune)
      [ "$dryrun" -eq 0 ] || { printf 'allow\n'; return 0; }
      # prune names no path: it rewrites the shared administration of whatever
      # repository the command runs against, including the record of every
      # sibling worktree, so the effective directory is what is judged. Only a
      # repository inside the unprotected scratch namespace - a fixture, never a
      # fleet checkout - is allowed, which is why the worker's own root does not
      # buy a pass here.
      local saved=$FM_WORKTREE_GUARD_ROOT
      FM_WORKTREE_GUARD_ROOT=
      if fm_worktree_guard_target_allowed "$cwd"; then
        FM_WORKTREE_GUARD_ROOT=$saved
        printf 'allow\n'
        return 0
      fi
      FM_WORKTREE_GUARD_ROOT=$saved
      fm_worktree_guard_deny worktree-prune "$cwd"
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
  FM_WORKTREE_GUARD_ROOT=$FM_WORKTREE_GUARD_PATH
  if [ -n "$FM_WORKTREE_GUARD_TASKTMP" ]; then
    fm_worktree_guard_normalize "$FM_WORKTREE_GUARD_TASKTMP" /
    FM_WORKTREE_GUARD_TASKTMP=$FM_WORKTREE_GUARD_PATH
  fi
  if [ -n "$FM_WORKTREE_GUARD_STATE_PREFIX" ]; then
    fm_worktree_guard_normalize "$FM_WORKTREE_GUARD_STATE_PREFIX" /
    FM_WORKTREE_GUARD_STATE_PREFIX=$FM_WORKTREE_GUARD_PATH
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

  if [ "$code" = worktree-escape-move ]; then
    fm_worktree_guard_move_operands "$@"
  else
    fm_worktree_guard_remove_operands "$@"
  fi
  local resolved
  for target in ${FM_WORKTREE_GUARD_TARGETS[@]+"${FM_WORKTREE_GUARD_TARGETS[@]}"}; do
    [ -n "$target" ] || continue
    fm_worktree_guard_normalize "$target" "$cwd"
    resolved=$FM_WORKTREE_GUARD_PATH
    if ! fm_worktree_guard_target_allowed "$resolved"; then
      fm_worktree_guard_deny "$code" "$resolved"
      return 0
    fi
  done
  printf 'allow\n'
}

# This task's own worktree root, read from the durable record rather than from
# an exported copy, so a relaunch that moves the task to another checkout is
# followed instead of judged against a stale path. Also publishes the two
# derived allowances the decision needs. Returns non-zero when the root cannot
# be established, which is the inert case.
fm_worktree_guard_load() {
  local meta=${FM_WORKTREE_GUARD_META:-} line key value id state_dir root=''
  FM_WORKTREE_GUARD_ROOT=
  FM_WORKTREE_GUARD_STATE_PREFIX=
  FM_WORKTREE_GUARD_TASKTMP=
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
  FM_WORKTREE_GUARD_ROOT=$( (CDPATH='' cd -- "$root" 2>/dev/null && pwd -P) || printf '%s' "$root")
  id=${meta##*/}
  id=${id%.meta}
  state_dir=${meta%/*}
  [ "$state_dir" != "$meta" ] || state_dir=.
  fm_worktree_guard_normalize "$state_dir" "${PWD:-/}"
  state_dir=$FM_WORKTREE_GUARD_PATH
  # Exactly this task's own sidecars: state/<id>.status, state/<id>.inbox/... .
  # A sibling's records, and the fleet-wide records next to them, stay
  # protected.
  [ -z "$id" ] || FM_WORKTREE_GUARD_STATE_PREFIX="$state_dir/$id."
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
  exit 3
}
