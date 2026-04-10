# Claude Runtime Adapter

@../llm/AGENTS.md

This file is Claude-specific runtime guidance layered on top of shared policy.

## Notifications

- Notifications are handled by `~/.claude/hooks/notify.sh`.
- Do not call `terminal-notifier` manually.

## Claude Runtime Files

- Settings: `~/repos/fun-bash-automations/claude/settings.json`
- Hooks: `~/repos/fun-bash-automations/claude/hooks/*.sh`
- Status line: `~/repos/fun-bash-automations/claude/statusline.sh`
- Claude-only agents: `~/repos/fun-bash-automations/claude/agents/*.md`

## Projection Model

- `~/.claude/CLAUDE.md` -> this adapter
- `~/.claude/AGENTS.md` -> `~/repos/fun-bash-automations/llm/AGENTS.md`
- `~/.claude/skills/*` -> `~/repos/fun-bash-automations/llm/skills/*`

Shared edits belong in `llm/`, not in this adapter.

