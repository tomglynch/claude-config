# Global Claude Code Instructions

## Communication
- Be concise. Skip unnecessary explanations.
- When showing file paths (worktrees, Claude conversations, etc.), use paths relative to `~` (home dir). User is already in `/Users/tlynch/`.

## Package Managers
- Node: Use pnpm (not npm/npx)
- Python: Use uv (not pip)

## Docker
Read-only commands only (ps, images, logs, inspect, stats). User manages containers manually.

## Git
- If a commit is made and then a fix to it is applied, if it would make sense to --amend --no-edit the commit, ask me if you can do this - i'll probably say yes.
- Don't force push unless asked.
- Prefer specific file staging over `git add -A`.
- Before starting work on an existing branch, remind me to `git pull` if there's a remote tracking branch.

## Searching Past Conversations
- Claude Code stores conversation history in `~/.claude/`. The main transcript log is `history.jsonl`, and per-project session transcripts (JSONL files) live under `projects/<encoded-project-path>/`. You can grep these files to find past conversations, tool calls, code snippets, or decisions from previous sessions.

## MCP Servers
When adding MCP servers, mention `--scope user` for global availability.
