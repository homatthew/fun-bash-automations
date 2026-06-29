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
main-branch guard and `bash-safety-guard.sh` always backstop you — `/ship`
never bypasses them.

Do not stop at analysis. Do not leave "next steps" unless blocked. Do not claim
code works unless you ran the checks.

## The shape

```
plan → work on a feature branch → verify on the real surface → /simplify → no-mistakes gate → PR
```

`/ship` is explicit permission to finish the delivery workflow for the current
task. It is **not** permission to push to a protected branch, to force-push, or
to bypass the gate.

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
git switch -c mho/<short-topic>          # if on a protected branch
```

The main-branch guard will block a protected-branch push regardless, but switch
early so commits land in the right place.

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

Hand the change to the **no-mistakes** gate. Invoke the `no-mistakes` skill (or
run `no-mistakes`), which validates the change — automated code review, tests,
lint, docs — and only then pushes to the configured target and opens/updates
the PR. Do not hand-roll `git push` + `gh pr create`; the gate owns the push so
the pipeline runs.

- First time in a repo: `no-mistakes init` (one-time; sets up the gate).
- Then: `no-mistakes` to run the pipeline for the current branch.
- Re-run after fixes: `no-mistakes rerun`.

If a step fails, fix it and re-run — do not `--skip` a real failure to get
green.

## Step 7 — Many tasks? Use firstmate

`/ship` lands **one** change. When the work is a set of independent tasks (e.g.
draining `bd ready`), let **firstmate** orchestrate: it pulls the backlog, runs
each task in a treehouse worktree, and ships each through this same
no-mistakes gate. `/ship` is the single-task path; firstmate is the breadth
path. They share the same gate, so the contract is identical.

## What `/ship` does NOT do

- It does not bypass the main-branch guard or `bash-safety-guard.sh`.
- It does not push to `main`/`master`/`develop`/`trunk`.
- It does not force-push, and it does not `--skip` a failing gate step to fake
  a green run.
