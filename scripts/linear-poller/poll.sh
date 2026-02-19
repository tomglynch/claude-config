#!/bin/bash
# Linear Poller — finds @claude-tagged tickets and launches them as background tasks
#
# Usage:
#   ./poll.sh
#
# Each ticket gets its own claude background task visible at claude.ai

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ─── Find tickets with @claude comments ───

QUERY='{ issues(filter: { comments: { body: { contains: "@claude" } }, state: { type: { in: ["triage", "unstarted", "started"] } }, labels: { every: { name: { neq: "ai-in-progress" } } } }) { nodes { id identifier title description state { name type } labels { nodes { name } } comments { nodes { body createdAt user { name } } } } } }'

RESPONSE=$(curl -s -X POST "$LINEAR_API_URL" \
  -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" \
  -d "{\"query\": $(echo "$QUERY" | jq -Rs .)}")

ISSUES=$(echo "$RESPONSE" | jq -c '.data.issues.nodes // []')
ISSUE_COUNT=$(echo "$ISSUES" | jq 'length')

echo "Found $ISSUE_COUNT ticket(s)"

if [ "$ISSUE_COUNT" -eq 0 ]; then
  exit 0
fi

# ─── For each ticket, launch a background task via tmux ───

# Each ticket gets its own tmux session so they don't interfere
echo "$ISSUES" | jq -c '.[]' | while read -r issue; do
  ISSUE_ID=$(echo "$issue" | jq -r '.id')
  ISSUE_IDENT=$(echo "$issue" | jq -r '.identifier')
  ISSUE_TITLE=$(echo "$issue" | jq -r '.title')
  ISSUE_DESC=$(echo "$issue" | jq -r '.description // ""')
  ISSUE_STATUS=$(echo "$issue" | jq -r '.state.name')

  # Get human comments only (filter out bot "Picking this up" / "Claude is working" comments)
  ALL_COMMENTS=$(echo "$issue" | jq -r '.comments.nodes | sort_by(.createdAt) | .[] | select(.body | (contains("Picking this up") or contains("Claude is working") or contains("ai-in-progress") or contains("ai-ready-for-review")) | not) | "\(.user.name): \(.body)"' | tr '\n' ' | ' | sed 's/  */ /g')

  # Find the @claude trigger comment specifically
  TRIGGER_COMMENT=$(echo "$issue" | jq -r '[.comments.nodes[] | select(.body | contains("@claude"))] | sort_by(.createdAt) | last | .body // ""')
  TRIGGER_USER=$(echo "$issue" | jq -r '[.comments.nodes[] | select(.body | contains("@claude"))] | sort_by(.createdAt) | last | .user.name // "Unknown"')

  # Skip if already done
  HAS_REVIEW_LABEL=$(echo "$issue" | jq -r '.labels.nodes[] | select(.name == "ai-ready-for-review") | .name' 2>/dev/null || true)
  if [ -n "$HAS_REVIEW_LABEL" ]; then
    echo "Skipping $ISSUE_IDENT — already reviewed"
    continue
  fi

  # Use trigger comment as instructions, fall back to title+desc
  if [ "$TRIGGER_COMMENT" = "@claude" ] || [ -z "$TRIGGER_COMMENT" ]; then
    INSTRUCTIONS="Implement the ticket as described in the title and description."
  else
    INSTRUCTIONS="$TRIGGER_COMMENT"
  fi

  # Flatten description
  CLEAN_DESC=$(echo "$ISSUE_DESC" | tr '\n' ' ' | sed 's/  */ /g')

  echo "=== $ISSUE_IDENT: $ISSUE_TITLE ($ISSUE_STATUS) ==="
  echo "  Triggered by: $TRIGGER_USER"
  echo "  Comment: ${TRIGGER_COMMENT:0:80}"

  # Each ticket gets its own tmux session
  SESSION="claude-${ISSUE_IDENT}"

  if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "  Skipping — tmux session '$SESSION' already exists"
    continue
  fi

  echo "  Launching background task..."

  tmux new-session -d -s "$SESSION" -c "$DEFAULT_REPO" "claude"
  sleep 8

  # Build prompt — include ticket details, no URLs that could confuse session capture
  PROMPT="Work on Linear issue $ISSUE_IDENT (ID: $ISSUE_ID). Title: $ISSUE_TITLE. Description: $CLEAN_DESC. Comments: $ALL_COMMENTS. Instructions: $INSTRUCTIONS. Workflow: (1) Plan what to do to complete the task. (2) Implement it, create a branch, commit, and push. Do NOT create a PR — a human reviewer will do that."
  PROMPT=$(echo "$PROMPT" | tr '\n' ' ' | sed 's/  */ /g')

  # Send & prefix — wait for TUI to recognize background mode
  tmux send-keys -t "$SESSION" "&"
  sleep 3

  # Send space
  tmux send-keys -t "$SESSION" " "
  sleep 0.5

  # Send prompt
  tmux send-keys -t "$SESSION" -l "$PROMPT"
  sleep 1

  # Submit
  tmux send-keys -t "$SESSION" Enter

  echo "  Sent! Waiting for background task to register..."

  # Poll for the "Include local changes?" dialog or session URL (up to 30s)
  for i in $(seq 1 15); do
    sleep 2
    PANE_OUTPUT=$(tmux capture-pane -t "$SESSION" -p)

    if echo "$PANE_OUTPUT" | grep -q "Include local changes"; then
      echo "  Handling 'Include local changes' dialog..."
      sleep 1
      tmux send-keys -t "$SESSION" Down
      sleep 0.5
      tmux send-keys -t "$SESSION" Enter
      sleep 8
      PANE_OUTPUT=$(tmux capture-pane -t "$SESSION" -p)
      break
    fi

    if echo "$PANE_OUTPUT" | grep -q "running in the background"; then
      break
    fi
  done

  # Capture session URL — only match URLs NOT already in the prompt
  SESSION_URL=$(echo "$PANE_OUTPUT" | grep -o 'https://claude.ai/code/session_[^ ]*' | sort -u | while read -r url; do
    # Skip URLs that were in our prompt (from old comments)
    if ! echo "$PROMPT" | grep -q "$url"; then
      echo "$url"
    fi
  done | tail -1)

  if [ -n "$SESSION_URL" ]; then
    echo "  Session: $SESSION_URL"
    # Post session link to Linear ticket
    COMMENT_BODY="Claude is working on this. Follow along or take over here: $SESSION_URL

@Tom Lynch please allow sharing"
    MUTATION=$(jq -n --arg id "$ISSUE_ID" --arg body "$COMMENT_BODY" \
      '{query: "mutation($id: String!, $body: String!) { commentCreate(input: { issueId: $id, body: $body }) { success } }", variables: {id: $id, body: $body}}')
    curl -s -X POST "$LINEAR_API_URL" \
      -H "Content-Type: application/json" \
      -H "Authorization: $LINEAR_API_KEY" \
      -d "$MUTATION" > /dev/null
    echo "  Posted session link to $ISSUE_IDENT"

    # Add ai-in-progress label via MCP-style issueUpdate (need label ID, not name)
    # Label ID for ai-in-progress: cc9f2277-acab-4744-a6d0-104741dc8db7
    LABEL_MUTATION=$(jq -n --arg id "$ISSUE_ID" \
      '{query: "mutation($id: String!) { issueUpdate(id: $id, input: { labelIds: [\"cc9f2277-acab-4744-a6d0-104741dc8db7\"] }) { success } }", variables: {id: $id}}')
    curl -s -X POST "$LINEAR_API_URL" \
      -H "Content-Type: application/json" \
      -H "Authorization: $LINEAR_API_KEY" \
      -d "$LABEL_MUTATION" > /dev/null 2>&1 || true
    echo "  Added '$AI_LABEL_IN_PROGRESS' label to $ISSUE_IDENT"
  else
    echo "  Warning: couldn't capture session URL"
  fi

done

echo ""
echo "All tickets dispatched."
echo "List sessions: tmux list-sessions"
