#!/bin/bash
# PostToolUse hook: add a targeted recovery hint for Sourcegraph MCP 502s.

set -euo pipefail

INPUT=$(cat)
HINT="Sourcegraph MCP returned a 502. This usually means Sourcegraph auth expired. Ask the user to open http://go/authorize-sourcegraph, then retry the Sourcegraph query. Do not keep retrying unauthenticated."

if ! printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1; then
  printf '{}\n'
  exit 0
fi

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // ""')
EVENT_NAME=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // "PostToolUse"')
PAYLOAD=$(printf '%s' "$INPUT" | jq -c .)

if ! printf '%s\n%s\n' "$TOOL_NAME" "$PAYLOAD" | grep -Eiq 'sourcegraph|ngp-mcp-sourcegraph'; then
  printf '{}\n'
  exit 0
fi

if ! printf '%s\n' "$PAYLOAD" | grep -Eiq '(^|[^0-9])502([^0-9]|$)|bad gateway|downstream'; then
  printf '{}\n'
  exit 0
fi

jq -n --arg hint "$HINT" --arg event "$EVENT_NAME" '{
  systemMessage: $hint,
  hookSpecificOutput: {
    hookEventName: $event,
    additionalContext: $hint
  }
}'
