# Claude Code Config

Shared [Claude Code](https://docs.anthropic.com/en/docs/claude-code) configuration — global instructions, skills, commands, and permissions.

## Setup

```bash
git clone git@github.com:<your-org>/claude-code-config.git ~/.claude
brew install jq gh
```

Restart Claude Code after cloning.

## What's included

| File / Directory | Purpose |
| --- | --- |
| `CLAUDE.md` | Global instructions applied to every session (package managers, git conventions, etc.) |
| `settings.json` | Pre-approved permissions, session hooks (iTerm2 bg color), custom status line |
| `commands/` | Custom slash commands (`/copy2`) |
| `scripts/` | Shared helper scripts (worktree-aware app opener) |
| `skills/` | Skills that activate on natural language — see below |

## Skills

| Skill | Trigger examples | Description |
| --- | --- | --- |
| [worktree-manager](skills/worktree-manager/) | "create worktree for X", "worktree status", "cleanup worktrees" | Full git worktree lifecycle with port allocation, dep install, and agent launch |
| vscode | `/v` | Open cwd or matching worktree in VS Code |
| iterm2 | `/it` | Open cwd or matching worktree in iTerm2 |
| finder | `/f` | Open cwd or matching worktree in Finder |
| copy | `/copy` | Copy last response to clipboard |

## Plugins

Plugins are gitignored (they auto-update independently). Install them with `/install-plugin`:

| Plugin | Marketplace | What it does | Install |
| --- | --- | --- | --- |
| [compound-engineering](https://github.com/EveryInc/compound-engineering-plugin) | every-marketplace | 28 agents, 24 commands, 15 skills for code review, research, design, and workflow automation | `/install-plugin compound-engineering@every-marketplace` |
| [ralph-loop](https://github.com/anthropics/claude-plugins-official) | claude-plugins-official | Runs Claude in a while-true loop with the same prompt until task completion (the "Ralph Wiggum technique") | `/install-plugin ralph-loop` |

To add the Every marketplace first: `/install-marketplace https://github.com/EveryInc/compound-engineering-plugin.git every-marketplace`

The official marketplace (`claude-plugins-official`) is available by default.

## Customising

- **Global instructions**: Edit `CLAUDE.md`
- **Permissions**: Add tool patterns to `settings.json` → `permissions.allow`
- **Worktree manager**: Edit `skills/worktree-manager/config.json` (terminal, shell, ports, claude command). The launch agent script is designed for iTerm2 — if you use a different terminal, ask Claude to update `skills/worktree-manager/scripts/launch-agent.sh` for your setup.
- **Per-project instructions**: Use a `CLAUDE.md` in that project's root instead
