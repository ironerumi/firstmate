#!/usr/bin/env bash
# tests/fm-session-lock-ancestry.test.sh - session-lock harness identity
# (bin/fm-session-lock-lib.sh).
#
# Two layers. The unit cases drive the library's own functions behind a
# deterministic fake ps, so both platforms' reporting semantics are covered from
# either host: macOS reports argv[0] in `ps -o comm=`, while procps on Linux
# reports the kernel exec name and ignores argv[0] entirely. The end-to-end cases
# run the REAL Stop auto-arm inside real process trees whose shapes differ only
# in how the per-session process is named and what its parent is. Those trees are
# orphaned before the hook fires, so the ancestry walk terminates inside the
# fixture and can never escape into the session running this suite.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-ancestry)
fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-session-lock-lib.sh"

# Claude Code's native installer names the per-session executable by its version,
# so the harness identity has to survive a basename that says nothing.
CLAUDE_VERSION_DIR="$TMP_ROOT/claude-install/share/claude/versions"
mkdir -p "$CLAUDE_VERSION_DIR"
ln -s /bin/bash "$CLAUDE_VERSION_DIR/2.1.220"
VERSIONED_CLAUDE="$CLAUDE_VERSION_DIR/2.1.220"

FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/claude"
NAMED_CLAUDE="$FAKEBIN/claude"

# --- unit layer: identity behind a deterministic process table ---------------

# Pin POSIX unit fixtures independently of the host's uname output.
posix_fakebin() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' Linux
SH
  chmod +x "$fakebin/uname"
  printf '%s\n' "$fakebin"
}

# Run one library expression with <fakebin> shadowing ps. kill is stubbed so
# liveness questions are decided by the process table alone (FM_TEST_KILL_RC=1
# makes every pid dead). The suite itself may run inside a Claude session whose
# CLAUDE_CODE_SESSION_ID and CLAUDE_PID would leak into the expression, so both
# are scrubbed and only FM_TEST_SESSION_ID and FM_TEST_CLAUDE_PID reach it.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  local -a session_env=()
  [ -z "${FM_TEST_SESSION_ID:-}" ] || session_env+=("CLAUDE_CODE_SESSION_ID=$FM_TEST_SESSION_ID")
  [ -z "${FM_TEST_CLAUDE_PID:-}" ] || session_env+=("CLAUDE_PID=$FM_TEST_CLAUDE_PID")
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID ${session_env[@]+"${session_env[@]}"} \
    PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    kill() { return \${FM_TEST_KILL_RC:-0}; }
    $expr
  " "$LIB"
}

test_version_named_session_is_identified_on_both_platforms() {
  local dir fakebin shape got
  dir="$TMP_ROOT/version-named"
  fakebin=$(posix_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_CLAUDE_SHAPE:-linux}" in
  700:comm=:linux) printf '%s\n' '2.1.220' ;;
  700:args=:linux) printf '%s\n' '/opt/claude/versions/2.1.220 --resume' ;;
  700:comm=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220' ;;
  700:args=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220 --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '700\n' > "$dir/state/.lock"

  for shape in linux macos; do
    got=$(FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
      || fail "$shape: the version-named session was not found in the ancestry at all"
    [ "$got" = 700 ] || fail "$shape: ancestry resolved '$got', expected the version-named session pid 700"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      || fail "$shape: a live version-named session was not recognized as a harness"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
      || fail "$shape: the session holding the lock did not recognize itself as the owner"
  done
  pass "session-lock: a version-named Claude Code session is identified from its install path and argv[0]"
}

# A harness that is pid 1 of its own PID namespace - a container, or the
# `codex sandbox` this shape was verified in - used to be invisible: the walk
# stopped as soon as the NEXT pid was 1, so the one process that identifies the
# session was never examined and the session could not recognize its own lock.
test_harness_at_namespace_pid1_is_examined() {
  local dir fakebin got
  dir="$TMP_ROOT/namespace-pid1"
  fakebin=$(posix_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  1:comm=) printf '%s\n' "${FM_TEST_PID1_COMM:-claude}" ;;
  1:args=) printf '%s\n' "${FM_TEST_PID1_COMM:-claude}" ;;
  1:ppid=) printf '%s\n' 0 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/fm-watch.sh' ;;
  *:ppid=) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '1\n' > "$dir/state/.lock"

  # Non-vacuity: with a host-shaped pid 1 the same table must find nothing, so
  # this case cannot pass by the walk matching everything it reaches.
  if FM_TEST_PID1_COMM=systemd lib_eval "$fakebin" 'fm_harness_ancestry_pid' >/dev/null 2>&1; then
    fail "a host-shaped pid 1 was read as a harness process"
  fi

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "the harness at namespace pid 1 was not found in the ancestry at all"
  [ "$got" = 1 ] || fail "ancestry resolved '$got', expected the namespace harness pid 1"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the session holding the lock at namespace pid 1 did not recognize itself as the owner"
  pass "session-lock: a harness that is pid 1 of its own namespace is examined, not skipped"
}

test_ordinary_paths_are_never_harness_processes() {
  local dir fakebin shape
  dir="$TMP_ROOT/ordinary-paths"
  fakebin=$(posix_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_PATH_SHAPE:-hookdir}" in
  810:comm=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh' ;;
  810:args=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh --quiet' ;;
  810:comm=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner' ;;
  810:args=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner --once' ;;
  810:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-watch-arm.sh' ;;
  *:ppid=:*) printf '%s\n' 810 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '810\n' > "$dir/state/.lock"

  # Identity may be read from an executable path, but only from whole path
  # components: anything merely living under ~/.claude, and any component that
  # merely starts with a harness name, must stay outside the harness identity.
  for shape in hookdir piprefix; do
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
      fail "$shape: an ordinary script path was treated as a harness process"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 810'; then
      fail "$shape: an ordinary script path passed the harness-liveness predicate"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
      fail "$shape: an ordinary script path claimed the home's session lock"
    fi
  done
  pass "session-lock: ordinary script paths under a harness directory are not harness processes"
}

test_harness_beyond_a_gap_never_owns_the_lock() {
  local dir fakebin got
  dir="$TMP_ROOT/gap"
  fakebin=$(posix_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  900:comm=) printf '%s\n' claude ;;
  900:args=) printf '%s\n' 'claude' ;;
  900:ppid=) printf '%s\n' 910 ;;
  910:comm=) printf '%s\n' bash ;;
  910:args=) printf '%s\n' 'bash tests/run.sh' ;;
  910:ppid=) printf '%s\n' 920 ;;
  920:comm=) printf '%s\n' claude ;;
  920:args=) printf '%s\n' 'claude' ;;
  920:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 900 ;;
esac
SH
  chmod +x "$fakebin/ps"

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "the contiguous harness run was not resolved"
  [ "$got" = 900 ] || fail "ancestry crossed a non-harness gap, resolved '$got' instead of 900"
  printf '920\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "an unrelated harness beyond a non-harness gap was accepted as this session's lock owner"
  fi
  printf '900\n' > "$dir/state/.lock"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the contiguous harness run did not recognize its own lock"
  pass "session-lock: ownership stops at the first non-harness gap above the contiguous run"
}

test_competing_version_named_session_is_seen_as_live() {
  local dir fakebin
  dir="$TMP_ROOT/competing"
  fakebin=$(posix_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  600:comm=) printf '%s\n' '2.1.220' ;;
  600:args=) printf '%s\n' '/opt/claude/versions/2.1.220' ;;
  600:ppid=) printf '%s\n' 1 ;;
  650:comm=) printf '%s\n' claude ;;
  650:args=) printf '%s\n' claude ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 650 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # pid 600 is a different live session that holds the lock; this process
  # descends from 650 instead. Treating 600 as dead would let this session
  # reclaim a live competitor's home.
  printf '600\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a lock held outside this ancestry was claimed as this session's own"
  fi
  lib_eval "$fakebin" 'fm_harness_pid_alive 600' \
    || fail "a live competing version-named session was classified as a dead lock owner"
  pass "session-lock: a live version-named session holding the lock is not mistaken for a stale owner"
}

test_windows_fallback_requires_native_ancestry() {
  local dir fakebin state got
  dir="$TMP_ROOT/windows-native-ancestry"
  fakebin=$(fm_fakebin "$dir")
  state="$dir/state"
  mkdir -p "$state"
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' Msys
SH
  cat > "$fakebin/cat" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  /proc/1/winpid) exit 1 ;;
  /proc/55/winpid) printf '%s\n' 550 ;;
  /proc/60/winpid) printf '%s\n' 600 ;;
  /proc/61/winpid) printf '%s\n' 610 ;;
  /proc/70/winpid) printf '%s\n' 700 ;;
  /proc/80/winpid) printf '%s\n' 800 ;;
  /proc/90/winpid) printf '%s\n' 900 ;;
  /proc/*/winpid) printf '%s\n' 500 ;;
  /proc/55/ppid) printf '%s\n' 1 ;;
  /proc/60/ppid) printf '%s\n' 70 ;;
  /proc/61/ppid) printf '%s\n' 90 ;;
  /proc/70/ppid) printf '%s\n' 80 ;;
  /proc/80/ppid) printf '%s\n' 90 ;;
  /proc/90/ppid) printf '%s\n' 0 ;;
  /proc/*/ppid) printf '%s\n' 55 ;;
  *) exec /bin/cat "$@" ;;
