#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d -t fba-review-fixes-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

settings="$TMP/settings.json"
cat > "$settings" <<'JSONC'
{
  // keep URL text intact while comments are removed
  "docs": "https://example.com/path//segment",
  "pattern": "literal/*value*/tail",
  "escaped": "quote: \" // still text",
  "array": [1, 2,],
}
JSONC
node "$ROOT/bin/update-jsonc-settings" "$settings"
jq -e '
  .docs == "https://example.com/path//segment"
  and .pattern == "literal/*value*/tail"
  and .escaped == "quote: \" // still text"
  and .array == [1, 2]
  and .["terminalNotification.preferOsNotifications"] == false
  and .["terminalNotification.showVsCodeNotification"] == false
' "$settings" >/dev/null || fail "JSONC settings were not patched safely"

secret="sk-proj-$(printf 'a%.0s' {1..32})"
private_cwd="/Users/${USER:-tester}/private"
audit_dir="$TMP/audit"
jq -n --arg secret "$secret" --arg cwd "$private_cwd" '{
  session_id: "private-session",
  turn_id: "private-turn",
  cwd: $cwd,
  tool_name: "Bash",
  tool_input: {command: ("curl -H Authorization:" + $secret)},
  tool_response: "{\"exit_code\":0}"
}' | CODEX_AUDIT_DIR="$audit_dir" bash "$ROOT/llm/hooks/post-tool-audit.sh" >/dev/null

audit_file="$audit_dir/audit.jsonl"
mode="$(stat -f '%Lp' "$audit_file" 2>/dev/null || stat -c '%a' "$audit_file")"
[[ "$mode" == "600" ]] || fail "audit log mode was $mode instead of 600"
jq -e 'keys == ["exit_code", "tool", "ts"] and .tool == "Bash" and .exit_code == 0' "$audit_file" >/dev/null ||
  fail "audit record contains unexpected fields"
if grep -Fq "$secret" "$audit_file" || grep -Fq "$private_cwd" "$audit_file" || grep -Fq "private-session" "$audit_file"; then
  fail "audit record retained sensitive command context"
fi

if rg -n 'com\.matthewho' "$ROOT/bin" "$ROOT/llm" >/dev/null; then
  fail "shared runtime files retain a personal bundle namespace"
fi
grep -Fq 'CLAUDE_NOTIFY_BUNDLE_ID:-dev.fun-bash-automations.claude-notify' "$ROOT/bin/install-claude-notify-app" ||
  fail "Claude notification bundle ID is not parameterized"

grep -Fq 'bash \"$test\" || exit $?' "$ROOT/.no-mistakes.yaml" ||
  fail "no-mistakes regression loop does not fail fast"
jq -e 'has("skipDangerousModePermissionPrompt") | not' "$ROOT/claude/settings.json" >/dev/null ||
  fail "Claude dangerous-mode prompt suppression remains enabled"
if rg -n 'claude-slack-(bot-token|channel|user-id)' "$ROOT/llm/hooks" >/dev/null; then
  fail "Slack hooks retain hardcoded keychain service identifiers"
fi
grep -Fq 'CROSS_REPO_CONTEXT_ALLOWLIST' "$ROOT/claude/agents/cross-repo-context.md" ||
  fail "cross-repo agent lacks an explicit repository allowlist"
if rg -n 'List ~/repos|\.context/repo-insights|git commit -m "second-brain' "$ROOT/claude/agents/cross-repo-context.md" >/dev/null; then
  fail "cross-repo agent still inventories or persists sibling repository data"
fi
grep -Fq "alias gcane='gca --no-edit'" "$ROOT/zsh/personal.zsh" ||
  fail "gcane still hides hook bypass behavior"
if rg -n 'gcane.*no-verify' "$ROOT/QoL.md" "$ROOT/zsh/personal.zsh" >/dev/null; then
  fail "public gcane documentation still exposes a hidden hook bypass"
fi

echo "review fixes regression passed"
