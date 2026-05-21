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

- `chrome-devtools`
  - command: `npx`
  - args: `chrome-devtools-mcp@latest`

- `core-tools`
  - HTTP MCP gateway for Netflix search, manuals, Slack RAG, and direct Slack
    thread fetch.

- `ndex-slack-private`
  - Slack MCP from the ODS first-team Claude plugin.
  - Codex uses `bin/launch-slack-mcp` so Keychain Slack token behavior matches
    local agent setup (`slack-user-token` or `claude-slack-user-token`).
  - Prefer `slack-user-token` as the canonical Keychain service name;
    `claude-slack-user-token` is supported only as a compatibility fallback.
  - Private Slack decision tree:
    1. Use `core-tools.fetch_slack_thread` for Slack content the Netflix MCP
       gateway can access.
    2. If `core-tools` returns `403` for a private channel, use
       `ndex-slack-private`; the gateway identity lacks private-channel access.
    3. If `ndex-slack-private` returns `Transport closed`, do not assume Slack
       auth is broken. Codex lost the MCP stdio process; validate the same
       permalink through the CLI fallback before asking for auth repair.
  - CLI fallback for private threads:
    ```bash
    bin/slack-private-thread --permalink "<permalink>"
    ```
    Equivalent raw command:
    ```bash
    SLACK_USER_TOKEN="$(security find-generic-password -s slack-user-token -w 2>/dev/null || security find-generic-password -s claude-slack-user-token -w)" \
      npx -y -p @netflix-internal/ndex-slack-private \
      ndex-slack-private-cli get_thread_from_permalink --permalink "<permalink>"
    ```
  - Troubleshooting:
    - `403` from `core-tools` means the gateway identity cannot read that
      private channel.
    - `Transport closed` from `ndex-slack-private` means the local MCP transport
      closed; the Slack token can still be valid.
    - Confirm token validity with the CLI fallback. Do not print token values.
    - Restart Codex after changing Keychain token values so the MCP server
      re-reads the token.

- `NECP`
  - HTTP MCP gateway for Netflix engineering context.

- `netflix-ci-official`
  - HTTP MCP gateway for Netflix CI / Boost tooling.

- `nflx-spinnaker`
  - command: `npx`
  - args: `-y @netflix-internal/mcp-server-spinnaker@latest`

- Sourcegraph MCP
  - Configured as both stdio `sourcegraph` and HTTP `sourcegraph-official`,
    matching the current Claude setup.
  - If Sourcegraph returns a 502, especially `downstream` or
    `ngp-mcp-sourcegraph`, ask the user to open
    `http://go/authorize-sourcegraph`, then retry the query.

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
