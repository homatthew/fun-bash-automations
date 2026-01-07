---
description: View and address GitHub PR review comments by a specific reviewer
---

# Address PR Comments by Reviewer

View and evaluate GitHub PR review comments from a specific reviewer, then accept or reject each suggestion.

## Usage

```
/address-comments-by <reviewer-username>
```

## Steps

### 1. Find the PR for the current branch

```bash
GH_HOST=github.netflix.net gh pr list --repo corp/cde-cdeportal --head $(git branch --show-current) --json number,title,state,url
```

### 2. Get review comments from the PR

```bash
GH_HOST=github.netflix.net gh api repos/corp/cde-cdeportal/pulls/<PR_NUMBER>/comments | jq -r '.[] | select(.user.login == "<REVIEWER>") | "---\nFile: \(.path):\(.line // .original_line)\nComment: \(.body)\n"'
```

For bot reviewers like graphite-app, use:
```bash
GH_HOST=github.netflix.net gh api repos/corp/cde-cdeportal/pulls/<PR_NUMBER>/comments | jq -r '.[] | select(.user.login | test("<REVIEWER>"; "i")) | "---\nFile: \(.path):\(.line // .original_line)\nComment: \(.body)\n"'
```

### 3. For each comment, evaluate using these criteria:

- **ACCEPT** if:
  - The suggestion fixes a real bug or edge case
  - The change improves defensive coding without adding complexity
  - The fix is minimal and has no negative side effects

- **REJECT** if:
  - The suggestion is based on a misunderstanding of the code
  - The concern is not a real scenario (e.g., API would never return that)
  - The fix adds unnecessary complexity

### 4. Apply accepted fixes

Use the Edit tool to apply each accepted fix.

### 5. Verify changes

```bash
newt exec npm run type-check -w client
newt exec npm run test -w client
```

## Notes

- For Netflix repos using `git.netflix.net` proxy, always prefix with `GH_HOST=github.netflix.net`
- Common reviewers: `graphite-app[bot]`, `bitbot`, human reviewers by username
- The `jq` filter with `test()` allows case-insensitive partial matching for bot names
