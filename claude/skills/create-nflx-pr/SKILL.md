---
name: create-nflx-pr
description: Create a PR on Netflix Enterprise GitHub
---

# Create a PR

> **Related skills:**
> - `/update-pr-description <PR#>` - Update an existing PR's description
> - `/commit-push-pr` - Commit, push, and create PR in one workflow
> - `/address-comments-by <reviewer>` - Address review comments after PR is created

## Step 1: Detect the repo type

Check the git remote to determine whether this is a Netflix GHE repo or a public GitHub repo:

```bash
git remote -v
```

- **Netflix GHE**: remote URLs contain `github.netflix.net` → use the GHE workflow below
- **Public GitHub (github.com)**: → use the public GitHub workflow below

## Step 2: Determine fork topology

```bash
# Check all remotes
git remote -v

# If there's an "upstream" remote, this is a fork-based workflow
# origin = your fork, upstream = canonical repo
# PRs should target upstream with cross-fork head: --head <your-username>:<branch>
```

---

## Public GitHub repos (github.com)

Use standard `gh pr create`. Works reliably for github.com repos.

### Same-repo (no fork)

```bash
gh pr create \
  --repo <org>/<repo> \
  --title "<title>" \
  --body "<body>" \
  --base main \
  --head <branch-name> \
  --draft
```

### Cross-fork (origin = fork, upstream = canonical)

PRs should be created on the **upstream** repo with the fork's branch as head:

```bash
gh pr create \
  --repo <upstream-org>/<repo> \
  --title "<title>" \
  --body "<body>" \
  --base main \
  --head <fork-owner>:<branch-name> \
  --draft
```

Example: fork is `homatthew/service-capacity-modeling`, upstream is `Netflix-Skunkworks/service-capacity-modeling`:
```bash
gh pr create \
  --repo Netflix-Skunkworks/service-capacity-modeling \
  --title "My change" \
  --body "Description" \
  --base main \
  --head homatthew:mho/my-branch \
  --draft
```

---

## Netflix GHE repos (github.netflix.net)

### Setup (required once per repo)

```bash
ghe-fix-proxy $(pwd) --verify
```

### Determine the repo path

The GitHub API repo path may differ from the git remote. Common patterns:
- `cde/reponame` in git remote → `corp/cde-reponame` in API
- Check the actual path by visiting the repo in browser

```bash
# Get the org/repo from git remote
git remote get-url origin | sed 's|.*github.netflix.net/||' | sed 's|\.git$||'
```

### Create the PR

**Use `gh api` with explicit hostname** (not `gh pr create` which doesn't reliably detect the host):

```bash
gh api --hostname github.netflix.net repos/{org}/{repo}/pulls \
  -f title="<title>" \
  -f body="<body>" \
  -f head="<branch-name>" \
  -f base="main" \
  -f draft=true
```

### Cleanup (restore config for other tools)

```bash
ghe-fix-proxy --reset
```

### Prerequisites

- Must be authenticated: `gh auth status` should show `github.netflix.net`
- Branch must be pushed first
- Proxy must be fixed with `ghe-fix-proxy` before running `gh` commands

### Why not `gh pr create` for GHE?

The `gh pr create` subcommand doesn't reliably detect the Netflix GHE hostname even after proxy setup. Using `gh api --hostname github.netflix.net` explicitly specifies the host and works reliably.

---

## General rules

- Always create PRs in **draft mode** unless explicitly told otherwise
- Use the full PR description template from `commit-push-pr` or `update-pr-description` skills — do not abbreviate
- Pass the body via a HEREDOC for multi-line descriptions to preserve formatting
