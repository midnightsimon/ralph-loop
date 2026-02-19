#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${REPO_ROOT}/.ralph-logs"
REVIEWED_FILE="${REPO_ROOT}/.ralph-reviewed-prs"

ALLOWED_TOOLS="Read,Edit,Write,Grep,Glob,Task,TaskCreate,TaskUpdate,TaskList,TaskGet,\
Bash(git *),Bash(gh *),Bash(npm *),Bash(npx *),\
Bash(cmake *),Bash(cd *),Bash(ls *),Bash(mkdir *),Bash(rm *)"

# ── Defaults ────────────────────────────────────────────────────────────────
COUNT=1
COUNT_EXPLICIT=false
DRY_RUN=false
MODEL="opus"
MAX_TURNS=75
TIMEOUT=1800  # seconds (30 minutes)
PR_LIST=""    # comma-separated PR numbers
TEAM_REVIEW=false
WATCH=false
POLL_INTERVAL=60  # seconds between polls in watch mode
AGENTS_DIR=""     # directory containing custom agent .md files
AGENT_NAMES=()
AGENT_MODELS=()
AGENT_COLORS=()
AGENT_INSTRUCTIONS=()

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
    --timeout)
      TIMEOUT="$2"; shift 2 ;;
    --prs)
      PR_LIST="$2"; shift 2 ;;
    --team-review)
      TEAM_REVIEW=true; shift ;;
    --watch)
      WATCH=true; shift ;;
    --agents-dir)
      AGENTS_DIR="$2"; shift 2 ;;
    --poll-interval)
      POLL_INTERVAL="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: ralph-review-loop.sh [OPTIONS]"
      echo ""
      echo "Autonomous PR reviewer. Reviews and merges open pull requests."
      echo "For issue implementation, see agent-team-ralph-loop.sh."
      echo ""
      echo "Options:"
      echo "  --count N            Number of PRs to review (default: 1, ignored in --watch)"
      echo "  --dry-run            Print what would happen without invoking Claude"
      echo "  --model MODEL        Model to use: sonnet, opus, haiku (default: opus)"
      echo "  --max-turns N        Max agentic turns per invocation (default: 75)"
      echo "  --timeout SECS       Timeout per Claude invocation in seconds (default: 1800)"
      echo "  --prs N,N,N          Comma-separated PR numbers to review"
      echo "  --team-review        Use agent team for multi-perspective review"
      echo "  --watch              Run continuously, polling for new PRs"
      echo "  --poll-interval SECS Seconds between polls in watch mode (default: 60)"
      echo "  --agents-dir PATH    Directory of agent .md files to use as reviewers"
      echo "  -h, --help           Show this help message"
      echo ""
      echo "Examples:"
      echo "  ralph-review-loop.sh --watch                 # watch forever, solo review"
      echo "  ralph-review-loop.sh --watch --team-review   # watch with agent team reviews"
      echo "  ralph-review-loop.sh --watch --poll-interval 120  # check every 2 minutes"
      echo "  ralph-review-loop.sh --prs 5,6,7             # review specific PRs and exit"
      echo "  ralph-review-loop.sh --team-review --agents-dir ./agents  # custom agent reviewers"
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

# Track which PRs have already been reviewed (persists across restarts)
is_reviewed() {
  local pr_number="$1"
  [[ -f "$REVIEWED_FILE" ]] && grep -q "^${pr_number}$" "$REVIEWED_FILE"
}

mark_reviewed() {
  local pr_number="$1"
  if ! is_reviewed "$pr_number"; then
    echo "$pr_number" >> "$REVIEWED_FILE"
  fi
}

# Graceful shutdown on SIGINT/SIGTERM
SHUTDOWN_REQUESTED=false
_shutdown() {
  log "Shutdown requested — finishing current review then exiting..."
  SHUTDOWN_REQUESTED=true
}
trap _shutdown SIGINT SIGTERM

# ── Custom Agent Loader ──────────────────────────────────────────────────────

