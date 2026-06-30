---
name: gnhf
description: Use for a long-running, autonomous single-agent loop on one objective — "keep going until X", overnight/unattended runs, large sweeps (mass refactors, grep-and-fix across a tree), or "ralph it". gnhf is the depth tool (one objective, many iterations). Replaces the retired ralph loop. For breadth across many tasks use firstmate; for a one-shot wake-up use ScheduleWakeup.
---

# gnhf — autonomous long-run agent loop

"Before I go to bed, I tell my agents: good night, have fun." gnhf drives a single
coding agent in an iterative loop against one objective until a stop condition is
met. It replaced the homegrown ralph loop.

## When to use

- One objective that needs many iterations: "fix every call site", "make the
  suite green", "migrate all of X".
- Unattended / overnight runs where you want bounded autonomy.
- A bounded sweep inside a treehouse worktree (e.g. a legacy-ref grep-and-fix).

Pick gnhf for **depth on one goal**. Pick **firstmate** for **breadth across
independent tasks**. Pick `/loop` for polling and `ScheduleWakeup` for a single
deferred wake.

## Invocation

```bash
gnhf "make the test suite pass"               # run the loop on an objective
gnhf --max-iterations 20 "..."                # ALWAYS bound unattended runs
gnhf --max-tokens 2000000 "..."               # or bound by token budget
gnhf --agent claude "..."                     # choose the agent (claude, codex, ...)
gnhf --worktree "..."                         # run in its own git worktree (parallel-safe)
gnhf --current-branch "..."                   # run on current branch instead of a new gnhf branch
gnhf --stop-when "all tests pass" "..."       # end when the agent reports this condition
```

## How it fits

- gnhf creates and pushes its own `gnhf/<...>` working branch and ships through
  the **no-mistakes** gate (see `agent-push-policy.json` → `gnhf_branches`).
- For parallel long-runs, combine with treehouse (`--worktree`) so multiple loops
  don't collide.
- **Always pass `--max-iterations` or `--max-tokens`** for unattended runs to cap
  cost and prevent runaways.

## Config

- Global config: `~/.gnhf/config.yml` (agent, default args, commit preset).
- Per-repo overrides: commit a `.gnhf.yml` and run `gnhf-here` (see
  `llm/gnhf-per-repo-config.md`).
