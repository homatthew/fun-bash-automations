---
name: push-review
description: "Analyze branch topology, map commits to PRs, and selectively push branches one-by-one with push-gate approval. Use when finishing work and preparing to push — especially with stacked branches or multiple PRs."
---

# Push Review

> **When to use:** After finishing implementation, when you want to review the state of the world before pushing. Analyzes commit DAG, maps branches to PRs, and guides sequential pushing with push-gate between each.

## Step 0: Stale Detection

Before analyzing what to push, surface anything that looks abandoned or needs attention. Run these checks across all your branches (not just the current one):

### 0a. Orphaned branches (pushed but no PR)

```bash
# Branches with a remote tracking branch but no open PR
for branch in $(git for-each-ref --format='%(refname:short)' refs/heads/mho/); do
  has_remote=$(git rev-parse --verify "origin/$branch" 2>/dev/null)
  if [ -n "$has_remote" ]; then
    pr_count=$(gh pr list --head "$branch" --state open --json number --jq 'length')
    if [ "$pr_count" = "0" ]; then
      last_commit_date=$(git log -1 --format='%cr' "$branch")
      echo "ORPHAN: $branch (pushed, no open PR, last commit $last_commit_date)"
    fi
  fi
done
```

### 0b. Stale PRs (open but no recent commits)

```bash
# Open PRs where the branch hasn't been updated recently
gh pr list --state open --author @me --json number,headRefName,title,updatedAt,url \
  --jq '.[] | "\(.number)\t\(.headRefName)\t\(.updatedAt)\t\(.title)"' | \
while IFS=$'\t' read -r num branch updated title; do
  # Calculate days since last update
  echo "PR #$num ($branch) last updated: $updated - $title"
done
```

### 0c. PRs with unresolved review requests

```bash
# PRs where reviewers requested changes
gh pr list --state open --author @me \
  --json number,headRefName,title,reviewDecision,reviews \
  --jq '.[] | select(.reviewDecision == "CHANGES_REQUESTED") | "CHANGES REQUESTED: #\(.number) \(.headRefName) - \(.title)"'
```

### 0d. PRs with merge conflicts

```bash
# PRs that can no longer be cleanly merged
gh pr list --state open --author @me \
  --json number,headRefName,title,mergeable \
  --jq '.[] | select(.mergeable == "CONFLICTING") | "CONFLICT: #\(.number) \(.headRefName) - \(.title)"'
```

### 0e. PRs with failing checks

```bash
# PRs where CI is red
gh pr list --state open --author @me \
  --json number,headRefName,title,statusCheckRollup \
  --jq '.[] | select(.statusCheckRollup != null) | select([.statusCheckRollup[] | select(.conclusion == "FAILURE")] | length > 0) | "CI FAILING: #\(.number) \(.headRefName) - \(.title)"'
```

### 0f. Branches behind main

```bash
# How far behind main each branch is (needs rebase if high)
BASE=${1:-main}
for branch in $(git for-each-ref --format='%(refname:short)' refs/heads/mho/); do
  behind=$(git rev-list --count "$branch..$BASE" 2>/dev/null)
  if [ "$behind" -gt 20 ]; then
    echo "DRIFT: $branch is $behind commits behind $BASE"
  fi
done
```

### 0g. Dead remote branches (remote deleted, local remains)

```bash
# Fetch and prune first
git fetch --prune origin 2>/dev/null
# Local branches whose upstream is gone
git for-each-ref --format='%(refname:short) %(upstream:track)' refs/heads/mho/ | \
  grep '\[gone\]' | awk '{print "DEAD REMOTE: " $1 " (remote branch deleted)"}'
```

### Present Stale Report

If any stale items are found, present them **before** the push plan:

```
### Stale / Needs Attention

| Status             | Branch / PR          | Detail                        | Suggested Action       |
|--------------------|----------------------|-------------------------------|------------------------|
| ORPHAN             | mho/old-experiment   | Pushed 3 weeks ago, no PR     | Delete or create PR    |
| CHANGES REQUESTED  | #38 mho/auth-fix     | Reviewer waiting since Feb 20 | Address or close       |
| CONFLICT           | #41 mho/refactor     | Can't merge cleanly           | Rebase onto main       |
| CI FAILING         | #39 mho/new-endpoint | 2 checks failing              | Fix or close           |
| DRIFT              | mho/feature-old      | 47 commits behind main        | Rebase or abandon      |
| DEAD REMOTE        | mho/merged-thing     | Remote branch deleted          | Delete local branch    |
```

Ask the user: "Want to deal with any of these before we proceed to the push plan?"

If nothing is stale, skip this section silently.

## Step 1: Analyze the Branch Topology

Gather the full picture of the current state:

