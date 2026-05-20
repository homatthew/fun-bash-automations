---
name: stack
description: Local-first stacked-PR CLI. Use `stack trunk list` for declared stacks and `stack status --pr <N> --children` for PR-scoped stacks instead of hand-rolling git/gh/pg tool calls; use `stack sync` for scratch-preflighted restacks, `stack squash` to collapse noisy incremental commits, and PR-scoped `stack push` or `stack trunk push` instead of the per-branch `pg prepare`/`pg push` loop from the `push-review` skill.
---

# stack

Local-first stacked-PR tooling. Merges `git`, `gh`, CI, and `pg` into one view
(`stack trunk list` or PR-scoped `stack status`), preflights cascade-rebases in a scratch clone after upstream
advances or a parent squash-merges (`stack sync`), inserts a new branch into an
existing stack with descendant restacks (`stack insert`), stores declared stack
manifests in push-gate's Dolt store (`stack trunk init/add`), materializes them
onto per-stack private trunks (`stack trunk materialize`), squashes noisy
incremental branch commits (`stack squash`), and orchestrates the per-branch
`pg prepare` / `pg push` loop for PR-scoped stacks (`stack push --pr <N> --children`)
or declared stacks (`stack trunk push --stack <name>`).
Human-readable output is guided: every command ends with a `Next step:` block
that states the safe command or human approval action to run next.

`stack push` never bypasses `pg` — it stops and waits for the human to approve
missing leases, then resumes on re-invocation. With `--async`, it prepares
async per-branch leases so one human review can authorize repeated pushes
inside the approved scope and budget.

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

- User asks "what's the state of my stack?" — run `stack trunk list` first for
  declared stacks. Don't loop through `git log`, `gh pr list`, `pg leases`
  yourself; `stack trunk list` is the default dashboard for materialized stacks.
  Use `stack status --pr <N> --children` for a PR-scoped view.
- Only use `stack status --implicit` when the user explicitly wants local
  ancestry diagnostics. Broad implicit stack inference is intentionally not the
  default because stale scratch and backup branches make the output hard to
  reason about.
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
- User wants to push a declared stack — run `stack trunk push --stack <name>`.
  For a PR-scoped stack, run `stack push --pr <N> --children`. Both paths walk
  parents first through `pg`, stop for missing approvals, and resume after the
  user approves.
- User wants unattended or overnight iteration on a PR-scoped stack — run
  `stack push --pr <N> --children --async --expires 8h --max-pushes <N>` so
  generated per-branch prepares carry async metadata. Add `--allow-rewrite`
  only when rebases/squashes are part of the approved workflow.
- Starting a push workflow and want a current-state snapshot before handing
  to `pg` — `stack trunk list` for declared stacks, or
  `stack status --pr <N> --children` for a specific PR stack.

## When NOT to use

- Single branch, no stack — normal `git` / `gh` / `pg` is enough.
- Branches outside a declared or PR-scoped stack. For an unrelated one-off
  branch, use `/commit-push-pr`.
- Adapting code for parent-PR renames (e.g., class rename, API break).
  `stack sync` handles the commits; you still have to read conflicts and
  adjust code yourself.

## Commands

```
stack -C <repo> <command> [...]
stack status [--json] [--base REF] [--prefix PREFIX] [--pr N] [--children] [--implicit]
stack checkout --pr N [--base REF] [--prefix PREFIX]
stack sync [--dry-run] [--keep-scratch] [--base REF] [--prefix PREFIX]
stack insert --branch BRANCH (--after BRANCH|--after-pr N) [--dry-run] [--keep-scratch] [--base REF] [--prefix PREFIX]
stack trunk init --name NAME --base REF --trunk BRANCH
stack trunk add --stack NAME --id ID --branch BRANCH [--pr N] [--after ID] [--base REF]
stack trunk move --stack NAME --id ID (--after ID|--before ID|--first|--last) [--dry-run]
stack trunk remove --stack NAME --id ID [--dry-run]
stack trunk list [--json] [--fast] [--base REF] [--prefix PREFIX]
stack trunk status --stack NAME [--json] [--base REF] [--prefix PREFIX]
stack trunk materialize --stack NAME [--dry-run] [--keep-scratch] [--base REF] [--prefix PREFIX]
stack trunk status --manifest PATH [--json] [--base REF] [--prefix PREFIX]                 # compatibility/import
stack trunk materialize --manifest PATH [--dry-run] [--keep-scratch] [--base REF] [--prefix PREFIX] # compatibility/import
stack trunk context --stack NAME [--json]
stack trunk context write --stack NAME --file context.yaml
stack trunk review --stack NAME [--json]
stack trunk push-plan --stack NAME [--json]
stack trunk push --stack NAME [--tip] [--dry-run] [--remote NAME]
stack squash [--dry-run] [-m "subject"] [--branch BRANCH] [--onto REF|--onto-pr-base] [--pr N] [--base REF] [--prefix PREFIX]
stack push [--dry-run] --pr N [--children] [--base REF] [--prefix PREFIX] [--async --expires 8h --max-pushes N --allow-rewrite]
```

