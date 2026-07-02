---
name: firstmate
description: Use to run a CREW — several independent project tasks in parallel (fixes, investigations, plans, audits) without tab-juggling. Triggers — "run these in parallel", "spawn a crew", "work the backlog", "firstmate", "ship N tasks". firstmate is the breadth tool (many tasks, one liaison). For depth on one objective use gnhf; for a single change use /ship.
---

# firstmate — talk to one agent, ship with a crew

firstmate is **not a CLI and not a binary** — it is an `AGENTS.md`-driven
orchestrator directory at `~/repos/firstmate`. You launch your agent harness
*inside* that directory and its `AGENTS.md` takes over: you become the **captain**
and talk only to the **first mate**, which dispatches autonomous crewmates, each
in its own tmux window and disposable **treehouse** worktree, supervises them, and
hands back finished PRs, approved local merges, or investigation reports.

## When to use

- You have **multiple independent tasks** to run at once (parallel fixes,
  investigations, plans, audits) and don't want to babysit tabs.
- You want to drain a backlog (e.g. `bd ready`) through the crew.
- Each task should run isolated and ship through each project's delivery mode.

Pick firstmate for **breadth** (many tasks, one liaison). Pick **gnhf** for
**depth** (one objective, many iterations). Pick **/ship** for a single change.

## Invocation

```sh
cd ~/repos/firstmate
claude                  # (or your harness) — AGENTS.md takes over; you are the captain
> ahoy! fix the flaky login test, investigate the slow query, and draft the cache plan
```

The first mate then checks its toolchain (asking consent before installing),
clones/locates projects under `projects/`, and spawns crewmates
(`fm-<task>-<id>`) in tmux windows.

## How it fits the stack

- **Substrate**: crewmates work in disposable **treehouse** worktrees.
- **Gate**: ship tasks follow each project's delivery mode — for our repos that is
  the **no-mistakes** gate. Scout/investigation tasks produce local reports and
  push nothing.
- **Gate isolation**: each crewmate worktree gets its own `NM_HOME` (derived by
  `nm-home`) so parallel no-mistakes runs use separate state, sockets, and
  daemons instead of serializing or contaminating each other. Branch names must
  still be unique per task because the remote git host and PR namespace are
  shared.
- **Read-only by construction** over your projects except clean default-branch
  refreshes, safe local-branch pruning, and approved `local-only` fast-forward
  merges.
- **Backlog**: beads is the source of truth; firstmate's markdown backlog is a
  one-way projection of `bd ready`/`bd list` (see the beads→firstmate bridge,
  q9v.12). The crew closes beads back (`bd close`) on merge.
- For larger fleets, route domains to persistent **secondmates** via
  `data/secondmates.md`.

## Config

- Home/state seeded via `bin/fm-bootstrap.sh` / `bin/fm-home-seed.sh`.
- Per-project mode via `bin/fm-project-mode.sh`; backlog via the `tasks-axi`
  markdown backend (`bin/fm-tasks-axi-lib.sh`, `.tasks.toml`).
- A thin `fm` launcher + checked-in `captain.md`/`projects.md` baseline is
  Track-2 I5.
