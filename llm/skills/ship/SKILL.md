---
name: ship
description: Finish the task end-to-end and ship it - plan, verify for real, get an independent-model code review, then push and open a PR. Trigger when the user says /ship, /go, "ship it", "finish the job", or clearly wants plan-first execution, real verification, and a PR.
---

# /ship

`/ship` means: finish the job for real, then ship it.

This is the one finish-the-job entrypoint. It is deliberately a **thin, local,
fast** workflow: you run the repo's own checks, you get one independent model to
review the diff, you fix what it finds, you push. There is no daemon, no
pipeline state machine, and no multi-minute gate between you and a push.

```
plan → feature branch → verify → independent review → fix → commit → push → PR
```

Do not stop at analysis. Do not leave "next steps" unless blocked. Do not claim
code works unless you ran the checks.

## Step 1 — Plan first

If no short execution plan exists, write one. Each step gets a Goal, the files
it Touches, a Verification method, and an Exit criterion. If the existing plan
is vague, rewrite it into that shape before continuing.

Skip this only for a genuine one-liner.

## Step 2 — Be on a feature branch

Never work on `main`/`master`/`develop`/`trunk`:

```bash
git rev-parse --abbrev-ref HEAD          # confirm where you are
git switch -c feature/<short-topic>      # if on a protected branch
```

`bash-safety-guard.sh` and the git-level pre-push hook block protected-branch
pushes. That backstop stays regardless of what this skill does.

## Step 3 — Execute, verifying as you go

One step at a time. Before starting the next step: run that step's verification,
**read the output** (not just the exit code), and fix failures or update the plan
if reality changed.

## Step 4 — Verify on the real surface

Use the strongest verification the repo actually supports, in order:

1. End-to-end CLI / API flow
2. Browser or computer-use flow
3. Focused automated tests
4. Static checks / typecheck / lint / build

Run the repo's real commands — its test runner, its linter, its build. Unit
tests alone are not enough when the user-facing path can be exercised directly.
Paste the failing output when something fails; never summarize a failure as
"mostly passing".

## Step 5 — Independent review, sized to the change

Pick the tier the change actually warrants. Escalating on habit rather than risk
is what makes a workflow something people route around.

| Tier | When | Legs |
| --- | --- | --- |
| **0 — none** | `wip/`, `scratch/`, `gnhf/`, `tmp/`, `experiment/`, `*yolo/` branches; throwaway spikes | none |
| **1 — one leg** *(default)* | Ordinary feature/fix branch headed for a PR | Codex `gpt-5.6-sol` |
| **2 — three legs** | Risky or wide (below), or on request | + Cursor `claude-opus-5-thinking-high`, Cursor `kimi-k3-high` |

**Escalate to tier 2** when the diff touches security guards, hooks, auth,
credentials, or push/delivery policy; can lose data or is hard to reverse; is
wide (roughly >400 lines or >15 files); or changes behaviour the user cannot
easily re-verify.

**When you do review, use a different model than the one that wrote the code.**
Self-review by the authoring model reproduces the authoring model's blind spots,
which is the whole reason this step exists. Treat reviewer output as dissent to
verify, not as truth.

| Model | How |
| --- | --- |
| Codex `gpt-5.6-sol` | `codex:codex-rescue` subagent, or `codex exec` |
| `claude-opus-5-thinking-high` | `cursor-sub-review` skill |
| `kimi-k3-high` | `cursor-sub-review` skill |

**Launch past the user's aliases.** `codex` and `claude` are aliased in the
user's shell to `--dangerously-bypass-approvals-and-sandbox` and
`--dangerously-skip-permissions`. Those flags land before the subcommand and beat
the `-s read-only` you add after it, so a review leg started as `codex exec -s
read-only` ran with `sandbox: danger-full-access` and every MCP server loaded.
Use the resolved binary and confirm the posture it prints:

```bash
"$(whence -p codex)" exec -s read-only -c 'mcp_servers={}' "$prompt"
#   header must say: approval: never / sandbox: read-only
```

If the header disagrees with what you asked for, kill it and relaunch. A leg
whose permissions you could not confirm is not a read-only review.

