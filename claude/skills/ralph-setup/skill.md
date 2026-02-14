---
name: ralph-setup
description: Initialize Ralph Wiggum autonomous loop in the current project. Creates .ralphrc, PROMPT.md, and adds gitignore entries.
---

# Ralph Setup

Initialize the current project for Ralph Wiggum — the autonomous Claude Code loop.

## Steps

1. **Check .gitignore** for Ralph artifacts. Add these if missing:
   ```
   .ralphrc
   .ralph/
   PROMPT.md
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

3. **Create PROMPT.md** with this template:
   ```markdown
   ## Task
   <!-- Describe what you want to accomplish -->

   ## Completion criteria
   - [ ] All tests pass
   - [ ] Code compiles/lints cleanly
   - [ ] Each logical change is committed separately

   ## Rules
   - Work incrementally: implement one thing, test it, commit it, move on
   - Run tests after each change
   - Commit after each passing step with a descriptive message
   - If tests fail, fix the issue before moving to the next step
   - Do NOT modify files outside the project directory
   - When ALL completion criteria are met, output the exact text: RALPH_DONE
   ```

4. **Tell the user** what was created and the next steps:
   - Edit PROMPT.md to describe their task and completion criteria
   - Run `ralph` in the terminal to start the loop
   - Review logs in `.ralph/` after the run

## Rules

- Do NOT create PROMPT.md if it already exists — tell the user to remove or edit it
- Do NOT create .ralphrc if it already exists — tell the user to edit it directly
- Always add gitignore entries even if the other files already exist
