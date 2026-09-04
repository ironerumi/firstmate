#!/usr/bin/env bash
# fm-nm-guard-shim.sh - the transport for the validation-owner guard.
#
# Reached only through the name it is invoked as: bin/shims/no-mistakes and
# bin/shims/git are symlinks to this file, and bin/fm-spawn.sh puts bin/shims on
# the PATH of the crewmate's pane before the harness starts. Every harness the
# fleet supports launches inside that pane and every tool call it makes inherits
# that PATH, so one mechanism covers claude, codex, opencode, pi, pi-signed, grok
# and kimi without a per-harness hook, and one launch line covers every runtime
# backend because bin/fm-spawn.sh sends it through the backend-agnostic text
# path. docs/nm-validation-owner-guard.md owns the full contract and its reach.
#
# The classification and the run read both live in bin/fm-nm-guard-lib.sh. This
# file only resolves the real tool, asks that owner, renders one refusal, and
# otherwise execs the real tool with the arguments it was given, unchanged. It
# also asks the worktree-isolation guard
# (bin/fm-worktree-guard-lib.sh, docs/worktree-guard.md) first, because `git` is
# a tool both guards front; that guard renders its own refusal and never changes
# this one's classification.
#
# It is a guard, not a sandbox. Its threat model is a worker's mistake under
# pressure - the same threat model as the other firstmate seatbelts - so an
# absolute path that bypasses PATH is an accepted non-goal, and every failure to
# read the pipeline execs the real tool rather than refusing work.
#
# Exit status 3 with no side effect is a refusal; every other status belongs to
# the real tool.
set -u

FM_NM_GUARD_TOOL=$(basename -- "$0")
SHIM_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P) || SHIM_DIR=""
FM_NM_SHIM_DIR=$SHIM_DIR
export FM_NM_SHIM_DIR

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

exec_real() {
  local real
  real=$(fm_nm_path_bin_fallback "$FM_NM_GUARD_TOOL") || {
    printf '%s: no %s found on PATH outside firstmate'"'"'s shim directory\n' \
      "$FM_NM_GUARD_TOOL" "$FM_NM_GUARD_TOOL" >&2
    exit 127
  }
  # Loop backstop. Another wrapper on PATH can resolve "the real tool" with
  # `command -v` and land back on this shim, and because both sides exec, the
  # two would swap places inside ONE process forever. The mark carries this
  # process's own pid, so a legitimate child process running the same tool is
  # untouched, while a second entry in the same process stops with a
  # diagnosable error instead of hanging the tool.
  if [ "${FM_GUARD_SHIM_MARK:-}" = "$$:$FM_NM_GUARD_TOOL" ]; then
    printf '%s: refusing an exec loop: another %s wrapper on PATH resolves back to firstmate'"'"'s shim (%s). Resolve the real tool without the shim directory.\n' \
      "$FM_NM_GUARD_TOOL" "$FM_NM_GUARD_TOOL" "$real" >&2
    exit 127
  fi
  FM_GUARD_SHIM_MARK="$$:$FM_NM_GUARD_TOOL"
  export FM_GUARD_SHIM_MARK
  exec "$real" "$@"
}

# True when <path>, followed through its whole symlink chain, is one of
# firstmate's guard shims. A fixture that captured `command -v <tool>` inside a
# worker pane holds a link to a shim link, so one hop is not enough.
fm_nm_is_guard_shim() { # <path>
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
fm_nm_path_bin_fallback() { # <name>
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
    ! fm_nm_is_guard_shim "$candidate" || continue
    printf '%s' "$candidate"
    return 0
  done
  # Last resort: the standard system locations, when PATH held no usable
  # candidate at all. A fixture that captures `command -v <tool>` inside a
  # worker pane captures THIS shim, and a closed PATH built from those captures
  # then contains no real tool - firstmate's own suites do exactly that.
  # Refusing to run the tool there would make the shim, rather than the guard,
  # the thing that broke the command.
  for entry in /bin /usr/bin /usr/local/bin /opt/homebrew/bin; do
    candidate="$entry/$name"
    [ -x "$candidate" ] && [ ! -d "$candidate" ] || continue
    ! fm_nm_is_guard_shim "$candidate" || continue
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

# The worktree-isolation guard rides the same transport for `git`, which this
# shim already fronts, so `git worktree remove` of a sibling task's checkout is
# refused before it runs (bin/fm-worktree-guard-lib.sh owns that decision;
# docs/worktree-guard.md owns its contract). Two independent guards, two
# owners, one shim: this call renders its own refusal and exits 3, or returns
# so the validation-owner classification below proceeds unchanged.
if [ -n "$BIN_DIR" ] && [ -f "$BIN_DIR/fm-worktree-guard-lib.sh" ]; then
  FM_WORKTREE_GUARD_REAL_GIT=$(fm_nm_path_bin_fallback git 2>/dev/null) || FM_WORKTREE_GUARD_REAL_GIT=
  # shellcheck source=bin/fm-worktree-guard-lib.sh
  . "$BIN_DIR/fm-worktree-guard-lib.sh"
  fm_worktree_guard_enforce "$FM_NM_GUARD_TOOL" "$@"
fi

[ -n "$BIN_DIR" ] && [ -f "$BIN_DIR/fm-nm-guard-lib.sh" ] || exec_real "$@"
# shellcheck source=bin/fm-nm-guard-lib.sh
. "$BIN_DIR/fm-nm-guard-lib.sh"

ACTION=$(fm_nm_guard_action "$FM_NM_GUARD_TOOL" "$@")
[ "$ACTION" != none ] || exec_real "$@"

# The one deliberate escape. firstmate hands this prefix to a worker verbatim
# when it has authorized the recovery the guard would otherwise refuse; it is
# visible in the command that used it, which is the point.
[ "${FM_NM_GUARD_ALLOW:-}" != "1" ] || exec_real "$@"

GIT_BIN=$(fm_nm_path_bin_fallback git) || exec_real "$@"
WT=$("$GIT_BIN" rev-parse --show-toplevel 2>/dev/null) || WT=""
[ -n "$WT" ] || exec_real "$@"

STATUS_FILE=${FM_NM_GUARD_STATUS:-}
IFS=$'\t' read -r STATE RUN_ID STEP <<EOF
$(fm_nm_run_state "$WT")
EOF
DECISION=$(fm_nm_guard_decide "$ACTION" "${STATE:-unknown}" "${RUN_ID:-}" "${STEP:-}" "$STATUS_FILE")
case "$DECISION" in
  deny*) ;;
  *) exec_real "$@" ;;
esac

TAB=$(printf '\t')
REST=${DECISION#*"$TAB"}
CODE=${REST%%"$TAB"*}
REASON=${REST#*"$TAB"}
[ -n "$CODE" ] && [ -n "$REASON" ] && [ "$REASON" != "$REST" ] || exec_real "$@"

RULE='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
{
  printf '●%s\n' "$RULE"
  printf '●  REFUSED BY FIRSTMATE [%s]\n' "$CODE"
  printf '●  %s\n' "$REASON"
  printf '●%s\n' "$RULE"
} >&2
exit 3
