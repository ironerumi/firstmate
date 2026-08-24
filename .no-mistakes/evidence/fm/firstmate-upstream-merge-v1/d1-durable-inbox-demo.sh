#!/usr/bin/env bash
# Manual end-to-end demonstration (test phase evidence) of D1: durable-inbox
# steer delivery. Drives the REAL bin/fm-send.sh over a stubbed tmux exactly
# as tests/fm-send-inbox.test.sh does, in a scratch home under the evidence
# dir, proving: (1) the steer is durably sequenced into state/<id>.inbox/,
# (2) only a doorbell line is typed, the payload is NEVER typed, (3) a second
# send enqueues the NEXT sequence number without retyping, (4) round-trips
# byte-exact, and (5) carve-outs for "/" steers keep the typed harness plane.
set -u
REPO=/Users/gu_yifu/.no-mistakes/worktrees/dd6dd5949f4a/01M0S2Y7DSFSYNRA8SSKPVDCN0
EVID=$(mktemp -d /var/folders/l8/tyd57dc53v3938ttkwmw5kgr0000gp/T/no-mistakes-evidence/01M0S2Y7DSFSYNRA8SSKPVDCN0/d1-demo.XXXXXX)
SEND="$REPO/bin/fm-send.sh"
mkdir -p "$EVID/home/state" "$EVID/fakebin"

cat > "$EVID/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then printf '%s\n' "${1:-}" >> "$FM_SEND_LOG"; fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
chmod +x "$EVID/fakebin/tmux"
cat > "$EVID/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$EVID/fakebin/sleep"

. "$REPO/bin/fm-marker-lib.sh"
. "$REPO/tests/lib.sh" >/dev/null 2>&1 || true
fm_write_meta "$EVID/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=claude"

run_send() { # <name> [env...] -- args...
  local name=$1; shift
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  : > "$EVID/$name.send.log"
  env PATH="$EVID/fakebin:$PATH" FM_ROOT_OVERRIDE="$EVID/home" FM_HOME="$EVID/home" \
    FM_SEND_LOG="$EVID/$name.send.log" FM_SEND_SETTLE=0 "${envs[@]+"${envs[@]}"}" \
    "$SEND" "$@" >"$EVID/$name.out" 2>"$EVID/$name.err"
  echo "exit=$?"
}

echo "================================================================"
echo "CASE 1: ordinary text steer -> durable inbox enqueue, never typed"
echo "================================================================"
run_send case1 -- t1 "please rebase onto main"
echo "--- state/t1.inbox/ listing after send ---"
ls -1 "$EVID/home/state/t1.inbox/"
echo "--- durable record 001.msg ---"
cat "$EVID/home/state/t1.inbox/001.msg"
echo "--- everything that crossed the "terminal" (send.log) ---"
cat "$EVID/case1.send.log"
echo "--- payload typed? (must be NO) ---"
grep -q "rebase onto main" "$EVID/case1.send.log" && echo "YES (VIOLATION)" || echo "no payload in typed output (doorbell-only)"

echo
echo "================================================================"
echo "CASE 2: second send -> NEW sequenced record, still never retypes"
echo "================================================================"
run_send case2 -- t1 "also update the changelog"
ls -1 "$EVID/home/state/t1.inbox/"
echo "--- record 002.msg ---"
cat "$EVID/home/state/t1.inbox/002.msg"
echo "--- case2 typed (send.log) ---"
cat "$EVID/case2.send.log"
grep -q "changelog" "$EVID/case2.send.log" && echo "YES (VIOLATION)" || echo "no payload in typed output (doorbell-only)"

echo
echo "================================================================"
echo "CASE 3: byte-exact multi-line round trip"
echo "================================================================"
run_send case3 -- t1 $'first line\nsecond line\nthird: punct!'
cat "$EVID/home/state/t1.inbox/003.msg"
echo "--- body extracted via fm_task_inbox_body ---"
bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$REPO/bin/fm-task-inbox-lib.sh" "$EVID/home/state/t1.inbox/003.msg"

echo
echo "================================================================"
echo "CASE 4: carve-out - a leading / steer keeps the typed harness plane"
echo "================================================================"
run_send case4 -- t1 "/status"
echo "--- a /-steer must NOT be in t1.inbox ---"
ls "$EVID/home/state/t1.inbox/" 2>/dev/null || echo "(no inbox records)"
echo "--- typed output for / steer ---"
cat "$EVID/case4.send.log"

echo
echo "================================================================"
echo "EVIDENCE DIR: $EVID"
echo "================================================================"