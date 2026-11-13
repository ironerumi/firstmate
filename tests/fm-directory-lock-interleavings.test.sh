#!/usr/bin/env bash
# Copied-link publication/retirement interleavings and refusal invariants.
set -u

# shellcheck source=tests/directory-lock-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/directory-lock-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-directory-lock-tests)

# The oracle is the public lock contract, not the representation: one live
# owner, same-owner recovery, dead-owner recovery and complete release must
# produce identical results with real links and with MSYS-style copied links.
lock_portability_scenario() {
  local state=$1 expected=$2
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    lock="$STATE/.portable.lock"
    fm_lock_try_acquire "$lock" || exit 10
    if [ "$2" = directory ]; then
      [ -d "$lock" ] && [ ! -L "$lock" ] || exit 11
    else
      [ -L "$lock" ] || exit 12
    fi
    owner=$(fm_lock_link_owner "$lock") || exit 13
    fm_lock_points_to_owner "$lock" "$owner" || exit 14
    printf "acquired\n"
    fm_lock_try_acquire "$lock" || exit 15
    printf "reentered\n"
    ( fm_lock_try_acquire "$lock" && exit 16
      fm_lock_release "$lock"
      [ -d "$lock" ] || exit 17
    ) || exit $?
    printf "refused foreign owner\n"
    fm_lock_release "$lock"
    [ ! -e "$lock" ] && [ ! -L "$lock" ] || exit 18
    printf "released\n"
    # wait is the proof that both the primary and steal holders have exited.
    bash -c '\''. "$1"; fm_lock_try_create "$2" && fm_lock_try_create "$2.steal"'\'' _ "$1" "$lock" &
    dead=$!
    wait "$dead" || exit 19
    fm_lock_try_acquire "$lock" || exit 20
    printf "reclaimed dead owner and steal mutex\n"
    fm_lock_release "$lock"
    [ ! -e "$lock" ] && [ ! -e "$lock.steal" ] || exit 21
    [ -z "$(find "$STATE" -name "*.owner.*" -print)" ] || exit 22
    printf "released reclaimed lock\n"
    fm_current_pid caller || exit 23
    bash -c '\''. "$1"; _fm_lock_acquire_wait_handoff "$2" "$3"'\'' _ "$1" "$lock" "$caller" &
    helper=$!
    wait "$helper" || exit 24
    [ "$(cat "$lock/pid")" = "$caller" ] || exit 25
    fm_lock_release "$lock"
    [ ! -e "$lock" ] || exit 26
    [ -z "$(find "$STATE" -name "*.owner.*" -print)" ] || exit 27
    printf "handed off and released\n"
  ' _ "$LIB" "$expected"
}

test_direct_directory_lock_release_and_reap() {
  local dir state lock dead
  dir=$(make_case direct-directory-lock)
  state="$dir/state"
  lock="$state/.direct.lock"
  dead=$(dead_pid)
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fm_current_pid me || exit 1
    mkdir "$2" || exit 2
    printf "%s\n" "$me" > "$2/pid" || exit 3
    fm_lock_release "$2"
    [ ! -e "$2" ] || exit 4
    mkdir "$2" || exit 5
    printf "%s\n" "$3" > "$2/pid" || exit 6
    fm_lock_try_acquire "$2" || exit 7
    [ -e "$2" ] || exit 8
    fm_lock_release "$2"
    [ ! -e "$2" ] || exit 9
  ' _ "$LIB" "$lock" "$dead" || fail "direct directory lock was not releasable and reclaimable"
  pass "direct directory locks release and recover through the shared paths"
}

test_lock_without_real_symlinks() {
  local native copied native_out copied_out real_ln
  native=$(make_case lock-native-parity)
  copied=$(make_case lock-copy-parity)
  real_ln=$(fm_real_tool ln)
  cat > "$copied/fakebin/ln" <<'SH'
#!/usr/bin/env bash
if [ "$1" = -s ]; then
  exec cp -R "$2" "$3"
fi
exec "$FM_TEST_REAL_LN" "$@"
SH
  chmod +x "$copied/fakebin/ln"
  native_out=$(lock_portability_scenario "$native/state" symlink) \
    || fail "native symlink lock contract failed"
  copied_out=$(PATH="$copied/fakebin:$PATH" FM_TEST_REAL_LN="$real_ln" \
    lock_portability_scenario "$copied/state" directory) \
    || fail "MSYS copied-link lock contract failed"
  [ "$native_out" = "$copied_out" ] \
    || fail "directory fallback changed the native lock contract: $copied_out"
  pass "copied-link fallback matches native acquire, re-entry, refusal, dead-owner recovery and release"
}

