#!/bin/bash
# Opens the appropriate directory in the specified app
# Usage: open-in-app.sh <app> [alias]
# Examples: open-in-app.sh "Visual Studio Code" v
#           open-in-app.sh iTerm
#           open-in-app.sh Finder

APP="$1"
ALIAS="$2"

# Determine target directory
TARGET="."

# Check if in a worktree
if [[ "$PWD" != *"/tmp/worktrees/"* ]]; then
  # Not in worktree - check if current branch matches one
  BRANCH=$(git branch --show-current 2>/dev/null)
  if [[ -n "$BRANCH" && -f ~/.claude/worktree-registry.json ]]; then
    WORKTREE=$(jq -r --arg b "$BRANCH" '.worktrees[] | select(.branch == $b) | .worktreePath' ~/.claude/worktree-registry.json 2>/dev/null)
    if [[ -n "$WORKTREE" && -d "$WORKTREE" ]]; then
      TARGET="$WORKTREE"
    fi
  fi
fi

# Open the target directory
# Note: Aliases from shell config aren't available in scripts, so use open -a
open -a "$APP" "$TARGET"

echo "Opened $TARGET in $APP"
