---
name: address-comments-by
description: View and address GitHub PR review comments by a specific reviewer
---

# Address PR Comments by Reviewer

> **Related skills:**
> - `/update-pr-description <PR#>` - Update PR description after addressing comments
> - `/create-nflx-pr` - Create a new PR
> - `/commit-push-pr` - Commit, push, and create PR in one workflow

View and evaluate GitHub PR review comments from a specific reviewer, then accept or reject each suggestion.

## Usage

```
/address-comments-by <reviewer-username>
```

## Steps

### 1. Find the PR for the current branch

```bash
gh pr list --head $(git branch --show-current) --json number,title,state,url
```

### 2. Determine the GH_HOST

`gh api` can't infer the host from git remotes, so set `GH_HOST` for Netflix repos:

```bash
# Check if this is a Netflix GHE repo
REMOTE_URL=$(git remote get-url origin)
if [[ "$REMOTE_URL" == *"git.netflix.net"* ]]; then
  export GH_HOST=git.netflix.net
fi
```

### 3. Get reviewers who left comments

```bash
gh api repos/<ORG>/<REPO>/pulls/<PR_NUMBER>/comments | jq -r '[.[].user.login] | unique'
```

### 4. Get review comments from a specific reviewer

```bash
gh api repos/<ORG>/<REPO>/pulls/<PR_NUMBER>/comments | jq -r '.[] | select(.user.login == "<REVIEWER>") | "---\nFile: \(.path):\(.line // .original_line)\nComment: \(.body)\n"'
```

For bot reviewers like graphite-app, use case-insensitive matching:
```bash
gh api repos/<ORG>/<REPO>/pulls/<PR_NUMBER>/comments | jq -r '.[] | select(.user.login | test("<REVIEWER>"; "i")) | "---\nFile: \(.path):\(.line // .original_line)\nComment: \(.body)\n"'
```

### 5. For each comment, evaluate using these criteria

- **ACCEPT** if:
  - The suggestion fixes a real bug or edge case
  - The change improves defensive coding without adding complexity
  - The fix is minimal and has no negative side effects

- **REJECT** if:
  - The suggestion is based on a misunderstanding of the code
  - The concern is not a real scenario (e.g., API would never return that)
  - The fix adds unnecessary complexity

### 6. Apply accepted fixes

Use the Edit tool to apply each accepted fix.

### 7. Verify changes

Run the project's tests to verify changes don't break anything.

## Notes

- The `<ORG>/<REPO>` can be extracted from `git remote get-url origin`
- Common reviewers: `graphite-app[bot]`, `bitbot`, human reviewers by username
- The `jq` filter with `test()` allows case-insensitive partial matching for bot names
