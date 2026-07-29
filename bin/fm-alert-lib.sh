#!/usr/bin/env bash
# fm-alert-lib.sh - user-visible supervision alerts.
#
# Two supervision failures are invisible to a captain who is not watching the
# pane: a watcher cycle that dies and cannot be repaired, and finished work that
# parks on a human decision and then sits overnight. Neither reaches the captain
# through the wake queue, because both are exactly the case where nothing is
# left running to surface them. This library is the single owner of the channel
# contract those two alerts share.
#
# It is deliberately NOT the away-mode injection wedge alarm
# (bin/fm-supervise-daemon.sh, docs/wedge-alarm.md). That alarm answers a
# different question (an escalation that could not be injected into firstmate's
# own pane while the captain is away) and owns its own config, rate limit, and
# process-group watchdog. Keeping the two separate keeps each alarm's meaning
# and default legible; only the general shape is shared.
#
# Config: config/supervision-alert (local, gitignored), one channel directive per
# non-empty, non-comment line. FM_ALERT_CHANNEL overrides the file with a single
# directive. Directives:
#   off              deliver nothing
#   auto | default   platform default: macOS -> osascript; otherwise none
#   osascript        macOS Notification Center banner
#   slack            Slack chat.postMessage, configured by config/alert-slack
#   command:<cmd>    run <cmd> via `sh -c`, summary on $1 and on stdin
# An absent config means "auto slack": the reachable OS channel plus Slack, and
# Slack is inert until config/alert-slack names a channel and a token source, so
# a home that never configured it sees no behavior change.
#
# Credential boundary: the Slack bot token is READ, used, and dropped. It is
# never copied into firstmate state, never written to the alert log, never
# printed, and never passed on a command line - curl receives the Authorization
# header through `--config -` on stdin, so it cannot appear in `ps` output.
# The token source is a path the captain configures; this library parses one
# SLACK_BOT_TOKEN assignment out of it rather than assuming a direnv-exported
# environment, because firstmate's scripts run outside that directory.
#
# Test seam: FM_ALERT_EXEC replaces every real notifier with that command,
# invoked as `<exec> <channel> <title> <summary>`. The value "discard" fires
# nothing at all. tests/wake-helpers.sh points it at a recorder so no suite can
# post a real notification or a real Slack message.

FM_ALERT_TIMEOUT_SECS_DEFAULT=10

fm_alert_config_dir() {
  printf '%s' "${FM_CONFIG_OVERRIDE:-${FM_HOME:-.}/config}"
}

fm_alert_state_dir() {
  printf '%s' "${FM_STATE_OVERRIDE:-${STATE:-${FM_HOME:-.}/state}}"
}

# Best-effort diagnostics. Never carries a credential value: callers log the
# fact that a token was missing or a post failed, never the token itself.
fm_alert_log() {  # <message>
  local log size
  log="$(fm_alert_state_dir)/.alert.log"
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$log" 2>/dev/null || return 0
  size=$(wc -c < "$log" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ "$size" -ge "${FM_ALERT_LOG_MAX_BYTES:-131072}" ] || return 0
  tail -n 200 "$log" > "$log.tmp" 2>/dev/null && mv -f "$log.tmp" "$log" 2>/dev/null
  rm -f "$log.tmp" 2>/dev/null || true
}

# Print the configured channel directives, one per line.
fm_alert_channels() {
  local cfg line found=
  if [ -n "${FM_ALERT_CHANNEL:-}" ]; then
    printf '%s\n' "$FM_ALERT_CHANNEL"
    return 0
  fi
  cfg="$(fm_alert_config_dir)/supervision-alert"
  if [ -f "$cfg" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      [ -n "$line" ] || continue
      case "$line" in '#'*) continue ;; esac
      printf '%s\n' "$line"
      found=1
    done < "$cfg"
  fi
  [ -n "$found" ] || printf 'auto\nslack\n'
}

fm_alert_platform_default() {
  case "$(uname 2>/dev/null || true)" in
    Darwin) command -v osascript >/dev/null 2>&1 && printf 'osascript' ;;
    *) : ;;
  esac
}

