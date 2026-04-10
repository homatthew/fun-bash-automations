# Shared LLM Agent Policy

This file is the canonical shared instruction source for personal agent
workflows across Claude, Codex, and future harnesses.

## Core Rules

- Keep history linear in `fun-bash-automations` on branch `mh-netflix`.
- Do not push unless explicitly asked.
- Use `push-gate` before any push operation that requires approval.
- Keep shared behavior harness-agnostic in this file and in `llm/skills`.

## Shared Runtime Assumptions

- Repositories live under `~/repos/*`.
- Beads is the persistent task tracker:
  - DB: `~/repos/dump/.beads/beads.db`
  - Resume after compaction with `bd ready`.
- Second-brain knowledge lives at:
  - Index: `~/repos/dump/second-brain/README.md`
  - Topics: `~/repos/dump/second-brain/topics/<topic>/README.md`

## Shared Skills

- Canonical skills directory: `llm/skills/`.
- Skill file name is always `SKILL.md`.
- Harness adapters may project these skills into `~/.claude/skills` or
  `~/.codex/skills`, but source-of-truth remains `llm/skills`.

## Harness-Specific Files

- Claude-only runtime files live under `claude/`:
  - `claude/settings.json`
  - `claude/hooks/*.sh`
  - `claude/statusline.sh`
  - `claude/agents/*.md`
- `claude/CLAUDE.md` is a Claude adapter and should not duplicate shared policy.

## LLM Config Maintenance

- Structural source of truth: `llm/manifest.json`
- Human maintainer guide: `llm/README.md`
- Integration parity + MCP mapping: `llm/integrations.md`
- Shared command guard policy: `llm/command-guard-policy.md`
- Use `fba-deploy` after editing repo-owned runtime files so `~/.claude` and
  `~/.codex` stay in sync with this repo.
