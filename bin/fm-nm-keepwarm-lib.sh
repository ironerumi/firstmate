# shellcheck shell=bash
# fm-nm-keepwarm-lib.sh - bounded keep-warm activation for a Claude crewmate
# whose no-mistakes validation has gone quiet.
# Usage: . bin/fm-nm-keepwarm-lib.sh
#
# Why this exists. A no-mistakes run can spend well over an hour in automated
# review, tests, and CI. Throughout that stretch the crewmate is correctly
# silent: the pipeline owns the work, the crew's status log stays sparse by
# contract, and the watcher absorbs the resulting stale wakes as
# provably-working (bin/fm-watch.sh's absorb-only-when-provably-working path).
# Nothing in that path ever reaches the worker, so a Claude Code crewmate can go
# from its last model turn to the pipeline's next gate without making a single
# turn in between. Its prompt cache expires in that gap, so the continuation
# re-reads the whole conversation prefix at full price and latency.
#
# What warms the cache is a MODEL TURN, not terminal activity: a repainted pane,
# a spinner, or a keystroke that never submits leaves the cache untouched. So
# both halves of this library are anchored on model-turn evidence:
#
#   - The quiet clock reads state/<id>.turn-ended, which the Claude crewmate's
#     own Stop hook touches at every turn boundary (bin/fm-spawn.sh installs it),
#     plus the status log and this library's own attempt marker. Pane churn is
#     deliberately NOT an activation: it is exactly the terminal-only signal that
#     would make an unwarmed session look warm.
#   - The activation itself is one ordinary line delivered through bin/fm-send.sh
#     - the same verified-submit path the pending-reply recovery re-send already
#     uses to revive an idle worker - so it produces a real turn rather than a
#     cosmetic one.
#
# Safety. The activation is benign by construction: it asks the worker to
# inspect its existing run and keep waiting. It is sent only while
# bin/fm-crew-state.sh reports `working` from an attributed `run-step`, so a
# parked gate, a terminal run, and a crew with no run at all are all excluded,
# and callers only reach the tick on a confirmed-idle pane so an active turn is
# never interrupted. Nothing here queues a wake, writes a status line, or
# otherwise reaches the captain.
#
# Idle is not the same as ready to receive, so the last gate before typing is
# the same composer guard the away-mode daemon's unattended injection enforces
# (bin/fm-supervise-daemon.sh): fm_backend_composer_state must read exactly
# `empty`. A crew-state verdict stays authoritative even after its pane has
# closed, and the watcher's idle check reads only busy signatures, so a pane
# that has dropped to a login shell, sits on an interactive prompt, or holds a
# half-typed line all reach this point looking idle - and typing into any of
# them either executes the line in a shell, answers a prompt with Enter, or
# corrupts pending text. fm-send.sh detects the bad shape only AFTER the
# keystrokes land, so the guard has to happen here, before them.
#
# Ownership. This adds no loop and no process: bin/fm-watch.sh calls the tick
# from the pane scan it already runs. All state is one marker file per task, so
# a watcher restart resumes the cadence instead of resetting or replaying it.
#
# Coverage. The crew harness decides eligibility and only claude opts in, so
# codex, opencode, pi, pi-signed, grok, and kimi crews keep their current
# behavior exactly. The primary harness is irrelevant: every supervision
# protocol drives the same watcher loop. The runtime backend is NOT irrelevant,
# because the composer guard has to read the live input row: tmux, herdr, orca,
# and cmux each expose a named classifier through fm_backend_composer_state,
# but zellij has none and reports `unknown` there (bin/fm-backend.sh), which is
# a refusal here. So a zellij-backed Claude crew defers on every evaluation and
# keep-warm is an unsupported no-op for it until zellij grows a verified
# composer classifier - deliberately, because refusing is the only safe answer
# for a pane whose input row cannot be read.

_FM_NM_KEEPWARM_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_NM_KEEPWARM_LIB_DIR="."
# FM_CREW_STATE_BIN, the overridable current-state reader, is defined here.
# shellcheck source=bin/fm-classify-lib.sh
. "$_FM_NM_KEEPWARM_LIB_DIR/fm-classify-lib.sh"
# Endpoint resolution from meta plus fm_backend_composer_state, the shared
# pre-submit input guard.
# shellcheck source=bin/fm-backend.sh
. "$_FM_NM_KEEPWARM_LIB_DIR/fm-backend.sh"

# Maximum quiet interval, in seconds, during an active no-mistakes run. 1800
# keeps every gap under Claude's one-hour extended cache window with room for a
# missed poll. 0 disables keep-warm entirely.
FM_NM_KEEPWARM_SECS_DEFAULT=1800

