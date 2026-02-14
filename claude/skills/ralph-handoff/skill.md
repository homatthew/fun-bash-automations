---
name: ralph-handoff
description: Find the current plan and output the ralph command to execute it
---

# Ralph Handoff

Hand off the current plan to Ralph Wiggum for autonomous execution.

## Steps

1. Find the most recently modified plan file:
   - Use Glob to list `~/.claude/plans/*.md` (sorted by mtime, most recent first)
   - If no plans found, tell the user there are no plans to hand off

2. Show the user the plan file and the command to run:
   ```
   Plan: ~/.claude/plans/<plan-name>.md

   Run this to execute via Ralph:

     ralph ~/.claude/plans/<plan-name>.md
   ```

3. If `.ralphrc` does NOT exist in the project root, suggest creating one based on the project type, or mention that ralph will use default tool scoping.

## Rules

- Only suggest the single most recent plan (don't list all plans)
- If the user mentions a specific plan, use that instead of auto-detecting
- Don't modify any files — this is read-only / informational
