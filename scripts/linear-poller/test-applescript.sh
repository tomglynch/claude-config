#!/bin/bash
# Test: AppleScript types & then arrow right twice, then space + prompt

osascript <<EOF
tell application "System Events"
    -- Type just &
    keystroke "&"
    delay 0.5

    -- Press right arrow twice
    key code 124
    delay 0.3
    key code 124
    delay 0.3

    -- Type space + prompt
    keystroke " test 8.0.0"
    delay 1

    -- Press Return
    key code 36
end tell
EOF

echo "Done."
