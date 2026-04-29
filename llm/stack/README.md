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

Prefer PR-scoped commands when a PR number is known:

```bash
stack status --pr <N> --children
stack checkout --pr <N>
stack push --pr <N> --children
```

Broad `stack push` remains supported, but it can include unrelated same-prefix
local stacks. Use it only when that broad scope is intentional.

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

5. Run the affected tests after refs move.

6. Dry-run the push to see exact ordering and the first approval:

   ```bash
   stack push --dry-run --pr <N> --children
   ```

7. Run the live push:

   ```bash
   stack push --pr <N> --children
   ```

8. If `stack push` prepares a branch, the human runs the printed approval
   command:

   ```bash
   pg -C <repo>
   ```

9. Re-run the exact `stack push ...` command printed under `Next step:`.

10. Update PR descriptions. The root PR description should compare against its
   GitHub base; each child PR description should compare against its parent
   branch.

## Safety Model

Push-gate leases are per branch tip. If `stack sync` or `stack squash` rewrites a
branch and its descendants, every moved branch with an existing lease is stale
and needs separate human approval. There is no batch approval and no agent
bypass. `stack push` prepares one branch, stops, prints `pg -C <repo>`, and waits
for the human before continuing on the next invocation.

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
