#!/usr/bin/env bash
# fm-task-inbox-ladder.sh - the one durable state record per steering-inbox
# message (fork issue #48: re-ring on state transition, not on a timer alone).
#
# Fork-owned seam sourced by bin/fm-task-inbox-lib.sh, which keeps owning the
# inbox contract and the ladder decision (fm_task_inbox_due_action). This file
# owns only the record: its format, its atomic write, and the transitions that
# change it. Nothing else in the inbox keeps ladder state.
#
# One record, <task>.inbox/.ring-state, one line, tab separated:
#   <msg>\t<state>\t<count>\t<ring_at>\t<seen_at>
#     msg      basename of the oldest unhandled message the record describes
#     state    ringing | escalated
#     count    delivery attempts spent on msg
#     ring_at  epoch of the last delivery attempt
#     seen_at  epoch the worker was last seen busy while msg was ringing, else 0
#
# The record is valid only for the message it names. A message with no record,
# or whose name differs from the record's, is in the implicit `delivered`
# state, so a new oldest message is a fresh ladder by construction rather than
# by a reset someone must remember. `handled` is implicit too: an
# acknowledged message leaves the inbox root, and the record is removed once no
# unhandled message remains.
#
# Transitions, each driven by exactly one event and each ONE atomic rewrite:
#   delivered -> ringing    the watcher attempted delivery (record_ring)
#   ringing   -> ringing    a re-ring (record_ring: count + 1) or a busy
#                           sighting after a ring (note_inflight: seen_at)
#   ringing/delivered -> escalated   the stale wake was queued (record_escalated)
#   any       -> handled    the worker moved the message (record dropped)
# A busy sighting never acks, never touches the message, and only moves the
# re-arm point (see fm_task_inbox_due_action), so suppression cannot consume a
# row or change the idempotent re-handling semantics.
#
# Writes are temp-then-rename inside the inbox directory, so a reader never
# sees a partial record. A write failure returns 1 while the inbox exists and
# is a quiet no-op for a concurrently removed inbox; the watcher reports the
# failure through its one stale-wake path.
#
# Sourced by bin/fm-task-inbox-lib.sh; no side effects on source.

fm_task_inbox_ladder_path() {  # <state-dir> <task-id>
  printf '%s/%s.inbox/.ring-state' "$1" "$2"
}

# Print "<state> <count> <ring_at> <seen_at>" for <msg>: the record's own
# values when it names <msg>, else the implicit delivered state.
fm_task_inbox_ladder_read() {  # <state-dir> <task-id> <msg-basename>
  local path rec_msg="" state="" count="" ring_at="" seen_at=""
  path=$(fm_task_inbox_ladder_path "$1" "$2")
  IFS=$(printf '\t') read -r rec_msg state count ring_at seen_at 2>/dev/null < "$path" || true
  case "$state" in
    ringing|escalated) ;;
    *) rec_msg= ;;
  esac
  case "$count" in ''|*[!0-9]*) rec_msg= ;; esac
  case "$ring_at" in ''|*[!0-9]*) rec_msg= ;; esac
  case "$seen_at" in ''|*[!0-9]*) rec_msg= ;; esac
  if [ -n "$rec_msg" ] && [ "$rec_msg" = "$3" ]; then
    printf '%s %s %s %s' "$state" "$count" "$ring_at" "$seen_at"
  else
    printf 'delivered 0 0 0'
  fi
}

fm_task_inbox_ladder_write() {  # <state-dir> <task-id> <msg> <state> <count> <ring_at> <seen_at>
  local dir path tmp
  dir="$1/$2.inbox"
  path=$(fm_task_inbox_ladder_path "$1" "$2")
  [ -d "$dir" ] || return 0
  if [ ! -d "$path" ] \
    && tmp=$(mktemp "$dir/.ring-state.XXXXXX" 2>/dev/null) \
    && { printf '%s\t%s\t%s\t%s\t%s\n' "$3" "$4" "$5" "$6" "$7" > "$tmp"; } 2>/dev/null \
    && mv "$tmp" "$path" 2>/dev/null; then
    return 0
  fi
  [ -z "${tmp:-}" ] || rm -f "$tmp" 2>/dev/null || true
  [ -d "$dir" ] || return 0
  return 1
}

fm_task_inbox_ladder_drop() {  # <state-dir> <task-id>
  rm -f "$(fm_task_inbox_ladder_path "$1" "$2")" 2>/dev/null || true
}

# A delivery attempt was made: a failed ring or a composer-protected skip still
# consumes budget, so neither an unreadable pane nor a permanently blocked
# composer can retry silently forever.
fm_task_inbox_ladder_record_ring() {  # <state-dir> <task-id> <record-path>
  local base=${3##*/} state count ring_at seen_at
  IFS=" " read -r state count ring_at seen_at <<EOF
$(fm_task_inbox_ladder_read "$1" "$2" "$base")
EOF
  fm_task_inbox_ladder_write "$1" "$2" "$base" ringing "$((count + 1))" "$(date +%s)" 0
}

# The stale wake for <msg> is durably queued. Wake-before-record ordering
# favors at-least-once recovery: a crash or write failure can cause a rare
# duplicate wake, never a lost one. A dead-pane escalation never rang, so it
# records count 0.
fm_task_inbox_ladder_record_escalated() {  # <state-dir> <task-id> <record-path>
  local base=${3##*/} state count ring_at seen_at
  IFS=" " read -r state count ring_at seen_at <<EOF
$(fm_task_inbox_ladder_read "$1" "$2" "$base")
EOF
  fm_task_inbox_ladder_write "$1" "$2" "$base" escalated "$count" "$ring_at" "$seen_at"
}

# True while the oldest message is ringing and its busy sighting may be
# refreshed. A recent sighting gates the expensive pane capture and rewrite;
# after half a grace the watcher may refresh it again.
fm_task_inbox_ladder_sighting_due() {  # <ring-at> <seen-at> <grace-secs>
  local ring_at=$1 seen_at=$2 grace=$3 half now
  [ "$seen_at" = 0 ] && return 0
  half=$(( (grace + 1) / 2 ))
  now=$(date +%s)
  [ "$((now - seen_at))" -ge "$half" ]
}

fm_task_inbox_ladder_probe_due() {  # <state-dir> <task-id> <msg-basename> <grace-secs>
  local state count ring_at seen_at
  IFS=" " read -r state count ring_at seen_at <<EOF
$(fm_task_inbox_ladder_read "$1" "$2" "$3")
EOF
  [ "$state" = ringing ] || return 1
  fm_task_inbox_ladder_sighting_due "$ring_at" "$seen_at" "${4:-0}"
}

# The worker was busy while <msg> is ringing: re-arm the next ring from this
# sighting. Anything but a ringing record for <msg> is left untouched.
fm_task_inbox_ladder_note_inflight() {  # <state-dir> <task-id> <msg-basename> <grace-secs>
  local state count ring_at seen_at
  IFS=" " read -r state count ring_at seen_at <<EOF
$(fm_task_inbox_ladder_read "$1" "$2" "$3")
EOF
  [ "$state" = ringing ] || return 0
  fm_task_inbox_ladder_sighting_due "$ring_at" "$seen_at" "${4:-0}" || return 0
  fm_task_inbox_ladder_write "$1" "$2" "$3" ringing "$count" "$ring_at" "$(date +%s)"
}
