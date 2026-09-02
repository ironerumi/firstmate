#!/usr/bin/env bash
# fm-nm-config-keydiff.sh - report top-level default config keys the local
# no-mistakes install ships but the operator's global config does not set.
#
# Usage:
#   fm-nm-config-keydiff.sh [check]
#   fm-nm-config-keydiff.sh arm
#   fm-nm-config-keydiff.sh disarm
#   fm-nm-config-keydiff.sh --help
#
# `check` prints one line when the config is missing one or more default keys
# and prints nothing at all otherwise, so it composes with the existing watcher
# state-check contract instead of needing a schedule of its own. `arm` writes
# state/nm-config-keydiff.check.sh and binds its bytes with fm-check-register.sh,
# so the watcher dispatches it on its normal FM_CHECK_INTERVAL cadence and turns
# its one line into a `check:` wake. `disarm` removes the shim, its trust
# binding, and the report record.
#
# The signal this check exists to raise: a no-mistakes upgrade ships new default
# settings, and a long-lived operator config that predates them keeps running
# without them - the operator has no sign the config silently missed a setting
# the new build now expects. The check names the top-level keys the installed
# binary embeds as defaults that the operator's config never sets. The
# adopt-or-ignore decision stays the operator's; this check only reports.
#
# How the default keys are read: the no-mistakes binary embeds its complete
# default config as one contiguous readable template. `strings` on the real
# binary is scanned for the template's header marker line
# "# no-mistakes global configuration", and the template block runs from that
# marker to the first line that is blank, a comment, a top-level key, or
# indented content and nothing else - so the bound is dynamic, never a line
# number, and the shell-completion scripts and json tags that follow the
# template in every cobra-built binary cannot leak into the key set. Top-level
# keys are then the lines of that block matching `^[a-z_]+:`, compared against
# the same shape read from the operator's config (commented lines excluded).
#
# The real binary is resolved the way the operator's shell resolves it. When
# PATH answers with one of firstmate's guard shims (bin/shims puts them first in
# a worker pane), the shim itself is a script with no embedded template, so the
# PATH is walked skipping firstmate shim directories to reach the real tool, the
# same walk the guard shim uses before exec'ing it, with the standard
# no-mistakes install location as a last resort.
#
# What this script never does: it reports, and it repairs nothing. It never
# writes, edits, merges, or reformats the operator's config, and it does not
# compare values or nested keys - only the presence of top-level keys. Every
# probe is local (the binary and the config file only), so a check run never
# touches the network. It does not run no-mistakes itself.
#
# The check degrades quietly rather than crashing or spewing, because it runs
# under the watcher: an absent config means nothing to diff against (silent),
# and a missing or unparseable binary means the defaults are unknown (silent),
# so a host where no-mistakes is not installed at all never wakes firstmate.
#
# The report record state/.nm-config-keydiff is written on every successful
# check run and carries the whole key set the last report was made from, so the
# same missing-key finding is reported once rather than on every poll. A run
# that could not read the binary or its template leaves no record, so a later
# readable run always reports what it finds. Each probe is one local `strings`
# pass over the binary plus one read of the config, well inside
# FM_CHECK_TIMEOUT (default 30), so no interval gate is needed.
#
# The config path is $HOME/.no-mistakes/config.yaml, overridable with FM_NM_CONFIG
# for tests, mirroring how FM_TOOL_UPDATE_NOW overrides the tool-update clock.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORD="$STATE/.nm-config-keydiff"
CHECK_ID=nm-config-keydiff
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
RECORD_SCHEMA=fm-nm-config-keydiff-v1
NM_CONFIG="${FM_NM_CONFIG:-$HOME/.no-mistakes/config.yaml}"
# The report can carry the config path plus every missing default key and stays
# comfortably within the watcher digest's line shape; capped through the same
# shared cut the digests use so an over-long report says it was cut.
MAX_LINE=1000
TEMPLATE_MARKER='# no-mistakes global configuration'

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-nm-config-keydiff.sh [check]   report missing no-mistakes default config keys (silent when current)
  fm-nm-config-keydiff.sh arm       write and register state/nm-config-keydiff.check.sh
  fm-nm-config-keydiff.sh disarm    remove the check shim, its trust binding, and the record
  fm-nm-config-keydiff.sh --help    print this help

