#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(pwd)"
LOG_DIR="${PROJECT_DIR}/.ralph-logs"
REVIEWED_FILE="${PROJECT_DIR}/.ralph-reviewed-prs"

ALLOWED_TOOLS="Read,Edit,Write,Grep,Glob,Task,TaskCreate,TaskUpdate,TaskList,TaskGet,\
Bash(git *),Bash(gh *),Bash(npm *),Bash(npx *),\
Bash(cmake *),Bash(cd *),Bash(ls *),Bash(mkdir *),Bash(rm *),\
Bash(*/ralph-safe-merge.sh *)"

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
WAIT_FOR_REVIEWER="devin-ai-integration[bot]"  # GitHub login to wait for before reviewing
REVIEWER_WAIT_TIMEOUT=600    # max seconds to wait in one-shot mode (10 min)
REVIEWER_POLL_INTERVAL=30    # seconds between API checks in one-shot mode
SKIP_CI_CHECK=false          # set true to bypass CI check gate
CI_CHECK_TIMEOUT=900         # max seconds to wait for CI checks (15 min)
CI_CHECK_POLL_INTERVAL=30    # seconds between CI status polls

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
    --wait-for-reviewer)
      WAIT_FOR_REVIEWER="$2"; shift 2 ;;
    --reviewer-timeout)
      REVIEWER_WAIT_TIMEOUT="$2"; shift 2 ;;
    --reviewer-poll-interval)
      REVIEWER_POLL_INTERVAL="$2"; shift 2 ;;
    --skip-ci-check)
      SKIP_CI_CHECK=true; shift ;;
    --ci-timeout)
      CI_CHECK_TIMEOUT="$2"; shift 2 ;;
    --ci-poll-interval)
      CI_CHECK_POLL_INTERVAL="$2"; shift 2 ;;
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
      echo "  --wait-for-reviewer USER   Wait for USER to review before Ralph reviews"
      echo "  --reviewer-timeout SECS    Max wait for reviewer in one-shot mode (default: 600)"
      echo "  --reviewer-poll-interval S Poll interval when waiting (default: 30)"
      echo "  --skip-ci-check            Bypass CI check gate (merge even if checks fail)"
      echo "  --ci-timeout SECS          Max wait for CI checks to complete (default: 900)"
      echo "  --ci-poll-interval SECS    Poll interval for CI status checks (default: 30)"
      echo "  -h, --help           Show this help message"
      echo ""
      echo "Examples:"
      echo "  ralph-review-loop.sh --watch                 # watch forever, solo review"
      echo "  ralph-review-loop.sh --watch --team-review   # watch with agent team reviews"
      echo "  ralph-review-loop.sh --watch --poll-interval 120  # check every 2 minutes"
      echo "  ralph-review-loop.sh --prs 5,6,7             # review specific PRs and exit"
      echo "  ralph-review-loop.sh --team-review --agents-dir ./agents  # custom agent reviewers"
      echo "  ralph-review-loop.sh --watch --wait-for-reviewer \"devin-ai-integration[bot]\""
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

# ── Retry tracking for PRs that fail CI after review ──────────────────────────
MAX_REVIEW_RETRIES="${MAX_REVIEW_RETRIES:-3}"

get_retry_count() {
  local pr_number="$1"
  local retry_file="${PROJECT_DIR}/.ralph-retry-counts"
  if [[ -f "$retry_file" ]]; then
    local count
    count=$(grep "^${pr_number}:" "$retry_file" 2>/dev/null | tail -1 | cut -d: -f2)
    echo "${count:-0}"
  else
    echo "0"
  fi
}

increment_retry_count() {
  local pr_number="$1"
  local retry_file="${PROJECT_DIR}/.ralph-retry-counts"
  local current
  current=$(get_retry_count "$pr_number")
  local new_count=$((current + 1))
  # Remove old entry and add updated one
  if [[ -f "$retry_file" ]]; then
    grep -v "^${pr_number}:" "$retry_file" > "${retry_file}.tmp" 2>/dev/null || true
    mv "${retry_file}.tmp" "$retry_file"
  fi
  echo "${pr_number}:${new_count}" >> "$retry_file"
  echo "$new_count"
}

