#!/usr/bin/env bash
# Interrupted directory-lock owners, bounded handoff and Bash frame identity.
set -u

# shellcheck source=tests/directory-lock-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/directory-lock-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-directory-lock-tests)

test_dirlock_d1_unpublished_staging_is_private() {
  local dir lock publisher contender staging rc
  dir=$(dirlock_case "dirlock-d1${DIRLOCK_TAG:-}")
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" a b
  # shellcheck disable=SC2016
  dirlock_spawn "$dir" a "publish:pre:wait:$lock" '
    fm_lock_try_acquire "$1"; printf "%s\n" "$?" > "$2"' "$lock" "$dir/a.rc" &
  publisher=$!
  dirlock_expect "a publish:pre:$lock" "D1: publisher did not reach its publication rename"
  [ ! -e "$lock" ] && [ ! -L "$lock" ] || fail "D1: L absent at barrier"
  for staging in "$lock".owner.*; do :; done
  [ -f "$staging/pid" ] && [ -d "$staging/.owner.${staging##*.owner.}" ] \
    || fail "D1: staged record is incomplete before publication: $(dirlock_tree "$dir")"
  dirlock_spawn "$dir" b "" "$DIRLOCK_HOLD" "$lock" "$dir/b.id" &
  contender=$!
  dirlock_expect "b held pid=$contender" "D1: contender did not acquire while the publisher was staged"
  printf 'go\n' >&7
  dirlock_expect "a done rc=1" "D1: publication rename did not fail onto the held lock"
  wait "$publisher" || fail "D1: publisher subject failed"
  rc=$(cat "$dir/a.rc")
  [ "$rc" = 1 ] || fail "D1: publisher acquired a held lock (rc=$rc)"
  [ ! -e "$staging" ] || fail "D1: publisher left its staging directory after a refused publication"
  [ "$(cat "$lock/pid")" = "$contender" ] || fail "D1: contender record changed"
  printf 'go\n' >&8
  wait "$contender" || fail "D1: contender could not release"
  dirlock_close
  dirlock_assert_clean "$dir" "D1: lock residue"
  pass "D1${DIRLOCK_TAG:-}: a staged directory record stays private and its creator discards it on refusal"
}

test_dirlock_d2_published_record_is_complete() {
  local dir lock publisher out generations
  dir=$(dirlock_case "dirlock-d2${DIRLOCK_TAG:-}")
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" a
  # shellcheck disable=SC2016
  dirlock_spawn "$dir" a "publish:post:wait:$lock" '
    sh -c '\''printf "%s\n" "$PPID"'\'' > "$2" || exit 9
    fm_lock_try_acquire "$1" || exit 10
    fm_lock_release "$1"' "$lock" "$dir/a.id" &
  publisher=$!
  dirlock_expect "a publish:post:$lock" "D2: publisher did not reach the end of its publication rename"
  [ "$(cat "$dir/a.id")" = "$publisher" ] || fail "D2: publisher identity is not its frame pid"
  # shellcheck disable=SC2016
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$dir/state" "${DIRLOCK_BASH:-bash}" -c '
    . "$0"
    if fm_lock_try_acquire "$1"; then echo stolen; else echo "held=$FM_LOCK_HELD_PID"; fi' "$LIB" "$lock")
  [ "$out" = "held=$publisher" ] || fail "D2: contender did not see the publisher hold a complete record: $out"
  [ "$(cat "$lock/pid")" = "$publisher" ] || fail "D2: L/pid is not the publisher"
  generations=$(cd "$lock" && find . -mindepth 1 -maxdepth 1 -name '.owner.*' -type d | wc -l | tr -d ' ')
  [ "$generations" = 1 ] || fail "D2: published record has $generations generation directories"
  printf 'go\n' >&7
  wait "$publisher" || fail "D2: publisher could not claim and release"
  dirlock_close
  dirlock_assert_clean "$dir" "D2: release residue"
  [ -z "$(find "$dir/state" -name '*.owner.*' -print)" ] || fail "D2: owner residue"
  pass "D2${DIRLOCK_TAG:-}: a just-published directory record is complete and owned by its live publisher"
}

