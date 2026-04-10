# Integration Parity Map (Claude -> Codex)

This inventory distinguishes portable MCP integrations from Claude-specific
plugin behavior.

## Command Guardrail Parity

- Shared command safety policy lives in `llm/command-guard-policy.md`.
- Claude currently enforces part of that policy with native `PreToolUse` hook
  scripts under `claude/hooks/`.
- Codex in this repo currently relies on shared `AGENTS.md` policy and native
  approval/sandbox controls rather than a documented repo-local pre-command
  hook adapter.

## Portable MCP (configure in Codex)

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
