#!/usr/bin/env bash
# ralph-safe-merge.sh — Programmatic CI gate before merging a PR.
# Usage: ralph-safe-merge.sh <pr-number> [gh-pr-merge-flags...]
#
# Verifies all CI checks pass before executing gh pr merge --auto.
# If checks fail, refuses to merge and exits 1.
# If checks are pending, polls until they resolve or timeout.
set -euo pipefail

PR_NUMBER="${1:?Usage: ralph-safe-merge.sh <pr-number> [merge-flags...]}"
shift
MERGE_FLAGS=("$@")

TIMEOUT="${RALPH_MERGE_CI_TIMEOUT:-300}"
POLL_INTERVAL=15

# Returns: 0=passed, 1=failed, 2=pending, 3=no checks
get_ci_status() {
  local checks_json
  checks_json=$(gh pr checks "$PR_NUMBER" --json state,bucket,name 2>/dev/null || echo "")

  [[ -z "$checks_json" || "$checks_json" == "[]" ]] && return 3

  local fail_count pending_count
  fail_count=$(echo "$checks_json" | jq '[.[] | select(.bucket == "fail")] | length')
  pending_count=$(echo "$checks_json" | jq '[.[] | select(.bucket == "pending")] | length')

  if [[ "$fail_count" -gt 0 ]]; then
    return 1
  elif [[ "$pending_count" -gt 0 ]]; then
    return 2
  else
    return 0
  fi
}

print_failed_checks() {
  gh pr checks "$PR_NUMBER" --json name,bucket,state 2>/dev/null \
    | jq -r '.[] | select(.bucket == "fail") | "  FAIL: \(.name) (\(.state))"' >&2
}

start=$(date +%s)
while true; do
  set +e
  get_ci_status
  status=$?
  set -e

  case $status in
    0)
      echo "CI checks passed — proceeding to merge PR #${PR_NUMBER}"
      exec gh pr merge "$PR_NUMBER" --auto "${MERGE_FLAGS[@]}"
      ;;
    1)
      echo "CI FAILED — blocking merge of PR #${PR_NUMBER}. Failed checks:" >&2
      print_failed_checks
      exit 1
      ;;
    3)
      echo "No CI checks found — proceeding to merge PR #${PR_NUMBER}"
      exec gh pr merge "$PR_NUMBER" --auto "${MERGE_FLAGS[@]}"
      ;;
    2)
      elapsed=$(( $(date +%s) - start ))
      if (( elapsed >= TIMEOUT )); then
        echo "Timed out waiting for CI checks on PR #${PR_NUMBER} after ${TIMEOUT}s — blocking merge" >&2
        exit 1
      fi
      echo "CI checks still pending for PR #${PR_NUMBER} (${elapsed}/${TIMEOUT}s)..."
      sleep "$POLL_INTERVAL"
      ;;
  esac
done