esac
SH
  cat > "$fakebin/powershell.exe" <<'SH'
#!/usr/bin/env bash
set -u
[ "${FM_TEST_WINDOWS_PROCESS_FAILURE:-}" = 1 ] && exit 1
[ -z "${FM_TEST_PS_CALLS:-}" ] || printf 'call\n' >> "$FM_TEST_PS_CALLS"
case "$*" in
  *Win32_Process*'-Filter'*) exit 1 ;;
  *Win32_Process*) ;;
  *) exit 1 ;;
esac
case "${FM_TEST_WINDOWS_TREE:-pi}" in
  claude) parent=700 ;;
  cursor) parent=610 ;;
  missing) parent=6676 ;;
  *) parent=600 ;;
esac
printf '500\tbash.exe\t6676\tC:/Windows/bash.exe\tbash\n'
printf '550\tbash.exe\t%s\tC:/Windows/bash.exe\tbash\n' "$parent"
printf '600\tpi.exe\t700\tC:/Users/u/pi.exe\tpi\n'
printf '610\tagent.exe\t900\tC:/Users/Jane Doe/.local/share/cursor-agent/versions/2026.08.11/cursor-agent.exe\tagent\n'
printf '700\tclaude.exe\t800\tC:/Users/u/claude.exe\tclaude\n'
printf '800\tclaude.exe\t900\tC:/Users/u/claude.exe\tclaude\n'
printf '900\texplorer.exe\t0\tC:/Windows/explorer.exe\texplorer\n'
SH
  chmod +x "$fakebin/uname" "$fakebin/cat" "$fakebin/powershell.exe"

  # Exact live MSYS topology: inner bash WinPID 500 has dead native parent
  # 6676, but its Cygwin parent 55 maps to outer bash WinPID 550. The outer
  # Cygwin ppid is 1 (no /proc/1/winpid); only native parentage reaches Pi
  # 600 or Claude 700. A Pi child must still reject inherited Claude identity.
  printf '700\n' > "$state/.lock"
  got=$(FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 lib_eval "$fakebin" 'fm_harness_ancestry_pids') \
    || fail "the native fallback did not find the hand-started Pi harness"
  [ "$got" = 600 ] || fail "the fallback reported '$got', expected only the Pi ancestor 600"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 lib_eval "$fakebin" "fm_session_lock_owned_by_self '$state'"; then
    fail "a hand-started Pi inherited Claude identity and claimed Claude's lock"
  fi
  got=$(FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 lib_eval "$fakebin" "fm_session_lock_foreign_owner_live '$state' && printf '%s' \"\$FM_SESSION_LOCK_FOREIGN_OWNER_PID\"") \
    || fail "the foreign Claude owner was not reported"
  [ "$got" = 700 ] || fail "the foreign owner was '$got', expected 700"
  got=$(FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "the hand-started Pi did not anchor to its native harness"
  [ "$got" = 600 ] || fail "the hand-started Pi anchored '$got', expected 600"

  # A live CLAUDE_PID cannot replace a missing native link above the outer
  # shell. The two tables only join at a real parent relationship.
  if FM_TEST_WINDOWS_TREE=missing FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 \
    lib_eval "$fakebin" 'fm_harness_ancestry_pids' >/dev/null; then
    fail "an unavailable outer native parent was replaced by inherited Claude identity"
  fi
  if FM_TEST_WINDOWS_TREE=missing FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 \
    lib_eval "$fakebin" "fm_session_lock_owned_by_self '$state'"; then
    fail "a missing native ancestry proof still claimed Claude's lock"
  fi

  # A real hybrid chain remains usable: Cygwin inner -> outer shell, then
  # native WinPID 550 -> claude 700 -> claude 800.
  got=$(FM_TEST_WINDOWS_TREE=claude FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 \
    lib_eval "$fakebin" 'fm_harness_ancestry_pids') \
    || fail "the native fallback did not walk the Claude chain"
  [ "$got" = $'700\n800' ] || fail "the Claude chain was '$got', expected 700 and 800"
  FM_TEST_WINDOWS_TREE=claude FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 \
    lib_eval "$fakebin" "fm_session_lock_owned_by_self '$state'" \
    || fail "the verified Claude ancestor did not own its lock"
  got=$(FM_TEST_WINDOWS_TREE=claude FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 \
    lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "the verified Claude chain did not anchor"
  [ "$got" = 700 ] || fail "the verified Claude chain anchored '$got', expected 700"

  got=$(FM_TEST_WINDOWS_TREE=cursor lib_eval "$fakebin" 'fm_harness_ancestry_pids') \
    || fail "the native fallback did not identify Cursor's agent alias"
  [ "$got" = 610 ] || fail "the Cursor alias ancestry was '$got', expected 610"
  FM_TEST_WINDOWS_TREE=cursor lib_eval "$fakebin" 'fm_harness_pid_alive 610' \
    || fail "Cursor's agent alias was not recognized as a live harness"
  printf '610\n' > "$state/.lock"
  FM_TEST_WINDOWS_TREE=cursor lib_eval "$fakebin" "fm_session_lock_owned_by_self '$state'" \
    || fail "Cursor's agent alias did not own its lock"
  got=$(FM_TEST_WINDOWS_TREE=cursor lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "Cursor's agent alias did not anchor"
  [ "$got" = 610 ] || fail "the Cursor alias anchored '$got', expected 610"

  # Inspection retains the live-ambiguous versus unavailable distinction.
  printf '900\n' > "$state/.lock"
  got=$(FM_TEST_KILL_RC=1 FM_TEST_WINDOWS_TREE=claude lib_eval "$fakebin" \
    "fm_session_lock_inspect '$state'; printf '%s %s' \"\$FM_LOCK_INSPECT_STATE\" \"\$FM_LOCK_INSPECT_LIVE_HARNESS\"")
  [ "$got" = 'unknown false' ] || fail "a live non-harness was inspected as '$got'"
  printf '999\n' > "$state/.lock"
  got=$(FM_TEST_KILL_RC=1 FM_TEST_WINDOWS_TREE=claude lib_eval "$fakebin" \
    "fm_session_lock_inspect '$state'; printf '%s %s' \"\$FM_LOCK_INSPECT_STATE\" \"\$FM_LOCK_INSPECT_LIVE_HARNESS\"")
  [ "$got" = 'stale false' ] || fail "an absent Windows PID was inspected as '$got'"
  got=$(FM_TEST_WINDOWS_PROCESS_FAILURE=1 FM_TEST_KILL_RC=1 FM_TEST_WINDOWS_TREE=claude lib_eval "$fakebin" \
    "fm_session_lock_inspect '$state'; printf '%s %s' \"\$FM_LOCK_INSPECT_STATE\" \"\$FM_LOCK_INSPECT_LIVE_HARNESS\"")
  [ "$got" = 'unknown false' ] || fail "a failed Windows process snapshot was inspected as '$got'"
  got=$(FM_TEST_WINDOWS_PROCESS_FAILURE=1 PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    bash "$ROOT/bin/fm-lock.sh" status 2>/dev/null)
  [ "$got" = 'lock: unknown (owner liveness could not be verified)' ] \
    || fail "the status CLI reported '$got' for an unavailable process snapshot"
  : > "$dir/calls"
  FM_TEST_WINDOWS_TREE=claude FM_TEST_PS_CALLS="$dir/calls" \
    lib_eval "$fakebin" 'fm_harness_pid_alive 700; fm_harness_pid_alive 700' >/dev/null \
    || fail "repeated Windows liveness checks failed outside acquisition"
  [ "$(wc -l < "$dir/calls" | tr -d ' ')" = 2 ] \
    || fail "Windows liveness reused a process snapshot outside acquisition"
  FM_TEST_WINDOWS_TREE=claude lib_eval "$fakebin" '
    fm_harness_pid_alive 700 || exit 1
    export FM_TEST_WINDOWS_PROCESS_FAILURE=1
    rc=0
    fm_harness_pid_alive 700 || rc=$?
    [ "$rc" -eq 3 ]
  ' || fail "a later snapshot failure reused an earlier live-harness verdict"
  : > "$dir/calls"
  # Drive real acquisition, not just helper calls: repeated identity and
  # trusted-session consumers must share one process-table query per command.
  mkdir -p "$dir/home"
  FM_HOME="$dir/home" FM_TEST_WINDOWS_TREE=claude FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 \
    FM_TEST_PS_CALLS="$dir/calls" lib_eval "$fakebin" "bash '$ROOT/bin/fm-lock.sh'" >/dev/null \
    || fail "Windows acquisition failed with a verified hybrid ancestry"
  [ "$(wc -l < "$dir/calls" | tr -d ' ')" = 1 ] \
    || fail "Windows acquisition made more than one PowerShell invocation"
  : > "$dir/calls"
  FM_HOME="$dir/home" FM_TEST_WINDOWS_TREE=claude FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 \
    FM_TEST_PS_CALLS="$dir/calls" lib_eval "$fakebin" "bash '$ROOT/bin/fm-lock.sh'" >/dev/null \
    || fail "Windows same-session confirmation failed"
  [ "$(wc -l < "$dir/calls" | tr -d ' ')" = 1 ] \
    || fail "Windows confirmation made more than one PowerShell invocation"
  : > "$dir/calls"
  if FM_HOME="$dir/home" FM_TEST_WINDOWS_TREE=pi FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 \
    FM_TEST_PS_CALLS="$dir/calls" lib_eval "$fakebin" "bash '$ROOT/bin/fm-lock.sh'" >/dev/null 2>&1; then
    fail "a real Pi acquisition claimed the existing Claude lock"
  fi
  [ "$(wc -l < "$dir/calls" | tr -d ' ')" = 1 ] \
    || fail "Windows foreign-owner refusal made more than one PowerShell invocation"
  pass "session-lock: Windows ownership requires real ancestry and one PowerShell query per acquisition"
}

test_windows_snapshot_is_taken_after_claim() {
  local dir fakebin home state holder_pid acquire_pid rc i
  dir="$TMP_ROOT/windows-snapshot-claim"
  fakebin=$(fm_fakebin "$dir/bin")
  home="$dir/home"
  state="$home/state"
  mkdir -p "$state"
  cat > "$fakebin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' Msys
SH
  cat > "$fakebin/cat" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  /proc/55/winpid) printf '%s\n' 550 ;;
  /proc/55/ppid) printf '%s\n' 1 ;;
  /proc/*/winpid) printf '%s\n' 500 ;;
  /proc/*/ppid) printf '%s\n' 55 ;;
  *) exec /bin/cat "$@" ;;