test_dirlock_d3_dead_holder_recovers_without_age() {
  local dir lock holder stale out
  for stale in 0 3600; do
    dir=$(dirlock_case "dirlock-d3-$stale${DIRLOCK_TAG:-}")
    lock="$dir/state/.d.lock"
    dirlock_open "$dir" a
    dirlock_spawn "$dir" a "" "$DIRLOCK_HOLD" "$lock" "$dir/a.id" &
    holder=$!
    dirlock_expect "a held pid=$holder" "D3: holder did not acquire"
    [ "$(cat "$dir/a.id")" = "$holder" ] || fail "D3: holder identity is not its frame pid"
    kill -KILL "$holder"
    wait "$holder" 2>/dev/null
    ! kill -0 "$holder" 2>/dev/null || fail "D3: holder survived SIGKILL"
    # shellcheck disable=SC2016
    out=$(PATH="$dir/fakebin:$PATH" FM_LOCK_STALE_AFTER=$stale FM_STATE_OVERRIDE="$dir/state" \
      "${DIRLOCK_BASH:-bash}" -c '
      . "$0"
      fm_lock_try_acquire "$1" || { echo "refused held=$FM_LOCK_HELD_PID"; exit 0; }
      echo "recovered=$FM_LOCK_RECOVERED_PID"
      fm_lock_release "$1"' "$LIB" "$lock")
    [ "$out" = "recovered=$holder" ] || fail "D3: dead holder not recovered with stale-after=$stale: $out"
    dirlock_close
    dirlock_assert_clean "$dir" "D3: recovery residue"
  done
  pass "D3${DIRLOCK_TAG:-}: a dead directory holder is recovered at once regardless of age"
}

test_dirlock_d4_crashed_release_is_finished() {
  local dir lock holder spec out generation
  for spec in retire:post discard:partial husk:pre; do
    dir=$(dirlock_case "dirlock-d4-${spec%%:*}")
    lock="$dir/state/.d.lock"
    dirlock_open "$dir" a
    # shellcheck disable=SC2016
    dirlock_spawn "$dir" a "$spec:kill:$lock" '
      fm_lock_try_acquire "$1" || exit 10
      fm_lock_release "$1"
      exit 11' "$lock" &
    holder=$!
    dirlock_expect "a $spec:$lock" "D4: releaser did not reach $spec"
    wait "$holder" 2>/dev/null
    ! kill -0 "$holder" 2>/dev/null || fail "D4: releaser survived its $spec kill"
    generation=$(dirlock_generation "$lock")
    case "$spec" in
      retire:post)
        [ ! -e "$lock/pid" ] && [ -f "$generation/pid.retired" ] \
          || fail "D4: retire post is not a committed retirement: $(dirlock_tree "$dir")" ;;
      discard:partial)
        [ ! -e "$lock/pid" ] && [ -f "$generation/pid" ] && [ ! -e "$generation/pid.retired" ] \
          || fail "D4: discard partial is not a partly deleted generation: $(dirlock_tree "$dir")" ;;
      husk:pre)
        [ -d "$lock" ] && [ "$(dirlock_tree "$dir")" = ./.d.lock ] \
          || fail "D4: husk pre is not an empty lock directory: $(dirlock_tree "$dir")" ;;
    esac
    # shellcheck disable=SC2016
    out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$dir/state" bash -c '
      . "$0"
      fm_lock_try_acquire "$1" || { echo refused; exit 0; }
      echo "recovered=$FM_LOCK_RECOVERED_PID"
      fm_lock_release "$1"' "$LIB" "$lock")
    if [ "$spec" = husk:pre ]; then
      [ "$out" = refused ] || fail "D4: an empty lock directory was taken inside its grace: $out"
      touch -t 200001010000 "$lock"
      # shellcheck disable=SC2016
      out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$dir/state" bash -c '
        . "$0"
        fm_lock_try_acquire "$1" || { echo refused; exit 0; }
        echo acquired
        fm_lock_release "$1"' "$LIB" "$lock")
      [ "$out" = acquired ] || fail "D4: an aged empty lock directory was not recovered: $out"
    else
      [ "$out" = "recovered=$holder" ] || fail "D4: crashed release at $spec was not finished: $out"
    fi
    dirlock_close
    dirlock_assert_clean "$dir" "D4: $spec residue"
  done
  pass "D4: a release killed after commit, mid-delete or before the final rmdir is finished by the next acquirer"
}

