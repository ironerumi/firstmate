#!/usr/bin/env bash
# tests/fm-nm-keepwarm.test.sh - a Claude crew waiting out a long no-mistakes
# run gets one benign activation per quiet interval, and nothing else does.
#
# Every case drives bin/fm-nm-keepwarm-lib.sh's tick with a controlled clock
# (FM_NM_KEEPWARM_NOW) and controlled file timestamps, so the 30-minute boundary
# is exercised without any test waiting 30 minutes. The crew-state reader and
# the send path are both stubbed: this suite owns the cadence and the safety
# gates, not the backend or the pipeline.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-nm-keepwarm)

# shellcheck disable=SC1091
. "$ROOT/bin/fm-nm-keepwarm-lib.sh"

HOME_DIR="$TMP/home"
STATE="$HOME_DIR/state"
mkdir -p "$STATE"
SENT_LOG="$TMP/sent.log"
: > "$SENT_LOG"

# Stub send: records one line per delivered activation. The exit code is driven
# by FAKE_SEND_RC so the refused-send case is a real non-zero return.
cat > "$TMP/fake-send.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$SENT_LOG"
exit "${FAKE_SEND_RC:-0}"
SH
chmod +x "$TMP/fake-send.sh"
export SENT_LOG
export FM_NM_KEEPWARM_SEND_HOOK="$TMP/fake-send.sh"

# Stub crew state: prints whatever FAKE_CREW_STATE holds, the same one-line
# contract bin/fm-crew-state.sh emits.
cat > "$TMP/fake-crew-state.sh" <<'SH'
#!/usr/bin/env bash
[ -n "${FAKE_CREW_STATE:-}" ] || exit 1
printf '%s\n' "$FAKE_CREW_STATE"
SH
chmod +x "$TMP/fake-crew-state.sh"
export FM_CREW_STATE_BIN="$TMP/fake-crew-state.sh"

# Stub composer state: prints whatever FAKE_COMPOSER holds, the same verdict
# vocabulary bin/fm-backend.sh's fm_backend_composer_state emits.
cat > "$TMP/fake-composer.sh" <<'SH'
#!/usr/bin/env bash
printf '%s' "${FAKE_COMPOSER:-empty}"
SH
chmod +x "$TMP/fake-composer.sh"
export FM_NM_KEEPWARM_COMPOSER_HOOK="$TMP/fake-composer.sh"
export FAKE_COMPOSER=empty

NOW=1800000000
WORKING='state: working · source: run-step · nm run r1 step ci running'
PARKED='state: parked · source: run-step · nm run r1 awaiting_approval: 2 findings'
DONE='state: done · source: run-step · nm run r1 checks-passed'

# --- fixtures ---------------------------------------------------------------

# make_task <id> [harness] [kind] [backend]: a crewmate whose last model turn
# was <NOW>. An absent backend is tmux, the meta compatibility contract.
make_task() {  # <id> [harness] [kind] [backend]
  local id=$1 harness=${2:-claude} kind=${3:-ship} backend=${4:-}
  fm_write_meta "$STATE/$id.meta" \
    "window=firstmate:fm-$id" \
    "worktree=$TMP/wt-$id" \
    "project=$TMP/projects/sample" \
    "harness=$harness" \
    "kind=$kind" \
    "mode=no-mistakes" \
    ${backend:+"backend=$backend"} \
    "yolo=off"
  : > "$STATE/$id.turn-ended"
  set_turn_end "$id" "$NOW"
  rm -f "$STATE/.keepwarm-$id"
}

# set_file_time <path> <epoch>: pin a signal file to a controlled timestamp.
set_file_time() {  # <path> <epoch>
  local stamp
  if [ "$(uname)" = Darwin ]; then
    stamp=$(date -r "$2" +%Y%m%d%H%M.%S)
  else
    stamp=$(date -d "@$2" +%Y%m%d%H%M.%S)
  fi
  touch -t "$stamp" "$1"
}

