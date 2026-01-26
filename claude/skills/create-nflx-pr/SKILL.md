---
name: create-nflx-pr
description: Create a PR on Netflix Enterprise GitHub
---

# Create PR on Netflix Enterprise GitHub

## Setup (required once per repo)

```bash
ghe-fix-proxy $(pwd) --verify
```

## Determine the repo path

The GitHub API repo path may differ from the git remote. Common patterns:
- `cde/reponame` in git remote → `corp/cde-reponame` in API
- Check the actual path by visiting the repo in browser

```bash
# Get the org/repo from git remote
git remote get-url origin | sed 's|.*github.netflix.net/||' | sed 's|\.git$||'
```

## Create the PR

**Use `gh api` with explicit hostname** (not `gh pr create` which doesn't reliably detect the host):

```bash
gh api --hostname github.netflix.net repos/{org}/{repo}/pulls \
  -f title="<title>" \
  -f body="<body>" \
  -f head="<branch-name>" \
  -f base="main" \
  -f draft=true
```

**Important:**
- Always create PRs in draft mode (`draft=true`)
- Use the full PR description template from `commit-push-pr` or `update-pr-description` skills - do not abbreviate

## Cleanup (restore config for other tools)

```bash
ghe-fix-proxy --reset
```

## Prerequisites

- Must be authenticated: `gh auth status` should show `github.netflix.net`
- Branch must be pushed first
- Proxy must be fixed with `ghe-fix-proxy` before running `gh` commands

## Why not `gh pr create`?

The `gh pr create` subcommand doesn't reliably detect the Netflix GHE hostname even after proxy setup. Using `gh api --hostname github.netflix.net` explicitly specifies the host and works reliably.