# D4b: after a bounded handoff only L/pid names the caller, so a release by
# the caller killed after its commit is recovered as the caller, not as the
# helper whose pid the generation still records.
test_dirlock_d4b_handoff_release_recovers_caller() {
  local dir lock caller generation out
  dir=$(dirlock_case dirlock-d4b)
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" c
  # shellcheck disable=SC2016
  dirlock_spawn "$dir" c "retire:post:kill:$lock" '
    printf "%s ready\n" "$FM_TEST_SUBJECT" >> "$FM_TEST_EVENTS"
    IFS= read -r _ < "$FM_TEST_RESUME"
    fm_lock_release "$1"
    exit 11' "$lock" &
  caller=$!
  dirlock_expect "c ready" "D4b: caller did not start"
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" bash -c '. "$0"; _fm_lock_acquire_wait_handoff "$1" "$2"' \
    "$LIB" "$lock" "$caller" || fail "D4b: helper could not hand the lock to the caller"
  generation=$(dirlock_generation "$lock")
  [ "$(cat "$lock/pid" 2>/dev/null)" = "$caller" ] && [ -f "$generation/pid" ] \
    && [ "$(cat "$generation/pid")" != "$caller" ] \
    || fail "D4b: handoff did not change only L/pid: $(dirlock_tree "$dir")"
  printf 'go\n' >&7
  dirlock_expect "c retire:post:$lock" "D4b: caller release did not reach its committed retirement"
  wait "$caller" 2>/dev/null
  ! kill -0 "$caller" 2>/dev/null || fail "D4b: caller survived its retire kill"
  [ ! -e "$lock/pid" ] && [ "$(cat "$generation/pid.retired" 2>/dev/null)" = "$caller" ] \
    || fail "D4b: caller release is not a committed retirement: $(dirlock_tree "$dir")"
  # shellcheck disable=SC2016
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$0"
    fm_lock_try_acquire "$1" || { echo refused; exit 0; }
    echo "recovered=$FM_LOCK_RECOVERED_PID"
    fm_lock_release "$1"' "$LIB" "$lock")
  [ "$out" = "recovered=$caller" ] || fail "D4b: handed-off release was not recovered as the caller: $out"
  dirlock_close
  dirlock_assert_clean "$dir" "D4b: residue"
  pass "D4b: a handed-off release killed after commit is recovered as the caller"
}

