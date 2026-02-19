#!/bin/bash
# Worker script — runs Claude on a single Linear ticket
# Called by poll.sh, runs in the background
#
# Modes:
#   background (default): runs claude --print headlessly — works locally or in cloud
#   local: uses worktree-manager skill to create worktree + launch in terminal

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# Allow nested claude sessions (worker may be spawned from within Claude Code)
unset CLAUDECODE

MODE="$1"
ISSUE_ID="$2"
ISSUE_IDENT="$3"
ISSUE_TITLE="$4"
ISSUE_DESC="$5"
TRIGGER_COMMENT="$6"
REPO="$7"

WORKER_LOG="$LOG_DIR/${ISSUE_IDENT}.log"
LOCK_FILE="$LOG_DIR/${ISSUE_IDENT}.lock"
PROMPT_DIR="$LOG_DIR/prompts"

WORKTREE_SCRIPTS="$HOME/.claude/skills/worktree-manager/scripts"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$WORKER_LOG"
}

# macOS-compatible timeout wrapper (uses perl since `timeout` isn't available)
run_with_timeout() {
  local secs="$1"
  shift
  perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
}

# Run claude --print with prompt from a temp file (avoids shell quoting issues)
run_claude() {
  local prompt_file="$1"
  shift
  cat "$prompt_file" | claude --print "$@"
}

cleanup() {
  rm -f "$LOCK_FILE"
  rm -f "$PROMPT_DIR/${ISSUE_IDENT}-"*.txt
}
trap cleanup EXIT

mkdir -p "$PROMPT_DIR"

log "=== Worker started for $ISSUE_IDENT (mode: $MODE) ==="
log "Title: $ISSUE_TITLE"
log "Repo: $REPO"

# ─── Step 1: Add ai-in-progress label + post pickup comment (via Claude + MCP) ───

log "Adding label and posting pickup comment..."

SETUP_PROMPT="$PROMPT_DIR/${ISSUE_IDENT}-setup.txt"
cat > "$SETUP_PROMPT" << EOF
Do these two things and nothing else:
1. Update Linear issue ID "$ISSUE_ID" to add the label "$AI_LABEL_IN_PROGRESS" (keep any existing labels too).
2. Post a comment on issue ID "$ISSUE_ID" saying: "Picking this up now. Will create a branch, implement, and open a PR."
Do not explain, just do it.
EOF

run_with_timeout 120 run_claude "$SETUP_PROMPT" \
  --dangerously-skip-permissions \
  --allowedTools "mcp__linear-server__update_issue,mcp__linear-server__create_comment" \
  >> "$WORKER_LOG" 2>&1

if [ $? -ne 0 ]; then
  log "ERROR: Failed to set up issue. Aborting."
  exit 1
fi
log "Setup complete."

# ─── Step 2: Get branch name ───