load_custom_agents() {
  local dir="$1"
  AGENT_NAMES=()
  AGENT_MODELS=()
  AGENT_COLORS=()
  AGENT_INSTRUCTIONS=()

  if [[ ! -d "$dir" ]]; then
    log "ERROR: agents directory not found: ${dir}"
    return 1
  fi

  local count=0
  for md_file in "$dir"/*.md; do
    [[ -f "$md_file" ]] || continue

    # Parse YAML frontmatter (between first two --- lines)
    local name="" model="" color=""
    local in_frontmatter=false
    local frontmatter_done=false
    local instructions=""
    local line_num=0

    while IFS= read -r line || [[ -n "$line" ]]; do
      line_num=$((line_num + 1))
      if [[ "$line" == "---" ]]; then
        if [[ "$in_frontmatter" == true ]]; then
          frontmatter_done=true
          continue
        elif [[ $line_num -eq 1 ]]; then
          in_frontmatter=true
          continue
        fi
      fi

      if [[ "$in_frontmatter" == true && "$frontmatter_done" == false ]]; then
        # Parse frontmatter fields (handles quoted and unquoted values)
        local val=""
        case "$line" in
          name:*)
            val="${line#name:}"; val="${val# }"; val="${val%\"}"; val="${val#\"}"
            name="$val" ;;
          model:*)
            val="${line#model:}"; val="${val# }"; val="${val%\"}"; val="${val#\"}"
            model="$val" ;;
          color:*)
            val="${line#color:}"; val="${val# }"; val="${val%\"}"; val="${val#\"}"
            color="$val" ;;
        esac
      elif [[ "$frontmatter_done" == true ]]; then
        instructions+="${line}"$'\n'
      fi
    done < "$md_file"

    # Use filename as fallback name
    if [[ -z "$name" ]]; then
      name=$(basename "$md_file" .md)
    fi
    [[ -z "$model" ]] && model="opus"
    [[ -z "$color" ]] && color="cyan"

    AGENT_NAMES+=("$name")
    AGENT_MODELS+=("$model")
    AGENT_COLORS+=("$color")
    AGENT_INSTRUCTIONS+=("$instructions")
    count=$((count + 1))
    log "Loaded agent: ${name} (model=${model}, color=${color})"
  done

  if [[ $count -eq 0 ]]; then
    log "WARNING: No .md files found in ${dir}"
    return 1
  fi
  log "Loaded ${count} custom agent(s) from ${dir}"
}

# ── ANSI Colors (matching Claude Code's agent team palette) ──────────────────
C_RESET='\033[0m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_LEAD='\033[1;37m'       # Bold white
C_SECURITY='\033[0;31m'    # Red
C_QUALITY='\033[0;34m'     # Blue
C_ARCHITECT='\033[0;35m'   # Magenta
C_TOOL='\033[2;37m'        # Dim white
C_MSG='\033[0;96m'         # Light cyan (inter-agent messages)

# Start the live stream formatter as a background process.
# Tails the raw stream-json log and writes color-coded output to a .live file.
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
f = open(live_file, "w", buffering=1)

RESET   = "\033[0m"
BOLD    = "\033[1m"
DIM     = "\033[2m"
COLORS  = {
    "lead":         "\033[1;37m",
    "security":     "\033[0;31m",
    "quality":      "\033[0;34m",
    "architect":    "\033[0;35m",
    "reviewer":     "\033[0;36m",
    "unknown":      "\033[2;37m",
}
TOOL_COLOR = "\033[2;37m"
MSG_COLOR  = "\033[0;96m"

ROLE_KEYWORDS = {
    "security":     ["security", "security-reviewer", "security_reviewer"],
    "quality":      ["quality", "quality-reviewer", "quality_reviewer"],
    "architect":    ["architecture", "architect", "architecture-reviewer"],
    "reviewer":     ["reviewer", "review"],
}

# Load custom agent names/colors from environment
_custom = os.environ.get("CUSTOM_AGENT_NAMES", "")
if _custom:
    _ansi_map = {
        "yellow":  "\033[0;33m", "pink":    "\033[0;35m",
        "red":     "\033[0;31m", "blue":    "\033[0;34m",
        "green":   "\033[0;32m", "cyan":    "\033[0;36m",
        "magenta": "\033[0;35m", "white":   "\033[1;37m",
        "orange":  "\033[0;33m",
    }
    for _entry in _custom.split(","):
        if ":" in _entry:
            _aname, _acolor = _entry.split(":", 1)
            _aname = _aname.strip()
            _key = _aname.lower().replace("-", "_")
            COLORS[_key] = _ansi_map.get(_acolor.strip(), COLORS["unknown"])
            ROLE_KEYWORDS[_key] = [_aname.lower(), _key, _aname.lower().replace("-", " ")]

session_to_role = {}
current_agent = "lead"

def detect_role(name_or_desc):
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

    if evt_type == "result":
        stop = evt.get("stop_reason", "end_turn")
        emit("lead", BOLD + "=" + RESET, f"Session ended (reason: {stop})")
        continue

    if evt_type == "system":
        text = evt.get("text", evt.get("message", ""))
        if text:
            emit("lead", DIM + "i" + RESET, truncate(str(text)))
        continue

    if evt_type == "assistant":
        msg = evt.get("message", evt)
        content_blocks = msg.get("content", [])
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
                        if "SendMessage" in text or "sending message" in text.lower():
                            emit(current_agent, MSG_COLOR + ">" + RESET, truncate(text))
                        else:
                            for line in text.strip().split("\n")[:3]:
                                if line.strip():
                                    emit(current_agent, " ", truncate(line))
                elif btype == "tool_use":
                    tool_name = block.get("name", "?")
                    tool_input = block.get("input", {})
                    if tool_name == "Task":
                        desc = tool_input.get("description", "")
                        name = tool_input.get("name", "")
                        role = detect_role(name) or detect_role(desc) or "unknown"
                        if name:
                            session_to_role[name] = role
                        emit(current_agent, BOLD + "+" + RESET,
                             f"Spawning reviewer: {get_color(role)}{name or desc}{RESET}")
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

    if evt_type == "tool_result" or evt_type == "tool":
        content = evt.get("content", evt.get("result", ""))
        if isinstance(content, list):
            content = " ".join(
                b.get("text", "") for b in content
                if isinstance(b, dict) and b.get("type") == "text"
            )
        content = str(content)
        if "error" in content.lower() or "failed" in content.lower():
            emit(current_agent, "\033[31m!" + RESET, truncate(content, 200))
        continue

    if evt_type == "content_block_delta":
        delta = evt.get("delta", {})
        text = delta.get("text", "")
        if len(text) > 40:
            emit(current_agent, " ", truncate(text))
        continue

f.close()
PYFORMAT

  tail -f "$raw_file" 2>/dev/null | python3 -u "$_FORMATTER_SCRIPT" "$live_file" &
  FORMATTER_PID=$!
}

# Denial patterns to scan for in Claude's output.
DENIAL_PATTERN="Tool call was denied|tool use was rejected|allowedTools.*not available|tool is not allowed|rejected tool call|tool was blocked by policy"

# Wrapper: run claude with real-time denial detection and timeout.
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
  log "Live view    → ${livefile}  (tail -f ${livefile})"

  # Start the live stream formatter
  FORMATTER_PID=""
  start_live_formatter "$outfile" "$livefile"

  # Done-pattern detection (set by caller via RALPH_DONE_PATTERN)
  local done_pattern="${RALPH_DONE_PATTERN:-}"
  local done_grace="${RALPH_DONE_GRACE:-120}"
  local done_detected_at=""

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

  _kill_formatter() {
    if [[ -n "${FORMATTER_PID:-}" ]]; then
      kill "$FORMATTER_PID" 2>/dev/null
      wait "$FORMATTER_PID" 2>/dev/null || true
      FORMATTER_PID=""
    fi
    [[ -n "${_FORMATTER_SCRIPT:-}" ]] && rm -f "$_FORMATTER_SCRIPT"
  }

  claude "${args[@]}" --verbose --output-format stream-json >"$outfile" 2>"$errfile" &
  local pid=$!
  local start_time
  start_time=$(date +%s)

  while kill -0 "$pid" 2>/dev/null; do
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

  sleep 1
  _kill_formatter

  if grep -qE "$DENIAL_PATTERN" "$outfile" "$errfile" 2>/dev/null; then
    log "PERMISSION DENIED detected in completed output:"
    grep -hE "$DENIAL_PATTERN" "$outfile" "$errfile" 2>/dev/null | head -5 | while IFS= read -r line; do
      log "  → $line"
    done
    log "Add the missing tool to ALLOWED_TOOLS and re-run."
    return 1
  fi

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

# ── Find open PRs ───────────────────────────────────────────────────────────

find_open_prs() {
  local limit="${1:-5}"
  gh pr list --state open --limit "$limit" --json number -q '.[].number'
}

# ── Review Prompts ───────────────────────────────────────────────────────────

generate_review_team_prompt() {
  local pr_number="$1"

  if [[ ${#AGENT_NAMES[@]} -gt 0 ]]; then
    # ── Dynamic prompt with custom agents ───────────────────────────────
    echo "You are the team lead for reviewing PR #${pr_number}."
    echo ""
    echo "## Teammates to Spawn"
    echo ""

    local i
    for ((i = 0; i < ${#AGENT_NAMES[@]}; i++)); do
      local cap_model="${AGENT_MODELS[$i]}"
      cap_model="$(echo "${cap_model:0:1}" | tr '[:lower:]' '[:upper:]')${cap_model:1}"
      echo "### $((i + 1)). ${AGENT_NAMES[$i]} (${cap_model})"
      echo ""
      echo "<agent-instructions>"
      echo "${AGENT_INSTRUCTIONS[$i]}"
      echo "</agent-instructions>"
      echo ""
    done

    cat <<PROMPT
## Your Role as Lead

1. Spawn each teammate above using their exact name and instructions
2. Have each reviewer examine the PR independently using:
   - gh pr view ${pr_number}
   - gh pr diff ${pr_number}
   - Reading relevant source files for context
3. Collect their findings
4. Synthesize a decision:
   - If fixable issues found: checkout the PR branch, fix, commit, push, then approve and merge
   - If the PR is good: approve and merge with gh pr merge --squash --delete-branch
   - If fundamentally broken: close with explanation

CRITICAL — HEADLESS AUTONOMY:
You are running in a fully automated headless pipeline with NO human present.
- NEVER ask for approval, confirmation, or permission for ANY action
- Execute ALL git and gh commands directly (commit, push, merge, close, etc.) without hesitation
- If something fails, try to fix it — do not stop and ask for guidance
- There is nobody to respond to your questions — just act
- Do NOT use plan mode for teammates — they should start working immediately
- NEVER use \`sleep\` or busy-wait loops to wait for teammates — messages are delivered automatically when teammates finish their turns
PROMPT
  else
    # ── Default hardcoded reviewers ─────────────────────────────────────
    cat <<PROMPT
You are the team lead for reviewing PR #${pr_number}.

## Instructions

Create an agent team to review this PR. Spawn three reviewers:

1. **Security Reviewer** (Opus) — Focus on security implications, input
   validation, injection risks, authentication/authorization issues, and
   sensitive data handling.

2. **Quality Reviewer** (Opus) — Check code quality, test coverage,
   convention adherence, error handling, and edge cases.

3. **Architecture Reviewer** (Opus) — Evaluate design decisions, performance
   implications, maintainability, and consistency with the existing codebase.

## Your Role as Lead

1. Spawn the three reviewers above
2. Have each reviewer examine the PR independently using:
   - gh pr view ${pr_number}
   - gh pr diff ${pr_number}
   - Reading relevant source files for context
3. Collect their findings
4. Synthesize a decision:
   - If fixable issues found: checkout the PR branch, fix, commit, push, then approve and merge
   - If the PR is good: approve and merge with gh pr merge --squash --delete-branch
   - If fundamentally broken: close with explanation

CRITICAL — HEADLESS AUTONOMY:
You are running in a fully automated headless pipeline with NO human present.
- NEVER ask for approval, confirmation, or permission for ANY action
- Execute ALL git and gh commands directly (commit, push, merge, close, etc.) without hesitation
- If something fails, try to fix it — do not stop and ask for guidance
- There is nobody to respond to your questions — just act
- Do NOT use plan mode for teammates — they should start working immediately
- NEVER use \`sleep\` or busy-wait loops to wait for teammates — messages are delivered automatically when teammates finish their turns
PROMPT
  fi
}

# ── Core Function ────────────────────────────────────────────────────────────

review_pr() {
  local pr_number="$1"
  local pr_title
  pr_title=$(gh pr view "$pr_number" --json title -q .title)

  log "Reviewing PR #${pr_number}: ${pr_title}"

  if [[ "$DRY_RUN" == true ]]; then
    if [[ "$TEAM_REVIEW" == true ]]; then
      log "[DRY RUN] Would invoke agent team to review PR #${pr_number}"
      log "[DRY RUN] Team prompt:"
      generate_review_team_prompt "$pr_number"
    else
      log "[DRY RUN] Would invoke Claude to review PR #${pr_number}"
    fi
    return
  fi

  local review_rc=0

  if [[ "$TEAM_REVIEW" == true ]]; then
    # ── Team-based review ──────────────────────────────────────────────
    log "Using agent team for PR review..."

    local review_prompt
    review_prompt=$(generate_review_team_prompt "$pr_number")

    # Detect review completion (merge, close, or approve) and give grace to wrap up
    export RALPH_DONE_PATTERN="gh pr merge|gh pr close|Approved by|--approve|successfully merged|pull request.*closed"
    export RALPH_DONE_GRACE=120

    run_claude -p "$review_prompt" \
      --model "$MODEL" \
      --max-turns "$MAX_TURNS" \
      --allowedTools "$ALLOWED_TOOLS" \
      --teammate-mode in-process || review_rc=$?

    unset RALPH_DONE_PATTERN RALPH_DONE_GRACE
  else
    # ── Solo review ────────────────────────────────────────────────────
    export RALPH_DONE_PATTERN="gh pr merge|gh pr close|Approved by|--approve|successfully merged|pull request.*closed"
    export RALPH_DONE_GRACE=90

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
- There is nobody to respond to your questions — just act
- Do NOT use plan mode for teammates — they should start working immediately
- NEVER use \`sleep\` or busy-wait loops to wait for teammates — messages are delivered automatically when teammates finish their turns" \
      --model "$MODEL" \
      --max-turns "$MAX_TURNS" \
      --allowedTools "$ALLOWED_TOOLS" || review_rc=$?

    unset RALPH_DONE_PATTERN RALPH_DONE_GRACE
  fi

  # Clean up worktree and branch if PR was merged
  local pr_state
  pr_state=$(gh pr view "$pr_number" --json state -q .state 2>/dev/null || echo "")
  if [[ "$pr_state" == "MERGED" ]]; then
    local pr_branch
    pr_branch=$(gh pr view "$pr_number" --json headRefName -q .headRefName 2>/dev/null || echo "")
    if [[ -n "$pr_branch" ]]; then
      local worktree_path=""
      worktree_path=$(git worktree list --porcelain 2>/dev/null | awk -v branch="branch refs/heads/${pr_branch}" '
        /^worktree / { wt = substr($0, 10) }
        $0 == branch { print wt; exit }
        /^$/ { wt = "" }
      ' || echo "")
      if [[ -n "$worktree_path" ]]; then
        log "Cleaning up worktree: ${worktree_path}"
        git worktree remove "$worktree_path" --force 2>/dev/null || true
        if [[ -d "$worktree_path" ]]; then
          log "Removing lingering worktree directory: ${worktree_path}"
          rm -rf "$worktree_path"
        fi
      fi
      local wt_dir="${REPO_ROOT}/.worktrees/${pr_branch##*/}"
      if [[ -d "$wt_dir" ]]; then
        log "Removing worktree directory: ${wt_dir}"
        git worktree remove "$wt_dir" --force 2>/dev/null || true
        rm -rf "$wt_dir"
      fi
      git branch -D "$pr_branch" 2>/dev/null || true
      log "Cleaned up branch: ${pr_branch}"
    fi
    git worktree prune 2>/dev/null || true
    git pull origin main 2>/dev/null || true
  fi
}

