#!/bin/bash
# Claude Code notification hook (Stop + Notification events)

INPUT=$(cat)

# Parse all fields once
eval "$(echo "$INPUT" | jq -r '
  @sh "EVENT=\(.hook_event_name // "")",
  @sh "NOTIF_TYPE=\(.notification_type // "")",
  @sh "STOP_ACTIVE=\(.stop_hook_active // false)",
  @sh "CWD=\(.cwd // "")",
  @sh "TRANSCRIPT=\(.transcript_path // "")",
  @sh "NOTIF_TITLE=\(.title // "")",
  @sh "NOTIF_MSG=\(.message // "")"
')"

# Early exits
[ "$NOTIF_TYPE" = "idle_prompt" ] && exit 0
[ "$STOP_ACTIVE" = "true" ] && exit 0

# Ghostty suppression: skip if already looking at it
if [ "$TERM_PROGRAM" = "ghostty" ]; then
  FRONT=$(osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true' 2>/dev/null)
  [ "$FRONT" = "com.mitchellh.ghostty" ] && exit 0
fi

# Derive repo name — prefer git toplevel (reliable), fall back to cwd
REPO=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null | xargs basename 2>/dev/null)
[ -z "$REPO" ] && REPO=$(basename "$CWD")

case "$EVENT" in
  Stop)
    SUBTITLE="Done"
    # Extract last assistant message via jq (avoids python)
    MESSAGE=$(jq -r '
      select(.type == "assistant")
      | .message.content[]?
      | select(.type == "text" and .text != "")
      | .text
    ' "$TRANSCRIPT" 2>/dev/null | tail -1 | cut -c1-300)
    [ -z "$MESSAGE" ] && MESSAGE="Task complete"
    ;;
  Notification)
    SUBTITLE="${NOTIF_TITLE:-Needs input}"
    MESSAGE="${NOTIF_MSG:-Waiting for input}"
    ;;
  *) exit 0 ;;
esac

# Click-to-activate terminal
case "$TERM_PROGRAM" in
  ghostty) ACTIVATE="com.mitchellh.ghostty" ;;
  vscode)  ACTIVATE="com.microsoft.VSCode" ;;
esac

# macOS notification — Claude.app icon, Pop sound
ARGS=(-title "$REPO" -subtitle "$SUBTITLE" -message "$MESSAGE" -sound Pop -group "claude-$REPO" -sender com.anthropic.claudefordesktop -timeout 10)
[ -n "$ACTIVATE" ] && ARGS+=(-activate "$ACTIVATE")
terminal-notifier "${ARGS[@]}" 2>/dev/null &

exit 0
