---
name: stacked-pr
description: Create and maintain stacked PRs (dependent PR chains with incremental diffs). Use when splitting work into dependent changes that build on each other.
---

# Stacked PRs

Stacked PRs are a chain of dependent pull requests where each PR builds on the previous one. Reviewers see only the incremental diff for each PR, not the entire accumulated change.

When a repo has both `origin` and `upstream` remotes:
- PR lookup/binding defaults to the upstream repo.
- Pushes stay on the branch's tracked remote when present.
- New untracked branches prefer `upstream` only when the current viewer can push there; otherwise they use `origin`.

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

## Step 2: Prepare + request push-gate approval (per branch)

For each branch in the stack, run `pg prepare` from that branch's
worktree/repo, then tell the user to approve. See the `push-gate-prepare`
skill for field guidance.

```bash
pg -C <absolute-repo-path> prepare \
  --what     'one-line what this branch changes' \
  --why      'one-line motivating reason' \
  --approach 'one-line strategy'
```

Then tell the user:

> **Branch `<branch>` ready.** Run in your terminal:
>     pg -C <absolute-repo-path>

Repeat per branch in stack order.

## Step 3: Push all branches and create PRs

Once the user confirms the branch lease was approved:

```bash
# Push each branch with a fresh caveman self-assertion
pg push --assert-flow $'new pr flow\nbranch mho/feature-base\nbase infra\nno rewrite' --set-upstream
pg push --assert-flow $'new pr flow\nbranch mho/feature-api\napi layer\nno rewrite' --set-upstream
pg push --assert-flow $'new pr flow\nbranch mho/feature-ui\nui layer\nno rewrite' --set-upstream

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

> **Faster path for the common case:** `stack sync` (see the `stack` skill)
> fetches the base remote, preflights PR-state adoption and
> `git-branchless sync --pull` in a scratch clone, then atomically applies the
> resulting local branch tips if the preflight succeeds. Use the manual
> `git rebase` flow below only when `stack sync` reports a conflict you have
> to resolve, or when `git-branchless` is unavailable.

When you update a parent branch, rebase children to pick up changes:

```bash
# After updating mho/feature-base
git checkout mho/feature-api
git rebase mho/feature-base
# HEAD changed — prepare a fresh brief and ask user to re-approve
pg prepare \
  --what     'rebase mho/feature-api onto updated mho/feature-base' \
  --why      'pick up parent changes; preserve incremental diff' \
  --approach 'git rebase; re-push with --force-with-lease'
# Tell user: pg -C <repo>
pg push --assert-flow $'update pr #<child>\nbranch mho/feature-api\nrebase onto parent\nrewrite branch' --force-with-lease
```

Always use `--force-with-lease` (never `--force`) — it fails safely if the remote has diverged.

## After Parent Merges

> **Faster path:** `stack sync` handles squash-merged parents through GitHub
> PR-state adoption plus `git-branchless` patch-id detection in a scratch
> clone — no manual `git rebase --onto` needed when preflight succeeds. You
> still have to run `gh pr edit --base main` to re-target the child PR
> (`stack sync` does not touch GitHub PR base).

When a parent PR merges into main, re-target the child:

```bash
# mho/feature-base merged into main
gh pr edit <child-PR-number> --base main

# Rebase child onto main to clean up merge base
git checkout mho/feature-api
git rebase main
pg prepare \
  --what     'rebase mho/feature-api onto main after parent merge' \
  --why      're-target child now that parent PR landed' \
  --approach 'git rebase onto main; re-push with --force-with-lease'
# Tell user: pg -C <repo>
pg push --assert-flow $'update pr #<child>\nbranch mho/feature-api\nrebase onto main\nrewrite branch' --force-with-lease
```

## Verifying Incremental Diffs

Each PR should show only its own changes, not accumulated parent changes:

```bash
# Check what PR #N shows as its diff
gh pr diff <N>
```

If the diff includes parent changes, the `--base` is wrong — fix with `gh pr edit <N> --base <correct-parent>`.

## Rules for Autonomous Agents

- Do all work locally first. Push only after the user approves a durable branch lease.
- Always create PRs with `--base <parent-branch>`, not `--base main` (except the first)
- Use `git rebase <parent>` to sync, never merge
- Prefer `stack sync` for routine local restacks; use manual rebases only for conflict resolution or unsupported cases
- Use `stack squash` to collapse noisy incremental commits before refreshing branch leases
- Use `stack push` for existing stacked PRs with fresh push-gate leases
- Use `--force-with-lease` to push rebased branches, but always create a replacement lease first
- Include dependency annotations in PR descriptions
- Verify `gh pr diff` shows only incremental changes
- After parent merges: `gh pr edit --base main` + rebase onto main

## Netflix GHE Notes

All `gh` commands work the same on Netflix GitHub Enterprise. The Netflix `gh` fork handles auth via metatron automatically.
