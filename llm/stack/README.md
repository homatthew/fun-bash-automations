# stack

`stack` is a guided workflow for stacked PRs. It exists because raw git
ancestry, GitHub PR bases, CI state, and push-gate leases are separate sources
of truth. Looking at only one of them makes an agent guess what is safe; `stack`
puts them in one view and ends each human-readable command with `Next step:`.

## Core Model

For PR-scoped workflows, GitHub PR `baseRefName` is authoritative. Local branch
ancestry is diagnostic: it can reveal stale local topology, redundant branches,
or restack work, but it does not override the PR DAG. When `stack` prints a
topology warning, operationally it means: GitHub PR base wins; local ancestry is
stale/diagnostic.

After a Dolt-backed private trunk is materialized, the final branch in a stack
may have the private trunk as its nearest local parent. `stack status`
recognizes that recorded materialization and prints it as an expected topology
note instead of stale local ancestry; GitHub PR bases still win for PR-scoped
commands.

Prefer PR-scoped commands when a PR number is known:

```bash
stack status --pr <N> --children
stack checkout --pr <N>
stack push --pr <N> --children
```

Broad `stack push` remains supported, but it can include unrelated same-prefix
local stacks. Use it only when that broad scope is intentional.

For codified stacks, the stack can own a private trunk. This trunk is a normal
local branch for one stack, not `main`. The manifest declares item order, the
private trunk ref, and the pointer branches. The manifest source of truth is
push-gate's Dolt store at `~/.push-gate/dolt-store` by default, not a repo
`.stack` file. `stack trunk materialize` builds that trunk in scratch,
hard-points each branch to its corresponding commit on the trunk, and records
the materialization back to Dolt.

Dolt must be on PATH for `--stack` trunk commands. Dotfiles installs it during
workspace utility bootstrap; otherwise install it with `brew install dolt`,
verify with `dolt version`, and set `PG_STORE_DIR` only if the default store
location should be overridden.

Private trunk refs must be private branches such as
`mho/trunk/scm-cassandra-dev`; protected refs like `main`, `origin/main`, and
`upstream/main` are rejected.

## Standard Loop

1. Inspect the stack:

   ```bash
   stack status --pr <N> --children
   ```

2. If the output says topology is stale or the base moved, run the recommended
   `stack sync` or `stack squash --pr <N> --onto-pr-base`.

3. To edit that PR, check out the branch through the guided workflow:

   ```bash
   stack checkout --pr <N>
   ```

4. Commit the edit, then squash the PR against its GitHub base:

   ```bash
   stack squash --pr <N> --onto-pr-base
   ```

5. If a new branch needs to go between this PR and its children, insert it
   through the scratch-preflight workflow:

   ```bash
   stack insert --branch <new-branch> --after-pr <N>
   ```

   This restacks PR children selected by GitHub `baseRefName`. It does not
   retarget GitHub PR bases; create or retarget PRs separately after refs move.

6. For a codified private-trunk stack, update the stored manifest order and
   materialize it:

   ```bash
   stack trunk init --name <name> --base origin/main --trunk mho/<name>.trunk
   stack trunk add --stack <name> --id <id> --branch <branch>
   stack trunk move --stack <name> --id <id> --after <id>
   stack trunk list --json
   stack trunk status --stack <name>
   stack trunk materialize --stack <name>
   ```

   The private trunk becomes the generated stack integration branch; each PR
   branch is moved to the commit it owns on that trunk.

7. Run the affected tests after refs move.

8. Dry-run the push to see exact ordering and the first approval:

   ```bash
   stack push --dry-run --pr <N> --children
   ```

9. Run the live push:

   ```bash
   stack push --pr <N> --children
   ```

10. If `stack push` prepares a branch, the human runs the printed approval
   command:

   ```bash
   pg -C <repo>
   ```

11. Re-run the exact `stack push ...` command printed under `Next step:`.

12. Update PR descriptions. The root PR description should compare against its
   GitHub base; each child PR description should compare against its parent
   branch.

## Safety Model

