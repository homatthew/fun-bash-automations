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

**Before pushing, ask the user to run `push-gate` to open a time-based approval window.** The push guard hook blocks all pushes until the user approves. Include the `cd` so the token is scoped to the right repo (important when working in a worktree).

Tell the user (substitute the actual working directory and branch):
> Ready to push `$BRANCH`. Run in your terminal:
> ```
> cd <working-directory>
> push-gate
> ```

Once the user confirms they've run it:

```bash
git push -u origin "$BRANCH"
```

If the push is blocked with an expired token message, ask the user to run `push-gate` again.

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