# Run one notifier under a wall-clock bound so a hung channel cannot stall the
# watcher poll that called it. Returns the notifier's exit code, or 124 on
# timeout.
fm_alert_run_bounded() {  # <channel> <command...>
  local channel=$1 timeout pid start elapsed rc
  shift
  timeout=${FM_ALERT_TIMEOUT_SECS:-$FM_ALERT_TIMEOUT_SECS_DEFAULT}
  case "$timeout" in
    ''|*[!0-9]*) timeout=$FM_ALERT_TIMEOUT_SECS_DEFAULT ;;
    *) [ "$timeout" -gt 0 ] 2>/dev/null || timeout=$FM_ALERT_TIMEOUT_SECS_DEFAULT ;;
  esac
  "$@" &
  pid=$!
  start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 0.2
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      fm_alert_log "alert: $channel notifier timed out after ${elapsed}s (limit ${timeout}s)"
      return 124
    fi
    sleep 0.1
  done
  if wait "$pid"; then rc=0; else rc=$?; fi
  return "$rc"
}

# The single execution seam. Returns 2 when no override is configured, which
# means the caller should run the real channel.
fm_alert_exec_override() {  # <channel> <title> <summary>
  local channel=$1 title=$2 summary=$3 rc exec_override=${FM_ALERT_EXEC:-}
  case "$exec_override" in
    '') return 2 ;;
    discard) return 0 ;;
    *)
      fm_alert_run_bounded "$channel" "$exec_override" "$channel" "$title" "$summary" >/dev/null 2>&1
      rc=$?
      [ "$rc" -eq 0 ] && return 0
      fm_alert_log "alert: notifier override exited $rc for channel '$channel'"
      return 1 ;;
  esac
}

# macOS Notification Center. The summary is an argv item, never interpolated
# into the AppleScript source, so its text cannot alter the script.
fm_alert_via_osascript() {  # <title> <summary>
  local title=$1 summary=$2 rc
  fm_alert_exec_override osascript "$title" "$summary"
  rc=$?
  case "$rc" in 0) return 0 ;; 1) return 1 ;; esac
  command -v osascript >/dev/null 2>&1 || {
    fm_alert_log "alert: osascript not found; cannot post a macOS notification"
    return 1
  }
  fm_alert_run_bounded osascript osascript -e 'on run argv' \
    -e 'display notification (item 1 of argv) with title (item 2 of argv) sound name "Basso"' \
    -e 'end run' "$summary" "$title" >/dev/null 2>&1 && return 0
  fm_alert_log "alert: osascript notification failed"
  return 1
}

fm_alert_slack_config_value() {  # <key>
  local cfg key=$1 line value=
  cfg="$(fm_alert_config_dir)/alert-slack"
  [ -f "$cfg" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      '#'*|'') continue ;;
      "$key"=*) value=${line#*=} ;;
    esac
  done < "$cfg"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  value="${value%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

# Resolve the bot token without assuming direnv inheritance: an already-exported
# SLACK_BOT_TOKEN wins, otherwise one assignment is parsed out of the captain's
# configured token_file. The value is returned on stdout to one caller and never
# stored anywhere else.
fm_alert_slack_token() {
  local src token
  if [ -n "${SLACK_BOT_TOKEN:-}" ]; then
    printf '%s' "$SLACK_BOT_TOKEN"
    return 0
  fi
  src=$(fm_alert_slack_config_value token_file) || return 1
  [ -r "$src" ] || {
    fm_alert_log "alert: slack token source is not readable"
    return 1
  }
  token=$(sed -n 's/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}SLACK_BOT_TOKEN=//p' "$src" 2>/dev/null | tail -1)
  token="${token%\"}"; token="${token#\"}"
  token="${token%\'}"; token="${token#\'}"
  [ -n "$token" ] || {
    fm_alert_log "alert: slack token source contains no SLACK_BOT_TOKEN assignment"
    return 1
  }
  printf '%s' "$token"
}

fm_alert_json_escape() {  # <text>
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk 'BEGIN{ORS=""} NR>1{printf "\\n"} {print}'
}

# The actual transport, split out so the token reaches curl only through this
# process's environment and curl's stdin config. It is never an argv item of any
# process: not of curl, and not of an `env VAR=...` wrapper, whose assignments
# would themselves be visible in `ps`.
fm_alert_slack_post() {
  printf 'header = "Authorization: Bearer %s"\n' "$FM_ALERT_SLACK_TOKEN" \
    | curl -sS --max-time "${FM_ALERT_SLACK_CURL_TIMEOUT:-10}" --config - \
      -H 'Content-Type: application/json; charset=utf-8' \
      --data "$FM_ALERT_SLACK_PAYLOAD" \
      "${FM_ALERT_SLACK_URL:-https://slack.com/api/chat.postMessage}"
}

# Post to Slack. Best-effort like every other channel: an unconfigured channel,
# an unreadable token source, or a failed post logs and returns 1 without
# affecting the other channels.
fm_alert_via_slack() {  # <title> <summary>
  local title=$1 summary=$2 rc channel
  fm_alert_exec_override slack "$title" "$summary"
  rc=$?
  case "$rc" in 0) return 0 ;; 1) return 1 ;; esac
  channel=$(fm_alert_slack_config_value channel) || {
    fm_alert_log "alert: slack channel not configured; skipping the slack channel"
    return 1
  }
  command -v curl >/dev/null 2>&1 || {
    fm_alert_log "alert: curl not found; cannot post to slack"
    return 1
  }
  FM_ALERT_SLACK_TOKEN=$(fm_alert_slack_token) || return 1
  FM_ALERT_SLACK_PAYLOAD=$(printf '{"channel":"%s","text":"%s"}' \
    "$(fm_alert_json_escape "$channel")" \
    "$(fm_alert_json_escape "$title"$'\n'"$summary")")
  export FM_ALERT_SLACK_TOKEN FM_ALERT_SLACK_PAYLOAD
  fm_alert_run_bounded slack fm_alert_slack_post >/dev/null 2>&1
  rc=$?
  unset FM_ALERT_SLACK_TOKEN FM_ALERT_SLACK_PAYLOAD
  [ "$rc" -eq 0 ] && return 0
  fm_alert_log "alert: slack post failed"
  return 1
}

