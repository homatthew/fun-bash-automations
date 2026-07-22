#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$ROOT/llm/hooks/notify.sh"
TMPDIR="${TMPDIR:-/tmp}"
LOG="$TMPDIR/fba-notify-regression.log"
WORKSPACE="$TMPDIR/fba-notify-regression-workspace"
REPO_NAME="$(basename "$WORKSPACE")"
DEFAULT_SESSION="notify-regression"
GUI_SESSION="notify-gui"
CODEX_STATE="/tmp/fba-notify-state-codex-$REPO_NAME-$DEFAULT_SESSION"
CODEX_GUI_STATE="/tmp/fba-notify-state-codex-$REPO_NAME-$GUI_SESSION"
CODEX_SUMMARY="/tmp/fba-notify-summary-codex-$REPO_NAME-$DEFAULT_SESSION"
CODEX_CONTEXT="/tmp/fba-notify-context-codex-$REPO_NAME-$DEFAULT_SESSION"
CLAUDE_STATE="/tmp/fba-notify-state-claude-$REPO_NAME-$DEFAULT_SESSION"
CLAUDE_SUMMARY="/tmp/fba-notify-summary-claude-$REPO_NAME-$DEFAULT_SESSION"
CLAUDE_CONTEXT="/tmp/fba-notify-context-claude-$REPO_NAME-$DEFAULT_SESSION"
TRANSCRIPT=""

cleanup() {
  rm -rf "$WORKSPACE"
  rm -f "$TRANSCRIPT" "$LOG"
  rm -f /tmp/fba-notify-state-codex-"$REPO_NAME"-notify-* \
    /tmp/fba-notify-summary-codex-"$REPO_NAME"-notify-* \
    /tmp/fba-notify-context-codex-"$REPO_NAME"-notify-* \
    /tmp/fba-notify-state-claude-"$REPO_NAME"-notify-* \
    /tmp/fba-notify-summary-claude-"$REPO_NAME"-notify-* \
    /tmp/fba-notify-context-claude-"$REPO_NAME"-notify-*
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

assert_not_contains() {
  local haystack="$1" needle="$2"
  [[ "$haystack" != *"$needle"* ]] || fail "expected output not to contain [$needle], got: $haystack"
}

assert_file_missing() {
  local file="$1"
  [[ ! -e "$file" ]] || fail "expected file to be absent: $file"
}

assert_file_equals() {
  local file="$1" expected="$2" actual
  [[ -f "$file" ]] || fail "expected file to exist: $file"
  actual="$(cat "$file")"
  [[ "$actual" == "$expected" ]] || fail "expected $file to be [$expected], got [$actual]"
}

notification_group() {
  local out="${1:-}"
  [ -n "$out" ] || out="$(cat)"
  printf '%s' "$out" | sed -n -E 's/.* group=([^ ]+) sender=.*/\1/p' | tail -n 1
}

assert_equals() {
  local actual="$1" expected="$2" label="${3:-value}"
  [[ "$actual" == "$expected" ]] || fail "expected $label to be [$expected], got [$actual]"
}

assert_not_equals() {
  local left="$1" right="$2" label="${3:-values}"
  [[ "$left" != "$right" ]] || fail "expected $label to differ, both were [$left]"
}

state_path() {
  local runtime="$1" session="$2"
  printf '/tmp/fba-notify-state-%s-%s-%s' "$runtime" "$REPO_NAME" "$session"
}

run_notify() {
  local runtime="$1" payload="$2"
  NOTIFY_RUNTIME="$runtime" \
    NOTIFY_SESSION_KEY="$DEFAULT_SESSION" \
    NOTIFY_MACOS_DRY_RUN=1 \
    NOTIFY_SUPPRESS_CODEX_GUI=0 \
    NOTIFY_LOG="$LOG" \
    TERM_PROGRAM=vscode \
    bash "$HOOK" <<<"$payload" 2>&1
}

run_notify_term() {
  local runtime="$1" term_program="$2" payload="$3"
  NOTIFY_RUNTIME="$runtime" \
    NOTIFY_SESSION_KEY="$DEFAULT_SESSION" \
    NOTIFY_MACOS_DRY_RUN=1 \
    NOTIFY_ASSUME_TTY=1 \
    NOTIFY_SUPPRESS_CODEX_GUI=0 \
    NOTIFY_LOG="$LOG" \
    TERM_PROGRAM="$term_program" \
    bash "$HOOK" <<<"$payload" 2>&1
}

run_notify_session() {
  local runtime="$1" term_program="$2" session="$3" payload="$4"
  NOTIFY_RUNTIME="$runtime" \
    NOTIFY_SESSION_KEY="$session" \
    NOTIFY_MACOS_DRY_RUN=1 \
    NOTIFY_SUPPRESS_CODEX_GUI=0 \
    NOTIFY_LOG="$LOG" \
    TERM_PROGRAM="$term_program" \
    bash "$HOOK" <<<"$payload" 2>&1
}

run_notify_codex_gui() {
  local payload="$1"
  NOTIFY_RUNTIME=codex \
    NOTIFY_SESSION_KEY="$GUI_SESSION" \
    NOTIFY_MACOS_DRY_RUN=1 \
    NOTIFY_LOG="$LOG" \
    TERM_PROGRAM=ghostty \
    __CFBundleIdentifier=com.openai.codex \
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
codex_running_group="$(notification_group "$out")"
assert_contains "$out" "state=running"
assert_contains "$out" "title=⏳ $REPO_NAME"
assert_contains "$out" "subtitle=Agent notifications"
assert_contains "$out" "action=Show"
assert_contains "$out" "timeout=14400"
assert_contains "$out" "sound=<none>"
assert_equals "$codex_running_group" "codex-$REPO_NAME-$DEFAULT_SESSION" "Codex running macOS group"
assert_file_equals "$CODEX_STATE" "notify-running"
echo "ok 1 - Codex UserPromptSubmit renders running"

payload="$(jq -n --arg cwd "$WORKSPACE" '{
  hook_event_name: "Stop",
  turn_id: "notify-suppressed",
  cwd: $cwd,
  last_assistant_message: "This should not render outside allowlisted terminals."
}')"
out="$(run_notify_session codex not-vscode notify-suppressed "$payload")"
assert_equals "$out" "{}" "non-allowlisted Codex output"
assert_file_missing "$(state_path codex notify-suppressed)"
echo "ok 1a - non-VS Code/Ghostty contexts suppress notifications"

payload="$(jq -n --arg cwd "$WORKSPACE" '{
  hook_event_name: "Stop",
  turn_id: "notify-running",
  cwd: $cwd,
  last_assistant_message: "Finished the same Codex turn."
}')"
out="$(run_notify codex "$payload")"
codex_done_same_turn_group="$(notification_group "$out")"
assert_equals "$codex_done_same_turn_group" "$codex_running_group" "same-turn Codex macOS group"
assert_file_equals "$CODEX_STATE" "final:notify-running"
echo "ok 1b - Codex running and done notifications share one macOS group per turn"

