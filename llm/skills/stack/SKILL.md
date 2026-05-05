---
name: stack
description: Local-first stacked-PR CLI. Use `stack status` instead of hand-rolling git/gh/pg tool calls, `stack sync` for scratch-preflighted restacks, `stack squash` to collapse noisy incremental commits, and `stack push` instead of the per-branch `pg prepare`/`pg push` loop from the `push-review` skill.
---

# stack

Local-first stacked-PR tooling. Merges `git`, `gh`, CI, and `pg` into one view
(`stack status`), preflights cascade-rebases in a scratch clone after upstream
advances or a parent squash-merges (`stack sync`), inserts a new branch into an
existing stack with descendant restacks (`stack insert`), stores declared stack
manifests in push-gate's Dolt store (`stack trunk init/add`), materializes them
onto per-stack private trunks (`stack trunk materialize`), squashes noisy
incremental branch commits (`stack squash`), and orchestrates the per-branch
`pg prepare` / `pg push` loop across the whole stack (`stack push`).
Human-readable output is guided: every command ends with a `Next step:` block
that states the safe command or human approval action to run next.

`stack push` never bypasses `pg` — it stops and waits for the human to
approve each lease, then resumes on re-invocation.

## Stale context reset

If the user says an ongoing agent may have stale stack context, tell that agent
to run `agent-stack-refresh` directly before using `stack` or `pg`.
`stack-latest` is a human zsh alias for the same helper and may not exist in
non-interactive agent shells. The helper prints the live SKILL.md paths, the
current Dolt-backed trunk flow, Dolt install/verification guidance, and optional
`stack --help` / `pg --help` output. Skills are symlinked by `fba-deploy`, so
fresh sessions see updates automatically; already-running sessions must
explicitly re-read or run the helper.

## When to invoke

- User asks "what's the state of my stack?" — run `stack status`. Don't loop
  through `git log`, `gh pr list`, `pg leases` yourself; `stack status`
  already composes them into one table (and `--json` for scripting).
- User asks about a specific PR stack — run `stack status --pr <N> --children`.
  This uses GitHub PR `baseRefName` as the stack DAG and warns if local branch
  ancestry disagrees. GitHub PR `baseRefName` is authoritative for PR-scoped
  stacks; local ancestry is diagnostic/stale.
- User needs to edit a PR in the middle of a stack — run `stack checkout --pr <N>`.
  It resolves the open PR to a local branch, refuses dirty worktrees, checks out
  that branch, prints the scoped stack context, and shows the exact
  edit/commit/squash/test/push flow.
- After a parent PR lands or main moves — run `stack sync`. It creates a
  throwaway scratch clone, handles both patch-id-detectable squashes and
  multi-commit squashes (PR-state cascade via `gh` first, then
  `git-branchless sync --pull`), and only then imports the resulting branch
  tips back into the real repo with old-tip verification.
- User says "fetch and rebase my stack" / "catch up on main" — `stack sync`.
- User needs to insert a new branch between an existing PR and its children —
  run `stack insert --branch <new-branch> --after-pr <N>`. It uses GitHub PR
  `baseRefName` to choose child PRs, preflights the inserted branch and child
  rebases in scratch, then imports moved refs atomically.
- User needs to insert a local branch into a purely local stack — run
  `stack insert --branch <new-branch> --after <branch>`.
- User has a codified stack and wants the stack's private trunk to be the
  source of truth — use `stack trunk init --name <name> --base <ref> --trunk <branch>`
  and `stack trunk add --stack <name> ...`, then run `stack trunk status --stack <name>`
  and `stack trunk materialize --stack <name>`. The manifest lives in
  push-gate's Dolt store; `--manifest <path>` is only a compatibility/import
  path. The private trunk is not `main`, `origin/main`, or `upstream/main`;
  branch pointers move to commits on that stack-specific trunk.
- User wants to clean up the current PR before pushing — run `stack squash`.
  It squashes the current branch's commits relative to its stack parent, then
  restacks selected descendants. When local ancestry is known wrong, prefer
  `stack squash --pr <N> --onto-pr-base`.
- User wants to push the whole stack — run `stack push`. Walks parents
  first, runs `pg push` where leases are fresh, runs `pg prepare` and
  stops where they are not. Re-run after the user approves to continue.
- Starting a push workflow and want a current-state snapshot before handing
  to `pg` — `stack status`.

## When NOT to use