esac
SH
  cat > "$fakebin/powershell.exe" <<'SH'
#!/usr/bin/env bash
set -u
claim_pid=$(cat "$FM_TEST_RACE_STATE/.lock.acquire/pid" 2>/dev/null || true)
if [ "$claim_pid" = "${FM_TEST_RACE_HOLDER_PID:-}" ]; then
  : > "$FM_TEST_RACE_PRECLAIM"
  while [ ! -e "$FM_TEST_RACE_RELEASE_SNAPSHOT" ]; do sleep 0.01; done
fi
printf '500\tbash.exe\t6676\tC:/Windows/bash.exe\tbash\n'
printf '550\tbash.exe\t700\tC:/Windows/bash.exe\tbash\n'
printf '700\tclaude.exe\t800\tC:/Users/u/claude.exe\tclaude\n'
printf '800\tclaude.exe\t900\tC:/Users/u/claude.exe\tclaude\n'
printf '900\texplorer.exe\t0\tC:/Windows/explorer.exe\texplorer\n'
if [ "$claim_pid" != "${FM_TEST_RACE_HOLDER_PID:-}" ] && [ -n "$claim_pid" ]; then
  : > "$FM_TEST_RACE_POSTCLAIM"
  printf '600\tpi.exe\t700\tC:/Users/u/pi.exe\tpi\n'
fi
SH
  cat > "$dir/hold-claim.sh" <<'SH'
#!/usr/bin/env bash
set -u
. "$FM_WAKE"
fm_lock_try_acquire "$FM_HOME/state/.lock.acquire" || exit 1
: > "$FM_HOME/state/holder-ready"
while [ ! -e "$FM_HOME/state/release-holder" ]; do sleep 0.01; done
printf '%s\n' 600 > "$FM_HOME/state/.lock"
printf '%s\n' OTHER > "$FM_HOME/state/.lock-session"
fm_lock_release "$FM_HOME/state/.lock.acquire"
SH
  cat > "$dir/acquire.sh" <<SH
#!/usr/bin/env bash
set -u
: > "$dir/acquirer-started"
CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=700 FM_HOME="$home" \\
  bash "$ROOT/bin/fm-lock.sh" > "$dir/acquire.out" 2>&1
printf '%s\\n' "\$?" > "$dir/acquire.rc"
SH
  chmod +x "$fakebin/uname" "$fakebin/cat" "$fakebin/powershell.exe" "$dir/hold-claim.sh" "$dir/acquire.sh"
  printf '%s\n' 999 > "$state/.lock"
  env FM_HOME="$home" FM_WAKE="$ROOT/bin/fm-wake-lib.sh" "$dir/hold-claim.sh" &
  holder_pid=$!
  i=0
  while [ "$i" -lt 400 ] && [ ! -e "$state/holder-ready" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$state/holder-ready" ] || fail "the claim-holder fixture never acquired the claim"
  env PATH="$fakebin:$PATH" FM_TEST_RACE_STATE="$state" \
    FM_TEST_RACE_HOLDER_PID="$holder_pid" \
    FM_TEST_RACE_PRECLAIM="$dir/preclaim" \
    FM_TEST_RACE_POSTCLAIM="$dir/postclaim" \
    FM_TEST_RACE_RELEASE_SNAPSHOT="$dir/release-snapshot" \
    "$dir/acquire.sh" &
  acquire_pid=$!
  i=0
  while [ "$i" -lt 40 ] && [ ! -e "$dir/acquirer-started" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  if [ ! -e "$dir/acquirer-started" ]; then
    : > "$dir/release-snapshot"
    kill "$acquire_pid" "$holder_pid" 2>/dev/null || true
    wait "$acquire_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
    fail "the acquisition fixture never started"
  fi
  i=0
  while [ "$i" -lt 40 ] && [ ! -e "$dir/preclaim" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  if [ -e "$dir/preclaim" ]; then
    : > "$dir/release-snapshot"
    kill "$acquire_pid" "$holder_pid" 2>/dev/null || true
    wait "$acquire_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
    fail "the process snapshot was taken before the claim was acquired"
  fi
  : > "$dir/release-snapshot"
  : > "$state/release-holder"
  wait "$holder_pid" || fail "the claim-holder fixture failed"
  wait "$acquire_pid" || true
  [ -e "$dir/postclaim" ] || fail "the process snapshot was not taken after the claim was acquired"
  rc=$(tr -d '[:space:]' < "$dir/acquire.rc")
  [ "$rc" != 0 ] || fail "the acquisition overwrote an owner published while it waited for the claim"
  [ "$(tr -d '[:space:]' < "$state/.lock")" = 600 ] \
    || fail "the acquisition changed the live owner's lock to $(cat "$state/.lock")"
  [ "$(tr -d '[:space:]' < "$state/.lock-session")" = OTHER ] \
    || fail "the acquisition changed the live owner's sidecar"
  pass "session-lock: Windows ownership snapshots after claim acquisition"
}

# A background Claude session's process table. The hook fires inside
# `claude bg-spare` (710), whose parent is `claude bg-pty-host` (720). With the
# transient daemon gone the pty-host is reparented to launchd, so the contiguous
# claude-named run from the hook ends at 720 and the live front-end 700 that
# holds the lock is no longer an ancestor at all. FM_TEST_DAEMON_PRESENT=1 puts
# the daemon (730) back between 720 and 700: the healthy topology.
write_background_session_ps() {  # <fakebin>
  cat > "$1/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_DAEMON_PRESENT:-0}" in
  700:comm=:*) printf '%s\n' claude ;;
  700:args=:*) printf '%s\n' 'claude --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  730:comm=:*) printf '%s\n' claude ;;
  730:args=:*) printf '%s\n' 'claude daemon run --origin transient' ;;
  730:ppid=:*) printf '%s\n' 700 ;;
  720:comm=:*) printf '%s\n' 'claude bg-pty-host' ;;
  720:args=:*) printf '%s\n' 'claude bg-pty-host /tmp/pty.sock 120 40 -- claude --bg-spare' ;;
  720:ppid=:1) printf '%s\n' 730 ;;
  720:ppid=:*) printf '%s\n' 1 ;;
  710:comm=:*) printf '%s\n' 'claude bg-spare' ;;
  710:args=:*) printf '%s\n' 'claude bg-spare /tmp/claim.sock' ;;
  710:ppid=:*) printf '%s\n' 720 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 710 ;;
esac
SH
  chmod +x "$1/ps"
}

owned() {  # <fakebin> <state>
  lib_eval "$1" "fm_session_lock_owned_by_self '$2'"
}

foreign_owner() {  # <fakebin> <state>  -> prints the foreign pid
  lib_eval "$1" "fm_session_lock_foreign_owner_live '$2' && printf '%s' \"\$FM_SESSION_LOCK_FOREIGN_OWNER_PID\""
}

