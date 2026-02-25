---
name: ralph-handoff
description: "Hand off a plan to Ralph Wiggum for autonomous execution. Trigger words: ralph, ralph it, hand off, hand this off."
---

# Ralph Handoff

Augment a plan for autonomous execution and hand it off to Ralph Wiggum.

Ralph runs without a human in the loop. The plan IS the only code reviewer. Every verification, every self-review checkpoint, every context boundary must be baked into the markdown — because no one will be there to catch drift.

## Steps

### 1. Find the plan

- Use Glob to list `~/.claude/plans/*.md` (sorted by mtime, most recent first)
- If the user mentioned a specific plan, use that instead
- If no plans found, tell the user there are no plans

### 2. Read the plan and audit its structure

Read the plan file. Check whether it has the required sections for autonomous execution. The plan MUST have all of these — if any are missing, you will add them in step 3:

**Required plan sections:**

- [ ] **Original Design Intent** — 2-4 sentences describing what this plan builds and WHY. This is the north star that every self-review checks against.
- [ ] **Session Management & Context Clearing** — Instructions for when to `/clear`, how to recover context after clearing, what commands to run on cold start.
- [ ] **Per-step Verification Checklist** — Every step must end with explicit verification commands (compile, test, lint) AND a self-review section.
- [ ] **Per-step Self-Review Gate** — Each step must include a self-review checklist that asks: "Does this match the original design intent? Did I only touch the files listed? Do the remaining steps still make sense?"
- [ ] **Context Checkpoint** — Between steps, a clear marker that says whether to `/clear` and what the next step touches (so the agent knows what context it needs).
- [ ] **Completion Signal** — Each step ends with the exact text the agent must output when done:
  - simple-ralph: `RALPH_STEP_DONE` per step, `RALPH_DONE` for the final step
  - full ralph: `RALPH_STORY_DONE` per story

### 3. Augment the plan

If the plan is missing required sections, **rewrite the plan file** to add them. Preserve all existing content — you are adding structure, not changing implementation details.

#### 3a. Add Original Design Intent (if missing)

Add this immediately after the plan title:

```markdown
## Original Design Intent

[2-4 sentences: what this builds, why it exists, what "done" looks like.
This section is referenced by every self-review gate below.]
```

Derive this from the plan's context/goal sections if they exist.

#### 3b. Add Session Management & Context Clearing (if missing)

Add this after the design intent:

```markdown
## Session Management & Context Clearing

**CRITICAL**: Each step below is a self-contained unit of work. After completing each step:
1. Run the verification checklist (must all pass)
2. Run the self-review gate (must all pass)
3. Commit with a descriptive message
4. Output RALPH_STEP_DONE (simple-ralph) or RALPH_STORY_DONE (full ralph)

**On session start / after context clear**: Run these commands to recover:
\```bash
cd <working-directory>
git log --oneline -10           # What's been committed?
cat <path-to-this-plan>         # Re-read the plan
\```
```

Fill in the actual working directory and plan path.

#### 3c. Add Verification Checklist to each step (if missing)

Every step must end with a verification block. If a step doesn't have one, add it:

```markdown
### Verification (Step N)
\```bash
# 1. Build/compile
<project-specific build command>

# 2. Run relevant tests
<project-specific test command>

# 3. Lint (if applicable)
<project-specific lint command>
\```
```

Use the project's actual build/test commands (check for `gradlew`, `pytest`, `npm test`, `cargo test`, etc. in the working directory).

#### 3d. Add Self-Review Gate to each step (if missing)

After the verification checklist, add:

```markdown
### Self-review before completing Step N
- [ ] Does this implementation match the **Original Design Intent**?
- [ ] Did I modify ONLY the files listed in this step?
- [ ] Read the verification checklists of remaining steps — does what I built here support what comes next?
- [ ] Would a code reviewer flag anything? (naming, error handling, edge cases, style)
- [ ] Are there any TODO/FIXME/HACK comments I introduced that should be resolved now?
```

The third bullet is the key insight: **use the future steps' verifications as a forward-looking code review**. If Step 3's verification says "test that the API returns 404 for missing resources", and you're currently on Step 2 building the API handler, your Step 2 self-review should ask "will my handler make Step 3's verification pass?"

#### 3e. Add Context Checkpoints between steps (if missing)

Between each step, add:

```markdown
---

### Context checkpoint
If context is large, this is a safe place to clear. The next step touches: [list key files/modules for next step].
```

### 4. Write the augmented plan

Write the enhanced plan back to the same path (`~/.claude/plans/<name>.md`). Tell the user what you added.

### 5. Show the execution commands

```
Plan: ~/.claude/plans/<plan-name>.md (augmented for autonomous execution)

# Full Ralph (TUI + PRD stories):
ralph ~/.claude/plans/<plan-name>.md

# Simple Ralph (bash, zero deps):
simple-ralph ~/.claude/plans/<plan-name>.md

# Simple Ralph with rich output (recommended):
simple-ralph --rich ~/.claude/plans/<plan-name>.md

# In a worktree (isolated):
simple-ralph --rich -w <slug> ~/.claude/plans/<plan-name>.md

# Or monitor separately (in another terminal):
rt                          # tail -f .ralph/output.log
ralph-watch                 # rich console version
```

### 6. Mention .ralphrc if missing

If `.ralphrc` does NOT exist in the project root:
- simple-ralph defaults to broad tools (`Edit Read Write Glob Grep Bash`)
- full ralph defaults to scoped bash (safer)
- `ralph init` creates a project-specific .ralphrc

## Rules

- Only suggest the single most recent plan (don't list all plans)
- If the user mentions a specific plan, use that instead of auto-detecting
- ALWAYS read and augment the plan — never hand off a plan without checking its structure
- Preserve all existing implementation content when augmenting
- The self-review gate is NOT optional — it replaces the human reviewer
- Use the project's ACTUAL build/test/lint commands, not generic placeholders
- Prefer simple-ralph for quick runs, full ralph for complex multi-story plans
