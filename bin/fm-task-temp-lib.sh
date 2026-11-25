#!/usr/bin/env bash
fm_task_temp_rule() {
  local data=$1 id=$2
  cat <<EOF
Named pipes, sockets, and other temporary sync objects go only in the task temp root \`/tmp/fm-$id/\` (\`tasktmp=\` in the task's meta), never under \`$data/$id/\`: those records outlive the task and a leftover pipe hangs anything that reads them.
EOF
}