test_same_session_id_owns_a_recycled_background_chain() {
  local dir fakebin state got
  dir="$TMP_ROOT/background-session"
  fakebin=$(posix_fakebin "$dir")
  state="$dir/state"
  mkdir -p "$state"
  write_background_session_ps "$fakebin"
  printf '700\n' > "$state/.lock"
  printf 'S1\n' > "$state/.lock-session"

  # The divergence itself, so none of the verdicts below can be vacuous: with
  # the daemon gone the front-end is not an ancestor, with it back it is.
  if lib_eval "$fakebin" 'fm_harness_ancestry_pids' | grep -qx 700; then
    fail "the recycled chain still reached the front-end, so the id cases would prove nothing"
  fi
  FM_TEST_DAEMON_PRESENT=1 lib_eval "$fakebin" 'fm_harness_ancestry_pids' | grep -qx 700 \
    || fail "the healthy chain did not reach the front-end"

  # 1. The session's own id from its model-loop process: owned, not foreign.
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state" \
    || fail "the same session's trusted id did not own the lock after the helper chain was recycled"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null; then
    fail "the session's own live front-end was reported as a foreign owner despite the matching id"
  fi
  # 2. A different id: the existing refusal, naming the live owner.
  if FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a different session id claimed a live owner's lock"
  fi
  got=$(FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state") \
    || fail "a different session id did not see the live owner as foreign"
  [ "$got" = 700 ] || fail "the foreign owner pid was '$got', expected 700"
  # 3. The trust gate: the right id carried by a CLAUDE_PID outside the run.
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 owned "$fakebin" "$state"; then
    fail "an id whose CLAUDE_PID is outside the current Claude run was trusted"
  fi
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 foreign_owner "$fakebin" "$state" >/dev/null \
    || fail "an untrusted id suppressed the foreign-owner verdict"
  printf 'S1:x\n' > "$state/.lock-session"
  FM_TEST_SESSION_ID='S1:x' FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state" \
    || fail "a trusted id containing a colon did not own the lock"
  if FM_TEST_SESSION_ID='S1:x' FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null; then
    fail "a matching id containing a colon was reported as a foreign owner"
  fi
  printf 'S1\r' > "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a recorded id containing a carriage return was treated as a session id"
  fi
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null \
    || fail "a carriage-return sidecar suppressed the foreign-owner verdict"
  printf 'S1\n' > "$state/.lock-session"
  # 4. No id at all: the legacy ancestry verdict, unchanged.
  if owned "$fakebin" "$state"; then
    fail "with no session id the recycled chain claimed the lock"
  fi
  foreign_owner "$fakebin" "$state" >/dev/null \
    || fail "with no session id the live owner was not reported as foreign"
  # 5. The healthy chain owns by ancestry whatever the environment says.
  FM_TEST_DAEMON_PRESENT=1 FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state" \
    || fail "ancestry membership lost to a different session id"
  FM_TEST_DAEMON_PRESENT=1 owned "$fakebin" "$state" \
    || fail "ancestry membership lost with no session id"
  if FM_TEST_DAEMON_PRESENT=1 FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null; then
    fail "an ancestor was reported as a foreign owner"
  fi
  # 6. Never fail open: no sidecar, a symlinked sidecar, and a dead recorded pid
  # are all ancestry-only, so the dead one is left for the ordinary reclaim.
  rm -f "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a lock with no recorded session id was owned through the environment id"
  fi
  printf 'S1\n' > "$dir/elsewhere"
  ln -s "$dir/elsewhere" "$state/.lock-session" 2>/dev/null || true
  if [ -L "$state/.lock-session" ]; then
    if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
      fail "a symlinked sidecar was trusted"
    fi
  else
    printf '%s\n' 'skip - symlinked sidecar rejection: ln -s did not create a symlink (Windows may require Developer Mode)'
  fi
  rm -f "$state/.lock-session"
  printf 'S1\n' > "$state/.lock-session"
  if FM_TEST_KILL_RC=1 FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a same-session lock whose recorded pid is dead was owned instead of left for reclaim"
  fi
  pass "session-lock: a trusted same-session id keeps owning a recycled background chain, and nothing weaker does"
}

test_anchor_pid_is_the_model_loop_process_only_for_a_trusted_id() {
  local dir fakebin got
  dir="$TMP_ROOT/background-anchor"
  fakebin=$(posix_fakebin "$dir")
  write_background_session_ps "$fakebin"

  got=$(FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for a trusted id"
  [ "$got" = 710 ] || fail "a trusted id anchored '$got', expected the model-loop process 710"
  got=$(lib_eval "$fakebin" 'fm_session_lock_anchor_pid') || fail "no anchor pid was resolved without an id"
  [ "$got" = 720 ] || fail "without an id the anchor was '$got', expected the outermost pid 720"
  got=$(FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for an untrusted id"
  [ "$got" = 720 ] || fail "an untrusted id anchored '$got', expected the outermost pid 720"
  got=$(FM_TEST_DAEMON_PRESENT=1 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for the healthy chain"
  [ "$got" = 700 ] || fail "the healthy chain without an id anchored '$got', expected the outermost pid 700"
  got=$(FM_TEST_DAEMON_PRESENT=1 FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for the healthy chain with a trusted id"
  [ "$got" = 710 ] || fail "the healthy chain with a trusted id anchored '$got', expected 710 rather than the front-end"
  pass "session-lock: a trusted id anchors the lock on the model-loop process, anything else on the outermost pid"
}

# --- end-to-end layer: the real Stop auto-arm in real process trees ----------

install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-path-lib.sh" "$dir/bin/fm-path-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/fm-cursor-lib.sh"
  # Launch probe sibling of fm-cursor-lib.sh; keep it next to the copy so a
  # fixture that ever verifies an executable does not source a missing file.
  cp "$ROOT/bin/fm-timeout-lib.sh" "$dir/bin/fm-timeout-lib.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$dir/bin/fm-supervision-engine-lib.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
  # The fixture arm written here stands in for the watcher arm, so the home opts out
  # of the supervision host a Claude home otherwise runs by default.
  mkdir -p "$dir/config"
  : > "$dir/config/supervision-host-off"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# A primary home with one task in flight, so the hook's scope and supervision-need
# gates both pass and only identity decides the outcome.
make_primary_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  install_autoarm_scripts "$dir"
  # The process that fires the hook records its own pid as the session lock
  # owner, exactly as a real session does at session start.
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FIXTURE_ORPHAN_HERE:-0}" = 1 ]; then
  i=0
  while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
    sleep 0.05
    i=$((i + 1))
  done
fi
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/hook.rc"
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
"$FM_SESSION_BIN" "$FM_HOME/session.sh"
exit 0
SH
  chmod +x "$dir/session.sh" "$dir/daemon.sh"
}

# Start the fixture tree detached from this suite's own process tree: the
# launcher exits immediately, so the tree is reparented to init and the ancestry
# walk terminates inside the fixture. Returns once the hook has recorded its exit
# code.
run_fixture_tree() {  # <dir> <session-bin> [<daemon-bin>]
  local dir=$1 session_bin=$2 daemon_bin=${3:-} i
  if [ -n "$daemon_bin" ]; then
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
      FM_HOME="$dir" FM_SESSION_BIN="$session_bin" FM_FIXTURE_ORPHAN_HERE=0 \
      bash -c '"$0" "$1" &' "$daemon_bin" "$dir/daemon.sh"
  else
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
      FM_HOME="$dir" FM_FIXTURE_ORPHAN_HERE=1 \
      bash -c '"$0" "$1" &' "$session_bin" "$dir/session.sh"
  fi
  i=0
  while [ "$i" -lt 400 ] && [ ! -s "$dir/state/hook.rc" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/state/hook.rc" ] || fail "the fixture hook never finished"
}

hook_rc() {
  tr -d '[:space:]' < "$1/state/hook.rc"
}

epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

test_e2e_version_named_session_claims_the_home() {
  local dir
  dir="$TMP_ROOT/e2e-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named session"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "no claim was recorded, got: $(epoch_outcome "$dir")"
  pass "session-lock e2e: a version-named session claims the home and arms supervision"
}

test_e2e_daemon_parented_session_claims_the_home() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-parented"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$NAMED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  [ -n "$session_pid" ] && [ "$session_pid" != "$daemon_pid" ] \
    || fail "fixture did not produce a distinct daemon and session: session=$session_pid daemon=$daemon_pid"
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  expect_code 2 "$(hook_rc "$dir")" "a session parented by a harness-named daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a daemon-parented session"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  pass "session-lock e2e: a session parented by a harness-named daemon claims the home and arms supervision"
}

test_e2e_daemon_parented_version_named_session_keeps_its_lock() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  [ "$lock_after" != "$daemon_pid" ] \
    || fail "the live session's lock was reclaimed as stale and rewritten to the shared daemon pid $daemon_pid"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session under a daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named daemon-parented session"
  pass "session-lock e2e: a version-named session under a harness-named daemon keeps its own lock"
}

# --- end-to-end layer: a background session whose helper chain is recycled ---
#
# The topology the four issue reports (#3902, #2314, #3398, #4066) recorded with
# real process listings: a front-end that acquired the lock, a transient daemon
# under it, the pty-host the daemon spawned, and the bg-spare inside the pty-host
# that runs the model loop and therefore fires every hook. Every fixture process
# is the fake claude, so the ancestry walk sees a contiguous claude-named run
# exactly as in production, and the tree is orphaned before use. The daemon is
# then ended while the front-end stays alive - the recycling that breaks the run
# above the pty-host - and the spare fires the real Stop auto-arm, the real
# turn-end guard, and the real lock script once per phase under a chosen hook
# environment, recording every verdict for the assertions below.

BG_FIXTURE_PIDS=()
reap_background_fixture() {
  local pid
  for pid in ${BG_FIXTURE_PIDS[@]+"${BG_FIXTURE_PIDS[@]}"}; do
    kill -TERM "$pid" 2>/dev/null || true
  done
}
trap 'reap_background_fixture; fm_test_cleanup' EXIT

make_background_session_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  # The whole bin, because the real turn-end guard composes far more of it than
  # the auto-arm alone; only the arm is replaced by the recording stub above.
  cp -R "$ROOT/bin" "$dir/bin"
  install_autoarm_scripts "$dir"
  # Every fixture script ends in an explicit exit so bash can never tail-exec the
  # script under test in place of the fake claude, which would collapse the
  # chain the assertions depend on.
  cat > "$dir/frontend.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/frontend-pid"
CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/frontend-lock.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/frontend-lock.rc"
"$FM_FIXTURE_CLAUDE" "$FM_HOME/daemon.sh" &
disown
while [ ! -e "$FM_HOME/state/stop-frontend" ]; do sleep 0.05; done
exit 0
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
exec -a 'claude bg-pty-host' "$FM_FIXTURE_CLAUDE" "$FM_HOME/ptyhost.sh" &
while :; do sleep 0.1; done
exit 0
SH
  cat > "$dir/ptyhost.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/ptyhost-pid"
exec -a 'claude bg-spare' "$FM_FIXTURE_CLAUDE" "$FM_HOME/spare.sh" &
while [ ! -e "$FM_HOME/state/stop-spare" ]; do sleep 0.1; done
exit 0
SH
  cat > "$dir/spare.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/spare-pid"
n=1
while [ ! -e "$FM_HOME/state/stop-spare" ]; do
  req="$FM_HOME/state/fire-$n"
  if [ -f "$req" ]; then
    out="$FM_HOME/state/phase-$n"
    mkdir -p "$out"
    unset CLAUDE_CODE_SESSION_ID CLAUDE_PID
    # shellcheck disable=SC1090
    . "$req"
    ( . "$FM_HOME/bin/fm-session-lock-lib.sh" && fm_harness_ancestry_pids ) > "$out/ancestry" 2>/dev/null
    printf '%s\n' '{"session_id":"fixture","stop_hook_active":true}' \
      | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" > "$out/hook.out" 2>&1
    printf '%s\n' "$?" > "$out/hook.rc"
    printf '%s\n' '{"session_id":"fixture","stop_hook_active":true}' \
      | "$FM_HOME/bin/fm-turnend-guard.sh" --claude > "$out/guard.out" 2>&1
    printf '%s\n' "$?" > "$out/guard.rc"
    "$FM_HOME/bin/fm-lock.sh" > "$out/lock.out" 2>&1
    printf '%s\n' "$?" > "$out/lock.rc"
    cp "$FM_HOME/state/.lock" "$out/lock-after"
    [ ! -e "$FM_HOME/state/.lock-session" ] || cp "$FM_HOME/state/.lock-session" "$out/session-after"
    : > "$out/done"
    n=$((n + 1))
  fi
  sleep 0.05
done
exit 0
SH
  chmod +x "$dir/frontend.sh" "$dir/daemon.sh" "$dir/ptyhost.sh" "$dir/spare.sh"
}

wait_for_file() {  # <path> <what>
  local i=0
  while [ "$i" -lt 400 ] && [ ! -s "$1" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$1" ] || fail "background-session fixture never produced $2"
}

fire_phase() {  # <dir> <n> <hook-environment-script>
  local dir=$1 n=$2
  printf '%s\n' "$3" > "$dir/state/fire-$n.tmp"
  mv "$dir/state/fire-$n.tmp" "$dir/state/fire-$n"
  wait_for_file "$dir/state/phase-$n/hook.rc" "phase $n"
  local i=0
  while [ "$i" -lt 400 ] && [ ! -e "$dir/state/phase-$n/done" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$dir/state/phase-$n/done" ] || fail "background-session fixture never finished phase $n"
}

phase_value() {  # <dir> <n> <file>
  tr -d '[:space:]' < "$1/state/phase-$2/$3"
}

arm_count() {  # <dir>
  [ -e "$1/state/arm-ran" ] || { printf '0'; return; }
  wc -l < "$1/state/arm-ran" | tr -d ' '
}

# The recycled chain must still be treated as the owner: arm, no diagnostic,
# lock accepted, line 1 naming <expected-lock-pid>, and the sidecar either
# byte-identical to the one the owner wrote or, when <expected-session-id> is
# given, re-keyed to that id. An owned actionable close records two arm
# invocations - the foreground arm plus the handling successor the hook starts
# before the rewake - so the cumulative <expected-arms> grows by two for every
# owned phase.
expect_phase_owned() {  # <dir> <n> <expected-arms> <expected-lock-pid> <label> [<expected-session-id>]
  local dir=$1 n=$2 arms=$3 lock_pid=$4 label=$5 session_id=${6:-}
  expect_code 2 "$(phase_value "$dir" "$n" hook.rc)" "$label: the Stop auto-arm did not rewake"
  [ "$(arm_count "$dir")" = "$arms" ] || fail "$label: expected $arms arm(s), got $(arm_count "$dir")"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "$label: no rewake claim was recorded, got: $(epoch_outcome "$dir")"
  expect_code 0 "$(phase_value "$dir" "$n" guard.rc)" "$label: the turn-end guard did not allow the stop"
  if grep -q 'OWNED BY ANOTHER LIVE SESSION' "$dir/state/phase-$n/guard.out"; then
    fail "$label: the turn-end guard took the foreign-owner exit: $(cat "$dir/state/phase-$n/guard.out")"
  fi
  expect_code 0 "$(phase_value "$dir" "$n" lock.rc)" "$label: fm-lock.sh refused the session's own lock: $(cat "$dir/state/phase-$n/lock.out")"
  [ "$(phase_value "$dir" "$n" lock-after)" = "$lock_pid" ] \
    || fail "$label: lock line 1 is $(phase_value "$dir" "$n" lock-after), expected $lock_pid"
  if [ -n "$session_id" ]; then
    [ "$(phase_value "$dir" "$n" session-after)" = "$session_id" ] \
      || fail "$label: the session sidecar names $(phase_value "$dir" "$n" session-after), expected $session_id"
  else
    cmp -s "$dir/state/phase-$n/session-after" "$dir/sidecar-initial" \
      || fail "$label: the session sidecar is not byte-identical to the one the owner wrote"
  fi
}

# Not the owner: no arm, the guard's foreign-owner diagnostic naming the live
# owner, and the lock refusal naming both the owner pid and its recorded id.
expect_phase_foreign() {  # <dir> <n> <expected-arms> <owner-pid> <label>
  local dir=$1 n=$2 arms=$3 owner=$4 label=$5
  expect_code 0 "$(phase_value "$dir" "$n" hook.rc)" "$label: the Stop auto-arm did not stand down"
  [ "$(arm_count "$dir")" = "$arms" ] || fail "$label: a non-owner armed: $(arm_count "$dir") arm(s), expected $arms"
  expect_code 0 "$(phase_value "$dir" "$n" guard.rc)" "$label: a non-owner Stop did not end safely"
  grep -q "OWNED BY ANOTHER LIVE SESSION.*lock owner pid $owner" "$dir/state/phase-$n/guard.out" \
    || fail "$label: the guard did not report the live owner $owner: $(cat "$dir/state/phase-$n/guard.out")"
  expect_code 1 "$(phase_value "$dir" "$n" lock.rc)" "$label: fm-lock.sh accepted a lock this session does not own"
  grep -q "another live firstmate session holds the lock (pid $owner, session S1)" "$dir/state/phase-$n/lock.out" \
    || fail "$label: the refusal did not name the owner pid and recorded session: $(cat "$dir/state/phase-$n/lock.out")"
  [ "$(phase_value "$dir" "$n" lock-after)" = "$owner" ] || fail "$label: a non-owner rewrote the lock"
}

test_e2e_background_session_keeps_its_lock_across_a_recycled_chain() {
  local dir frontend daemon ptyhost spare i
  dir="$TMP_ROOT/e2e-background-session"
  make_background_session_home "$dir"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_FIXTURE_CLAUDE="$NAMED_CLAUDE" FM_POLL=1 FM_HEARTBEAT=999999 \
    FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0 \
    bash -c '"$0" "$1" &' "$NAMED_CLAUDE" "$dir/frontend.sh"
  wait_for_file "$dir/state/frontend-lock.rc" "the front-end's lock result"
  wait_for_file "$dir/state/spare-pid" "the bg-spare"
  frontend=$(tr -d '[:space:]' < "$dir/state/frontend-pid")
  daemon=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  ptyhost=$(tr -d '[:space:]' < "$dir/state/ptyhost-pid")
  spare=$(tr -d '[:space:]' < "$dir/state/spare-pid")
  BG_FIXTURE_PIDS+=("$frontend" "$daemon" "$ptyhost" "$spare")
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/frontend-lock.rc")" "the front-end could not acquire the lock: $(cat "$dir/state/frontend-lock.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$frontend" ] \
    || fail "the front-end's lock names $(cat "$dir/state/.lock"), expected its own pid $frontend"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = S1 ] \
    || fail "the front-end did not record its trusted session id beside the lock"
  cp "$dir/state/.lock-session" "$dir/sidecar-initial"

  # Phase 1: the healthy contiguous chain, the session's own id.
  fire_phase "$dir" 1 'export CLAUDE_CODE_SESSION_ID=S1; export CLAUDE_PID=$$'
  grep -qx "$frontend" "$dir/state/phase-1/ancestry" || fail "the healthy chain did not reach the front-end"
  expect_phase_owned "$dir" 1 2 "$frontend" "healthy chain"

  # Recycle the bridge: the daemon ends, the pty-host is reparented to init, and
  # the front-end that holds the lock stays alive.
  kill -TERM "$daemon"
  i=0
  while [ "$i" -lt 200 ] && { kill -0 "$daemon" 2>/dev/null || [ "$(ps -o ppid= -p "$ptyhost" 2>/dev/null | tr -d ' ')" != 1 ]; }; do
    sleep 0.05
    i=$((i + 1))
  done
  [ "$(ps -o ppid= -p "$ptyhost" 2>/dev/null | tr -d ' ')" = 1 ] || fail "the pty-host was not reparented to init after the daemon ended"
  kill -0 "$frontend" 2>/dev/null || fail "the front-end died with the daemon, so the recycled case cannot be exercised"

  # Phases 2-4: before the spare proves anything, a different id, the right id
  # from a CLAUDE_PID outside the run, and no id at all are each a non-owner
  # over the broken chain.
  fire_phase "$dir" 2 'export CLAUDE_CODE_SESSION_ID=S2; export CLAUDE_PID=$$'
  if grep -qx "$frontend" "$dir/state/phase-2/ancestry"; then
    fail "the recycled chain still reached the front-end, so these phases prove nothing"
  fi
  grep -qx "$spare" "$dir/state/phase-2/ancestry" || fail "the hook's ancestry lost its own spare"
  expect_phase_foreign "$dir" 2 2 "$frontend" "recycled chain, different session"
  fire_phase "$dir" 3 "export CLAUDE_CODE_SESSION_ID=S1; export CLAUDE_PID=$frontend"
  expect_phase_foreign "$dir" 3 2 "$frontend" "recycled chain, untrusted id"
  fire_phase "$dir" 4 ''
  expect_phase_foreign "$dir" 4 2 "$frontend" "recycled chain, no id"

  # Phase 5: the same session id over the broken chain - the reported drift. The
  # confirmation re-anchors line 1 from the live non-ancestor front-end onto the
  # spare - the model-loop process - not onto the outermost pty-host.
  fire_phase "$dir" 5 'export CLAUDE_CODE_SESSION_ID=S1; export CLAUDE_PID=$$'
  expect_phase_owned "$dir" 5 4 "$spare" "recycled chain, same session"
  [ "$spare" != "$ptyhost" ] || fail "fixture collapsed the spare into the pty-host"
  kill -0 "$frontend" 2>/dev/null || fail "the front-end exited, so the re-anchor was not over a live owner"

  # Phase 6: /clear - the same spare under a new id while the front-end that
  # first recorded the lock is still alive. Ancestry still proves ownership and
  # the sidecar is re-keyed.
  fire_phase "$dir" 6 'export CLAUDE_CODE_SESSION_ID=S2; export CLAUDE_PID=$$'
  expect_phase_owned "$dir" 6 6 "$spare" "same process after a session-id change" S2

  : > "$dir/state/stop-frontend"
  : > "$dir/state/stop-spare"
  pass "session-lock e2e: a background session keeps its lock and its supervision across a recycled helper chain and a same-process session-id change"
}

# A same-session confirmation must refresh a /clear re-key even while another
# process holds .lock.acquire. The prior-session-sweep-is-finishing refusal is
# a takeover rule and does not apply here; the confirmation waits, then writes
# the new id.
test_same_session_confirmation_refreshes_rekeyed_id_under_claim_lock() {
  local dir session_pid holder_pid confirm_pid
  dir="$TMP_ROOT/confirm-under-claim"
  mkdir -p "$dir/state"
  cat > "$dir/run.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/acquire.out" 2>&1
acquire_rc=$?
if [ "$acquire_rc" != 0 ]; then
  printf '%s\n' "$acquire_rc" > "$FM_HOME/state/acquire.rc"
  printf '%s\n' 1 > "$FM_HOME/state/confirm.rc"
  exit 1
fi
cp "$FM_HOME/state/.lock-session" "$FM_HOME/state/sidecar-after-acquire"
printf '%s\n' 0 > "$FM_HOME/state/acquire.rc"

bash -c '
  set -u
  . "$1"
  fm_lock_try_acquire "$2/.lock.acquire" || exit 1
  : > "$2/holder-ready"
  while [ ! -e "$2/release-holder" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
    sleep 0.05
  done
  fm_lock_release "$2/.lock.acquire"
' _ "$FM_WAKE" "$FM_HOME/state" &
printf '%s\n' "$!" > "$FM_HOME/state/holder-pid"

i=0
while [ "$i" -lt 400 ] && [ ! -e "$FM_HOME/state/holder-ready" ]; do
  sleep 0.05
  i=$((i + 1))
done
if [ ! -e "$FM_HOME/state/holder-ready" ]; then
  printf '%s\n' 2 > "$FM_HOME/state/confirm.rc"
  exit 2
fi

CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/confirm.out" 2>&1 &
printf '%s\n' "$!" > "$FM_HOME/state/confirm-pid"

i=0
while [ "$i" -lt 20 ]; do
  sleep 0.05
  i=$((i + 1))
done

: > "$FM_HOME/state/release-holder"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/confirm-pid")"
printf '%s\n' "$?" > "$FM_HOME/state/confirm.rc"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/holder-pid")" || true
SH
  chmod +x "$dir/run.sh"

  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" FM_WAKE="$ROOT/bin/fm-wake-lib.sh" \
    "$NAMED_CLAUDE" "$dir/run.sh" &
  session_pid=$!
  BG_FIXTURE_PIDS+=("$session_pid")
  wait_for_file "$dir/state/acquire.rc" "the initial lock acquisition"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/acquire.rc")" \
    "the session could not acquire its lock: $(cat "$dir/state/acquire.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/sidecar-after-acquire")" = S1 ] \
    || fail "the initial acquire did not record S1"
  wait_for_file "$dir/state/holder-pid" "the claim-lock holder pid"
  holder_pid=$(tr -d '[:space:]' < "$dir/state/holder-pid")
  BG_FIXTURE_PIDS+=("$holder_pid")
  wait_for_file "$dir/state/confirm-pid" "the same-session confirmation pid"
  confirm_pid=$(tr -d '[:space:]' < "$dir/state/confirm-pid")
  BG_FIXTURE_PIDS+=("$confirm_pid")
  wait_for_file "$dir/state/confirm.rc" "the contended confirmation result"
  wait "$session_pid" || true
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/confirm.rc")" \
    "the same-session confirmation failed while the claim lock was held: $(cat "$dir/state/confirm.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = S2 ] \
    || fail "the sidecar still names $(cat "$dir/state/.lock-session"), expected the re-keyed id S2"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$(tr -d '[:space:]' < "$dir/state/session-pid")" ] \
    || fail "the confirmation rewrote lock line 1"
  grep -q 'lock acquired: harness pid' "$dir/state/confirm.out" \
    || fail "the confirmation did not report acquisition: $(cat "$dir/state/confirm.out")"
  pass "session-lock: a same-session confirmation waits for the claim lock and refreshes a re-keyed id"
}

# If another live session publishes while a confirmation is waiting on the claim
# lock, the waiter must not overwrite that session's sidecar or report success.
test_same_session_confirmation_does_not_steal_after_wait() {
  local dir session_pid holder_pid confirm_pid other_pid
  dir="$TMP_ROOT/confirm-no-steal"
  mkdir -p "$dir/state"
  cat > "$dir/run.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/acquire.out" 2>&1
acquire_rc=$?
if [ "$acquire_rc" != 0 ]; then
  printf '%s\n' "$acquire_rc" > "$FM_HOME/state/acquire.rc"
  printf '%s\n' 1 > "$FM_HOME/state/confirm.rc"
  exit 1
fi
cp "$FM_HOME/state/.lock-session" "$FM_HOME/state/sidecar-after-acquire"
printf '%s\n' 0 > "$FM_HOME/state/acquire.rc"

"$FM_CLAUDE" -c '
  printf "%s\n" "$$" > "$FM_HOME/state/other-pid"
  while [ ! -e "$FM_HOME/state/stop-other" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
    sleep 0.05
  done
' &
printf '%s\n' "$!" > "$FM_HOME/state/other-bash-pid"
i=0
while [ "$i" -lt 400 ] && [ ! -s "$FM_HOME/state/other-pid" ]; do
  sleep 0.05
  i=$((i + 1))
done
[ -s "$FM_HOME/state/other-pid" ] || {
  printf '%s\n' 2 > "$FM_HOME/state/confirm.rc"
  exit 2
}

bash -c '
  set -u
  . "$1"
  fm_lock_try_acquire "$2/.lock.acquire" || exit 1
  : > "$2/holder-ready"
  while [ ! -e "$2/release-holder" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
    sleep 0.05
  done
  fm_lock_release "$2/.lock.acquire"
' _ "$FM_WAKE" "$FM_HOME/state" &
printf '%s\n' "$!" > "$FM_HOME/state/holder-pid"

i=0
while [ "$i" -lt 400 ] && [ ! -e "$FM_HOME/state/holder-ready" ]; do
  sleep 0.05
  i=$((i + 1))
done
if [ ! -e "$FM_HOME/state/holder-ready" ]; then
  printf '%s\n' 2 > "$FM_HOME/state/confirm.rc"
  exit 2
fi

CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/confirm.out" 2>&1 &
printf '%s\n' "$!" > "$FM_HOME/state/confirm-pid"

i=0
while [ "$i" -lt 20 ]; do
  sleep 0.05
  i=$((i + 1))
done

cp "$FM_HOME/state/other-pid" "$FM_HOME/state/.lock"
printf '%s\n' OTHER > "$FM_HOME/state/.lock-session"
: > "$FM_HOME/state/release-holder"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/confirm-pid")"
printf '%s\n' "$?" > "$FM_HOME/state/confirm.rc"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/holder-pid")" || true
: > "$FM_HOME/state/stop-other"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/other-bash-pid")" || true
SH
  chmod +x "$dir/run.sh"

  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" FM_WAKE="$ROOT/bin/fm-wake-lib.sh" \
    FM_CLAUDE="$NAMED_CLAUDE" \
    "$NAMED_CLAUDE" "$dir/run.sh" &
  session_pid=$!
  BG_FIXTURE_PIDS+=("$session_pid")
  wait_for_file "$dir/state/acquire.rc" "the initial lock acquisition"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/acquire.rc")" \
    "the session could not acquire its lock: $(cat "$dir/state/acquire.out")"
  wait_for_file "$dir/state/other-pid" "the other live harness pid"
  other_pid=$(tr -d '[:space:]' < "$dir/state/other-pid")
  BG_FIXTURE_PIDS+=("$other_pid")
  wait_for_file "$dir/state/holder-pid" "the claim-lock holder pid"
  holder_pid=$(tr -d '[:space:]' < "$dir/state/holder-pid")
  BG_FIXTURE_PIDS+=("$holder_pid")
  wait_for_file "$dir/state/confirm-pid" "the same-session confirmation pid"
  confirm_pid=$(tr -d '[:space:]' < "$dir/state/confirm-pid")
  BG_FIXTURE_PIDS+=("$confirm_pid")
  wait_for_file "$dir/state/confirm.rc" "the contended confirmation result"
  wait "$session_pid" || true
  [ "$(tr -d '[:space:]' < "$dir/state/confirm.rc")" != 0 ] \
    || fail "the waiter reported success after another live session published: $(cat "$dir/state/confirm.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = OTHER ] \
    || fail "the waiter overwrote the other session's sidecar to $(cat "$dir/state/.lock-session")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$other_pid" ] \
    || fail "the waiter rewrote lock line 1 off the other live session"
  grep -q "another live firstmate session holds the lock (pid $other_pid, session OTHER)" "$dir/state/confirm.out" \
    || fail "the waiter did not refuse the other live owner: $(cat "$dir/state/confirm.out")"
  pass "session-lock: a waiting confirmation does not steal another session's lock"
}

# A failed line-1 write after publishing a new id must restore the previous
# sidecar, not leave the new id beside the unclaimed pid.
test_failed_lock_write_restores_previous_sidecar() {
  local dir stale_pid
  dir="$TMP_ROOT/restore-sidecar"
  mkdir -p "$dir/state"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/acquire.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/acquire.rc"
      printf "%s\n" "$$" > "$FM_HOME/state/stale-pid"
    '
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/acquire.rc")" \
    "the first session could not acquire its lock: $(cat "$dir/state/acquire.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = S1 ] \
    || fail "the first session did not record S1"
  stale_pid=$(tr -d '[:space:]' < "$dir/state/stale-pid")
  cp "$dir/state/.lock" "$dir/state/lock-before-reclaim"
  chmod a-w "$dir/state/.lock" || fail "could not make the stale lock read-only"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reclaim.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reclaim.rc"
    '
  chmod u+w "$dir/state/.lock" 2>/dev/null || true
  [ "$(tr -d '[:space:]' < "$dir/state/reclaim.rc")" != 0 ] \
    || fail "a read-only stale lock was overwritten: $(cat "$dir/state/reclaim.out")"
  grep -q 'cannot write session lock' "$dir/state/reclaim.out" \
    || fail "the reclaim did not fail on the lock write: $(cat "$dir/state/reclaim.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = S1 ] \
    || fail "the failed reclaim left sidecar $(cat "$dir/state/.lock-session"), expected the previous id S1"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$stale_pid" ] \
    || fail "the failed reclaim rewrote lock line 1"
  cmp -s "$dir/state/lock-before-reclaim" "$dir/state/.lock" \
    || fail "the failed reclaim changed lock bytes when line 1 was unwritable"
  pass "session-lock: a failed lock write restores the previous sidecar"
}

