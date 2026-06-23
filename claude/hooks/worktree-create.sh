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
# --no-track is load-bearing: it ensures the new branch never adopts an
# upstream (e.g. origin/main) from the base it is cut from. This is part of the
# structural guarantee that a yolo branch (mho-yolo/*) — or any worktree branch —
# cannot acquire a base ref as upstream and later push to it. The bash-safety
# guard's check_branch_tracking enforces the same rule on hand-run git commands;
# this keeps the hook-created worktrees consistent with it. Covered by a pen test.
git worktree add --no-track -b "$name" "$worktree_path" >&2

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
