## Git Branch Rules

**For this repo (fun-bash-automations):** Always push to `mh-netflix` branch. No feature sub-branches needed.
- All changes go to `mh-netflix`
- Never push directly to `main`

**For other repos:** Follow standard feature branch rules - create `mho/<feature-name>` branches, never push directly to `main` or `master`.

**Exception:** `service-capacity-model` repo allows direct pushes to `origin main` (but NOT `upstream main`).

## Skills Quick Reference

**IMPORTANT**: Always use skills for PR operations on Netflix repos. Never use raw `gh pr create` or `gh pr edit` - they don't reliably detect Netflix GHE.

| Task | Skill | Notes |
|------|-------|-------|
| Create new PR | `/create-nflx-pr` | Uses `gh api --hostname`, creates in draft mode |
| Update PR description | `/update-pr-description <PR#>` | Full template with "What/Why/Tests/How" |
| Commit + push + PR | `/commit-push-pr` | All-in-one workflow |
| Address review comments | `/address-comments-by <reviewer>` | Fetch and respond to specific reviewer |
| Split large PR | `/split-pr` | Analyze and propose atomic commits |
| Isolated development | `/worktree-dev` | Create worktree, develop, return results |
| Verify build passes | `/verify-build` | Run tests and fix issues |
| Simplify code | `/simplify` | Simplify code after implementation |
| Desktop notification | `/notify` | Alert when task completes |
| Design architecture | `/architect` | Design and maintain feature architecture |
| Persist insights | `/second-brain` | Save architectural learnings |

## GitHub CLI Usage

**For Netflix repos**: Use skills above, not raw `gh` commands for PR creation/editing.

- **Proxy setup** (required once per repo before any gh commands):
  ```bash
  ghe-fix-proxy /full/path/to/repo --verify
  ```
- **Read-only commands work after proxy fix**:
  - `gh pr list` - auto-detects repo from git remote
  - `gh pr view 123` - works without -R flag when in repo
  - `gh api repos/corp/repo-name/pulls` - works after proxy fix
- **Reset when done** (restores config for other tools):
  ```bash
  ghe-fix-proxy --reset
  ```
- Note: `gh pr checkout` doesn't work due to Netflix Git Proxy; use git fetch workaround
- **Creating gists** (special case):
  ```bash
  # 1. Fix proxy first
  ghe-fix-proxy /path/to/any/repo --verify

  # 2. Use GH_HOST to target Netflix GHE
  GH_HOST=github.netflix.net gh gist create file1.md file2.py --desc "Description"

  # 3. Reset when done
  ghe-fix-proxy --reset
  ```
  Note: `gh gist` requires `GH_HOST` env var since it doesn't auto-detect from repo remotes.
- For public GitHub (github.com):
  - Use regular `gh` commands (no special handling needed)

## Multi-Repo Workflow
- All repositories live in `~/repos/*`
- Use the `cross-repo-context` agent when you need patterns from other repos
- When referencing code from another repo, use full paths: `~/repos/<repo-name>/path/to/file`
- Common cross-repo scenarios:
  - Finding similar implementations
  - Checking how other services handle auth, errors, configs
  - Copying patterns for consistency across projects

## Plan Mode Preference
- I prefer to use plan mode for non-trivial changes
- Always persist plans to `.claude/plans/<feature-name>.md`
- Consult the plan file when resuming work

## Git Worktree Workflow
Worktrees allow parallel work on the same repo without conflicts. Use this for:
- Running Claude agents on isolated branches while you work on main
- Testing changes in isolation before merging
- Long-running experiments that shouldn't clutter your main checkout

### Naming Convention
- Branch: `mho/<branch-name>`
- Path: `~/worktrees/mho-<branch-name>`

Example: `gwt auth-refactor` creates branch `mho/auth-refactor` at `~/worktrees/mho-auth-refactor`

### Shell Commands
```bash
gwt <name>       # Create worktree (adds mho/ prefix)
gwtl             # List all worktrees
gwtr [path]      # Remove worktree (fzf if no path)
gwtp             # Prune stale references
gwtc [path]      # cd into worktree (fzf if no path)
gwtclean         # Interactive cleanup of all worktrees
```

### Claude Agent Workflow
When spawning a Claude agent to work on a separate branch:
1. Create a worktree: `gwt feature-name` → `~/worktrees/mho-feature-name`
2. Have Claude work in that directory (isolated from your main checkout)
3. Changes in the worktree won't affect files in `~/repos/` (only shared: commits, branches, stash)
4. When done, review changes, merge, then `gwtr ~/worktrees/mho-feature-name`

### Working in Worktrees (Important for Status Line)
When you need to work in a worktree, **cd into it as a standalone command first**:
```bash
# GOOD - status line will show correct branch
cd ~/worktrees/mho-feature-name
git add .
git commit -m "message"

# BAD - status line won't update (cd is ephemeral in && chain)
cd ~/worktrees/mho-feature-name && git add . && git commit -m "message"
```
This ensures the status line displays the correct branch. The cd persists for subsequent commands.

### Key Facts
- Worktrees share: commits, branches, remotes, stash, reflog
- Worktrees isolate: working directory, staging area, HEAD
- Cannot checkout same branch in two worktrees simultaneously
- `gwtr` removes the directory but keeps the branch (delete branch separately with `git branch -d`)

## Notifications
After completing a significant task, use `/notify` to send a desktop notification so I know to return.

**When to notify:**
- After finishing an implementation task (feature, bugfix, refactor)
- After completing a research task with findings ready
- After a build/test run completes (pass or fail)
- When blocked and waiting for input

**When NOT to notify:**
- Mid-task updates (I'll see the todo list)
- Simple questions or clarifications
- After trivial single-line changes

## Claude Config Management
The live config is in `~/.claude/`.
The version-controlled source is in `~/repos/fun-bash-automations/claude/`.

**Two workflows:**

1. **Edit repo, then deploy** (preferred for planned changes):
   - Edit files in `~/repos/fun-bash-automations/claude/`
   - Run `claude-deploy` to copy to `~/.claude/` (makes changes live)

2. **Edit live, then sync** (for quick iterations):
   - Edit files in `~/.claude/`
   - Run `claude-sync` to copy back to repo for version control

**Commands:**
```bash
claude-deploy  # repo → ~/.claude (make changes live)
claude-sync    # ~/.claude → repo (save for version control)
```

## Shell Configuration
My shell config lives in `~/repos/fun-bash-automations/` and is symlinked to `~/.zshrc`.

**Key files:**
- `zsh/personal.zsh` - Custom functions, aliases, key bindings
- `zsh/netflix.zsh` - Netflix-specific config

**When issues arise:**
- If a shell function has a bug, **fix it directly** in `~/repos/fun-bash-automations/zsh/personal.zsh`
- After fixing, remind me to run `source ~/.zshrc` to reload
- These are my personal scripts - feel free to improve them when problems surface

**When to use shell aliases vs raw commands:**
- Use `gwt`, `gwtl`, `gwtr`, etc. when working interactively or giving me instructions
- Use raw `git worktree` commands in scripts/skills for portability
- If a shell alias is broken, fall back to the raw command and fix the alias

## Skills Location
Skills are symlinked from `~/repos/fun-bash-automations/claude/skills/` to `~/.claude/skills/`.
To add a new skill:
1. Create skill directory in `~/repos/fun-bash-automations/claude/skills/<skill-name>/`
2. Add `skill.md` with frontmatter (name, description) and instructions
3. Symlink: `ln -s ~/repos/fun-bash-automations/claude/skills/<skill-name> ~/.claude/skills/`
