#!/usr/bin/env bash
# fm-guard-refusal-lib.sh - makes a worker-pane guard refusal report itself.
#
# bin/fm-nm-guard-shim.sh renders a refusal to the worker's terminal. A refusal
# the worker quietly routes around never reaches firstmate that way, so every
# refusal attempts to append one keyed `blocked:` line to the task's status
# record, which wakes firstmate whatever the worker does next when the write
# succeeds. Deduplication is best effort because a concurrent claim, resolution,
# or status-file reset can produce one duplicate, but those races do not lose
# the report while the status record remains writable.
#
# Public interface:
#   fm_guard_refusal_report <status-file> <tool> <code>
#       Attempts to append `blocked [at=<epoch>] [key=guard-<code>]: ...` unless
#       that key is already open, so a retry loop normally cannot flood the log.
#       A `resolved` line for the key closes it, and the next refusal then reports
#       again. An empty status file argument, or any write failure, is a silent
#       no-op: reporting must never change the refusal or refuse work.
#
# The line names the tool and code only, never the refusal text: the reason can
# carry a no-mistakes run id, and bin/fm-nm-guard-lib.sh treats a status line
# mentioning that id as the worker's own failure report, so echoing the reason
# would let the guard's refusal satisfy the guard.
#
# The line grammar is owned by bin/fm-classify-lib.sh; this file only writes it.

fm_guard_refusal_claim() { # <status-file> <key>
  local status=$1 key=$2 generation sentinel
  case "$status" in
    /*) ;;
    *) status="$(pwd -P)/$status" ;;
  esac
  if [ -f "$status" ]; then
    generation=$(awk -v token="[key=$key]" '
      {
        colon = index($0, ":")
        head = colon ? substr($0, 1, colon - 1) : $0
        if (index(head, token) == 0) next
        verb = $1
        sub(/:$/, "", verb)
        if (verb == "resolved") count++
      }
      END { print count + 0 }
    ' "$status" 2>/dev/null) || return 1
  else
    generation=0
  fi
  case "$generation" in
    ''|*[!0-9]*) return 1 ;;
  esac
  sentinel="$status.$key.$generation.claim"
  ( set -C; : > "$sentinel" ) 2>/dev/null && return 0
  # A prior claimant may have left this generation's sentinel behind after the
  # status file was reset, or before it reached the append. Only take that
  # sentinel over when the current record has no open blocker; a failed create
  # for any other reason remains a quiet no-op.
  [ -e "$sentinel" ] || return 1
  if [ -f "$status" ]; then
    local open
    open=$(awk -v token="[key=$key]" '
      {
        colon = index($0, ":")
        head = colon ? substr($0, 1, colon - 1) : $0
        if (index(head, token) == 0) next
        verb = $1
        sub(/:$/, "", verb)
        if (verb == "blocked") open = 1
        else if (verb == "resolved") open = 0
      }
      END { print open ? "yes" : "no" }
    ' "$status" 2>/dev/null) || return 1
    [ "$open" = no ] || return 1
  fi
  : > "$sentinel" 2>/dev/null
}

fm_guard_refusal_report() { # <status-file> <tool> <code>
  local status=${1:-} tool=${2:-} code=${3:-} key epoch
  [ -n "$status" ] && [ -n "$code" ] || return 0
  key="guard-$code"
  epoch=$(date +%s 2>/dev/null) || return 0
  fm_guard_refusal_claim "$status" "$key" || return 0
  printf 'blocked [at=%s] [key=%s]: guard refused %s [%s]; check whether the guard or the worker is wrong\n' \
    "$epoch" "$key" "$tool" "$code" >> "$status" 2>/dev/null || true
  return 0
}