payload="$(jq -n --arg cwd "$WORKSPACE" '{
  hook_event_name: "UserPromptSubmit",
  turn_id: "notify-running-next",
  cwd: $cwd,
  prompt: "Start another task in the same Codex session"
}')"
out="$(run_notify codex "$payload")"
codex_next_running_group="$(notification_group "$out")"
payload="$(jq -n --arg cwd "$WORKSPACE" '{
  hook_event_name: "Stop",
  turn_id: "notify-done-next",
  cwd: $cwd,
  last_assistant_message: "Finished another task in the same Codex session."
}')"
out="$(run_notify codex "$payload")"
codex_next_done_group="$(notification_group "$out")"
assert_equals "$codex_next_running_group" "$codex_running_group" "same-session next running macOS group"
assert_equals "$codex_next_done_group" "$codex_running_group" "same-session cross-turn done macOS group"
assert_file_equals "$CODEX_STATE" "final:notify-done-next"
echo "ok 1c - Codex same-session cross-turn notifications replace the waiting timer"

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

payload="$(jq -n --arg cwd "$WORKSPACE" '{
  hook_event_name: "Stop",
  turn_id: "notify-ghostty",
  cwd: $cwd,
  last_assistant_message: "Finished Ghostty notification routing."
}')"
out="$(run_notify_term codex ghostty "$payload")"
assert_contains "$out" "backend=ghostty"
assert_contains "$out" "state=done"
assert_contains "$out" "open=<ghostty-native>"
assert_file_equals "$CODEX_STATE" "final:notify-ghostty"
echo "ok 6 - Ghostty uses native notification backend"

