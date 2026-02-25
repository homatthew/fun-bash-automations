#!/bin/bash
# dgw-write-guard.sh
# PreToolUse hook: blocks dgw-cli kv put/delete against any environment
# unless the matching authorization flag is present:
#   DGW_TEST_WRITE_AUTHORIZED=1  for -e test
#   DGW_PROD_WRITE_AUTHORIZED=1  for -e prod

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# Only act on dgw-cli kv write operations
if echo "$COMMAND" | grep -qE 'dgw-cli[[:space:]]+kv' && \
   echo "$COMMAND" | grep -qE '[[:space:]](put|delete)[[:space:]]'; then

  # Determine target environment
  if echo "$COMMAND" | grep -qE '(-e|--env)[[:space:]]+prod'; then
    ENV=prod
    FLAG=DGW_PROD_WRITE_AUTHORIZED=1
  elif echo "$COMMAND" | grep -qE '(-e|--env)[[:space:]]+test'; then
    ENV=test
    FLAG=DGW_TEST_WRITE_AUTHORIZED=1
  else
    ENV=unknown
    FLAG=DGW_PROD_WRITE_AUTHORIZED=1  # default to prod-level restriction
  fi

  # Allow if the correct flag is present
  if echo "$COMMAND" | grep -q "$FLAG"; then
    exit 0
  fi

  jq -n --arg env "$ENV" --arg flag "$FLAG" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: ("dgw-cli KV writes to " + $env + " are blocked. To authorize, the user must explicitly confirm intent in their message, then prefix the command with " + $flag + ".")
    }
  }'
  exit 0
fi

exit 0
