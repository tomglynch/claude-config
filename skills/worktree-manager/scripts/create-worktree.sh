#!/bin/bash
# create-worktree.sh - Create a complete worktree with dependencies installed
#
# Usage: ./create-worktree.sh <repo-path> <branch-name> [task]
#
# Arguments:
#   repo-path   - Path to the source repository (e.g., ~/qz/toocan-app)
#   branch-name - Branch name to create (e.g., feature/auth or my-feature)
#   task        - Optional task description
#
# Example:
#   ./create-worktree.sh ~/qz/toocan-app test-permissions-check "Test permissions"
#
# This script:
#   1. Detects project name from git remote
#   2. Allocates ports from the global pool
#   3. Creates the git worktree
#   4. Copies .agents/ and .env.example if present
#   5. Installs dependencies (detects pnpm/npm/uv/etc)
#   6. Registers in the global worktree registry

set -e

REPO_PATH="$1"
BRANCH="$2"
TASK="${3:-}"

# Validate inputs
if [ -z "$REPO_PATH" ] || [ -z "$BRANCH" ]; then
    echo "Usage: $0 <repo-path> <branch-name> [task]" >&2
    exit 1
fi

# Expand ~ in repo path
REPO_PATH="${REPO_PATH/#\~/$HOME}"

# Verify repo exists
if [ ! -d "$REPO_PATH/.git" ] && [ ! -f "$REPO_PATH/.git" ]; then
    echo "Error: $REPO_PATH is not a git repository" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Step 1: Detect project name ---
echo ">>> Detecting project name..."
cd "$REPO_PATH"
PROJECT=$(basename "$(git remote get-url origin 2>/dev/null | sed 's/\.git$//')" 2>/dev/null || basename "$REPO_PATH")
echo "    Project: $PROJECT"

# --- Step 2: Slugify branch name ---
BRANCH_SLUG=$(echo "$BRANCH" | tr '/' '-')
echo "    Branch: $BRANCH (slug: $BRANCH_SLUG)"

# --- Step 3: Determine worktree path ---
WORKTREE_BASE="$HOME/tmp/worktrees"
WORKTREE_PATH="$WORKTREE_BASE/$PROJECT/$BRANCH_SLUG"
echo "    Path: $WORKTREE_PATH"

# Check if worktree already exists
if [ -d "$WORKTREE_PATH" ]; then
    echo "Error: Worktree already exists at $WORKTREE_PATH" >&2
    echo "Run cleanup first: ~/.claude/skills/worktree-manager/scripts/cleanup.sh $PROJECT $BRANCH" >&2
    exit 1
fi

# --- Step 4: Allocate ports ---
echo ">>> Allocating ports..."
PORTS=$("$SCRIPT_DIR/allocate-ports.sh" 2)
echo "    Ports: $PORTS"
PORTS_CSV=$(echo "$PORTS" | tr ' ' ',')

# --- Step 5: Fetch latest from origin ---
echo ">>> Fetching latest from origin..."
git fetch origin --prune 2>&1 | tail -3 || echo "    Warning: fetch failed (offline?)"

# Detect default branch (main or master)
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
if [ -z "$DEFAULT_BRANCH" ]; then
    DEFAULT_BRANCH="main"  # fallback
fi
echo "    Default branch: $DEFAULT_BRANCH"

# --- Step 6: Create worktree ---
echo ">>> Creating git worktree..."
mkdir -p "$WORKTREE_BASE/$PROJECT"

# Check if branch already exists
if git show-ref --verify --quiet "refs/heads/$BRANCH" 2>/dev/null; then
    echo "    Using existing branch: $BRANCH"
    git worktree add "$WORKTREE_PATH" "$BRANCH"
else
    echo "    Creating new branch: $BRANCH (from origin/$DEFAULT_BRANCH)"
    git worktree add "$WORKTREE_PATH" -b "$BRANCH" "origin/$DEFAULT_BRANCH"
fi

