# Portable Integration Map

This repository contains only integrations that are reusable outside a private
company environment. Internal gateways, private Slack tooling, enterprise-host
overrides, and credentials belong in the private `dotfiles` overlay.

## Command Guardrail Parity

- Shared command safety policy lives in `llm/command-guard-policy.md`.
- Claude and Codex project the same shared Bash guard through `fba-deploy`.
- Environment-specific protections should be added as dotfiles-owned guard
  extensions instead of hard-coded into the shared runtime.

## Portable MCPs

Codex MCPs are declared in `codex/mcp.toml`; install and authentication notes
live in `codex/MCP.md`. Only add servers with public installation instructions
and no dependency on private endpoints or credentials.

- `chrome-devtools`
  - command: `npx`
  - package: `chrome-devtools-mcp@1.6.0`

Private MCP gateways and internal plugin marketplaces are layered by
`dotfiles/config/codex/mcp-overlay.toml` after the portable FBA projection.

## Claude-Only Plugins

Claude plugins without a portable MCP or command contract remain Claude-only.
Re-create behavior in shared `llm/skills` only when it is useful and runnable
in a general OSS environment.
