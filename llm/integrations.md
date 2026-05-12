# Integration Parity Map (Claude -> Codex)

This inventory distinguishes portable MCP integrations from Claude-specific
plugin behavior.

## Command Guardrail Parity

- Shared command safety policy lives in `llm/command-guard-policy.md`.
- Claude currently enforces part of that policy with native `PreToolUse` hook
  scripts under `claude/hooks/`.
- Codex in this repo uses experimental native hooks via `codex/hooks.json`.
- The current Codex parity target is Bash `PreToolUse` guardrails using the
  same guard script implementations that Claude uses.

## Portable MCP (configure in Codex)

- Sourcegraph MCP
  - If Sourcegraph returns a 502, especially `downstream` or
    `ngp-mcp-sourcegraph`, ask the user to open
    `http://go/authorize-sourcegraph`, then retry the query.

- `chrome-devtools-mcp@chrome-devtools-plugins`
  - Claude plugin contains an MCP server definition:
    - command: `npx`
    - args: `chrome-devtools-mcp@latest`
  - Codex parity target: register as Codex MCP server.

## Non-MCP Claude Plugin Workflows (shared skill/helper parity)

- `beads@beads-marketplace`
  - Primarily command/agent bundle + hooks (`bd prime`)
  - Parity strategy: shared skills + shell functions + explicit AGENTS policy.

- `codex@openai-codex`
  - Claude plugin that delegates to Codex from Claude.
  - No Codex-side parity required; Codex is already the primary harness.

- `frontend-design`, `pr-review-toolkit`, `code-review`, `skill-creator`,
  `superpowers`, `interface-design`, `elements-of-style`, `ods-first-team`
  - Treat as Claude plugin UX unless an explicit MCP server contract exists.
  - Parity strategy: document as Claude-only or re-create high-value behavior
    via shared `llm/skills`.
