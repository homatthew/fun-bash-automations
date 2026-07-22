---
name: ship
description: Finish the task end-to-end and ship it through the no-mistakes gate. Trigger when the user says /ship, /go, "ship it", "finish the job", or clearly wants plan-first execution, real verification, and a PR. Thin successor to the retired /go — delegates delivery to no-mistakes (+ firstmate for multi-task breadth).
---

# /ship

`/ship` means: finish the job for real, then take it through the gate.

This is the one sanctioned finish-the-job entrypoint. It replaces the retired
`/go` + the whole push-gate/stack/PR ceremony. The delivery mechanism is now
**no-mistakes** (the automated gate) on a feature branch; **firstmate**
orchestrates when there is more than one task to land. The git-level
main-branch guard and `bash-safety-guard.sh` always backstop you; configured
direct-delivery exceptions still go through the gate.

Do not stop at analysis. Do not leave "next steps" unless blocked. Do not claim
code works unless you ran the checks.

## The shape

```
plan → feature branch → verify → /simplify → no-mistakes gate → PR or direct-delivery target
```

`/ship` is explicit permission to finish the delivery workflow for the current
task. It is **not** permission to force-push or bypass the gate. A configured
direct-delivery repository may target its protected delivery branch through the
gate.

## Step 1 — Plan first

If no short execution plan exists, write one. Break the work into small steps;
each step has a Goal, the files/surface it Touches, a Verification method, and
an Exit criterion. If the existing plan is vague, rewrite it into that shape
before continuing.

## Step 2 — Be on a feature branch

Never work on `main`/`master`/`develop`/`trunk`. If you are on one, create a
feature branch first:

```bash
git rev-parse --abbrev-ref HEAD          # confirm where you are
git switch -c feature/<short-topic>      # if on a protected branch
```

The main-branch guard blocks unconfigured protected-branch pushes. Work still
starts on a feature branch even when the configured delivery target is `main`.

## Step 3 — Execute with gates

Work one step at a time. Before starting the next step: run the listed
verification, read the result (not just the exit code), and fix failures or
update the plan if reality changed.

## Step 4 — Verify on the real surface

Prefer the strongest realistic verification available, in order:

1. End-to-end CLI / API flow
2. Browser or computer-use flow
3. Focused automated tests
4. Static checks / typecheck / lint / build

Unit tests alone are not enough when the user-facing path can be exercised
directly.

## Step 5 — Simplify

Once the code works, run `/simplify` (and `/ai-slop-removal` for AI-generated
churn). Re-run the relevant verification afterward.

## Step 6 — Ship through the gate

Hand the change to the **no-mistakes** gate. Invoke the `no-mistakes` skill or,
for agent-driven work, drive `no-mistakes axi run --intent "..."`. It validates
the change — automated code review, tests, lint, docs — and only then pushes to
the configured target and opens/updates a PR when applicable. Do not hand-roll
`git push` + `gh pr create`; the gate owns the push so the pipeline runs.

- First time in a repo: `no-mistakes init` (one-time; sets up the gate).
- Then: `/no-mistakes` or `no-mistakes axi run --intent "..."` for agents;
  humans may use the bare `no-mistakes` TUI.
- Re-run after fixes: `no-mistakes rerun`.
- **Self-hosted GitHub:** upstream no-mistakes routes through the `gh` CLI.
  Authenticate the configured host first; the gate should then own PR creation
  and CI polling. Keep environment-specific fallback helpers in a private
  overlay.

If a step fails, fix it and re-run — do not `--skip` a real failure to get
green.

## Step 7 — Many tasks? Use firstmate

`/ship` lands **one** change. When the work is a set of independent tasks (e.g.
draining `bd ready`), let **firstmate** orchestrate: it pulls the backlog, runs
each task in a treehouse worktree, and ships each through the same no-mistakes
policy. For parallel tasks, firstmate also gives each crewmate a distinct
per-worktree `NM_HOME`, which isolates no-mistakes state, sockets, gate repos,
database, and daemon. `/ship` is the single-task path; firstmate is the breadth
path. Keep branch names unique per task because remote branches and PRs are
still shared at the git host.

## What `/ship` does NOT do

- It does not bypass the main-branch guard or `bash-safety-guard.sh`.
- It does not hand-push to protected branches; only a configured direct-delivery
  target may receive a gate-owned push.
- It does not force-push, and it does not `--skip` a failing gate step to fake
  a green run.