# set_turn_end <id> <epoch>: the crew's last real model turn, as its Stop hook
# would have left it.
set_turn_end() {  # <id> <epoch>
  set_file_time "$STATE/$1.turn-ended" "$2"
}

# tick <id> <now-epoch>: one keep-warm evaluation at a controlled clock.
tick() {  # <id> <now>
  FM_NM_KEEPWARM_NOW=$2 fm_nm_keepwarm_tick "$HOME_DIR" "$STATE" "$1" || true
}

sent_count() {  # <id>
  grep -c -F "	$1	" "$SENT_LOG" 2>/dev/null || true
}

# --- 30-minute boundary -----------------------------------------------------

export FAKE_CREW_STATE="$WORKING"

make_task boundary
out=$(tick boundary $((NOW + 1799)))
[ "$out" = not-due ] || fail "one second before the interval must not activate (got '$out')"
[ "$(sent_count boundary)" = 0 ] || fail "no activation may be sent before the interval elapses"
pass "quiet just under 30 minutes sends nothing"

out=$(tick boundary $((NOW + 1800)))
[ "$out" = sent ] || fail "the 30-minute boundary must activate (got '$out')"
[ "$(sent_count boundary)" = 1 ] || fail "exactly one activation at the boundary"
assert_grep "$FM_NM_KEEPWARM_MESSAGE" "$SENT_LOG" "the activation must carry the benign keep-warm text"
pass "quiet reaching 30 minutes sends exactly one activation"

# --- no early duplicate -----------------------------------------------------

out=$(tick boundary $((NOW + 1801)))
[ "$out" = not-due ] || fail "a second poll right after an activation must not re-send (got '$out')"
out=$(tick boundary $((NOW + 3599)))
[ "$out" = not-due ] || fail "the next activation is due a full interval later (got '$out')"
[ "$(sent_count boundary)" = 1 ] || fail "no duplicate activation inside the interval"
out=$(tick boundary $((NOW + 3600)))
[ "$out" = sent ] || fail "the next interval must activate again (got '$out')"
[ "$(sent_count boundary)" = 2 ] || fail "one activation per elapsed interval"
pass "an activation resets the cadence; no duplicate before the next interval"

# --- a real worker turn resets the cadence ----------------------------------

make_task turnreset
set_turn_end turnreset $((NOW + 1500))   # the crew took its own turn mid-wait
out=$(tick turnreset $((NOW + 1800)))
[ "$out" = not-due ] || fail "a fresh worker turn must restart the quiet clock (got '$out')"
[ "$(sent_count turnreset)" = 0 ] || fail "a crew that just took a turn needs no activation"
out=$(tick turnreset $((NOW + 3299)))
[ "$out" = not-due ] || fail "the clock runs from the worker turn, not the previous tick (got '$out')"
out=$(tick turnreset $((NOW + 3300)))
[ "$out" = sent ] || fail "30 minutes after the worker's own turn must activate (got '$out')"
pass "a normal worker turn resets the cadence"

# A status line the crew writes is the other qualifying activation.
make_task statusreset
printf 'working: still validating\n' > "$STATE/statusreset.status"
set_file_time "$STATE/statusreset.status" $((NOW + 1500))
out=$(tick statusreset $((NOW + 1800)))
[ "$out" = not-due ] || fail "a fresh status event must restart the quiet clock (got '$out')"
pass "a crew-authored status event resets the cadence"

# --- active-turn suppression ------------------------------------------------
#
# The watcher only reaches the tick on a pane that stayed identical across polls
# with no busy signature, so an active turn never gets here. The library's own
# backstop is the crew-state gate: a `pane`-sourced working verdict is not an
# attributed run and must not be activated.
make_task activeturn
export FAKE_CREW_STATE='state: working · source: pane · busy signature'
out=$(tick activeturn $((NOW + 3600)))
[ "$out" = no-active-run ] || fail "a busy pane without an attributed run must not be activated (got '$out')"
[ "$(sent_count activeturn)" = 0 ] || fail "no activation may be sent to a working pane"
pass "an active turn without an attributed run is suppressed"

