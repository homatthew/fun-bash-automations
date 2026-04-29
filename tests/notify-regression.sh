#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/llm/hooks/notify.sh"
TMPDIR="${TMPDIR:-/tmp}"
LOG="$TMPDIR/fba-notify-regression.log"
WORKSPACE="$TMPDIR/fba-notify-regression-workspace"
REPO_NAME="$(basename "$WORKSPACE")"
CODEX_STATE="/tmp/fba-notify-state-codex-$REPO_NAME"
CODEX_SUMMARY="/tmp/fba-notify-summary-codex-$REPO_NAME"
CODEX_CONTEXT="/tmp/fba-notify-context-codex-$REPO_NAME"
CLAUDE_STATE="/tmp/fba-notify-state-claude-$REPO_NAME"
CLAUDE_SUMMARY="/tmp/fba-notify-summary-claude-$REPO_NAME"
CLAUDE_CONTEXT="/tmp/fba-notify-context-claude-$REPO_NAME"
TRANSCRIPT=""

cleanup() {
  rm -rf "$WORKSPACE"
  rm -f "$TRANSCRIPT" "$LOG" \
    "$CODEX_STATE" "$CODEX_SUMMARY" "$CODEX_CONTEXT" \
    "$CLAUDE_STATE" "$CLAUDE_SUMMARY" "$CLAUDE_CONTEXT"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" == *"$needle"* ]] || fail "expected output to contain [$needle], got: $haystack"
}

assert_file_equals() {
  local file="$1" expected="$2" actual
  [[ -f "$file" ]] || fail "expected file to exist: $file"
  actual="$(cat "$file")"
  [[ "$actual" == "$expected" ]] || fail "expected $file to be [$expected], got [$actual]"
}

run_notify() {
  local runtime="$1" payload="$2"
  NOTIFY_RUNTIME="$runtime" \
    NOTIFY_MACOS_DRY_RUN=1 \
    NOTIFY_LOG="$LOG" \
    TERM_PROGRAM=not-vscode \
    bash "$HOOK" <<<"$payload" 2>&1
}

cleanup
mkdir -p "$WORKSPACE"

payload="$(jq -n --arg cwd "$WORKSPACE" '{
  hook_event_name: "UserPromptSubmit",
  turn_id: "notify-running",
  cwd: $cwd,
  prompt: "Review agent notification state semantics"
}')"
out="$(run_notify codex "$payload")"
assert_contains "$out" "state=running"
assert_contains "$out" "title=⏳ $REPO_NAME"
assert_contains "$out" "subtitle=Agent notifications"
assert_contains "$out" "action=Show"
assert_contains "$out" "sound=<none>"
assert_file_equals "$CODEX_STATE" "notify-running"
echo "ok 1 - Codex UserPromptSubmit renders running"

payload="$(jq -n --arg cwd "$WORKSPACE" '{
  hook_event_name: "Stop",
  turn_id: "notify-permission",
  cwd: $cwd,
  last_assistant_message: "Please run `pg` in your terminal and tell me when it is approved."
}')"
out="$(run_notify codex "$payload")"
assert_contains "$out" "state=input"
assert_contains "$out" "title=❓ $REPO_NAME"
assert_contains "$out" "subtitle=Permission · Agent notifications"
assert_contains "$out" "action=Respond"
assert_contains "$out" "sound=Pop"
assert_file_equals "$CODEX_STATE" "input:notify-permission"
echo "ok 2 - Codex permission-shaped Stop renders input"

payload="$(jq -n --arg cwd "$WORKSPACE" '{
  hook_event_name: "Stop",
  turn_id: "notify-choice",
  cwd: $cwd,
  last_assistant_message: "Which option should I use for sticky input notifications?"
}')"
out="$(run_notify codex "$payload")"
assert_contains "$out" "state=input"
assert_contains "$out" "subtitle=Choice needed · Agent notifications"
assert_contains "$out" "action=Respond"
assert_file_equals "$CODEX_STATE" "input:notify-choice"
echo "ok 3 - Codex choice-shaped Stop renders input"

payload="$(jq -n --arg cwd "$WORKSPACE" '{
  hook_event_name: "Stop",
  turn_id: "notify-done",
  cwd: $cwd,
  last_assistant_message: "Updated notification state semantics and verified dry-run coverage."
}')"
out="$(run_notify codex "$payload")"
assert_contains "$out" "state=done"
assert_contains "$out" "title=🏁 $REPO_NAME"
assert_contains "$out" "action=Show"
assert_contains "$out" "sound=Pop"
assert_file_equals "$CODEX_STATE" "final:notify-done"
echo "ok 4 - Codex normal Stop renders done"

payload="$(jq -n --arg cwd "$WORKSPACE" '{
  hook_event_name: "Stop",
  turn_id: "notify-rhetorical-question",
  cwd: $cwd,
  last_assistant_message: "I found why it happened. Does that explain what you saw?"
}')"
out="$(run_notify codex "$payload")"
assert_contains "$out" "state=done"
assert_contains "$out" "title=🏁 $REPO_NAME"
assert_contains "$out" "action=Show"
assert_file_equals "$CODEX_STATE" "final:notify-rhetorical-question"
echo "ok 5 - Codex rhetorical question Stop renders done"

TRANSCRIPT="$(mktemp -t fba-notify-regression-transcript)"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Please confirm the hook deployment."}]}}' > "$TRANSCRIPT"
payload="$(jq -n --arg cwd "$WORKSPACE" --arg transcript "$TRANSCRIPT" '{
  hook_event_name: "Notification",
  session_id: "claude-input",
  cwd: $cwd,
  transcript_path: $transcript,
  title: "Needs input",
  message: "Claude needs your attention"
}')"
out="$(run_notify claude "$payload")"
assert_contains "$out" "state=input"
assert_contains "$out" "title=❓ $REPO_NAME"
assert_contains "$out" "subtitle=Confirm · Needs input"
assert_contains "$out" "message=Please confirm the hook deployment"
assert_contains "$out" "action=Respond"
assert_file_equals "$CLAUDE_STATE" "input:claude-input"
echo "ok 6 - Claude Notification renders input"
