---
name: setup-explain
description: Explain how the user's Kun-stack agent setup works and the expected day-to-day way to use it. Trigger when the user asks "how does my setup work", "explain my setup", "how am I supposed to use this", "what's the workflow here", "which tool do I use for X", "/setup-explain", or otherwise seems unsure which tool or command to reach for.
---

# /setup-explain — how your agent setup works

When invoked, explain the setup below to the user, tailored to what they asked
(the whole thing, or just the slice they're unsure about). Keep it concise and
scannable. This file is the canonical summary; if anything here disagrees with
`llm/sanctioned-paths.md`, `llm/AGENTS.md`, or a tool's own `SKILL.md`, those win
— skim them first if the user asks about a detail. Offer to render the overview
as a lavish artifact (`plan-to-lavish` / lavish) if they'd like it visual.

## The mental model (one line)

**beads = the task graph · firstmate = the crew · treehouse = the substrate ·
no-mistakes = the gate · gnhf = the long-run loop · lavish = the plan/review UI.**

You are the **captain**: you talk to one agent and it runs the rest. You only
have to touch two gates — **approve the plan**, and **answer findings / review
the PR**. Everything between those is automated.

## The day-to-day flow

1. **Track work in beads.** `bd ready` is your queue; beads is the source of
   truth and survives compaction. Everything else is downstream of it.
2. **One change → `/ship`.** Work on a feature branch, then `/ship`: it verifies,
   `/simplify`s, and hands off to the **no-mistakes** gate (automated review →
   test → lint → docs → push → PR). Never push straight to `main`.
3. **Many tasks → firstmate (`fm`).** Launch the crew with `fm`; talk to the
   first mate as captain. It spawns crewmates in tmux windows, each in its own
   **treehouse** worktree, supervises them, and ships each through the same
   no-mistakes policy. For parallel gate runs, firstmate gives every crewmate a
   per-worktree `NM_HOME`, so no-mistakes state/socket/gate-repos/database/daemon
   data stays isolated even when tasks target the same repo.
4. **One deep/long objective → `gnhf`.** For "keep going until X" work; always
   bound it (`--max-iterations` / `--max-tokens`). Per-repo tuning via a
   committed `.gnhf.yml` + `gnhf-here`.
5. **Review before the gate → the `code-review` skill.** The one deep-review
   entrypoint (dual Claude+Codex). `no-mistakes` is the automated gate on top.
6. **Self-hosted GitHub / Netflix GHE repos:** authenticate `gh` for the host
   (`gh auth login --hostname git.netflix.net`) and let no-mistakes own PR
   creation/CI. `nm-ghes-pr` is only a legacy fallback if a run explicitly skips
   PR creation after the branch was validated and pushed.

## Which tool for which job

| You want to… | Reach for |
|---|---|
| Finish + ship one change | `/ship` (→ no-mistakes → PR) |
| Run several tasks in parallel | `fm` (firstmate crew) |
| Grind one objective to done | `gnhf` (bounded) |
| An isolated checkout to work in | `treehouse get` |
| A deep code review | the `code-review` skill |
| The automated ship gate | `no-mistakes` |
| See fleet / gate / pool state | `kun-status` |
| Feed `bd ready` into firstmate | `bd-firstmate-bridge` |
| Render a plan for human review | `plan-to-lavish` / lavish |
| Check the stack is installed right | `kun-stack-verify` |

Full "one sanctioned path per function" reference: `llm/sanctioned-paths.md`.

## Commands cheat-sheet

```
/ship                     finish + gate one change (single entrypoint)
fm                        launch firstmate (the crew), you = captain
gnhf "objective" --max-iterations N     bounded long-run loop
treehouse get [--lease]   acquire an isolated worktree
no-mistakes / no-mistakes axi run        run the gate
nm-ghes-pr                legacy fallback if GHES PR creation is skipped
eval "$(nm-home --for "$PWD" --mkdir --export)"    explicit per-worktree NM_HOME for manual gates
kun-status                one-glance TOON status of the stack
bd ready                  your task queue (source of truth)
bd-firstmate-bridge       project bd ready -> firstmate backlog (one-way)
kun-stack-verify          verify the pinned stack is installed
plan-to-lavish <plan.md>  render a plan to a lavish review surface
```

## The guardrails (never weakened)

The git-level main pre-push hook + `bash-safety-guard.sh` block direct pushes to
`main`/`master`/`develop`/`trunk`, bare/ambiguous pushes, and plain
`git push --force`. push-gate/stack/ralph are retired; the main-branch
protection is the one surviving piece. Details: `llm/command-guard-policy.md`.

## Go deeper

- `llm/AGENTS.md` — shared policy (work modes, delivery/gate policy)
- `llm/sanctioned-paths.md` — one path per function
- `llm/no-mistakes-stages.md` — what each gate stage does
- Per-tool `SKILL.md`: `treehouse`, `gnhf`, `no-mistakes`, `firstmate`, `ship`
