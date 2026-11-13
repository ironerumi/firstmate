#!/usr/bin/env bash
set -eu
git fetch --no-tags https://github.com/kunchenguid/firstmate.git main:refs/remotes/reference/main
echo '=== actual fork-budget CLI ==='
bash bin/fm-lint.sh --check-fork-surface
echo 'budget CLI exit=0'
base=$(git merge-base HEAD reference/main)
echo "merge base=$base"
echo '=== independent upstream-owned file/line measurement ==='
git diff --no-renames --numstat --diff-filter=MDT "$base" -- | awk '{files++; added += $1; deleted += $2} END {printf "files=%d added=%d deleted=%d total=%d\n",files,added,deleted,added+deleted}'
echo '=== stored budget ==='
git show HEAD:.fork-surface-budget
echo '=== upstream commits ahead ==='
git log --oneline "$base"..reference/main
