# Sanctioned Paths

One sanctioned tool per function in the Kun-stack agent workflow. There is
exactly one path per function — no ambiguous double-paths. Use the sanctioned
tool; do not reach for the deprecated or wrong-function alternative listed
beside it. When two tools could plausibly fit, this doc is the tiebreaker.

## Decision Table

| Function | Use this | Do NOT use |
| --- | --- | --- |
| Long-running single-objective autonomous loop (depth) | `gnhf` (bound with `--max-iterations` / `--max-tokens`) | ralph |
| Breadth across many independent tasks (a crew) | `firstmate` (you are the captain) | a hand-rolled loop, ad-hoc parallel shells |
| Polling / recurring checks on an interval | the `/loop` skill | a `gnhf` loop, a sleep loop |
| A single deferred one-shot wake-up | `ScheduleWakeup` | `/loop`, a sleep |
| Deterministic multi-agent orchestration (fan-out with loops/conditionals) | `Workflow` (explicit opt-in only) | firstmate, native Agent fan-out |
| Isolated parallel worktrees (substrate) | `treehouse` pool (`treehouse get` / `--lease`) | `cwt()`, worktree-dev, `proj()` |
| Finish-the-job / ship a single change | the `/ship` skill (drives no-mistakes) | `/go`, push-gate, hand-rolled push + PR |
| The automated delivery gate itself | `no-mistakes` | push-gate, stack, `pg` |
| Deep code review | the `code-review` skill + the no-mistakes gate | code-review plugin, pr-review-toolkit, test-code-reviewer |
| Plan-of-record / human plan review surface | `lavish` (lavish-axi); poll for annotations | inline prose plans, a second review tool |
| Canonical task graph / source of truth | `beads` (`bd`) | firstmate backlog as a tracker, any second tracker |
| In-session parallel research/edits | native Agent fan-out (Agent tool) | firstmate |
| Persistent, supervised, tmux-visible crew that ships through the gate | `firstmate` | native Agent fan-out |

## Notes

- **`gnhf`** — the bound autonomous loop for one objective, taken to depth.
  Always bound it with `--max-iterations` and `--max-tokens`. Replaced ralph.
- **`firstmate`** — the orchestrator defined by `~/repos/firstmate` `AGENTS.md`.
  You are the captain; crewmates run in treehouse worktrees. Use it for breadth
  across many independent tasks. firstmate also gives each crewmate a
  per-worktree `NM_HOME` and worktree-local `no-mistakes` remote so parallel
  no-mistakes runs do not share state, sockets, gate repos, databases, daemons,
  or gate remotes.
- **`/loop` skill** — recurring checks on a fixed interval. Not for one-shot
  work and not for single-objective depth.
- **`ScheduleWakeup`** — one deferred wake-up, once. Not a substitute for a
  recurring `/loop`.
- **`Workflow`** — deterministic multi-agent orchestration with loops and
  conditionals. Opt-in only, on explicit request; do not default to it.
- **`treehouse` pool** — the substrate for isolated parallel worktrees, via
  `treehouse get` / `--lease`. Replaced `cwt()` and worktree-dev. The kept
  `proj()` / `bootstrap-proj` is for multi-repo project layout, NOT agent
  isolation — do not use it to isolate agents. A worktree alone does not isolate
  no-mistakes; manual parallel gate runs need the matching per-worktree
  `NM_HOME` and worktree-local gate remote, e.g.
  `eval "$(nm-home --for "$PWD" --mkdir --activate --export)"`.
- **`/ship` skill** — finish-the-job for a single change. Drives the
  no-mistakes gate through validation, then pushes to a PR or configured
  direct-delivery target. Replaced `/go` and push-gate.
- **`no-mistakes`** — the one automated delivery gate. Not push-gate, stack,
  or `pg`. Never bypass it.
- **`code-review` skill** — the one deep-review path: dual Claude + Codex,
  run pre-gate, then backed by the no-mistakes automated gate. simplify,
  ai-slop-removal, and security-review are pre-gate passes that feed it. The
  code-review plugin, the standalone pr-review-toolkit, and the
  test-code-reviewer agent are deprecated in favor of this skill (dump-q9v.19).
- **`lavish` (lavish-axi)** — the plan-of-record and human plan-review surface.
  Annotations come back via `lavish-axi poll` (pull, not push).
- **`beads` (`bd`)** — the canonical task graph and source of truth.
  firstmate's backlog is a one-way generated projection of `bd ready` /
  `bd list` (dump-q9v.12), never a second tracker.
- **Native Agent fan-out vs `firstmate`** — use native Agent fan-out (Agent
  tool) for in-session parallel research and edits; use `firstmate` when you
  want persistent, supervised, tmux-visible crewmates that ship through the
  gate.