Sequencing: the Codex leg is a native subprocess and may run alongside one
Cursor leg. The two Cursor legs **must run sequentially** — Cursor's
`~/.cursor/cli-config.json` is user-level state and concurrent runs race;
worktrees do not isolate it.

Give every reviewer the same package: the **actual diff** (not "look at the
current files"), the user's intent in their own words, the files changed, the
verification you already ran, and an explicit ban on edits and git writes. Ask
for introduced defects with file/line evidence only.

Then triage. Fix real defects. Reject style churn, pre-existing issues, and
anything the user explicitly chose. Re-run the relevant verification after
fixing. Report what the reviewer caught that you missed — that is the signal
worth surfacing.

**Skipping is allowed and does not need permission.** If review does not fit —
throwaway work, already reviewed, the user asked you to stop, or it plainly is
not worth it — say `skipping review: <reason>` in one line and continue. What is
not allowed is skipping silently or claiming a review you did not run.

For the deep multi-phase version — hypothesis forming, consolidation, targeted
deep dives — use the `code-review` skill instead. `/ship` runs the cheap subset
on purpose.

### On yolo branches

Don't review continuously. Review the **end state** once: before promoting to a
delivery branch, before handing off, or when the user asks. In between, just keep
it running.

## Step 6 — Simplify

Run `/simplify` (and `/ai-slop-removal` for AI-generated churn). Re-run the
relevant verification afterward.

## Step 7 — Record the review, commit, and push

Before creating PRs, choose the delivery topology from the actual final diff.
Do not turn commit boundaries into PR boundaries automatically. For more than
one PR, present a short table with each PR's claim, base, independently usable
result, deployment safety boundary, and verification; get explicit user
approval before publishing the stack. If a layer needs a later PR to become
correct, reviewable, or useful, keep the layers as ordered commits in one PR.

Check for an existing live PR or stack for the same objective. Update it when
its topology is still valid; otherwise close or explicitly supersede it before
opening a replacement. Never leave multiple speculative stacks open while the
contract is still changing.

```bash
git add <the files that belong to this task>
git commit -m "..."
~/.claude/hooks/self-review-guard.sh --mark-reviewed
git push origin <branch>
```

Commit only what belongs to the user's task; preserve unrelated pre-existing
changes. Then open or update the PR (`gh pr create` / `gh pr edit`), unless the
repo is a configured direct-delivery target.

`--mark-reviewed` tells the Stop-event guard this diff has been through review.
Run it **because you actually did steps 4-5**, never to silence the guard. If you
skipped review, say so instead — the guard prompts only once per diff and will
not trap you.

Keep the PR reviewable: aim for **under ~400 changed lines and ~15 files** when
the change has natural boundaries, and keep one reviewable claim per PR. If the
description needs "and also", split it. Land refactors separately from behaviour
changes. Size is a review signal, not permission to invent unsafe or useless PR
boundaries; use one coherent PR with ordered commits when that is the honest
merge and deployment unit.

## Step 8 — Many tasks? Use firstmate

`/ship` lands **one** change. For a set of independent tasks (e.g. draining
`bd ready`), let **firstmate** orchestrate: each task in its own treehouse
worktree, each shipped through this same workflow. Keep branch names unique per
task.

## What `/ship` does NOT do

- It does not bypass the main-branch guard or `bash-safety-guard.sh`. Those are
  hard controls and stay hard, at every tier.
- It does not force-push.
- It does not push to a protected branch except a configured direct-delivery
  target, after an explicit user ask.
- It does not claim a review it did not run, and it does not skip one silently.

## Heavier gate, on request

`no-mistakes` (full pipeline: intent, rebase, review, test, document, lint, push,
PR, CI monitoring) is **opt-in, not the default**. It is a good tool for a large
or unfamiliar change you want babysat end to end; it is the wrong default because
its cost does not scale down to a two-line fix. Reach for the `no-mistakes` skill
only when the user explicitly asks, and note the repo needs `no-mistakes init`
first. Do not treat it as a precondition for pushing.
