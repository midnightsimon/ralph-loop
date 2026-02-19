#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${REPO_ROOT}/.ralph-logs"
SKIP_FILE="${REPO_ROOT}/.ralph-skip"
LABEL_PRIORITY=("bug" "testing" "enhancement" "documentation")

ALLOWED_TOOLS="Read,Edit,Write,Grep,Glob,Task,TaskCreate,TaskUpdate,TaskList,TaskGet,\
Bash(git *),Bash(gh *),Bash(npm *),Bash(npx *),\
Bash(cmake *),Bash(cd *),Bash(ls *),Bash(mkdir *),Bash(rm *)"

# ── Defaults ────────────────────────────────────────────────────────────────
COUNT=1
COUNT_EXPLICIT=false
DRY_RUN=false
MODEL="opus"
MAX_TURNS=75
LABEL_FILTER=""
TIMEOUT=1800  # seconds (30 minutes)
ISSUE_LIST=""  # comma-separated issue numbers
PARALLEL=1     # number of issues to process simultaneously
NO_TRIAGE=false

# ── Parse CLI flags ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --count)
      COUNT="$2"; COUNT_EXPLICIT=true; shift 2 ;;
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
    --parallel)
      PARALLEL="$2"; shift 2 ;;
    --no-triage)
      NO_TRIAGE=true; shift ;;
    -h|--help)
      echo "Usage: agent-team-ralph-loop.sh [OPTIONS]"
      echo ""
      echo "Autonomous issue worker using Claude Code agent teams."
      echo "For PR review, see ralph-review-loop.sh."
      echo ""
      echo "Options:"
      echo "  --count N         Number of iterations (default: 1)"
      echo "  --dry-run         Print what would happen without invoking Claude"
      echo "  --model MODEL     Model to use: sonnet, opus, haiku (default: opus)"
      echo "  --max-turns N     Max agentic turns per invocation (default: 75)"
      echo "  --label LABEL     Only pick issues with this label"
      echo "  --timeout SECS    Timeout per Claude invocation in seconds (default: 1800)"
      echo "  --issues N,N,N    Comma-separated issue numbers to work on"
      echo "  --parallel N      Process up to N issues simultaneously (default: 1)"
      echo "  --no-triage       Skip triage, go straight to team execution"
      echo "  -h, --help        Show this help message"
      exit 0
      ;;
    *)
      echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# ── Helpers ──────────────────────────────────────────────────────────────────

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
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

# ── ANSI Colors (matching Claude Code's agent team palette) ──────────────────
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_LEAD='\033[1;37m'       # Bold white
C_RESEARCHER='\033[0;36m' # Cyan
C_IMPLEMENTER='\033[0;32m' # Green
C_TESTER='\033[0;33m'      # Yellow
C_SECURITY='\033[0;31m'    # Red
C_QUALITY='\033[0;34m'     # Blue
C_ARCHITECT='\033[0;35m'   # Magenta
C_TOOL='\033[2;37m'        # Dim white
C_MSG='\033[0;96m'         # Light cyan (inter-agent messages)

