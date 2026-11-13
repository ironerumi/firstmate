#!/usr/bin/env bash
# Fork regressions for process-event claims written before the UTC identity pin.
# Only the blocking-source and stranded-wake fixtures used by these cases are
# retained from fm-procevent.test.sh; tests/lib.sh owns runner cleanup.
# The original host has errexit enabled when it reaches these cases.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-procevent-identity-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

BLOCKER="$TMP_ROOT/blocker.sh"
cat > "$BLOCKER" <<'SH'
#!/usr/bin/env bash
# These identity cases never complete the source; bound an escaped fixture.
trigger=$1
while [ ! -e "$trigger" ]; do
  [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ] || exit 75
  sleep 0.05
done
SH
chmod +x "$BLOCKER"

# Records that the wrapped command actually started, then becomes it. A claim
# only proves its runner got as far as claiming; a test that needs the runner
# already inside its source command waits for this marker instead of a settle
# window, because a runner still short of that command retires itself when its
# registration goes away.
STARTED_BLOCKER="$TMP_ROOT/started-blocker.sh"
cat > "$STARTED_BLOCKER" <<'SH'
#!/usr/bin/env bash
printf 'started\n' > "$1"
shift
exec "$@"
SH
chmod +x "$STARTED_BLOCKER"

pe() { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }

# Every home this suite registers a source in is tracked so teardown can stop
# its runners. A runner started by reconcile is detached and reparented, so a
# source that never completes outlives the suite unless its home is swept -
# removing the fixture directory does not stop an already-running child.
# tests/lib.sh owns that sweep and runs it from every cleanup path.
pe_register() {  # <home> <adapter> <source-id> -- <argv>...
  local home=$1 adapter=$2 id=$3
  shift 3
  fm_test_track_procevent_home "$home"
  pe "$home" register "$adapter" "$id" "$@"
}
new_home() { mkdir -p "$1/state"; }

# The wake queue is a durable tab-separated record firstmate consumes:
# <epoch> <sequence> <kind> <key> <payload>. These read the rows reconcile
# publishes for a source it stranded, keyed by that source and its claim
# generation.
stranded_wake_keys() {  # <home> <source-id>
  [ -e "$1/state/.wake-queue" ] || return 0
  awk -F '\t' -v id="$2" \
    '$3 == "check" && index($4, "procevent:" id ":stranded:") == 1 { print $4 }' \
    "$1/state/.wake-queue"
}
stranded_wake_count() {  # <home> <source-id>
  stranded_wake_keys "$1" "$2" | grep -c . || true
}
stranded_wake_payloads() {  # <home> <source-id>
  [ -e "$1/state/.wake-queue" ] || return 0
  awk -F '\t' -v id="$2" \
    '$3 == "check" && index($4, "procevent:" id ":stranded:") == 1 { print $5 }' \
    "$1/state/.wake-queue"
}

wait_for() {  # <file> [tries]
  local f=$1 n=${2:-100}
  for _ in $(seq 1 "$n"); do [ -s "$f" ] && return 0; sleep 0.1; done
  return 1
}

# --- a live runner from before the UTC identity pin survives an update ---------
# A release before fm_pid_identity's UTC pin rendered the start time of a claim's
# runner in the local zone, and that runner keeps polling across a fast-forward.
# Only the ps fallback renders a zone, so these cases hide /proc to run it on
# every platform, under a zone that differs from UTC whatever the host's is.
LZ="$TMP_ROOT/legacy-zone"
mkdir -p "$LZ/no-proc" "$LZ/ps-bin"
lz_pe() { TZ=ENG-9 FM_PROC_ROOT_OVERRIDE="$LZ/no-proc" pe "$@"; }
lz_list_owner() { lz_pe "$1" list | awk -v id="$2" '$1 == id { print $3 }'; }
# The exact rendering the earlier release wrote into a claim.
lz_pre_pin_identity() {
  COLUMNS=10000 LC_ALL=C TZ=ENG-9 ps -p "$1" -o lstart= -o command= | sed 's/^[[:space:]]*//'
}
lz_set_identity() {  # <claim> <identity>
  awk -v v="$2" 'NR == 4 { print v; next } { print }' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
  chmod 0600 "$1"
}
lz_arm() {  # <home> <source-id>, sets LZ_CLAIM and LZ_LEADER
  new_home "$1"
  TZ=ENG-9 FM_PROC_ROOT_OVERRIDE="$LZ/no-proc" pe_register "$1" lavish "$2" \
    -- "$STARTED_BLOCKER" "$1/started" "$BLOCKER" "$1/trigger" >/dev/null
  lz_pe "$1" reconcile >/dev/null
  LZ_CLAIM="$FM_PROCEVENT_CLAIM_ROOT/$2.claim"
  wait_for "$LZ_CLAIM" || fail "$2 never claimed its source"
  wait_for "$1/started" || fail "$2 never reached its source command"
  LZ_LEADER=$(sed -n '2p' "$LZ_CLAIM")
}

HLZ1="$TMP_ROOT/hlz1"
lz_arm "$HLZ1" pre-pin-live-src
lz1_pinned=$(sed -n '4p' "$LZ_CLAIM")
lz1_pre_pin=$(lz_pre_pin_identity "$LZ_LEADER")
[ "$lz1_pinned" != "$lz1_pre_pin" ] \
  || fail "fixture invalid: the pre-pin rendering equals the pinned one: $lz1_pinned"
