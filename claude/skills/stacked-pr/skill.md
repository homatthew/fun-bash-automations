---
name: stacked-pr
description: Create and maintain stacked PRs (dependent PR chains with incremental diffs). Use when splitting work into dependent changes that build on each other.
---

# Stacked PRs

Stacked PRs are a chain of dependent pull requests where each PR builds on the previous one. Reviewers see only the incremental diff for each PR, not the entire accumulated change.

## When to Use

- Feature requires multiple dependent changes (e.g., library + consumer)
- Single PR would be too large for effective review
- Changes have a natural ordering (infra -> API -> UI)

## Branch Structure

```
main
 └── mho/feature-base     (PR #1 -> main)
      └── mho/feature-api  (PR #2 -> mho/feature-base)
           └── mho/feature-ui (PR #3 -> mho/feature-api)
```

Each PR targets its parent branch, NOT main (except the first).

## Step 1: Create all branches and commits locally

Do ALL the work first. No pushing yet.

```bash
# Base branch
git checkout -b mho/feature-base main
# ... make changes, commit ...

# Child branch
git checkout -b mho/feature-api
# ... make changes, commit ...

# More children as needed
git checkout -b mho/feature-ui
# ... make changes, commit ...
```

## Step 2: Request push-gate approval

Include the `cd` so the token is scoped to the right repo (important when working in a worktree).

Tell the user:

> All branches ready. Run in your terminal:
> ```
> cd <working-directory>
> push-gate 5
> ```
> (5-minute window for multiple pushes.) Then I'll push all branches and create the PRs.

## Step 3: Push all branches and create PRs

Once the user confirms they've run `push-gate`:

```bash
# Push each branch (one push-gate token consumed per push)
git push -u origin mho/feature-base
git push -u origin mho/feature-api
git push -u origin mho/feature-ui

# Create PRs with correct base targets
gh pr create --base main --head mho/feature-base \
  --title "feat: add base infrastructure" --body "..." --draft

gh pr create --base mho/feature-base --head mho/feature-api \
  --title "feat: add API layer" --body "> Depends on #<base-PR>" --draft

gh pr create --base mho/feature-api --head mho/feature-ui \
  --title "feat: add UI layer" --body "> Depends on #<api-PR>" --draft
```

## PR Description Conventions

In each child PR description, add:
```
> Depends on #<parent-PR-number>
```

In the base PR description, add:
```
> Base PR for stack: #<child1>, #<child2>
```

## Maintaining the Stack

When you update a parent branch, rebase children to pick up changes:

```bash
# After updating mho/feature-base
git checkout mho/feature-api
git rebase mho/feature-base
# HEAD changed — user needs to run push-gate before pushing
git push --force-with-lease origin mho/feature-api
```

Always use `--force-with-lease` (never `--force`) — it fails safely if the remote has diverged.

## After Parent Merges

When a parent PR merges into main, re-target the child:

```bash
# mho/feature-base merged into main
gh pr edit <child-PR-number> --base main

# Rebase child onto main to clean up merge base
git checkout mho/feature-api
git rebase main
git push --force-with-lease origin mho/feature-api
```

## Verifying Incremental Diffs

Each PR should show only its own changes, not accumulated parent changes:

```bash
# Check what PR #N shows as its diff
gh pr diff <N>
```

If the diff includes parent changes, the `--base` is wrong — fix with `gh pr edit <N> --base <correct-parent>`.

## Rules for Autonomous Agents

- Do all work locally first. Push only after user runs `push-gate`.
- Always create PRs with `--base <parent-branch>`, not `--base main` (except the first)
- Use `git rebase <parent>` to sync, never merge
- Use `--force-with-lease` to push rebased branches
- Include dependency annotations in PR descriptions
- Verify `gh pr diff` shows only incremental changes
- After parent merges: `gh pr edit --base main` + rebase onto main

## Netflix GHE Notes

All `gh` commands work the same on Netflix GitHub Enterprise. The Netflix `gh` fork handles auth via metatron automatically.
