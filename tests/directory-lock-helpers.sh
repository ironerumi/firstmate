#!/usr/bin/env bash
# Shared FIFO/barrier fixtures for the fork's directory-lock regression suites.
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

LIB="$ROOT/bin/fm-wake-lib.sh"

# --- copied-link directory-record protocol -----------------------------------
# These cases force directory mode with a copying ln and pause or kill the
# protocol's external children through barrier shims. A subject sets
# FM_TEST_BARRIERS to space-separated role:stage:action:lock specs; each spec
# fires once per subject. A firing shim appends
# "<subject> <role>:<stage>:<lock> pid=<shim> caller=<frame>" to FM_TEST_EVENTS,
# then acts: wait (block on FM_TEST_RESUME), kill (SIGKILL the calling frame),
# fail (skip the operation, exit 1) or none. A pre-stage shim reports
# "<subject> done rc=<rc>" after the real operation, so an orphaned child's
# outcome is observable after its frame died.
# Roles: publish = perl rename onto <lock>; retire = perl rename of <lock>/pid;
# discard = rm -rf <lock>/.owner.* (stage partial deletes pid.retired only);
# husk = rmdir <lock>. Stage skip-role drops <lock>/role from a retire rename.
dirlock_case() {  # <name>
  local dir tool
  dir=$(make_case "$1")
  # shellcheck disable=SC2016 # The shim expands its own arguments.
  printf '#!/usr/bin/env bash\nif [ "$1" = -s ]; then exec cp -R "$2" "$3"; fi\nexec %q "$@"\n' \
    "$(fm_real_tool ln)" > "$dir/fakebin/ln"
  chmod +x "$dir/fakebin/ln"
  for tool in perl rm rmdir; do
    { printf '#!/usr/bin/env bash\nFM_TEST_TOOL=%s\nFM_TEST_REAL=%q\n' "$tool" "$(fm_real_tool "$tool")"
      cat <<'SH'
set -u
[ -n "${FM_TEST_BARRIERS:-}" ] || exec "$FM_TEST_REAL" "$@"
barrier_match() {
  local spec i=0 r s a l
  for spec in $FM_TEST_BARRIERS; do
    i=$((i + 1))
    IFS=: read -r r s a l <<< "$spec"
    case "$FM_TEST_TOOL:$r" in
      perl:publish) [ "${!#}" = "$l" ] || continue ;;
      perl:retire) case " $* " in *" $l/pid "*) ;; *) continue ;; esac ;;
      rm:discard) [ "$#" -eq 2 ] && [ "$1" = -rf ] || continue
        case "$2" in "$l"/.owner.*) ;; *) continue ;; esac ;;
      rmdir:husk) [ "$#" -eq 1 ] && [ "$1" = "$l" ] || continue ;;
      *) continue ;;
    esac
    mkdir "$FM_TEST_BARRIER_DIR/fired.$i" 2>/dev/null || continue
    role=$r stage=$s action=$a lock=$l
    return 0
  done
  return 1
}
barrier() {
  printf '%s %s:%s:%s pid=%s caller=%s\n' "$FM_TEST_SUBJECT" "$role" "$stage" "$lock" "$$" "$PPID" >> "$FM_TEST_EVENTS"
  case "$action" in
    wait) IFS= read -r _ < "$FM_TEST_RESUME" ;;
    kill) kill -KILL "$PPID"; exit 1 ;;
    fail) exit 1 ;;
  esac
}
barrier_match "$@" || exec "$FM_TEST_REAL" "$@"
case "$stage" in
  pre)
    barrier
    rc=0; "$FM_TEST_REAL" "$@" || rc=$?
    printf '%s done rc=%s\n' "$FM_TEST_SUBJECT" "$rc" >> "$FM_TEST_EVENTS"
    exit "$rc" ;;
  post) rc=0; "$FM_TEST_REAL" "$@" || rc=$?; barrier; exit "$rc" ;;
  partial) "$FM_TEST_REAL" -f "$2/pid.retired"; barrier; exit 1 ;;
  skip-role)
    args=()
    for arg in "$@"; do [ "$arg" = "$lock/role" ] || args+=("$arg"); done
    barrier; exec "$FM_TEST_REAL" "${args[@]}" ;;
esac
SH
    } > "$dir/fakebin/$tool"
    chmod +x "$dir/fakebin/$tool"
  done
  mkfifo "$dir/events"
  printf '%s\n' "$dir"
}

