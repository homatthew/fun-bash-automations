#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SPAWN_IMPL="$ROOT/lib/cursor-sub-review/spawn-cursor-pane.sh"
TMP="$(mktemp -d -t fba-cursor-sub-review-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

mkdir -p "$TMP/bin" "$TMP/workspace/.cursor" "$TMP/output"
printf '%s\n' '{"mcpServers":{"workspace-tool":{"command":"false"}}}' \
  > "$TMP/workspace/.cursor/mcp.json"
cat > "$TMP/bin/cursor-agent" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--list-models" ]]; then
  echo "test-model"
  exit 0
fi
if [[ "${1:-} ${2:-}" == "mcp list" ]]; then
  if [[ -e "${CURSOR_CONFIG_DIR:?}/workspace-tool.disabled" ]]; then
    echo "workspace-tool: disabled"
  elif [[ -e "$PWD/.cursor/mcp.json" ]]; then
    echo "workspace-tool: not loaded (needs approval)"
  else
    echo "No MCP servers configured (expected in .cursor/mcp.json or ~/.cursor/mcp.json)"
  fi
  exit 0
fi
if [[ "${1:-} ${2:-}" == "mcp disable" ]]; then
  [[ "${3:-}" == workspace-tool ]] || exit 2
  : > "${CURSOR_CONFIG_DIR:?}/workspace-tool.disabled"
  echo "disabled $3" >> "${CURSOR_MCP_CAPTURE:?}"
  exit 0
fi
printf 'config=%s\nargs=%s\n' "${CURSOR_CONFIG_DIR:-}" "$*" > "$CURSOR_CAPTURE"
cat <<'JSONL'
{"type":"result","result":"superseded result"}
{"type":"result","result":"first line\nsecond line\nthird line"}
JSONL
EOF
chmod +x "$TMP/bin/cursor-agent"
printf '%s\n' 'Review this fixture.' > "$TMP/prompt.md"

HOME="$TMP/home" TMPDIR="$TMP" CURSOR_CAPTURE="$TMP/cursor-call" \
  CURSOR_MCP_CAPTURE="$TMP/cursor-mcp-call" PATH="$TMP/bin:$PATH" \
  "$ROOT/llm/skills/cursor-sub-review/scripts/run-review.sh" \
    --workspace "$TMP/workspace" \
    --prompt "$TMP/prompt.md" \
    --model test-model \
    --output-dir "$TMP/output" \
    --config-dir "$TMP/config" \
    --heartbeat-seconds 1 >/dev/null

expected=$'first line\nsecond line\nthird line'
actual="$(cat "$TMP/output/cursor.result.md")"
[[ "$actual" == "$expected" ]] || fail "multiline final result was not preserved"
grep -Fq "config=$TMP/config" "$TMP/cursor-call" \
  || fail "headless Cursor review did not inherit the isolated config"
! grep -Fq -- '--approve-mcps' "$TMP/cursor-call" \
  || fail "headless Cursor review still auto-approves MCP servers"
[[ "$(cat "$TMP/config/mcp.json")" == '{"mcpServers":{}}' ]] \
  || fail "headless Cursor review config was not zero-MCP"
grep -Fxq 'disabled workspace-tool' "$TMP/cursor-mcp-call" \
  || fail "headless Cursor review did not disable its effective workspace MCP"

printf 'collision\n' > "$TMP/config-file"
if HOME="$TMP/home" TMPDIR="$TMP" CURSOR_CAPTURE="$TMP/cursor-collision-call" \
     CURSOR_MCP_CAPTURE="$TMP/cursor-mcp-collision" PATH="$TMP/bin:$PATH" \
     "$ROOT/llm/skills/cursor-sub-review/scripts/run-review.sh" \
       --workspace "$TMP/workspace" --prompt "$TMP/prompt.md" --model test-model \
       --output-dir "$TMP/output-collision" --config-dir "$TMP/config-file" \
       --heartbeat-seconds 1 >/dev/null 2>&1; then
  fail "headless Cursor review accepted an invalid MCP config path"
fi
[ ! -e "$TMP/cursor-collision-call" ] \
  || fail "Cursor started before its isolated MCP config was verified"

