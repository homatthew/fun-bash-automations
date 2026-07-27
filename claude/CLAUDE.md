# Claude Runtime Adapter

@../llm/AGENTS.md

This file is Claude-specific runtime guidance layered on top of shared policy.

## Notifications

- The portable baseline registers no alert hooks. Where `notify.sh` is
  registered locally, it owns alerts; `fba-deploy` preserves that registration.
- Do not call `terminal-notifier` manually.

## Claude Runtime Files

- Settings: `~/repos/fun-bash-automations/claude/settings.json`
- Hooks: `~/repos/fun-bash-automations/llm/hooks/*.sh` (shared) + `~/repos/fun-bash-automations/claude/hooks/*.sh` (Claude-only)
- Status line: `~/repos/fun-bash-automations/claude/statusline.sh`
- Claude-only agents: `~/repos/fun-bash-automations/claude/agents/*.md`

## Projection Model

- `~/.claude/CLAUDE.md` -> this adapter
- `~/.claude/AGENTS.md` -> `~/repos/fun-bash-automations/llm/AGENTS.md`
- `~/.claude/skills/*` -> `~/repos/fun-bash-automations/llm/skills/*`

## Shared Finish Workflow

- When the user says `/ship`, load the shared `/ship` skill from projected
  skills and use it as the finish-the-job workflow.
- Keep execution-quality rules in `llm/AGENTS.md` and `llm/skills/*`, not in
  this adapter.

Shared edits belong in `llm/`, not in this adapter.
