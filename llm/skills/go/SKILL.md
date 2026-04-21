---
name: go
description: "Finish the task end-to-end without laziness. Trigger when the user says /go or clearly wants plan-first execution, real verification, simplification, and PR completion."
---

# /go

`/go` means: finish the job for real.

Do not stop at analysis. Do not leave "next steps" unless blocked. Do not claim code works unless you ran the checks.

## What `/go` requires

1. Make or repair the plan first.
2. Execute one step at a time.
3. Verify each step before moving on.
4. Run `/simplify` after the code works.
5. Re-run the relevant verification.
6. Commit, push, and open/update a PR at the end.

`/go` is explicit permission to finish the delivery workflow for the current task, but it does **not** bypass repo guardrails. If the repo requires `push-gate`, durable branch leases, draft PRs, stacked branches, or other safeguards, follow them.

## Step 1: Plan first

Before substantial edits, write a short execution plan if one does not already exist.

Break the work into small steps. Each step must have:

- Goal
- Expected files or surface area
- Verification method
- Exit criterion

If the existing plan is vague, rewrite it into that shape before continuing.

### Step template

```markdown
## Step N
- Goal: what changes in this step
- Touches: files, modules, UI surfaces, commands, or APIs
- Verification: exact commands, browser flow, or computer-use flow
- Exit: what must be true before moving on
```

## Step 2: Execute with gates

Only work on the current step.

Before starting the next step:

- Run the listed verification
- Read the result, not just the exit code
- Fix failures or update the plan if reality changed
- Confirm the step still supports the remaining steps

Do not defer verification to the very end unless the step truly cannot be verified in isolation.

## Step 3: Verify on the real surface

Prefer the strongest realistic verification surface available:

1. End-to-end bash/CLI/API flow
2. Browser flow
3. Computer-use/manual UI flow
4. Focused automated tests
5. Static checks, typechecks, lint, or build

Unit tests alone are not enough when the user-facing path can be exercised directly.

When practical:

- Reproduce the bug or missing behavior before the fix
- Show it passing after the fix
- Add or improve automated coverage so the result stays verifiable later

If the repo lacks a good verification path, create the lightest reasonable one instead of skipping verification.

Never say "tested" unless you actually ran it.

## Step 4: Use Ralph-style execution for long work

If the task is long-running, multi-file, or likely to outlive the current context window, upgrade the plan into a durable execution document.

That document should include:

- Original design intent
- Ordered steps
- Per-step verification commands
- Per-step self-review gate
- Resume instructions
- Clear completion signal for each step

At each resume point, re-read the plan, finish exactly one step, run its verification, and update the status before continuing.

### Self-review gate for every step

Before marking a step done, check:

- Does this still match the original design intent?
- Did I actually verify the thing I changed?
- Did I touch only the intended files/surfaces for this step?
- Do the remaining steps and their verifications still make sense?
- Is there obvious complexity, dead code, or speculative code I should remove now?

## Step 5: Run `/simplify`

After the implementation works, run the `/simplify` skill or apply the same pass directly.

Simplify the code and tests without changing behavior:

- Remove dead code
- Reduce unnecessary branching
- Remove redundant tests
- Collapse obvious verbosity
- Delete comments that only narrate the code

Then re-run the affected verification.

## Step 6: Finish the PR workflow

Once the work is implemented, simplified, and verified:

1. Review the diff
2. Commit cleanly
3. Push with the repo's approval flow
4. Open or update the PR

Choose the right finishing skill:

- Simple single-branch flow: `/commit-push-pr`
- Multiple branches or unclear remote state: `/push-review`
- True stacked diff chain: `/stacked-pr`

Default to draft PRs unless the user says otherwise.

## Output contract

Do not present the work as done until you can state:

- What plan was executed
- What verification ran
- Whether `/simplify` was run
- What commit/PR state exists
- Any exact blocker that prevented full completion

If blocked on user approval for push or external credentials, stop there and say so plainly. Do not pretend the PR is up if it is not.

## Anti-laziness rules

- Do not replace execution with a recommendation when you can do the work now.
- Do not skip verification because it is slow, annoying, or requires real interaction.
- Do not move to the next step with a red or uninspected verification result.
- Do not keep complexity that `/simplify` should have removed.
- Do not stop at "implemented"; stop at "verified and ready for review."