# A failed line-1 write that had no previous sidecar must not leave the new id
# behind; the lock stays ancestry-only.
test_failed_lock_write_removes_new_sidecar_when_none_existed() {
  local dir
  dir="$TMP_ROOT/restore-absent-sidecar"
  mkdir -p "$dir/state"
  printf '1\n' > "$dir/state/.lock"
  chmod a-w "$dir/state/.lock" || fail "could not make the stale lock read-only"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reclaim.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reclaim.rc"
    '
  chmod u+w "$dir/state/.lock" 2>/dev/null || true
  [ "$(tr -d '[:space:]' < "$dir/state/reclaim.rc")" != 0 ] \
    || fail "a read-only stale lock was overwritten: $(cat "$dir/state/reclaim.out")"
  grep -q 'cannot write session lock' "$dir/state/reclaim.out" \
    || fail "the reclaim did not fail on the lock write: $(cat "$dir/state/reclaim.out")"
  [ ! -e "$dir/state/.lock-session" ] \
    || fail "the failed reclaim left sidecar $(cat "$dir/state/.lock-session"), expected none"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = 1 ] \
    || fail "the failed reclaim rewrote lock line 1"
  pass "session-lock: a failed lock write removes a newly created sidecar"
}

# A completed reclaim must keep the new id beside the new pid after the writer
# exits, so a late signal cannot unwind a verified publication.
test_verified_reclaim_keeps_new_sidecar() {
  local dir
  dir="$TMP_ROOT/verified-reclaim"
  mkdir -p "$dir/state"
  printf '1\n' > "$dir/state/.lock"
  printf 'S1\n' > "$dir/state/.lock-session"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reclaim.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reclaim.rc"
      printf "%s\n" "$$" > "$FM_HOME/state/new-pid"
    '
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/reclaim.rc")" \
    "the reclaim failed: $(cat "$dir/state/reclaim.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = S2 ] \
    || fail "the verified reclaim left sidecar $(cat "$dir/state/.lock-session"), expected S2"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$(tr -d '[:space:]' < "$dir/state/new-pid")" ] \
    || fail "the verified reclaim did not record the new anchor pid"
  pass "session-lock: a verified reclaim keeps the new sidecar beside the new pid"
}

