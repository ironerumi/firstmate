#!/usr/bin/env bash
# fm-guard-refusal-lib.sh - makes a worker-pane guard refusal report itself.
#
# bin/fm-worktree-guard-lib.sh and bin/fm-nm-guard-shim.sh each render a refusal
# to the worker's terminal. A refusal the worker quietly routes around (the
# 2026-09-28 --no-verify commits) never reaches firstmate that way, so every
# refusal also appends ONE keyed `blocked:` line to the task's status record,
# which wakes firstmate whatever the worker does next.
#
# Public interface:
#   fm_guard_refusal_report <status-file> <tool> <code>
#       Appends `blocked [at=<epoch>] [key=guard-<code>]: ...` unless that key is
#       already open, so a retry loop cannot flood the log. A `resolved` line for
#       the key closes it, and the next refusal then reports again. An empty
#       status file argument, or any write failure, is a silent no-op: reporting
#       must never change the refusal or refuse work.
#
# The line names the tool and code only, never the refusal text: the reason can
# carry a no-mistakes run id, and bin/fm-nm-guard-lib.sh treats a status line
# mentioning that id as the worker's own failure report, so echoing the reason
# would let the guard's refusal satisfy the guard.
#
# The line grammar is owned by bin/fm-classify-lib.sh; this file only writes it.

# 0 when <status-file> already holds an OPEN blocked line for <key>.
fm_guard_refusal_key_open() { # <status-file> <key>
  [ -f "$1" ] || return 1
  awk -v token="[key=$2]" '
    {
      colon = index($0, ":")
      head = colon ? substr($0, 1, colon - 1) : $0
      if (index(head, token) == 0) next
      verb = $1
      sub(/:$/, "", verb)
      if (verb == "blocked") open = 1
      else if (verb == "resolved") open = 0
    }
    END { exit open ? 0 : 1 }
  ' "$1" 2>/dev/null
}

fm_guard_refusal_report() { # <status-file> <tool> <code>
  local status=${1:-} tool=${2:-} code=${3:-} key epoch
  [ -n "$status" ] && [ -n "$code" ] || return 0
  key="guard-$code"
  fm_guard_refusal_key_open "$status" "$key" && return 0
  epoch=$(date +%s 2>/dev/null) || return 0
  printf 'blocked [at=%s] [key=%s]: guard refused %s [%s]; check whether the guard or the worker is wrong\n' \
    "$epoch" "$key" "$tool" "$code" >> "$status" 2>/dev/null || true
  return 0
}
