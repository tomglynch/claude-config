#!/bin/bash
# Test: Send & as individual keystroke, let TUI detect background mode

SESSION="claude-test"

tmux kill-session -t "$SESSION" 2>/dev/null
tmux new-session -d -s "$SESSION" -c "$HOME/qz/toocan-app" "claude"

# Wait for claude to fully load
sleep 6

# Send & as a single keystroke (no -l flag)
tmux send-keys -t "$SESSION" "&"
sleep 3

# Send space
tmux send-keys -t "$SESSION" " "
sleep 1

# Send prompt one char at a time
for char in w h a t " " i s " " 2 + 2; do
  tmux send-keys -t "$SESSION" -l "$char"
  sleep 0.05
done
sleep 1

# Submit
tmux send-keys -t "$SESSION" Enter

echo "Sent. Attach with: tmux attach -t $SESSION"
