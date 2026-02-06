# Copy to Clipboard

Copy Claude's last response to the clipboard as clean text.

## Triggers

- `/copy` - Copy the last response to clipboard

## Instructions

When the user invokes `/copy`:

1. Recall your most recent response (the text you output before this command)
2. Copy it to the system clipboard using the appropriate command for the platform:
   - **macOS**: `pbcopy`
   - **Linux**: `xclip -selection clipboard` or `xsel --clipboard`
   - **Windows/WSL**: `clip.exe`

3. Use printf piped to pbcopy:

```bash
printf '%s' 'your last response here' | pbcopy
```

For multi-line text, use `$'...'` syntax with `\n` for newlines, or encode the text properly.

4. Confirm to the user that the text was copied.

## Notes

- Strip any markdown formatting if the user asks for "plain text"
- If the last response was very long, confirm before copying
- If there's no previous response, let the user know
