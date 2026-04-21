# LLM Config Maintainer Guide

This directory is the canonical source for shared agent behavior across LLM
harnesses.

## Layout

- `AGENTS.md` shared instruction policy
- `skills/*/SKILL.md` shared skills
- `hooks/*.sh` shared hooks (projected to both harnesses)
- `manifest.json` machine-readable mapping for projection scripts
- `integrations.md` Claude plugin vs Codex MCP parity map
- `../codex/config.toml` portable Codex config template
- `../codex/auth.json` portable Codex auth template (dummy gateway token)
- `../codex/hooks.json` portable Codex hooks template
- `command-guard-policy.md` shared command safety policy

## Canonical Editing Rules

1. Edit shared guidance in `llm/AGENTS.md`.
2. Edit shared skills only under `llm/skills/`.
3. Keep harness-specific deltas in adapter files (`claude/CLAUDE.md`, Claude
   runtime hooks/settings).
4. Never treat `~/.claude` or `~/.codex` as source of truth.
5. After changing repo-owned runtime files, run `fba-deploy` to project them
   into local harness homes.
6. Update `llm/command-guard-policy.md` before changing Claude hook guard
   behavior.

## Projection Targets

- Claude:
  - `~/.claude/CLAUDE.md` -> `claude/CLAUDE.md`
  - `~/.claude/AGENTS.md` -> `llm/AGENTS.md`
  - `~/.claude/skills/*` -> `llm/skills/*`
  - `~/.claude/hooks/*.sh` -> `llm/hooks/*.sh` + `claude/hooks/*.sh`
- Codex:
  - `~/.codex/auth.json` -> copied from `codex/auth.json`
  - `~/.codex/hooks.json` -> copied from `codex/hooks.json`
  - `~/.codex/hooks/*.sh` -> `llm/hooks/*.sh`
  - `~/.codex/AGENTS.md` -> `llm/AGENTS.md`
  - `~/.codex/skills/*` -> `llm/skills/*` (preserve `.codex/skills/.system`)

Adding a new shared hook: drop a `.sh` into `llm/hooks/`, run `fba-deploy`,
then wire it into each harness's config (`claude/settings.json`,
`codex/hooks.json`).
- External skills (managed by `fba-deploy project_shared`):
  - `~/repos/cursor-google-workspace-skills/skills/google-*` -> both `~/.claude/skills/` and `~/.codex/skills/`
  - Venv: `~/.claude/google-workspace-venv` (shared, scripts bootstrap into it)
  - Creds: `~/.claude/google_credentials.json` (shared across harnesses)

## Guardrail Sync

- Shared command guard intent lives in `llm/command-guard-policy.md`.
- Claude has native command-hook enforcement.
- Codex has experimental native command-hook enforcement for supported events.
- Both harnesses use the same guard script implementations for Bash pre-tool
  checks.

## Compaction Recovery

- Task continuity: `bd ready`
- Durable architecture notes: `~/repos/dump/second-brain/topics/*/README.md`
- Repo-level rediscovery path:
  1. `AGENTS.md`
  2. `llm/manifest.json`
  3. `llm/integrations.md`
