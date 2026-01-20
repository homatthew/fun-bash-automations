#!/bin/bash
# Claude Code completion notification
# Shows which project finished in the notification

# Read the hook input (contains session_id, transcript_path, etc.)
input=$(cat)

# Get project name from current directory
project=$(basename "$PWD")

# Send notification with project context
terminal-notifier \
  -title "Claude Code" \
  -subtitle "$project" \
  -message "Ready for review" \
  -sound Hero \
  -group "claude-$project" \
  -activate com.microsoft.VSCode
