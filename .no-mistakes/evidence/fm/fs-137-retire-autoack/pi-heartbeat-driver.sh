#!/usr/bin/env bash
set -u
ROOT=$PWD
E=~/.no-mistakes/evidence/01M7J52HYGCQ2XX0FPT3Z582E1
LAB="$ROOT/.nm-pi-lab"
bash bin/fm-lab-home.sh create "$LAB" || exit
SOCKET_DIR=$(bash bin/fm-lab-home.sh tmux-dir "$LAB") || exit
cleanup() {
 TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab capture-pane -p -S -300 -t primary > "$E/pi-heartbeat-pane.txt" 2>&1 || true
 TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab kill-server 2>/dev/null || true
 bash bin/fm-lab-home.sh teardown "$LAB"
 rm -rf "$LAB"
}
trap cleanup EXIT
mkdir -p "$LAB/tmux" "$LAB/sessions"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab new-session -d -x 120 -y 40 -s primary -c "$ROOT" -e FM_HOME="$LAB" -e FM_HEARTBEAT_EVIDENCE="$E/pi-heartbeat.jsonl" "pi --offline --no-extensions --no-mcp --no-context-files --no-skills --no-prompt-templates -e '$ROOT/.nm-heartbeat-extension.ts' --skill '$ROOT/.agents/skills/afk/SKILL.md' --session-dir '$LAB/sessions' --approve"
sleep 3
TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab send-keys -t primary -l '/skill:afk I am away. This is a disposable lab home. Do not touch any other home or write outside FM_HOME. Use the bin scripts from the current worktree. No tasks are running.'
TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab send-keys -t primary Enter
for ((i=0;i<210;i++)); do
 if [ -f "$E/pi-heartbeat.jsonl" ] && grep -q '"complete":true' "$E/pi-heartbeat.jsonl"; then
  cp -R "$LAB/sessions" "$E/pi-heartbeat-sessions"
  exit 0
 fi
 if ! TMUX_TMPDIR="$SOCKET_DIR" tmux -L fm-lab has-session -t primary 2>/dev/null; then
  cp -R "$LAB/sessions" "$E/pi-heartbeat-sessions"
  echo 'Pi exited before completing heartbeat scenario'; exit 2
 fi
 sleep 1
done
cp -R "$LAB/sessions" "$E/pi-heartbeat-sessions"
echo 'time bound'; exit 124