# First retry delay, in seconds, after an evaluation that did not deliver an
# activation. Only a delivered activation restarts the full interval; a refused
# send, an unusable composer, or a run that was not active is retried after
# this delay instead of after another full interval, which is what keeps the
# worst-case quiet gap at one interval plus one retry rather than two intervals.
# The delay doubles per consecutive miss of the SAME kind and is capped at the
# interval, so a permanently unreachable pane settles back to one evaluation per
# interval instead of probing forever at the short delay. A crew with no run to
# keep warm and a crew that could not be reached back off independently, and a
# real crew turn clears both histories: neither is evidence about the other, and
# a delay inherited from an unrelated earlier condition would spend the very
# interval this retry exists to protect.
FM_NM_KEEPWARM_RETRY_SECS_DEFAULT=300

# Harnesses whose crewmates get keep-warm activation, space separated and
# matched as a prefix (so `claude` covers a versioned `claude-*` recording).
# Claude is the only harness with evidence that a quiet validation costs a cold
# prompt cache; every other harness is a deliberate no-op until it has its own.
FM_NM_KEEPWARM_HARNESSES_DEFAULT='claude'

# The activation text. One line, read-only, and explicitly fenced against every
# action the crew must not take while the pipeline owns the branch: no second
# run, no push, no gate answer, and no status line (which would surface routine
# progress to the captain).
FM_NM_KEEPWARM_MESSAGE='Keep-warm check while your no-mistakes run is still active: run no-mistakes axi status to confirm it is still progressing, then keep waiting. Do not start or restart a run, do not push, do not abort or answer a gate on your own, and do not append a status line for this check.'

fm_nm_keepwarm_now() {
  if [ -n "${FM_NM_KEEPWARM_NOW:-}" ]; then
    printf '%s' "$FM_NM_KEEPWARM_NOW"
    return 0
  fi
  date +%s
}

# Portable mtime, or nothing when the path does not exist. The platform is
# resolved once at source time rather than per call: this runs inside the
# watcher's per-poll pane scan, which is the one place a per-call `uname` fork
# is measurable (bin/fm-watch.sh resolves its own stat flavor the same way).
if [ "$(uname)" = Darwin ]; then
  fm_nm_keepwarm_mtime() {  # <path>
    [ -e "$1" ] || return 1
    stat -f %m "$1" 2>/dev/null
  }
else
  fm_nm_keepwarm_mtime() {  # <path>
    [ -e "$1" ] || return 1
    stat -c %Y "$1" 2>/dev/null
  }
fi

fm_nm_keepwarm_interval_secs() {
  local v=${FM_NM_KEEPWARM_SECS:-$FM_NM_KEEPWARM_SECS_DEFAULT}
  case "$v" in ''|*[!0-9]*) v=$FM_NM_KEEPWARM_SECS_DEFAULT ;; esac
  printf '%s' "$v"
}

fm_nm_keepwarm_retry_secs() {
  local v=${FM_NM_KEEPWARM_RETRY_SECS:-$FM_NM_KEEPWARM_RETRY_SECS_DEFAULT}
  case "$v" in ''|*[!0-9]*|0) v=$FM_NM_KEEPWARM_RETRY_SECS_DEFAULT ;; esac
  printf '%s' "$v"
}

# The per-task attempt marker. Line 1 is the epoch the quiet clock currently
# runs from; line 2 counts consecutive evaluations that reached the crew but
# could not deliver, and line 3 counts consecutive evaluations that found no run
# to keep warm. The two never mix: "the pane refused the line" and "there was
# nothing to send yet" are different facts, and one must not lengthen the
# other's retry.
# A delivered activation records the real epoch; a miss records the epoch that
# makes the next evaluation fall due one retry delay later, so both cadences
# ride the same single anchor and a watcher restart resumes either one.
# The recorded epoch, not the file mtime, is authoritative so the cadence obeys
# one controllable clock.
fm_nm_keepwarm_marker() {  # <state> <id>
  printf '%s/.keepwarm-%s' "$1" "$2"
}

fm_nm_keepwarm_marker_epoch() {  # <state> <id>
  local f v
  f=$(fm_nm_keepwarm_marker "$1" "$2")
  [ -f "$f" ] || return 1
  v=$(head -1 "$f" 2>/dev/null | tr -d '[:space:]')
  case "$v" in ''|*[!0-9]*) fm_nm_keepwarm_mtime "$f" ;; *) printf '%s' "$v" ;; esac
}

fm_nm_keepwarm_marker_misses() {  # <state> <id> <undelivered|no-run>
  local f v
  f=$(fm_nm_keepwarm_marker "$1" "$2")
  [ -f "$f" ] || { printf '0'; return 0; }
  case "$3" in
    no-run) v=$(sed -n 3p "$f" 2>/dev/null | tr -d '[:space:]') ;;
    *) v=$(sed -n 2p "$f" 2>/dev/null | tr -d '[:space:]') ;;
  esac
  case "$v" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "$v" ;; esac
}