clear_retry_count() {
  local pr_number="$1"
  local retry_file="${PROJECT_DIR}/.ralph-retry-counts"
  if [[ -f "$retry_file" ]]; then
    grep -v "^${pr_number}:" "$retry_file" > "${retry_file}.tmp" 2>/dev/null || true
    mv "${retry_file}.tmp" "$retry_file"
  fi
}

# Check if a specific reviewer has submitted a review on a PR
has_reviewer_reviewed() {
  local pr_number="$1" reviewer="$2" repo_nwo="$3"
  # Get the PR's current head SHA
  local head_sha
  head_sha=$(gh api "repos/${repo_nwo}/pulls/${pr_number}" -q '.head.sha' 2>/dev/null || echo "")
  [[ -z "$head_sha" ]] && return 1
  local count
  count=$(gh api "repos/${repo_nwo}/pulls/${pr_number}/reviews" 2>/dev/null \
    | jq --arg user "$reviewer" --arg sha "$head_sha" \
    '[.[] | select(.user.login == $user and .state != "PENDING" and .state != "DISMISSED" and .commit_id == $sha)] | length' 2>/dev/null || echo "0")
  [[ "$count" -gt 0 ]]
}

# Fetch review comments from a specific reviewer
get_reviewer_comments() {
  local pr_number="$1" reviewer="$2" repo_nwo="$3"
  local comments=""

  # Get the reviewer's latest review state (APPROVED, CHANGES_REQUESTED, etc.)
  local review_state
  review_state=$(gh api "repos/${repo_nwo}/pulls/${pr_number}/reviews" 2>/dev/null \
    | jq -r --arg user "$reviewer" \
    '[.[] | select(.user.login == $user and .state != "PENDING" and .state != "DISMISSED")] | last | .state // "UNKNOWN"' \
    2>/dev/null || echo "UNKNOWN")
  comments+="### Verdict: ${review_state}\n\n"

  # Get review-level summaries
  local review_bodies
  review_bodies=$(gh api "repos/${repo_nwo}/pulls/${pr_number}/reviews" 2>/dev/null \
    | jq -r --arg user "$reviewer" \
    '[.[] | select(.user.login == $user) | .body | select(. != null and . != "")] | join("\n\n")' \
    2>/dev/null || echo "")

  # Get inline review comments (line-level findings on specific files)
  local inline_comments
  inline_comments=$(gh api "repos/${repo_nwo}/pulls/${pr_number}/comments" 2>/dev/null \
    | jq -r --arg user "$reviewer" \
    '[.[] | select(.user.login == $user) | "File: \(.path), Line: \(.line // .original_line // "N/A")\n\(.body)"] | join("\n\n---\n\n")' \
    2>/dev/null || echo "")

  if [[ -n "$review_bodies" ]]; then
    comments+="### Review Summary\n${review_bodies}\n\n"
  fi
  if [[ -n "$inline_comments" ]]; then
    comments+="### Inline Comments\n${inline_comments}"
  fi
  echo -e "$comments"
}

# Wait for an external reviewer to submit their review (one-shot mode polling)
wait_for_external_reviewer() {
  local pr_number="$1"
  [[ -z "$WAIT_FOR_REVIEWER" ]] && return 0
  local start; start=$(date +%s)
  while true; do
    has_reviewer_reviewed "$pr_number" "$WAIT_FOR_REVIEWER" "$REPO_NWO" && return 0
    local elapsed=$(( $(date +%s) - start ))
    (( elapsed >= REVIEWER_WAIT_TIMEOUT )) && {
      log "WARNING: Timed out waiting for ${WAIT_FOR_REVIEWER} on PR #${pr_number}"
      return 1
    }
    log "PR #${pr_number}: waiting for ${WAIT_FOR_REVIEWER} (${elapsed}/${REVIEWER_WAIT_TIMEOUT}s)..."
    sleep "$REVIEWER_POLL_INTERVAL"
  done
}

