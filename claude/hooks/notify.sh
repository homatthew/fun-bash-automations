#!/bin/bash
# Claude/Codex macOS notification hook.

set -euo pipefail

INPUT=$(cat)

emit_success() {
  if [ "${RUNTIME:-}" = "codex" ]; then
    printf '{}\n'
  fi
}

cleanup_and_exit() {
  emit_success
  exit 0
}

normalize_message() {
  printf '%s' "$1" \
    | tr '\n' ' ' \
    | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' \
    | cut -c1-300
}

extract_transcript_message() {
  if [ -z "${TRANSCRIPT:-}" ] || [ ! -f "${TRANSCRIPT:-}" ]; then
    return 0
  fi

  jq -rs '
    [
      .[]?
      | select(.type == "assistant")
      | .message.content[]?
      | select(.type == "text" and (.text // "") != "")
      | .text
    ]
    | last // ""
  ' "$TRANSCRIPT" 2>/dev/null
}

SCRIPT_PATH="$0"
case "$SCRIPT_PATH" in
  *"/.codex/"*) RUNTIME="codex" ;;
  *) RUNTIME="claude" ;;
esac

eval "$(printf '%s' "$INPUT" | jq -r '
  @sh "EVENT=\(.hook_event_name // "")",
  @sh "NOTIF_TYPE=\(.notification_type // "")",
  @sh "STOP_ACTIVE=\(.stop_hook_active // false)",
  @sh "CWD=\(.cwd // "")",
  @sh "TRANSCRIPT=\(.transcript_path // "")",
  @sh "NOTIF_TITLE=\(.title // "")",
  @sh "NOTIF_MSG=\(.message // "")",
  @sh "LAST_ASSISTANT=\(.last_assistant_message // "")"
')"

[ "$NOTIF_TYPE" = "idle_prompt" ] && cleanup_and_exit
[ "$STOP_ACTIVE" = "true" ] && cleanup_and_exit

# Ghostty suppression: skip if already looking at it
if [ "${TERM_PROGRAM:-}" = "ghostty" ]; then
  FRONT=$(osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true' 2>/dev/null)
  [ "$FRONT" = "com.mitchellh.ghostty" ] && cleanup_and_exit
fi

# Derive repo name — prefer git toplevel (reliable), fall back to cwd
REPO=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null | xargs basename 2>/dev/null)
[ -z "$REPO" ] && REPO=$(basename "$CWD")

case "$EVENT" in
  Stop)
    SUBTITLE="Done"
    MESSAGE="${LAST_ASSISTANT:-}"
    [ -z "$MESSAGE" ] && MESSAGE="$(extract_transcript_message)"
    [ -z "$MESSAGE" ] && MESSAGE="Task complete"
    ;;
  Notification)
    SUBTITLE="${NOTIF_TITLE:-Needs input}"
    MESSAGE="${NOTIF_MSG:-Waiting for input}"
    ;;
  *) cleanup_and_exit ;;
esac

MESSAGE="$(normalize_message "$MESSAGE")"

# Click-to-activate terminal
case "${TERM_PROGRAM:-}" in
  ghostty) ACTIVATE="com.mitchellh.ghostty" ;;
  vscode)  ACTIVATE="com.microsoft.VSCode" ;;
  *)       ACTIVATE="" ;;
esac

if [ "$RUNTIME" = "codex" ]; then
  GROUP="codex-$REPO"
  SENDER="com.openai.codex"
else
  GROUP="claude-$REPO"
  SENDER="com.anthropic.claudefordesktop"
fi

if [ "${NOTIFY_MACOS_DRY_RUN:-0}" = "1" ]; then
  printf 'macos title=%s subtitle=%s message=%s group=%s sender=%s activate=%s\n' \
    "$REPO" "$SUBTITLE" "$MESSAGE" "$GROUP" "${SENDER:-<none>}" "${ACTIVATE:-<none>}" >&2
  cleanup_and_exit
fi

ARGS=(-title "$REPO" -subtitle "$SUBTITLE" -message "$MESSAGE" -sound Pop -group "$GROUP" -timeout 10)
[ -n "$SENDER" ] && ARGS+=(-sender "$SENDER")
[ -n "$ACTIVATE" ] && ARGS+=(-activate "$ACTIVATE")
terminal-notifier "${ARGS[@]}" >/dev/null 2>&1 &

cleanup_and_exit