test_directory_lock_single_winner_under_load() {
  local dir state round i pids pid winners result
  dir=$(make_case directory-lock-contention)
  state="$dir/state"
  cat > "$dir/fakebin/ln" <<'SH'
#!/usr/bin/env bash
exec cp -R "$2" "$3"
SH
  chmod +x "$dir/fakebin/ln"
  mkfifo "$dir/ready" "$dir/start" "$dir/result" "$dir/release"
  exec 6<> "$dir/ready" 7<> "$dir/start" 8<> "$dir/result" 9<> "$dir/release"
  for round in {1..10}; do
    pids=''
    winners=0
    for i in {1..8}; do
      PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" bash -c '
        . "$1"
        printf "ready\n" >&6
        IFS= read -r go <&7
        if fm_lock_try_acquire "$2"; then
          [ -d "$2" ] && [ ! -L "$2" ] || exit 10
          printf "won\n" >&8
          IFS= read -r release <&9
          fm_lock_release "$2"
        else
          printf "lost\n" >&8
        fi
      ' _ "$LIB" "$state/.contend.lock" &
      pids="$pids $!"
    done
    for i in {1..8}; do IFS= read -r result <&6; done
    for i in {1..8}; do printf 'go\n' >&7; done
    for i in {1..8}; do
      IFS= read -r result <&8
      [ "$result" != won ] || winners=$((winners + 1))
    done
    [ "$winners" -eq 1 ] || fail "directory contention round $round had $winners winners"
    printf 'release\n' >&9
    for pid in $pids; do wait "$pid" || fail "directory contender failed in round $round"; done
    [ ! -e "$state/.contend.lock" ] || fail "directory winner did not release in round $round"
    [ -z "$(find "$state" -name '*.owner.*' -print)" ] \
      || fail "directory contention round $round left owner entries: $(find "$state" -name '*.owner.*' -print)"
  done
  exec 6>&- 7>&- 8>&- 9>&-
  pass "directory lock has exactly one winner in 10 event-synchronized rounds of 8 contenders"
}

# D1b: a claim that fails after publication leaves its generation to
# retirement. Its first retirement commits and then fails to delete the
# generation; the claim's cleanup must not delete it outside retirement.
test_dirlock_d1b_failed_claim_leaves_generation_to_retirement() {
  local dir lock claimant
  dir=$(dirlock_case dirlock-d1b)
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" a
  mkdir "$lock.steal"
  # shellcheck disable=SC2016
  dirlock_spawn "$dir" a "discard:pre:fail:$lock" '
    if fm_lock_try_create "$1"; then out=acquired; else out=refused; fi
    printf "%s finished out=%s\n" "$FM_TEST_SUBJECT" "$out" >> "$FM_TEST_EVENTS"' "$lock" &
  claimant=$!
  dirlock_expect "a discard:pre:$lock" "D1b: the steal-blocked claim did not retire its generation"
  dirlock_expect "a finished out=refused" "D1b: a claim blocked by a steal mutex did not refuse"
  wait "$claimant" || fail "D1b: claimant subject failed"
  rmdir "$lock.steal"
  dirlock_close
  dirlock_assert_clean "$dir" "D1b: the generation was deleted outside retirement"
  pass "D1b: a claim that fails after publication leaves its generation to retirement"
}

