#!/bin/bash
# Activate a specific iTerm2 session by GUID, switching Spaces if needed,
# then double-flash the background to make it visually obvious.
set -e

SESSION_GUID="$1"
FLASH_COLOR="4a3a00"
BG_COLOR="2d2d3d"

if [ -z "$SESSION_GUID" ]; then
    exit 1
fi

TTY_PATH=$(osascript <<EOF
tell application "iTerm2"
    set targetTTY to ""
    set targetWindow to missing value
    repeat with w in windows
        tell w
            repeat with t in tabs
                tell t
                    repeat with s in sessions
                        tell s
                            if unique id contains "$SESSION_GUID" then
                                select t
                                select
                                set targetTTY to tty
                                set targetWindow to w
                            end if
                        end tell
                    end repeat
                end tell
            end repeat
        end tell
    end repeat
    if targetWindow is not missing value then
        set index of targetWindow to 1
    end if
    activate
    return targetTTY
end tell
EOF
)

# Double flash: wait, flash, pause, flash
if [ -n "$TTY_PATH" ]; then
    sleep 0.2
    printf '\033]1337;SetColors=bg=%s\007' "$FLASH_COLOR" > "$TTY_PATH"
    sleep 0.15
    printf '\033]1337;SetColors=bg=%s\007' "$BG_COLOR" > "$TTY_PATH"
    sleep 0.5
    printf '\033]1337;SetColors=bg=%s\007' "$FLASH_COLOR" > "$TTY_PATH"
    sleep 0.15
    printf '\033]1337;SetColors=bg=%s\007' "$BG_COLOR" > "$TTY_PATH"
fi
