#!/usr/bin/env bash
# WorktreeCreate hook — creates the worktree and runs newt build for Netflix Gradle repos.
# stdout: absolute path to the created worktree (required by Claude Code)
# stderr: all other output (build logs, errors)

set -euo pipefail

input=$(cat)
name=$(echo "$input" | jq -r '.name')
cwd=$(echo "$input" | jq -r '.cwd')

worktree_path="$cwd/.claude/worktrees/$name"

cd "$cwd"
git worktree add "$worktree_path" -b "$name" >&2

remote=$(git remote get-url origin 2>/dev/null || echo "")
project=$(basename "$(git rev-parse --show-toplevel)")

if echo "$project" | grep -qi "service-capacity-model"; then
  echo "service-capacity-model detected — creating tox venv (no tests)..." >&2
  cd "$worktree_path"
  tox --notest -e py311 >&2 || echo "Warning: tox venv setup failed, worktree still created" >&2
elif echo "$remote" | grep -qi "netflix" && [ -f "gradlew" ]; then
  echo "Netflix Gradle repo detected — running newt exec ./gradlew build..." >&2
  cd "$worktree_path"
  newt exec ./gradlew build >&2 || echo "Warning: build failed, worktree still created" >&2
fi

echo "$worktree_path"
