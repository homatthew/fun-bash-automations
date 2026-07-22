#!/bin/bash
# Codex PostToolUse hook: append-only audit log of Bash tool invocations.
#
# Writes minimal JSONL records to ~/.codex/logs/audit.jsonl so Bash tool use is
# reviewable post-facto. No network, no slack, no user notifications.
#
# Emits an empty JSON object so Codex proceeds normally.

set -euo pipefail

INPUT=$(cat)

LOG_DIR="${CODEX_AUDIT_DIR:-$HOME/.codex/logs}"
LOG_FILE="$LOG_DIR/audit.jsonl"
umask 077
mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Produce a compact one-line JSON record per invocation.
printf '%s' "$INPUT" | jq -c --arg ts "$ts" '{
  ts: $ts,
  tool: (.tool_name // null),
  exit_code: (try (.tool_response | fromjson | .exit_code) catch null)
}' >> "$LOG_FILE" 2>/dev/null || true

printf '{}\n'
