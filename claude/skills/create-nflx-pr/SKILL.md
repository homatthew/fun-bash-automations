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

- **Netflix GHE**: remote URLs contain `git.netflix.net` → use the Netflix GHE workflow below
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

## Netflix GHE repos (git.netflix.net)

Netflix's `gh` fork works directly with `git.netflix.net` repos — no proxy setup needed.

### Create the PR

```bash
BRANCH=$(git branch --show-current)

gh pr create \
  --title "<title>" \
  --body "<body>" \
  --base main \
  --head "$BRANCH" \
  --draft
```

### Prerequisites

- Netflix `gh` fork installed (`/usr/local/bin/gh`)
- Authenticated: `gh auth status` should show `git.netflix.net`
- Remotes use canonical URLs (`nfgit canonical origin`)
- Branch must be pushed first

---

## General rules

- Always create PRs in **draft mode** unless explicitly told otherwise
- Use the full PR description template from `commit-push-pr` or `update-pr-description` skills — do not abbreviate
- Pass the body via a HEREDOC for multi-line descriptions to preserve formatting