# Check CI status for a PR. Returns: 0=passed, 1=failed, 2=pending, 3=no checks
get_ci_status() {
  local pr_number="$1"
  local checks_json
  checks_json=$(gh pr checks "$pr_number" --json state,bucket,name 2>/dev/null || echo "")

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

# Wait for CI checks to pass. Returns 0 on success/no-checks, 1 on failure/timeout.
wait_for_ci_checks() {
  local pr_number="$1"
  [[ "$SKIP_CI_CHECK" == true ]] && return 0
  local start; start=$(date +%s)
  while true; do
    get_ci_status "$pr_number"
    local status=$?
    case $status in
      0) log "PR #${pr_number}: All CI checks passed"; return 0 ;;
      1)
        log "WARNING: PR #${pr_number}: CI checks FAILED"
        gh pr checks "$pr_number" --json name,bucket,state 2>/dev/null \
          | jq -r '.[] | select(.bucket == "fail") | "  FAIL: \(.name) (\(.state))"' \
          | while IFS= read -r line; do log "$line"; done
        return 1 ;;
      3) log "PR #${pr_number}: No CI checks found — proceeding"; return 0 ;;
      2)
        local elapsed=$(( $(date +%s) - start ))
        if (( elapsed >= CI_CHECK_TIMEOUT )); then
          log "WARNING: Timed out waiting for CI checks on PR #${pr_number} after ${CI_CHECK_TIMEOUT}s"
          return 1
        fi
        log "PR #${pr_number}: CI checks still running (${elapsed}/${CI_CHECK_TIMEOUT}s)..."
        sleep "$CI_CHECK_POLL_INTERVAL"
        ;;
    esac
  done
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

  # Close stdout (>/dev/null) so the formatter subshell doesn't hold the $() pipe
  # open when run_claude is called inside plan_output=$(run_claude ...).
  (tail -f "$raw_file" 2>/dev/null | python3 -u "$_FORMATTER_SCRIPT" "$live_file") >/dev/null &
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
  local worktree_path="$2"
  local pr_branch="$3"
  local reviewer_context="${4:-}"

  local worktree_section
  worktree_section=$(cat <<WTSECTION
## Worktree
A git worktree has been created for this PR at: ${worktree_path}
Branch: ${pr_branch}
All code reading and fixes MUST happen in this worktree directory.
Do NOT use \`gh pr checkout\` — the branch is already checked out in the worktree.
If fixes are needed, make changes in the worktree, commit, and push from there.
WTSECTION
)

  if [[ ${#AGENT_NAMES[@]} -gt 0 ]]; then
    # ── Dynamic prompt with custom agents ───────────────────────────────
    echo "You are the team lead for reviewing PR #${pr_number}."
    echo ""
    echo "${worktree_section}"
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

1. Spawn each teammate above using the Task tool with \`run_in_background: true\`
2. Each reviewer should examine the PR independently using:
   - gh pr view ${pr_number}
   - gh pr diff ${pr_number}
   - Reading relevant source files in the worktree (${worktree_path}) for context
3. After spawning ALL teammates, use \`TaskOutput\` with \`block: true\` to wait for each one's result
4. Once you have all results, synthesize a decision:
   - If fixable issues found: make fixes in the worktree (${worktree_path}), commit, push, then wait for CI to re-run and pass (\`gh pr checks ${pr_number} --watch --fail-fast\`), then approve and merge
   - If the PR is good: approve and merge using the safe-merge wrapper (it verifies CI before merging):
     \`gh pr review ${pr_number} --approve\` then \`${SCRIPT_DIR}/ralph-safe-merge.sh ${pr_number} --squash --delete-branch\`
   - Do NOT use \`gh pr merge\` directly — always use ralph-safe-merge.sh
   - If the safe-merge wrapper reports CI failure: read the errors, attempt to fix them in the worktree, commit, push, wait for CI (\`gh pr checks ${pr_number} --watch --fail-fast\`), then retry the merge
   - If you cannot fix the CI errors, leave a comment explaining what failed and stop
   - If fundamentally broken: close with explanation

IMPORTANT — SPAWNING PATTERN (you MUST follow this):
- Spawn each teammate with \`run_in_background: true\` so they run in parallel
- Then call \`TaskOutput\` (with \`block: true\`) for each spawned task to collect their results
- Do NOT use TeamCreate — just use Task directly
- Do NOT end your turn with just a text message — always have an active tool call

CRITICAL — HEADLESS AUTONOMY:
You are running in a fully automated headless pipeline with NO human present.
- NEVER ask for approval, confirmation, or permission for ANY action
- Execute ALL git and gh commands directly (commit, push, merge, close, etc.) without hesitation
- If something fails, try to fix it — do not stop and ask for guidance
- There is nobody to respond to your questions — just act
- Do NOT use plan mode for teammates — they should start working immediately
- NEVER use \`sleep\` or busy-wait loops — use TaskOutput to wait for results
PROMPT
  else
    # ── Default: Cornelius solo code reviewer ─────────────────────────────
    local reviewer_prompt_section=""
    if [[ -n "$reviewer_context" ]]; then
      reviewer_prompt_section="
## External Review Feedback
${WAIT_FOR_REVIEWER} has already reviewed this PR. Their feedback is below.
Consider their comments in your review — address, fix, or acknowledge each point.

${reviewer_context}
"
    fi
    cat <<PROMPT
You are Cornelius, a meticulous and thorough code reviewer. You are reviewing PR #${pr_number}.

${worktree_section}

## Review Process

You work alone — do NOT spawn sub-agents, teams, or teammates. Review this PR yourself.

1. Run \`gh pr view ${pr_number}\` to read the PR description.
2. Run \`gh pr diff ${pr_number}\` to see the full diff.
3. Read changed files in the worktree (\`${worktree_path}/...\`) to understand context.
4. Evaluate the PR thoroughly for:
   - **Correctness**: Logic errors, bugs, edge cases
   - **Security**: Input validation, injection risks, authentication/authorization, sensitive data
   - **Quality**: Test coverage, error handling, code style, convention adherence
   - **Architecture**: Design decisions, performance, maintainability, codebase consistency

## After Review

5. **If changes are needed and you can fix them:**
   - Make the fixes in the worktree directory (${worktree_path})
   - Commit with conventional commit messages:
     \`cd ${worktree_path} && git add . && git commit -m "fix: ..."\`
   - Push: \`cd ${worktree_path} && git push origin ${pr_branch}\`
   - Then approve and merge (step 6)

6. **If the PR is acceptable** (either initially or after your fixes):
   - \`gh pr review ${pr_number} --approve --body "Reviewed and approved by Cornelius."\`
   - Merge using the safe-merge wrapper (it verifies CI passes before merging):
     \`${SCRIPT_DIR}/ralph-safe-merge.sh ${pr_number} --squash --delete-branch\`
   - Do NOT use \`gh pr merge\` directly — always use ralph-safe-merge.sh

7. **If the safe-merge wrapper reports CI failure:**
   - Read the failing check output to understand what failed (e.g. typecheck, lint, tests)
   - Attempt to fix the errors in the worktree: \`cd ${worktree_path} && ...\`
   - Commit and push: \`cd ${worktree_path} && git add . && git commit -m "fix: ..." && git push origin ${pr_branch}\`
   - Wait for CI to re-run: \`gh pr checks ${pr_number} --watch --fail-fast\`
   - Try merging again: \`${SCRIPT_DIR}/ralph-safe-merge.sh ${pr_number} --squash --delete-branch\`
   - If you cannot fix the errors, leave a comment explaining what failed and stop

8. **If the PR is fundamentally broken** (can't be fixed reasonably):
   - \`gh pr close ${pr_number} --comment "Closing: <explanation>"\`

## Cleanup After Merge/Close

After merging or closing the PR, clean up:
- Remove the review worktree: \`git worktree remove ${worktree_path} --force 2>/dev/null || true\`
- Delete the local branch: \`git branch -D ${pr_branch} 2>/dev/null || true\`
- Prune stale worktrees: \`git worktree prune 2>/dev/null || true\`

## Future Issues

If you identify concerns that don't block this PR but should be tracked for
the future (tech debt, missing tests, potential improvements, performance
concerns, etc.), create a GitHub issue for each concern:

First ensure the label exists:
  \`gh label create review-followup --description "Follow-up from PR review" --color "c5def5" 2>/dev/null || true\`

Then create issues:
  \`gh issue create --title "<concise title>" --body "<description with context and PR #${pr_number} reference>" --label "review-followup"\`
${reviewer_prompt_section}
CRITICAL — HEADLESS AUTONOMY:
You are running in a fully automated headless pipeline with NO human present.
- NEVER ask for approval, confirmation, or permission for ANY action
- Execute ALL git and gh commands directly without hesitation
- If something fails, try to fix it — do not stop and ask for guidance
- There is nobody to respond to your questions — just act
- Do NOT spawn sub-agents, use TeamCreate, or use the Task tool to create teammates
- NEVER use \`sleep\` or busy-wait loops
PROMPT
  fi
}

# ── Core Function ────────────────────────────────────────────────────────────

review_pr() {
  local pr_number="$1"
  local pr_title pr_branch
  pr_title=$(gh pr view "$pr_number" --json title -q .title)
  pr_branch=$(gh pr view "$pr_number" --json headRefName -q .headRefName 2>/dev/null || echo "")

  log "Reviewing PR #${pr_number}: ${pr_title} (branch: ${pr_branch})"

  # Fetch external reviewer's comments if configured
  local reviewer_context=""
  if [[ -n "$WAIT_FOR_REVIEWER" ]]; then
    reviewer_context=$(get_reviewer_comments "$pr_number" "$WAIT_FOR_REVIEWER" "$REPO_NWO")
    if [[ -n "$reviewer_context" ]]; then
      log "Fetched review comments from ${WAIT_FOR_REVIEWER} for PR #${pr_number}"
    fi
  fi

  if [[ "$DRY_RUN" == true ]]; then
    if [[ "$TEAM_REVIEW" == true ]]; then
      log "[DRY RUN] Would invoke Cornelius to review PR #${pr_number}"
      log "[DRY RUN] Review prompt:"
      generate_review_team_prompt "$pr_number" "/tmp/example-worktree" "example-branch"
    else
      log "[DRY RUN] Would invoke Claude to review PR #${pr_number}"
    fi
    return
  fi

  # ── Create a worktree so we don't touch the main working tree ──────
  mkdir -p "${PROJECT_DIR}/.worktrees"
  local worktree_path="${PROJECT_DIR}/.worktrees/review-pr-${pr_number}"

  # Fetch the PR branch so it's available locally
  git fetch origin "pull/${pr_number}/head:${pr_branch}" 2>/dev/null || \
    git fetch origin "${pr_branch}" 2>/dev/null || true

  if [[ -d "$worktree_path" ]]; then
    log "Reusing existing review worktree: ${worktree_path}"
  else
    git worktree add "$worktree_path" "$pr_branch" 2>/dev/null || {
      log "Failed to create review worktree for PR #${pr_number} — falling back to detached HEAD"
      git worktree add --detach "$worktree_path" "$pr_branch" 2>/dev/null || {
        log "ERROR: Could not create worktree at all for PR #${pr_number}"
        return 1
      }
    }
  fi
  log "Review worktree ready: ${worktree_path}"

  local review_rc=0

  if [[ "$TEAM_REVIEW" == true ]]; then
    # ── Team-based review ──────────────────────────────────────────────
    log "Dispatching Cornelius for PR review..."

    local review_prompt
    review_prompt=$(generate_review_team_prompt "$pr_number" "$worktree_path" "$pr_branch" "$reviewer_context")

    # Detect review completion (merge, close, or approve) and give grace to wrap up
    export RALPH_DONE_PATTERN="gh pr merge|ralph-safe-merge|gh pr close|Approved by|--approve|successfully merged|pull request.*closed|CI FAILED.*blocking merge|CI checks failed"
    export RALPH_DONE_GRACE=120

    run_claude -p "$review_prompt" \
      --model "$MODEL" \
      --max-turns "$MAX_TURNS" \
      --allowedTools "$ALLOWED_TOOLS" \
      || review_rc=$?

    unset RALPH_DONE_PATTERN RALPH_DONE_GRACE
  else
    # ── Solo review ────────────────────────────────────────────────────
    export RALPH_DONE_PATTERN="gh pr merge|ralph-safe-merge|gh pr close|Approved by|--approve|successfully merged|pull request.*closed|CI FAILED.*blocking merge|CI checks failed"
    export RALPH_DONE_GRACE=90

    local reviewer_section=""
    if [[ -n "$reviewer_context" ]]; then
      reviewer_section="
## External Review Feedback
${WAIT_FOR_REVIEWER} has already reviewed this PR. Their feedback is below.
Consider their comments in your review — address, fix, or acknowledge each point.

${reviewer_context}
"
    fi

    run_claude -p "You are reviewing pull request #${pr_number} in this repository.

## Worktree
A git worktree has been created for this PR at: ${worktree_path}
Branch: ${pr_branch}
All code reading and fixes MUST happen in this worktree directory.
Do NOT use \`gh pr checkout\` — the branch is already checked out in the worktree.

## Instructions

1. Run \`gh pr view ${pr_number}\` to read the PR description.
2. Run \`gh pr diff ${pr_number}\` to see the full diff.
3. Read any changed files in the worktree (\`${worktree_path}/...\`) to understand context.
4. Evaluate the PR for:
   - Correctness and logic errors
   - Test coverage (are new features tested?)
   - Adherence to repo conventions (see CLAUDE.md)
   - Security issues
   - Code style and clarity

5. **If changes are needed and you can fix them:**
   - Make the fixes in the worktree directory (${worktree_path})
   - Commit with a clear message (conventional commits) — run git commands from the worktree:
     \`cd ${worktree_path} && git add . && git commit -m \"fix: ...\"\`
   - Push the fixes: \`cd ${worktree_path} && git push origin ${pr_branch}\`
   - Then approve and merge (step 6)

6. **If the PR is good** (either initially or after your fixes):
   - \`gh pr review ${pr_number} --approve --body \"Looks good! Reviewed and approved by Cornelius.\"\`
   - Merge using the safe-merge wrapper (it verifies CI passes before merging):
     \`${SCRIPT_DIR}/ralph-safe-merge.sh ${pr_number} --squash --delete-branch\`
   - Do NOT use \`gh pr merge\` directly — always use ralph-safe-merge.sh

7. **If the safe-merge wrapper reports CI failure:**
   - Read the failing check output to understand what failed (e.g. typecheck, lint, tests)
   - Attempt to fix the errors in the worktree: \`cd ${worktree_path} && ...\`
   - Commit and push: \`cd ${worktree_path} && git add . && git commit -m \"fix: ...\" && git push origin ${pr_branch}\`
   - Wait for CI to re-run: \`gh pr checks ${pr_number} --watch --fail-fast\`
   - Try merging again: \`${SCRIPT_DIR}/ralph-safe-merge.sh ${pr_number} --squash --delete-branch\`
   - If you cannot fix the errors, leave a comment explaining what failed and stop

8. **If the PR is fundamentally broken** (can't be fixed reasonably):
   - \`gh pr close ${pr_number} --comment \"Closing: <explanation of why this PR is not mergeable>\"\`
${reviewer_section}
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

  # Always clean up the review worktree (it's ours, not the user's)
  if [[ -d "$worktree_path" ]]; then
    log "Cleaning up review worktree: ${worktree_path}"
    git worktree remove "$worktree_path" --force 2>/dev/null || true
    if [[ -d "$worktree_path" ]]; then
      rm -rf "$worktree_path"
    fi
  fi

  # Clean up branch and sync main if PR was merged
  local pr_state
  pr_state=$(gh pr view "$pr_number" --json state -q .state 2>/dev/null || echo "")
  if [[ "$pr_state" == "MERGED" ]]; then
    if [[ -n "$pr_branch" ]]; then
      # Also check for any other worktrees using this branch
      local other_wt=""
      other_wt=$(git worktree list --porcelain 2>/dev/null | awk -v branch="branch refs/heads/${pr_branch}" '
        /^worktree / { wt = substr($0, 10) }
        $0 == branch { print wt; exit }
        /^$/ { wt = "" }
      ' || echo "")
      if [[ -n "$other_wt" ]]; then
        log "Cleaning up worktree: ${other_wt}"
        git worktree remove "$other_wt" --force 2>/dev/null || true
        [[ -d "$other_wt" ]] && rm -rf "$other_wt"
      fi
      git branch -D "$pr_branch" 2>/dev/null || true
      log "Cleaned up branch: ${pr_branch}"
    fi
    git worktree prune 2>/dev/null || true
    git pull origin main 2>/dev/null || true
  else
    git worktree prune 2>/dev/null || true
  fi
}

# ── Load custom agents (only when --agents-dir is explicitly passed) ───────────
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

# ── Resolve repo name for external reviewer checks ───────────────────────────
REPO_NWO=""
if [[ -n "$WAIT_FOR_REVIEWER" ]]; then
  REPO_NWO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
  log "Will wait for '${WAIT_FOR_REVIEWER}' before reviewing (repo: ${REPO_NWO})"
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
  log "Ralph Review Loop starting in WATCH mode — poll=${POLL_INTERVAL}s, model=${MODEL}, max-turns=${MAX_TURNS}, timeout=${TIMEOUT}s, team-review=${TEAM_REVIEW}, agents-dir=${AGENTS_DIR:-none}, wait-for-reviewer=${WAIT_FOR_REVIEWER:-none}, skip-ci-check=${SKIP_CI_CHECK}, ci-timeout=${CI_CHECK_TIMEOUT}s, dry-run=${DRY_RUN}"
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

        if [[ -n "$WAIT_FOR_REVIEWER" ]]; then
          if ! has_reviewer_reviewed "$pr" "$WAIT_FOR_REVIEWER" "$REPO_NWO"; then
            log "PR #${pr}: waiting for ${WAIT_FOR_REVIEWER} — skipping this cycle"
            continue
          fi
        fi

        if ! wait_for_ci_checks "$pr"; then
          log "PR #${pr}: CI checks failed — skipping this cycle"
          continue
        fi

        # Check retry count before reviewing
        retries=$(get_retry_count "$pr")
        if (( retries >= MAX_REVIEW_RETRIES )); then
          log "PR #${pr}: exceeded max retries (${retries}/${MAX_REVIEW_RETRIES}) — giving up"
          mark_reviewed "$pr"
          continue
        fi

        found_new=true
        reviews_done=$((reviews_done + 1))
        log "── Review #${reviews_done} (PR #${pr}) ──────────────────────────────────────"
        review_pr "$pr"

        # Only mark as reviewed if PR was merged or closed; otherwise retry next cycle
        post_state=$(gh pr view "$pr" --json state -q .state 2>/dev/null || echo "OPEN")
        if [[ "$post_state" == "MERGED" || "$post_state" == "CLOSED" ]]; then
          mark_reviewed "$pr"
          clear_retry_count "$pr"
        else
          new_count=$(increment_retry_count "$pr")
          log "PR #${pr}: still open after review (retry ${new_count}/${MAX_REVIEW_RETRIES}) — will retry next cycle"
        fi
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
  log "Ralph Review Loop starting — count=${COUNT}, model=${MODEL}, max-turns=${MAX_TURNS}, timeout=${TIMEOUT}s, team-review=${TEAM_REVIEW}, agents-dir=${AGENTS_DIR:-none}, wait-for-reviewer=${WAIT_FOR_REVIEWER:-none}, skip-ci-check=${SKIP_CI_CHECK}, ci-timeout=${CI_CHECK_TIMEOUT}s, dry-run=${DRY_RUN}"
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
        if ! wait_for_external_reviewer "$pr"; then
          log "Skipping PR #${pr} (reviewer timeout)"
          continue
        fi
        if ! wait_for_ci_checks "$pr"; then
          log "Skipping PR #${pr} (CI checks failed)"
          continue
        fi
        review_pr "$pr"
      else
        log "Empty PR number in list, skipping."
      fi
    else
      # Find oldest open PR
      pr=$(find_open_prs 1 | head -1)
      if [[ -n "$pr" ]]; then
        if ! wait_for_external_reviewer "$pr"; then
          log "Skipping PR #${pr} (reviewer timeout)"
          continue
        fi
        if ! wait_for_ci_checks "$pr"; then
          log "Skipping PR #${pr} (CI checks failed)"
          continue
        fi
        review_pr "$pr"
      else
        log "No open PRs found. Nothing to review."
      fi
    fi
  done

  log "Ralph Review Loop complete."
fi
