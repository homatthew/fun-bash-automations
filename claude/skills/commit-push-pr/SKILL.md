---
name: commit-push-pr
description: Commit, push, and create a PR in one workflow
---

# Commit, Push, and Create PR

First, gather context by running these commands:

```bash
git status
git diff --cached --stat
git log --oneline -5
git branch --show-current
git remote -v
```

Then:

1. **Commit** - Create a concise commit message based on staged changes
2. **Push** - Push the current branch to origin
3. **Create PR** - Create a draft PR using the template below

## PR Description Template

Use this structure for all PR descriptions (GitHub supports Mermaid diagrams):

```markdown
## What am I trying to do?
[1-3 sentences explaining the goal/problem being solved]

## Why did I do it this way?
[High-level explanation of the approach chosen and key decisions]

## Are there any tests?
[Yes/No - describe what's tested and any gaps]

## How would I use the new code?
[Example usage, API changes, or migration notes if applicable]

## Architecture (optional)
[Include a Mermaid diagram if the change involves multiple components]

\`\`\`mermaid
graph LR
    A[Component A] --> B[Component B]
    B --> C[Component C]
\`\`\`
```

## Creating the PR

### For Netflix repos (git.netflix.net proxy)

**Use `gh api` with explicit hostname** (not `gh pr create` which doesn't reliably detect the host):

```bash
# Fix proxy first
ghe-fix-proxy $(pwd) --verify

# Get current branch name
BRANCH=$(git branch --show-current)

# Determine repo path - may differ from git remote (e.g., cde/repo → corp/cde-repo)
# Check by visiting the repo in browser if unsure

# Create the PR using the full template above
gh api --hostname github.netflix.net repos/{org}/{repo}/pulls \
  -f title="Your PR title" \
  -f body="[Use the full PR Description Template above - do not abbreviate]" \
  -f head="$BRANCH" \
  -f base="main" \
  -f draft=true

# Reset proxy when done
ghe-fix-proxy --reset
```

### For standard GitHub repos

```bash
gh pr create --draft
```

Always create PRs in draft mode unless explicitly told otherwise.

## Why `gh api` instead of `gh pr create`?

The `gh pr create` subcommand doesn't reliably detect the Netflix GHE hostname even after proxy setup. Using `gh api --hostname github.netflix.net` explicitly specifies the host and works reliably.
