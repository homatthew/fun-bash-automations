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

- This repository delivers directly on `main`; there is no PR gate. **Fix
  forward on `main`** — do not open long-lived branches here. A long-lived branch
  accumulates unaudited history, makes parallel sessions collide, and turns
  delivery into a rewrite exercise.
- After the user explicitly asks to push or invokes an explicit finish workflow,
  push directly with an explicit branch target: `git push origin main`. The guard
  permits exactly that combination for this repository, per
  `direct_push_exceptions` in `llm/agent-push-policy.json`. Force forms, other
  remotes, other protected refs, bare pushes, and unresolved repository
  redirects (`--git-dir`, `--work-tree`, `--namespace`) all stay blocked.
  `git -C <repo> push origin main` is allowed only after the guard resolves
  `<repo>` and finds its matching direct-delivery entry.
- Do not start parallel sessions unless the user asks. When parallel work is
  requested, isolate each writer in its own worktree.
- Before delivery, run the repository's relevant focused tests and inspect the
  outgoing diff. Add review ceremony only when the change's risk warrants it or
  the user requests it.
- Keep PRs and delivery commits reviewable: target under ~400 changed lines and
  ~15 files, one reviewable claim each, refactors separate from behaviour changes.
- That delivery push rule does not apply to configured non-delivery scratch
  branches when Remote Scratch Mode is active; see `llm/AGENTS.md` and
  `llm/agent-push-policy.json`. Promoting scratch work to a delivery branch uses
  the normal delivery checks above.
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
