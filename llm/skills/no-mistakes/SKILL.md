---
name: no-mistakes
description: Use to validate code changes through the no-mistakes gate (automated review, tests, lint, docs) before they reach the configured push target, then push + open/update the PR. Triggers — "gate", "ship safely", "validate my changes", "run no-mistakes", or any push/PR for a feature branch. This is the ONE automated delivery gate; /ship drives it.
---

# no-mistakes — the automated delivery gate

no-mistakes is a local git proxy that validates changes (code review, tests,
lint, docs) before they reach the configured push target, then pushes and
opens/updates the PR. It is the single sanctioned automated gate that replaced
the push-gate/stack pipeline. `/ship` and firstmate ship tasks both drive it.

> This repo-managed wrapper documents *when to reach for the gate and how*. The
> no-mistakes tool also ships its own richer skill; at deploy time (q9v.13)
> decide which projection wins for `~/.claude/skills/no-mistakes` to avoid a
> shadow.

## When to use

- You finished a change on a feature branch and want it shipped correctly.
- The user says "gate it", "ship", "validate and push", or runs `/ship`.
- A gnhf or firstmate run reached a ship point.

Always ship from a **feature branch**, never `main`/`master`/`develop`/`trunk` —
the git-level main guard and `bash-safety-guard.sh` block protected-branch pushes.

## Invocation

```bash
no-mistakes init        # one-time per repo: create the local gate bare repo,
                        # post-receive hook, and the "no-mistakes" git remote
no-mistakes             # run the pipeline for the current branch (interactive)
no-mistakes status      # status of the current repository's gate
no-mistakes rerun       # re-run after fixing a failed step
no-mistakes runs        # list pipeline runs
```

Agent-driven (token-efficient TOON, no prompts):

```bash
no-mistakes axi run      # validate; blocks until a decision point or outcome
no-mistakes axi          # show current pipeline state
no-mistakes axi respond  # answer the active approval gate and continue
no-mistakes axi logs     # show a step's log output
no-mistakes axi abort    # cancel the active run
```

## How it fits

- Default delivery path for `mho/`, `feature/`, `fix/`, `gnhf/*` branches
  (`agent-push-policy.json`). The gate owns the push (`git push no-mistakes`), so
  do not hand-roll `git push` + `gh pr create`.
- Pipeline stages are configured in `.no-mistakes.yaml` (sanctioned baseline at
  the FBA repo root; stage reference in `llm/no-mistakes-stages.md`).
- Default gate agent is **codex** (chosen for speed; set globally in
  `~/.no-mistakes/config.yaml`, seeded by `kun-stack-install`). Deep review still
  uses the dual Claude+Codex `code-review` skill. Override per-repo with `agent:`
  in `.no-mistakes.yaml`.
- If a step fails, fix and `rerun` — do **not** `--skip` a real failure to fake a
  green run.
