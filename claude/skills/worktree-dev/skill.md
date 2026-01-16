---
name: worktree-dev
description: Create a worktree and develop changes in isolation, then return results
---

# Worktree Development Workflow

Develop changes in an isolated worktree, keeping the user's main checkout untouched.

## When to Use
- User wants changes developed without affecting their current working directory
- Running long experiments or refactors that shouldn't block main work
- User explicitly asks for worktree-based development

## Naming Convention
- Branch: `mho/<branch-name>`
- Path: `~/worktrees/mho-<branch-name>`

Example: branch `mho/auth-refactor` lives at `~/worktrees/mho-auth-refactor`

## Workflow Steps

### 1. Setup Worktree
```bash
BRANCH_NAME="mho/<feature-name>"
WORKTREE_PATH=~/worktrees/mho-<feature-name>

mkdir -p ~/worktrees
git worktree add -b "$BRANCH_NAME" "$WORKTREE_PATH" HEAD
```

### 2. Develop in Worktree
- Change working directory to the worktree path
- Make all changes there (edits, new files, tests)
- Commit changes to the branch
- Run tests/builds as needed

### 3. Report Back
When development is complete, provide:
- Summary of changes made
- Files modified/created
- Test results (if applicable)
- The worktree path and branch name for review

### 4. User Actions (inform them)
After reviewing, user can:
```bash
# cd into the worktree
gwtc                     # Interactive fzf selection
cd ~/worktrees/mho-<feature>

# Merge changes to their current branch
git merge mho/<branch-name>

# Or cherry-pick specific commits
git cherry-pick <commit-hash>

# Remove single worktree
gwtr ~/worktrees/mho-<feature>

# Or use interactive cleanup
gwtclean
```

## Shell Commands Reference
The user has these aliases/functions available:
- `gwt <name>` - Create worktree with `mho/` prefix
- `gwtl` - List all worktrees
- `gwtr [path]` - Remove worktree (fzf selection if no path)
- `gwtp` - Prune stale references
- `gwtc [path]` - cd into worktree (fzf selection if no path)
- `gwtclean` - Interactive cleanup of all worktrees

## Important Notes
- NEVER remove the worktree without user permission
- ALWAYS report the worktree path so user can inspect changes
- Commits made in worktree are visible from main repo (shared history)
- If tests fail, fix them in the worktree before reporting completion

## Example Invocation
User: "Use worktree-dev to refactor the authentication module"

Response:
1. Create worktree at `~/worktrees/mho-auth-refactor` on branch `mho/auth-refactor`
2. Perform the refactoring work there
3. Run tests, commit changes
4. Report: "Changes complete in `~/worktrees/mho-auth-refactor` on branch `mho/auth-refactor`. Created 3 commits, all tests passing. Ready for your review."
