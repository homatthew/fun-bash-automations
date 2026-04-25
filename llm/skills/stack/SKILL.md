---
name: stack
description: Local-first stacked-PR CLI. Use `stack status` instead of hand-rolling git/gh/pg tool calls, `stack sync` for scratch-preflighted restacks, `stack squash` to collapse noisy incremental commits, and `stack push` instead of the per-branch `pg prepare`/`pg push` loop from the `push-review` skill.
---

# stack

Local-first stacked-PR tooling. Merges `git`, `gh`, and `pg` into one view
(`stack status`), preflights cascade-rebases in a scratch clone after upstream
advances or a parent squash-merges (`stack sync`), squashes noisy incremental
branch commits (`stack squash`), and orchestrates the per-branch `pg prepare`
/ `pg push` loop across the whole stack (`stack push`).

`stack push` never bypasses `pg` — it stops and waits for the human to
approve each lease, then resumes on re-invocation.

## When to invoke

- User asks "what's the state of my stack?" — run `stack status`. Don't loop
  through `git log`, `gh pr list`, `pg leases` yourself; `stack status`
  already composes them into one table (and `--json` for scripting).
- After a parent PR lands or main moves — run `stack sync`. It creates a
  throwaway scratch clone, handles both patch-id-detectable squashes and
  multi-commit squashes (PR-state cascade via `gh` first, then
  `git-branchless sync --pull`), and only then imports the resulting branch
  tips back into the real repo with old-tip verification.
- User says "fetch and rebase my stack" / "catch up on main" — `stack sync`.
- User wants to clean up the current PR before pushing — run `stack squash`.
  It squashes the current branch's commits relative to its stack parent, then
  restacks local descendants.
- User wants to push the whole stack — run `stack push`. Walks parents
  first, runs `pg push` where leases are fresh, runs `pg prepare` and
  stops where they are not. Re-run after the user approves to continue.
- Starting a push workflow and want a current-state snapshot before handing
  to `pg` — `stack status`.

## When NOT to use

- Single branch, no stack — normal `git` / `gh` / `pg` is enough.
- Branches with no PR yet. `stack push` skips them. Use
  `/commit-push-pr` to create the first PR for a branch.
- Adapting code for parent-PR renames (e.g., class rename, API break).
  `stack sync` handles the commits; you still have to read conflicts and
  adjust code yourself.

## Commands

```
stack status [--json] [--base REF] [--prefix PREFIX]
stack sync [--dry-run] [--keep-scratch] [--base REF] [--prefix PREFIX]
stack squash [--dry-run] [-m "subject"] [--base REF] [--prefix PREFIX]
stack push [--dry-run] [--base REF] [--prefix PREFIX]
```

Base ref auto-detected from `upstream/main` or `origin/main`. Branch
prefix defaults to `mho/` (override via `git config stack.prefix`).

`stack sync` runs two cascade passes in a scratch clone:
1. **PR-state pass** (via `gh pr list --head <branch>`): for any branch
   whose PR is MERGED, rebase all local descendants onto the PR's
   `baseRefName` using `git rebase --onto`. Catches multi-commit squashes
   that patch-id detection misses.
2. **Patch-id pass** (`git-branchless sync --pull`): drops commits whose
   patch-id matches one already on the new base. Catches cherry-picks and
   single-commit squashes.

If scratch preflight fails, the real branch refs are unchanged. By default the
scratch clone is removed on success and failure. Use `--keep-scratch` to
preserve it; the command prints the scratch path and a debug command to rerun
the preflight.

Set `STACK_DEBUG=1` when alpha-testing or investigating surprising behavior.
Debug output goes to stderr and includes repo roots, branch counts, scratch
paths, lease-match counts, planned ref updates on transaction failures, and
push-gate decision breadcrumbs.

`stack squash` acts on the currently checked-out branch. It determines that
branch's stack parent, soft-resets the branch to that parent, commits one
combined change using `-m`, the PR title, or the first commit subject, and then
rebases local descendants onto the new parent tips. Any moved branch with an
existing push-gate lease is reported as stale.

`stack push` walks the stack parents-first. For each branch:
- No PR → skipped (warn; create the PR via `/commit-push-pr`).
- No unpushed commits → skipped silently.
- Lease fresh (`pg check` returns `allowed && anchor==HEAD`) → runs
  `pg push --force-with-lease --assert-flow "update pr #N\nbranch <name>\n..."`.
- Lease missing or stale → runs `pg prepare` with auto-derived
  what/why/approach, prints "Run `pg -C <repo>` to approve, then re-run
  `stack push`", and exits 0. Idempotent: re-invoke after each approval.

At the end of a push attempt, `stack push` prints an **Agent handoff** block.
Use it as the checklist for the next agent action: existing PR numbers to
refresh with `/update-pr-description`, no-PR branches with their target base,
and the exact `stack push` command to re-run when a custom `--base` or
`--prefix` was used.

## Rules for agents

1. **Do not bypass `pg`.** `stack sync` only flags which leases go stale — it
   never revokes or re-approves. After `stack sync` moves a branch tip, the
   user must re-run `pg` on that branch. `stack push` is the same: it
   prepares briefs and runs `pg push` against fresh leases, but every
   first-push for a tip still requires the human to run `pg`. Never set
   `PG_SKIP_EDIT`, `PG_ALLOW_DESCENDANT`, `PG_SCOPE_OVERRIDE`, or pipe
   `yes` into the approval prompt.
2. **Guard working tree.** `stack sync`, `stack squash`, and `stack push` hard-fail on
   a dirty tree. Don't `git stash` for them — surface the message and let
   them choose.
3. **Conflict stops are hard stops.** If scratch preflight or
   `git-branchless sync` exits non-zero, surface the scratch path/error and
   stop. Do not try to auto-resolve.
4. **`git-branchless` is required for `sync`.** If missing, `stack` prints
   an install hint. Don't silently fall back to a manual rebase loop — the
   whole point is mechanical cascade with patch-id detection.
5. **`stack push` checks out branches.** It saves the caller's branch and
   restores it before any stop or completion. If you see the user's HEAD
   on a different branch after a `stack push` failure, `git checkout -`
   should put them back.

## Output shape (JSON)

`stack status --json` emits:

```json
{
  "base": "upstream/main",
  "prefix": "mho/",
  "stacks": [
    {
      "root": "mho/feature-base",
      "branches": [
        {
          "name": "mho/feature-base",
          "parent": "upstream/main",
          "depth": 0,
          "ahead": 3, "behind": 0,
          "head": "abc123…",
          "pr": { "number": 42, "baseRefName": "main", … } | null,
          "lease": { … } | null,
          "lease_state": "allowed" | "stale-tip" | "revoked" | "—",
          "ci": "PASS" | "FAIL" | "PENDING" | "—"
        }
      ]
    }
  ]
}
```

Use `jq` to filter: e.g., branches with no PR are `.stacks[].branches[] | select(.pr == null)`.
