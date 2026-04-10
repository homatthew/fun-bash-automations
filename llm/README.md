# LLM Config Maintainer Guide

This directory is the canonical source for shared agent behavior across LLM
harnesses.

## Layout

- `AGENTS.md` shared instruction policy
- `skills/*/SKILL.md` shared skills
- `manifest.json` machine-readable mapping for projection scripts
- `integrations.md` Claude plugin vs Codex MCP parity map
- `../codex/config.toml` portable Codex config template
- `../codex/auth.json` portable Codex auth template (dummy gateway token)

## Canonical Editing Rules

1. Edit shared guidance in `llm/AGENTS.md`.
2. Edit shared skills only under `llm/skills/`.
3. Keep harness-specific deltas in adapter files (`claude/CLAUDE.md`, Claude
   runtime hooks/settings).
4. Never treat `~/.claude` or `~/.codex` as source of truth.
5. After changing repo-owned runtime files, run `fba-deploy` to project them
   into local harness homes.

## Projection Targets

- Claude:
  - `~/.claude/CLAUDE.md` -> `claude/CLAUDE.md`
  - `~/.claude/AGENTS.md` -> `llm/AGENTS.md`
  - `~/.claude/skills/*` -> `llm/skills/*`
- Codex:
  - `~/.codex/auth.json` -> copied from `codex/auth.json`
  - `~/.codex/AGENTS.md` -> `llm/AGENTS.md`
  - `~/.codex/skills/*` -> `llm/skills/*` (preserve `.codex/skills/.system`)

## Compaction Recovery

- Task continuity: `bd ready`
- Durable architecture notes: `~/repos/dump/second-brain/topics/*/README.md`
- Repo-level rediscovery path:
  1. `AGENTS.md`
  2. `llm/manifest.json`
  3. `llm/integrations.md`
