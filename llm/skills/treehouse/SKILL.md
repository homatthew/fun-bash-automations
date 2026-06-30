---
name: treehouse
description: Use when you need an isolated, pre-warmed git worktree to run an agent (or several agents) on a repo in parallel without colliding on the working tree. Triggers — "worktree", "run agents in parallel", "isolated checkout", "treehouse", or any crew/fan-out that must not stomp the main checkout. Replaces the retired cwt()/worktree-dev tooling.
---

# treehouse — pooled, pre-warmed git worktrees

Treehouse maintains a **pool** of reusable git worktrees so multiple agents can
work on the same repo in parallel. It is the substrate under firstmate crews and
under any manual parallel work. It replaced the homegrown `cwt()` helper and the
`worktree-dev` skill.

## When to use

- You (or firstmate) need a clean, isolated checkout to run an agent in, separate
  from the primary working tree.
- You want several agents on the same repo at once without working-tree
  conflicts.
- You want disposable worktrees that are pruned automatically when idle.

Do **not** hand-roll `git worktree add` for agent isolation — use the pool.

## Invocation

```bash
treehouse init                 # one-time: write a default treehouse.toml in the repo
treehouse get                  # acquire a worktree and drop into a subshell in it
treehouse get --lease          # non-interactive: reserve a worktree, print only its
                               # absolute path to stdout (banners go to stderr).
                               # A leased worktree is never reused or pruned until released.
treehouse status               # show all worktrees in the pool and their state
treehouse return <path>        # terminate lingering processes and return/release a worktree
treehouse prune                # remove stale worktrees and opted-in orphans
treehouse destroy              # remove worktrees from the pool
```

## How it fits

- **Substrate**: firstmate crewmates each get a disposable treehouse worktree.
- **Manual parallel work**: `treehouse get` for an interactive isolated shell;
  `treehouse get --lease` when a script/agent needs the path without a subshell.
- Always `treehouse return <path>` (or let prune reclaim it) when done so the pool
  stays healthy.

## Notes

- Config lives in the repo's `treehouse.toml` (created by `treehouse init`).
- Leasing is durable across processes — a leased worktree survives until an
  explicit `treehouse return`.