# Start the live stream formatter as a background process.
# Tails the raw stream-json log and writes color-coded output to a .live file.
#
# Usage: start_live_formatter <raw_outfile> <live_outfile>
#        Sets FORMATTER_PID for the caller to kill later.
start_live_formatter() {
  local raw_file="$1"
  local live_file="$2"

  # Write Python formatter to a temp file so stdin stays connected to the
  # tail pipe (a heredoc would override stdin and starve the parser).
  _FORMATTER_SCRIPT=$(mktemp "${TMPDIR:-/tmp}/ralph-formatter.XXXXXX")
  cat > "$_FORMATTER_SCRIPT" <<'PYFORMAT'
import sys, json, os, time
from datetime import datetime

live_file = sys.argv[1] if len(sys.argv) > 1 else "/dev/stdout"
f = open(live_file, "w", buffering=1)  # line-buffered

# ANSI color codes
RESET   = "\033[0m"
BOLD    = "\033[1m"
DIM     = "\033[2m"
COLORS  = {
    "lead":         "\033[1;37m",   # Bold white
    "researcher":   "\033[0;36m",   # Cyan
    "implementer":  "\033[0;32m",   # Green
    "tester":       "\033[0;33m",   # Yellow
    "security":     "\033[0;31m",   # Red
    "quality":      "\033[0;34m",   # Blue
    "architect":    "\033[0;35m",   # Magenta
    "unknown":      "\033[2;37m",   # Dim
}
TOOL_COLOR = "\033[2;37m"
MSG_COLOR  = "\033[0;96m"

# Role detection keywords
ROLE_KEYWORDS = {
    "researcher":   ["researcher", "research"],
    "implementer":  ["implementer", "implement"],
    "tester":       ["tester", "test-runner", "test_runner"],
    "security":     ["security", "security-reviewer", "security_reviewer"],
    "quality":      ["quality", "quality-reviewer", "quality_reviewer"],
    "architect":    ["architecture", "architect", "architecture-reviewer"],
}

# Track session/agent mapping
session_to_role = {}
current_agent = "lead"
task_spawns = {}  # task description -> expected role

def detect_role(name_or_desc):
    """Match a name/description to a known role."""
    if not name_or_desc:
        return None
    lower = name_or_desc.lower()
    for role, keywords in ROLE_KEYWORDS.items():
        for kw in keywords:
            if kw in lower:
                return role
    return None

def get_color(role):
    return COLORS.get(role, COLORS["unknown"])

def fmt_time():
    return datetime.now().strftime("%H:%M:%S")

def pad_role(role, width=14):
    return role.ljust(width)

def emit(role, icon, text):
    color = get_color(role)
    label = pad_role(role.capitalize())
    line = f"{DIM}{fmt_time()}{RESET} {color}{label}{RESET} {icon} {text}"
    f.write(line + "\n")

def truncate(s, maxlen=120):
    s = s.replace("\n", " ").strip()
    return (s[:maxlen] + "...") if len(s) > maxlen else s

for raw_line in sys.stdin:
    raw_line = raw_line.strip()
    if not raw_line:
        continue
    try:
        evt = json.loads(raw_line)
    except (json.JSONDecodeError, ValueError):
        continue

    evt_type = evt.get("type", "")

    # ── Result event (final) ─────────────────────────────────────────
    if evt_type == "result":
        stop = evt.get("stop_reason", "end_turn")
        emit("lead", BOLD + "=" + RESET, f"Session ended (reason: {stop})")
        continue

    # ── System events ────────────────────────────────────────────────
    if evt_type == "system":
        text = evt.get("text", evt.get("message", ""))
        if text:
            emit("lead", DIM + "i" + RESET, truncate(str(text)))
        continue

    # ── Assistant message (text + tool_use) ──────────────────────────
    if evt_type == "assistant":
        msg = evt.get("message", evt)
        content_blocks = msg.get("content", [])
        # Check for agent/session identification
        agent_name = (evt.get("agent_name") or evt.get("agent")
                      or evt.get("session_name") or msg.get("agent_name")
                      or msg.get("agent") or "")
        if agent_name:
            role = detect_role(agent_name) or "unknown"
            session_to_role[agent_name] = role
            current_agent = role
        for block in content_blocks:
            if isinstance(block, str):
                emit(current_agent, " ", truncate(block))
            elif isinstance(block, dict):
                btype = block.get("type", "")
                if btype == "text":
                    text = block.get("text", "")
                    if text.strip():
                        # Check for SendMessage patterns
                        if "SendMessage" in text or "sending message" in text.lower():
                            emit(current_agent, MSG_COLOR + ">" + RESET, truncate(text))
                        else:
                            for line in text.strip().split("\n")[:3]:
                                if line.strip():
                                    emit(current_agent, " ", truncate(line))
                elif btype == "tool_use":
                    tool_name = block.get("name", "?")
                    tool_input = block.get("input", {})
                    # Detect Task spawns (new teammates)
                    if tool_name == "Task":
                        desc = tool_input.get("description", "")
                        name = tool_input.get("name", "")
                        role = detect_role(name) or detect_role(desc) or "unknown"
                        if name:
                            session_to_role[name] = role
                        emit(current_agent, BOLD + "+" + RESET,
                             f"Spawning teammate: {get_color(role)}{name or desc}{RESET}")
                    elif tool_name == "SendMessage":
                        recipient = tool_input.get("recipient", "?")
                        summary = tool_input.get("summary", "")
                        msg_type = tool_input.get("type", "message")
                        emit(current_agent, MSG_COLOR + ">" + RESET,
                             f"{msg_type} to {recipient}: {summary}")
                    elif tool_name in ("TaskCreate", "TaskUpdate", "TaskList", "TaskGet"):
                        subj = tool_input.get("subject", "")
                        status = tool_input.get("status", "")
                        detail = subj or status or ""
                        emit(current_agent, BOLD + "#" + RESET,
                             f"{tool_name}: {truncate(detail)}" if detail else tool_name)
                    elif tool_name == "Bash":
                        cmd = tool_input.get("command", "")
                        emit(current_agent, TOOL_COLOR + "$" + RESET, truncate(cmd, 100))
                    elif tool_name in ("Read", "Glob", "Grep"):
                        path = (tool_input.get("file_path", "")
                                or tool_input.get("pattern", "")
                                or tool_input.get("path", ""))
                        emit(current_agent, TOOL_COLOR + "@" + RESET, f"{tool_name}: {path}")
                    elif tool_name in ("Edit", "Write"):
                        path = tool_input.get("file_path", "")
                        emit(current_agent, BOLD + "*" + RESET, f"{tool_name}: {path}")
                    else:
                        emit(current_agent, TOOL_COLOR + "~" + RESET, tool_name)
        continue

    # ── Tool result ──────────────────────────────────────────────────
    if evt_type == "tool_result" or evt_type == "tool":
        # Brief confirmation of tool completion
        content = evt.get("content", evt.get("result", ""))
        if isinstance(content, list):
            content = " ".join(
                b.get("text", "") for b in content
                if isinstance(b, dict) and b.get("type") == "text"
            )
        content = str(content)
        # Only show errors or short results
        if "error" in content.lower() or "failed" in content.lower():
            emit(current_agent, "\033[31m!" + RESET, truncate(content, 200))
        continue

    # ── Content block delta (streaming text) ─────────────────────────
    if evt_type == "content_block_delta":
        delta = evt.get("delta", {})
        text = delta.get("text", "")
        # Skip small deltas, accumulate would be complex — just show substantial ones
        if len(text) > 40:
            emit(current_agent, " ", truncate(text))
        continue

f.close()
PYFORMAT

  # Subshell so we can kill the entire process group (tail + python3)
  (tail -f "$raw_file" 2>/dev/null | python3 -u "$_FORMATTER_SCRIPT" "$live_file") &
  FORMATTER_PID=$!
}