test_dirlock_d5_orphan_retirement_cannot_touch_successor() {
  local dir lock holder orphan contender generation
  dir=$(dirlock_case dirlock-d5)
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" a b
  # shellcheck disable=SC2016
  dirlock_spawn "$dir" a "retire:pre:wait:$lock" '
    fm_lock_try_acquire "$1" || exit 10
    fm_lock_release "$1"' "$lock" &
  holder=$!
  dirlock_expect "a retire:pre:$lock" "D5: holder did not reach its retirement rename"
  orphan=$(dirlock_event_field pid)
  [ "$(dirlock_event_field caller)" = "$holder" ] || fail "D5: barrier was not raised by the holder: $DIRLOCK_EVENT"
  kill -KILL "$holder"
  wait "$holder" 2>/dev/null
  ! kill -0 "$holder" 2>/dev/null || fail "D5: holder survived SIGKILL"
  kill -0 "$orphan" 2>/dev/null || fail "D5: retirement child died with its frame"
  FM_LOCK_STALE_AFTER=0 dirlock_spawn "$dir" b "" "$DIRLOCK_HOLD" "$lock" "$dir/b.id" &
  contender=$!
  dirlock_expect "b held pid=$contender" "D5: contender did not recover the dead holder"
  generation=$(cd "$lock" && echo .owner.*)
  printf 'go\n' >&7
  dirlock_expect "a done rc=" "D5: orphaned retirement did not resume"
  [ "$(cat "$lock/pid" 2>/dev/null)" = "$contender" ] || fail "D5: orphaned retirement took the successor's pid"
  [ "$(cd "$lock" && echo .owner.*)" = "$generation" ] && [ -f "$lock/$generation/pid" ] \
    || fail "D5: orphaned retirement changed the successor's generation: $(dirlock_tree "$dir")"
  printf 'go\n' >&8
  wait "$contender" || fail "D5: contender could not release cleanly"
  dirlock_close
  dirlock_assert_clean "$dir" "D5: residue"
  pass "D5: an orphaned retirement child resumed after recovery cannot touch the successor"
}

test_dirlock_d5b_stealer_retires_only_captured_generation() {
  local dir lock stealer sleeper live_stage out
  dir=$(dirlock_case dirlock-d5b)
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" s
  FM_STATE_OVERRIDE="$dir/state" PATH="$dir/fakebin:$PATH" bash -c '. "$0"; fm_lock_try_acquire "$1"' "$LIB" "$lock" \
    || fail "D5': could not leave a dead-held record"
  # shellcheck disable=SC2016
  FM_LOCK_STALE_AFTER=0 dirlock_spawn "$dir" s "retire:pre:wait:$lock" '
    if fm_lock_try_acquire "$1"; then echo acquired > "$2"; else echo "held=$FM_LOCK_HELD_PID" > "$2"; fi' \
    "$lock" "$dir/s.out" &
  stealer=$!
  dirlock_expect "s retire:pre:$lock" "D5': stealer did not reach its retirement rename"
  # The self-held reclaim's effect: the dead generation is retired and a live
  # one is published in its place while the stealer is paused.
  FM_STATE_OVERRIDE="$dir/state" bash -c '. "$0"; fm_lock_remove_path "$1"' "$LIB" "$lock" \
    || fail "D5': could not retire the dead generation"
  [ ! -e "$lock" ] || fail "D5': dead generation retirement left the lock"
  sleep 300 &
  sleeper=$!
  live_stage="$dir/state/.d.lock.owner.live000"
  mkdir -p "$live_stage/.owner.live000"
  printf '%s\n' "$sleeper" > "$live_stage/pid"
  printf '%s\n' "$sleeper" > "$live_stage/.owner.live000/pid"
  mv "$live_stage" "$lock"
  printf 'go\n' >&7
  wait "$stealer" || fail "D5': stealer subject failed"
  out=$(cat "$dir/s.out")
  [ "$out" = "held=$sleeper" ] || fail "D5': stealer did not report the live successor: $out"
  [ "$(cat "$lock/pid" 2>/dev/null)" = "$sleeper" ] && [ -f "$lock/.owner.live000/pid" ] \
    || fail "D5': stealer damaged the live record: $(dirlock_tree "$dir")"
  kill "$sleeper"
  wait "$sleeper" 2>/dev/null
  dirlock_close
  pass "D5': a paused stealer's retirement is addressed only to the generation it validated"
}

