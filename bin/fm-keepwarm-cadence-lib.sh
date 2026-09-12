# shellcheck shell=bash
# fm-keepwarm-cadence-lib.sh - the one keep-warm cadence shared by every
# Claude keep-warm path.
# Usage: . bin/fm-keepwarm-cadence-lib.sh
#
# Two paths keep a Claude prompt cache warm: bin/fm-nm-keepwarm-lib.sh warms a
# crewmate waiting out its own no-mistakes run, and
# bin/fm-claude-keepwarm-selfwake.sh warms an idle Claude supervisor session
# (the main firstmate or a secondmate primary). Both read the same knob and are
# bound by the same ceiling, so the longest gap between two real model turns
# on any kept-warm Claude session is one value fleet-wide:
#
#   - FM_NM_KEEPWARM_SECS (default 1800) is the requested quiet interval.
#     0 disables keep-warm on every path.
#   - FM_KEEPWARM_CAP_SECS (3000, not configurable) is the ceiling. Claude's
#     extended prompt cache lives one hour after the last turn; 50 minutes
#     leaves a ten-minute margin for a wake that lands late (a hook scheduled
#     under load, a slow turn start) so the real turn still lands inside the
#     cache window. A request above the cap is clamped, never refused, so a
#     home that asked for a longer quiet interval silently gets the longest
#     safe one instead of a cold cache.
#
# This library is deliberately dependency-free so the Stop hook can source it
# without pulling the crew library's backend and classifier dependencies into
# every turn boundary.

FM_NM_KEEPWARM_SECS_DEFAULT=1800
FM_KEEPWARM_CAP_SECS=3000

# The effective quiet interval: FM_NM_KEEPWARM_SECS when it is a whole number
# of seconds, the default otherwise, clamped to the cap. Prints 0 when keep-warm
# is disabled.
fm_keepwarm_interval_secs() {
  local v=${FM_NM_KEEPWARM_SECS:-$FM_NM_KEEPWARM_SECS_DEFAULT}
  case "$v" in ''|*[!0-9]*) v=$FM_NM_KEEPWARM_SECS_DEFAULT ;; esac
  [ "$v" -le "$FM_KEEPWARM_CAP_SECS" ] || v=$FM_KEEPWARM_CAP_SECS
  printf '%s' "$v"
}
