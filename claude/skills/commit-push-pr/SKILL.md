---
name: commit-push-pr
description: Commit, push, and create a PR in one workflow
---

# Commit, Push, and Create PR

> **Related skills:**
> - `/create-nflx-pr` - Create PR only (if already committed and pushed)
> - `/update-pr-description <PR#>` - Update an existing PR's description
> - `/address-comments-by <reviewer>` - Address review comments after PR is created

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

First, detect repo type and fork topology:

```bash
git remote -v
# git.netflix.net → Netflix GHE workflow
# github.com → Public GitHub workflow
# If "upstream" remote exists → cross-fork PR (target upstream, head from fork)
```

### For Netflix GHE repos (git.netflix.net)

Netflix's `gh` fork works directly — no proxy setup needed.

```bash
BRANCH=$(git branch --show-current)

gh pr create \
  --title "Your PR title" \
  --body "[Use the full PR Description Template above - do not abbreviate]" \
  --base main \
  --head "$BRANCH" \
  --draft
```

### For public GitHub repos (github.com)

#### Same-repo (no fork)

```bash
gh pr create \
  --repo <org>/<repo> \
  --title "Your PR title" \
  --body "[Use the full PR Description Template above]" \
  --base main \
  --head <branch-name> \
  --draft
```

#### Cross-fork (origin = fork, upstream = canonical)

Create the PR on the **upstream** repo with your fork's branch as head:

```bash
gh pr create \
  --repo <upstream-org>/<repo> \
  --title "Your PR title" \
  --body "[Use the full PR Description Template above]" \
  --base main \
  --head <fork-owner>:<branch-name> \
  --draft
```

Always create PRs in draft mode unless explicitly told otherwise.
