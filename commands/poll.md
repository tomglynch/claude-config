Find and work on Linear tickets tagged with @claude.

## Step 1: Find tickets

Run this curl command to search Linear for matching tickets:

```bash
source ~/.claude/scripts/linear-poller/config.sh
curl -s -X POST "$LINEAR_API_URL" \
  -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" \
  -d '{"query":"{ issues(filter: { comments: { body: { contains: \"@claude\" } }, state: { type: { in: [\"triage\", \"unstarted\", \"started\"] } }, labels: { every: { name: { neq: \"ai-in-progress\" } } } }) { nodes { id identifier title description state { name type } labels { nodes { name } } comments(filter: { body: { contains: \"@claude\" } }) { nodes { body createdAt user { name } } } } } }"}' | jq .
```

## Step 2: Show results

For each ticket found, display:
- Identifier and title
- Current status
- Who triggered it and what the @claude comment says (this is the prompt/instructions)
- Skip any with `ai-ready-for-review` label

If no tickets found, say so and stop.

## Step 3: For each ticket, ask the user

Ask: "Found X ticket(s). Which should I work on?" — show the list and let them pick.

## Step 4: Work on selected tickets

The **@claude comment is the prompt**. If someone writes `@claude please implement this` or `@claude do this in /qz/k8s-apps`, use that as the instructions. If the comment is just `@claude` with nothing else, use the ticket title and description as the task.

For each selected ticket:

1. Use Linear MCP to add the `ai-in-progress` label and post a comment: "Picking this up now."
2. Default repo is /qz/toocan-app — but if the @claude comment mentions a different repo path, use that instead.
3. If `--local` was passed as an argument:
   - Use the worktree-manager skill to create a worktree and launch an agent in a terminal
   - Pass the @claude comment as the task description
4. Otherwise (default):
   - Work on it right here in this session — read the codebase, implement, commit, push, create PR
   - When done, use Linear MCP to:
     - Remove `ai-in-progress` label
     - Add `ai-ready-for-review` label
     - Post a summary comment with PR link

Keep the user informed of progress throughout.
