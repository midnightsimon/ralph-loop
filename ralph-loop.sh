#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${REPO_ROOT}/.ralph-logs"
SKIP_FILE="${REPO_ROOT}/.ralph-skip"
LABEL_PRIORITY=("bug" "testing" "enhancement" "documentation")

ALLOWED_TOOLS="Read,Edit,Write,Grep,Glob,\
Bash(git *),Bash(gh *),Bash(npm *),Bash(npx *),\
Bash(cmake *),Bash(cd *),Bash(ls *),Bash(mkdir *),Bash(rm *)"

# ── Defaults ────────────────────────────────────────────────────────────────
COUNT=1
DRY_RUN=false
MODEL="opus"
MAX_TURNS=75
LABEL_FILTER=""
TIMEOUT=1800  # seconds (30 minutes)
ISSUE_LIST=""  # comma-separated issue numbers

# ── Parse CLI flags ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --count)
      COUNT="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN=true; shift ;;
    --model)
      MODEL="$2"; shift 2 ;;
    --max-turns)
      MAX_TURNS="$2"; shift 2 ;;
    --label)
      LABEL_FILTER="$2"; shift 2 ;;
    --timeout)
      TIMEOUT="$2"; shift 2 ;;
    --issues)
      ISSUE_LIST="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: ralph-loop.sh [OPTIONS]"
      echo ""
      echo "Autonomous issue & PR worker — invokes Claude Code headlessly."
      echo ""
      echo "Options:"
      echo "  --count N      Number of iterations (default: 1)"
      echo "  --dry-run      Print what would happen without invoking Claude"
      echo "  --model MODEL  Model to use: sonnet, opus, haiku (default: opus)"
      echo "  --max-turns N  Max agentic turns per invocation (default: 75)"
      echo "  --label LABEL  Only pick issues with this label"
      echo "  --timeout SECS Timeout per Claude invocation in seconds (default: 1800)"
      echo "  --issues N,N,N Comma-separated issue numbers to work on"
      echo "  -h, --help     Show this help message"
      exit 0
      ;;
    *)
      echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Check if an issue number is in the skip file
is_skipped() {
  local issue_number="$1"
  [[ -f "$SKIP_FILE" ]] && grep -q "^${issue_number}$" "$SKIP_FILE"
}

# Add an issue to the skip file
skip_issue() {
  local issue_number="$1"
  local reason="$2"
  if ! is_skipped "$issue_number"; then
    echo "$issue_number" >> "$SKIP_FILE"
    log "Added issue #${issue_number} to skip file (${reason})"
  fi
}

# Denial patterns to scan for in Claude's output.
# When Claude tries a tool not on the allowlist, the CLI rejects it and the
# model's response will mention the denial. We detect that and abort early.
DENIAL_PATTERN="tool.*denied|not.*allowed|permission.*denied|tool.*not available|rejected tool|tool.*blocked"

