# Quality of Life Features

Personal productivity enhancements for shell and vim.

## Setup

```bash
./setupPermissions.sh
source ~/.zshrc
```

---

## Zsh Features

### Oh My Zsh Plugins
| Plugin | Description |
|--------|-------------|
| `z` | Jump to frequently used directories (`z proj` → `~/projects`) |
| `fzf` | Fuzzy finder integration |
| `history` | History aliases (`h`, `hs`, `hsi`) |
| `colored-man-pages` | Colorized man pages |
| `command-not-found` | Suggests packages for unknown commands |

### FZF Keybindings
| Keybinding | Action |
|------------|--------|
| `Ctrl+R` | Fuzzy history search |
| `Ctrl+T` | Fuzzy file finder |
| `Alt+C` | Fuzzy cd to directory |

### FZF-Git Keybindings
Press `Ctrl+G` then the second key:

| Keybinding | Action |
|------------|--------|
| `Ctrl+G Ctrl+B` | Fuzzy branch picker (with commit preview) |
| `Ctrl+G Ctrl+T` | Fuzzy tag picker |
| `Ctrl+G Ctrl+H` | Fuzzy commit hash picker |
| `Ctrl+G Ctrl+R` | Fuzzy remote picker |
| `Ctrl+G Ctrl+S` | Fuzzy stash picker |
| `Ctrl+G Ctrl+F` | Fuzzy file picker (git status) |

### History Navigation
| Keybinding | Action |
|------------|--------|
| `Up/Down` | Prefix-based history search (type partial command first) |
| `Ctrl+P/N` | Same as Up/Down |
| `Option+←/→` | Jump by word |
| `Option+Backspace` | Delete word backward |
| `Ctrl+Space` | Accept autosuggestion |

### Shell Enhancements
- **Autosuggestions**: Fish-like suggestions as you type (gray text)
- **Syntax highlighting**: Commands colorized as you type
- **50k history**: Shared across sessions, no duplicates

### Git Aliases
| Alias | Command |
|-------|---------|
| `gca` | `git commit --amend` |
| `gcane` | `git commit --amend --no-edit --no-verify` |
| `gpo` | `git push origin` |
| `gpofwl` | `git push origin --force-with-lease` |
| `gpu` | `git push upstream` |
| `gpufwl` | `git push upstream --force-with-lease` |
| `gprb` | `git pull --rebase origin master` |
| `gch` | `git checkout` |
| `gb` | `git branch` |
| `gl` | Pretty git log |
| `grb` | `git rebase` |
| `grbc` | `git rebase --continue` |
| `rbi` | `git rebase -i master` |
| `squash` | `rbi && gca` |

### Git Branch Pruning
| Command | Description |
|---------|-------------|
| `gbprune` | Interactive fzf branch deletion (Tab to multi-select) |
| `gbprune --merged` | Show only merged branches |
| `gbprune --stale 30` | Show branches older than N days |
| `gbprune --all` | Show all branches |
| `gbdel` | Quick single branch delete with fzf |
| `gbdelmerged` | Delete all merged branches (non-interactive) |
| `gprune` | Prune remote tracking branches |
| `gprunelocal` | Delete local branches whose remote is gone |

### Utility Functions
| Command | Description |
|---------|-------------|
| `svenv` | `source .venv/bin/activate` |
| `svba [dir]` | Activate venv in submodule |
| `rrc` | Reload zshrc |
| `use-java N` | Switch Java version via SDKMAN |
| `ytmp3 <url>` | Download YouTube audio as MP3 |
| `to_mp3 <file>` | Convert any audio file to MP3 |
| `webm_to_mp3` | Convert all .webm files in directory |

### Push-gate (durable push approval)
| Command | Description |
|---------|-------------|
| `pg` | Review exact Diffview diff, then approve a human-first YAML lease draft |
| `pg -C <path>` | Run pg in another repo without `cd` |
| `pgr [shortname]` | fzf picker over active-lease repos + `~/repos/*`, then `pg -C` there |
| `pg leases` | Table of active leases across all repos (SQLite index) |
| `pg queue` | Show prepared briefs plus active leases |
| `pg approve-all -C repo1 -C repo2` | Sequentially run normal human approval review for multiple repos |
| `pg leases --all --json` | Full lease index as JSON |
| `pg leases reindex` | Scan `~/repos/*/.git/push-gate/leases/*` into the DB |
| `pg review-diff` | Open the exact approval diff in Neovim Diffview; `q` or `Space q r` closes the review |
| `Space g c` | Open AI-assisted local review thread UI that breaks vague notes into agent-actionable asks |
| `a/r/e/q` | In the review thread panel: accept/save, reply/refine, edit/save, or cancel |
| `:PgReviewComment TEXT` | Record a direct local cursor-line review comment |
| `Space r l` | Cycle Diffview split layouts while in the push-gate review |
| `Space r u` | Open a unified inline-style `git diff base..head` buffer |
| `Space 9 s` | Ask the optional 99/Codex helper to search the current repo/diff |
| `Space 9 v` | In visual mode, ask Codex for a suggested edit and store it as a local review comment |
| `pg review-comments --json` | Export local pre-push review comments for agents |
| `pg review-comments status` | Show unresolved/resolved/stale local review comment counts |
| `pg push --assert-flow TEXT` | Guarded push (requires active lease, scope-validated) |
| `pg check [branch]` | Machine-readable: approved scope plus unresolved local review comments |

Requires: `jq`, `yq` (mikefarah), `gh`, `sqlite3`, `fzf`, `nvim`, `Diffview.nvim`, Codex CLI, and the optional 99 helper. All installed by dotfiles bootstrap.

---

## Vim Features

### General Settings
- Line numbers enabled
- Syntax highlighting
- Smart indentation (2 spaces)
- Mouse support
- System clipboard integration (`brew install vim` for macOS)
- Trailing whitespace highlighted in red and auto-removed on save

### Navigation
| Keybinding | Action |
|------------|--------|
| `Ctrl+J/K` | Move 5 lines down/up |
| `Ctrl+H/L` | Navigate between splits |
| `<Space>bn` | Next buffer |
| `<Space>bp` | Previous buffer |
| `<Space>bd` | Delete buffer |

### Search
| Keybinding | Action |
|------------|--------|
| `Esc` | Clear search highlighting |
| `n/N` | Next/prev match (cursor stays centered) |
| `Ctrl+D/U` | Page down/up (cursor stays centered) |

### Search Settings
- Incremental search (matches as you type)
- Case-insensitive (unless uppercase used)
- All matches highlighted

### Visual Enhancements
- Custom status line showing: mode, filename, modified flag, filetype, line:col, percentage
- Cursor line highlighted
- 8 lines always visible above/below cursor
- Matching brackets highlighted

---

## File Structure

```
~/repos/fun-bash-automations/
├── .zshrc              → ~/.zshrc (symlink)
├── .vimrc              → ~/.vimrc (symlink)
├── zsh/
│   ├── personal.zsh    → ~/.zsh/personal.zsh (symlink)
│   └── netflix.zsh     → ~/.zsh/netflix.zsh (symlink)
└── setupPermissions.sh  # Run to install everything
```
