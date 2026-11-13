#!/usr/bin/env bash
set -eu
T0=$(< ~/.no-mistakes/evidence/01M7AXJ0M8JYYSFXRXT049SN4P/test-start)
echo "phase 2 / cadence elapsed minutes: $(( ($(date +%s) - T0) / 60 ))"
. bin/fm-timeout-lib.sh
scenario() {
  LAB=$(mktemp -d "$PWD/.fm-validation-lab.XXXXXX")
  trap 'rm -rf "$LAB"' EXIT
  mkdir -p "$LAB/config" "$LAB/state" "$LAB/bin"
  printf '#!/bin/sh\nprintf "probe\\n" >> "%s"\nprintf "cadence-fixture 1.0.0\\n"\n' "$LAB/probes" > "$LAB/bin/fm-cadence-fixture"
  chmod +x "$LAB/bin/fm-cadence-fixture"
  printf '{"tools":[{"name":"cadence","command":"fm-cadence-fixture"}]}\n' > "$LAB/config/watched-tools.json"
  for offset in 0 899 900; do
    env -u FM_TOOL_UPDATE_INTERVAL -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$LAB" PATH="$LAB/bin:$PATH" FM_CHECK_TIMEOUT=30 FM_TOOL_UPDATE_NOW="$((1700000000 + offset))" bash bin/fm-tool-update-check.sh check > "$LAB/output"
    count=$(wc -l < "$LAB/probes" | tr -d ' ')
    printf 'At +%ss: probes=%s; output bytes=%s\n' "$offset" "$count" "$(wc -c < "$LAB/output" | tr -d ' ')"
    case "$offset" in 0|899) test "$count" = 1;; 900) test "$count" = 2;; esac
    test ! -s "$LAB/output"
  done
  printf 'Default cadence: no early probe at 899s; second probe exactly at 900s.\n'
}
export -f scenario
fm_run_timed 240 bash -eu -c scenario
