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
# The classification lives in bin/fm-nm-guard-lib.sh and the run read lives in
# bin/fm-nm-status-lib.sh. This file only resolves the real tool, asks those two
# owners, renders one refusal, and otherwise execs the real tool with the
# arguments it was given, unchanged.
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
    printf '%s: no %s found on PATH outside firstmate'"'"'s shim directory\n' "$FM_NM_GUARD_TOOL" "$FM_NM_GUARD_TOOL" >&2
    exit 127
  }
  exec "$real" "$@"
}

# Minimal PATH walk used before the libraries are known to be loadable, so a
# broken firstmate checkout can never make the tool itself unreachable.
fm_nm_path_bin_fallback() {  # <name>
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
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

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