test_dirlock_d7_handoff_transient_follows_generation_pid() {
  local dir lock sleeper out
  dir=$(dirlock_case "dirlock-d7${DIRLOCK_TAG:-}")
  lock="$dir/state/.d.lock"
  sleep 300 &
  sleeper=$!
  mkdir -p "$lock/.owner.handof"
  printf '%s\n' "$sleeper" > "$lock/.owner.handof/pid"
  : > "$lock/pid"
  touch -t 200001010000 "$lock" "$lock/pid"
  # shellcheck disable=SC2016
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$dir/state" "${DIRLOCK_BASH:-bash}" -c '
    . "$0"
    if fm_lock_try_acquire "$1"; then echo stolen; else echo refused; fi' "$LIB" "$lock")
  [ "$out" = refused ] || fail "D7: an empty pid with a live generation pid was stolen: $out"
  [ -e "$lock/pid" ] && [ -f "$lock/.owner.handof/pid" ] || fail "D7: contender changed the handoff record"
  kill "$sleeper"
  wait "$sleeper" 2>/dev/null
  # shellcheck disable=SC2016
  out=$(FM_LOCK_STALE_AFTER=0 FM_STATE_OVERRIDE="$dir/state" "${DIRLOCK_BASH:-bash}" -c '
    . "$0"
    fm_lock_try_acquire "$1" || { echo refused; exit 0; }
    echo "recovered=$FM_LOCK_RECOVERED_PID"
    fm_lock_release "$1"' "$LIB" "$lock")
  [ "$out" = "recovered=$sleeper" ] || fail "D7: a dead handoff helper's record was not recovered: $out"
  dirlock_assert_clean "$dir" "D7: residue"
  pass "D7${DIRLOCK_TAG:-}: an empty handoff pid is held exactly while the generation's pid lives"
}

test_dirlock_d7b_bounded_helper_killed_by_deadline() {
  local dir lock holder caller out
  dir=$(dirlock_case dirlock-d7b)
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" h c
  dirlock_spawn "$dir" h "" "$DIRLOCK_HOLD" "$lock" "$dir/h.id" &
  holder=$!
  dirlock_expect "h held pid=$holder" "D7': holder did not acquire"
  # The caller announces its timed helper; the helper's own publication then
  # pauses until the deadline kills it before the handoff write.
  # shellcheck disable=SC2016
  dirlock_spawn "$dir" c "publish:post:wait:$lock" '
    _fm_wake_require_timeout || exit 9
    eval "_dirlock_run_timed() $(declare -f fm_run_timed | tail -n +2)"
    fm_run_timed() { printf "c helper-start\n" >> "$FM_TEST_EVENTS"; _dirlock_run_timed "$@"; }
    sh -c '\''printf "%s\n" "$PPID"'\'' > "$2" || exit 8
    rc=0; fm_lock_acquire_wait_bounded "$1" 2 || rc=$?
    printf "rc=%s pid=%s\n" "$rc" "$(cat "$1/pid" 2>/dev/null)" > "$3"
    [ "$rc" -ne 0 ] || fm_lock_release "$1"' "$lock" "$dir/c.id" "$dir/c.out" &
  caller=$!
  dirlock_expect "c helper-start" "D7': caller did not start its timed helper"
  printf 'go\n' >&7
  wait "$holder" || fail "D7': holder could not release"
  dirlock_expect "c publish:post:$lock" "D7': helper did not acquire after the holder released"
  wait "$caller" || fail "D7': caller subject failed"
  out=$(cat "$dir/c.out")
  [ "$out" = "rc=0 pid=$caller" ] || fail "D7': caller did not end holding after its helper was killed: $out"
  dirlock_close
  dirlock_assert_clean "$dir" "D7': residue"
  pass "D7': a bounded helper killed by its deadline after acquiring leaves the caller holding"
}

test_dirlock_d16_pre_v2_record_recovers_as_raw() {
  local dir lock old lock_abs out
  dir=$(dirlock_case dirlock-d16)
  lock="$dir/state/.d.lock"
  lock_abs="$(cd "$dir/state" && pwd -P)/.d.lock"
  old="$lock_abs.owner.oldv1x"
  mkdir -p "$lock" "$old"
  dead_pid > "$old/pid"
  cp "$old/pid" "$lock/pid"
  printf '%s\n' "$old" > "$lock/.owner"
  # shellcheck disable=SC2016
  out=$(PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$0"
    fm_lock_try_acquire "$1" || { echo refused; exit 0; }
    fm_current_pid me
    owner=$(fm_lock_link_owner "$1") || { echo no-owner; exit 0; }
    [ "$(cat "$1/pid")" = "$me" ] && [ "$owner" = "$FM_LOCK_OWNER_DIR" ] && [ ! -e "$1/.owner" ] \
      && case "$owner" in "$1"/.owner.*|*/.d.lock/.owner.*) true ;; *) false ;; esac || { echo not-v2; exit 0; }
    fm_lock_release "$1"
    echo republished' "$LIB" "$lock")
  [ "$out" = republished ] || fail "D16: a dead pre-v2 record was not recovered into the v2 layout: $out"
  [ "$(dirlock_tree "$dir")" = "./${old##*/}
./${old##*/}/pid" ] || fail "D16: expected only the inert pre-v2 private directory: $(dirlock_tree "$dir")"
  pass "D16: a dead pre-v2 directory record is recovered as raw, leaving its private directory inert"
}

test_dirlock_d17_subshell_publisher_identity() {
  local dir lock holder recorded
  dir=$(dirlock_case "dirlock-d17${DIRLOCK_TAG:-}")
  lock="$dir/state/.d.lock"
  dirlock_open "$dir" a
  # shellcheck disable=SC2016
  dirlock_spawn "$dir" a "" '
    (
      sh -c '\''printf "%s\n" "$PPID"'\'' > "$2" || exit 9
      fm_lock_try_acquire "$1" || exit 10
      printf "%s held pid=%s\n" "$FM_TEST_SUBJECT" "$(cat "$1/pid")" >> "$FM_TEST_EVENTS"
      IFS= read -r _ < "$FM_TEST_RESUME"
      fm_lock_release "$1"
    ) &
    wait "$!"' "$lock" "$dir/a.id" &
  holder=$!
  dirlock_expect "a held pid=" "D17: subshell publisher did not acquire"
  recorded=$(cat "$dir/a.id")
  [ "$(dirlock_event_field pid)" = "$recorded" ] && [ "$recorded" != "$holder" ] \
    && [ "$(cat "$(dirlock_generation "$lock")/pid")" = "$recorded" ] \
    || fail "D17: subshell publisher recorded $(dirlock_event_field pid), expected its own frame $recorded"
  printf 'go\n' >&7
  wait "$holder" || fail "D17: subshell publisher could not release"
  dirlock_close
  dirlock_assert_clean "$dir" "D17: residue"
  pass "D17${DIRLOCK_TAG:-}: a background-subshell publisher records its own frame identity"
}

# D17: the identity-sensitive cases also run under stock macOS Bash 3.2, whose
# fm_current_pid has no BASHPID. A shell whose version already ran is skipped:
# on Linux both names are the same Bash, and its rows would reuse the fixtures.
test_dirlock_identity_cases_per_shell() {
  local shell version seen=" "
  for shell in bash /bin/bash; do
    command -v "$shell" >/dev/null 2>&1 || continue
    # shellcheck disable=SC2016 # Expanded by the probed shell.
    version=$("$shell" -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"')
    case "$seen" in *" $version "*) continue ;; esac
    seen="$seen$version "
    DIRLOCK_BASH=$shell DIRLOCK_TAG="-bash-$version"
    export DIRLOCK_BASH
    test_dirlock_d1_unpublished_staging_is_private
    test_dirlock_d2_published_record_is_complete
    test_dirlock_d3_dead_holder_recovers_without_age
    test_dirlock_d7_handoff_transient_follows_generation_pid
    test_dirlock_d17_subshell_publisher_identity
  done
  unset DIRLOCK_BASH DIRLOCK_TAG
}

test_dirlock_identity_cases_per_shell
test_dirlock_d4_crashed_release_is_finished
test_dirlock_d4b_handoff_release_recovers_caller
test_dirlock_d7b_bounded_helper_killed_by_deadline
test_dirlock_d16_pre_v2_record_recovers_as_raw
