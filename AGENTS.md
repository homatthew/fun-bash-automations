# fun-bash-automations Agent Guide

This repository is configured for multi-harness agent use. `AGENTS.md` is the
canonical instruction entrypoint.

## Canonical Sources

- Repository role, install paths, and contribution guide: `README.md`
- Shared instructions: `llm/AGENTS.md`
- Shared skills: `llm/skills/*/SKILL.md`
- Shared layout + migration notes: `llm/README.md`
- Machine-readable mapping: `llm/manifest.json`
- Portable Codex config template: `codex/config.toml`
- Portable Codex MCP allowlist and docs: `codex/mcp.toml`, `codex/MCP.md`
- Codex authentication: user-local state preserved by `fba-deploy`

## Repository Delivery Policy

- This repository delivers directly on `main`; there is no PR gate.
- After the user explicitly asks to push or invokes an explicit finish workflow,
  the no-mistakes gate performs the direct delivery push with an explicit branch
  target, e.g. `git push origin main`.
- The finish-the-job entrypoint is the `/ship` skill for a single change; it runs
  the `no-mistakes` gate (automated code review, tests, lint, docs) and then
  pushes to the configured target. For breadth across many tasks use `firstmate`;
  for a long-run single-objective loop use `gnhf`.
- That delivery push rule does not apply to configured non-delivery scratch
  branches when Remote Scratch Mode is active; see `llm/AGENTS.md` and
  `llm/agent-push-policy.json`. Promoting scratch work to a delivery branch goes
  through the `no-mistakes` gate.
- Do not create, reopen, or mark ready PRs for this repository; `main` is the
  direct-push delivery branch.

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
- For durable resumption across compaction, use beads (`bd ready`) and the
  optional `SECOND_BRAIN_DIR` knowledge store.

## Install Boundary

- Treat this repository as the shared base layer.
- Treat `~/repos/dotfiles` as the private final-install layer for company
  workspaces and MacBook-specific local overlays.
- Do not add confidential topology, private URLs, or machine-specific install
  behavior here; put those details in `dotfiles/config/`.
- For MacBook shell repair, prefer `dotfiles/scripts/link-local-shell.sh`
  instead of the full workspace installer.

## Open-Source Boundary

- Keep this repository suitable for general OSS use. Reusable shell behavior,
  Unix preferences, and portable agent workflows belong here.
- Before delivery, inspect both the outgoing snapshot and any commit history
  newly introduced to `main`. Deleted secrets and private details still exist
  when their historical commits are published.
- If a branch carries old local history that has not been audited for public
  release, rebuild the desired snapshot on the current public `main` rather
  than publishing that history wholesale.
- Move company-internal topology, private URLs, credentials, private auth,
  team-specific lore, and machine-specific overlays to `~/repos/dotfiles`.
