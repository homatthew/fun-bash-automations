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

# Suppress when the caller is an internal LLM invocation (e.g. pg
# running `codex exec` for its semantic brief/intent check). Parent
# sets NOTIFY_SUPPRESS=1 which propagates through into this hook.
[ "${NOTIFY_SUPPRESS:-0}" = "1" ] && cleanup_and_exit

url_encode_path() {
  local s="$1" out="" c i
  for ((i=0; i<${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9._~/:-]) out+="$c" ;;
      *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
    esac
  done
  printf '%s' "$out"
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

# Resolve the main repo path even when CWD is a worktree. Worktrees report
# their own path via --show-toplevel but share the main repo's .git common-dir,
# so dirname(common-dir) gets us back to the main repo root.
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
  REPO="$(basename "$CWD")"
fi

case "$EVENT" in
  Stop)
    MESSAGE="${LAST_ASSISTANT:-}"
    [ -z "$MESSAGE" ] && MESSAGE="$(extract_transcript_message)"
    [ -z "$MESSAGE" ] && MESSAGE="Task complete"
    # Subtitle: "<branch> · <LLM one-line title>". LLM falls back to
    # first-line heuristic if codex unavailable.
    llm_title=""
    if command -v codex >/dev/null 2>&1; then
      _tmp=$(mktemp -t notify-title 2>/dev/null) || _tmp=""
      if [ -n "$_tmp" ]; then
        NOTIFY_SUPPRESS=1 PG_INTERNAL_CODEX=1 codex exec \
          -m gpt-5-nano \
          -c model_reasoning_effort='"low"' \
          --output-last-message "$_tmp" \
          "Summarize this assistant-turn output into ONE imperative phrase under 8 words. No period, no trailing punctuation. Output only the phrase:

$MESSAGE" </dev/null >/dev/null 2>&1
        llm_title=$(awk 'NF{print; exit}' "$_tmp" 2>/dev/null | cut -c1-60)
        rm -f "$_tmp"
      fi
    fi
    if [ -z "$llm_title" ]; then
      llm_title=$(printf '%s\n' "$MESSAGE" \
        | sed -E 's/^[[:space:]]*[•\-\*]?[[:space:]]*//' \
        | awk 'NF{print; exit}' \
        | cut -c1-60)
      [ -z "$llm_title" ] && llm_title="done"
    fi
    if [ -n "${BRANCH:-}" ]; then
      SUBTITLE="${BRANCH} · ${llm_title}"
    else
      SUBTITLE="$llm_title"
    fi
    ;;
  Notification)
    SUBTITLE="${NOTIF_TITLE:-Needs input}"
    MESSAGE="${NOTIF_MSG:-Waiting for input}"
    ;;
  *) cleanup_and_exit ;;
esac

MESSAGE="$(normalize_message "$MESSAGE")"

# Click behavior: always open the canonical repo in VS Code when we have
# one; fall back to activating the current terminal if not.
OPEN_URL=""
ACTIVATE=""
if [ -n "${MAIN_REPO_PATH:-}" ]; then
  OPEN_URL="vscode://file$(url_encode_path "$MAIN_REPO_PATH")"
else
  case "${TERM_PROGRAM:-}" in
    ghostty) ACTIVATE="com.mitchellh.ghostty" ;;
    vscode)  ACTIVATE="com.microsoft.VSCode" ;;
  esac
fi

if [ "$RUNTIME" = "codex" ]; then
  GROUP="codex-$REPO"
  SENDER_BUNDLE="com.openai.codex"
else
  GROUP="claude-$REPO"
  # com.anthropic.claudefordesktop -sender hangs terminal-notifier on this
  # machine (Claude.app notification endpoint is broken). Use the placeholder
  # Claude Notify.app bundle (~/Applications/Claude Notify.app) which carries
  # Claude's icon but a clean bundle-id.
  SENDER_BUNDLE="com.matthewho.claudenotify"
fi
SENDER="$SENDER_BUNDLE"

if [ "${NOTIFY_MACOS_DRY_RUN:-0}" = "1" ]; then
  printf 'macos title=%s subtitle=%s message=%s group=%s sender=%s activate=%s open=%s\n' \
    "$REPO" "$SUBTITLE" "$MESSAGE" "$GROUP" "${SENDER:-<none>}" "${ACTIVATE:-<none>}" "${OPEN_URL:-<none>}" >&2
  cleanup_and_exit
fi

if command -v alerter >/dev/null 2>&1; then
  (
    resp=$(alerter --title "$REPO" --subtitle "$SUBTITLE" --message "$MESSAGE" \
      --sound Pop --timeout 60 --ignore-dnd \
      ${SENDER:+--sender "$SENDER"} --json 2>/dev/null)
    act=$(printf '%s' "$resp" | jq -r '.activationType // ""' 2>/dev/null)
    if [ "$act" = "contentsClicked" ] && [ -n "$OPEN_URL" ]; then
      open "$OPEN_URL" >/dev/null 2>&1 || true
    fi
  ) >/dev/null 2>&1 &
else
  ARGS=(-title "$REPO" -subtitle "$SUBTITLE" -message "$MESSAGE" -sound Pop -group "$GROUP" -timeout 10 -ignoreDnD)
  [ -n "$SENDER" ] && ARGS+=(-sender "$SENDER")
  if [ -n "$OPEN_URL" ]; then
    ARGS+=(-open "$OPEN_URL")
  elif [ -n "$ACTIVATE" ]; then
    ARGS+=(-activate "$ACTIVATE")
  fi
  terminal-notifier "${ARGS[@]}" >/dev/null 2>&1 &
fi

cleanup_and_exit