# ── Load custom agents (explicit flag or auto-discover from $PWD) ─────────────
if [[ -z "$AGENTS_DIR" && -d "${PWD}/.claude/agents" ]]; then
  AGENTS_DIR="${PWD}/.claude/agents"
  log "Auto-discovered agents directory: ${AGENTS_DIR}"
fi
if [[ -n "$AGENTS_DIR" ]]; then
  load_custom_agents "$AGENTS_DIR"
  # Export agent names/colors for the live formatter subprocess
  if [[ ${#AGENT_NAMES[@]} -gt 0 ]]; then
    _agent_env=""
    for ((_i = 0; _i < ${#AGENT_NAMES[@]}; _i++)); do
      [[ -n "$_agent_env" ]] && _agent_env+=","
      _agent_env+="${AGENT_NAMES[$_i]}:${AGENT_COLORS[$_i]}"
    done
    export CUSTOM_AGENT_NAMES="$_agent_env"
  fi
fi

# ── Build PR queue from --prs if provided ────────────────────────────────────
PR_QUEUE=()
if [[ -n "$PR_LIST" ]]; then
  IFS=',' read -ra PR_QUEUE <<< "$PR_LIST"
  if [[ "$COUNT_EXPLICIT" == false && "${#PR_QUEUE[@]}" -ge 1 ]]; then
    COUNT="${#PR_QUEUE[@]}"
  fi
fi

# ── Main loop ────────────────────────────────────────────────────────────────

if [[ "$WATCH" == true ]]; then
  # ── Watch mode: long-running daemon ──────────────────────────────────────
  log "Ralph Review Loop starting in WATCH mode — poll=${POLL_INTERVAL}s, model=${MODEL}, max-turns=${MAX_TURNS}, timeout=${TIMEOUT}s, team-review=${TEAM_REVIEW}, agents-dir=${AGENTS_DIR:-none}, dry-run=${DRY_RUN}"
  log "Tracking reviewed PRs in: ${REVIEWED_FILE}"
  log "Press Ctrl+C to stop gracefully."

  reviews_done=0

  while [[ "$SHUTDOWN_REQUESTED" == false ]]; do
    # Find all open PRs
    open_prs=$(find_open_prs 20 2>/dev/null || true)

    if [[ -z "$open_prs" ]]; then
      log "No open PRs. Sleeping ${POLL_INTERVAL}s..."
    else
      found_new=false
      for pr in $open_prs; do
        [[ "$SHUTDOWN_REQUESTED" == true ]] && break

        if is_reviewed "$pr"; then
          continue
        fi

        found_new=true
        reviews_done=$((reviews_done + 1))
        log "── Review #${reviews_done} (PR #${pr}) ──────────────────────────────────────"
        review_pr "$pr"
        mark_reviewed "$pr"
      done

      if [[ "$found_new" == false ]]; then
        log "All open PRs already reviewed. Sleeping ${POLL_INTERVAL}s..."
      fi
    fi

    # Sleep in small increments so we can respond to shutdown quickly
    if [[ "$SHUTDOWN_REQUESTED" == false ]]; then
      elapsed=0
      while [[ $elapsed -lt $POLL_INTERVAL && "$SHUTDOWN_REQUESTED" == false ]]; do
        sleep 5
        elapsed=$((elapsed + 5))
      done
    fi
  done

  log "Ralph Review Loop stopped after ${reviews_done} reviews."

else
  # ── One-shot mode: review specific PRs or N from queue ───────────────────
  log "Ralph Review Loop starting — count=${COUNT}, model=${MODEL}, max-turns=${MAX_TURNS}, timeout=${TIMEOUT}s, team-review=${TEAM_REVIEW}, agents-dir=${AGENTS_DIR:-none}, dry-run=${DRY_RUN}"
  if [[ -n "$PR_LIST" ]]; then
    log "Explicit PR list: ${PR_LIST} (${#PR_QUEUE[@]} PRs)"
  fi

  for ((i = 1; i <= COUNT; i++)); do
    log "── Review ${i}/${COUNT} ──────────────────────────────────────"

    if [[ "${#PR_QUEUE[@]}" -gt 0 ]]; then
      # Pop first PR from the queue
      pr="${PR_QUEUE[0]}"
      if [[ "${#PR_QUEUE[@]}" -le 1 ]]; then
        PR_QUEUE=()
      else
        PR_QUEUE=("${PR_QUEUE[@]:1}")
      fi
      pr="${pr// /}"
      if [[ -n "$pr" ]]; then
        review_pr "$pr"
      else
        log "Empty PR number in list, skipping."
      fi
    else
      # Find oldest open PR
      pr=$(find_open_prs 1 | head -1)
      if [[ -n "$pr" ]]; then
        review_pr "$pr"
      else
        log "No open PRs found. Nothing to review."
      fi
    fi
  done

  log "Ralph Review Loop complete."
fi
