#!/bin/bash
# launch-agent.sh - Launch Claude Code in a new terminal for a worktree
#
# Usage: ./launch-agent.sh <worktree-path> [task-description]
#
# Examples:
#   ./launch-agent.sh ~/worktrees-qz/my-project/feature-auth
#   ./launch-agent.sh ~/worktrees-qz/my-project/feature-auth "Implement OAuth login"

set -e

WORKTREE_PATH="$1"
TASK="$2"

# Validate input
if [ -z "$WORKTREE_PATH" ]; then
    echo "Error: Worktree path required"
    echo "Usage: $0 <worktree-path> [task-description]"
    exit 1
fi

# Write task to file to avoid shell escaping issues with special characters
# (backticks, quotes, parentheses in markdown break when passed through
# bash → AppleScript → zsh/fish)
if [ -n "$TASK" ]; then
    TASK_FILE="$WORKTREE_PATH/.claude-task"
    printf '%s\n' "$TASK" > "$TASK_FILE"
fi

# Auto-detect available terminal
detect_terminal() {
    if [ -d "/Applications/Ghostty.app" ]; then echo "ghostty"
    elif [ -d "/Applications/iTerm.app" ]; then echo "iterm2"
    elif [ -d "/Applications/WezTerm.app" ]; then echo "wezterm"
    elif [ -d "/Applications/kitty.app" ]; then echo "kitty"
    elif command -v tmux &>/dev/null; then echo "tmux"
    else echo "terminal"  # macOS default Terminal.app
    fi
}

# Check if a terminal is available
is_terminal_available() {
    case "$1" in
        ghostty) [ -d "/Applications/Ghostty.app" ] ;;
        iterm2|iterm) [ -d "/Applications/iTerm.app" ] ;;
        wezterm) [ -d "/Applications/WezTerm.app" ] || command -v wezterm &>/dev/null ;;
        kitty) [ -d "/Applications/kitty.app" ] || command -v kitty &>/dev/null ;;
        alacritty) command -v alacritty &>/dev/null ;;
        tmux) command -v tmux &>/dev/null ;;
        terminal) true ;;  # Always available on macOS
        *) false ;;
    esac
}

# Find script directory and config
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../config.json"

# Load config (with defaults)
if [ -f "$CONFIG_FILE" ] && command -v jq &> /dev/null; then
    TERMINAL=$(jq -r '.terminal // "ghostty"' "$CONFIG_FILE")
    SHELL_CMD=$(jq -r '.shell // "fish"' "$CONFIG_FILE")
    CLAUDE_CMD=$(jq -r '.claudeCommand // "cc"' "$CONFIG_FILE")
else
    TERMINAL="ghostty"
    SHELL_CMD="fish"
    CLAUDE_CMD="cc"
fi

# Auto-detect terminal if configured one isn't available
if ! is_terminal_available "$TERMINAL"; then
    DETECTED=$(detect_terminal)
    echo "⚠️  Configured terminal '$TERMINAL' not found, using '$DETECTED'"
    TERMINAL="$DETECTED"
fi

# Note: CLAUDE_CMD (default "cc") is configurable in config.json
# It runs inside the target shell (fish) which should have the alias defined
# Falls back to "claude" if the alias/command fails

# Expand ~ in path
WORKTREE_PATH="${WORKTREE_PATH/#\~/$HOME}"

