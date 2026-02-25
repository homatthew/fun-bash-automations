---
name: ralph-handoff
description: "Hand off a plan to Ralph Wiggum for autonomous execution. Trigger words: ralph, ralph it, hand off, hand this off."
---

# Ralph Handoff

Hand off the current plan to Ralph Wiggum for autonomous execution.

## Steps

1. Find the most recently modified plan file:
   - Use Glob to list `~/.claude/plans/*.md` (sorted by mtime, most recent first)
   - If no plans found, tell the user there are no plans to hand off

2. Show the user the plan file and commands to run:
   ```
   Plan: ~/.claude/plans/<plan-name>.md

   # Full Ralph (TUI + PRD stories):
   ralph ~/.claude/plans/<plan-name>.md

   # Simple Ralph (bash, zero deps, easy to tail):
   simple-ralph ~/.claude/plans/<plan-name>.md

   # In a worktree (isolated):
   simple-ralph -w <slug> ~/.claude/plans/<plan-name>.md

   # Monitor (in another terminal):
   rt                          # tail -f .ralph/output.log
   ralph-watch                 # rich console version
   ```

3. If `.ralphrc` does NOT exist in the project root, mention that:
   - simple-ralph defaults to broad tools (`Edit Read Write Glob Grep Bash`)
   - full ralph defaults to scoped bash (safer)
   - `ralph init` creates a project-specific .ralphrc

## Rules

- Only suggest the single most recent plan (don't list all plans)
- If the user mentions a specific plan, use that instead of auto-detecting
- Don't modify any files — this is read-only / informational
- Prefer simple-ralph for quick runs, full ralph for complex multi-story plans
