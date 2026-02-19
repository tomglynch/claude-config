---
name: search-history
description: Search past Claude Code conversations across all projects. Use when user says "search history", "find conversation", "when did I", "search past chats", "recall", "did we discuss", "find where we talked about", "what did I do today/yesterday/friday/last week", "what did I work on", or any query about past Claude sessions.
---

# Search Claude Code History

Find past conversations — by keyword or by date. Show compact results and offer resume commands.

## Goal

Use **as few tokens as possible**. Search fast, show compact results.

## Data

- `~/.claude/history.jsonl` — one JSON line per user prompt. Fields: `display`, `timestamp` (ms), `project` (absolute path), `sessionId`
- `~/.claude/projects/<encoded-path>/<session-id>.jsonl` — full transcripts. First `type:"user"` entry has `cwd` field (exact working directory).

Path encoding: `/Users/tlynch/q/toocan-app` → `-Users-tlynch-q-toocan-app`

## Timezone

Timestamps in history.jsonl are Unix epoch (UTC). jq's `strftime` outputs UTC. **Always convert to local time** before displaying or filtering by date.

Get the local UTC offset in seconds at the start of the search:
```bash
TZ_OFFSET=$(date +%z | awk '{h=substr($0,1,3)+0; m=substr($0,4,2)+0; print (h*3600)+(m*60)}')
```

Then in all jq expressions, add the offset before formatting:
- `((.timestamp / 1000 + $tz) | strftime(...))` where `$tz` is passed via `--argjson tz $TZ_OFFSET`

This handles AEDT/AEST transitions automatically since `date +%z` reflects the current offset.

## Step 1: Detect Query Type

Parse the user's query into one of two modes:

### Date mode (triggers on time-based queries)
Detect phrases like: "today", "yesterday", "friday", "last week", "this week", "last month", "on monday", "feb 10", "2026-02-13", "the past 3 days"

Resolve to a date range:
- "today" → today's date
- "yesterday" → yesterday's date
- Day names ("friday", "monday") → most recent occurrence of that day
- "last week" → Monday–Sunday of the previous week
- "this week" → Monday of current week through today
- "last month" → 1st–last of previous month

Use the current date from context (CLAUDE.md says today's date).

### Keyword mode (triggers on everything else)
Detect search terms like: "find conversation about X", "when did I discuss X", "recall X", "colour changes", "auth bug"

### Combined mode
Both can apply: "what did I work on friday in toocan-app" → date filter + project filter. "conversations about auth last week" → date filter + keyword filter.

## Step 2: Run the search script

The script `~/.claude/skills/search-history/search-history.sh` handles all searching. It accepts:

```
--start YYYY-MM-DD    Start date (inclusive)
--end YYYY-MM-DD      End date (inclusive)
--keyword TERM        Keyword to grep for
--project FILTER      Project name filter (case-insensitive regex)
```

### Examples

Date mode:
```bash
~/.claude/skills/search-history/search-history.sh --start 2026-02-13 --end 2026-02-13
```

Keyword mode:
```bash
~/.claude/skills/search-history/search-history.sh --keyword "auth bug"
```

Combined (keyword + date + project):
```bash
~/.claude/skills/search-history/search-history.sh --start 2026-02-10 --end 2026-02-14 --keyword "deploy" --project "toocan"
```

The script outputs JSON objects (one per session) with fields: `session`, `project`, `project_full`, `time`, `date`, `first_msg`, `count`. Format these into the compact table shown in Output Formats below.

The script supports `--deep` to force deep search even when history.jsonl has results:

```bash
~/.claude/skills/search-history/search-history.sh --keyword "in-call pods" --deep
```

When the keyword isn't found in history.jsonl, the script automatically falls back to deep searching transcript files. Deep search results include the `cwd` field extracted from the transcript, and a `"source": "deep"` marker.

## Step 3: Building resume commands

**CRITICAL: NEVER decode the encoded project path manually.** The encoding is lossy — hyphens in directory names (e.g. `worktrees-qz`) are indistinguishable from path separators. Always get the real path from one of:

1. The `project_full` field (from history.jsonl results) — this is the original project path
2. The `cwd` field (from deep search results or transcript files) — this is the exact working directory

To get `cwd` from a transcript when you have the encoded directory and session ID:
```bash
jq -r 'select(.cwd) | .cwd' ~/.claude/projects/<encoded-dir>/<session-id>.jsonl | head -1
```

Use `cwd` (not `project_full`) for resume commands, since worktree sessions have a different cwd than the project root.

## Output Formats

### Date mode — daily summary

Group sessions by project, show as compact table:

```
Friday 2026-02-13 — 14 sessions:

 1. 11:01  .claude         "in my last 10 conversations, was there one..."
 2. 11:10  PRO-504         "apparently we can ask google engineers to..."
 3. 14:29  toocan-app      "new worktree for PRO-556"
 4. 14:30  PRO-556         "Read and execute the task described in..."
 ...
```

For multi-day ranges (e.g. "last week"), group by day with a header per day.

After showing the list, ask: "Want to resume any of these? Or want me to include git commits for more detail?"

### Keyword mode — search results + resume

```
Found 3 sessions:

1. 2026-02-10 14:30 | toocan-app | "fix the auth redirect bug when..."
2. 2026-02-08 09:15 | infra | "update k8s deployment config..."
3. 2026-01-28 16:00 | toocan-app | "add websocket reconnection..."
```

Then output resume command for best match (or ask user to pick), using `cwd` from the result:

```
cd ~/q/toocan-app && claude -r abc12345-def6-7890-abcd-ef1234567890
```

Use `~` relative paths. For deep search results, `cwd` is already in the JSON output. For history.jsonl-only results that need a resume path, read `cwd` from the transcript file (see Step 3).

## Depth Levels (opt-in)

By default, only use history.jsonl (Level 1). Offer deeper levels if the user asks:

- **Level 1** (default): `history.jsonl` only — session list with first messages. ~500 tokens.
- **Level 2** (on request: "include git commits"): Also run `git log --oneline --after=<start> --before=<end+1>` across known repos (check `~/.claude/projects/` for encoded paths → decode to repo paths). ~2k tokens.
- **Level 3** (on request: "tell me more about session 3"): Read that session's transcript for a richer summary. Variable tokens.

## Rules

- Do NOT read full transcript contents unless the user explicitly asks for detail on a specific session.
- Do NOT output jq/grep results raw — always format into the compact list.
- Prefer `grep | jq` over pure `jq` (faster on large files).
- If the user says "recent" with no search term, show the last ~10 sessions grouped by day.
- Always resolve relative day names against the current date from context.
- For date ranges, use inclusive bounds on both ends.
