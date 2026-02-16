  Ralph Loop

  An autonomous GitHub issue and PR worker that uses Claude Code to
  triage, implement, and review work — fully headless, no human in the
  loop.

  What It Does

  Ralph Loop runs in a cycle. Each iteration, it:

  1. Checks for open PRs — if one exists, it invokes Claude to review
  the diff, fix issues if needed, then approve and merge (or close if
  fundamentally broken).
  2. Picks an issue — if no open PRs exist, it finds the
  highest-priority unassigned issue and works it in two phases:
    - Phase 1 (Triage): Claude reads the codebase, determines if the
  issue is still relevant, and produces an implementation plan. Stale
  issues get closed automatically.
    - Phase 2 (Implement): Claude creates a git worktree, implements
  the plan, runs tests, commits, pushes, and opens a PR — all
  autonomously.

  When using --issues, it processes the specified issues directly,
  skipping the PR-check/issue-pick logic.

  Requirements

  - Claude Code CLI (claude command available in PATH)
  - GitHub CLI (gh) — authenticated
  - jq and python3 (for JSON parsing)
  - A GitHub repository with issues and a CLAUDE.md file describing
  your project conventions

  Setup

  1. Copy ralph-loop.sh into the root of your GitHub repository.
  2. Make it executable:
  chmod +x ralph-loop.sh
  3. Ensure your repo has a CLAUDE.md at the root — Claude uses it to
  understand your project structure, conventions, and workflow.

  Usage

  ./ralph-loop.sh [OPTIONS]

  Options

  Flag: --count N
  Default: 1
  Description: Number of iterations to run
  ────────────────────────────────────────
  Flag: --issues N,N,N
  Default: —
  Description: Comma-separated issue numbers to work on (skips
    auto-picking)
  ────────────────────────────────────────
  Flag: --label LABEL
  Default: —
  Description: Only pick issues with this GitHub label
  ────────────────────────────────────────
  Flag: --model MODEL
  Default: opus
  Description: Claude model to use: opus, sonnet, or haiku
  ────────────────────────────────────────
  Flag: --max-turns N
  Default: 75
  Description: Max agentic turns per Claude invocation
  ────────────────────────────────────────
  Flag: --timeout SECS
  Default: 1800
  Description: Timeout per invocation in seconds (default: 30 min)
  ────────────────────────────────────────
  Flag: --dry-run
  Default: —
  Description: Print what would happen without invoking Claude
  ────────────────────────────────────────
  Flag: -h, --help
  Default: —
  Description: Show help

  Examples

  # Work one issue (auto-picks highest priority)
  ./ralph-loop.sh

  # Work 5 iterations (reviews PRs + picks issues)
  ./ralph-loop.sh --count 5

  # Work on specific issues
  ./ralph-loop.sh --issues 42,58,73

  # Only work bug-labeled issues, using sonnet
  ./ralph-loop.sh --label bug --model sonnet --count 3

  # Preview what would happen
  ./ralph-loop.sh --count 3 --dry-run

  Issue Priority

  When auto-picking issues, Ralph checks labels in this order:

  1. bug
  2. testing
  3. enhancement
  4. documentation
  5. Fallback: oldest unassigned open issue

  Issues that are already assigned are skipped. Issues that fail or hit
   max turns are added to .ralph-skip so they won't be retried.

  How It Works Internally

  - Tool sandboxing: Claude is restricted to a specific set of allowed
  tools (file read/write, git, gh, npm, cmake, etc.) via
  --allowedTools. If Claude tries anything outside the allowlist, Ralph
   detects the denial and aborts.
  - Timeout protection: Each Claude invocation is killed if it exceeds
  the configured timeout.
  - Max turns detection: If Claude hits the turn limit, the issue is
  added to the skip file.
  - Skip file (.ralph-skip): A newline-delimited list of issue numbers
  that Ralph won't retry. Delete the file or remove entries to
  re-enable them.
  - Logs (.ralph-logs/): Every Claude invocation's stdout/stderr is
  saved with a timestamp for debugging.
  - Worktree cleanup: After merging a PR, Ralph automatically removes
  the associated git worktree and local branch.

  Customization

  Allowed Tools

  The ALLOWED_TOOLS variable at the top of the script controls what
  Claude can do. Modify it to match your project's needs:

  ALLOWED_TOOLS="Read,Edit,Write,Grep,Glob,\
  Bash(git *),Bash(gh *),Bash(npm *),Bash(npx *),\
  Bash(cmake *),Bash(cd *),Bash(ls *),Bash(mkdir *),Bash(rm *)"

  Label Priority

  Change the LABEL_PRIORITY array to match your label scheme:

  LABEL_PRIORITY=("bug" "testing" "enhancement" "documentation")

  License

  MIT