# Convert to absolute path if relative
if [[ "$WORKTREE_PATH" != /* ]]; then
    WORKTREE_PATH="$(pwd)/$WORKTREE_PATH"
fi

# Verify worktree exists
if [ ! -d "$WORKTREE_PATH" ]; then
    echo "Error: Worktree directory does not exist: $WORKTREE_PATH"
    exit 1
fi

# Verify it's a git worktree (has .git file or directory)
if [ ! -e "$WORKTREE_PATH/.git" ]; then
    echo "Error: Not a git worktree: $WORKTREE_PATH"
    exit 1
fi

# Get branch name
BRANCH=$(cd "$WORKTREE_PATH" && git branch --show-current 2>/dev/null || basename "$WORKTREE_PATH")

# Get project name from path
PROJECT=$(basename "$(dirname "$WORKTREE_PATH")")

# Build the command to run in the new terminal
# Task is always read from .claude-task file to avoid shell escaping issues
# Use configured command (cc) - fish syntax compatible
# For fish: use 'or' instead of '||' for fallback, and avoid subshells
SAFE_PROMPT="Read and execute the task described in .claude-task"
if [ "$SHELL_CMD" = "fish" ]; then
    if [ -n "$TASK" ]; then
        INNER_CMD="cd '$WORKTREE_PATH'; and echo '🌳 Worktree: $PROJECT / $BRANCH'; and echo ''; and $CLAUDE_CMD '$SAFE_PROMPT'; or claude '$SAFE_PROMPT'"
    else
        INNER_CMD="cd '$WORKTREE_PATH'; and echo '🌳 Worktree: $PROJECT / $BRANCH'; and echo ''; and $CLAUDE_CMD; or claude"
    fi
else
    # bash/zsh syntax
    if [ -n "$TASK" ]; then
        INNER_CMD="cd '$WORKTREE_PATH' && echo '🌳 Worktree: $PROJECT / $BRANCH' && echo '' && ($CLAUDE_CMD '$SAFE_PROMPT' || claude '$SAFE_PROMPT')"
    else
        INNER_CMD="cd '$WORKTREE_PATH' && echo '🌳 Worktree: $PROJECT / $BRANCH' && echo '' && ($CLAUDE_CMD || claude)"
    fi
fi

# Launch based on terminal type
case "$TERMINAL" in
    ghostty)
        if ! command -v ghostty &> /dev/null && [ ! -d "/Applications/Ghostty.app" ]; then
            echo "Error: Ghostty not found"
            exit 1
        fi
        # Launch Ghostty with the command
        open -na "Ghostty.app" --args -e "$SHELL_CMD" -c "$INNER_CMD"
        ;;

    iterm2|iterm)
        # Build command - task is read from .claude-task file to avoid escaping issues
        if [ -n "$TASK" ]; then
            CLAUDE_PANE_CMD="cd '${WORKTREE_PATH}' && ${CLAUDE_CMD} '${SAFE_PROMPT}'"
        else
            CLAUDE_PANE_CMD="cd '${WORKTREE_PATH}' && ${CLAUDE_CMD}"
        fi
        SHELL_PANE_CMD="cd '${WORKTREE_PATH}'"

        # Step 1: Create new desktop and switch to it
        osascript <<EOF
tell application "System Events" to tell application process "Dock"
    key code 160
    delay 1
    tell group 2 of group 1 of group 1
        click (buttons whose description is "add desktop")
    end tell
    delay 0.3
    key code 53
end tell

delay 0.3

-- Move right 10 times to reach the new desktop
tell application "System Events"
    repeat 16 times
        key code 124 using control down
        delay 0.1
    end repeat
end tell
EOF

        # Step 2: Create iTerm window with vertical split
        # Make window 900x460, positioned at top-left
        # Use "open -a iTerm" first to bring iTerm to the CURRENT space,
        # otherwise "tell application iTerm2" switches to iTerm's existing space
        osascript <<EOF
do shell script "open -a iTerm"
delay 0.5

tell application "iTerm2"
    create window with default profile
    tell current window
        set bounds to {0, 0, 900, 460}
        tell current session
            split vertically with default profile
        end tell
        -- After split: left pane is session 1, right pane is session 2
        tell first session of current tab
            write text "$CLAUDE_PANE_CMD"
        end tell
        tell second session of current tab
            write text "$SHELL_PANE_CMD"
        end tell
    end tell
end tell
EOF

        # Step 3: Open VS Code in the worktree
        code "$WORKTREE_PATH"
        ;;

    tmux)
        if ! command -v tmux &> /dev/null; then
            echo "Error: tmux not found"
            exit 1
        fi
        SESSION_NAME="wt-$PROJECT-$(echo "$BRANCH" | tr '/' '-')"
        tmux new-session -d -s "$SESSION_NAME" -c "$WORKTREE_PATH" "$SHELL_CMD -c '$CLAUDE_CMD'"
        echo "   tmux session: $SESSION_NAME (attach with: tmux attach -t $SESSION_NAME)"
        ;;

    wezterm)
        if ! command -v wezterm &> /dev/null; then
            echo "Error: WezTerm not found"
            exit 1
        fi
        wezterm start --cwd "$WORKTREE_PATH" -- "$SHELL_CMD" -c "$INNER_CMD"
        ;;

    kitty)
        if ! command -v kitty &> /dev/null; then
            echo "Error: Kitty not found"
            exit 1
        fi
        kitty --detach --directory "$WORKTREE_PATH" "$SHELL_CMD" -c "$INNER_CMD"
        ;;

    alacritty)
        if ! command -v alacritty &> /dev/null; then
            echo "Error: Alacritty not found"
            exit 1
        fi
        alacritty --working-directory "$WORKTREE_PATH" -e "$SHELL_CMD" -c "$INNER_CMD" &
        ;;

    terminal)
        # macOS default Terminal.app - task read from .claude-task file
        if [ -n "$TASK" ]; then
            CMD="cd '${WORKTREE_PATH}' && ${CLAUDE_CMD} '${SAFE_PROMPT}'"
        else
            CMD="cd '${WORKTREE_PATH}' && ${CLAUDE_CMD}"
        fi
        osascript -e 'tell application "Terminal"' \
                  -e "do script \"$CMD\"" \
                  -e 'activate' \
                  -e 'end tell'
        ;;

    *)
        echo "Error: Unknown terminal type: $TERMINAL"
        echo "Supported: ghostty, iterm2, terminal, tmux, wezterm, kitty, alacritty"
        exit 1
        ;;
esac

echo "✅ Launched Claude Code agent"
echo "   Terminal: $TERMINAL"
echo "   Project: $PROJECT"
echo "   Branch: $BRANCH"
echo "   Path: $WORKTREE_PATH"
if [ -n "$TASK" ]; then
    echo "   Task: $TASK"
fi
