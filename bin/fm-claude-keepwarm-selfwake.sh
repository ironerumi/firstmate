#!/usr/bin/env bash
# Claude Stop-owned supervisor keep-warm self-wake (asyncRewake hook).
#
# Registered in tracked .claude/settings.json as a Stop command hook with
# "asyncRewake": true. Claude Code fires it in the background on EVERY Stop of
# a Claude primary session, so each turn boundary is the anchor for one
# deterministic self-wake: the hook sleeps until
#
#   deadline = this turn's end + fm_keepwarm_interval_secs
#
# and, if no real turn has happened by then, exits 2 with a marked benign
# banner on stderr, which is Claude's native idle wake ("Stop hook feedback").
# The resulting model turn is what keeps the session's prompt cache warm, and
# its own Stop re-arms the next self-wake, so an idle Claude supervisor takes a
# real turn at least once per interval for as long as the session lives. The
# interval is FM_NM_KEEPWARM_SECS clamped to the fleet-wide 3000-second cap
# (bin/fm-keepwarm-cadence-lib.sh owns both), so the turn always lands inside
# Claude's one-hour cache window.
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
# hook again. The new firing records itself as the current owner in
# state/.keepwarm-selfwake (line 1 the anchor epoch, line 2 the owning pid,
# line 3 the deadline epoch), terminates the superseded sleeper, and the
# sleeper independently re-reads that record on every poll and stands down the
# moment it is no longer the owner. Claude does not dedupe async hooks, so two
# firings for one Stop simply race to the same record and the loser exits 0.
# The record is private state: bin/fm-teardown.sh never touches it, and a
# missing or malformed record is harmless because the next Stop rewrites it.
#
# Scope and gates, each an exit 0:
#   - Only a genuine primary checkout (plain checkout or validly marked
#     secondmate home): the exact fm-turnend-guard.sh scope. Child crew and
#     scout worktrees stay inert; a crew's own keep-warm is
#     bin/fm-nm-keepwarm-lib.sh.
#   - Only when THIS session's harness ancestor holds state/.lock, and that
#     lock owner is a Claude process. A lock-refused second session, a dead or
#     missing lock, or a non-Claude harness that loaded these settings is not a
#     live Claude supervisor, so there is nothing to keep warm. No lock
#     recovery is attempted here; bin/fm-claude-stop-autoarm.sh owns that.
#   - Only on a Claude-delivered payload: Cursor loads the tracked Claude
#     settings too and has no asyncRewake, so this sleep would hold its turn
#     open (bin/fm-hook-host-lib.sh). The settings entry itself stands down
#     under Grok's markers.
#   - FM_NM_KEEPWARM_SECS=0 disables the self-wake for the home.
#   Away mode is NOT a gate: an away session is the longest idle stretch of
#   all, and the banner carries the operational-input prefix so the /afk
#   contract reads it as an internal input rather than the captain's return.
#
# The wake is benign by construction. The banner asks for one acknowledgement
# line and nothing else: no wake drain, no steer, no decision, no gate action,
# no captain message. Nothing here queues a wake, writes a status line, or
# reaches the captain. If the deadline passes while a real turn is already in
# progress, Claude delivers the feedback when that turn ends and the extra
# turn is one more benign acknowledgement.
#
# Deadline check at fire time repeats every gate, so a session whose lock
# changed hands or whose harness died while the hook slept exits 0 silently.
# Exit 0 is always silent; exit 2 carries the banner on stderr and nothing on
# stdout.
#
# Environment:
#   FM_NM_KEEPWARM_SECS            requested quiet interval, default 1800, clamped to 3000; 0 disables
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MARKER="$STATE/.keepwarm-selfwake"
POLL=30

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
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
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0

# --- scope: genuine primary checkout only -----------------------------------
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- cadence: disabled home ----------------------------------------------------
INTERVAL=$(fm_keepwarm_interval_secs)
[ "$INTERVAL" -gt 0 ] || exit 0

# --- identity: this session owns the lock, and it is a Claude session ----------
lock_pid_is_claude() {  # <pid>
  local comm args
  comm=$(ps -o comm= -p "$1" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$1" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args" || return 1
  [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ]
}

# The lock pid seen at arm time is pinned: a lock that later names a different
# pid means the session that armed this wake is no longer the supervisor.
LOCK_PID=''
live_claude_supervisor() {
  local lock_pid
  fm_session_lock_owned_by_self "$STATE" || return 1
  lock_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$lock_pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -z "$LOCK_PID" ]; then
    LOCK_PID=$lock_pid
  else
    [ "$lock_pid" = "$LOCK_PID" ] || return 1
  fi
  lock_pid_is_claude "$lock_pid"
}

live_claude_supervisor || exit 0

# --- arm: record this firing as the owner and cancel the superseded sleeper ---
NOW=$(date +%s)
DEADLINE=$((NOW + INTERVAL))
PREV_PID=$(sed -n '2p' "$MARKER" 2>/dev/null | tr -d '[:space:]')
TMP=$(mktemp "$STATE/.keepwarm-selfwake.XXXXXX" 2>/dev/null) || exit 0
if ! printf '%s\n%s\n%s\n' "$NOW" "$$" "$DEADLINE" > "$TMP" || ! mv -f "$TMP" "$MARKER"; then
  rm -f "$TMP" 2>/dev/null
  exit 0
fi
case "$PREV_PID" in
  ''|*[!0-9]*) ;;
  "$$") ;;
  *)
    # Only ever terminate a process that is provably a sleeping sibling of this
    # hook, never a recycled pid.
    case "$(ps -o args= -p "$PREV_PID" 2>/dev/null)" in
      *fm-claude-keepwarm-selfwake*) kill -TERM "$PREV_PID" 2>/dev/null || true ;;
    esac
    ;;
esac

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
  live_claude_supervisor || exit 0
done

# --- fire: the native idle wake, re-gated at the deadline ----------------------
still_owner || exit 0
live_claude_supervisor || exit 0
BODY='Keep-warm turn - no supervision event, decision, or captain message is attached. Print one short acknowledgement line and end the turn. Do not run the wake drain, steer a worker, answer a decision, touch a parked gate, change any record, or message the captain; this turn exists only to keep this session prompt cache warm, and any real event still arrives through its own wake.'
fm_operational_input_encode keep-warm "$BODY" BANNER || exit 0
printf '%s\n' "$BANNER" >&2
exit 2
