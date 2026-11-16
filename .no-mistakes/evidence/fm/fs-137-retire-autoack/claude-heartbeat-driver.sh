#!/usr/bin/env bash
set -u
ROOT=$PWD
E=~/.no-mistakes/evidence/01M7J52HYGCQ2XX0FPT3Z582E1
LAB="$ROOT/.nm-claude-lab"
bash bin/fm-lab-home.sh create "$LAB" || exit
SOCKET_DIR=$(bash bin/fm-lab-home.sh tmux-dir "$LAB") || exit
cleanup() {
 TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab capture-pane -p -S -1000 -t primary > "$E/claude-heartbeat-pane.txt" 2>&1 || true
 [ ! -f "$LAB/state/observer.log" ] || cp "$LAB/state/observer.log" "$E/claude-heartbeat-observer.log"
 TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab kill-server 2>/dev/null || true
 bash bin/fm-lab-home.sh teardown "$LAB"
 rm -rf "$LAB"
}
trap cleanup EXIT
mkdir -p "$LAB/tmux"
mkfifo "$LAB/input"
exec 3<>"$LAB/input"
python3 - "$LAB" <<'PY'
import json,sys
from pathlib import Path
lab=Path(sys.argv[1])
script=lab/'observe.sh'
script.write_text('#!/bin/bash\nif [ -f "$FM_HOME/state/.afk-contract" ]; then echo away; else echo present; fi >> "$FM_HOME/state/observer.log"\n')
(lab/'observer.json').write_text(json.dumps({'hooks':{'Stop':[{'hooks':[{'type':'command','command':'bash '+str(script)}]}]}}))
PY
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab new-session -d -x 120 -y 40 -s primary -c "$ROOT" -e FM_HOME="$LAB" "claude -p --input-format stream-json --output-format stream-json --verbose --no-session-persistence --dangerously-skip-permissions --setting-sources project --plugin-dir '$ROOT/.nm-heartbeat-plugin' --settings '$LAB/observer.json' --append-system-prompt 'This is a disposable live-verification home. Confine every file write to FM_HOME. Do not touch other homes, user configuration, credentials, or shared services. Use bin scripts from the current worktree. There are no tasks running.' < '$LAB/input' > '$E/claude-heartbeat-stream.jsonl' 2>&1; rc=\$?; echo \$rc > '$E/claude-cli-exit.txt'; sleep 220"
send_prompt() {
 local message
 message=$(python3 -c 'import json,sys; print(json.dumps({"type":"user","message":{"role":"user","content":sys.argv[1]}}))' "$1")
 printf '%s\n' "$message" >&3
}
wait_stop() {
 local target=$1
 for ((j=0;j<65;j++)); do
  local pane
  pane=$(TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab capture-pane -p -t primary 2>/dev/null)
  if [ -f "$E/claude-cli-exit.txt" ]; then echo 'Claude exited before scenario completion'; return 1; fi
  if [ -f "$LAB/state/observer.log" ] && [ "$(wc -l < "$LAB/state/observer.log")" -ge "$target" ]; then sleep 2; return 0; fi
  sleep 1
 done
 echo "No Stop observed at step $target"; return 1
}
sleep 6
TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab capture-pane -p -t primary > "$E/claude-heartbeat-startup.txt"
send_prompt '/afk I am away. This is a disposable lab home. Do not touch any other home or write outside FM_HOME. No tasks are running.'
wait_stop 1 || exit 2
[ -f "$LAB/state/.afk-contract" ] || { echo 'Initial away record absent'; exit 2; }
echo 'entry: away record exists'
for n in 1 2 3; do
 T0=$(<"$E/t0"); echo "Heartbeat $n elapsed: $(( ($(date +%s)-T0)/60 )) minutes"
 sleep 1
 send_prompt '/lab-heartbeat:heartbeat'
 wait_stop "$((n+1))" || exit 2
 if [ ! -f "$LAB/state/.afk-contract" ]; then echo "FAIL heartbeat $n cleared away"; exit 1; fi
 echo "heartbeat $n: away record persists"
done
send_prompt "I'm back. Please report the current away posture."
wait_stop 5 || exit 2
[ ! -f "$LAB/state/.afk-contract" ] || { echo 'FAIL genuine captain return did not clear away'; exit 1; }
echo 'captain return: away record cleared'
