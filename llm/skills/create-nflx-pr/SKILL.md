---
name: create-nflx-pr
description: "DEPRECATED — use /commit-push-pr instead. Kept as a redirect."
---

# Create a PR

> **This skill is deprecated.** Use `/commit-push-pr` instead — it handles commit, durable push-gate leasing, `pg push`, and PR creation in one flow.
>
> If you are here, invoke `/commit-push-pr` and stop reading this file.

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
- Branch must be pushed first — use `/commit-push-pr` (raw `git push` is blocked by the push guard hook)

---

## General rules

- Always create PRs in **draft mode** unless explicitly told otherwise
- Use the full PR description template from `commit-push-pr` or `update-pr-description` skills — do not abbreviate
- Pass the body via a HEREDOC for multi-line descriptions to preserve formatting