Base ref auto-detected from `upstream/main` or `origin/main`. Branch
prefix defaults to `mho/` (override via `git config stack.prefix`).
Use `stack -C <repo> ...` for all copied commands so terminal cwd and worktree
layout cannot change the target repository.

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
push-gate store. `stack trunk list --json` is the materialized-stack dashboard
contract: it lists only current-repo Dolt-backed stacks, ordered manifest items,
latest materialization, trunk approval, PR metadata, and local/remote tip state.
Use `--fast` for UI refreshes that can omit live GitHub PR title/base
enrichment. It does not include inferred loose branches from `stack status`. `stack trunk materialize --stack <name>` reads that manifest,
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
`stack trunk remove --stack <name> --id <item>` to prune an item. Removing the
final item deletes the empty Dolt stack metadata, so no materialize step remains.
Otherwise, these commands change the Dolt manifest order only; run
`stack trunk materialize --stack <name>` afterwards to rebuild the private trunk
commits and branch pointers. Do not create a `-v2` stack just to reorder items.
`stack trunk review --stack <name> --json` is the Stack Review diff contract:
it reports full-stack, item-only, and cumulative-through-item review sections
with base/head refs, contained commits, changed files, and shortstats.
`stack trunk context --stack <name> --json` is the durable prepare-context
contract: it reports the current materialization identity, stored context for
that exact materialization, completeness/missing required fields, stale prior
contexts, generated review hints, and repo-pinned write/prepare commands.
Agents should finish stack work by writing compact handoff context with
`stack trunk context write --stack <name> --file context.yaml`; the human
approval lease is still created only by `pg trunk`.
`stack trunk push-plan --stack <name> --json` is the final readiness contract:
it reports materialization, prepare/approval checklist state, ordered push
units, remote relationship, approval coverage, and exact repo-pinned commands.
If the checked-out branch is one of the refs moved by materialization, `stack`
refreshes the worktree to the new branch tip so the checkout does not appear
dirty with inverse changes from the old tip. Dolt must be on PATH for
`--stack` commands. Dotfiles installs it during workspace utility bootstrap;
otherwise install with `brew install dolt`, verify with `dolt version`, and use
`PG_STORE_DIR` only when the default `~/.push-gate/dolt-store` should be overridden.
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

Plain `stack push` no longer acts on broad local ancestry. Use
`stack trunk push --stack <name>` for declared stacks, or
`stack push --pr <N> --children` for PR-scoped stacks.

`stack checkout --pr N` is intentionally simple. It does not absorb/fixup
changes or infer edit intent; it only checks out the PR branch and prints the
rails:
`edit -> git add && git commit -> stack squash --pr N --onto-pr-base -> tests
-> stack push --dry-run --pr N --children -> stack push --pr N --children`.

`stack push --pr <N> --children` walks the PR-scoped stack parents-first. For
each branch:
- No unpushed commits → skipped silently.
- Lease fresh (`pg check` returns `allowed && anchor==HEAD`) → runs
  `pg push --force-with-lease --assert-flow "update pr #N\nbranch <name>\n..."`.
- Async lease valid (`pg check` returns `allowed` with
  `async_iteration.enabled`) → runs the same `pg push` even when `HEAD` moved
  from the original approved anchor. Push-gate still enforces expiry, budget,
  branch/remote scope, rewrite approval, semantic scope, and self-assertion.
- Lease missing or stale → runs `pg prepare` with auto-derived
  what/why/approach, prints "Run `pg -C <repo>` to approve, then re-run the
  exact PR-scoped `stack push` command", and exits 0. Idempotent: re-invoke
  after each approval.

Use `stack push --pr <N> --children --async --expires 8h --max-pushes 20` when
the user has asked for one review to cover repeated iteration. The flags are
forwarded only to new `pg prepare` calls for stale/missing branch leases;
existing valid async leases are reused. Normal PR-scoped `stack push` still
produces exact-tip prepares.

At the end of a push attempt, `stack push` prints an **Agent handoff** block.
Use it as the checklist for the next agent action. It includes a phase
(`needs approval`, `ready to push`, `needs restack`, `needs PR description
update`, or `done`), existing PR numbers to refresh with
`/update-pr-description`, and the exact PR-scoped `stack push` command to
re-run when a custom `--base`, `--prefix`, or PR scope was used. PR description
bases follow GitHub semantics: the root PR compares against its base branch and
each child PR compares against its parent branch.

The canonical long-form guide is `llm/stack/README.md`.

## Rules for agents

1. **Do not bypass `pg`.** `stack sync` only flags which leases go stale — it
   never revokes or re-approves. After `stack sync` moves a branch tip, the
   user must re-run `pg` on that branch unless an approved async lease covers
   the new tip and scope. `stack push` prepares briefs and runs `pg push`
   against fresh or valid async leases, but every new authorization still
   requires the human to run `pg`. Never set bypass env vars or pipe automated
   confirmation into the approval prompt.
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

`stack status --json` is PR-scoped unless `--implicit` is passed. Broad local
ancestry inference requires `stack status --implicit --json` and emits:

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