# --- parked-decision suppression --------------------------------------------

make_task parked
export FAKE_CREW_STATE="$PARKED"
out=$(tick parked $((NOW + 3600)))
[ "$out" = no-active-run ] || fail "a parked gate must never be activated (got '$out')"
[ "$(sent_count parked)" = 0 ] || fail "no activation may reach a crew parked on a decision"
pass "a parked decision is suppressed"

# --- terminal run behavior --------------------------------------------------

make_task terminal
export FAKE_CREW_STATE="$DONE"
out=$(tick terminal $((NOW + 3600)))
[ "$out" = no-active-run ] || fail "a finished run must not be kept warm (got '$out')"
[ "$(sent_count terminal)" = 0 ] || fail "no activation may reach a crew whose run is terminal"
# The refusal re-anchors, so a finished crew is not re-evaluated every poll.
out=$(tick terminal $((NOW + 3601)))
[ "$out" = not-due ] || fail "a terminal refusal must re-anchor the clock (got '$out')"
pass "a terminal run is never kept warm"

# A crew with no attributed run at all (pre-validation) is the same no-op.
make_task norun
export FAKE_CREW_STATE=''
out=$(tick norun $((NOW + 3600)))
[ "$out" = no-active-run ] || fail "a crew with no run must not be activated (got '$out')"
pass "a crew with no run is never kept warm"

# --- restart and retry idempotency ------------------------------------------

export FAKE_CREW_STATE="$WORKING"
make_task restart
out=$(tick restart $((NOW + 1800)))
[ "$out" = sent ] || fail "restart fixture must activate once (got '$out')"
before=$(cat "$STATE/.keepwarm-restart")
# A watcher restart re-reads the same marker: the replayed poll is a no-op and
# the recorded anchor is unchanged.
out=$(tick restart $((NOW + 1800)))
[ "$out" = not-due ] || fail "a replayed poll after a restart must not re-send (got '$out')"
[ "$(cat "$STATE/.keepwarm-restart")" = "$before" ] || fail "a replayed poll must not move the anchor"
[ "$(sent_count restart)" = 1 ] || fail "a restart must not duplicate the activation"
pass "restart replays the same anchor without duplicating the activation"

# A first sighting with no signal at all seeds the clock instead of activating.
make_task seeded
rm -f "$STATE/seeded.turn-ended"
out=$(tick seeded "$NOW")
[ "$out" = seeded ] || fail "a task with no prior signal must seed the clock (got '$out')"
[ "$(sent_count seeded)" = 0 ] || fail "seeding must not activate"
out=$(tick seeded $((NOW + 1800)))
[ "$out" = sent ] || fail "the seeded clock must activate one interval later (got '$out')"
pass "a first sighting seeds the clock rather than activating immediately"

# A refused send re-anchors too, so a broken send path cannot loop every poll -
# but only for the retry delay, because nothing was delivered.
make_task refused
out=$(FAKE_SEND_RC=1 tick refused $((NOW + 1800)))
[ "$out" = send-failed ] || fail "a refused send must be reported (got '$out')"
out=$(FAKE_SEND_RC=1 tick refused $((NOW + 1801)))
[ "$out" = not-due ] || fail "a refused send must re-anchor rather than retry every poll (got '$out')"
before=$(sent_count refused)
out=$(tick refused $((NOW + 2099)))
[ "$out" = not-due ] || fail "the retry delay must be waited out (got '$out')"
[ "$(sent_count refused)" = "$before" ] || fail "no send may be attempted before the retry falls due"
out=$(tick refused $((NOW + 2100)))
[ "$out" = sent ] || fail "a refused send must be retried after the retry delay, not a full interval (got '$out')"
pass "a refused send retries after the bounded delay, not another full interval"

