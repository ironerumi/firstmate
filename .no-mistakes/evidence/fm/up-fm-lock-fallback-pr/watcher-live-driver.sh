#!/usr/bin/env bash
set -eu
ROOT=$PWD
LAB="$PWD/l"
EVIDENCE=/Users/gu_yifu/.no-mistakes/evidence/01M62N8Y0JDN77J5355YNCS8ZQ
mkdir -p "$LAB/copy-bin"
printf '#!/usr/bin/env bash\nif [ "$1" = -s ]; then exec cp -R "$2" "$3"; fi\nexec /bin/ln "$@"\n' > "$LAB/copy-bin/ln"
chmod +x "$LAB/copy-bin/ln"
export PATH="$LAB/copy-bin:$PATH" FM_HOME="$LAB" FM_BACKEND=tmux
export FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
p1= p2= p3=
cleanup() {
  for p in "$p1" "$p2" "$p3"; do [ -z "$p" ] || kill -TERM "$p" 2>/dev/null || true; done
  wait || true
}
trap cleanup EXIT
wait_lock() {
  local i
  for i in $(seq 1 200); do
    if [ "$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null || true)" = "$1" ] && [ -e "$LAB/state/.last-watcher-beat" ] && [ -e "$LAB/state/.watch.lock/fm-home" ] && [ ! -e "$LAB/state/.watch.lock.steal" ]; then sleep 1; return 0; fi
    sleep .1
  done
  echo "FAIL: no watcher lock for $1"; return 1
}
"$ROOT/bin/fm-watch.sh" > "$EVIDENCE/watcher-first.log" 2>&1 & p1=$!
wait_lock "$p1"
[ ! -L "$LAB/state/.watch.lock" ]
printf 'first watcher acquired directory lock: pid=%s generation=%s\n' "$p1" "$(echo "$LAB/state/.watch.lock"/.owner.*)"
"$ROOT/bin/fm-watch.sh" > "$EVIDENCE/watcher-contender.log" 2>&1 & p2=$!
for i in $(seq 1 100); do
  grep -q 'already running pid' "$EVIDENCE/watcher-contender.log" && break
  sleep .1
done
grep 'already running pid' "$EVIDENCE/watcher-contender.log"
[ "$(cat "$LAB/state/.watch.lock/pid")" = "$p1" ]
echo 'contending watcher refused; first owner unchanged'
kill -KILL "$p1"; wait "$p1" 2>/dev/null || true; p1=
rm -f "$LAB/state/.last-watcher-beat"
"$ROOT/bin/fm-watch.sh" > "$EVIDENCE/watcher-successor.log" 2>&1 & p3=$!
wait "$p3"
p3=
grep 'check: rearm-resurface' "$EVIDENCE/watcher-successor.log"
[ ! -e "$LAB/state/.watch.lock" ] && [ ! -e "$LAB/state/.watch.lock.steal" ]
echo 'successor reclaimed dead watcher, surfaced recovery wake, and released both locks completely'
echo LIVE_WATCHER_COMPLETE
