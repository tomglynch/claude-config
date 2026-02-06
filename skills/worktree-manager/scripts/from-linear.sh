#!/bin/bash
# from-linear.sh - Create a worktree from a Linear ticket ID
#
# Usage: ./from-linear.sh <ticket-id> [repo-path]
#
# Examples:
#   ./from-linear.sh PRO-475
#   ./from-linear.sh PRO-475 /path/to/repo
#
# This script:
# 1. Fetches ticket details from Linear (requires linear MCP or API)
# 2. Creates a worktree with the ticket's git branch name
# 3. Installs dependencies (auto-detects package manager)
# 4. Allocates ports and registers in global registry
# 5. Launches Claude agent with ticket description as task

set -e

TICKET_ID="$1"
REPO_PATH="${2:-$(pwd)}"

# Validate input
if [ -z "$TICKET_ID" ]; then
    echo "Error: Ticket ID required"
    echo "Usage: $0 <ticket-id> [repo-path]"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Get project name
cd "$REPO_PATH"
PROJECT=$(basename "$(git remote get-url origin 2>/dev/null | sed 's/\.git$//')" 2>/dev/null || basename "$REPO_PATH")
REPO_ROOT=$(git rev-parse --show-toplevel)

echo "📋 Fetching ticket $TICKET_ID..."

# This script is meant to be called by Claude, which will:
# 1. Fetch ticket from Linear MCP
# 2. Pass branch name and task description
# For standalone use, we expect these as environment variables
if [ -z "$BRANCH" ] || [ -z "$TASK" ]; then
    echo "Error: This script expects BRANCH and TASK environment variables"
    echo "It's designed to be called by Claude after fetching Linear ticket details"
    echo ""
    echo "Example:"
    echo "  BRANCH='tom/pro-475-fix-theme' TASK='Fix the theme color' $0 PRO-475"
    exit 1
fi

BRANCH_SLUG=$(echo "$BRANCH" | tr '/' '-')
WORKTREE_PATH="$HOME/tmp/worktrees/$PROJECT/$BRANCH_SLUG"

echo "🌳 Creating worktree for $TICKET_ID"
echo "   Project: $PROJECT"
echo "   Branch: $BRANCH"
echo "   Path: $WORKTREE_PATH"

# Create worktree
mkdir -p "$HOME/tmp/worktrees/$PROJECT"
if git show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null; then
    git worktree add "$WORKTREE_PATH" "$BRANCH"
else
    git worktree add "$WORKTREE_PATH" -b "$BRANCH"
fi

# Copy resources
for DIR in .agents .env.example .env; do
    if [ -e "$REPO_ROOT/$DIR" ]; then
        cp -r "$REPO_ROOT/$DIR" "$WORKTREE_PATH/" 2>/dev/null && echo "   Copied $DIR"
    fi
done

# Detect and install dependencies
echo "📦 Installing dependencies..."
install_deps() {
    local dir="$1"
    cd "$dir"
    if [ -f "bun.lockb" ]; then bun install
    elif [ -f "pnpm-lock.yaml" ]; then pnpm install
    elif [ -f "yarn.lock" ]; then yarn install
    elif [ -f "package-lock.json" ]; then npm install
    elif [ -f "uv.lock" ]; then uv sync
    elif [ -f "pyproject.toml" ]; then uv sync
    elif [ -f "requirements.txt" ]; then pip install -r requirements.txt
    elif [ -f "go.mod" ]; then go mod download
    elif [ -f "Cargo.toml" ]; then cargo build
    fi
}

# Install in root
install_deps "$WORKTREE_PATH"

# Install in subdirectories (client, server, etc.)
for subdir in client server frontend backend api; do
    if [ -d "$WORKTREE_PATH/$subdir" ]; then
        echo "   Installing in $subdir/..."
        install_deps "$WORKTREE_PATH/$subdir" 2>/dev/null || true
    fi
done

# Allocate ports
echo "🔌 Allocating ports..."
PORTS=$("$SCRIPT_DIR/allocate-ports.sh" 2)
PORT_ARRAY=($PORTS)
echo "   Allocated: ${PORT_ARRAY[0]}, ${PORT_ARRAY[1]}"

# Register worktree
echo "📝 Registering worktree..."
"$SCRIPT_DIR/register.sh" \
    "$PROJECT" \
    "$BRANCH" \
    "$BRANCH_SLUG" \
    "$WORKTREE_PATH" \
    "$REPO_ROOT" \
    "${PORT_ARRAY[0]},${PORT_ARRAY[1]}" \
    "$TICKET_ID: $TASK"

# Launch agent
echo "🚀 Launching Claude agent..."
"$SCRIPT_DIR/launch-agent.sh" "$WORKTREE_PATH" "$TICKET_ID: $TASK"

echo ""
echo "✅ Worktree ready for $TICKET_ID"
echo "   Branch: $BRANCH"
echo "   Path: $WORKTREE_PATH"
echo "   Ports: ${PORT_ARRAY[0]}, ${PORT_ARRAY[1]}"
