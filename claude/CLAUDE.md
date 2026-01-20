## GitHub CLI Usage
- For Netflix GitHub Enterprise repos (github.netflix.net / git.netflix.net):
  - **First, fix the proxy** (required once per repo before any gh commands):
    ```bash
    ghe-fix-proxy /full/path/to/repo --verify
    ```
  - Then use regular `gh` commands:
    - `gh pr list` - auto-detects repo from git remote
    - `gh pr view 123` - works without -R flag when in repo
    - `gh api repos/corp/repo-name/pulls` - works after proxy fix
  - **Reset when done** (restores config for other tools):
    ```bash
    ghe-fix-proxy --reset
    ```
  - Note: `gh pr checkout` doesn't work due to Netflix Git Proxy; use git fetch workaround
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
The live config is in `~/.claude/` (Claude writes freely here).
The version-controlled source is in `~/repos/fun-bash-automations/claude/`.

**When you modify ~/.claude/CLAUDE.md or ~/.claude/settings.json:**
1. After making changes, sync back to the repo:
   ```bash
   cp ~/.claude/CLAUDE.md ~/repos/fun-bash-automations/claude/CLAUDE.md
   cp ~/.claude/settings.json ~/repos/fun-bash-automations/claude/settings.json
   ```
2. Inform me that config was updated so I can review/commit later

**User can manually sync with:** `claude-sync`

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
