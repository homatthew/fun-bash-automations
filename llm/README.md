# LLM Config Maintainer Guide

This directory is the canonical source for shared agent behavior across LLM
harnesses.

## Layout

- `AGENTS.md` shared instruction policy
- `agent-push-policy.json` schema-backed branch classes for delivery vs
  opt-in non-delivery scratch pushes
- `skills/*/SKILL.md` shared skills
- `hooks/*.sh` shared hooks (projected to both harnesses)
- `kun-stack/manifest.json` pinned Kun-stack tool versions for
  `kun-stack-install` / `kun-stack-verify`
- `no-mistakes-stages.md` no-mistakes stage and skip semantics
- `sanctioned-paths.md` one sanctioned tool per agent workflow function
- `manifest.json` machine-readable mapping for projection scripts
- `integrations.md` Claude plugin vs Codex MCP parity map
- `firstmate/` checked-in firstmate preset baselines
- `gnhf-per-repo-config.md` `.gnhf.yml` + `gnhf-here` convention
- `../codex/config.toml` portable Codex config template
- `../codex/mcp.toml` explicit portable Codex MCP allowlist
- `../codex/MCP.md` Codex MCP install/auth notes
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
  - `~/.claude/skills/*` -> `llm/skills/*`
  - `~/.claude/hooks/*.sh` -> copied shared hooks from `llm/hooks/*.sh` plus
    optional Claude-only hooks from `claude/hooks/*.sh`
- Codex:
  - `~/.codex/auth.json` -> copied from `codex/auth.json`
  - `~/.codex/config.toml` -> rendered from `codex/config.toml` plus
    `codex/mcp.toml`, preserving user-local state
  - `~/.codex/hooks.json` -> copied from `codex/hooks.json`
  - `~/.codex/hooks/*.sh` -> `llm/hooks/*.sh`
  - `~/.codex/AGENTS.md` -> `llm/AGENTS.md`
  - `~/.codex/agent-push-policy*.json` -> `llm/agent-push-policy*.json`
  - `~/.codex/skills/*` -> `llm/skills/*` (preserve `.codex/skills/.system`)

Adding a new shared hook: drop a `.sh` into `llm/hooks/`, run `fba-deploy`,
then wire it into each harness's config (`claude/settings.json`,
`codex/hooks.json`).
- External skills (managed by `fba-deploy project_shared`):
  - `~/repos/cursor-google-workspace-skills/skills/google-*` -> both `~/.claude/skills/` and `~/.codex/skills/`
  - Venv: `~/.claude/google-workspace-venv` (shared, scripts bootstrap into it)
  - Creds: `~/.claude/google_credentials.json` (shared across harnesses)

## Projection Behavior

`bin/fba-deploy` has four modes: full projection, `--claude-only`,
`--codex-only`, and `--shared-only`. Full/Claude/Codex modes copy shared hooks,
project shared skills, prune retired repo-managed skill links when they still
match the old repo-managed content, and render harness-specific config.
`--shared-only` refreshes shared `AGENTS.md`, push-policy JSON, and skill links
in both homes without rewriting harness-specific settings.

Codex config rendering preserves user-local sections that are not managed by
FBA: hook trust state, model NUX state, project trust, plugin/marketplace
sections, and unmanaged `mcp_servers.*` tables by default. Set
`FBA_DEPLOY_PRESERVE_CODEX_MCP=0` to stop preserving unmanaged local Codex MCP
tables during projection.

Other projection knobs:

- `USER_NETFLIX_EMAIL` overrides the email substituted into
  `claude/settings.json`; otherwise `fba-deploy` uses `git config user.email`
  when it is a Netflix address.
- `MODEL_GATEWAY_PROJECT_ID` switches the rendered Codex base URL from the
  local default project to the secure project proxy.
- `FBA_DEPLOY_SKIP_MAC_EXTRAS=1` skips macOS-only Claude Notify.app and VS Code
  OSC notifier installation.
- `FBA_DEPLOY_LOG=<path>` appends projection actions to a shared installer log.

## Guardrail Sync

- Shared command guard intent lives in `llm/command-guard-policy.md`.
- Claude has native command-hook enforcement wired through `claude/settings.json`
  to shared scripts in `llm/hooks/*.sh`.
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