fm_alert_via_command() {  # <cmd> <title> <summary>
  local cmd=$1 title=$2 summary=$3 rc text
  fm_alert_exec_override "command:$cmd" "$title" "$summary"
  rc=$?
  case "$rc" in 0) return 0 ;; 1) return 1 ;; esac
  text="$title: $summary"
  printf '%s\n' "$text" | fm_alert_run_bounded "command:$cmd" sh -c "$cmd" sh "$text" >/dev/null 2>&1 && return 0
  fm_alert_log "alert: command channel failed"
  return 1
}

# Deliver one alert through every configured channel. Each channel is
# best-effort and isolated: a missing binary, a missing credential, or a
# non-zero exit logs and moves to the next channel, so one broken channel can
# never suppress a working one or crash the caller's loop.
# Returns 0 when at least one channel delivered.
fm_alert_notify() {  # <title> <summary>
  local title=$1 summary=$2 directive resolved delivered=1
  while IFS= read -r directive || [ -n "$directive" ]; do
    [ -n "$directive" ] || continue
    resolved=$directive
    case "$directive" in
      off) return 0 ;;
      auto|default)
        resolved=$(fm_alert_platform_default)
        [ -n "$resolved" ] || {
          fm_alert_log "alert: no built-in OS channel on this platform; configure a command: or slack directive"
          continue
        }
        ;;
    esac
    case "$resolved" in
      osascript) fm_alert_via_osascript "$title" "$summary" && delivered=0 ;;
      slack) fm_alert_via_slack "$title" "$summary" && delivered=0 ;;
      command:*) fm_alert_via_command "${resolved#command:}" "$title" "$summary" && delivered=0 ;;
      *) fm_alert_log "alert: unknown channel directive '$directive'" ;;
    esac
  done <<EOF
$(fm_alert_channels)
EOF
  return "$delivered"
}

# One-shot delivery guarded by a durable marker, so a condition that persists
# across many watcher polls alerts once rather than every poll. The marker is
# written before delivery is attempted: a channel that fails must not turn into
# a retry storm, and the alert log records the failure.
# Returns 0 when this call fired, 1 when the marker already existed.
fm_alert_notify_once() {  # <marker-path> <title> <summary>
  local marker=$1 title=$2 summary=$3
  [ -e "$marker" ] && return 1
  date +%s > "$marker" 2>/dev/null || true
  fm_alert_notify "$title" "$summary" || true
  return 0
}

# Re-arm a one-shot marker once its condition clears.
fm_alert_clear_once() {  # <marker-path>
  rm -f "$1" 2>/dev/null || true
}