# A delivered activation is the only outcome that restarts the full interval,
# and it clears the miss streak, so the next failure starts from the base delay.
out=$(tick refused $((NOW + 3899)))
[ "$out" = not-due ] || fail "a delivered activation must restart the full interval (got '$out')"
out=$(FAKE_SEND_RC=1 tick refused $((NOW + 3900)))
[ "$out" = send-failed ] || fail "the next interval must attempt again (got '$out')"
out=$(tick refused $((NOW + 4200)))
[ "$out" = sent ] || fail "a delivered activation must reset the retry streak (got '$out')"
pass "only a delivered activation restarts the full interval"

# --- composer safety gate ---------------------------------------------------
#
# A confirmed-idle pane is not automatically a pane that can be typed into: a
# crew-state verdict stays authoritative after the pane closes, and the
# watcher's idle check reads busy signatures only. So a dead-shell prompt, an
# interactive prompt, and a half-typed line all arrive here looking idle, and
# each one would be executed, answered, or corrupted by an unguarded send.
for composer in pending pending-unproven unknown; do
  make_task "composer-$composer"
  out=$(FAKE_COMPOSER=$composer tick "composer-$composer" $((NOW + 1800)))
  [ "$out" = deferred ] || fail "composer '$composer' must defer instead of typing (got '$out')"
  [ "$(sent_count "composer-$composer")" = 0 ] || \
    fail "composer '$composer' must receive no keystrokes"
done
pass "only a confirmed-empty composer is typed into"

# A deferral is a miss, not a delivery: the crew is retried after the bounded
# delay, so a transient composer state costs one retry, not a silent hour.
make_task deferretry
out=$(FAKE_COMPOSER=pending tick deferretry $((NOW + 1800)))
[ "$out" = deferred ] || fail "the deferral fixture must defer (got '$out')"
out=$(FAKE_COMPOSER=pending tick deferretry $((NOW + 2099)))
[ "$out" = not-due ] || fail "a deferral must not re-evaluate every poll (got '$out')"
out=$(tick deferretry $((NOW + 2100)))
[ "$out" = sent ] || fail "a cleared composer must activate at the retry, not a full interval later (got '$out')"
pass "a deferral retries after the bounded delay"

# With no hook, the guard resolves the endpoint from meta: an endpoint that
# cannot be read is `unknown`, which is a refusal and not a fallback to typing.
make_task unresolvable
out=$(FM_NM_KEEPWARM_COMPOSER_HOOK='' tick unresolvable $((NOW + 1800)))
[ "$out" = deferred ] || fail "an unreadable endpoint must defer (got '$out')"
[ "$(sent_count unresolvable)" = 0 ] || fail "an unreadable endpoint must receive no keystrokes"
pass "an endpoint that cannot be read is never typed into"

# zellij has no composer classifier, so it can never prove a pane safe to type
# into: keep-warm is an unsupported no-op there until it grows one. This pins
# the exclusion the library header and docs/architecture.md document.
make_task zellij claude ship zellij
out=$(FM_NM_KEEPWARM_COMPOSER_HOOK='' tick zellij $((NOW + 1800)))
[ "$out" = deferred ] || fail "a zellij-backed crew must defer, not type blind (got '$out')"
[ "$(sent_count zellij)" = 0 ] || fail "a zellij-backed crew must receive no keystrokes"
pass "a backend with no composer classifier is never typed into"