Push-gate leases are per branch or per Dolt stack scope. Normal branch leases
approve the reviewed tip exactly. If `stack sync`, `stack insert`,
`stack trunk materialize`, or `stack squash` rewrites a branch and its
descendants, every moved branch with a normal lease is stale and needs human
review again. Async leases are opt-in: `pg prepare --async` or
`stack push --async` lets one review cover repeated pushes only while expiry,
push budget, branch/remote scope, semantic scope, and optional rewrite approval
still pass. There is no agent bypass. `stack push` prepares one branch, stops,
prints `pg -C <repo>`, and waits for the human before continuing on the next
invocation.

## Command Behavior

`stack status` shows git topology, GitHub PR state, CI, and pg lease state. The
human table ends with a safe next command. `stack status --json` stays pure JSON
for scripts.

`stack checkout --pr <N>` resolves an open PR to a local branch, refuses dirty
worktrees, checks out that branch, prints the PR-scoped stack context, and shows
the exact `edit -> commit -> stack squash --pr N --onto-pr-base -> test -> dry-run
push -> live push` flow. It intentionally does not absorb/fixup changes or add a
new stack model.

`stack sync` fetches the base remote, creates a scratch clone, runs PR-state
adoption and `git-branchless sync --pull`, then atomically imports changed refs.
Its next step says whether refs changed, which leases became stale, and whether
to run tests, inspect status, or push.

Stack-managed restacks turn on repo-local rerere before conflict-prone work:

```bash
git config --local rerere.enabled true
git config --local rerere.autoupdate true
```

`stack sync`, `stack insert`, `stack trunk materialize`, and `stack squash` do
this automatically for the working repo and scratch repos they create, and copy
the source repo's rerere cache into scratch before preflight. Separate clones
need their own repo-local rerere config and rerere cache/history; rerere does
not learn a conflict resolution in a clone that has never seen that conflict.

`stack insert --branch <new-branch> --after <branch>` inserts a local branch
after a local stack branch. `stack insert --branch <new-branch> --after-pr <N>`
uses GitHub PR `baseRefName` to choose child PRs under `N`, excluding no-PR
local children. Live runs create a scratch clone, rebase the inserted branch
onto the insertion point, rebase selected descendants onto the inserted branch,
and atomically import moved refs with old-tip verification. `--dry-run` prints
planned rebases without moving refs. The command reports stale push-gate leases
but does not change GitHub PR bases.

`stack trunk init` and `stack trunk add` write a stack manifest to push-gate's
Dolt store. `stack trunk list --json` lists only current-repo Dolt-backed
materialized stacks with manifest order, latest materialization, trunk approval,
PR details, and local/remote tip state. It intentionally omits inferred loose
branches from `stack status`. `stack trunk move` reorders existing items with `--after`,
`--before`, `--first`, or `--last`; `stack trunk remove` prunes an item and
compacts order. Removing the final item deletes the empty stack metadata, so it
no longer appears in `stack trunk list`. These commands only change manifest order. `stack trunk
materialize --stack <name>` reads that manifest, builds the private trunk in a
scratch clone by replaying item branches in manifest order, then atomically
moves the trunk ref and each item branch pointer to the corresponding commit on
that trunk. This is the declarative stack mode: change the stored order, run one
materialization, then test and push. `stack trunk status` prints the manifest
order, inferred patch bases, trunk ref, and pointer heads. `--manifest <path>`
remains available for compatibility/import flows, but it is not the durable
source of truth and does not record materializations. PR bases are validated or
retargeted separately; materialization only moves local refs.

If materialization moves the currently checked-out branch, `stack` refreshes the
worktree to the new `HEAD` after the atomic ref import. That prevents a clean
checkout from appearing dirty with inverse changes from the old branch tip.

Push-gate can approve the whole materialized trunk:

```bash
stack trunk context write --stack <name> --file /tmp/<name>-prepare-context.yaml
pg prepare-trunk --stack <name> --from-context
pg trunk --stack <name>
pg check-trunk --stack <name>
stack trunk push --stack <name>
```

For multi-item trunks, agents should store item-level explanations in the
durable context:

```yaml
brief:
  what: overall stack outcome
  why: why these items land together
  approach: how the trunk was built and verified
item_briefs:
  - id: first-item
    summary: item outcome
    motivation: item reason
    approach: item implementation approach
source:
  kind: agent
```

The trunk approval records the manifest hash, private trunk tip, and each item
branch commit in Dolt. `stack trunk push --stack <name>` then walks the approved
items and invokes `pg push --trunk-stack` for each branch, so each item commit
can be pushed from the private trunk without requiring a separate per-branch
lease.

Async trunk approvals still show SHA-specific materialization details in the
draft. Those SHAs are the initial reviewed/audited stack state. The async scope
is narrower and more durable: same stack name, same private trunk ref, same
manifest hash, same item ids, and same item branch names. With
`--allow-rewrite`, later materializations may move item commit SHAs inside that
unchanged scope until expiry or push budget is exhausted.

For squash-merge-heavy stacks, push only the composed validation ref first:

```bash
stack trunk push --stack <name> --tip
```

`--tip` pushes the private trunk ref at the approved `trunk_tip` and does not
push item branches. Use this when CI should run once on the full stack before
spending CI on intermediate review branches that may be invalidated by a parent
squash merge.

The approval draft shows each ordered stack item with:

- `brief`: required item-level `what`, `why`, and `approach`, preferably as
  YAML bullet lists.
- `pointer_commit`: exact branch tip approved for push.
- `base_commit`: effective review base.
- `contained_commits`: commits included in the item patch range.
- `changed_files`: paths grouped as readable labels like `added` or
  `modified`, not raw git status letters.
- `shortstat`: compact diff size for the item.

That restores branch-by-branch detail without losing the whole-stack approval
flow.

The canonical Stack Review command classifications live in
[`command-surface.md`](command-surface.md). Use that matrix when deciding which
commands remain primary UI actions, advanced diagnostics, compatibility paths,
or plumbing-only internals.

`stack squash` collapses a branch's incremental commits into one commit and
restacks descendants. Use `--pr <N> --onto-pr-base` when GitHub says a PR's base
differs from local ancestry. Its next step lists moved descendants, stale
leases, and the push command to continue.

`stack push --dry-run` prints the push order, identifies the first branch that
will prepare, and explains why downstream branches wait. `stack push` then walks
parents first, using fresh leases for `pg push` and stopping at the first missing
or stale lease after `pg prepare`.

## Edge Cases

- Merged parent PR: `stack sync` can adopt the new GitHub base and restack local
  descendants in scratch before touching real refs.
- New middle branch: `stack insert --branch <new> --after-pr <N>` can place a
  branch between an open PR and its PR children without manually rebasing each
  child branch.
- Private stack trunk: `stack trunk materialize --stack <name>` can rebuild a
  stack-specific trunk from the Dolt manifest and move branch pointers after
  changing manifest order. If the final branch sees that private trunk as its
  nearest local parent, status reports the recorded trunk materialization as
  expected rather than stale ancestry.
- Redundant local parent branch: PR-scoped status/push still follow GitHub
  `baseRefName`; local ancestry only triggers a warning.
- Unrelated same-prefix branches: use `--pr <N> --children` to exclude them.
- No-PR children: broad stack views include them; PR-scoped child traversal only
  follows branches with PRs in the GitHub DAG.
- Stale leases: any moved branch tip needs a fresh `pg` approval.
- Topology mismatch: GitHub PR base wins; use `stack squash --pr <N>
  --onto-pr-base` if the branch itself needs cleanup against the PR base.

## Agent Handoff

`stack push` prints an `Agent handoff:` block with a phase:

- `ready to push`: dry-run completed; run the printed live push command.
- `needs approval`: `pg prepare` completed; the human must run the printed
  `pg -C <repo>` command.
- `needs restack`: run the printed sync or squash command before pushing.
- `needs PR description update`: push completed; update PR descriptions with
  the correct base semantics.
- `done`: no further stack action remains.

Agents should copy the exact command from `Next step:` rather than reconstructing
the DAG manually.
