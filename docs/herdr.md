# Herdr portable profile

The repository owns a portable template, helper commands, and an explicit
installer. It does not track a rendered `config.toml`, a generated Herdr skill,
plugin checkouts, integration hooks, sockets, or pane history.

## Install

Install the core command-line and terminal dependencies, then opt into the
profile:

```bash
brew bundle
bin/install-herdr --adopt
bin/install-herdr --check
```

Adoption renders `herdr/config.toml.in` with this checkout's `bin/` directory,
backs up a different existing config, and generates the canonical agent skill
from the installed `herdr --skill`. Nothing mutates Herdr configuration without
`--adopt`.

Plugins and agent integrations are separate, explicit scopes:

```bash
bin/install-herdr --adopt --plugins
bin/install-herdr --adopt --integrations claude,codex,kimi,cursor
bin/install-herdr --check --plugins --integrations claude,codex,kimi,cursor
```

`herdr/plugins.toml` pins public plugins to immutable commits. A local
confirmation plugin is intentionally absent from the public manifest; link one
only with `--local-confirmation-plugin DIR`.

## Dependencies

| Component | Used by |
| --- | --- |
| Herdr | multiplexer, pane/agent lifecycle, generated skill |
| Bash | installer and helper commands |
| `jq` | Herdr JSON responses and saved pane records |
| `git` | plugin installation and broader FBA workflows |
| `ripgrep` | installer validation |
| `nc` | Herdr socket layout export in `herdr-pane-snapshot` |
| Ghostty | OSC appearance reporting, notifications, and terminal UI |

macOS provides `nc`. On Linux, install a Unix-socket-capable `nc` with the
distribution's native package manager; the Brewfile does not supply it.
`fzf`, `gh`, and GNU core utilities are part of the broader FBA toolset declared
by the root `Brewfile`. Ghostty is installed by Brew Bundle only on macOS.

## Bindings

The prefix is `ctrl+space`.

| Binding | State | Behavior |
| --- | --- | --- |
| `prefix+x` | active | Confirm, snapshot, and close the current pane |
| `cmd+u` / `cmd+i` | active | Focus previous/next agent in the workspace |
| `prefix+u` | active | Reopen the last snapshotted pane and resume its agent |
| `prefix+shift+z` | active | Confirm and close a tab after snapshotting its panes |
| `prefix+shift+q` | active | Herdr's immediate close-pane escape hatch |
| `cmd+l` | active | Focus the previously active pane |
| `prefix+p` / `prefix+n` | active default | Previous/next tab |
| `prefix+shift+v` | plugin | Toggle the reviewr pane |
| `prefix+f` / `prefix+shift+f` | plugin | Open file viewer split/tab |
| `herdr-cycle-tab` | installed, unbound | Alternative tab cycling helper |
| `herdr-close-pane` | installed, unbound | Immediate close with an undo snapshot |

The confirmation commands use repository scripts, so they work without the
optional local confirmation plugin. Plugin bindings require their pinned public
plugins to be installed.

## Resume and appearance behavior

Reopened Claude and Codex panes always retain their bypass-permission flags.
Cursor/Grok resume with Cursor's force flag. Kimi uses its native
`--yolo --session ID` interface rather than Cursor flags.

Herdr selects Catppuccin Latte for light appearance and Catppuccin for dark
appearance. Ghostty reports the macOS appearance and uses its matching built-in
light/dark pair; see `ghostty/config`.
