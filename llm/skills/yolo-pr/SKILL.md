---
name: yolo-pr
description: "Raw explicit-branch push + PR fast path on a yolo branch (mho-yolo/*). No push-gate, no editor, no lease. Use when the user wants the old branch -> push branch -> open a PR flow on a mho-yolo/ branch."
---

# YOLO PR (raw explicit push + PR on `mho-yolo/*`)

> **When to use:** the user wants the pre-push-gate flow back — branch,
> `git push origin mho-yolo/<topic>`, open a PR — with no `pg prepare`, no Neovim review, no lease.
> This works **only** on branches named `mho-yolo/<topic>` on any repo.
> For real delivery work use `/commit-push-pr` (push-gate) instead.

> **Related skills:**
> - `/commit-push-pr` — the push-gate delivery flow for non-yolo branches.
> - `/push-gate` — the approval policy this fast path deliberately skips.

## The one hard rule

A yolo branch can **never** target `main`/`master`/`develop`/`trunk`/any base
ref, and can **never** acquire a base ref as upstream. This is structural, not a
convention:

- The push allow is keyed on the resolved push **target** matching `mho-yolo/`.
  Base refs never match that prefix, so `git push origin mho-yolo/x:main`,
  `git push origin HEAD:main`, and friends all resolve their target to a base
  and are hard-blocked.
- Creating a yolo branch from a base ref **requires `--no-track`**, otherwise the
  bash-safety guard blocks it (the branch would adopt `origin/main` as upstream).

```bash
# ✅ correct — no upstream adopted from the base
git switch --no-track -c mho-yolo/<topic> origin/main

# ❌ blocked — would track origin/main
git switch -c mho-yolo/<topic> origin/main
```

## Autonomy: default still requires an explicit ask

The prefix **alone** mechanically allows the push — no session toggle is needed
to unblock it. But the autonomy default is the same soft rule as the direct-push
repos: **only push / open the PR after the user explicitly asks.**

Bare `git push` is never allowed. The command must name the target branch or
refspec so the hook can classify the push from the command text, not hidden
current-branch/upstream state.

- Default (`requires_explicit_user_ask: true`): do the branch + commits, then
  wait for the user to say "push" / "open the PR".
- Fully autonomous push + PR (e.g. an unattended run) is opt-in via
  `AGENT_WORK_MODE=yolo`. Only set it when the user has authorized unattended
  yolo delivery.

## Step 1: Branch

```bash
git switch --no-track -c mho-yolo/<topic> origin/main   # or any base ref
```

## Step 2: Commit

Before committing or pushing, shape the branch into reviewer-meaningful commits.
Each commit should be a unit a reviewer would care about, usually a feature,
behavior change, or independently reviewable refactor.

- Prefer feature commits that include the implementation and its tests together.
- Fold bug fixes for mistakes introduced during the same task back into the
  feature commit with `git commit --amend` or an interactive rebase.
- Do not leave "fix my previous commit", typo, formatting, cleanup, or
  agent-iteration commits as standalone commits unless they are genuinely
  independently reviewable.
- Prune equivalent rewrites before committing. If a hunk does not directly
  serve the feature, behavior change, required typing fix, or reviewable
  refactor, remove it instead of hiding it inside the feature commit.
- Review the diff by intent, not by file. For each hunk, ask whether a reviewer
  would care about that change as part of the stated PR goal.
- Check `git diff --word-diff origin/main..HEAD`, `git diff origin/main..HEAD`,
  and `git log --oneline origin/main..HEAD` before pushing.

Stage and commit normally after the history is shaped. Follow repo conventions
from `git log`.

```bash
git add -A
git commit -m "<concise message>"
```

Before pushing, verify this checklist:

- `git log --oneline origin/main..HEAD` shows only reviewer-meaningful commits.
- The branch has no cleanup/fixup/agent-iteration commits.
- `git diff --word-diff origin/main..HEAD` has no incidental equivalent rewrites.
- Tests or verification evidence matches the changed behavior.

## Step 3: Push (raw — no push-gate)

Explicit branch push only. No `pg prepare`, no `pg push`, no lease.

```bash
git push -u origin mho-yolo/<topic>
```

Force and delete are allowed on yolo branches:

```bash
git push --force-with-lease origin mho-yolo/<topic>   # ✅ sanctioned force form
git push --delete origin mho-yolo/<topic>             # ✅ remote delete allowed
git branch -D mho-yolo/<topic>                        # ✅ local cleanup allowed
```

Plain `git push --force` is still blocked for everyone — use
`--force-with-lease`. Bare `git push` is also blocked for everyone — use
`git push origin mho-yolo/<topic>`.

## Step 4: Open the PR

Yolo branches are PR-eligible (scratch branches are not). Base it on `main` (or
the repo's base); the head is your `mho-yolo/<topic>` branch.

```bash
gh pr create \
  --title "<title>" \
  --body "$(cat <<'EOF'
## What am I trying to do?

[1-3 sentences explaining the high-level goal.]

## Why did I do it this way?

[Explain the key design decisions and trade-offs.]

## Are there any tests?

[Describe what the tests prove.]

## How would I use the new code?

[Show a concrete command, API call, or code snippet when applicable.]
EOF
)" \
  --base main \
  --head mho-yolo/<topic>
```

Use the full `/update-pr-description` style by default. Yolo changes skip
push-gate mechanics, but they do not skip reviewer context. A short body is only
acceptable for truly mechanical changes where the title, commit, and diff are
self-evident.

> **Repo exception:** `fun-bash-automations` delivers on `mh-netflix`; do not
> open PRs from `mho-yolo/*` to `main` there if it conflicts with that repo's
> delivery policy. Everywhere else, a yolo PR to `main` is fine.
