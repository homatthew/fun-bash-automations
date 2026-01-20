#!/bin/bash
# Claude Code status line: shows git branch and context remaining

input=$(cat)

# Parse JSON input
MODEL=$(echo "$input" | jq -r '.model.display_name // "Claude"')
REMAINING=$(echo "$input" | jq -r '.context_window.remaining_percentage // 100' | cut -d. -f1)

# Try multiple directory fields - cwd seems most reliable
CWD=$(echo "$input" | jq -r '.cwd // .workspace.current_dir // .workspace.project_dir // ""')

# Get git branch - use CWD if set, otherwise current directory
BRANCH=""
if [ -n "$CWD" ] && [ -d "$CWD" ]; then
    BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null)
else
    BRANCH=$(git branch --show-current 2>/dev/null)
fi

# Check if we're in a worktree (path contains /worktrees/)
WORKTREE=""
if [[ "$CWD" == *"/worktrees/"* ]]; then
    WORKTREE=$(basename "$CWD")
fi

# Build status line
if [ -n "$BRANCH" ]; then
    if [ -n "$WORKTREE" ] && [ "$WORKTREE" != "mho-${BRANCH#mho/}" ]; then
        echo "[$MODEL] $BRANCH ($WORKTREE) | ${REMAINING}% left"
    else
        echo "[$MODEL] $BRANCH | ${REMAINING}% left"
    fi
else
    echo "[$MODEL] ${REMAINING}% left"
fi