# Denial patterns to scan for in Claude's output.
DENIAL_PATTERN="Tool call was denied|tool use was rejected|allowedTools.*not available|tool is not allowed|rejected tool call|tool was blocked by policy"

# Wrapper: run claude with real-time denial detection and timeout.
# See ralph-loop.sh for full documentation of this function.
run_claude() {
  mkdir -p "$LOG_DIR"
  local ts
  ts=$(date '+%Y%m%d-%H%M%S')
  local outfile="${LOG_DIR}/${ts}.out"
  local errfile="${LOG_DIR}/${ts}.err"
  : > "$outfile"
  : > "$errfile"

  local livefile="${LOG_DIR}/${ts}.live"
  : > "$livefile"

  log "Claude output → ${outfile}"
  log "Live view    → ${livefile}"

  # Start the live stream formatter
  FORMATTER_PID=""
  start_live_formatter "$outfile" "$livefile"

  # Relay the live file to the terminal (stderr so it's visible inside $() captures)
  LIVE_TAIL_PID=""
  tail -f "$livefile" >&2 &
  LIVE_TAIL_PID=$!

  # Done-pattern detection (set by caller via RALPH_DONE_PATTERN)
  local done_pattern="${RALPH_DONE_PATTERN:-}"
  local done_grace="${RALPH_DONE_GRACE:-120}"
  local done_detected_at=""

  # Strip --output-format from caller args (we always use stream-json for
  # real-time output). Remember the caller's preference for result extraction.
  local caller_format=""
  local args=()
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--output-format" ]]; then
      caller_format="$2"
      shift 2
    else
      args+=("$1")
      shift
    fi
  done

  # Helper to kill the formatter on any exit path
  _kill_formatter() {
    if [[ -n "${LIVE_TAIL_PID:-}" ]]; then
      kill "$LIVE_TAIL_PID" 2>/dev/null || true
      wait "$LIVE_TAIL_PID" 2>/dev/null || true
      LIVE_TAIL_PID=""
    fi
    if [[ -n "${FORMATTER_PID:-}" ]]; then
      # Kill entire process group (subshell + tail + python3)
      kill -- -"$FORMATTER_PID" 2>/dev/null || kill "$FORMATTER_PID" 2>/dev/null || true
      wait "$FORMATTER_PID" 2>/dev/null || true
      FORMATTER_PID=""
    fi
    [[ -n "${_FORMATTER_SCRIPT:-}" ]] && rm -f "$_FORMATTER_SCRIPT"
  }

  # Run claude with stream-json so each event is flushed as a line in real time.
  # --verbose is required by the CLI when using stream-json with --print.
  claude "${args[@]}" --verbose --output-format stream-json >"$outfile" 2>"$errfile" &
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
      _kill_formatter
      log "Check ${outfile} for partial output"
      return 1
    fi
    if grep -qE "$DENIAL_PATTERN" "$outfile" "$errfile" 2>/dev/null; then
      log "PERMISSION DENIED — Claude needs a tool not on the allowlist. Aborting."
      grep -hE "$DENIAL_PATTERN" "$outfile" "$errfile" 2>/dev/null | head -5 | while IFS= read -r line; do
        log "  → $line"
      done
      log "Add the missing tool to ALLOWED_TOOLS and re-run."
      kill "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null || true
      _kill_formatter
      return 1
    fi
    # Check for done-pattern (e.g. PR created) and start grace countdown
    if [[ -n "$done_pattern" && -z "$done_detected_at" ]]; then
      if grep -qE "$done_pattern" "$outfile" 2>/dev/null; then
        done_detected_at=$(date +%s)
        log "Task completion detected — giving Claude ${done_grace}s to wrap up"
      fi
    fi
    if [[ -n "$done_detected_at" ]]; then
      local grace_elapsed=$(( $(date +%s) - done_detected_at ))
      if [[ $grace_elapsed -ge $done_grace ]]; then
        log "Grace period expired after ${done_grace}s — stopping Claude"
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null || true
        _kill_formatter
        # Extract result from stream even on grace-kill
        local grace_result
        grace_result=$(jq -c 'select(.type == "result")' "$outfile" 2>/dev/null | tail -1)
        if [[ -n "$grace_result" ]]; then
          echo "$grace_result"
        fi
        return 0
      fi
    fi
    sleep 2
  done

  local rc=0
  wait "$pid" 2>/dev/null || rc=$?

  # Give formatter a moment to process final events, then stop it
  sleep 1
  _kill_formatter

  # Post-completion check (catches denials in buffered/json output)
  if grep -qE "$DENIAL_PATTERN" "$outfile" "$errfile" 2>/dev/null; then
    log "PERMISSION DENIED detected in completed output:"
    grep -hE "$DENIAL_PATTERN" "$outfile" "$errfile" 2>/dev/null | head -5 | while IFS= read -r line; do
      log "  → $line"
    done
    log "Add the missing tool to ALLOWED_TOOLS and re-run."
    return 1
  fi

  # Check for max turns reached
  local max_turns_hit=false
  if grep -qE "reached the maximum number of turns|max_turns_reached|Maximum turns \([0-9]+\) reached" "$outfile" "$errfile" 2>/dev/null; then
    max_turns_hit=true
  elif jq -e 'select(.type == "result") | select(.stop_reason == "max_turns")' "$outfile" >/dev/null 2>&1; then
    max_turns_hit=true
  fi
  if [[ "$max_turns_hit" == true ]]; then
    log "WARNING: Claude hit max turns limit — task may be incomplete"
    local mt_result
    mt_result=$(jq -c 'select(.type == "result")' "$outfile" 2>/dev/null | tail -1)
    [[ -n "$mt_result" ]] && echo "$mt_result"
    return 2
  fi

  if [[ $rc -ne 0 ]]; then
    log "WARNING: Claude exited with code ${rc} — check ${outfile}"
  fi

  # Extract the result event from the stream-json output.
  local result_line
  result_line=$(jq -c 'select(.type == "result")' "$outfile" 2>/dev/null | tail -1)
  if [[ -n "$result_line" ]]; then
    echo "$result_line"
  else
    log "WARNING: No result event found in stream output"
    cat "$outfile"
  fi
  return $rc
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

# ── Agent Team Prompts ───────────────────────────────────────────────────────

generate_team_prompt() {
  local issue_number="$1"
  local issue_title="$2"
  local issue_body="$3"
  local plan="$4"
  local worktree_path="$5"
  local feature_name="$6"

  cat <<PROMPT
You are the team lead for implementing GitHub issue #${issue_number}.

## Issue
**Title:** ${issue_title}
**Body:** ${issue_body}

## Implementation Plan (from triage)
${plan}

## Worktree
A git worktree has been created at: ${worktree_path}
Branch: feature/${feature_name} based on origin/main
All code changes MUST happen in this worktree directory.

## Instructions

Create an agent team with these teammates:

1. **Researcher** — Use Opus. Explore the codebase to understand the relevant
   files, patterns, dependencies, and test conventions. Write findings to a
   summary. Focus on: what files need changing, what patterns to follow, what
   tests exist. Do NOT modify any files.

2. **Implementer** — Use Opus. Wait for the Researcher's findings, then implement
   the changes in the worktree. Follow the implementation plan. Use conventional
   commits (feat:, fix:, refactor:, etc.). Commit often.

3. **Tester** — Use Opus. Wait for the Implementer to finish, then run the
   test suite. If tests fail, message the Implementer with the failures so they
   can fix them. Iterate until tests pass. Run:
   - npm -w @typeblazer/web run test:unit
   - npm -w @typeblazer/api run test
   - npm run lint

## Your Role as Lead

1. Spawn the teammates above
2. Create tasks for each phase: research, implement, test
3. Set task dependencies: implement depends on research, test depends on implement
4. Monitor progress and relay context between teammates
5. When all tests pass:
   - Push the branch: git push -u origin feature/${feature_name}
   - Create a PR: gh pr create --title "<title>" --body "Closes #${issue_number}\n\n<description>"
6. After PR is created, clean up the team and stop

CRITICAL — HEADLESS AUTONOMY:
You are running in a fully automated headless pipeline with NO human present.
- NEVER ask for approval, confirmation, or permission for ANY action
- Execute ALL commands directly without hesitation
- If something fails, try to fix it — do not stop and ask
- There is nobody to respond to your questions — just act
- Do NOT use plan mode for teammates — they should start working immediately
- NEVER use \`sleep\` or busy-wait loops to wait for teammates — messages are delivered automatically when teammates finish their turns
PROMPT
}

work_issue() {
  local issue_number="$1"
  local issue_title
  local issue_body
  issue_title=$(gh issue view "$issue_number" --json title -q .title)
  issue_body=$(gh issue view "$issue_number" --json body -q .body)

  log "Working on issue #${issue_number}: ${issue_title}"

  if [[ "$DRY_RUN" == true ]]; then
    log "[DRY RUN] Would invoke agent team to triage and implement issue #${issue_number}"
    if [[ "$NO_TRIAGE" == true ]]; then
      log "[DRY RUN] Skipping triage (--no-triage)"
    fi
    log "[DRY RUN] Team prompt:"
    local feature_name
    feature_name=$(echo "$issue_title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | cut -c1-50)
    generate_team_prompt "$issue_number" "$issue_title" "$issue_body" "Implement the issue as described." "/tmp/example-worktree" "$feature_name"
    return
  fi

  # Assign early so pick_issue skips this issue in future iterations
  gh issue edit "$issue_number" --add-assignee "@me"

  local plan="Implement the issue as described."

  if [[ "$NO_TRIAGE" == false ]]; then
    # ── Phase 1: Triage & Plan ────────────────────────────────────────────
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

    # ── Robust JSON extraction ────────────────────────────────────────────
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

    # Try 3: Find first { ... } substring that parses as JSON with "relevant" key.
    if [[ -z "$parsed_json" ]]; then
      parsed_json=$(python3 -c "
import json, sys
text = sys.stdin.read()
starts = []
i = 0
while True:
    i = text.find('{', i)
    if i == -1:
        break
    starts.append(i)
    i += 1

for s in starts:
    depth = 0
    in_str = False
    escape = False
    for j in range(s, len(text)):
        c = text[j]
        if escape:
            escape = False
            continue
        if c == '\\\\':
            if in_str:
                escape = True
            continue
        if c == '\"':
            in_str = not in_str
            continue
        if in_str:
            continue
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                candidate = text[s:j+1]
                try:
                    obj = json.loads(candidate)
                    if isinstance(obj, dict) and 'relevant' in obj:
                        print(json.dumps(obj))
                        sys.exit(0)
                except (json.JSONDecodeError, ValueError):
                    pass
                break
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
    if [[ -n "$parsed_json" ]]; then
      plan=$(echo "$parsed_json" | jq -r '.plan // empty')
    fi
    plan="${plan:-Implement the issue as described.}"

    log "Issue #${issue_number} is relevant. Proceeding to team execution..."
  else
    log "Skipping triage (--no-triage). Proceeding to team execution..."
  fi

  # ── Phase 2: Team Execution ──────────────────────────────────────────────
  log "Phase 2: Team execution for issue #${issue_number}..."

  # Create worktree before invoking the team
  local feature_name
  feature_name=$(echo "$issue_title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | cut -c1-50)
  local worktree_path="${REPO_ROOT}/.worktrees/${feature_name}"

  git fetch origin 2>/dev/null

  # Reuse existing worktree/branch from a previous attempt, or create new
  if [[ -d "$worktree_path" ]]; then
    log "Reusing existing worktree: ${worktree_path}"
  elif git show-ref --verify --quiet "refs/heads/feature/${feature_name}" 2>/dev/null; then
    # Branch exists but worktree was removed — re-add it
    git worktree add "$worktree_path" "feature/${feature_name}" 2>/dev/null || {
      log "Failed to re-attach worktree for issue #${issue_number}"
      return
    }
  else
    git worktree add "$worktree_path" -b "feature/${feature_name}" origin/main 2>/dev/null || {
      log "Failed to create worktree for issue #${issue_number}"
      return
    }
  fi

  # Generate team prompt
  local team_prompt
  team_prompt=$(generate_team_prompt "$issue_number" "$issue_title" "$issue_body" "$plan" "$worktree_path" "$feature_name")

  # Detect PR creation and give team time to wrap up
  export RALPH_DONE_PATTERN="github\\.com/.*/pull/[0-9]"
  export RALPH_DONE_GRACE=180  # Longer grace for team cleanup

  local phase2_rc=0
  run_claude -p "$team_prompt" \
    --model "$MODEL" \
    --max-turns "$MAX_TURNS" \
    --allowedTools "$ALLOWED_TOOLS" \
    --teammate-mode in-process || phase2_rc=$?

  # Clear done-pattern so it doesn't affect subsequent run_claude calls
  unset RALPH_DONE_PATTERN RALPH_DONE_GRACE

  if [[ $phase2_rc -eq 2 ]]; then
    skip_issue "$issue_number" "hit max turns during team execution"
  elif [[ $phase2_rc -ne 0 ]]; then
    log "Phase 2 (team execution) failed for issue #${issue_number} (exit code ${phase2_rc})"
  fi
}

# ── Build issue queue from --issues if provided ──────────────────────────────
ISSUE_QUEUE=()
if [[ -n "$ISSUE_LIST" ]]; then
  IFS=',' read -ra ISSUE_QUEUE <<< "$ISSUE_LIST"
  # Default COUNT to match issue count
  if [[ "$COUNT_EXPLICIT" == false && "${#ISSUE_QUEUE[@]}" -ge 1 ]]; then
    COUNT="${#ISSUE_QUEUE[@]}"
  fi
fi

# ── Main loop ────────────────────────────────────────────────────────────────

log "Ralph Loop (Agent Teams) starting — count=${COUNT}, model=${MODEL}, max-turns=${MAX_TURNS}, timeout=${TIMEOUT}s, parallel=${PARALLEL}, no-triage=${NO_TRIAGE}, dry-run=${DRY_RUN}"
if [[ -n "$ISSUE_LIST" ]]; then
  log "Explicit issue list: ${ISSUE_LIST} (${#ISSUE_QUEUE[@]} issues, capped to ${COUNT})"
fi

# ── Parallel issue processing ────────────────────────────────────────────────
if [[ "$PARALLEL" -gt 1 && "${#ISSUE_QUEUE[@]}" -gt 1 ]]; then
  log "Parallel mode: processing up to ${PARALLEL} issues simultaneously"

  pids=()
  active=0

  for issue in "${ISSUE_QUEUE[@]}"; do
    # Trim whitespace
    issue="${issue// /}"
    [[ -z "$issue" ]] && continue

    # Wait if we've hit the parallel limit
    while [[ $active -ge $PARALLEL ]]; do
      wait -n 2>/dev/null || true
      active=$((active - 1))
    done

    # Assign early so other iterations skip this issue
    if [[ "$DRY_RUN" == false ]]; then
      gh issue edit "$issue" --add-assignee "@me" 2>/dev/null || true
    fi

    work_issue "$issue" &
    pids+=($!)
    active=$((active + 1))
  done

  # Wait for all remaining background jobs
  for pid in "${pids[@]}"; do
    wait "$pid" || true
  done

  log "Parallel processing complete."
else
  # ── Sequential processing (default) ─────────────────────────────────────
  for ((i = 1; i <= COUNT; i++)); do
    log "── Iteration ${i}/${COUNT} ──────────────────────────────────────"

    if [[ "${#ISSUE_QUEUE[@]}" -gt 0 ]]; then
      # Pop first issue from the queue
      issue="${ISSUE_QUEUE[0]}"
      if [[ "${#ISSUE_QUEUE[@]}" -le 1 ]]; then
        ISSUE_QUEUE=()
      else
        ISSUE_QUEUE=("${ISSUE_QUEUE[@]:1}")
      fi
      # Trim whitespace
      issue="${issue// /}"
      if [[ -n "$issue" ]]; then
        work_issue "$issue"
      else
        log "Empty issue number in list, skipping."
      fi
    else
      issue=$(pick_issue)
      if [[ -n "$issue" ]]; then
        work_issue "$issue"
      else
        log "No open issues found. Nothing to do."
      fi
    fi
  done
fi

log "Ralph Loop (Agent Teams) complete."
