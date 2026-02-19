#!/bin/bash
# Linear Poller Configuration

# Linear API (used ONLY for the comment search query — MCP can't search comments)
# API key lives in .env (gitignored) — copy .env.example to .env and fill in
SCRIPT_POLLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_POLLER_DIR/.env" ]; then
    source "$SCRIPT_POLLER_DIR/.env"
fi
LINEAR_API_URL="https://api.linear.app/graphql"

# Label names (applied/removed via MCP)
AI_LABEL_IN_PROGRESS="ai-in-progress"
AI_LABEL_READY_FOR_REVIEW="ai-ready-for-review"

# Default repo to work in (the @claude comment can override this)
DEFAULT_REPO="$HOME/qz/toocan-app"

# Worktree base directory (only used in --local mode)
WORKTREE_DIR="$HOME/worktrees-claude"

# Timeout for claude worker (in seconds) — 30 minutes
WORKER_TIMEOUT=1800

# Log directory
LOG_DIR="$HOME/.claude/scripts/linear-poller/logs"

# Branch prefix for AI-created branches
BRANCH_PREFIX="ai"