# Record an evaluation at <epoch> with the two consecutive-miss counts.
# Idempotent: the same evaluation replayed after a watcher restart rewrites the
# same anchor rather than adding state.
fm_nm_keepwarm_record() {  # <state> <id> <epoch> [undelivered] [no-run]
  printf '%s\n%s\n%s\n' "$3" "${4:-0}" "${5:-0}" \
    > "$(fm_nm_keepwarm_marker "$1" "$2")" 2>/dev/null
}

# Record a miss of <kind>: anchor the clock so the next evaluation falls due one
# retry delay from <now> instead of one full interval, with the delay doubled
# per consecutive miss of that kind and capped at the interval. <fresh>=1 drops
# both prior counts first, for a clock the crew itself restarted: the streak is
# only consecutive as long as nothing happened in between.
fm_nm_keepwarm_record_miss() {  # <state> <id> <now> <interval> <kind> <fresh>
  local state=$1 id=$2 now=$3 interval=$4 kind=$5 fresh=$6
  local undelivered no_run misses retry n
  undelivered=$(fm_nm_keepwarm_marker_misses "$state" "$id" undelivered)
  no_run=$(fm_nm_keepwarm_marker_misses "$state" "$id" no-run)
  if [ "$fresh" = 1 ]; then
    undelivered=0
    no_run=0
  fi
  case "$kind" in
    no-run) no_run=$((no_run + 1)); misses=$no_run ;;
    *) undelivered=$((undelivered + 1)); misses=$undelivered ;;
  esac
  retry=$(fm_nm_keepwarm_retry_secs)
  n=1
  while [ "$n" -lt "$misses" ] && [ "$retry" -lt "$interval" ]; do
    retry=$((retry * 2))
    n=$((n + 1))
  done
  [ "$retry" -le "$interval" ] || retry=$interval
  fm_nm_keepwarm_record "$state" "$id" "$((now - interval + retry))" \
    "$undelivered" "$no_run"
}

fm_nm_keepwarm_meta_value() {  # <meta> <key>
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

# 0 when task <id> is a crewmate whose recorded harness opts into keep-warm.
# A secondmate is idle by charter, so its quiet pane is healthy and never a
# cache-warming case.
fm_nm_keepwarm_eligible() {  # <state> <id>
  local state=$1 id=$2 meta harness kind h
  meta="$state/$id.meta"
  [ -f "$meta" ] || return 1
  kind=$(fm_nm_keepwarm_meta_value "$meta" kind)
  [ "$kind" != secondmate ] || return 1
  harness=$(fm_nm_keepwarm_meta_value "$meta" harness)
  [ -n "$harness" ] || return 1
  for h in ${FM_NM_KEEPWARM_HARNESSES:-$FM_NM_KEEPWARM_HARNESSES_DEFAULT}; do
    case "$harness" in "$h"*) return 0 ;; esac
  done
  return 1
}

# Epoch of this crew's most recent qualifying activation, or nothing when the
# task has left no signal at all yet. Turn-end (a real model turn), the status
# log (a crew-authored event), and the attempt marker are all restart points.
fm_nm_keepwarm_last_activation() {  # <state> <id>
  local state=$1 id=$2 newest='' m f
  for f in "$state/$id.turn-ended" "$state/$id.status"; do
    m=$(fm_nm_keepwarm_mtime "$f") || continue
    case "$m" in ''|*[!0-9]*) continue ;; esac
    { [ -n "$newest" ] && [ "$m" -le "$newest" ]; } && continue
    newest=$m
  done
  if m=$(fm_nm_keepwarm_marker_epoch "$state" "$id"); then
    case "$m" in
      ''|*[!0-9]*) ;;
      *) { [ -n "$newest" ] && [ "$m" -le "$newest" ]; } || newest=$m ;;
    esac
  fi
  [ -n "$newest" ] || return 1
  printf '%s' "$newest"
}

# 0 when bin/fm-crew-state.sh reports an attributed no-mistakes run that is
# actively working. `parked` (a gate awaiting a decision), the terminal states,
# and a `pane`-sourced working verdict all fail this on purpose: only a run the
# crew is genuinely waiting out earns an activation.
# The home is passed explicitly because bin/fm-crew-state.sh resolves its state
# directory from FM_HOME: a watcher that inherited no exported home would
# otherwise read another home's records to decide whether to steer this crew.
fm_nm_keepwarm_run_active() {  # <home> <id>
  local home=$1 id=$2 line state src
  line=$(env FM_HOME="$home" "$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || return 1
  case "$line" in state:*) ;; *) return 1 ;; esac
  state=${line#state: }; state=${state%% *}
  [ "$state" = working ] || return 1
  case "$line" in *"source: "*) ;; *) return 1 ;; esac
  src=${line#*source: }; src=${src%% *}
  [ "$src" = run-step ]
}

