# fun-bash-automations

Personal shell config and Claude Code configuration for Matthew Ho.

## Repository Structure

```
├── zsh/
│   ├── personal.zsh     # Custom functions, aliases, key bindings
│   └── netflix.zsh      # Netflix-specific config
├── claude/
│   ├── CLAUDE.md        # Global user instructions (source of truth for ~/.claude/CLAUDE.md)
│   ├── settings.json    # Claude Code settings (source of truth for ~/.claude/settings.json)
│   ├── statusline.sh    # Status line script (symlinked from ~/.claude/)
│   ├── skills/          # Claude skills (symlinked from ~/.claude/skills/)
│   ├── hooks/           # Claude hooks
│   └── agents/          # Claude agent configs
└── CLAUDE.md            # This file (project-specific instructions)
```

## Claude Config Architecture

**Symlinked files** (repo is source of truth, no sync needed):
- `~/.claude/statusline.sh` → `claude/statusline.sh`
- `~/.claude/skills/*` → `claude/skills/*`

**Copied files** (sync with `claude-sync` after changes):
- `~/.claude/CLAUDE.md` ← copy → `claude/CLAUDE.md`
- `~/.claude/settings.json` ← copy → `claude/settings.json`

## When Making Changes

### To statusline.sh or skills
Edit directly in this repo - changes are immediate via symlink.

### To CLAUDE.md or settings.json
1. Edit in `~/.claude/` (Claude writes here)
2. Run `claude-sync` to copy back to this repo
3. Commit changes

### Adding a new skill
1. Create `claude/skills/<skill-name>/skill.md`
2. Symlink: `ln -s ~/repos/fun-bash-automations/claude/skills/<skill-name> ~/.claude/skills/`

## Shell Functions

The `zsh/personal.zsh` file defines these functions that Claude should know about:
- `claude-sync` - Sync ~/.claude/ files back to this repo
- `gwt`, `gwtl`, `gwtr`, `gwtc`, `gwtclean` - Git worktree helpers
- `ghe-fix-proxy` - Fix gh CLI for Netflix GitHub Enterprise
