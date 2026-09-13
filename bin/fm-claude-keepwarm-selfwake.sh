#!/usr/bin/env bash
# Claude Stop-owned keep-warm self-wake (asyncRewake hook): the one keep-warm
# path for every Claude agent firstmate runs.
#
# Claude Code fires this hook in the background on EVERY Stop of a Claude
# session, so each turn boundary is the anchor for one deterministic self-wake:
# the hook sleeps until
#
#   deadline = this turn's end + fm_keepwarm_interval_secs
#
# and, if no real turn has happened by then, exits 2 with a marked benign
# banner on stderr, which is Claude's native idle wake ("Stop hook feedback").
# The resulting model turn is what keeps the session's prompt cache warm, and
# its own Stop re-arms the next self-wake, so an idle Claude session takes a
# real turn at least once per interval for as long as it lives. The interval
# is FM_NM_KEEPWARM_SECS clamped to the fleet-wide 3000-second cap
# (bin/fm-keepwarm-cadence-lib.sh owns both), so the turn always lands inside
# Claude's one-hour cache window.
#
# Two registrations, one script:
#   - Supervisors. Tracked .claude/settings.json registers the bare form for
#     the main firstmate and every secondmate primary. That form acts only in
#     a genuine primary home (bin/fm-primary-scope-lib.sh): a firstmate-repo
#     crew worktree loads the same tracked settings, and if its tracked entry
#     armed too the crew would carry two sleepers for one session, so the
#     bare form stands down there and the crew's own --task entry is the one
#     that fires. No session-lock check is made: any Claude session sitting in
#     a primary home is a cache worth keeping warm.
#   - Crews and scouts. bin/fm-spawn.sh injects `--task <id>` into the
#     per-task .claude/settings.local.json it already writes for every Claude
#     crew, with FM_STATE_OVERRIDE naming the spawning home's state dir, so the
#     hook works inside any project repo without that repo loading firstmate's
#     settings. Non-Claude crews never receive the entry and self-manage.
#
# Why a self-wake and not the watcher. A watcher-driven deadline was tried and
# went cold exactly during active supervision: the watcher's own wakes are
# absorbed as provably-working, and a busy watcher never reaches the idle
# primary. Anchoring the wake at the session's own turn boundary makes it
# independent of what the watcher is doing, keeps bin/fm-watch.sh free of any
# keep-warm reference, and replaces pane injection (and its composer-state
# guess) with the harness's native wake.
#
# Cancellation. Every real turn ends in a Stop, so every real turn fires this
# hook again. The new firing records itself as the current owner in the
# session's marker (line 1 the anchor epoch, line 2 the owning pid, line 3 the
# deadline epoch), and the sleeper independently re-reads that record on every
# poll and stands down the moment it is no longer the owner. The marker is
# state/.keepwarm-selfwake for a supervisor and state/.keepwarm-<id> for a
# crew, so sessions sharing one home never cancel each other. Marker
# cancellation covers all normal real turns. If a real turn crosses the exact
# deadline before its Stop rewrites the marker, at most one extra benign
# acknowledgement turn is delivered by design. Claude does not dedupe async
# hooks, so two firings for one Stop simply race to the same record and the
# loser exits 0.
# The supervisor marker is private state nothing else touches; the crew marker
# is removed by bin/fm-teardown.sh. A missing or malformed record is harmless
# because the next Stop rewrites it.
#
# Gates, each an exit 0:
#   - Only on a Claude-delivered payload: Cursor loads the tracked Claude
#     settings too and has no asyncRewake, so this sleep would hold its
#     synchronous stop hook open (bin/fm-hook-host-lib.sh). The tracked
#     settings entry itself stands down under Grok's markers.
#   - The bare form only in a genuine primary home, as above.
#   - FM_NM_KEEPWARM_SECS=0 disables the self-wake for the home.
#   Away mode is NOT a gate: an away session is the longest idle stretch of
#   all, and the banner carries the operational-input prefix so the /afk
#   contract reads it as an internal input rather than the captain's return.
#
# The wake is benign by construction. The banner asks for one acknowledgement
# line and nothing else: no wake drain, no steer, no decision, no gate action,
# no status line, no captain message. Nothing here queues a wake, writes a
# status line, or reaches the captain. If the deadline passes while a real
# turn is already in progress, Claude delivers the feedback when that turn
# ends.
#
# Exit 0 is always silent; exit 2 carries the banner on stderr and nothing on
# stdout.
#
# Usage: fm-claude-keepwarm-selfwake.sh [--task <id>]
#
# Environment:
#   FM_NM_KEEPWARM_SECS            requested quiet interval, default 1800, clamped to 3000; 0 disables
#   FM_HOME / FM_STATE_OVERRIDE    the home whose state dir holds the marker
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
POLL=30

