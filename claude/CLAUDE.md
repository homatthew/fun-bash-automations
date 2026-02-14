## Git Branch Rules

**For this repo (fun-bash-automations):** Always push to `mh-netflix` branch. No feature sub-branches needed.
- All changes go to `mh-netflix`
- Never push directly to `main`

**For other repos:** Follow standard feature branch rules - create `mho/<feature-name>` branches, never push directly to `main` or `master`.

**Exception:** `service-capacity-model` repo allows direct pushes to `origin main` (but NOT `upstream main`).

## Skills Quick Reference

**IMPORTANT**: Use skills for PR operations on Netflix repos for consistent templates and formatting.

| Task | Skill | Notes |
|------|-------|-------|
| Create new PR | `/create-nflx-pr` | Uses `gh pr create`, creates in draft mode |
| Update PR description | `/update-pr-description <PR#>` | Full template with "What/Why/Tests/How" |
| Commit + push + PR | `/commit-push-pr` | All-in-one workflow |
| Address review comments | `/address-comments-by <reviewer>` | Fetch and respond to specific reviewer |
| Split large PR | `/split-pr` | Analyze and propose atomic commits |
| Isolated development | `/worktree-dev` | Create worktree, develop, return results |
| Verify build passes | `/verify-build` | Run tests and fix issues |
| Simplify code | `/simplify` | Simplify code after implementation |
| Design architecture | `/architect` | Design and maintain feature architecture |
| Persist insights | `/second-brain` | Save architectural learnings |

## GitHub CLI Usage

Netflix's `gh` CLI fork (`/usr/local/bin/gh`) uses metatron auth natively. No proxy setup/reset needed.

- **All standard commands work directly in Netflix repos**:
  - `gh pr list`, `gh pr create`, `gh pr edit`, `gh pr view`
  - `gh api repos/corp/repo-name/pulls`
- **Prerequisites**: Netflix fork installed, `git.netflix.net` auth, canonical remotes (`nfgit canonical origin`)
- Note: `gh pr checkout` doesn't work due to Netflix Git Proxy; use git fetch workaround
- **Creating gists** (special case):
  ```bash
  GH_HOST=git.netflix.net gh gist create file1.md file2.py --desc "Description"
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

## Skills Marketplace Strategy

Netflix's `cde-ods-skills` repo is a plugin marketplace (`claude plugin install ods-datastores`). This section guides donate-vs-keep decisions and marketplace integration.

### Decision Framework

When deciding whether to donate a skill to a marketplace plugin:

| Factor | Keep if... | Donate if... |
|--------|-----------|--------------|
| **Personal runtime coupling** | Needs `gwt` aliases, `~/repos/dump/`, Ghostty | Uses only standard tools |
| **Identity coupling** | Contains `mho/` prefixes, personal paths, personal templates | Fully generic |
| **Marketplace fit** | Doesn't fit the target plugin's domain (e.g., workflow skills don't belong in an ODS datastores plugin) | Naturally fits the plugin's category |
| **Community maintenance** | Only you would maintain it | Many engineers would improve it |
| **Competitive differentiation** | Embodies a unique philosophy or methodology | Mechanical procedure anyone could write |

**Rule of thumb:** Keep the philosophy, donate the mechanics.

### Current Skill Allocation

| Skill | Status | Reason |
|-------|--------|--------|
| **ai-slop-removal** | Keep (donate to general plugin if one exists) | General workflow — doesn't fit ODS domain |
| **simplify** | Keep (donate to general plugin if one exists) | General workflow — doesn't fit ODS domain |
| **architect** | Keep (donate to general plugin if one exists) | General workflow — doesn't fit ODS domain |
| **verify-build** | Keep | `newt` coupling + too generic for ODS |
| **split-pr** | Keep | `mho/` naming, worktree aliases |
| **address-comments-by** | Keep | Personal workflow + template |
| **commit-push-pr** | Keep | Personal workflow + template |
| **update-pr-description** | Keep | Personal template |
| **create-nflx-pr** | Keep | Netflix-specific + personal template |
| **notify** | Replaced by hook | Auto-fires via `claude/hooks/notify.sh` on Stop/Notification events |
| **one-pager** | Keep | Personal methodology + second-brain |
| **second-brain** | Keep | Personal knowledge store |
| **worktree-dev** | Keep | Shell alias dependent |

**Summary:** No current skills fit the `ods-datastores` plugin. Four general-purpose skills (ai-slop-removal, simplify, architect, verify-build) are candidates for a *general developer workflow* plugin if one emerges.

### Marketplace Integration Rules

**Consuming marketplace skills:**
- Install plugins via `claude plugin install ods-datastores`
- Use marketplace skills as black boxes — don't duplicate locally
- If a marketplace skill overlaps with a personal one, try the marketplace version first
- Personal skills in `~/.claude/skills/` take precedence over plugin skills with the same name
- If a marketplace skill becomes better than your personal version, delete yours

**Contributing to marketplace:**
- Only contribute if the skill fits the plugin's domain — don't shoehorn workflow skills into an ODS datastores plugin
- If a general-purpose skills plugin emerges, the four general skills are ready to donate
- When donating: strip personal runtime deps, remove hardcoded paths, use standard tools only
- After donating: delete the local copy and use the plugin version (fewer things to maintain)
