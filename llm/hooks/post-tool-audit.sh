#!/bin/bash
# Codex PostToolUse hook: append-only audit log of Bash tool invocations.
#
# Writes JSONL records to ~/.codex/logs/audit.jsonl so Bash commands executed
# by Codex are reviewable post-facto. Intentionally dumb and side-effect-free
# beyond the log write. No network, no slack, no user notifications.
#
# Emits an empty JSON object so Codex proceeds normally.

set -euo pipefail

INPUT=$(cat)

LOG_DIR="${CODEX_AUDIT_DIR:-$HOME/.codex/logs}"
LOG_FILE="$LOG_DIR/audit.jsonl"
mkdir -p "$LOG_DIR"

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Produce a compact one-line JSON record per invocation.
printf '%s' "$INPUT" | jq -c --arg ts "$ts" '{
  ts: $ts,
  session_id: (.session_id // null),
  turn_id: (.turn_id // null),
  cwd: (.cwd // null),
  tool: (.tool_name // null),
  command: (.tool_input.command // null),
  exit_code: (try (.tool_response | fromjson | .exit_code) catch null)
}' >> "$LOG_FILE" 2>/dev/null || true

printf '{}\n'
