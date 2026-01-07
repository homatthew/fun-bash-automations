---
name: create-nflx-pr
description: Create a PR on Netflix Enterprise GitHub
---

# Create PR on Netflix Enterprise GitHub

When creating PRs for Netflix repos that use `git.netflix.net` proxy:

```bash
GH_HOST=github.netflix.net gh pr create --repo "corp/<repo-name>" --title "<title>" --body "<body>" --base main --head <branch-name> --draft
```

**Important:** Always create PRs in draft mode (`--draft` flag).

**Why:** The proxy config in `~/.gitconfig-proxy` rewrites `github.netflix.net` -> `git.netflix.net`, which `gh` CLI doesn't recognize as a GitHub host. Using `GH_HOST` env var forces `gh` to use the correct host.

**Prerequisites:**
- Must be authenticated: `gh auth status` should show `github.netflix.net`
- Branch must be pushed first