# --- bounded retry backoff --------------------------------------------------
#
# Retries double so a permanently unreachable crew settles back to one
# evaluation per interval instead of probing at the short delay forever.
make_task backoff
export FAKE_CREW_STATE=''
for probe in "1800 no-active-run" "2099 not-due" "2100 no-active-run" \
             "2699 not-due" "2700 no-active-run" "3899 not-due" \
             "3900 no-active-run" "5699 not-due" "5700 no-active-run"; do
  at=${probe%% *}; want=${probe#* }
  out=$(tick backoff $((NOW + at)))
  [ "$out" = "$want" ] || fail "backoff at +${at}s expected '$want' (got '$out')"
done
[ "$(sent_count backoff)" = 0 ] || fail "a crew with no run must never be activated"
pass "the retry delay doubles and is capped at one interval"

# A miss streak is only consecutive while nothing else happened: a real model
# turn is exactly that something, so the crew that follows it starts from the
# base delay instead of inheriting a saturated one from an earlier condition.
make_task streakreset
for at in 1800 2100 2700; do
  out=$(tick streakreset $((NOW + at)))
  [ "$out" = no-active-run ] || fail "streak fixture at +${at}s expected no-active-run (got '$out')"
done
set_turn_end streakreset $((NOW + 4000))
export FAKE_CREW_STATE="$WORKING"
out=$(FAKE_COMPOSER=pending tick streakreset $((NOW + 5800)))
[ "$out" = deferred ] || fail "the run that follows a real turn must be evaluated (got '$out')"
out=$(tick streakreset $((NOW + 6099)))
[ "$out" = not-due ] || fail "the base retry delay must still be waited out (got '$out')"
out=$(tick streakreset $((NOW + 6100)))
[ "$out" = sent ] || fail "a real turn must clear the miss history, so the retry is the base delay (got '$out')"
pass "a real worker turn clears the miss history"

# The two histories are independent: hours of ordinary idling must not spend
# the short retry that the first active run depends on.
make_task idlestreak
export FAKE_CREW_STATE=''
for at in 1800 2100 2700 3900; do
  out=$(tick idlestreak $((NOW + at)))
  [ "$out" = no-active-run ] || fail "idle fixture at +${at}s expected no-active-run (got '$out')"
done
export FAKE_CREW_STATE="$WORKING"
out=$(FAKE_COMPOSER=pending tick idlestreak $((NOW + 5700)))
[ "$out" = deferred ] || fail "the newly active run must be evaluated (got '$out')"
out=$(tick idlestreak $((NOW + 5999)))
[ "$out" = not-due ] || fail "the base retry delay must still be waited out (got '$out')"
out=$(tick idlestreak $((NOW + 6000)))
[ "$out" = sent ] || fail "an idle stretch must not lengthen the first delivery retry (got '$out')"
pass "having no run to keep warm never consumes the delivery retry"

# --- non-Claude and non-crewmate no-op --------------------------------------

for harness in codex opencode pi pi-signed grok kimi; do
  make_task "h-$harness" "$harness"
  out=$(tick "h-$harness" $((NOW + 7200)))
  [ "$out" = ineligible ] || fail "$harness must keep current behavior (got '$out')"
  [ "$(sent_count "h-$harness")" = 0 ] || fail "$harness must receive no activation"
  assert_absent "$STATE/.keepwarm-h-$harness" "$harness must leave no keep-warm state"
done
pass "every non-Claude harness is an untouched no-op"

make_task secondmate claude secondmate
out=$(tick secondmate $((NOW + 7200)))
[ "$out" = ineligible ] || fail "an idle secondmate must not be kept warm (got '$out')"
pass "a secondmate's idle-by-charter pane is never kept warm"

make_task disabled
out=$(FM_NM_KEEPWARM_SECS=0 tick disabled $((NOW + 7200)))
[ "$out" = disabled ] || fail "FM_NM_KEEPWARM_SECS=0 must disable keep-warm (got '$out')"
[ "$(sent_count disabled)" = 0 ] || fail "a disabled home must send nothing"
pass "keep-warm can be disabled for a home"

out=$(tick unknown-task $((NOW + 7200)))
[ "$out" = ineligible ] || fail "a task with no metadata must be a no-op (got '$out')"
pass "a task with no metadata is a no-op"

# --- watcher wiring ---------------------------------------------------------

assert_grep 'fm_nm_keepwarm_tick' "$ROOT/bin/fm-watch.sh" \
  "the watcher must own the single keep-warm call site"
[ "$(grep -c 'fm_nm_keepwarm_tick' "$ROOT/bin/fm-watch.sh")" = 1 ] || \
  fail "keep-warm must have exactly one call site, not a second polling path"
assert_grep 'fm-nm-keepwarm-lib.sh' "$ROOT/bin/fm-watch.sh" \
  "the watcher must source the keep-warm library"
pass "keep-warm rides the existing watcher loop with one call site"