# Wrapper: run claude with real-time denial detection and timeout.
# Captures full output to .ralph-logs/. If a tool denial is detected in the
# output stream, kills claude immediately and returns 1.
# Usage: run_claude [claude args...]
run_claude() {
  mkdir -p "$LOG_DIR"
  local ts
  ts=$(date '+%Y%m%d-%H%M%S')
  local outfile="${LOG_DIR}/${ts}.out"
  local errfile="${LOG_DIR}/${ts}.err"
  : > "$outfile"
  : > "$errfile"

  log "Claude output → ${outfile}"

  # Run claude in the background so we can monitor its output
  claude "$@" >"$outfile" 2>"$errfile" &
  local pid=$!
  local start_time
  start_time=$(date +%s)

  # Poll output files for permission denials and timeout while claude runs
  while kill -0 "$pid" 2>/dev/null; do
    # Check for timeout
    local elapsed=$(( $(date +%s) - start_time ))
    if [[ $elapsed -ge $TIMEOUT ]]; then
      log "ERROR: Claude timed out after ${TIMEOUT}s — killing process"
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null || true
      log "Check ${outfile} for partial output"
      return 1
    fi
    if grep -qiE "$DENIAL_PATTERN" "$outfile" "$errfile" 2>/dev/null; then
      log "PERMISSION DENIED — Claude needs a tool not on the allowlist. Aborting."
      grep -hiE "$DENIAL_PATTERN" "$outfile" "$errfile" 2>/dev/null | head -5 | while IFS= read -r line; do
        log "  → $line"
      done
      log "Add the missing tool to ALLOWED_TOOLS and re-run."
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null || true
      return 1
    fi
    sleep 2
  done

  wait "$pid" 2>/dev/null || true
  local rc=$?

  # Post-completion check (catches denials in buffered/json output)
  if grep -qiE "$DENIAL_PATTERN" "$outfile" "$errfile" 2>/dev/null; then
    log "PERMISSION DENIED detected in completed output:"
    grep -hiE "$DENIAL_PATTERN" "$outfile" "$errfile" 2>/dev/null | head -5 | while IFS= read -r line; do
      log "  → $line"
    done
    log "Add the missing tool to ALLOWED_TOOLS and re-run."
    return 1
  fi

  # Check for max turns reached
  if grep -qiE "max turns|maximum.*turns|reached.*turns" "$outfile" "$errfile" 2>/dev/null; then
    log "WARNING: Claude hit max turns limit — task may be incomplete"
    # Return code 2 to signal max turns (callers can check this)
    cat "$outfile"
    return 2
  fi

  if [[ $rc -ne 0 ]]; then
    log "WARNING: Claude exited with code ${rc} — check ${outfile}"
  fi

  # Output captured stdout for callers using $() to capture it
  cat "$outfile"
  return $rc
}

find_open_pr() {
  gh pr list --state open --limit 1 --json number -q '.[0].number // empty'
}

pick_issue() {
  local labels_to_check=()

  if [[ -n "$LABEL_FILTER" ]]; then
    labels_to_check=("$LABEL_FILTER")
  else
    labels_to_check=("${LABEL_PRIORITY[@]}")
  fi

  # Try each label in priority order
  for label in "${labels_to_check[@]}"; do
    local issues
    issues=$(gh issue list --label "$label" --state open --search "no:assignee" --limit 5 --json number -q '.[].number')
    for issue in $issues; do
      if ! is_skipped "$issue"; then
        echo "$issue"
        return
      fi
    done
  done

  # Fallback: oldest unassigned open issue (no label filter)
  if [[ -z "$LABEL_FILTER" ]]; then
    local issues
    issues=$(gh issue list --state open --search "no:assignee sort:created-asc" --limit 5 --json number -q '.[].number')
    for issue in $issues; do
      if ! is_skipped "$issue"; then
        echo "$issue"
        return
      fi
    done
  fi
}

review_pr() {
  local pr_number="$1"
  local pr_title
  pr_title=$(gh pr view "$pr_number" --json title -q .title)

  log "Reviewing PR #${pr_number}: ${pr_title}"

  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY RUN] Would invoke Claude to review PR #${pr_number}"
    return
  fi

  local review_rc=0
  run_claude -p "You are reviewing pull request #${pr_number} in this repository.

## Instructions

