# fun-bash-automations Agent Guide

This repository is configured for multi-harness agent use. `AGENTS.md` is the
canonical instruction entrypoint.

## Canonical Sources

- Shared instructions: `llm/AGENTS.md`
- Shared skills: `llm/skills/*/SKILL.md`
- Shared layout + migration notes: `llm/README.md`
- Machine-readable mapping: `llm/manifest.json`
- Portable Codex config template: `codex/config.toml`
- Portable Codex auth template: `codex/auth.json`

## Repository Delivery Policy

- This repository does not use push-gate.
- After the user explicitly asks to push or invokes an explicit finish workflow,
  agents should push directly with normal `git push` to `mh-netflix`.
- Do not run `pg prepare`, ask the user to run `pg`, or use `pg push` for this
  repository.
- Do not create, reopen, or mark ready PRs from `mh-netflix` to `main`;
  `mh-netflix` is the delivery branch.

## Compatibility Adapters

- `CLAUDE.md` at repo root is a compatibility shim for Claude.
- `claude/CLAUDE.md` contains Claude-only runtime behavior and imports the
  shared instructions.
- Claude-only runtime assets remain in `claude/` (`settings.json`, hooks,
  statusline, agents).

## LLM Config Maintenance

- Edit shared policy/skills in `llm/` only.
- Do not treat `~/.claude/*` or `~/.codex/*` as source of truth.
- Use setup/install scripts to project shared files to home directories.
- For durable resumption across compaction, use beads (`bd ready`) and second
  brain topics in `~/repos/dump/second-brain/topics/*/README.md`.
