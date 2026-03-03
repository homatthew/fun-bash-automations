---
name: ralph-run
description: "Export the current plan and generate the command to run it with simple-ralph. Use when you want to hand off a plan for autonomous execution."
---

# Ralph Run — Plan Export & Execute

Export the current plan and output the command to run it autonomously.

## Steps

1. **Find the plan file:**
   - Use Glob to list `~/.claude/plans/*.md` (sorted by mtime, most recent first)
   - If the user mentioned a specific plan, use that instead
   - If no plans found, tell the user there are no plans

2. **Determine execution mode** based on context:

   **Option A: Run in current directory (default)**
   ```
   simple-ralph ~/.claude/plans/<plan>.md
   ```

   **Option B: Run in a worktree (isolated)**
   ```
   simple-ralph -w <slug> ~/.claude/plans/<plan>.md
   ```
   Where `<slug>` is derived from the plan filename (e.g., `refactor-auth.md` → `refactor-auth`).

3. **Output the command block** with monitoring instructions:
   ```
   # Execute:
   simple-ralph [-w <slug>] ~/.claude/plans/<plan>.md

   # Monitor (in another terminal):
   rt                          # shell function (tail -f)
   ralph-watch                 # rich console
   tail -f .ralph/output.log   # raw

   # Status:
   ralph-status
   ```

4. **If `.ralphrc` is missing** in the target directory, mention it:
   - Defaults to `Edit Read Write Glob Grep Bash` (broad)
   - Create `.ralphrc` manually if tighter tool scoping is desired

## Rules

- Don't execute the plan — this is informational only
- Use `-w` worktree mode if the plan would modify the current repo and isolation is desired
- Always show the monitoring commands — that's the whole point
