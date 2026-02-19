#!/bin/bash
# Search Claude Code history by date range and/or keyword
# Usage: search-history.sh [--start DATE] [--end DATE] [--keyword TERM] [--project FILTER] [--deep]

HISTORY_FILE="$HOME/.claude/history.jsonl"
PROJECTS_DIR="$HOME/.claude/projects"
TZ_OFFSET=$(date +%z | awk '{h=substr($0,1,3)+0; m=substr($0,4,2)+0; print (h*3600)+(m*60)}')

START=""
END=""
KEYWORD=""
PROJECT=""
DEEP=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --start) START="$2"; shift 2 ;;
    --end) END="$2"; shift 2 ;;
    --keyword) KEYWORD="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --deep) DEEP=true; shift ;;
    *) shift ;;
  esac
done

# Build jq filter
FILTER="."

if [[ -n "$START" && -n "$END" ]]; then
  FILTER="select(((.timestamp / 1000 + $TZ_OFFSET) | strftime(\"%Y-%m-%d\")) >= \"$START\" and ((.timestamp / 1000 + $TZ_OFFSET) | strftime(\"%Y-%m-%d\")) <= \"$END\")"
fi

if [[ -n "$PROJECT" ]]; then
  FILTER="$FILTER | select(.project | test(\"$PROJECT\"; \"i\"))"
fi

# Extract cwd from a transcript file (reads the first entry with a cwd field)
get_cwd() {
  local transcript_file="$1"
  jq -r 'select(.cwd) | .cwd' "$transcript_file" 2>/dev/null | head -1
}

# Primary search: history.jsonl
run_history_search() {
  local results
  if [[ -n "$KEYWORD" ]]; then
    results=$(grep -i "$KEYWORD" "$HISTORY_FILE" | jq -s --argjson tz "$TZ_OFFSET" "
      [.[] | $FILTER] | group_by(.sessionId) | map({
        session: .[0].sessionId,
        project: (.[0].project | split(\"/\") | last),
        project_full: .[0].project,
        time: ((.[0].timestamp / 1000 + \$tz) | strftime(\"%H:%M\")),
        date: ((.[0].timestamp / 1000 + \$tz) | strftime(\"%Y-%m-%d\")),
        first_msg: (sort_by(.timestamp) | .[0].display | .[0:80]),
        count: length
      }) | sort_by(.date + .time) | .[]
    " 2>/dev/null)
  else
    results=$(jq -c "$FILTER" "$HISTORY_FILE" | jq -s --argjson tz "$TZ_OFFSET" '
      group_by(.sessionId) | map({
        session: .[0].sessionId,
        project: (.[0].project | split("/") | last),
        project_full: .[0].project,
        time: ((.[0].timestamp / 1000 + $tz) | strftime("%H:%M")),
        date: ((.[0].timestamp / 1000 + $tz) | strftime("%Y-%m-%d")),
        first_msg: (sort_by(.timestamp) | .[0].display | .[0:80]),
        count: length
      }) | sort_by(.date + .time) | .[]
    ' 2>/dev/null)
  fi
  echo "$results"
}

# Deep search: grep transcript files for keyword
run_deep_search() {
  local keyword="$1"
  local files
  files=$(grep -rli "$keyword" "$PROJECTS_DIR"/*/*.jsonl 2>/dev/null | head -10)

  if [[ -z "$files" ]]; then
    return
  fi

  while IFS= read -r file; do
    local session_id
    session_id=$(basename "$file" .jsonl)
    local cwd
    cwd=$(get_cwd "$file")
    local project_name
    project_name=$(basename "$cwd" 2>/dev/null)
    # Get first user message from transcript
    local first_msg
    first_msg=$(jq -r 'select(.type=="user") | .message // .display // "" | if type == "object" then .content // "" elif type == "array" then .[0].content // .[0].text // "" else tostring end | .[0:80]' "$file" 2>/dev/null | head -1)
    # Get timestamp from the file modification time as fallback
    local file_date
    file_date=$(stat -f "%Sm" -t "%Y-%m-%d" "$file" 2>/dev/null || stat --format="%y" "$file" 2>/dev/null | cut -d' ' -f1)
    local file_time
    file_time=$(stat -f "%Sm" -t "%H:%M" "$file" 2>/dev/null || stat --format="%y" "$file" 2>/dev/null | cut -d' ' -f2 | cut -d: -f1-2)

    jq -n \
      --arg session "$session_id" \
      --arg project "$project_name" \
      --arg cwd "$cwd" \
      --arg time "$file_time" \
      --arg date "$file_date" \
      --arg first_msg "$first_msg" \
      '{session: $session, project: $project, project_full: $cwd, cwd: $cwd, time: $time, date: $date, first_msg: $first_msg, count: 1, source: "deep"}'
  done <<< "$files"
}

# Run primary search
results=$(run_history_search)

# If keyword search returned no results (or --deep flag), try deep search
if [[ -n "$KEYWORD" && (-z "$results" || "$DEEP" == true) ]]; then
  deep_results=$(run_deep_search "$KEYWORD")
  if [[ -n "$deep_results" ]]; then
    if [[ -z "$results" ]]; then
      results="$deep_results"
    else
      # Merge: append deep results, deduplicate by session ID
      results=$(echo -e "${results}\n${deep_results}" | jq -s 'group_by(.session) | map(.[0]) | sort_by(.date + .time) | .[]')
    fi
  fi
fi

echo "$results"
