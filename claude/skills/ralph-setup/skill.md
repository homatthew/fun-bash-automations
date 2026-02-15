---
name: ralph-setup
description: Initialize Ralph Wiggum autonomous loop in the current project. Creates .ralphrc with scoped tool permissions.
---

# Ralph Setup

Initialize the current project for Ralph Wiggum — the autonomous Claude Code loop.

## Steps

1. **Check .gitignore** for Ralph artifacts. Add these if missing:
   ```
   .ralphrc
   .ralph/
   ```

2. **Detect project type** and create `.ralphrc` with appropriate tool permissions:

   **Python** (pyproject.toml, setup.py, tox.ini):
   ```bash
   RALPH_TOOLS="Edit Read Write Glob Grep Bash(git add:*) Bash(git commit:*) Bash(git status:*) Bash(git diff:*) Bash(git log:*) Bash(pytest:*) Bash(newt:*) Bash(tox:*)"
   RALPH_MAX_ITER=10
   ```

   **Java/Gradle** (build.gradle, build.gradle.kts, gradlew):
   ```bash
   RALPH_TOOLS="Edit Read Write Glob Grep Bash(git add:*) Bash(git commit:*) Bash(git status:*) Bash(git diff:*) Bash(git log:*) Bash(./gradlew:*) Bash(newt:*)"
   RALPH_MAX_ITER=15
   ```

   **Node.js** (package.json):
   ```bash
   RALPH_TOOLS="Edit Read Write Glob Grep Bash(git add:*) Bash(git commit:*) Bash(git status:*) Bash(git diff:*) Bash(git log:*) Bash(npm test:*) Bash(npm run build:*) Bash(npm run lint:*)"
   RALPH_MAX_ITER=10
   ```

   **NEVER include these (shell escapes):** `Bash(python:*)`, `Bash(node:*)`, `Bash(npm:*)` (broad), `Bash(npx:*)`, `Bash(make:*)`

   If no project type is detected, skip `.ralphrc` and note that the global defaults will be used.

3. **Tell the user** what was created and how to use ralph:
   - Plans live in `~/.claude/plans/` (Claude Code's global default)
   - `ralph` — interactive plan picker
   - `ralph run ~/.claude/plans/<plan-name>.md` — execute a plan directly
   - `ralph <plan-name>.md` — shortcut for `ralph run`
   - `ralph run -n 20 <plan.md>` — override max iterations
   - `ralph inject "focus on tests"` — queue directive for next iteration
   - `ralph status` — check session state and progress
   - `ralph logs` — browse iteration logs
   - Review logs in `.ralph/` after the run

## Rules

- Do NOT create .ralphrc if it already exists — tell the user to edit it directly
- Always add gitignore entries even if the other files already exist
- Do NOT create PROMPT.md — ralph now accepts plan files directly
- ralph is a Python CLI installed via `uv tool install -e ~/repos/fun-bash-automations/ralph`