lz_set_identity "$LZ_CLAIM" "$lz1_pre_pin"
lz1_out=$(lz_pe "$HLZ1" reconcile)
assert_contains "$lz1_out" "started=0" "reconcile started a poller beside a live pre-pin runner: $lz1_out"
assert_contains "$lz1_out" "uncertain=0" "reconcile could not settle a live pre-pin runner: $lz1_out"
[ "$(lz_list_owner "$HLZ1" pre-pin-live-src)" = live ] \
  || fail "a live pre-pin runner is listed as '$(lz_list_owner "$HLZ1" pre-pin-live-src)'"
[ "$(stranded_wake_count "$HLZ1" pre-pin-live-src)" = 0 ] \
  || fail "a live pre-pin runner was announced stranded: $(stranded_wake_payloads "$HLZ1" pre-pin-live-src)"
kill -0 "$LZ_LEADER" 2>/dev/null || fail "reconcile ended a live pre-pin runner"
# The same proof has to authorize the signal, or retire leaves the poller behind.
lz_pe "$HLZ1" retire pre-pin-live-src >/dev/null \
  || fail "retire refused a live pre-pin runner"
kill -0 "$LZ_LEADER" 2>/dev/null && fail "retire left a live pre-pin runner polling"
pass "a live runner from before the UTC identity pin stays live and stoppable"

HLZ2="$TMP_ROOT/hlz2"
lz_arm "$HLZ2" pre-pin-reused-src
lz2_pinned=$(sed -n '4p' "$LZ_CLAIM")
lz2_pre_pin=$(lz_pre_pin_identity "$LZ_LEADER")
# Right command, another start: the record of a process this pid no longer is.
lz_set_identity "$LZ_CLAIM" "Mon Jan  1 00:00:00 2001 $(ps -p "$LZ_LEADER" -o command= | sed 's/^[[:space:]]*//')"
lz2_out=$(lz_pe "$HLZ2" reconcile)
assert_contains "$lz2_out" "started=0" "reconcile started a poller beside a reused pid: $lz2_out"
assert_contains "$lz2_out" "uncertain=1" "reconcile settled a reused pid as live: $lz2_out"
[ "$(lz_list_owner "$HLZ2" pre-pin-reused-src)" = orphaned ] \
  || fail "a reused pid is listed as '$(lz_list_owner "$HLZ2" pre-pin-reused-src)'"
[ "$(stranded_wake_count "$HLZ2" pre-pin-reused-src)" = 1 ] \
  || fail "a reused pid behind a pre-pin claim was not announced"
pass "a pre-pin claim naming another process stays stranded"

# An unreadable rendering proves nothing either way: the claim stays, unsignalled.
lz_set_identity "$LZ_CLAIM" "$lz2_pre_pin"
cat > "$LZ/ps-bin/ps" <<SH
#!/usr/bin/env bash
[ "\${TZ:-}" = UTC0 ] || exit 1
exec "$(command -v ps)" "\$@"
SH
chmod +x "$LZ/ps-bin/ps"
[ "$(PATH="$LZ/ps-bin:$PATH" lz_list_owner "$HLZ2" pre-pin-reused-src)" = uncertain ] \
  || fail "an unreadable pre-pin rendering was not reported uncertain"
set +e
lz3_retire=$(PATH="$LZ/ps-bin:$PATH" lz_pe "$HLZ2" retire pre-pin-reused-src 2>&1)
lz3_rc=$?
set -e
[ "$lz3_rc" -ne 0 ] || fail "retire released a claim whose identity it could not read: $lz3_retire"
assert_contains "$lz3_retire" "cannot confirm runner identity" "retire did not name the refusal: $lz3_retire"
[ "$(sed -n '2p' "$LZ_CLAIM")" = "$LZ_LEADER" ] || fail "retire replaced an uncertain claim"
kill -0 "$LZ_LEADER" 2>/dev/null || fail "an uncertain identity was signalled"
lz_set_identity "$LZ_CLAIM" "$lz2_pinned"
lz_pe "$HLZ2" retire pre-pin-reused-src >/dev/null || fail "fixture retire failed"
pass "an unreadable pre-pin rendering preserves the claim and signals nothing"

HLZ3="$TMP_ROOT/hlz3"
lz_arm "$HLZ3" pre-pin-dead-src
lz_set_identity "$LZ_CLAIM" "$(lz_pre_pin_identity "$LZ_LEADER")"
kill -KILL "$LZ_LEADER"
while kill -0 "$LZ_LEADER" 2>/dev/null && [ "$(ps -p "$LZ_LEADER" -o stat= | cut -c1)" != Z ]; do sleep 0.05; done
kill -0 -"$LZ_LEADER" 2>/dev/null || fail "fixture invalid: the dead runner's group is empty"
lz4_out=$(lz_pe "$HLZ3" reconcile)
assert_contains "$lz4_out" "started=0" "reconcile started a poller beside a dead runner's group: $lz4_out"
assert_contains "$lz4_out" "uncertain=1" "reconcile did not report a dead runner's group: $lz4_out"
[ "$(lz_list_owner "$HLZ3" pre-pin-dead-src)" = orphaned ] \
  || fail "a dead pre-pin runner is listed as '$(lz_list_owner "$HLZ3" pre-pin-dead-src)'"
[ "$(stranded_wake_count "$HLZ3" pre-pin-dead-src)" = 1 ] \
  || fail "a dead pre-pin runner was not announced"
kill -KILL -"$LZ_LEADER" 2>/dev/null || true
lz_pe "$HLZ3" retire pre-pin-dead-src >/dev/null 2>&1 || true
pass "a truly dead pre-pin runner is still reported"

printf '\nall procevent identity tests passed\n'