payload="$(jq -n --arg cwd "$WORKSPACE" '{
  hook_event_name: "UserPromptSubmit",
  turn_id: "notify-gui-ghostty",
  cwd: $cwd,
  prompt: "Fix notification from Codex GUI"
}')"
out="$(run_notify_codex_gui "$payload")"
assert_equals "$out" "{}" "Codex GUI hook output"
assert_not_contains "$out" "backend="
assert_not_contains "$out" "vscode:"
assert_file_missing "$CODEX_GUI_STATE"
echo "ok 6b - Codex GUI invocation suppresses custom hook notification"

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
echo "ok 7 - Claude Notification renders input"

payload="$(jq -n --arg cwd "$WORKSPACE" --arg transcript "$TRANSCRIPT" '{
  hook_event_name: "Notification",
  session_id: "claude-ghostty",
  cwd: $cwd,
  transcript_path: $transcript,
  title: "Needs input",
  message: "Claude needs your attention"
}')"
out="$(run_notify_term claude ghostty "$payload")"
assert_contains "$out" "backend=ghostty"
assert_contains "$out" "state=input"
assert_contains "$out" "open=<ghostty-native>"
assert_file_equals "$CLAUDE_STATE" "input:claude-ghostty"
echo "ok 8 - Claude Ghostty uses native notification backend"

codex_a_state="$(state_path codex notify-codex-a)"
codex_b_state="$(state_path codex notify-codex-b)"
payload="$(jq -n --arg cwd "$WORKSPACE" '{
  hook_event_name: "UserPromptSubmit",
  turn_id: "codex-a-running",
  cwd: $cwd,
  prompt: "Session A should stay isolated"
}')"
codex_a_group="$(run_notify_session codex vscode notify-codex-a "$payload" | notification_group)"
payload="$(jq -n --arg cwd "$WORKSPACE" '{
  hook_event_name: "UserPromptSubmit",
  turn_id: "codex-b-running",
  cwd: $cwd,
  prompt: "Session B should stay isolated"
}')"
codex_b_group="$(run_notify_session codex vscode notify-codex-b "$payload" | notification_group)"
assert_not_equals "$codex_a_group" "$codex_b_group" "Codex macOS groups"
assert_file_equals "$codex_a_state" "codex-a-running"
assert_file_equals "$codex_b_state" "codex-b-running"
payload="$(jq -n --arg cwd "$WORKSPACE" '{
  hook_event_name: "Stop",
  turn_id: "codex-a-done",
  cwd: $cwd,
  last_assistant_message: "Finished session A."
}')"
run_notify_session codex vscode notify-codex-a "$payload" >/dev/null
assert_file_equals "$codex_a_state" "final:codex-a-done"
assert_file_equals "$codex_b_state" "codex-b-running"
echo "ok 9 - Codex sessions keep independent notification state"

claude_a_state="$(state_path claude notify-claude-a)"
claude_b_state="$(state_path claude notify-claude-b)"
payload="$(jq -n --arg cwd "$WORKSPACE" --arg transcript "$TRANSCRIPT" '{
  hook_event_name: "Notification",
  session_id: "claude-a-input",
  cwd: $cwd,
  transcript_path: $transcript,
  title: "Needs input",
  message: "Claude needs your attention"
}')"
claude_a_group="$(run_notify_session claude vscode notify-claude-a "$payload" | notification_group)"
payload="$(jq -n --arg cwd "$WORKSPACE" --arg transcript "$TRANSCRIPT" '{
  hook_event_name: "Notification",
  session_id: "claude-b-input",
  cwd: $cwd,
  transcript_path: $transcript,
  title: "Needs input",
  message: "Claude needs your attention"
}')"
claude_b_group="$(run_notify_session claude vscode notify-claude-b "$payload" | notification_group)"
assert_not_equals "$claude_a_group" "$claude_b_group" "Claude macOS groups"
assert_file_equals "$claude_a_state" "input:claude-a-input"
assert_file_equals "$claude_b_state" "input:claude-b-input"
payload="$(jq -n --arg cwd "$WORKSPACE" '{
  hook_event_name: "Stop",
  session_id: "claude-a-done",
  cwd: $cwd,
  last_assistant_message: "Finished session A."
}')"
run_notify_session claude vscode notify-claude-a "$payload" >/dev/null
assert_file_equals "$claude_a_state" "final:claude-a-done"
assert_file_equals "$claude_b_state" "input:claude-b-input"
echo "ok 10 - Claude sessions keep independent notification state"
