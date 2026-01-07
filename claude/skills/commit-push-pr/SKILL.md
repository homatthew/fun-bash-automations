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

For Netflix repos using `git.netflix.net` proxy:
```bash
GH_HOST=github.netflix.net gh pr create --repo "corp/<repo-name>" --draft
```

For standard GitHub repos:
```bash
gh pr create --draft
```

Always create PRs in draft mode unless explicitly told otherwise.