test_dirlock_d5c_acquirer_retires_captured_generation() {
  local dir lock stealer
  dir=$(dirlock_case dirlock-d5c)
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" s
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" bash -c '. "$0"; fm_lock_try_acquire "$1"' "$LIB" "$lock" \
    || fail "D5c: could not leave a dead-held record"
  # shellcheck disable=SC2016
  FM_LOCK_STALE_AFTER=0 dirlock_spawn "$dir" s "" "$DIRLOCK_PAUSE_REMOVE"'
    if fm_lock_try_acquire "$1"; then out=acquired; fm_lock_release "$1"; else out="held=$FM_LOCK_HELD_PID"; fi
    printf "%s finished out=%s\n" "$FM_TEST_SUBJECT" "$out" >> "$FM_TEST_EVENTS"' "$lock" &
  stealer=$!
  dirlock_expect "s remove:pre:$lock" "D5c: acquirer did not pause after its stale recheck"
  dirlock_replace_with_live_successor "$dir" "$lock" D5c
  printf 'go\n' >&7
  dirlock_expect "s finished out=" "D5c: acquirer did not finish"
  wait "$stealer" || fail "D5c: acquirer subject failed"
  [ "$(dirlock_event_field out)" = "held=$$" ] \
    || fail "D5c: acquirer damaged or took the successor: $DIRLOCK_EVENT"
  dirlock_assert_live_successor "$dir" "$lock" D5c
  dirlock_close
  dirlock_assert_clean "$dir" "D5c: residue"
  pass "D5c: stale acquisition retires only its captured generation"
}

# D8b: the direct reaper's mutation after its stale recheck is addressed to the
# generation it rechecked, not to whatever record the lock path holds by then.
test_dirlock_d8b_reaper_retires_captured_generation() {
  local dir lock reaper
  dir=$(dirlock_case dirlock-d8b)
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" r
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" bash -c '. "$0"; fm_lock_try_acquire "$1"' "$LIB" "$lock" \
    || fail "D8b: could not leave a dead-held record"
  # shellcheck disable=SC2016
  dirlock_spawn "$dir" r "" "$DIRLOCK_PAUSE_REMOVE"'
    if fm_lock_reap_dead_link "$1"; then out=reaped; else out=refused; fi
    printf "%s finished out=%s\n" "$FM_TEST_SUBJECT" "$out" >> "$FM_TEST_EVENTS"' "$lock" &
  reaper=$!
  dirlock_expect "r remove:pre:$lock" "D8b: reaper did not pause after its stale recheck"
  dirlock_replace_with_live_successor "$dir" "$lock" D8b
  printf 'go\n' >&7
  dirlock_expect "r finished out=" "D8b: reaper did not finish"
  wait "$reaper" || fail "D8b: reaper subject failed"
  dirlock_assert_live_successor "$dir" "$lock" D8b
  dirlock_close
  dirlock_assert_clean "$dir" "D8b: residue"
  pass "D8b: a paused direct reaper retires only the generation it rechecked"
}

