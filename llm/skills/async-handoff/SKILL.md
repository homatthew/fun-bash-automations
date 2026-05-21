---
name: async-handoff
description: "Prepare reviewed async push-gate leases for plan-backed unattended work. Use when the user asks for an async lease, overnight/background implementation, or asks an agent to keep working and push within an approved scope."
---

# Async Handoff

Use this skill when a human wants an agent to continue implementing after
approval, possibly while the human is away. The goal is a reviewed work package,
not a push-gate shortcut.

## Hard Rules

- Re-read and follow the `push-gate` skill before any `pg` command.
- Never use bypass flags, piped confirmations, manual lease edits, or direct
  `git push`.
- Do not create an async lease from a vague request. First capture the problem,
  hypothesis, plan, expected scope, verification, and risks.
- The human must run the approval command in an interactive terminal. The agent
  prepares the lease and later pushes with `pg check` plus `pg push`.
- If `pg check` says the lease is expired, out of budget, rewritten without
  approval, or outside scope, stop and re-prepare for human review.

## Branch Flow

1. Confirm the work package.
   - Problem: what is broken or desired.
   - Hypothesis: what likely needs to change and why.
   - Plan: ordered slices with verification per slice.
   - Scope: expected files, commands, docs, tests, and out-of-scope areas.
   - Risks: uncertainty, likely follow-up approval triggers, rewrite needs.
2. Prepare the async lease from the repo root.

```bash
pg prepare --async --expires 8h --max-pushes 20 \
  --what "Implement <observable feature/fix>" \
  --why "<user-visible reason>" \
  --approach "<planned slices and verification surface>" \
  --scope "mixed" \
  --risks "<known caveats or approval triggers>"
```

3. Ask the human to approve in their terminal.

```bash
pg -C /absolute/path/to/repo
```

4. Continue implementation only inside the approved work package.
5. Before every push, validate the lease.

```bash
pg check | jq '{allowed, reason, current, async_iteration}'
```

6. Push only when allowed.

```bash
pg push --assert-flow $'update PR #<number>\nbranch <branch>\n<approved work package summary>\nno rewrite'
```

Use `--allow-rewrite` on `pg prepare` only when the reviewed plan explicitly
requires rebases, squashes, or force-with-lease updates.

## Stack Trunk Flow

Use the stack flow when the approved work spans multiple dependent PR branches.

1. Write stack context with item-level briefs.

```bash
stack trunk context write --stack <stack-name> --file context.yaml
```

2. Prepare the reviewed trunk lease.

```bash
pg prepare-trunk --stack <stack-name> --from-context \
  --async --expires 8h --max-pushes 30 --allow-rewrite
```

3. Ask the human to approve the trunk.

```bash
pg trunk --stack <stack-name>
```

4. Validate and push through stack tooling.

```bash
pg check-trunk --stack <stack-name>
stack trunk push --stack <stack-name>
```

The trunk async scope is narrow: stack name, private trunk ref, manifest hash,
item ids, and branch names must remain inside the approved shape. New branches
or changed item identities require a new reviewed prepare.

## Context Template

Use this before preparing the lease:

```markdown
## Async Work Package
- Repo:
- Branch or stack:
- Problem:
- Hypothesis:
- Plan:
- Expected files or path prefixes:
- Verification:
- Out of scope:
- Risks:
- Async lease:
  - expires:
  - max pushes:
  - rewrite allowed:
- Approval command for human:
- Push assertion the agent expects to use:
```

## Dry-Run Example

For a branch-only feature:

```bash
pg prepare --async --expires 8h --max-pushes 20 \
  --what "Implement push-gate approval readability and local review workflow" \
  --why "Make human approval faster, clearer, and agent-actionable before pushes" \
  --approach "Split into reviewed slices for approval rendering, diff stats, review-diff, queue UX, fixtures, and docs" \
  --scope "mixed" \
  --risks "Unrelated paths, unexpected rewrites, or exhausted push budget require re-approval"
```

Then tell the human:

```bash
pg -C /Users/matthewho/repos/fun-bash-automations
```

After approval and implementation:

```bash
pg check | jq '{allowed, reason, current, async_iteration}'
pg push --assert-flow $'update PR #3\nbranch mh-netflix\npush-gate approval readability and local review workflow\nno rewrite'
```

## Handoff Notes

- Keep the lease text broad enough to cover the reviewed implementation slices,
  but concrete enough that unrelated files and commit subjects are blocked.
- Prefer one async work package per coherent feature. Do not pack unrelated
  cleanup into the same approval just to avoid a second review.
- If the agent discovers a materially different solution, stop and re-prepare.
- Close or update beads only after the relevant verification actually ran.
