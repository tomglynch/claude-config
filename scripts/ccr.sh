#!/usr/bin/env bash
# ccr - Claude Code Resume: list recent sessions, pick one to resume
set -euo pipefail

LIMIT="${1:-10}"

# Python handles all parsing AND rendering via a temp file for selection data
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

python3 - "$LIMIT" "$tmpfile" << 'PYEOF'
import os, json, glob, sys

limit = int(sys.argv[1])
tmpfile = sys.argv[2]
projects_dir = os.path.expanduser("~/.claude/projects")
home = os.path.expanduser("~")

if not os.path.isdir(projects_dir):
    print("No Claude sessions found.")
    sys.exit(1)

# Find session files sorted by mtime
files = []
for f in glob.glob(os.path.join(projects_dir, "*", "*.jsonl")):
    try:
        files.append((os.path.getmtime(f), f))
    except OSError:
        pass

files.sort(reverse=True)
files = files[:limit * 2]  # grab extra since some may have no messages

def decode_dir(encoded_dir):
    """Reconstruct real path from encoded directory name."""
    raw = encoded_dir.split("-")
    rebuilt = ""
    i = 1  # skip leading empty from first dash
    while i < len(raw):
        seg = raw[i]
        if seg == "":
            # double-dash means dot-prefixed component
            i += 1
            seg = "." + raw[i] if i < len(raw) else ""
            if not seg:
                break
        if not rebuilt:
            rebuilt = seg
        else:
            slash = rebuilt + "/" + seg
            dash = rebuilt + "-" + seg
            if os.path.isdir("/" + slash):
                rebuilt = slash
            elif os.path.isdir("/" + dash):
                rebuilt = dash
            else:
                rebuilt = slash
        i += 1
    return "/" + rebuilt

sessions = []
for mtime, filepath in files:
    if len(sessions) >= limit:
        break
    session_id = os.path.basename(filepath).replace(".jsonl", "")
    encoded = os.path.basename(os.path.dirname(filepath))
    real_dir = decode_dir(encoded)
    short_dir = real_dir.replace(home, "~")

    first_msg = first_ts = last_msg = last_ts = ""
    try:
        with open(filepath) as fh:
            for line in fh:
                try:
                    d = json.loads(line)
                    if d.get("type") == "user":
                        msg = d.get("message", {}).get("content", "")
                        if isinstance(msg, list):
                            msg = " ".join(
                                b.get("text", "") for b in msg if b.get("type") == "text"
                            )
                        msg = " ".join(msg.split())
                        ts = d.get("timestamp", "")[:16].replace("T", " ")
                        if not first_msg and msg.strip():
                            first_msg = msg
                            first_ts = ts
                        if msg.strip():
                            last_msg = msg
                            last_ts = ts
                except (json.JSONDecodeError, KeyError):
                    pass
    except Exception:
        continue

    if not first_msg:
        continue

    sessions.append({
        "sid": session_id,
        "dir": short_dir,
        "real_dir": real_dir,
        "first_ts": first_ts,
        "first_msg": first_msg,
        "last_ts": last_ts,
        "last_msg": last_msg,
    })

if not sessions:
    print("No sessions found.")
    sys.exit(1)

# Write lookup file: one line per session "session_id|real_dir"
with open(tmpfile, "w") as f:
    for s in sessions:
        f.write(f"{s['sid']}|{s['real_dir']}\n")

# Get terminal width
try:
    cols = os.get_terminal_size().columns
except Exception:
    cols = 100

msg_width = cols - 8  # leave room for number + padding

# Print formatted list
for i, s in enumerate(sessions):
    num = f" {i + 1:>2}) "

    # Line 1: directory + first message
    first_trunc = s["first_msg"][:msg_width] if len(s["first_msg"]) > msg_width else s["first_msg"]
    print(f"\033[1;33m{num}\033[0;36m{s['dir']}\033[0m")
    print(f"      \033[2m{s['first_ts']}\033[0m  {first_trunc}")

    # Line 2: last message (if different)
    if s["last_msg"] != s["first_msg"] and s["last_msg"]:
        last_trunc = s["last_msg"][:msg_width] if len(s["last_msg"]) > msg_width else s["last_msg"]
        print(f"      \033[2m{s['last_ts']}\033[0m  {last_trunc}")

    print()
PYEOF

# Check if python found sessions
if [[ ! -s "$tmpfile" ]]; then
  exit 1
fi

count=$(wc -l < "$tmpfile" | tr -d ' ')

# Prompt for selection
printf '\033[2m  m) show more...\033[0m\n\n'
printf '\033[1mEnter number to resume (m for more, q to quit): \033[0m'
read -r choice

case "$choice" in
  q|Q|"") exit 0 ;;
  m|M) exec bash "$0" "30" ;;
  *[!0-9]*) echo "Invalid selection."; exit 1 ;;
esac

if (( choice < 1 || choice > count )); then
  echo "Invalid selection (1-$count)."
  exit 1
fi

# Read the selected session
line=$(sed -n "${choice}p" "$tmpfile")
sid="${line%%|*}"
rdir="${line#*|}"

if [[ -d "$rdir" ]]; then
  printf 'Resuming in %s...\n' "$rdir"
  cd "$rdir"
fi
exec claude --resume "$sid"
