---
name: split-pr
description: Analyze a PR and propose atomic commit strategy for stacked diffs
---

# Split PR

Analyze changes on a branch and propose how to split them into atomic, reviewable commits for stacked diffs.

## Arguments

- `[base]` - Base ref to diff against (default: `main`)

## Phase 1: Analyze the Changes

1. Determine the base ref (default `main`, or user-specified)
2. Get the diff: `git diff <base>...HEAD`
3. List all commits: `git log <base>..HEAD --oneline`
4. Categorize changed files:

| Category | Examples |
|----------|----------|
| **Interfaces/Contracts** | types, protocols, abstract classes, API schemas, `.d.ts` |
| **Core Logic** | business logic, domain entities, algorithms |
| **Infrastructure** | configs, utilities, helpers, adapters |
| **Integration** | glue code, wiring, DI registration, entry points |
| **Tests** | unit, integration, e2e tests |
| **Refactors** | renames, restructuring, no behavior change |

5. Build dependency graph:
   - What depends on what?
   - What are "leaf" changes (no dependencies)?
   - What is the entry point / main feature?

## Phase 2: Ask Clarifying Questions

Use AskUserQuestion to understand:

- What is the main entry point for this feature?
- What are the core domain entities being introduced/modified?
- Are there any changes that could merge independently today?
- Any commits that should stay together?

## Phase 3: Choose Splitting Strategy

Based on the PR shape, recommend one of:

### Strategy A: Interface-First
**When**: Adding new subsystems, APIs, or cross-cutting concerns

Stack order:
1. Interfaces & Types (contracts without implementation)
2. Core implementations (one commit per major component)
3. Infrastructure/Helpers (supporting utilities)
4. Integration & Wiring (connect the pieces)
5. Tests (can parallel with implementation)

### Strategy B: Entity-Based
**When**: Clear domain boundaries, modifying existing patterns

Stack order:
1. Shared dependencies (anything multiple entities need)
2. Entity A (complete vertical slice: model + logic + tests)
3. Entity B (complete vertical slice)
4. Integration (tie entities together)
5. Feature flag / entry point (expose to users)

### Strategy C: Refactor-Then-Feature
**When**: PR mixes cleanup with new functionality

Stack order:
1. Pure refactors (no behavior change, easy to review)
2. Feature changes (on clean foundation)

## Phase 4: Output the Plan

Create `~/.claude/plans/split-pr-<branch-name>.md`:

```markdown
# Split Plan: <branch-name>

## Summary
- **Base**: <base-ref>
- **Branch**: <current-branch>
- **Total commits**: <count>
- **Files changed**: <count>
- **Lines**: +<added> -<removed>

## Strategy: <A/B/C> - <name>

Rationale: <why this strategy fits>

## Proposed Commits (in merge order)

### 1. <title>
**Purpose**: <single sentence>
**Type**: Interface | Core | Infrastructure | Integration | Test | Refactor
**Files**:
- `path/to/file.ts` - <what changes>
**Dependencies**: None (base)

### 2. <title>
**Purpose**: <single sentence>
**Type**: <type>
**Files**:
- `path/to/file.ts` - <what changes>
**Dependencies**: Commit 1

[...]

## Execution Strategy Preference

- [ ] **Rebase**: Reorder/split commits in place (`git rebase -i`)
- [ ] **Reconstruct**: Fresh branch, rebuild piece by piece (preserves original)

## Risks & Notes
- <rebasing concerns>
- <test coverage gaps>
- <files that are tricky to split>
```

## Phase 5: Get Approval

Present the plan to the user. Ask:

1. Does the commit ordering make sense?
2. Should any commits be combined or split further?
3. **Execution preference**: Rebase or Reconstruct?

Do NOT proceed to execution without explicit approval.

## Phase 6: Execute the Split

After approval, spawn an agent in a worktree to execute.

### Reconstruct Strategy (Safer)

1. Note the current branch name as `<original-branch>`
2. Create a worktree: `git worktree add --no-track -b mho/split-<branch> ~/worktrees/mho-split-<branch> <base>`
3. For each planned commit:
   - Cherry-pick relevant changes or manually apply from original
   - Stage only the files for this commit
   - Commit with the planned message
   - Verify build/tests pass
4. When complete, user can:
   - Compare: `git diff <original-branch>..mho/split-<branch>` (should be empty)
   - Force-push to original: `git push origin mho/split-<branch>:<original-branch> --force-with-lease`
   - Or open as new PR

### Rebase Strategy (In-Place)

1. Create backup tag: `git tag backup-<branch>-<date>`
2. Interactive rebase: `git rebase -i <base>`
3. Reorder commits per plan
4. Use `edit` to stop and split commits as needed
5. If anything goes wrong: `git rebase --abort` or `git reset --hard backup-<branch>-<date>`

## Rules

- Each commit MUST build and pass tests independently
- Never mix refactors with feature changes in one commit
- Prefer smaller commits (50-200 lines ideal)
- Document what each commit does in the message
- Preserve the original branch until split is verified
- If reconstruct produces different final state than original, STOP and investigate

## References

- [Stacked Diffs - Pragmatic Engineer](https://newsletter.pragmaticengineer.com/p/stacked-diffs)
- [Atomic Commits - LeanIX](https://engineering.leanix.net/blog/atomic-commit/)
- [Splitting PRs - Droids on Roids](https://www.thedroidsonroids.com/blog/splitting-pull-request)