TASK=''
case "${1:-}" in
  --task)
    TASK=${2:-}
    case "$TASK" in ''|*[!A-Za-z0-9._-]*) exit 0 ;; esac
    ;;
  '') ;;
  *) exit 0 ;;
esac
if [ -n "$TASK" ]; then
  MARKER="$STATE/.keepwarm-$TASK"
else
  MARKER="$STATE/.keepwarm-selfwake"
fi

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
# shellcheck source=bin/fm-keepwarm-cadence-lib.sh
. "$SCRIPT_DIR/fm-keepwarm-cadence-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"

# A superseding firing terminates this sleeper; stand down silently.
trap 'exit 0' TERM

# Consume the Stop payload once so a slow writer never wedges on a full pipe,
# and inspect its host before anything else runs.
PAYLOAD=$(cat 2>/dev/null || true)
command -v jq >/dev/null 2>&1 || exit 0
if ! printf '%s' "$PAYLOAD" | jq -e '
  type == "object" and
  ((has("cursor_version") | not) or
    (has("cursor_version") and (.cursor_version | type == "string")))
' >/dev/null 2>&1; then
  exit 0
fi
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0

# --- scope: the bare form acts only in a genuine primary home -------------------
if [ -z "$TASK" ]; then
  fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0
fi
[ -d "$STATE" ] || exit 0

# --- cadence: disabled home ----------------------------------------------------
INTERVAL=$(fm_keepwarm_interval_secs)
[ "$INTERVAL" -gt 0 ] || exit 0

# --- arm: record this firing as the owner and cancel the superseded sleeper ---
NOW=$(date +%s)
DEADLINE=$((NOW + INTERVAL))
TMP=$(mktemp "$MARKER.XXXXXX" 2>/dev/null) || exit 0
if ! printf '%s\n%s\n%s\n' "$NOW" "$$" "$DEADLINE" > "$TMP" || ! mv -f "$TMP" "$MARKER"; then
  rm -f "$TMP" 2>/dev/null
  exit 0
fi

still_owner() {
  [ "$(sed -n '2p' "$MARKER" 2>/dev/null | tr -d '[:space:]')" = "$$" ]
}

# --- sleep to the deadline, standing down the moment a real turn supersedes ---
while :; do
  NOW=$(date +%s)
  REMAINING=$((DEADLINE - NOW))
  [ "$REMAINING" -gt 0 ] || break
  if [ "$REMAINING" -lt "$POLL" ]; then sleep "$REMAINING"; else sleep "$POLL"; fi
  still_owner || exit 0
done

# --- fire: the native idle wake, re-checked at the deadline ---------------------
still_owner || exit 0
BODY='Keep-warm turn - no supervision event, decision, pipeline gate, or captain message is attached. Print one short acknowledgement line and end the turn. Do not run the wake drain, steer a worker, answer a decision, respond to a validation gate, append a status line, change any record, or message the captain; this turn exists only to keep this session prompt cache warm, and any real event still arrives through its own wake.'
fm_operational_input_encode keep-warm "$BODY" BANNER || exit 0
printf '%s\n' "$BANNER" >&2
exit 2
