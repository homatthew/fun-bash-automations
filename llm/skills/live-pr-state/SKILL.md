---
name: live-pr-state
description: "Hard live GitHub PR state gate. Use before answering PR/base status questions or editing PR bases, especially: is PR updated, is parent merged, why does a PR point to a branch, is the stack/base correct, retarget this PR, update stacked PRs, or before final PR status claims."
---

# Live PR State

Use this skill before making any claim about a PR's current base, parent,
merge state, or whether a stacked child should still point at its parent.
GitHub PR state is authoritative; local stack status is only diagnostic.

## Hard Rule

Never answer "why does PR point at X?", "is PR updated?", "isn't X merged?",
"is the base correct?", or final PR status from memory or `stack status`
alone. Re-read live GitHub PR JSON first.

## Live State Gate

When a parent/child PR relationship is involved, run this gate immediately:

```bash
git fetch upstream main --prune
gh pr view <parent> --json state,mergedAt,baseRefName,headRefOid,mergeCommit
gh pr view <child> --json state,baseRefName,headRefOid,mergeable,additions,deletions,commits
git merge-base --is-ancestor <parent-head-sha> upstream/main
```

If the repo's canonical remote is not named `upstream`, first identify the
remote that points at the canonical repository and use that remote's `main`.

For a single PR with no explicit parent, still fetch and re-read live PR JSON:

```bash
git fetch upstream main --prune
gh pr view <pr> --json state,baseRefName,headRefName,headRefOid,mergeable,additions,deletions,commits
```

## Decision Rules

- If parent PR `state == MERGED`, the child PR must not keep the parent branch
  as base unless there is an explicit, current reason.
- If the parent PR head SHA is an ancestor of `upstream/main`, retarget the
  child to `main`.
- If the parent PR is merged but its head SHA is not an ancestor of
  `upstream/main` (for example, squash merge), do not answer from ancestry
  alone. Inspect the live PR state and explain the uncertainty or validate the
  child diff against `main` before retargeting.
- If the parent PR is open, the child may still correctly target the parent
  branch; verify the child's live `baseRefName`.
- If local stack metadata and GitHub PR JSON disagree, GitHub PR JSON wins for
  PR status/base claims.

## Retarget Flow

Only edit a PR base when the user asked you to update/fix/retarget the PR or
the current workflow already includes PR updates.

```bash
gh pr edit <child> --base main
gh pr view <child> --json baseRefName,headRefName,headRefOid,mergeable,additions,deletions,commits
```

After every `gh pr edit --base`, immediately re-read PR JSON and report the
observed `baseRefName`. Do not claim the retarget worked until the re-read
shows the intended base.

## Response Contract

When answering, include the live facts you just observed:

- parent PR state and `mergedAt` when a parent exists
- parent `headRefOid` ancestry result when checked
- child current `baseRefName`
- any retarget action taken
- child `baseRefName` after retarget, if edited

Do not cite stale branch names or prior stack shape as the reason unless the
live PR JSON still supports it.