# The recorded endpoint's composer verdict: empty|pending|pending-unproven|
# unknown, exactly as bin/fm-backend.sh classifies it. An endpoint that cannot
# be resolved at all is `unknown`, which is a refusal here, not a fallback.
fm_nm_keepwarm_composer_state() {  # <state> <id>
  local meta=$1/$2.meta backend target verdict
  if [ -n "${FM_NM_KEEPWARM_COMPOSER_HOOK:-}" ]; then
    # Hook receives: state id
    verdict=$(eval "$FM_NM_KEEPWARM_COMPOSER_HOOK" "$(printf '%q' "$1")" \
      "$(printf '%q' "$2")" 2>/dev/null)
    printf '%s' "${verdict:-unknown}"
    return 0
  fi
  [ -f "$meta" ] || { printf 'unknown'; return 0; }
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || { printf 'unknown'; return 0; }
  verdict=$(fm_backend_composer_state "$backend" "$target" 2>/dev/null)
  printf '%s' "${verdict:-unknown}"
}

fm_nm_keepwarm_send() {  # <home> <id>
  if [ -n "${FM_NM_KEEPWARM_SEND_HOOK:-}" ]; then
    # Hook receives: home id message
    # shellcheck disable=SC2086
    eval "$FM_NM_KEEPWARM_SEND_HOOK" "$(printf '%q' "$1")" "$(printf '%q' "$2")" \
      "$(printf '%q' "$FM_NM_KEEPWARM_MESSAGE")"
    return $?
  fi
  env FM_HOME="$1" "$_FM_NM_KEEPWARM_LIB_DIR/fm-send.sh" "$2" "$FM_NM_KEEPWARM_MESSAGE" >/dev/null 2>&1
}

# One keep-warm evaluation for task <id>, called from the watcher's pane scan
# once the pane is confirmed idle. Prints exactly one outcome word and returns 0
# only when an activation was delivered:
#   ineligible    not a keep-warm harness, or not an ordinary crewmate
#   disabled      keep-warm turned off for this home
#   seeded        first sighting with no prior signal; the clock starts now
#   not-due       still inside the quiet interval
#   no-active-run no attributed, actively-working no-mistakes run to keep warm
#   deferred      the pane is not a confirmed-empty composer, so nothing was typed
#   sent          activation delivered
#   send-failed   the send path refused or could not confirm submission
# Only `sent` restarts the full interval. Every other non-delivering outcome
# except ineligible/disabled/not-due re-anchors the marker for a retry delay
# instead, so a transient refusal costs one retry rather than a second full
# interval of silence, while the doubling in fm_nm_keepwarm_record_miss keeps a
# permanently unreachable pane at one evaluation per interval instead of a
# per-poll retry storm. A watcher restart resumes the same cadence from the
# same file either way.
fm_nm_keepwarm_tick() {  # <home> <state> <id>
  local home=$1 state=$2 id=$3 interval last now composer marker fresh=0
  [ -n "$id" ] || { printf 'ineligible'; return 1; }
  fm_nm_keepwarm_eligible "$state" "$id" || { printf 'ineligible'; return 1; }
  interval=$(fm_nm_keepwarm_interval_secs)
  [ "$interval" -gt 0 ] || { printf 'disabled'; return 1; }
  now=$(fm_nm_keepwarm_now)
  if ! last=$(fm_nm_keepwarm_last_activation "$state" "$id"); then
    fm_nm_keepwarm_record "$state" "$id" "$now"
    printf 'seeded'
    return 1
  fi
  if [ $((now - last)) -lt "$interval" ]; then
    printf 'not-due'
    return 1
  fi
  marker=$(fm_nm_keepwarm_marker_epoch "$state" "$id") || marker=''
  [ "$last" = "$marker" ] || fresh=1
  if ! fm_nm_keepwarm_run_active "$home" "$id"; then
    fm_nm_keepwarm_record_miss "$state" "$id" "$now" "$interval" no-run "$fresh"
    printf 'no-active-run'
    return 1
  fi
  composer=$(fm_nm_keepwarm_composer_state "$state" "$id")
  if [ "$composer" != empty ]; then
    fm_nm_keepwarm_record_miss "$state" "$id" "$now" "$interval" undelivered "$fresh"
    printf 'deferred'
    return 1
  fi
  if fm_nm_keepwarm_send "$home" "$id"; then
    fm_nm_keepwarm_record "$state" "$id" "$now" 0 0
    printf 'sent'
    return 0
  fi
  fm_nm_keepwarm_record_miss "$state" "$id" "$now" "$interval" undelivered "$fresh"
  printf 'send-failed'
  return 1
}
