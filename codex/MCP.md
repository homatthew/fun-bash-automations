# Codex MCP Setup

Codex MCPs are explicit. Do not copy Claude, Dropship, or plugin MCP state into
Codex by default. A server belongs in `codex/mcp.toml` only when its Codex
command, arguments, environment, and remote install/auth requirements are known.

`bin/fba-deploy` renders `codex/config.toml`, appends `codex/mcp.toml`, then
preserves user-local Codex sections such as hook trust state, model NUX state,
project trust, plugin marketplaces, and unmanaged local MCPs.

## Conflict Behavior

`fba-deploy` treats the table headers in `codex/mcp.toml` as the managed
portable MCP set. Existing local tables with the same names, or child tables
under those names such as `mcp_servers.example.env`, are replaced during
projection. Local MCPs with different names are preserved by default.

The private dotfiles workspace installer layers its internal MCP/plugin overlay
after `fba-deploy`. It strips tables owned by that overlay before appending it,
so repeated installs update those definitions instead of creating duplicate
TOML tables.

This prevents literal config duplicates. It cannot infer semantic duplicates:
two differently named MCPs may still point at the same backend if both are
listed intentionally.

## Portable MCPs

### chrome-devtools

- Config: `mcp_servers.chrome-devtools`
- Command: `npx chrome-devtools-mcp@1.6.0`
- Remote requirement: Node.js and `npx`.
- Auth: none.

## Not Automatic

These are not automatically Codex MCPs:

- Claude plugin MCPs.
- Dropship MCP state.
- Internal MCPs that require private gateways, packages, or authentication.

Add each as an explicit portable entry only after confirming the Codex endpoint,
install path, and auth behavior for remote workspaces.