cat > "$TMP/bin/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${HERDR_CALLS:?}"
case "$1 $2" in
  "status ") printf 'status: running\n' ;;
  "tab list")
    printf '%s\n' '{"result":{"tabs":[{"tab_id":"t1","label":"cursor-ephemeral:fixture"}]}}'
    ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[{"pane_id":"w1:p4","tab_id":"t1"}]}}'
    ;;
  "agent list")
    printf '%s\n' '{"result":{"agents":[{"name":"cursor-fixture","pane_id":"w1:p4","agent":"cursor","agent_status":"idle"}]}}'
    ;;
  "agent read") printf 'Add a follow-up   ctrl+c to stop\n' ;;
  "pane run") printf '{"result":{}}\n' ;;
  "agent start") printf '{"result":{"type":"agent_started"},"type":"agent_started"}\n' ;;
  "agent prompt"|"agent send-keys") printf '{"result":{}}\n' ;;
  "pane close") printf '{"result":{}}\n' ;;
  "pane read")
    if [[ "$*" == *"--source recent --lines"* ]]; then
      [[ "${HERDR_SCENARIO:-}" != capture-fail ]] || exit 1
      printf 'captured transcript\n'
    elif [[ "${HERDR_SCENARIO:-}" == success ]]; then
      printf 'Run Everything\nctrl+c to stop\n'
      # Exceed a pipe buffer after the early match. The old
      # `herdr pane read | grep -q` check made grep close immediately, gave
      # Herdr SIGPIPE under pipefail, and rejected this healthy pane.
      for _ in $(seq 1 2000); do
        printf 'rendered Cursor screen padding that follows the mode footer\n'
      done
    else
      printf 'Run Everything\nAdd a follow-up\n'
    fi
    ;;
  *) printf '{"result":{}}\n' ;;
esac
EOF
chmod +x "$TMP/bin/herdr"

: > "$TMP/spawn-calls"
HOME="$TMP/home" HERDR_ENV=1 HERDR_SCENARIO=success \
  HERDR_CALLS="$TMP/spawn-calls" CURSOR_MCP_CAPTURE="$TMP/spawn-mcp-calls" \
  PATH="$TMP/bin:$PATH" \
  "$ROOT/llm/skills/cursor-sub-review/scripts/spawn-cursor-pane.sh" \
    --model test-model --pane w1:p1 --cwd "$TMP/workspace" \
    --config-dir "$TMP/spawn-config" --prompt 'review now' --no-wait --keep \
    --start-timeout 1 >/dev/null \
  || fail "verified standalone Cursor prompt did not launch"
grep -Fxq 'disabled workspace-tool' "$TMP/spawn-mcp-calls" \
  || fail "standalone Cursor spawner did not disable effective workspace MCPs"
grep -Fq 'herdr tab create --label "$label" --cwd "$cwd" --no-focus' \
  "$SPAWN_IMPL" \
  || fail "standalone Cursor spawner can still steal focus when creating a tab"

: > "$TMP/prompt-fail-calls"
if HOME="$TMP/home" HERDR_ENV=1 HERDR_SCENARIO=prompt-fail \
     HERDR_CALLS="$TMP/prompt-fail-calls" CURSOR_MCP_CAPTURE="$TMP/prompt-fail-mcp" \
     PATH="$TMP/bin:$PATH" \
     "$ROOT/llm/skills/cursor-sub-review/scripts/spawn-cursor-pane.sh" \
       --model test-model --pane w1:p2 --cwd "$TMP/workspace" \
       --config-dir "$TMP/prompt-fail-config" --prompt 'review now' \
       --no-wait --keep --start-timeout 1 >/dev/null 2>&1; then
  fail "standalone Cursor spawner accepted an unsubmitted prompt"
fi
grep -Fq 'pane close w1:p2' "$TMP/prompt-fail-calls" \
  || fail "failed prompt submission leaked the owned Cursor pane"

: > "$TMP/capture-fail-calls"
if HOME="$TMP/home" HERDR_ENV=1 HERDR_SCENARIO=capture-fail \
     HERDR_CALLS="$TMP/capture-fail-calls" CURSOR_MCP_CAPTURE="$TMP/capture-fail-mcp" \
     PATH="$TMP/bin:$PATH" \
     "$ROOT/llm/skills/cursor-sub-review/scripts/spawn-cursor-pane.sh" \
       --model test-model --pane w1:p3 --cwd "$TMP/workspace" \
       --config-dir "$TMP/capture-fail-config" --prompt 'review now' \
       --no-prompt-check --start-timeout 1 --wait-timeout 5 \
       --result-file "$TMP/empty-capture.md" >/dev/null 2>&1; then
  fail "standalone Cursor spawner closed after an empty transcript capture"
fi
! grep -Fq 'pane close w1:p3' "$TMP/capture-fail-calls" \
  || fail "empty transcript capture closed the only evidence pane"

: > "$TMP/sweep-calls"
if HOME="$TMP/home" HERDR_ENV=1 HERDR_SCENARIO=sweep \
     HERDR_CALLS="$TMP/sweep-calls" PATH="$TMP/bin:$PATH" \
     "$ROOT/llm/skills/cursor-sub-review/scripts/spawn-cursor-pane.sh" \
       --sweep >/dev/null 2>&1; then
  fail "Cursor sweep treated idle-but-composing as settled"
fi
! grep -Fq 'pane close w1:p4' "$TMP/sweep-calls" \
  || fail "Cursor sweep closed an idle-but-composing pane"

echo "cursor sub-review regression passed"
