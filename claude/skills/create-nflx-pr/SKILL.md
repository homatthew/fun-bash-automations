---
name: create-nflx-pr
description: Create a PR on Netflix Enterprise GitHub
---

# Create PR on Netflix Enterprise GitHub

## Setup (required once per repo)

```bash
ghe-fix-proxy $(pwd) --verify
```

## Create the PR

```bash
gh pr create --title "<title>" --body "<body>" --base main --head <branch-name> --draft
```

**Important:** Always create PRs in draft mode (`--draft` flag).

## Cleanup (restore config for other tools)

```bash
ghe-fix-proxy --reset
```

## Prerequisites

- Must be authenticated: `gh auth status` should show `github.netflix.net`
- Branch must be pushed first
- Proxy must be fixed with `ghe-fix-proxy` before running `gh` commands
