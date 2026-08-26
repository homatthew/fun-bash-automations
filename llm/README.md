# LLM Config Maintainer Guide

This directory is the canonical source for shared agent behavior across LLM
harnesses.

## Layout

- `AGENTS.md` shared instruction policy
- `agent-push-policy.json` schema-backed branch classes for delivery vs
  opt-in non-delivery scratch pushes
- `skills/*/SKILL.md` retained skill sources
- `skills.allowlist` custom skills projected into runtimes
- `hooks/*.sh` shared hooks (projected to both harnesses)
- `manifest.json` machine-readable mapping for projection scripts
- `integrations.md` Claude plugin vs Codex MCP parity map
- `../codex/config.toml` portable Codex config template
- `../codex/mcp.toml` explicit portable Codex MCP allowlist
- `../codex/MCP.md` Codex MCP install/auth notes
- `../codex/hooks.json` portable Codex hooks template
- `command-guard-policy.md` shared command safety policy

## Canonical Editing Rules

1. Edit shared guidance in `llm/AGENTS.md`.
2. Edit shared skills only under `llm/skills/`; add one to
   `llm/skills.allowlist` only after its recurring job is demonstrated.
3. Keep harness-specific deltas in adapter files (`claude/CLAUDE.md`, Claude
   runtime hooks/settings).
4. Never treat `~/.claude` or `~/.codex` as source of truth.
5. After changing repo-owned runtime files, run `fba-deploy` to project them
   into local harness homes.
6. Update `llm/command-guard-policy.md` before changing Claude hook guard
   behavior.

## Confidential Boundary

Keep project-specific confidential topology out of this repo: custom field IDs,
private board/category IDs, internal component mappings, team-owned labels,
personal deployment branches, private pipeline IDs, Slack channel lore, and
internal-only examples. Put that material in the private dotfiles overlay under
`~/repos/dotfiles/config/`, which installers layer after shared FBA assets. For
LLM skills, use `config/llm/skills-internal/`; for private shell config, use
`config/zsh/`; for Codex MCPs and plugin marketplaces, use `config/codex/`.

## Projection Targets

- Claude:
  - `~/.claude/CLAUDE.md` -> `claude/CLAUDE.md`
  - `~/.claude/AGENTS.md` -> `llm/AGENTS.md`
  - `~/.claude/agent-push-policy*.json` -> `llm/agent-push-policy*.json`
  - `~/.claude/skills/*` -> skills named in `llm/skills.allowlist`
  - `~/.claude/hooks/*.sh` -> `llm/hooks/*.sh` + `claude/hooks/*.sh`
- Codex:
  - `~/.codex/auth.json` -> preserved as user-local authentication state
  - `~/.codex/config.toml` -> rendered from `codex/config.toml` plus
    `codex/mcp.toml`, preserving user-local state
  - `~/.codex/hooks.json` -> copied from `codex/hooks.json`
  - `~/.codex/hooks/*.sh` -> `llm/hooks/*.sh`
  - `~/.codex/AGENTS.md` -> `llm/AGENTS.md`
  - `~/.codex/agent-push-policy*.json` -> `llm/agent-push-policy*.json`
  - `~/.codex/skills/*` -> skills named in `llm/skills.allowlist` (preserve
    `.codex/skills/.system`)

Adding a new shared hook: drop a `.sh` into `llm/hooks/`, run `fba-deploy`,
then wire it into each harness's config (`claude/settings.json`,
`codex/hooks.json`).
- External skills are projected only from directories explicitly passed with
  `fba-deploy --external-skills-dir <dir>`; they reach Claude, Codex, and Cursor.
  If `<dir>.allowlist` exists, it controls both projection and pruning so the
  three runtimes converge after every deploy. Machine-specific checkouts are
  never discovered implicitly.
  Private overlays own any related environments, credentials, and install
  paths.

## Guardrail Sync

- Shared command guard intent lives in `llm/command-guard-policy.md`.
- Claude has native command-hook enforcement.
- Codex has experimental native command-hook enforcement for supported events.
- Both harnesses use the same guard script implementations for Bash pre-tool
  checks.

## Compaction Recovery

- Task continuity: `bd ready`
- Durable architecture notes: `${SECOND_BRAIN_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/second-brain}/topics/*/README.md`
- Repo-level rediscovery path:
  1. `AGENTS.md`
  2. `llm/manifest.json`
  3. `llm/integrations.md`