- Single branch, no stack — normal `git` / `gh` / `pg` is enough.
- Branches with no local stack ancestry. `stack push` only knows how to push
  branches it can place in the local stack. For an unrelated one-off branch,
  use `/commit-push-pr`.
- Adapting code for parent-PR renames (e.g., class rename, API break).
  `stack sync` handles the commits; you still have to read conflicts and
  adjust code yourself.

## Commands

```
stack status [--json] [--base REF] [--prefix PREFIX] [--pr N] [--children]
stack checkout --pr N [--base REF] [--prefix PREFIX]
stack sync [--dry-run] [--keep-scratch] [--base REF] [--prefix PREFIX]
stack insert --branch BRANCH (--after BRANCH|--after-pr N) [--dry-run] [--keep-scratch] [--base REF] [--prefix PREFIX]
stack trunk init --name NAME --base REF --trunk BRANCH
stack trunk add --stack NAME --id ID --branch BRANCH [--pr N] [--after ID] [--base REF]
stack trunk move --stack NAME --id ID (--after ID|--before ID|--first|--last) [--dry-run]
stack trunk remove --stack NAME --id ID [--dry-run]
stack trunk status --name NAME|--stack NAME|--manifest PATH [--json] [--base REF] [--prefix PREFIX]
stack trunk materialize --name NAME|--stack NAME|--manifest PATH [--dry-run] [--keep-scratch] [--base REF] [--prefix PREFIX]
stack trunk push --stack NAME [--tip] [--dry-run] [--remote NAME]
stack squash [--dry-run] [-m "subject"] [--branch BRANCH] [--onto REF|--onto-pr-base] [--pr N] [--base REF] [--prefix PREFIX]
stack push [--dry-run] [--base REF] [--prefix PREFIX] [--pr N] [--children]
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

`stack sync`, `stack insert`, `stack trunk materialize`, and `stack squash`
enable Git rerere automatically for the repo-local config they operate on:

```
git config --local rerere.enabled true
git config --local rerere.autoupdate true
```

Scratch clones receive the source repo's rerere cache before stack-managed
restacks, so repeated conflicts can be reused. Separate clones need their own
repo-local rerere config and their own rerere cache/history; enabling rerere in
one clone does not create conflict history in another clone.

Set `STACK_DEBUG=1` when alpha-testing or investigating surprising behavior.
Debug output goes to stderr and includes repo roots, branch counts, scratch
paths, lease-match counts, planned ref updates on transaction failures, and
push-gate decision breadcrumbs.

`stack insert` places an existing local branch after a stack branch and restacks
selected descendants onto it. Use `--after-pr N` when the insertion point is an
open PR; child selection follows GitHub PR `baseRefName` and excludes no-PR
local children. Use `--after BRANCH` for local ancestry. Live runs create a
scratch clone, rebase the inserted branch onto the insertion point, rebase
descendants onto the inserted branch, and import moved refs with atomic
old-tip verification. `--dry-run` prints the planned rebases without creating a
scratch clone or moving refs. Any moved branch with an existing push-gate lease
is reported as stale. The command does not change GitHub PR bases; retarget or
create PRs separately when the inserted branch becomes the new review base.

`stack trunk init` and `stack trunk add` write the manifest to the Dolt-backed
push-gate store. `stack trunk materialize --stack <name>` reads that manifest,
builds the stack's private trunk in a scratch clone, replays item branches in
manifest order, and then atomically moves the trunk ref plus each item branch
pointer to the corresponding commit on the trunk. This is the declarative form
of restacking: change the stored order, then materialize once. The private trunk
is per stack and is never `main`. `stack trunk status` shows the manifest order,
inferred patch bases, trunk ref, and pointer branch heads. PR base changes are
handled separately; this command only moves local refs, records the
materialization in Dolt, and reports stale push-gate leases.
Use `stack trunk move --stack <name> --id <item> --after <item>` or
`--before` / `--first` / `--last` to reorder existing items. Use
`stack trunk remove --stack <name> --id <item>` to prune an item. These commands
change the Dolt manifest order only; run `stack trunk materialize --stack <name>`
afterwards to rebuild the private trunk commits and branch pointers. Do not
create a `-v2` stack just to reorder items.
If the checked-out branch is one of the refs moved by materialization, `stack`
refreshes the worktree to the new branch tip so the checkout does not appear
dirty with inverse changes from the old tip. Dolt must be on PATH for
`--stack` commands; install with `brew install dolt`, verify with `dolt version`,
and use `PG_STORE_DIR` only when the default `~/.push-gate/dolt-store` should be
overridden.
After the human approves the materialized trunk with `pg trunk --stack <name>`,
`stack trunk push --stack <name>` walks the approved item commits and invokes
`pg push --trunk-stack` for each branch. If the trunk lease is missing or stale,
it stops with the exact prepare/review commands instead of pushing.
Use `stack trunk push --stack <name> --tip` when the goal is CI validation of
the composed stack: it pushes only the private trunk ref at the approved
`trunk_tip` and leaves item branches untouched.

The push-gate trunk approval draft uses explicit stack vocabulary:
- `description`: PR-description-style human review text at the top of YAML.
- `stack_items`: ordered review/push units.
- `stack_items[].description`: required item-level summary, motivation, and
  approach; use YAML bullet lists for reviewable detail.
- `stack_items[].brief`: compatibility mirror derived from `description`.
- `pointer_commit`: exact commit approved for that stack item.
- `base_commit`: effective review base for that stack item.
- `contained_commits`: commits included in the item patch range.
- `changed_files`: readable file groups such as `added` and `modified`.

Agents should use the stack-level `prepare-trunk` brief for the cross-item
`what`, `why`, and `approach`, and pass `pg prepare-trunk --item-briefs FILE`
for item-level explanations.

`stack squash` acts on the currently checked-out branch. It determines that
branch's stack parent, soft-resets the branch to that parent, commits one
combined change using `-m`, the PR title, or the first commit subject, and then
rebases local descendants onto the new parent tips. Any moved branch with an
existing push-gate lease is reported as stale.

Use `--branch BRANCH` or `--pr N` to target a branch without checking it out
first. Use `--onto REF` for an explicit squash base, or `--onto-pr-base` to
derive the base from the PR's GitHub `baseRefName`.

With `--pr N --children`, `stack status` and `stack push` scope to the GitHub PR
DAG rooted at PR `N`. This prevents unrelated same-prefix branches from being
processed and emits topology mismatch warnings when local ancestry disagrees
with GitHub PR bases.

When a user names a PR, default to:

```
stack status --pr <N> --children
stack checkout --pr <N>       # when editing this PR
stack push --pr <N> --children
```

Broad `stack push` is still supported, but it can include unrelated local stacks
that share the configured prefix.

`stack checkout --pr N` is intentionally simple. It does not absorb/fixup
changes or infer edit intent; it only checks out the PR branch and prints the
rails:
`edit -> git add && git commit -> stack squash --pr N --onto-pr-base -> tests
-> stack push --dry-run --pr N --children -> stack push --pr N --children`.

`stack push` walks the stack parents-first. For each branch:
- No PR → still goes through `pg check`; if the lease is fresh, pushes the
  branch with `pg push --force-with-lease --set-upstream`, then lists the
  draft PR to create with the correct base.
- No unpushed commits → skipped silently.
- Lease fresh (`pg check` returns `allowed && anchor==HEAD`) → runs
  `pg push --force-with-lease --assert-flow "update pr #N\nbranch <name>\n..."`.
- Lease missing or stale → runs `pg prepare` with auto-derived
  what/why/approach, prints "Run `pg -C <repo>` to approve, then re-run
  `stack push`", and exits 0. Idempotent: re-invoke after each approval.

At the end of a push attempt, `stack push` prints an **Agent handoff** block.
Use it as the checklist for the next agent action. It includes a phase
(`needs approval`, `ready to push`, `needs restack`, `needs PR description
update`, or `done`), existing PR numbers to refresh with
`/update-pr-description`, no-PR branches with their target base, and the exact
`stack push` command to re-run when a custom `--base`, `--prefix`, or PR scope
was used. PR description bases follow GitHub semantics: the root PR compares
against its base branch and each child PR compares against its parent branch.

The canonical long-form guide is `llm/stack/README.md`.

## Rules for agents

1. **Do not bypass `pg`.** `stack sync` only flags which leases go stale — it
   never revokes or re-approves. After `stack sync` moves a branch tip, the
   user must re-run `pg` on that branch. `stack push` is the same: it
   prepares briefs and runs `pg push` against fresh leases, but every
   first-push for a tip still requires the human to run `pg`. Never set
   `PG_SKIP_EDIT`, `PG_ALLOW_DESCENDANT`, `PG_SCOPE_OVERRIDE`, or pipe
   `yes` into the approval prompt.
2. **Guard working tree.** `stack sync`, `stack insert`, `stack squash`, and
   `stack push` hard-fail on a dirty tree. Don't `git stash` for them —
   surface the message and let them choose.
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
