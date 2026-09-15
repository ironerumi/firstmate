# shellcheck shell=bash
# fm-keepwarm-cadence-lib.sh - the one keep-warm cadence for every Claude
# session firstmate keeps warm.
# Usage: . bin/fm-keepwarm-cadence-lib.sh
#
# bin/fm-claude-keepwarm-selfwake.sh is the only keep-warm path: it warms an
# idle Claude supervisor (the main firstmate or a secondmate primary) and every
# idle Claude crew or scout alike. This library owns the interval it sleeps
# toward, so the longest gap between two real model turns on any kept-warm
# Claude session is one value fleet-wide. In precedence order:
#
#   - FM_NM_KEEPWARM_SECS, when set to a non-empty value, is the requested
#     quiet interval. It is the per-process override and wins over the config
#     file below, which is what lets bin/fm-spawn.sh hand a spawned Claude crew
#     the spawning home's cadence through the crew's own environment.
#   - config/keepwarm-secs (local, gitignored, absent by default) is the
#     home-local cadence, read from this home's config dir as the first
#     non-empty line. Create it to set the cadence without exporting anything
#     into a shell or launch environment; it reaches a home's supervisor and,
#     through bin/fm-spawn.sh, its spawned crews alike.
#   - 1800 seconds (30 minutes) is the default when neither is set.
#
# A value that is not a whole number of seconds falls back to the default
# whichever source supplied it, and 0 disables keep-warm for every session of
# the home.
#
# FM_KEEPWARM_CAP_SECS (3000, not configurable) is the ceiling. Claude's
# extended prompt cache lives one hour after the last turn; 50 minutes leaves a
# ten-minute margin for a wake that lands late (a hook scheduled under load, a
# slow turn start) so the real turn still lands inside the cache window. A
# request above the cap is clamped, never refused, so a home that asked for a
# longer quiet interval silently gets the longest safe one instead of a cold
# cache.
#
# This library is deliberately dependency-free so the Stop hook can source it
# at every turn boundary without pulling anything else in.

FM_NM_KEEPWARM_SECS_DEFAULT=1800
FM_KEEPWARM_CAP_SECS=3000
FM_KEEPWARM_CONFIG_FILE="keepwarm-secs"

# The tracked code root this library was sourced from, used only when the
# caller names no home. Resolved once at source time, and without an external
# command, because the Stop hook sources this at every turn boundary.
FM_KEEPWARM_LIB_ROOT="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"

# Print this home's config dir, using the same home resolution as the rest of
# firstmate: FM_HOME, then FM_ROOT_OVERRIDE, then the wired code root, with
# FM_CONFIG_OVERRIDE ahead of all three.
fm_keepwarm_config_dir() {
  local home=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_KEEPWARM_LIB_ROOT}}
  printf '%s' "${FM_CONFIG_OVERRIDE:-$home/config}"
}

# Print the first non-empty line of this home's config/keepwarm-secs with its
# surrounding whitespace trimmed, or nothing when the home has no such file.
# Interior whitespace and anything non-numeric stay in the value so the
# interval resolver below rejects them rather than silently merging digits.
fm_keepwarm_config_secs() {
  local line
  local file
  file=$(fm_keepwarm_config_dir)/$FM_KEEPWARM_CONFIG_FILE
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    [ -n "$line" ] || continue
    printf '%s' "$line"
    return 0
  done < "$file"
}

# True when this home has a config/keepwarm-secs file to read.
fm_keepwarm_config_present() {
  [ -f "$(fm_keepwarm_config_dir)/$FM_KEEPWARM_CONFIG_FILE" ]
}

# The effective quiet interval: FM_NM_KEEPWARM_SECS when it is a whole number
# of seconds, else this home's config/keepwarm-secs when it holds one, else the
# default - clamped to the cap either way. Prints 0 when keep-warm is disabled.
fm_keepwarm_interval_secs() {
  local v=${FM_NM_KEEPWARM_SECS:-}
  if [ -z "$v" ]; then
    v=$(fm_keepwarm_config_secs)
  fi
  case "$v" in ''|*[!0-9]*) v=$FM_NM_KEEPWARM_SECS_DEFAULT ;; esac
  while [ "${#v}" -gt 1 ] && [ "${v#0}" != "$v" ]; do v=${v#0}; done
  [ "$v" -le "$FM_KEEPWARM_CAP_SECS" ] || v=$FM_KEEPWARM_CAP_SECS
  printf '%s' "$v"
}
