#!/usr/bin/env bash
# Ring-time re-classification and deterministic acknowledgement of wakes that no
# longer need a model turn (fork issues #45 and #46).
#
# bin/fm-claude-stop-autoarm.sh runs this once an arm closes with an actionable
# wake, immediately before it would ring the model. The watcher classified each
# queued row when it surfaced it; a handling turn can be minutes long, and the
# state a row described may have cleared by the time the next ring is delivered
# (the model's own steer put the crew back to work). This script re-asks the one
# authoritative question, crew_is_provably_working (bin/fm-classify-lib.sh),
# at ring time. When EVERY queued row is answered, it runs the same two drain
# calls the away daemon runs (bin/fm-supervise-daemon.sh handle_durable_wakes):
# present, then --ack-through with the recovery generation the presentation
# printed. The model never sees a turn it would only have spent copying that ack.
#
# Ack-class row, deliberately narrow; anything unproven rings as it does today:
#   - signal row keyed <task>.turn-ended, payload "signal: ...", task provably
#     working now. A captain-relevant status file never qualifies (its own row
#     is keyed <task>.status), and neither does a needs-decision payload.
#   - stale row whose payload is exactly "stale: <window>" (the first-sight
#     form), task provably working now. Every enriched stale form (possible
#     wedge, declared wait recheck, unavailable endpoint, unread steer) rings.
#   - never check or heartbeat rows.
#
# Nothing is dropped silently. The drain consumes unread status presentation as
# a side effect, so after running it this script requires the presentation to
# hold nothing but the queued rows and the acknowledgement line; any other
# content (status lines, open decisions, guard warnings, a row that arrived
# meanwhile) is printed to stdout, exit 3, and the caller carries it into the
# rewake banner. Every acknowledged row is recorded verbatim in
# state/.wake-autoack.log (bounded) and the caller's banner names that file.
#
# Gate: config/wake-autoack must exist. Absent, the script exits 1 untouched.
#
# Exit codes:
#   0  every queued row was ack-class; presented and acknowledged, logged
#   1  nothing done (gate off, empty queue, or any row not ack-class); no drain ran
#   3  the drain ran but acknowledgement was not safe or failed; the captured
#      presentation is on stdout and the rows stay queued
#
# Environment (test seams, like FM_CREW_STATE_BIN):
#   FM_WAKE_AUTOACK_DRAIN      drain script to run (default bin/fm-wake-drain.sh)
#   FM_WAKE_AUTOACK_LOG_LINES  log lines kept (default 200)
set -u

usage() {
  cat <<'EOF'
Usage: fm-wake-autoack.sh

Run by the Claude Stop hook before it rings the model. Exit 0: every queued
wake row no longer needs a turn and was acknowledged; 1: nothing done; 3: the
presentation needs the model (printed on stdout). Requires config/wake-autoack.
EOF
}

if [ "$#" -gt 0 ]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DRAIN="${FM_WAKE_AUTOACK_DRAIN:-$SCRIPT_DIR/fm-wake-drain.sh}"
LOG="$STATE/.wake-autoack.log"

[ -e "$CONFIG/wake-autoack" ] || exit 1

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

# 0 when <kind> <key> <payload> no longer needs a model turn.
row_is_ack_class() {
  local kind=$1 key=$2 payload=$3 task
  case "$kind" in
    signal)
      case "$key" in *.turn-ended) task=${key%.turn-ended} ;; *) return 1 ;; esac
      case "$payload" in 'signal: '*) ;; *) return 1 ;; esac
      ;;
    stale)
      [ "$payload" = "stale: $key" ] || return 1
      task=$(window_to_task "$key" "$STATE")
      ;;
    *) return 1 ;;
  esac
  case "$task" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  crew_is_provably_working "$task"
}

[ -s "$FM_WAKE_QUEUE" ] || exit 1
rows=$(awk -F '\t' 'NF >= 5 && $2 ~ /^[0-9]+$/' "$FM_WAKE_QUEUE") || exit 1
[ -n "$rows" ] || exit 1

tab=$(printf '\t')
max_seq=0
while IFS="$tab" read -r _epoch seq kind key payload _rest; do
  row_is_ack_class "$kind" "$key" "$payload" || exit 1
  [ "$seq" -le "$max_seq" ] || max_seq=$seq
done <<EOF
$rows
EOF

out=$(mktemp "$STATE/.wake-autoack.out.XXXXXX") || exit 1
err=$(mktemp "$STATE/.wake-autoack.err.XXXXXX") || { rm -f "$out"; exit 1; }
trap 'rm -f "$out" "$err"' EXIT

# Print whatever the drain presented, for the caller to carry to the model.
hand_back() {
  cat "$out" "$err"
  exit 3
}

"$DRAIN" >"$out" 2>"$err" || hand_back

ack_line=$(sed -n 's/^WAKE_ACK_REQUIRED: .*--ack-through \([0-9][0-9]*\) --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1 \2/p' "$err" | tail -n 1)
[ -n "$ack_line" ] || hand_back
ack_through=${ack_line%% *}
ack_generation=${ack_line#* }

# The presentation must hold only the rows, the acknowledgement line, and the
# guard's routine reminder that the rows it just presented are still queued
# (bin/fm-guard.sh prints it on every drain until the acknowledgement lands), and
# must cover exactly the rows that were classified: a row appended between the
# classification and the drain was never re-asked. Any other line, such as a
# watcher-down banner, goes to the model.
[ "$ack_through" = "$max_seq" ] || hand_back
[ -z "$(grep -v -e '^WAKE_ACK_REQUIRED: ' \
  -e '^WARNING: queued wakes pending - drain them with bin/fm-wake-drain.sh before anything else\.$' "$err")" ] || hand_back
awk -F '\t' -v max="$max_seq" 'NF < 5 || $2 !~ /^[0-9]+$/ || $2 + 0 > max { bad = 1 } END { exit bad }' "$out" || hand_back

"$DRAIN" --ack-through "$ack_through" --recovery-generation "$ack_generation" >"$out" 2>"$err" || hand_back

{
  stamp=$(date '+%Y-%m-%dT%H:%M:%S%z')
  printf '%s acknowledged through %s without a model turn (crew provably working at ring time):\n' "$stamp" "$ack_through"
  printf '%s\n' "$rows"
} >> "$LOG" 2>/dev/null || true
keep=${FM_WAKE_AUTOACK_LOG_LINES:-200}
case "$keep" in ''|*[!0-9]*) keep=200 ;; esac
if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt "$keep" ]; then
  tail -n "$keep" "$LOG" > "$LOG.tmp.$$" 2>/dev/null && mv -f "$LOG.tmp.$$" "$LOG" 2>/dev/null || rm -f "$LOG.tmp.$$"
fi
exit 0
