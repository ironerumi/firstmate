#!/usr/bin/env bash
set -eu
for sha in 07409e73f3bdb6de2970869fce16cbe498011d62 d44427a3 34c77d54 427056c4; do
  echo "=== upstream $sha check runs ==="
  gh-axi api "/repos/kunchenguid/firstmate/commits/$sha/check-runs?per_page=100" --jq '{total_count, checks: [.check_runs[] | {name,status,conclusion}]}'
done