1. Run \`gh pr view ${pr_number}\` to read the PR description.
2. Run \`gh pr diff ${pr_number}\` to see the full diff.
3. Read any changed files in full to understand context.
4. Evaluate the PR for:
   - Correctness and logic errors
   - Test coverage (are new features tested?)
   - Adherence to repo conventions (see CLAUDE.md)
   - Security issues
   - Code style and clarity

5. **If changes are needed and you can fix them:**
   - Check out the PR branch: \`gh pr checkout ${pr_number}\`
   - Make the necessary fixes
   - Commit with a clear message (conventional commits)
   - Push the fixes: \`git push\`
   - Then approve and merge (step 6)

6. **If the PR is good** (either initially or after your fixes):
   - \`gh pr review ${pr_number} --approve --body \"Looks good! Approved by Ralph.\"\`
   - \`gh pr merge ${pr_number} --squash --delete-branch\`

7. **If the PR is fundamentally broken** (can't be fixed reasonably):
   - \`gh pr close ${pr_number} --comment \"Closing: <explanation of why this PR is not mergeable>\"\`

Always explain your reasoning before taking action.

CRITICAL — HEADLESS AUTONOMY:
You are running in a fully automated headless pipeline with NO human present.
- NEVER ask for approval, confirmation, or permission for ANY action
- Execute ALL git and gh commands directly (commit, push, merge, close, etc.) without hesitation
- If something fails, try to fix it — do not stop and ask for guidance
- There is nobody to respond to your questions — just act" \
    --model "$MODEL" \
    --max-turns "$MAX_TURNS" \
    --allowedTools "$ALLOWED_TOOLS" || review_rc=$?

  # Clean up worktree and branch if PR was merged
  local pr_state
  pr_state=$(gh pr view "$pr_number" --json state -q .state 2>/dev/null || echo "")
  if [[ "$pr_state" == "MERGED" ]]; then
    local pr_branch
    pr_branch=$(gh pr view "$pr_number" --json headRefName -q .headRefName 2>/dev/null || echo "")
    if [[ -n "$pr_branch" ]]; then
      # Remove any worktree using this branch
      local worktree_path
      worktree_path=$(git worktree list --porcelain | grep -B2 "branch refs/heads/${pr_branch}" | grep "^worktree " | sed 's/^worktree //' || echo "")
      if [[ -n "$worktree_path" ]]; then
        log "Cleaning up worktree: ${worktree_path}"
        git worktree remove "$worktree_path" --force 2>/dev/null || true
        # If the directory still lingers (e.g. node_modules), force-remove it
        if [[ -d "$worktree_path" ]]; then
          log "Removing lingering worktree directory: ${worktree_path}"
          rm -rf "$worktree_path"
        fi
      fi
      # Also check .worktrees/ for a directory matching the branch suffix
      # (handles cases where git no longer tracks the worktree but the folder remains)
      local wt_dir="${REPO_ROOT}/.worktrees/${pr_branch#*/}"
      if [[ -d "$wt_dir" ]]; then
        log "Removing worktree directory: ${wt_dir}"
        git worktree remove "$wt_dir" --force 2>/dev/null || true
        rm -rf "$wt_dir"
      fi
      # Delete local branch
      git branch -D "$pr_branch" 2>/dev/null || true
      log "Cleaned up branch: ${pr_branch}"
    fi
    git worktree prune 2>/dev/null || true
    git pull origin main 2>/dev/null || true
  fi
}

work_issue() {
  local issue_number="$1"
  local issue_title
  local issue_body
  issue_title=$(gh issue view "$issue_number" --json title -q .title)
  issue_body=$(gh issue view "$issue_number" --json body -q .body)

  log "Working on issue #${issue_number}: ${issue_title}"

  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY RUN] Would invoke Claude to triage and implement issue #${issue_number}"
    return
  fi

  # Assign early so pick_issue skips this issue in future iterations
  gh issue edit "$issue_number" --add-assignee "@me"

  # ── Phase 1: Triage & Plan ──────────────────────────────────────────────
  log "Phase 1: Triaging issue #${issue_number}..."

  local plan_output
  local phase1_rc=0
  plan_output=$(run_claude -p "You are triaging GitHub issue #${issue_number}.

## Issue Title
${issue_title}

## Issue Body
${issue_body}

## Instructions

1. Read the codebase to understand whether this issue is still relevant.
   - Check if the problem described has already been fixed.
   - Check if the feature described already exists.
   - Check if the issue conflicts with current architecture.

2. If the issue is **no longer relevant**, output JSON:
   \`\`\`json
   {\"relevant\": false, \"reason\": \"<why it's no longer relevant>\", \"plan\": \"\"}
   \`\`\`

3. If the issue **is still relevant**, create a detailed implementation plan and output JSON:
   \`\`\`json
   {\"relevant\": true, \"reason\": \"<why it's still relevant>\", \"plan\": \"<detailed step-by-step implementation plan>\"}
   \`\`\`

CRITICAL: You are running headlessly with no human present. Never ask for approval — just execute and output the JSON.

Output ONLY the JSON object, no other text." \
    --model "$MODEL" \
    --max-turns "$MAX_TURNS" \
    --allowedTools "$ALLOWED_TOOLS" \
    --output-format json) || phase1_rc=$?

  if [[ $phase1_rc -eq 2 ]]; then
    skip_issue "$issue_number" "hit max turns during triage"
    return
  elif [[ $phase1_rc -ne 0 ]]; then
    log "Phase 1 failed for issue #${issue_number} (exit code ${phase1_rc})"
    return
  fi

  # Extract the result text from the JSON output
  local result_text
  result_text=$(echo "$plan_output" | jq -r '.result // empty' 2>/dev/null || echo "$plan_output")

  # ── Robust JSON extraction ──────────────────────────────────────────────
  # Phase 1 output may contain narrative text around the JSON. Try multiple
  # strategies to locate the JSON object with a "relevant" key.
  local parsed_json=""

  # Try 1: result_text is already raw JSON
  if echo "$result_text" | jq -e '.relevant' >/dev/null 2>&1; then
    parsed_json="$result_text"
  fi

  # Try 2: JSON is inside a ```json ... ``` code block
  if [[ -z "$parsed_json" ]]; then
    local extracted
    extracted=$(echo "$result_text" | sed -n '/^```json$/,/^```$/p' | sed '1d;$d')
    if [[ -n "$extracted" ]] && echo "$extracted" | jq -e '.relevant' >/dev/null 2>&1; then
      parsed_json="$extracted"
    fi
  fi

  # Try 3: Find first { ... } substring that parses as JSON with "relevant" key
  if [[ -z "$parsed_json" ]]; then
    parsed_json=$(python3 -c "
import json, sys
text = sys.stdin.read()
start = text.find('{')
while start != -1:
    for end in range(len(text), start, -1):
        try:
            obj = json.loads(text[start:end])
            if 'relevant' in obj:
                print(json.dumps(obj))
                sys.exit(0)
        except:
            pass
    start = text.find('{', start + 1)
" <<< "$result_text" 2>/dev/null || true)
  fi

  # Parse fields from extracted JSON, with fallbacks
  local is_relevant
  if [[ -n "$parsed_json" ]]; then
    is_relevant=$(echo "$parsed_json" | jq -r '.relevant')
  elif echo "$result_text" | grep -qo '"relevant":[[:space:]]*false'; then
    is_relevant="false"
  else
    is_relevant="true"
  fi

  if [[ "$is_relevant" == "false" ]]; then
    local reason
    if [[ -n "$parsed_json" ]]; then
      reason=$(echo "$parsed_json" | jq -r '.reason // empty')
    fi
    reason="${reason:-Issue appears to be no longer relevant based on codebase analysis.}"
    log "Issue #${issue_number} is no longer relevant: ${reason}"
    gh issue close "$issue_number" --comment "Closing: ${reason}"
    return
  fi

  # Extract the plan
  local plan
  if [[ -n "$parsed_json" ]]; then
    plan=$(echo "$parsed_json" | jq -r '.plan // empty')
  fi
  plan="${plan:-Implement the issue as described.}"

  log "Issue #${issue_number} is relevant. Proceeding to implementation..."

  # ── Phase 2: Implement ──────────────────────────────────────────────────
  log "Phase 2: Implementing issue #${issue_number}..."

  local phase2_rc=0
  run_claude -p "You are implementing GitHub issue #${issue_number}.

## Issue Title
${issue_title}

## Issue Body
${issue_body}

## Implementation Plan (from triage phase)
${plan}

## Instructions

Follow the CLAUDE.md workflow exactly:

1. Run \`git fetch origin\` first.
2. Create a worktree:
   \`git worktree add .worktrees/<feature-name> -b feature/<feature-name> origin/main\`
   Choose a descriptive feature name based on the issue.
3. Change to the worktree directory.
4. Run \`npm install\` in the worktree.
5. Implement the changes according to the plan above.
6. Run relevant tests to verify your changes work:
   - Frontend: \`npm -w @typeblazer/web run test:unit\`
   - API: \`npm -w @typeblazer/api run test\`
   - Lint: \`npm run lint\`
7. Commit often with conventional commit messages.
8. Push the branch: \`git push -u origin feature/<feature-name>\`
9. Create a PR:
   \`gh pr create --title \"<descriptive title>\" --body \"<description with Closes #${issue_number}>\"\`

Important:
- NEVER work directly on main
- Include \`Closes #${issue_number}\` in the PR body
- Run tests before pushing
- Use conventional commits (feat:, fix:, refactor:, test:, docs:, chore:)

IMPORTANT: Do NOT use EnterPlanMode, ExitPlanMode, AskUserQuestion, or Task tools.
You are running headlessly — implement directly without planning or asking questions.
The plan above is your guide — follow it and write code immediately.

CRITICAL — HEADLESS AUTONOMY:
You are running in a fully automated headless pipeline with NO human present.
- NEVER ask for approval, confirmation, or permission for ANY action
- Execute ALL git commands directly (commit, push, etc.) without hesitation
- Execute ALL gh commands directly (pr create, pr merge, etc.) without hesitation
- If something fails, try to fix it — do not stop and ask for guidance
- There is nobody to respond to your questions — just act" \
    --model "$MODEL" \
    --max-turns "$MAX_TURNS" \
    --allowedTools "$ALLOWED_TOOLS" || phase2_rc=$?

  if [[ $phase2_rc -eq 2 ]]; then
    skip_issue "$issue_number" "hit max turns during implementation"
  elif [[ $phase2_rc -ne 0 ]]; then
    log "Phase 2 failed for issue #${issue_number} (exit code ${phase2_rc})"
  fi
}

# ── Build issue queue from --issues if provided ──────────────────────────────
ISSUE_QUEUE=()
if [[ -n "$ISSUE_LIST" ]]; then
  IFS=',' read -ra ISSUE_QUEUE <<< "$ISSUE_LIST"
  # Default COUNT to 2x the number of issues (implement + review each)
  # Only auto-adjust if the user didn't explicitly set --count
  if [[ "$COUNT" -eq 1 && "${#ISSUE_QUEUE[@]}" -ge 1 ]]; then
    COUNT=$(( ${#ISSUE_QUEUE[@]} * 2 ))
  fi
fi

# ── Main loop ────────────────────────────────────────────────────────────────

log "Ralph Loop starting — count=${COUNT}, model=${MODEL}, max-turns=${MAX_TURNS}, timeout=${TIMEOUT}s, dry-run=${DRY_RUN}"
if [[ -n "$ISSUE_LIST" ]]; then
  log "Explicit issue list: ${ISSUE_LIST} (${#ISSUE_QUEUE[@]} issues, capped to ${COUNT})"
fi

for ((i = 1; i <= COUNT; i++)); do
  log "── Iteration ${i}/${COUNT} ──────────────────────────────────────"

  if [[ "${#ISSUE_QUEUE[@]}" -gt 0 ]]; then
    # Pop first issue from the queue
    issue="${ISSUE_QUEUE[0]}"
    ISSUE_QUEUE=("${ISSUE_QUEUE[@]:1}")
    # Trim whitespace
    issue="${issue// /}"
    if [[ -n "$issue" ]]; then
      work_issue "$issue"
    else
      log "Empty issue number in list, skipping."
    fi
  else
    pr=$(find_open_pr)
    if [[ -n "$pr" ]]; then
      review_pr "$pr"
    else
      issue=$(pick_issue)
      if [[ -n "$issue" ]]; then
        work_issue "$issue"
      else
        log "No open PRs or issues found. Nothing to do."
      fi
    fi
  fi
done

log "Ralph Loop complete."