# dirlock_spawn <dir> <subject> <barriers> <script> [args...] - run with `&`:
# it execs the subject so $! is the subject frame. The script sees the lock
# library loaded and its own arguments as "$@". Output goes to the case's
# <subject>.log so a subject left paused by a failed case holds no test pipe.
dirlock_spawn() {
  local dir=$1 subject=$2 barriers=$3 script=$4
  shift 4
  mkdir -p "$dir/barrier.$subject"
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" FM_TEST_SUBJECT="$subject" \
    FM_LOCK_STALE_AFTER="${FM_LOCK_STALE_AFTER:-2}" \
    FM_TEST_BARRIERS="$barriers" FM_TEST_BARRIER_DIR="$dir/barrier.$subject" \
    FM_TEST_EVENTS="$dir/events" FM_TEST_RESUME="$dir/resume.$subject" \
    exec "${DIRLOCK_BASH:-bash}" -c ". \"\$0\"; $script" "$LIB" "$@" >> "$dir/$subject.log" 2>&1
}

# Open the shared event stream on fd 6 and one resume FIFO per named subject
# on fds 7, 8, 9 in order.
dirlock_open() {  # <dir> <subject>...
  local dir=$1 fd=7 subject
  shift
  exec 6<> "$dir/events"
  for subject in "$@"; do
    mkfifo "$dir/resume.$subject"
    eval "exec $fd<> \"\$dir/resume.\$subject\""
    fd=$((fd + 1))
  done
}

dirlock_close() {
  exec 6>&- 7>&- 8>&- 9>&-
}

# Read the next event and require its prefix; leaves the line in DIRLOCK_EVENT.
dirlock_expect() {  # <prefix> <failure>
  DIRLOCK_EVENT=
  IFS= read -r -t 30 DIRLOCK_EVENT <&6 || fail "$2 (no event, expected '$1')"
  case "$DIRLOCK_EVENT" in
    "$1"*) ;;
    *) fail "$2 (event '$DIRLOCK_EVENT', expected '$1')" ;;
  esac
}

dirlock_event_field() {  # <field>
  local value=${DIRLOCK_EVENT##* "$1"=}
  printf '%s\n' "${value%% *}"
}

# The lock's generation directory path (the glob itself when there is none).
dirlock_generation() {  # <lock>
  local generation
  for generation in "$1"/.owner.*; do :; done
  printf '%s\n' "$generation"
}

# Everything under the state directory.
dirlock_tree() {  # <dir>
  (cd "$1/state" && find . -mindepth 1 -print | LC_ALL=C sort)
}

dirlock_assert_clean() {  # <dir> <failure>
  local left
  left=$(dirlock_tree "$1")
  [ -z "$left" ] || fail "$2: left $left"
}

# A holder script: acquire, publish identity and pid, wait for resume, release.
# shellcheck disable=SC2016 # Expanded by the subject shell.
DIRLOCK_HOLD='sh -c '\''printf "%s\n" "$PPID"'\'' > "$2" || exit 9
fm_lock_try_acquire "$1" || exit 10
printf "%s held pid=%s\n" "$FM_TEST_SUBJECT" "$(cat "$1/pid")" >> "$FM_TEST_EVENTS"
IFS= read -r _ < "$FM_TEST_RESUME"
fm_lock_release "$1"'

# A subject script that pauses its first fm_lock_remove_path of <lock> (the
# mutation after its stale recheck), runs <call> on <lock>, and reports
# "<subject> finished out=<result>" so a wrong outcome fails within the event
# deadline instead of blocking on the pause.
# shellcheck disable=SC2016 # Expanded by the subject shell.
DIRLOCK_PAUSE_REMOVE='target=$1 paused=
original=$(declare -f fm_lock_remove_path)
eval "${original/fm_lock_remove_path/_fm_original_remove_path}"
fm_lock_remove_path() {
  if [ -z "$paused" ] && [ "$1" = "$target" ]; then
    paused=1
    printf "%s remove:pre:%s\n" "$FM_TEST_SUBJECT" "$target" >> "$FM_TEST_EVENTS"
    IFS= read -r _ < "$FM_TEST_RESUME"
  fi
  _fm_original_remove_path "$@"
}'

# Replace the paused subject's dead record with a live successor held by this
# test shell, retiring the dead generation the way a competing reaper does.
dirlock_replace_with_live_successor() {  # <dir> <lock> <row>
  local dir=$1 lock=$2 row=$3 live_stage
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" bash -c '. "$0"; fm_lock_remove_path "$1"' "$LIB" "$lock" \
    || fail "$row: could not retire the captured dead generation"
  [ ! -e "$lock" ] || fail "$row: dead generation retirement left the lock"
  live_stage="$lock.owner.live000"
  mkdir -p "$live_stage/.owner.live000"
  printf '%s\n' "$$" > "$live_stage/pid"
  printf '%s\n' "$$" > "$live_stage/.owner.live000/pid"
  mv "$live_stage" "$lock"
}

dirlock_assert_live_successor() {  # <dir> <lock> <row>
  [ "$(cat "$2/pid" 2>/dev/null)" = "$$" ] && [ -f "$2/.owner.live000/pid" ] \
    || fail "$3: successor record changed: $(dirlock_tree "$1")"
  rm -rf "$2"
}