# --- Step 7: Copy resources ---
echo ">>> Copying resources..."
if [ -d "$REPO_PATH/.agents" ]; then
    cp -r "$REPO_PATH/.agents" "$WORKTREE_PATH/"
    echo "    Copied .agents/"
fi

if [ -f "$REPO_PATH/.env.example" ]; then
    cp "$REPO_PATH/.env.example" "$WORKTREE_PATH/.env"
    echo "    Copied .env.example to .env"
fi

if [ -f "$REPO_PATH/.env" ]; then
    cp "$REPO_PATH/.env" "$WORKTREE_PATH/.env"
    echo "    Copied .env"
fi

# --- Step 7b: Set VS Code workspace color (lighter variant) ---
echo ">>> Setting VS Code workspace color..."

# Function to lighten a hex color (shift toward white by ~40%)
lighten_color() {
    local hex="${1#\#}"
    local r=$((16#${hex:0:2}))
    local g=$((16#${hex:2:2}))
    local b=$((16#${hex:4:2}))

    # Lighten by 25% toward white (255)
    r=$(( r + (255 - r) * 25 / 100 ))
    g=$(( g + (255 - g) * 25 / 100 ))
    b=$(( b + (255 - b) * 25 / 100 ))

    printf "#%02x%02x%02x" $r $g $b
}

# Try to extract color from source repo's VS Code settings (using grep since JSONC has trailing commas)
SOURCE_COLOR=""
if [ -f "$REPO_PATH/.vscode/settings.json" ]; then
    SOURCE_COLOR=$(grep -o '"activityBar.background"[[:space:]]*:[[:space:]]*"#[0-9a-fA-F]\{6\}"' "$REPO_PATH/.vscode/settings.json" 2>/dev/null | grep -o '#[0-9a-fA-F]\{6\}' | head -1)
fi

# Default to a nice blue if no source color found
if [ -z "$SOURCE_COLOR" ]; then
    SOURCE_COLOR="#1e3a5f"
fi

LIGHT_COLOR=$(lighten_color "$SOURCE_COLOR")
echo "    Base color: $SOURCE_COLOR → Worktree color: $LIGHT_COLOR"

# Create .vscode directory and update color settings in existing settings.json
# Note: settings.json may be JSONC (trailing commas, comments) so jq won't work
mkdir -p "$WORKTREE_PATH/.vscode"
VSCODE_SETTINGS="$WORKTREE_PATH/.vscode/settings.json"

if [ -f "$VSCODE_SETTINGS" ]; then
    # Replace hex color values for the three known keys using sed
    sed -i '' \
        -e 's/\("activityBar.background"[[:space:]]*:[[:space:]]*"\)#[0-9a-fA-F]\{6\}"/\1'"$LIGHT_COLOR"'"/' \
        -e 's/\("titleBar.activeBackground"[[:space:]]*:[[:space:]]*"\)#[0-9a-fA-F]\{6\}"/\1'"$LIGHT_COLOR"'"/' \
        -e 's/\("titleBar.inactiveBackground"[[:space:]]*:[[:space:]]*"\)#[0-9a-fA-F]\{6\}"/\1'"$LIGHT_COLOR"'"/' \
        "$VSCODE_SETTINGS"
    echo "    Updated colors in existing .vscode/settings.json"
else
    # Create new settings file
    cat > "$VSCODE_SETTINGS" << VSCODE_EOF
{
    "workbench.colorCustomizations": {
        "activityBar.background": "$LIGHT_COLOR",
        "titleBar.activeBackground": "$LIGHT_COLOR",
        "titleBar.inactiveBackground": "$LIGHT_COLOR"
    }
}
VSCODE_EOF
    echo "    Created .vscode/settings.json"
fi

# --- Step 8: Install dependencies ---
echo ">>> Installing dependencies..."

install_deps() {
    local dir="$1"
    local name="$2"

    cd "$dir"

    if [ -f "bun.lockb" ]; then
        echo "    [$name] Running: bun install"
        bun install 2>&1 | tail -5
    elif [ -f "pnpm-lock.yaml" ]; then
        echo "    [$name] Running: pnpm install"
        pnpm install 2>&1 | tail -5
    elif [ -f "yarn.lock" ]; then
        echo "    [$name] Running: yarn install"
        yarn install 2>&1 | tail -5
    elif [ -f "package-lock.json" ]; then
        echo "    [$name] Running: npm install"
        npm install 2>&1 | tail -5
    elif [ -f "package.json" ]; then
        echo "    [$name] Running: npm install (no lockfile)"
        npm install 2>&1 | tail -5
    elif [ -f "uv.lock" ] || [ -f "pyproject.toml" ]; then
        echo "    [$name] Running: uv sync"
        uv sync 2>&1 | tail -5
    elif [ -f "requirements.txt" ]; then
        echo "    [$name] Running: pip install -r requirements.txt"
        pip install -r requirements.txt 2>&1 | tail -5
    elif [ -f "go.mod" ]; then
        echo "    [$name] Running: go mod download"
        go mod download 2>&1 | tail -5
    elif [ -f "Cargo.toml" ]; then
        echo "    [$name] Running: cargo build"
        cargo build 2>&1 | tail -5
    else
        echo "    [$name] No package manager detected"
    fi
}

# Install in root
install_deps "$WORKTREE_PATH" "root"

# Check for common subdirectories with their own dependencies
for subdir in client server frontend backend api web app; do
    if [ -d "$WORKTREE_PATH/$subdir" ]; then
        if [ -f "$WORKTREE_PATH/$subdir/package.json" ] || \
           [ -f "$WORKTREE_PATH/$subdir/pyproject.toml" ] || \
           [ -f "$WORKTREE_PATH/$subdir/requirements.txt" ] || \
           [ -f "$WORKTREE_PATH/$subdir/go.mod" ] || \
           [ -f "$WORKTREE_PATH/$subdir/Cargo.toml" ]; then
            install_deps "$WORKTREE_PATH/$subdir" "$subdir"
        fi
    fi
done

# --- Step 9: Register worktree ---
echo ">>> Registering worktree..."
"$SCRIPT_DIR/register.sh" "$PROJECT" "$BRANCH" "$BRANCH_SLUG" "$WORKTREE_PATH" "$REPO_PATH" "$PORTS_CSV" "$TASK"

# --- Step 10: Pre-trust worktree in Claude config ---
echo ">>> Pre-trusting worktree in Claude config..."
CLAUDE_CONFIG="$HOME/.claude.json"
if [ -f "$CLAUDE_CONFIG" ] && command -v jq &> /dev/null; then
    TMP=$(mktemp)
    # Add project entry with hasTrustDialogAccepted=true to skip trust prompt
    jq --arg path "$WORKTREE_PATH" '.projects[$path] = {
        "allowedTools": [],
        "mcpContextUris": [],
        "mcpServers": {},
        "enabledMcpjsonServers": [],
        "disabledMcpjsonServers": [],
        "hasTrustDialogAccepted": true,
        "projectOnboardingSeenCount": 1,
        "hasCompletedProjectOnboarding": true,
        "disabledMcpServers": []
    }' "$CLAUDE_CONFIG" > "$TMP" && mv "$TMP" "$CLAUDE_CONFIG"
    echo "    Added trust entry for $WORKTREE_PATH"
fi

# --- Step 11: Launch agent in new terminal ---
echo ">>> Launching Claude agent..."
"$SCRIPT_DIR/launch-agent.sh" "$WORKTREE_PATH" "$TASK"

# --- Done ---
echo ""
echo "============================================"
echo "Worktree created successfully!"
echo "============================================"
echo "  Project:  $PROJECT"
echo "  Branch:   $BRANCH"
echo "  Path:     $WORKTREE_PATH"
echo "  Ports:    $PORTS"
if [ -n "$TASK" ]; then
    echo "  Task:     $TASK"
fi
echo "  Agent:    Launched in new terminal"
echo "============================================"
