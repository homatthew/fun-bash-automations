#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/llm/hooks/cursor-mode-guard.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_guard() {
  jq -n --arg cmd "$1" '{tool_input: {command: $cmd}}' | bash "$GUARD"
}

assert_denied() {
  local out
  out="$(run_guard "$1")"
  grep -q '"permissionDecision": *"deny"' <<<"$out" ||
    fail "expected deny for: $1"
}

assert_allowed() {
  local out
  out="$(run_guard "$1")"
  [[ -z "$out" ]] || fail "expected pass-through for: $1 (got: $out)"
}

# Launches that would stall on an unanswered permission prompt.
assert_denied "cursor-agent --model kimi-k3-high 'review this diff'"
assert_denied "cursor-agent -p --mode ask --trust --model kimi-k3-high 'review'"
assert_denied "herdr agent start review --kind cursor --pane w1:pX"
assert_denied "herdr agent start review --kind cursor --pane w1:pX -- --trust --model composer-2.5"

# Correct launches.
assert_allowed "CURSOR_CONFIG_DIR=/tmp/empty cursor-agent -p --mode ask --force --trust --model kimi-k3-high 'review'"
assert_allowed "cursor-agent -p --yolo --model composer-2.5 'do the thing'"
assert_allowed "CURSOR_CONFIG_DIR=/tmp/empty herdr agent start review --kind cursor --pane w1:pX -- --force --trust --model composer-2.5"

# Read-only Cursor calls never prompt, so they must not be blocked.
assert_allowed "cursor-agent --list-models"
assert_allowed "cursor-agent --help"
assert_allowed "cursor-agent status"

# Command position, not mere mention: a launch after a separator still counts,
# while the name appearing as an argument to something else does not.
assert_denied "cd /tmp/work && cursor-agent --model composer-2.5 'go'"
assert_denied "CURSOR_API_KEY=x cursor-agent --model composer-2.5 'go'"
assert_allowed "grep -rn cursor-agent llm/"
assert_allowed "rg 'herdr agent start --kind cursor' docs/"

# Unrelated commands, and other agents, are untouched.
assert_allowed "git diff --stat"
assert_allowed "herdr agent start worker --kind codex --pane w1:pX"
assert_allowed "echo cursor-agent is mentioned in this string only"

echo "cursor mode guard regression passed"