# A re-anchor moves leases recorded against the old live line 1 onto the new
# anchor, so the other supervision actor still cannot claim a held task.
test_reanchor_keeps_task_leases_live() {
  local dir front_pid model_pid lease_rc
  dir="$TMP_ROOT/reanchor-leases"
  mkdir -p "$dir/state"
  "$NAMED_CLAUDE" -c '
    printf "%s\n" "$$" > "$0/state/front-pid"
    while [ ! -e "$0/state/stop" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 0.05; done
  ' "$dir" &
  BG_FIXTURE_PIDS+=("$!")
  wait_for_file "$dir/state/front-pid" "the front-end pid"
  front_pid=$(tr -d '[:space:]' < "$dir/state/front-pid")
  printf '%s\n' "$front_pid" > "$dir/state/.lock"
  printf 'S1\n' > "$dir/state/.lock-session"
  printf 'branch\t%s\t100\n' "$front_pid" > "$dir/state/.lease-t1"
  printf 'main\t%s\t200\n' "$front_pid" > "$dir/state/.lease-t2"
  printf 'branch\t%s\t300\n' "$$" > "$dir/state/.lease-t3"
  cp "$dir/state/.lease-t3" "$dir/state/lease-t3-before"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reanchor.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reanchor.rc"
      printf "%s\n" "$$" > "$FM_HOME/state/model-pid"
      while [ ! -e "$FM_HOME/state/stop" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 0.05; done
    ' &
  BG_FIXTURE_PIDS+=("$!")
  wait_for_file "$dir/state/model-pid" "the model-loop pid"
  model_pid=$(tr -d '[:space:]' < "$dir/state/model-pid")
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/reanchor.rc")" \
    "the same-session re-anchor failed: $(cat "$dir/state/reanchor.out")"
  kill -0 "$front_pid" 2>/dev/null || fail "the front-end exited, so the lock line was never live"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$model_pid" ] \
    || fail "the re-anchor left lock line 1 at $(cat "$dir/state/.lock"), expected $model_pid"
  [ "$(cat "$dir/state/.lease-t1")" = "$(printf 'branch\t%s\t100' "$model_pid")" ] \
    || fail "the branch lease was not moved to the new anchor: $(cat "$dir/state/.lease-t1")"
  [ "$(cat "$dir/state/.lease-t2")" = "$(printf 'main\t%s\t200' "$model_pid")" ] \
    || fail "the main lease was not moved to the new anchor: $(cat "$dir/state/.lease-t2")"
  cmp -s "$dir/state/lease-t3-before" "$dir/state/.lease-t3" \
    || fail "a lease recorded against another pid changed: $(cat "$dir/state/.lease-t3")"
  env -u FM_SUPERVISION_ACTOR -u FM_LEASE_HOLDER_PID FM_HOME="$dir" \
    "$ROOT/bin/fm-lease.sh" claim t1 > "$dir/state/main-claim.out" 2>&1
  lease_rc=$?
  expect_code 6 "$lease_rc" "main claimed the branch's task after the re-anchor: $(cat "$dir/state/main-claim.out")"
  env -u FM_SUPERVISION_ACTOR FM_HOME="$dir" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID="$model_pid" \
    "$ROOT/bin/fm-lease.sh" claim t2 > "$dir/state/branch-claim.out" 2>&1
  lease_rc=$?
  expect_code 6 "$lease_rc" "the branch claimed main's task after the re-anchor: $(cat "$dir/state/branch-claim.out")"
  : > "$dir/state/stop"
  pass "session-lock: a re-anchor keeps both supervision actors' task leases live"
}

autoarm_midturn_healthy() {  # <state-dir>
  FM_STATE_OVERRIDE="$1" bash -c '. "$0"; fm_autoarm_midturn_healthy "$FM_STATE_OVERRIDE" 300' "$ROOT/bin/fm-wake-lib.sh"
}

# A re-anchor during a rewake handling turn that has outrun grace moves the
# auto-arm ledger's session_pid with line 1 and keeps the ledger's other bytes
# and mtime, so the mid-turn guard still sees healthy supervision.
test_reanchor_keeps_autoarm_midturn_healthy() {
  local dir front_pid model_pid
  dir="$TMP_ROOT/reanchor-autoarm"
  mkdir -p "$dir/state"
  "$NAMED_CLAUDE" -c '
    printf "%s\n" "$$" > "$0/state/front-pid"
    while [ ! -e "$0/state/stop" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 0.05; done
  ' "$dir" &
  BG_FIXTURE_PIDS+=("$!")
  wait_for_file "$dir/state/front-pid" "the front-end pid"
  front_pid=$(tr -d '[:space:]' < "$dir/state/front-pid")
  printf '%s\n' "$front_pid" > "$dir/state/.lock"
  printf 'S1\n' > "$dir/state/.lock-session"
  printf 'epoch=7 owner_pid=1 outcome=rewake updated_at=1 session_pid=%s recovery_generation=g1\nidentity-1\n' \
    "$front_pid" > "$dir/state/.claude-autoarm-epoch"
  printf 'acked:handling:g1\n' > "$dir/state/.watcher-down"
  touch -t 201901010000 "$dir/state/.last-watcher-beat"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch" "$dir/state/epoch-mtime"
  autoarm_midturn_healthy "$dir/state" || fail "the rewake fixture is not healthy before the re-anchor, so this case proves nothing"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reanchor.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reanchor.rc"
      printf "%s\n" "$$" > "$FM_HOME/state/model-pid"
      while [ ! -e "$FM_HOME/state/stop" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 0.05; done
    ' &
  BG_FIXTURE_PIDS+=("$!")
  wait_for_file "$dir/state/model-pid" "the model-loop pid"
  model_pid=$(tr -d '[:space:]' < "$dir/state/model-pid")
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/reanchor.rc")" \
    "the same-session re-anchor failed: $(cat "$dir/state/reanchor.out")"
  kill -0 "$front_pid" 2>/dev/null || fail "the front-end exited, so the lock line was never live"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$model_pid" ] \
    || fail "the re-anchor left lock line 1 at $(cat "$dir/state/.lock"), expected $model_pid"
  [ "$(cat "$dir/state/.claude-autoarm-epoch")" = "$(printf 'epoch=7 owner_pid=1 outcome=rewake updated_at=1 session_pid=%s recovery_generation=g1\nidentity-1' "$model_pid")" ] \
    || fail "the rewake was not moved to the new anchor intact: $(cat "$dir/state/.claude-autoarm-epoch")"
  if [ "$dir/state/.claude-autoarm-epoch" -nt "$dir/state/epoch-mtime" ] \
    || [ "$dir/state/.claude-autoarm-epoch" -ot "$dir/state/epoch-mtime" ]; then
    fail "the rewake move changed the ledger mtime"
  fi
  autoarm_midturn_healthy "$dir/state" \
    || fail "the mid-turn guard rejects the rewake after the re-anchor: $(cat "$dir/state/reanchor.out")"
  : > "$dir/state/stop"
  pass "session-lock: a re-anchor during a rewake turn keeps the mid-turn auto-arm proof healthy"
}

test_version_named_session_is_identified_on_both_platforms
test_harness_at_namespace_pid1_is_examined
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_windows_fallback_requires_native_ancestry
test_windows_snapshot_is_taken_after_claim
test_same_session_id_owns_a_recycled_background_chain
test_anchor_pid_is_the_model_loop_process_only_for_a_trusted_id
# Windows without executable symlinks can copy bash to an extensionless name
# that Cygwin cannot exec. Probe only the binaries each case actually needs;
# never hide a real test failure after a fixture executable has started.
run_executable_fixture_test() {  # <test-function> <fixture-binary>...
  local test=$1 binary
  shift
  for binary in "$@"; do
    if ! "$binary" -c 'exit 0' >/dev/null 2>&1; then
      case "$(uname -s)" in
        CYGWIN*|MSYS*|MINGW*)
          printf 'skip - %s: platform cannot execute fixture %s (Windows executable-symlink capability required)\n' "$test" "$binary"
          return 0
          ;;
        *) fail "$test: cannot execute fixture $binary" ;;
      esac
    fi
  done
  "$test"
}
run_executable_fixture_test test_e2e_version_named_session_claims_the_home "$VERSIONED_CLAUDE"
run_executable_fixture_test test_e2e_daemon_parented_session_claims_the_home "$NAMED_CLAUDE"
run_executable_fixture_test test_e2e_daemon_parented_version_named_session_keeps_its_lock "$VERSIONED_CLAUDE" "$NAMED_CLAUDE"
run_executable_fixture_test test_e2e_background_session_keeps_its_lock_across_a_recycled_chain "$NAMED_CLAUDE"
run_executable_fixture_test test_same_session_confirmation_refreshes_rekeyed_id_under_claim_lock "$NAMED_CLAUDE"
run_executable_fixture_test test_same_session_confirmation_does_not_steal_after_wait "$NAMED_CLAUDE"
run_executable_fixture_test test_failed_lock_write_restores_previous_sidecar "$NAMED_CLAUDE"
run_executable_fixture_test test_failed_lock_write_removes_new_sidecar_when_none_existed "$NAMED_CLAUDE"
run_executable_fixture_test test_verified_reclaim_keeps_new_sidecar "$NAMED_CLAUDE"
run_executable_fixture_test test_reanchor_keeps_task_leases_live "$NAMED_CLAUDE"
run_executable_fixture_test test_reanchor_keeps_autoarm_midturn_healthy "$NAMED_CLAUDE"