```bash
# Current branch and its relationship to main
CURRENT=$(git branch --show-current)
BASE=${1:-main}

# All local branches that are ahead of base
echo "=== Branches ahead of $BASE ==="
for branch in $(git for-each-ref --format='%(refname:short)' refs/heads/); do
  ahead=$(git rev-list --count "$BASE..$branch" 2>/dev/null)
  if [ "$ahead" -gt 0 ]; then
    echo "  $branch (+$ahead commits)"
  fi
done

# Commit DAG for current branch
echo ""
echo "=== Commit DAG ==="
git log --oneline --graph --all --decorate "$BASE..HEAD"

# Which branches contain which commits
echo ""
echo "=== Branch parentage ==="
git log --oneline --first-parent "$BASE..HEAD"
```

For stacked branches, determine the dependency chain:

```bash
# Check if branches are stacked (child branches forked from parent branches)
for branch in $(git for-each-ref --format='%(refname:short)' refs/heads/mho/); do
  merge_base=$(git merge-base "$BASE" "$branch")
  echo "$branch: merge-base with $BASE is $(git rev-parse --short $merge_base)"
done
```

## Step 2: Map Branches to Existing PRs

```bash
# Check each relevant branch for existing PRs
for branch in $(git for-each-ref --format='%(refname:short)' refs/heads/); do
  ahead=$(git rev-list --count "$BASE..$branch" 2>/dev/null)
  if [ "$ahead" -gt 0 ]; then
    pr_info=$(gh pr list --head "$branch" --json number,title,url,state,baseRefName --jq '.[] | "#\(.number) [\(.state)] \(.title) (base: \(.baseRefName))"')
    if [ -n "$pr_info" ]; then
      echo "$branch -> $pr_info"
    else
      echo "$branch -> NO PR"
    fi
  fi
done
```

## Step 3: Present the Push Plan

Build and display a summary table. Example format:

```
| # | Branch              | Commits | PR      | Base | Description            | Action      |
|---|---------------------|---------|---------|------|------------------------|-------------|
| 1 | mho/feature-base    | 3       | #42     | main | Core data model        | Push update |
| 2 | mho/feature-api     | 2       | (new)   | #42  | API endpoints          | Create PR   |
| 3 | mho/feature-ui      | 4       | #44     | #43  | React components       | Push update |
```

For each row, show:
- **Branch**: the local branch name
- **Commits**: count of commits ahead of its base
- **PR**: existing PR number or "(new)" if no PR exists yet
- **Base**: what the PR targets (main, or parent PR number)
- **Description**: brief summary derived from commit messages
- **Action**: what will happen (push update, create PR, nothing)

Include a diff summary per branch:
```bash
# For each branch, show what changed
git diff --stat <parent>..<branch>
```

## Step 4: Get User Approval on the Plan

Present the table and ask:
1. Does this ordering look correct?
2. Should any branches be skipped?
3. Any description corrections for new PRs?

**Do NOT proceed to pushing without explicit approval.**

## Step 5: Sequential Push with Push-Gate

Process branches in dependency order (parents before children). For each branch:

### 5a. Show what's about to be pushed

```bash
git log --oneline <remote-tracking>..<branch>
git diff --stat <remote-tracking>..<branch>
```

### 5b. Request push-gate approval

```bash
COMMIT=$(git rev-parse <branch>)
```

Tell the user:
> **Branch 1 of N: `<branch>`**
> Pushing <N> commits. Run in your terminal:
> ```
> push-gate <full-commit-hash>
> ```

### 5c. Push after approval

```bash
git push -u origin <branch>
```

### 5d. Create PR if needed (using commit-push-pr template)

If no PR exists for this branch, create one with the standard Netflix template.
If a PR exists, report the updated state.

### 5e. Report result and move to next

```
Branch 1/3 done: mho/feature-base -> PR #42 updated (3 new commits)
```

Then repeat 5a-5e for the next branch. Each branch gets its own push-gate cycle.

## Step 6: Final Summary

After all branches are processed:

```
| Branch              | Result                          |
|---------------------|---------------------------------|
| mho/feature-base    | PR #42 updated (3 commits)      |
| mho/feature-api     | PR #43 created (draft)          |
| mho/feature-ui      | PR #44 updated (4 commits)      |
```

## Single-Branch Mode

If there's only one branch with unpushed work, skip the table ceremony — just show the commit summary and go straight to push-gate. This skill should feel lightweight for simple cases.

## Rules

- Always process in dependency order: parents before children
- One push-gate per branch — never batch (user reviews each push)
- If a push fails or is denied, stop and report. Don't continue to children.
- Use `/commit-push-pr` conventions for PR creation (Netflix template, draft mode)
- If the user says "skip" for a branch, skip it and its children (children depend on parent being pushed)
- Show diffs before each push so the user knows exactly what's going out
