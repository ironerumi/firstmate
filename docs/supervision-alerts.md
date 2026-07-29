# Supervision alerts

Two supervision failures never reach the captain through the wake queue, because both are exactly the case where nothing is left running to raise one.
A watcher cycle that dies and cannot be re-armed leaves the session blind until someone notices the banner.
Work that is finished except for a human decision parks silently, and the calendar cost of that park is invisible until the next morning.
`bin/fm-alert-lib.sh` is the single owner of the channel contract those two alerts share.

It is not the away-mode injection wedge alarm, which answers a different question and keeps its own config, rate limit, and defaults; see [`wedge-alarm.md`](wedge-alarm.md).

## What raises an alert

`bin/fm-watch-arm.sh` repairs an unexpectedly dead watcher cycle in place before anything is reported.
It re-arms up to `FM_WATCH_REPAIR_RETRIES` times (default 3, `FM_WATCH_REPAIR_DELAY` seconds apart) and then reports the repaired cycle's own outcome, so an ordinary transient watcher death never surfaces as a blind-turn banner.
Repair is bounded deliberately: unbounded silent restarts would hide a genuinely broken watcher behind the appearance of live supervision.
Once the budget is spent the arm stops retrying, prints the same typed failure line it always did, and raises one alert.
The alert is one-shot per outage; a cycle that recovers re-arms it.

`bin/fm-watch.sh` sweeps for parked work on a slow cadence (`FM_PARK_SCAN_INTERVAL`, default 300 seconds) and alerts once when a task has been waiting on a person for longer than `FM_PARK_ALERT_SECS` (default 1800).
Only two gates count as a person's turn to act: a reported-ready PR on a task firstmate may not merge itself, and an open `needs-decision` that is still the crew's current state.
Ordinary working and validation time, a declared external wait, an idle secondmate, a task firstmate merges under standing authority, a worker blocked on firstmate, and a queue item with no task of its own are all excluded.
The scan never queues a wake: an idle fleet has no supervision work to do, and turning a park into a wake would spend a turn to say "still parked".

## Channels

`config/supervision-alert` is local and gitignored.
It lists channel directives, one per non-empty, non-comment line, and every listed non-`off` channel fires best-effort.
`FM_ALERT_CHANNEL` overrides the file with one directive for focused testing.

- `off` delivers nothing.
- `auto` or `default` resolves to `osascript` on macOS; other platforms have no built-in OS channel, so configure `command:` or `slack` there.
- `osascript` posts a macOS Notification Center banner.
- `slack` posts to the channel named in `config/alert-slack`.
- `command:<cmd>` runs `<cmd>` through `sh -c` with the alert text as `$1` and on stdin.

An absent `config/supervision-alert` behaves as `auto` plus `slack`.
Slack stays inert until it is configured, so a home that never set it up sees no change.

Each channel is best-effort and isolated: a missing binary, a missing credential, or a non-zero exit is logged to `state/.alert.log` and the next channel still runs.
Every invocation is bounded by `FM_ALERT_TIMEOUT_SECS`, which defaults to 10 seconds.
AppleScript receives the alert text as an argv item rather than interpolated source, so the text cannot alter the script.

## Slack channel and credential

`config/alert-slack` is local and gitignored and takes two lines:

```
channel=C0BERD2U7JP
token_file=/absolute/path/to/.envrc
```

`channel` is the Slack channel id to post to.
`token_file` is a file the captain already keeps that contains a `SLACK_BOT_TOKEN` assignment; firstmate's scripts run outside that directory, so the token is parsed from the file rather than assumed to be exported by direnv.
An already-exported `SLACK_BOT_TOKEN` in the environment wins over the file.

The token is read, used, and dropped.
It is never copied into firstmate state, never written to the alert log, never printed, and never passed as a command-line argument: curl receives the `Authorization` header through `--config -` on stdin, so it cannot appear in `ps` output.
An unreadable source or an absent assignment logs a skip and leaves the other channels working.

## Test safety

Every notifier routes through `FM_ALERT_EXEC`, which replaces the real channel with that command, invoked as `<exec> <channel> <title> <summary>`.
The value `discard` fires nothing.
`tests/wake-helpers.sh` points the seam at a recorder for every suite that sources it, so no test can post a real notification or a real Slack message.

`tests/fm-supervision-alert.test.sh` covers channel resolution, per-channel failure isolation, the credential boundary against a fake curl, bounded repair success and exhaustion, alert deduplication and re-arm, and every park exclusion.
`tests/fm-watcher-lock.test.sh` continues to own the arm layer's cycle classification with repair disabled.
[`verification/supervision.md`](verification/supervision.md#supervision-alerts) records the manual macOS and Slack channel proof.