test_dirlock_d6_late_publication_is_ordinary_recovery() {
  local dir lock publisher orphan contender case_name out staging
  for case_name in held released; do
    dir=$(dirlock_case "dirlock-d6-$case_name")
    lock="$dir/state/.d.lock"
    dirlock_open "$dir" a b
    # shellcheck disable=SC2016
    dirlock_spawn "$dir" a "publish:pre:wait:$lock" 'fm_lock_try_acquire "$1"' "$lock" &
    publisher=$!
    dirlock_expect "a publish:pre:$lock" "D6: publisher did not reach its publication rename"
    orphan=$(dirlock_event_field pid)
    for staging in "$lock".owner.*; do :; done
    kill -KILL "$publisher"
    wait "$publisher" 2>/dev/null
    ! kill -0 "$publisher" 2>/dev/null || fail "D6: publisher survived SIGKILL"
    kill -0 "$orphan" 2>/dev/null || fail "D6: publication child died with its frame"
    dirlock_spawn "$dir" b "" "$DIRLOCK_HOLD" "$lock" "$dir/b.id" &
    contender=$!
    dirlock_expect "b held pid=$contender" "D6: contender did not acquire"
    if [ "$case_name" = held ]; then
      printf 'go\n' >&7
      dirlock_expect "a done rc=1" "D6: late publication did not fail onto the held lock"
      [ "$(cat "$lock/pid")" = "$contender" ] || fail "D6: late publication changed the holder"
      [ -d "$staging" ] || fail "D6: the dead publisher's staging directory vanished"
      printf 'go\n' >&8
      wait "$contender" || fail "D6: contender could not release"
      [ "$(dirlock_tree "$dir")" = "./${staging##*/}
./${staging##*/}/.owner.${staging##*.owner.}
./${staging##*/}/.owner.${staging##*.owner.}/pid
./${staging##*/}/pid
./${staging##*/}/pid-start" ] || fail "D6: unexpected leftovers besides the one inert staging directory: $(dirlock_tree "$dir")"
    else
      printf 'go\n' >&8
      wait "$contender" || fail "D6: contender could not release"
      printf 'go\n' >&7
      dirlock_expect "a done rc=0" "D6: late publication did not publish onto the absent lock"
      [ "$(cat "$lock/pid")" = "$publisher" ] || fail "D6: late publication is not held by its dead publisher"
      # shellcheck disable=SC2016
      out=$(FM_STATE_OVERRIDE="$dir/state" bash -c '
        . "$0"
        fm_lock_try_acquire "$1" || { echo refused; exit 0; }
        echo "recovered=$FM_LOCK_RECOVERED_PID"
        fm_lock_release "$1"' "$LIB" "$lock")
      [ "$out" = "recovered=$publisher" ] || fail "D6: late dead-held publication was not recovered: $out"
      dirlock_assert_clean "$dir" "D6: residue after recovering a late publication"
    fi
    dirlock_close
  done
  pass "D6: a late publication by a dead publisher fails onto a holder or becomes an ordinary dead-held record"
}

test_dirlock_d8_dead_steal_mutex_observers_compose() {
  local dir lock first second
  dir=$(dirlock_case dirlock-d8)
  lock="$dir/state/.d.lock"
  # shellcheck disable=SC2016
  FM_STATE_OVERRIDE="$dir/state" PATH="$dir/fakebin:$PATH" bash -c '
    . "$0"; fm_lock_try_create "$1" && fm_lock_try_create "$1.steal"' "$LIB" "$lock" \
    || fail "D8: could not leave dead primary and steal records"
  dirlock_open "$dir" a b
  # shellcheck disable=SC2016
  FM_LOCK_STALE_AFTER=0 dirlock_spawn "$dir" a "retire:pre:wait:$lock.steal publish:post:wait:$lock" '
    fm_lock_try_acquire "$1" || exit 10
    fm_lock_release "$1"' "$lock" &
  first=$!
  dirlock_expect "a retire:pre:$lock.steal" "D8: first observer did not reach the steal-mutex retirement"
  # shellcheck disable=SC2016
  FM_LOCK_STALE_AFTER=0 dirlock_spawn "$dir" b "retire:pre:wait:$lock.steal" '
    if fm_lock_try_acquire "$1"; then out=acquired; else out="held=$FM_LOCK_HELD_PID"; fi
    printf "%s result %s\n" "$FM_TEST_SUBJECT" "$out" >> "$FM_TEST_EVENTS"
    IFS= read -r _ < "$FM_TEST_RESUME"
    fm_lock_try_acquire "$1" || exit 11
    fm_lock_release "$1"' "$lock" &
  second=$!
  dirlock_expect "b retire:pre:$lock.steal" "D8: second observer did not reach the steal-mutex retirement"
  printf 'go\n' >&7
  dirlock_expect "a done rc=" "D8: first observer's retirement did not finish"
  dirlock_expect "a publish:post:$lock" "D8: first observer did not publish the primary lock"
  [ "$(cat "$lock.steal/pid")" = "$first" ] && [ "$(cat "$lock/pid")" = "$first" ] \
    || fail "D8: first observer does not hold the steal mutex and the lock: $(dirlock_tree "$dir")"
  printf 'go\n' >&8
  dirlock_expect "b done rc=" "D8: second observer's late retirement did not run"
  dirlock_expect "b result held=$first" "D8: second observer did not report the first as holder"
  [ "$(cat "$lock.steal/pid")" = "$first" ] && [ "$(cat "$lock/pid")" = "$first" ] \
    || fail "D8: second observer's retirement touched the first's records: $(dirlock_tree "$dir")"
  printf 'go\n' >&7
  wait "$first" || fail "D8: first observer could not finish"
  printf 'go\n' >&8
  wait "$second" || fail "D8: second observer could not acquire after the first released"
  dirlock_close
  dirlock_assert_clean "$dir" "D8: residue"
  pass "D8: two observers of a dead directory steal mutex compose and cannot disturb the winner"
}

test_dirlock_d9_uncommitted_retirement_keeps_record() {
  local dir lock holder out
  dir=$(dirlock_case dirlock-d9)
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" a
  # shellcheck disable=SC2016
  dirlock_spawn "$dir" a "retire:pre:fail:$lock retire:pre:fail:$lock" '
    fm_lock_try_acquire "$1" || exit 10
    rc=0; fm_lock_remove_path "$1" || rc=$?
    [ "$rc" -eq 1 ] || exit 11
    fm_lock_release "$1" || exit 12
    printf "%s held pid=%s\n" "$FM_TEST_SUBJECT" "$(cat "$1/pid")" >> "$FM_TEST_EVENTS"
    IFS= read -r _ < "$FM_TEST_RESUME"
    fm_lock_release "$1"' "$lock" &
  holder=$!
  dirlock_expect "a retire:pre:$lock" "D9: first retirement did not reach its rename"
  dirlock_expect "a retire:pre:$lock" "D9: release did not reach its rename"
  dirlock_expect "a held pid=$holder" "D9: failed retirement did not leave the holder's record"
  [ "$(cat "$(dirlock_generation "$lock")/pid")" = "$holder" ] \
    || fail "D9: failed retirement damaged the generation: $(dirlock_tree "$dir")"
  # shellcheck disable=SC2016
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$0"; if fm_lock_try_acquire "$1"; then echo stolen; else echo "held=$FM_LOCK_HELD_PID"; fi' "$LIB" "$lock")
  [ "$out" = "held=$holder" ] || fail "D9: contender took a record whose retirement failed: $out"
  printf 'go\n' >&7
  wait "$holder" || fail "D9: holder subject failed"
  dirlock_close
  dirlock_assert_clean "$dir" "D9: residue after the fault cleared"
  pass "D9: an uncommitted retirement leaves the complete held record and deletes nothing"
}

test_dirlock_d10_committed_retirement_is_finished() {
  local dir lock holder out expected
  dir=$(dirlock_case dirlock-d10)
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" a
  # shellcheck disable=SC2016
  dirlock_spawn "$dir" a "retire:skip-role:none:$lock" '
    fm_lock_try_acquire "$1" || exit 10
    fm_lock_set_role "$1" autoarm || exit 11
    rc=0; fm_lock_remove_path "$1" || rc=$?
    [ "$rc" -eq 1 ] || exit 12' "$lock" &
  holder=$!
  dirlock_expect "a retire:skip-role:$lock" "D10: retirement did not reach its rename"
  wait "$holder" || fail "D10: remove_path did not report the unfinished retirement"
  expected=$(cd "$lock" && printf './%s\n' role .owner.* .owner.*/pid .owner.*/pid-start.retired .owner.*/pid.retired | LC_ALL=C sort)
  [ "$(cd "$lock" && find . -mindepth 1 -print | LC_ALL=C sort)" = "$expected" ] \
    || fail "D10: committed retirement left an unexpected record: $(dirlock_tree "$dir")"
  # shellcheck disable=SC2016
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$0"
    fm_lock_try_acquire "$1" || { echo refused; exit 0; }
    echo acquired
    fm_lock_release "$1"' "$LIB" "$lock")
  [ "$out" = acquired ] || fail "D10: contender did not finish a committed retirement: $out"
  dirlock_close
  dirlock_assert_clean "$dir" "D10: residue"
  pass "D10: a committed retirement blocked by a remaining known file is finished by the next acquirer"
}

test_dirlock_d11_ambiguous_generation_is_refused() {
  local dir lock holder before
  dir=$(dirlock_case dirlock-d11)
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" a
  # shellcheck disable=SC2016
  dirlock_spawn "$dir" a "" '
    fm_current_pid me || exit 9
    mkdir -p "$1/.owner.first1" "$1/.owner.secnd2" || exit 10
    printf "%s\n" "$me" > "$1/pid"
    printf "%s\n" "$me" > "$1/.owner.first1/pid"
    printf "%s\n" "$me" > "$1/.owner.secnd2/pid"
    ! fm_lock_link_owner "$1" >/dev/null || exit 11
    fm_lock_release "$1" || exit 12
    printf "%s held pid=%s\n" "$FM_TEST_SUBJECT" "$(cat "$1/pid")" >> "$FM_TEST_EVENTS"
    IFS= read -r _ < "$FM_TEST_RESUME"' "$lock" &
  holder=$!
  dirlock_expect "a held pid=$holder" "D11: ambiguous record was not refused by its own holder"
  before=$(dirlock_tree "$dir")
  [ "$(printf '%s\n' "$before" | grep -c '/pid$')" = 3 ] || fail "D11: release touched the ambiguous record: $before"
  FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$dir/state" bash -c '. "$0"; ! fm_lock_try_acquire "$1"' "$LIB" "$lock" \
    || fail "D11: contender acquired an ambiguous live record"
  [ "$(dirlock_tree "$dir")" = "$before" ] || fail "D11: contender changed the ambiguous record"
  printf 'go\n' >&7
  wait "$holder" || fail "D11: holder subject failed"
  dirlock_close
  pass "D11: a record with more than one generation is invalid and never released or taken"
}

# D11c runs D11b on the watcher lock, whose stale recovery first publishes
# downtime evidence: an invalid record must be refused before that too.
test_dirlock_d11b_dead_ambiguous_generation_is_refused() {
  local dir lock dead before out row
  for row in D11b:.d.lock D11c:.watch.lock; do
    dir=$(dirlock_case "dirlock-${row%%:*}")
    lock="$dir/state/${row#*:}"
    row=${row%%:*}
    dirlock_open "$dir"
    dead=$(dead_pid)
    mkdir -p "$lock/.owner.first1" "$lock/.owner.secnd2"
    printf '%s\n' "$dead" > "$lock/pid"
    printf '%s\n' "$dead" > "$lock/.owner.first1/pid"
    printf '%s\n' "$dead" > "$lock/.owner.secnd2/pid"
    before=$(dirlock_tree "$dir")
    out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$dir/state" bash -c '
      . "$0"
      if fm_lock_try_acquire "$1"; then echo acquired; else echo refused; fi' "$LIB" "$lock")
    [ "$out" = refused ] || fail "$row: contender acted on an invalid dead record: $out"
    [ "$(dirlock_tree "$dir")" = "$before" ] || fail "$row: invalid dead record or its state was changed: $(dirlock_tree "$dir")"
    dirlock_close
  done
  pass "D11b: an invalid dead record fails closed before destructive cleanup"
  pass "D11c: an invalid dead watcher record is refused before downtime evidence is published"
}

test_dirlock_d12_staging_litter_is_never_consulted() {
  local dir lock sleeper before
  dir=$(dirlock_case dirlock-d12)
  lock="$dir/state/.d.lock"
  sleep 300 &
  sleeper=$!
  mkdir -p "$lock.owner.livepb/.owner.livepb" "$lock.owner.deadpb/.owner.deadpb"
  printf '%s\n' "$sleeper" > "$lock.owner.livepb/pid"
  printf '%s\n' "$sleeper" > "$lock.owner.livepb/.owner.livepb/pid"
  printf '%s\n' "$(dead_pid)" > "$lock.owner.deadpb/pid"
  printf '%s\n' "$(dead_pid)" > "$lock.owner.deadpb/.owner.deadpb/pid"
  before=$(dirlock_tree "$dir")
  # shellcheck disable=SC2016
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$0"
    fm_lock_try_acquire "$1" || exit 10
    fm_lock_release "$1"
    [ ! -e "$1" ] || exit 11
    fm_lock_try_acquire "$1" || exit 12
    fm_lock_release "$1"' "$LIB" "$lock" || fail "D12: staging litter interfered with acquire and release"
  [ "$(dirlock_tree "$dir")" = "$before" ] || fail "D12: lock operations changed staging litter: $(dirlock_tree "$dir")"
  kill "$sleeper"
  wait "$sleeper" 2>/dev/null
  pass "D12: staging directories beside a directory lock are never read or removed"
}


test_direct_directory_lock_release_and_reap
test_lock_without_real_symlinks
test_directory_lock_single_winner_under_load
test_dirlock_d1b_failed_claim_leaves_generation_to_retirement
test_dirlock_d5_orphan_retirement_cannot_touch_successor
test_dirlock_d5b_stealer_retires_only_captured_generation
test_dirlock_d5c_acquirer_retires_captured_generation
test_dirlock_d6_late_publication_is_ordinary_recovery
test_dirlock_d8_dead_steal_mutex_observers_compose
test_dirlock_d8b_reaper_retires_captured_generation
test_dirlock_d9_uncommitted_retirement_keeps_record
test_dirlock_d10_committed_retirement_is_finished
test_dirlock_d11_ambiguous_generation_is_refused
test_dirlock_d11b_dead_ambiguous_generation_is_refused
test_dirlock_d12_staging_litter_is_never_consulted
