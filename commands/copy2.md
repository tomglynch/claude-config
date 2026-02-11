Copy your most recent response to the clipboard as clean text.

1. Recall the text you output immediately before this command was invoked
2. Copy it to the system clipboard:
   - **macOS**: `printf '%s' '...' | pbcopy`
   - **Linux**: `xclip -selection clipboard` or `xsel --clipboard`
   - **Windows/WSL**: `clip.exe`
3. For multi-line text, use a heredoc or properly escaped string
4. Strip markdown formatting unless the user asks to keep it
5. If the last response was very long, confirm before copying
6. Confirm to the user that the text was copied
