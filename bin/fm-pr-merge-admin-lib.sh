#!/usr/bin/env bash
# fm-pr-merge-admin-lib.sh - the fork's captain-authorized admin-merge decision.
#
# Usage: . bin/fm-pr-merge-admin-lib.sh (from bin/fm-pr-merge.sh)
#
# The exact token --admin after the optional -- separator is this fork's
# captain-authorized branch-protection override (AGENTS.md section 7). It is
# permitted in place of --attended-override for that single flag while every
# live pre-merge check in fm-pr-merge.sh still applies, and near-miss spellings
# are refused so an intended override is never silently dropped.
#
# fm_pr_merge_admin_arg <arg> classifies one protected forge argument:
#   0 -> the exact admin token, allowed through to the forge
#   1 -> a refused near-miss (the refusal has been printed)
#   2 -> not an admin argument; the caller's own protection checks still apply
#
# Nothing here writes or reaches a forge. The policy is fork-owned so
# fm-pr-merge.sh carries only the classification call.
set -u

fm_pr_merge_admin_arg() {  # <arg>
  case "$1" in
    --admin) return 0 ;;
    --admin=*)
      echo "error: pass exactly --admin for a captain-authorized admin merge" >&2
      return 1
      ;;
  esac
  return 2
}
