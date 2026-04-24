---
name: commit-push-pr
description: "Commit, push, and create/update a PR. This is the ONLY sanctioned way to push code. Use when the user explicitly asks to push, create a PR, or update a PR with new commits."
---

# Commit, Push, and Create/Update PR

> **When to use:** ONLY when the user explicitly asks to push, create a PR, or update an existing PR with new commits. Do NOT invoke this skill proactively at the end of a task.

> **Related skills:**
> - `/update-pr-description <PR#>` - Update an existing PR's description text (no push needed)
> - `/address-comments-by <reviewer>` - Address review comments after PR is created

## Step 1: Gather Context

```bash
git status
git diff --cached --stat
git log --oneline -5
git branch --show-current
git remote -v
```

## Step 2: Check for Existing PR

```bash
BRANCH=$(git branch --show-current)
gh pr list --head "$BRANCH" --json number,title,url
```

- If a PR already exists → this is an **update** (commit + push only, skip PR creation)
- If no PR exists → this is a **new PR** (commit + push + create)

## Step 3: Commit

Create a concise commit message based on staged changes. Follow repo conventions from `git log`.

## Step 4: Push

Push-gate blocks all `git push` until a lease exists. The canonical flow
is three commands, one per actor:

> **Do NOT bypass push-gate.** Never suggest `PG_SKIP_EDIT=1`,
> `PG_ALLOW_DESCENDANT=1`, `PG_SCOPE_OVERRIDE=1`, `PG_ALLOW_INFERENCE=1`
> (that last one is for humans without an agent, not for you), or piping
> `yes` into the approval prompt. See
> [`llm/command-guard-policy.md` → Push-gate bypass prohibition](../../command-guard-policy.md).

### 4a. Prepare (agent)

Hand off your rationale. See the `push-gate-prepare` skill for details.

```bash
pg prepare \
  --what     'one-line: what this branch changes' \
  --why      'one-line: motivating bug/ask' \
  --approach 'one-line: strategy and trade-offs' \
  --risks    'one-line: caveats, or "none apparent"'
```

### 4b. Approve (user)

Tell the user:

> Run in your terminal: `pg -C <absolute-repo-path>`

Their editor opens on the YAML draft with your prepared brief. They
review, edit if needed, and confirm. On approval, the lease is written
and a macOS notification fires.

### 4c. Self-validate and push (agent)

After the user confirms, verify the lease still covers the current HEAD:

```bash
pg check | jq '{allowed, reason, current}'
```

If `.allowed` is `false` or `.current.anchor_matches_head` is `false`,
commits have landed since approval or scope has drifted. Re-run
`pg prepare` with the updated rationale and ask the user to re-run `pg`.

Then push:

```bash
pg push \
  --assert-flow $'update pr #<pr>\nbranch '"$BRANCH"$'\n<main areas>\nno rewrite' \
  --set-upstream
```

If the push is blocked, use `pg doctor` or generate a replacement lease. For rebases or amended commits, create a new lease before using `pg push --force-with-lease`.

## Step 5: Create PR (new PRs only)

Skip this step if a PR already exists (Step 2 found one).

First, detect repo type and fork topology:

```bash
git remote -v
# git.netflix.net → Netflix GHE workflow
# github.com → Public GitHub workflow
# If "upstream" remote exists → cross-fork PR
```

### For Netflix GHE repos (git.netflix.net)

```bash
gh pr create \
  --title "<title>" \
  --body "$(cat <<'EOF'
## What am I trying to do?
[1-3 sentences explaining the goal/problem being solved]

## Why did I do it this way?
[High-level explanation of the approach chosen and key decisions]

## Are there any tests?
[Yes/No - describe what's tested and any gaps]

## How would I use the new code?
[Example usage, API changes, or migration notes if applicable]

## Architecture (optional)
[Include a Mermaid diagram ONLY if data flows through 3+ components,
there's a non-obvious ordering, or the text explanation exceeds 5 sentences]
EOF
)" \
  --base main \
  --head "$BRANCH" \
  --draft
```

### For public GitHub repos (github.com)

#### Same-repo (no fork)

```bash
gh pr create \
  --repo <org>/<repo> \
  --title "<title>" \
  --body "<use template above>" \
  --base main \
  --head "$BRANCH" \
  --draft
```

#### Cross-fork (origin = fork, upstream = canonical)

Create the PR on the **upstream** repo with your fork's branch as head:

```bash
gh pr create \
  --repo <upstream-org>/<repo> \
  --title "<title>" \
  --body "<use template above>" \
  --base main \
  --head <fork-owner>:"$BRANCH" \
  --draft
```

Example: fork is `homatthew/service-capacity-modeling`, upstream is `Netflix-Skunkworks/service-capacity-modeling`:
```bash
gh pr create \
  --repo Netflix-Skunkworks/service-capacity-modeling \
  --title "My change" \
  --body "..." \
  --base main \
  --head homatthew:"$BRANCH" \
  --draft
```

## General Rules

- Always create PRs in **draft mode** unless explicitly told otherwise
- Use the full PR description template — do not abbreviate
- Pass the body via HEREDOC for multi-line descriptions
- Return the PR URL when done