The check diffs the top-level keys the installed no-mistakes binary embeds as
defaults against the keys set in $HOME/.no-mistakes/config.yaml (FM_NM_CONFIG
overrides the path for tests) and reports the default keys the config lacks.
It never writes the config; the adopt-or-ignore decision stays the operator's.
EOF
}

die_usage() {
  printf 'fm-nm-config-keydiff: %s\n' "$1" >&2
  usage >&2
  exit 2
}

# --- binary resolution ------------------------------------------------------

# Follow a path through its whole symlink chain, so `command -v` results and
# PATH entries resolve to the file they actually name.
nm_resolve_links() {
  local p=$1 link links=0
  while [ -L "$p" ] && [ "$links" -lt 10 ]; do
    link=$(readlink "$p" 2>/dev/null) || break
    case "$link" in
      /*) p=$link ;;
      *) p="${p%/*}/$link" ;;
    esac
    links=$((links + 1))
  done
  printf '%s\n' "$p"
}

# True when <path> is one of firstmate's guard shims, identified by file name
# after symlink resolution, because a shim is a bash script that execs the real
# tool and carries none of its embedded data.
nm_is_guard_shim() {
  case "$1" in
    *fm-nm-guard-shim.sh|*fm-worktree-guard-shim.sh) return 0 ;;
  esac
  return 1
}

# Resolve the actual no-mistakes binary the operator's shell reaches. When
# PATH answers with a firstmate guard shim, walk PATH the way the shim itself
# does - every entry, skipping firstmate shim directories and other guard
# shims - then fall back to the standard no-mistakes install locations.
# Prints the resolved path and returns 0, or returns 1 when nothing resolves.
nm_binary_resolve() {
  local entry candidate
  local IFS=:
  for entry in ${PATH:-}; do
    [ -n "$entry" ] || entry=.
    candidate=$(nm_resolve_links "$entry/no-mistakes")
    [ -f "$candidate" ] && [ -x "$candidate" ] || continue
    nm_is_guard_shim "$candidate" && continue
    printf '%s\n' "$candidate"
    return 0
  done
  for candidate in "$HOME/.no-mistakes/bin/no-mistakes" \
    /usr/local/bin/no-mistakes /opt/homebrew/bin/no-mistakes; do
    candidate=$(nm_resolve_links "$candidate")
    [ -f "$candidate" ] && [ -x "$candidate" ] || continue
    nm_is_guard_shim "$candidate" && continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

# --- default and config keys ------------------------------------------------

# The embedded template block: from the header marker to the first line that is
# not blank, a comment, a top-level key, or indented content. That bound keeps
# the shell-completion scripts and other embedded strings that follow the
# template in the binary out of the key set, and never depends on a line
# number, so a future build that moves the template is still read correctly.
nm_template() {
  local bin=$1
  strings "$bin" 2>/dev/null | awk -v marker="$TEMPLATE_MARKER" '
    index($0, marker) == 1 { in_block = 1; next }
    in_block == 0 { next }
    /^[ \t]*$/ { print; next }
    /^#/ { print; next }
    /^[a-z_]+:/ { print; next }
    /^[ \t]/ { print; next }
    { exit }
  '
}

# Top-level keys of a YAML config read from stdin: uncommented lines matching
# `^[a-z_]+:`, key only, unique and sorted. The shape is shared by the embedded
# template and the operator's config, commented lines excluded by the pattern.
nm_keys() {
  grep -E '^[a-z_]+:' | sed 's/:.*//' | LC_ALL=C sort -u
}

# Default keys absent from the operator's config, in sorted order as one
# newline-separated set. Both inputs are `nm_keys` output: <defaults> then
# <config>.
nm_missing() {
  local defaults=$1 config=$2
  awk 'NR == FNR { cfg[$0] = 1; next } !($0 in cfg) { print }' \
    <(printf '%s\n' "$config") <(printf '%s\n' "$defaults")
}

# --- report record ----------------------------------------------------------

RECORD_REPORTED=

record_read() {
  local line first=1
  RECORD_REPORTED=
  [ -f "$RECORD" ] || return 0
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      first=0
      [ "$line" = "$RECORD_SCHEMA" ] || return 0
      continue
    fi
    case "$line" in
      reported=*) RECORD_REPORTED=${line#reported=} ;;
    esac
  done < "$RECORD"
  return 0
}

