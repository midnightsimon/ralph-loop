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

  1. Clone this repo (or put it anywhere on your machine):
  git clone <repo-url> ~/ralph-loop
  2. Ensure your target project has a CLAUDE.md at its root — Claude
  uses it to understand your project structure, conventions, and
  workflow.
  3. Run the scripts from your project directory:
  cd ~/my-project && ~/ralph-loop/ralph-loop.sh

  No need to copy scripts into each project. The scripts auto-detect
  the project from your current working directory.

  Usage

  ralph-loop.sh [OPTIONS]

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
  cd ~/my-project && ~/ralph-loop/ralph-loop.sh

  # Work 5 iterations (reviews PRs + picks issues)
  ~/ralph-loop/ralph-loop.sh --count 5

  # Work on specific issues
  ~/ralph-loop/ralph-loop.sh --issues 42,58,73

  # Only work bug-labeled issues, using sonnet
  ~/ralph-loop/ralph-loop.sh --label bug --model sonnet --count 3

  # Preview what would happen
  ~/ralph-loop/ralph-loop.sh --count 3 --dry-run

  Issue Priority

  When auto-picking issues, Ralph checks labels in this order:

  1. bug
  2. testing
  3. enhancement
  4. documentation
  5. Fallback: oldest unassigned open issue

  Issues that are already assigned are skipped. Issues that fail or hit
   max turns are added to .ralph-skip so they won't be retried.

  Review Loop (ralph-review-loop.sh)

  A dedicated PR review loop that watches for open PRs and reviews
  them automatically. Supports watch mode (continuous polling) and
  one-shot mode.

  cd ~/my-project && ~/ralph-loop/ralph-review-loop.sh --watch
  cd ~/my-project && ~/ralph-loop/ralph-review-loop.sh --prs 42,58

  Key features:
  - CI-gated merges: PRs are only merged after all CI checks pass.
    Merges go through ralph-safe-merge.sh, which programmatically
    verifies CI status before executing the merge.
  - Auto-fix CI failures: If CI fails after review (e.g. typecheck
    errors), Claude attempts to fix the errors, push, and retry.
  - Retry on failure: If a PR can't be merged (CI still failing),
    it's retried on the next poll cycle, up to 3 times (configurable
    via MAX_REVIEW_RETRIES env var). After max retries, the PR is
    skipped.
  - Team review mode: Use --team-review to have multiple AI
    reviewers examine the PR independently before a lead synthesizes
    a decision.
  - External reviewer gating: Use --wait-for-reviewer NAME to wait
    for a human/bot review before Ralph reviews.

  Safe Merge (ralph-safe-merge.sh)

  A standalone merge wrapper that enforces CI checks at merge time.
  Used by the review loop internally, but can also be called
  directly:

  ~/ralph-loop/ralph-safe-merge.sh 123 --squash --delete-branch

  Behavior:
  - Checks gh pr checks for failures before merging
  - If checks are pending, polls every 15s (up to 5 min, configurable
    via RALPH_MERGE_CI_TIMEOUT env var)
  - If checks fail, prints which checks failed and exits 1
  - If checks pass, merges with --auto flag for server-side
    enforcement
  - If no CI checks are configured, proceeds with the merge

  How It Works Internally

  - Tool sandboxing: Claude is restricted to a specific set of allowed
  tools (file read/write, git, gh, npm, cmake, etc.) via
  --allowedTools. If Claude tries anything outside the allowlist, Ralph
   detects the denial and aborts.
  - Timeout protection: Each Claude invocation is killed if it exceeds
  the configured timeout.
  - Max turns detection: If Claude hits the turn limit, the issue is
  added to the skip file.
  - Directory separation: SCRIPT_DIR (where ralph scripts live) and
  PROJECT_DIR (your current working directory) are tracked
  separately, so the scripts work from any project without copying.
  - CI-gated merging: All merges go through ralph-safe-merge.sh,
  which checks CI status programmatically — not just via prompt
  instructions to Claude.
  - Retry tracking (.ralph-retry-counts): Tracks how many times a PR
  has been retried after failed reviews. Cleared on successful
  merge/close.
  - Skip file (.ralph-skip): A newline-delimited list of issue numbers
  that Ralph won't retry. Delete the file or remove entries to
  re-enable them.
  - Reviewed PRs (.ralph-reviewed-prs): Tracks which PRs have been
  reviewed. PRs are only marked as reviewed after they are merged or
  closed — not just after a review attempt.
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
