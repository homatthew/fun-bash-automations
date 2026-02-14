---
name: ralph-plan
description: Generate a Ralph Wiggum PROMPT.md from an existing implementation plan in .claude/plans/
---

# Ralph Plan

Generate a PROMPT.md for the Ralph Wiggum loop from an existing implementation plan.

## Steps

1. **Find the plan file.** If the user didn't specify one:
   - List files in `.claude/plans/`
   - Ask the user to pick one

2. **Read the plan file** to understand the steps and scope.

3. **Create PROMPT.md** with this structure:
   ```markdown
   ## Task
   Execute the implementation plan in <plan-file-path>

   Read the plan file first, then work through it step by step.

   ## Completion criteria
   - All steps in the plan are implemented
   - All tests pass
   - Each step has its own commit with a descriptive message
   - Code compiles/lints cleanly

   ## Rules
   - Work through the plan one step at a time, in order
   - After completing each step, run the relevant tests
   - Commit after each passing step
   - If tests fail, fix the issue before moving to the next step
   - Do NOT skip steps or reorder them unless a step is explicitly marked optional
   - Do NOT modify files outside the project directory
   - When ALL steps are complete and all tests pass, output the exact text: RALPH_DONE
   ```

4. **Tell the user** to review PROMPT.md and run `ralph` when ready.

## Rules

- Do NOT create PROMPT.md if it already exists — tell the user to remove or edit it
- The plan file path in PROMPT.md must be relative to the project root
- Do NOT modify the plan file itself