record_write() {
  local reported=$1 tmp
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'reported=%s\n' "$reported"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# --- actions ----------------------------------------------------------------

action_check() {
  local bin config defaults config_keys missing found line

  # An absent config is not a finding: there is nothing to diff against. (Unlike
  # arm, check does not insist the config exist - a host without one simply has
  # no config to be missing keys.)
  [ -f "$NM_CONFIG" ] || return 0
  config=$(cat -- "$NM_CONFIG" 2>/dev/null) || return 0
  config_keys=$(printf '%s\n' "$config" | nm_keys) || return 0
  bin=$(nm_binary_resolve) || {
    rm -f -- "$RECORD" 2>/dev/null || true
    return 0
  }
  defaults=$(nm_template "$bin" | nm_keys) || {
    rm -f -- "$RECORD" 2>/dev/null || true
    return 0
  }
  # No template block readable means the defaults are unknown, so nothing can be
  # reported and no prior finding remains authoritative.
  if [ -z "$defaults" ]; then
    rm -f -- "$RECORD" 2>/dev/null || true
    return 0
  fi
  missing=$(nm_missing "$defaults" "$config_keys") || return 0
  found=
  if [ -n "$missing" ]; then
    found=$(printf '%s\n' "$missing" \
      | awk '{ out = (out ? out ", " : "") $0 } END { print out }') || found=
  fi

  record_read
  line=
  if [ -n "$found" ]; then
    fm_cap_line_var "no-mistakes config $NM_CONFIG is missing default keys: $found" "$MAX_LINE"
    line=$FM_LINE_CAP_LINE
  fi

  # Report before recording, so a record that cannot be written costs a repeated
  # report rather than a lost one.
  if [ -n "$line" ] && [ "$RECORD_REPORTED" != "$found" ]; then
    printf '%s\n' "$line"
  fi
  record_write "$found" || true
  return 0
}

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory and a relative spelling would send the check to a
# different home, or to none at all.
shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-nm-config-keydiff.sh - no-mistakes config keydiff poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-nm-config-keydiff.sh") check"
}

# Write the shim the way this repo writes its other trusted check shim: the
# guards run before anything is written, so a symlink at the shim path is
# refused instead of followed, and the bytes arrive by rename so the watcher
# never reads a half-written shim and rejects it as unauthenticated.
SHIM_WRITE_TMP=

shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-nm-config-keydiff-check.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

# Keep a byte copy of a shim that is already in place, so a failed arm can put
# back the shim a working home was already using rather than an equivalent
# rewrite. The trust binding is over the bytes, so a rewrite would satisfy it
# too, but a home that was armed stays armed with what it had.
shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-nm-config-keydiff-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

ARM_BACKUP=

# An unregistered shim is not inert: the watcher rejects it on every cycle and
# wakes firstmate about unauthenticated state checks. So the one rule after a
# failed or interrupted arm is that the home never holds a shim without a
# matching trust binding. The shim a working home had is put back and kept only
# when it is still bound; otherwise the shim goes, so the home is plainly not
# armed and the failure is the only thing the operator has to act on.
arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM"
}

# shellcheck disable=SC2329  # Registered by action_arm's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-nm-config-keydiff: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

# Arming is a deliberate operator action and fails loudly, unlike check, which
# degrades quietly. The two things the check reads must exist, or a check armed
# here could never report anything and the operator should hear that now.
action_arm() {
  local want home bin defaults
  mkdir -p "$STATE" || return 1
  if [ ! -f "$NM_CONFIG" ]; then
    printf 'fm-nm-config-keydiff: no no-mistakes config at %s\n' "$NM_CONFIG" >&2
    return 1
  fi
  bin=$(nm_binary_resolve) || {
    printf 'fm-nm-config-keydiff: no no-mistakes binary found on PATH\n' >&2
    return 1
  }
  defaults=$(nm_template "$bin" | nm_keys) || defaults=
  if [ -z "$defaults" ]; then
    printf 'fm-nm-config-keydiff: no default config template readable in %s\n' "$bin" >&2
    return 1
  fi
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-nm-config-keydiff: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-nm-config-keydiff: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  # The shim exists unbound from the rename until the register returns, so a
  # signal in that window rolls back the same way a failure does.
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-nm-config-keydiff: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-nm-config-keydiff: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
