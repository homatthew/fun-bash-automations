#!/bin/bash
# PostToolUse Bash hook — posts push / PR-create / PR-merge events into the
# existing notify-slack thread for the current (repo, branch). Strictly
# additive: never creates a new thread, never pings.
#
# Exits silently on any of:
#   - tool call didn't succeed
#   - command didn't match git push / gh pr create / gh pr merge
#   - no Slack creds, no git context, no existing thread anchor

set -euo pipefail

INPUT=$(cat)

emit_success() { [ "${RUNTIME:-}" = "codex" ] && printf '{}\n'; return 0; }
cleanup_and_exit() { emit_success; exit 0; }

# Suppress when caller is an internal LLM invocation (pg → codex exec).
[ "${NOTIFY_SUPPRESS:-0}" = "1" ] && cleanup_and_exit

SCRIPT_PATH="$0"
case "$SCRIPT_PATH" in
  *"/.codex/"*) RUNTIME="codex" ;;
  *"/.claude/"*) RUNTIME="claude" ;;
  *)
    RUNTIME="$(printf '%s' "$INPUT" | jq -r 'if has("turn_id") then "codex" else "claude" end' 2>/dev/null || echo claude)"
    ;;
esac

eval "$(printf '%s' "$INPUT" | jq -r '
  @sh "EVENT=\(.hook_event_name // "")",
  @sh "TOOL_NAME=\(.tool_name // "")",
  @sh "SESSION_ID=\(.session_id // "")",
  @sh "CWD=\(.cwd // "")",
  @sh "CMD=\(.tool_input.command // "")",
  @sh "FAILED=\(if (.tool_response | type) == "object" and ((.tool_response.success == false) or (.tool_response.ok == false)) then "1" else "0" end)"
')"

[ "$TOOL_NAME" = "Bash" ] || cleanup_and_exit
[ -n "$CMD" ] || cleanup_and_exit
[ "$FAILED" = "0" ] || cleanup_and_exit

# Resolve main repo even when CWD is a worktree.
resolve_main_repo() {
  local common_dir main_git_dir
  common_dir=$(git -C "$CWD" rev-parse --git-common-dir 2>/dev/null) || return 0
  case "$common_dir" in
    /*) main_git_dir="$common_dir" ;;
    *) main_git_dir="$CWD/$common_dir" ;;
  esac
  (cd "$(dirname "$main_git_dir")" 2>/dev/null && pwd)
}

MAIN_REPO_PATH="$(resolve_main_repo)"
if [ -n "$MAIN_REPO_PATH" ]; then
  REPO="$(basename "$MAIN_REPO_PATH")"
else
  REPO="$(basename "${CWD:-}")"
fi
BRANCH=$(git -C "${CWD:-.}" branch --show-current 2>/dev/null || true)
[ -n "$REPO" ] || cleanup_and_exit
[ -n "$BRANCH" ] || cleanup_and_exit

# Match dispatch. First successful match wins.
EVENT_KIND=""
case "$CMD" in
  *"git push"*)       EVENT_KIND="push" ;;
  *"gh pr create"*)   EVENT_KIND="pr_create" ;;
  *"gh pr merge"*)    EVENT_KIND="pr_merge" ;;
esac
[ -n "$EVENT_KIND" ] || cleanup_and_exit

# PR lookup: 2 s timeout. Returns `<url|#N title>` or empty.
pr_lookup() {
  command -v gh >/dev/null 2>&1 || return 0
  ( cd "$CWD" 2>/dev/null || return 0
    timeout 2 gh pr list --head "$BRANCH" --json url,number,title --limit 1 \
      -q '.[0] | select(. != null) | "<\(.url)|#\(.number) \(.title)>"' 2>/dev/null
  )
}

pr_lookup_merged() {
  command -v gh >/dev/null 2>&1 || return 0
  ( cd "$CWD" 2>/dev/null || return 0
    timeout 2 gh pr view --json url,number,title,state \
      -q 'select(.state == "MERGED") | "<\(.url)|#\(.number) \(.title)>"' 2>/dev/null
  )
}

# VS Code deep-link to the main repo path (not worktree). Clicking in Slack
# opens the canonical tree in VS Code.
VSCODE_LINK=""
if [ -n "$MAIN_REPO_PATH" ]; then
  VSCODE_LINK="<vscode://file$MAIN_REPO_PATH|VS Code>"
fi

case "$EVENT_KIND" in
  push)
    PR_LINK="$(pr_lookup || true)"
    MSG="🚀 *pushed* \`$BRANCH\`"
    [ -n "$PR_LINK" ]    && MSG="$MSG · $PR_LINK"
    [ -n "$VSCODE_LINK" ] && MSG="$MSG · $VSCODE_LINK"
    ;;
  pr_create)
    sleep 1
    PR_LINK="$(pr_lookup || true)"
    [ -n "$PR_LINK" ] || cleanup_and_exit
    MSG="📬 *opened PR* $PR_LINK"
    case "$CMD" in *"--draft"*) MSG="$MSG _(draft)_" ;; esac
    [ -n "$VSCODE_LINK" ] && MSG="$MSG · $VSCODE_LINK"
    ;;
  pr_merge)
    PR_LINK="$(pr_lookup_merged || true)"
    [ -n "$PR_LINK" ] || cleanup_and_exit
    MSG="✅ *merged PR* $PR_LINK"
    [ -n "$VSCODE_LINK" ] && MSG="$MSG · $VSCODE_LINK"
    ;;
esac

TOKEN=""; CHAN=""
if command -v security >/dev/null 2>&1; then
  TOKEN=$(security find-generic-password -a "${USER:-$(id -un)}" -s claude-slack-bot-token -w 2>/dev/null || true)
  CHAN=$(security find-generic-password -a "${USER:-$(id -un)}" -s claude-slack-channel -w 2>/dev/null || true)
fi
[ -n "$TOKEN" ] || cleanup_and_exit
[ -n "$CHAN" ] || cleanup_and_exit

# Thread anchor — same convention as notify-slack.sh. No anchor = no post.
THREAD_DIR="${NOTIFY_THREAD_DIR:-/tmp/claude-slack-threads}"
context_key() {
  if [ -n "${REPO:-}" ]; then
    local key="$REPO"
    [ -n "${BRANCH:-}" ] && key="${key}__${BRANCH}"
    printf '%s' "$key" | tr '/ ' '__'
    return
  fi
  printf '%s' "${SESSION_ID:-unknown}"
}
THREAD_KEY="$(context_key)"
THREAD_FILE="$THREAD_DIR/$THREAD_KEY"
[ -r "$THREAD_FILE" ] || cleanup_and_exit
THREAD_TS="$(cat "$THREAD_FILE" 2>/dev/null || true)"
[ -n "$THREAD_TS" ] || cleanup_and_exit

PAYLOAD=$(jq -n \
  --arg channel "$CHAN" \
  --arg text "$MSG" \
  --arg thread_ts "$THREAD_TS" \
  '{
    channel: $channel,
    text: $text,
    blocks: [ { type: "section", text: { type: "mrkdwn", text: $text } } ],
    thread_ts: $thread_ts,
    unfurl_links: false,
    unfurl_media: false
  }')

if [ "${NOTIFY_SLACK_DRY_RUN:-0}" = "1" ]; then
  if [ "$RUNTIME" = "codex" ]; then
    printf '%s\n' "$PAYLOAD" >&2
  else
    printf '%s\n' "$PAYLOAD"
  fi
  cleanup_and_exit
fi

curl -sS https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json; charset=utf-8' \
  --data "$PAYLOAD" >/dev/null 2>&1 || true

cleanup_and_exit