BRANCH_NAME="${BRANCH_PREFIX}/${ISSUE_IDENT}"
MAIN_BRANCH=$(git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")

# ─── Step 3: Mode-specific execution ───

if [ "$MODE" = "local" ]; then
  # ── LOCAL MODE: Use worktree-manager skill ──
  log "Creating worktree via worktree-manager skill..."

  TASK_DESC="$ISSUE_IDENT: $ISSUE_TITLE

Description: $ISSUE_DESC

Trigger: $TRIGGER_COMMENT

Instructions:
- Implement the task described above
- Write clean, tested code
- Commit referencing $ISSUE_IDENT
- Push and create a PR
- When done, use Linear MCP to:
  1. Post a summary comment on issue $ISSUE_ID with PR link
  2. Remove the '$AI_LABEL_IN_PROGRESS' label from issue $ISSUE_ID
  3. Add the '$AI_LABEL_READY_FOR_REVIEW' label to issue $ISSUE_ID
- If stuck, post a comment explaining what you need and remove the '$AI_LABEL_IN_PROGRESS' label"

  BRANCH="$BRANCH_NAME" TASK="$TASK_DESC" \
    "$WORKTREE_SCRIPTS/from-linear.sh" "$ISSUE_IDENT" "$REPO" >> "$WORKER_LOG" 2>&1

  if [ $? -ne 0 ]; then
    log "ERROR: Worktree creation failed. Posting error comment."
    ERROR_PROMPT="$PROMPT_DIR/${ISSUE_IDENT}-error.txt"
    cat > "$ERROR_PROMPT" << EOF
Do two things:
1. Post a comment on Linear issue ID "$ISSUE_ID" saying: "Failed to create worktree for this ticket. Manual intervention needed."
2. Remove the label "$AI_LABEL_IN_PROGRESS" from issue ID "$ISSUE_ID".
EOF
    run_with_timeout 120 run_claude "$ERROR_PROMPT" \
      --dangerously-skip-permissions \
      --allowedTools "mcp__linear-server__create_comment,mcp__linear-server__update_issue" \
      >> "$WORKER_LOG" 2>&1
    exit 1
  fi

  log "Worktree created and agent launched in terminal."

else
  # ── BACKGROUND MODE: Run claude --print headlessly ──
  log "Running in background mode..."

  WORKTREE_PATH="$WORKTREE_DIR/$ISSUE_IDENT"
  mkdir -p "$WORKTREE_DIR"

  if [ -d "$WORKTREE_PATH" ]; then
    git -C "$REPO" worktree remove "$WORKTREE_PATH" --force 2>/dev/null || true
  fi

  git -C "$REPO" fetch origin >> "$WORKER_LOG" 2>&1
  git -C "$REPO" worktree add -b "$BRANCH_NAME" "$WORKTREE_PATH" "origin/$MAIN_BRANCH" >> "$WORKER_LOG" 2>&1

  if [ $? -ne 0 ]; then
    log "ERROR: Failed to create worktree."
    ERROR_PROMPT="$PROMPT_DIR/${ISSUE_IDENT}-error.txt"
    cat > "$ERROR_PROMPT" << EOF
Do two things:
1. Post a comment on Linear issue ID "$ISSUE_ID" saying: "Failed to create git worktree. Manual intervention needed."
2. Remove the label "$AI_LABEL_IN_PROGRESS" from issue ID "$ISSUE_ID".
EOF
    run_with_timeout 120 run_claude "$ERROR_PROMPT" \
      --dangerously-skip-permissions \
      --allowedTools "mcp__linear-server__create_comment,mcp__linear-server__update_issue" \
      >> "$WORKER_LOG" 2>&1
    exit 1
  fi

  log "Worktree created at $WORKTREE_PATH. Starting Claude..."

  # The @claude comment IS the prompt — if it's just "@claude", fall back to title + description
  if [ "$TRIGGER_COMMENT" = "@claude" ] || [ -z "$TRIGGER_COMMENT" ]; then
    USER_INSTRUCTIONS="Implement the ticket as described in the title and description."
  else
    USER_INSTRUCTIONS="$TRIGGER_COMMENT"
  fi

  WORK_PROMPT="$PROMPT_DIR/${ISSUE_IDENT}-work.txt"
  cat > "$WORK_PROMPT" << EOF
You are working on Linear ticket $ISSUE_IDENT.

Title: $ISSUE_TITLE

Description:
$ISSUE_DESC

What was asked:
$USER_INSTRUCTIONS

Instructions:
1. You are in a git worktree on branch '$BRANCH_NAME' based off $MAIN_BRANCH.
2. Read the codebase, understand the task, and implement it.
3. Write clean, tested code. Run any existing tests to make sure you haven't broken anything.
4. Commit your changes with a clear commit message referencing $ISSUE_IDENT.
5. Push the branch to origin.
6. Create a PR using 'gh pr create' with a clear title and description linking to the Linear ticket.
7. When done, use the Linear MCP to:
   a. Post a comment on issue $ISSUE_ID with a summary of what you did and a link to the PR.
   b. Remove the '$AI_LABEL_IN_PROGRESS' label from issue $ISSUE_ID.
   c. Add the '$AI_LABEL_READY_FOR_REVIEW' label to issue $ISSUE_ID.

If you get stuck or the task is unclear, post a comment on the issue explaining what you need and remove the '$AI_LABEL_IN_PROGRESS' label.
EOF

  EXIT_CODE=0
  cd "$WORKTREE_PATH" && run_with_timeout "$WORKER_TIMEOUT" run_claude "$WORK_PROMPT" \
    --dangerously-skip-permissions \
    --allowedTools "Bash,Read,Write,Edit,Glob,Grep,mcp__linear-server__update_issue,mcp__linear-server__create_comment,mcp__linear-server__get_issue,mcp__linear-server__list_comments" \
    >> "$WORKER_LOG" 2>&1 || EXIT_CODE=$?

  log "Claude exited with code $EXIT_CODE"

  # ── Handle failure ──
  if [ $EXIT_CODE -ne 0 ]; then
    log "ERROR: Claude failed with exit code $EXIT_CODE"
    FAIL_PROMPT="$PROMPT_DIR/${ISSUE_IDENT}-fail.txt"
    cat > "$FAIL_PROMPT" << EOF
Do two things:
1. Post a comment on Linear issue ID "$ISSUE_ID" saying: "Encountered an error (exit code $EXIT_CODE). Branch $BRANCH_NAME may have partial work. Check logs for details."
2. Remove the label "$AI_LABEL_IN_PROGRESS" from issue ID "$ISSUE_ID".
EOF
    run_with_timeout 120 run_claude "$FAIL_PROMPT" \
      --dangerously-skip-permissions \
      --allowedTools "mcp__linear-server__create_comment,mcp__linear-server__update_issue" \
      >> "$WORKER_LOG" 2>&1
  fi

  # ── Clean up worktree ──
  log "Cleaning up worktree..."
  git -C "$REPO" worktree remove "$WORKTREE_PATH" --force >> "$WORKER_LOG" 2>&1 || true
fi

log "=== Worker finished for $ISSUE_IDENT ==="
