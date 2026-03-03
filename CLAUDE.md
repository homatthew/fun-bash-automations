# fun-bash-automations

Personal shell config and Claude Code configuration for Matthew Ho.

## Repository Structure

```
├── bin/
│   └── simple-ralph     # Autonomous Claude execution loop (bash, zero deps)
├── ralph/
│   ├── src/ralph/watch.py  # ralph-watch Rich monitor (installed via uv tool)
│   ├── pyproject.toml      # Only exposes ralph-watch entry point
│   └── DEPRECATED.md       # Full Ralph package is deprecated
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
├── ghostty/
│   └── config           # Ghostty terminal config (symlinked to ~/.config/ghostty/config)
└── CLAUDE.md            # This file (project-specific instructions)
```

## Claude Config Architecture

**Symlinked files** (repo is source of truth, no sync needed):
- `~/.claude/statusline.sh` → `claude/statusline.sh`
- `~/.claude/skills/*` → `claude/skills/*`

**Copied files** (use `claude-deploy` or `claude-sync`):
- `~/.claude/CLAUDE.md` ↔ `claude/CLAUDE.md`
- `~/.claude/settings.json` ↔ `claude/settings.json`

## When Making Changes

### To statusline.sh or skills
Edit directly in this repo - changes are immediate via symlink.

### To CLAUDE.md or settings.json
Two workflows:

1. **Edit repo, then deploy** (preferred for planned changes):
   - Edit files in this repo under `claude/`
   - Run `claude-deploy` to make changes live

2. **Edit live, then sync** (for quick iterations):
   - Edit files in `~/.claude/`
   - Run `claude-sync` to save to repo
   - Commit changes

### Adding a new skill
1. Create `claude/skills/<skill-name>/skill.md`
2. Symlink: `ln -s ~/repos/fun-bash-automations/claude/skills/<skill-name> ~/.claude/skills/`

## Ralph (Autonomous Execution)

**simple-ralph** (`bin/simple-ralph`) is the execution engine. Zero deps beyond bash + claude CLI.

**ralph-watch** (`ralph/src/ralph/watch.py`) is the Rich monitor. Installed via:
```bash
uv tool install -e ~/repos/fun-bash-automations/ralph
```
This is the source of truth. Do NOT create standalone copies in `bin/`.

**Session isolation**: Each run creates `.ralph/sessions/<session-name>/` with a 3-word name
(e.g., `bold-crow-leap`). Symlinks at `.ralph/{output.log,meta.json}` point to the current session.

## Shell Functions

The `zsh/personal.zsh` file defines these functions that Claude should know about:
- `claude-deploy` - Deploy repo config to ~/.claude (make changes live)
- `claude-sync` - Sync ~/.claude config back to this repo
- `gwt`, `gwtl`, `gwtr`, `gwtc`, `gwtclean` - Git worktree helpers
- `rt` - Tail Ralph output (`tail -f .ralph/output.log`)
- `ralph-status` - Quick status check from `.ralph/meta.json`
