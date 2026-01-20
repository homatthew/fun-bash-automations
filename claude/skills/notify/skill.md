---
name: notify
description: Send a macOS notification to alert the user with context about what's ready
---

# Notify User

Send a desktop notification with sound to alert the user.

## Notification Types

| Type | When to Use | Sound |
|------|-------------|-------|
| `done` | Task completed successfully, no action needed | Glass |
| `review` | Work ready for user to review/approve | Ping |
| `blocked` | Need user input or permission to continue | Submarine |

## Command Template

```bash
# Pick the appropriate sound based on notification type
SOUND="Glass"      # done - task complete
SOUND="Ping"       # review - ready for review
SOUND="Submarine"  # blocked - need input

terminal-notifier \
  -title "Claude Code" \
  -subtitle "$(basename "$PWD")" \
  -message "<YOUR_SUMMARY_HERE>" \
  -sound "$SOUND" \
  -group "claude-$(basename "$PWD")" \
  -activate com.mitchellh.ghostty
```

## Examples

### Task Complete (done)
```bash
terminal-notifier -title "Claude Code" -subtitle "$(basename "$PWD")" -message "Auth feature complete" -sound Glass -group "claude-$(basename "$PWD")" -activate com.mitchellh.ghostty
```

### Ready for Review (review)
```bash
terminal-notifier -title "Claude Code" -subtitle "$(basename "$PWD")" -message "PR ready for review" -sound Ping -group "claude-$(basename "$PWD")" -activate com.mitchellh.ghostty
```

### Blocked/Need Input (blocked)
```bash
terminal-notifier -title "Claude Code" -subtitle "$(basename "$PWD")" -message "Need permission to delete files" -sound Submarine -group "claude-$(basename "$PWD")" -activate com.mitchellh.ghostty
```

## After Sending

Respond with a brief confirmation. Do NOT ask follow-up questions after notifying - the user will return when ready.
