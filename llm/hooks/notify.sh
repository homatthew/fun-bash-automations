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

# Coupled to the forked VS Code extension's package id and URI handler.
# The hook opens vscode://<publisher>.<name>/<path>?cwd=...&pids=...
# after alerter reports a click; the extension resolves the correct window
# by cwd and the correct terminal by PID.
VSCODE_EXT_PUBLISHER="homatthew"
VSCODE_EXT_NAME="vscode-terminal-osc-notifier"
VSCODE_EXT_URI_PATH="/focus"

url_encode_path() {
  python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe="/:~._-"))' "$1"
}

normalize_message() {
  # Strip markdown so macOS banners render as plain prose. Collapse
  # newlines first: sed's `[^`]*` doesn't cross line boundaries, so
  # multi-line ``` fences slip through unless we join them up front.
  # Second argument caps length: banners truncate visually anyway, but
  # alert dialogs can comfortably display ~1000 chars.
  local limit="${2:-300}"
  printf '%s' "$1" \
    | tr '\n\r' '  ' \
    | sed -E '
        s/```[^`]*```/ /g;
        s/```/ /g;
        s/`([^`]+)`/\1/g;
        s/\*\*([^*]+)\*\*/\1/g;
        s/__([^_]+)__/\1/g;
        s/\[([^]]+)\]\([^)]+\)/\1/g;
        s/#{1,6}[[:space:]]+//g;
        s/[[:space:]]+/ /g;
        s/^ //; s/ $//;' \
    | cut -c"1-$limit"
}

extract_transcript_message() {
  if [ -z "${TRANSCRIPT:-}" ] || [ ! -f "${TRANSCRIPT:-}" ]; then
    return 0
  fi

  # Pull the latest assistant content that's user-facing prose:
  # either a `text` block, or an `AskUserQuestion` tool_use whose
  # input.questions[].question carries the actual prompt.
  jq -rs '
    [
      .[]?
      | select(.type == "assistant")
      | .message.content[]?
      | (
          (select(.type == "text" and (.text // "") != "") | .text),
          (select(.type == "tool_use" and .name == "AskUserQuestion")
            | (.input.questions // [])
            | map(.question // "")
            | join(" "))
        )
      | select(. != "")
    ]
    | last // ""
  ' "$TRANSCRIPT" 2>/dev/null
}

notify_editor_scheme() {
  printf '%s' "${NOTIFY_EDITOR_SCHEME:-vscode}"
}

NOTIFY_LOG="${NOTIFY_LOG:-/tmp/fba-notify.log}"

nlog() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "$NOTIFY_LOG" 2>/dev/null || true
}

dispatch_alerter() {
  local title="$1" subtitle="$2" message="$3" group="$4" sender="$5" open_url="$6" style="$7" cwd="$8"
  local dispatcher spec label
  dispatcher="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/notify-dispatch.sh"
  if [ ! -x "$dispatcher" ]; then
    nlog "notify dispatcher missing: $dispatcher"
    return 1
  fi
  spec=$(mktemp -t fba-notify-dispatch 2>/dev/null) || return 1
  jq -n \
    --arg title "$title" \
    --arg subtitle "$subtitle" \
    --arg message "$message" \
    --arg group "$group" \
    --arg sender "$sender" \
    --arg open_url "$open_url" \
    --arg style "$style" \
    --arg cwd "$cwd" \
    --arg log "$NOTIFY_LOG" \
    '{title:$title, subtitle:$subtitle, message:$message, group:$group, sender:$sender, open_url:$open_url, style:$style, cwd:$cwd, log:$log}' \
    > "$spec"
  label="com.matthewho.fba.notify.${RUNTIME:-agent}.$$.$RANDOM"
  if launchctl submit -l "$label" -o /tmp/fba-notify-dispatch.out -e /tmp/fba-notify-dispatch.err -- /bin/bash "$dispatcher" "$spec" >/dev/null 2>&1; then
    nlog "alerter dispatched: label=$label"
    return 0
  fi
  nlog "launchctl dispatch failed; falling back to nohup"
  nohup /bin/bash "$dispatcher" "$spec" >/dev/null 2>&1 &
}

pick_backend() {
  [ "${NOTIFY_SUPPRESS:-0}" = "1" ] && { printf 'suppressed'; return; }
  if [ "${TERM_PROGRAM:-}" = "ghostty" ]; then
    local front
    front=$(osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true' 2>/dev/null || true)
    [ "$front" = "com.mitchellh.ghostty" ] && { printf 'suppressed'; return; }
  fi
  if command -v alerter >/dev/null 2>&1; then
    [ "${TERM_PROGRAM:-}" = "vscode" ] && { printf 'vscode'; return; }
    printf 'alerter'
    return
  fi
  printf 'suppressed'
}

backend_alerter() {
  local title="$1" subtitle="$2" message="$3" group="$4" sender="$5" open_url="$6" style="${7:-banner}"
  # Stop events: short banner (auto-dismisses).
  # Notification events: alert-style with action button — alerter only renders
  # as a persistent alert when --actions is supplied; --timeout 0 means no
  # auto-close so Claude's input prompts don't disappear.
  local extra_args=()
  if [ "$style" = "alert" ]; then
    extra_args+=(--actions "Respond" --timeout 0)
  else
    extra_args+=(--timeout 60)
  fi
  nlog "alerter invoke: title=$title subtitle=$subtitle style=$style msg_len=${#message} sender=${sender:-<none>} open=${open_url:-<none>}"
  if dispatch_alerter "$title" "$subtitle" "$message" "$group" "$sender" "$open_url" "$style" "${MAIN_REPO_PATH:-$CWD}"; then
    return
  fi
  (
    resp=$(alerter --title "$title" --subtitle "$subtitle" --message "$message" \
      --sound Pop --ignore-dnd \
      "${extra_args[@]}" \
      ${sender:+--sender "$sender"} --json 2>&1)
    nlog "alerter response: $resp"
    act=$(printf '%s' "$resp" | jq -r '.activationType // ""' 2>/dev/null)
    nlog "alerter act=$act"
    if [[ "$act" = "contentsClicked" || "$act" = "actionClicked" ]] && [ -n "$open_url" ]; then
      nlog "alerter opening: $open_url"
      # Fire URI immediately (same-window fast path — no delay).
      # Also run `code <cwd>` in background + re-fire for cross-window case.
      # Extension ignores the one whose cwd doesn't match its workspace.
      open "$open_url" >/dev/null 2>&1 || true
      if [[ "$open_url" == *"cwd="* ]] && command -v code >/dev/null 2>&1; then
        _cwd=$(printf '%s' "$open_url" | sed -E 's/.*[?&]cwd=([^&]*).*/\1/' | python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))" 2>/dev/null)
        [ -n "$_cwd" ] && ( code "$_cwd" >/dev/null 2>&1; open "$open_url" >/dev/null 2>&1 ) &
      fi
    fi
  ) &
}

# Walk up the process tree from PPID and return ancestor PIDs as a
# comma-separated list. The VS Code extension matches these against
# terminal.processId to find the exact terminal among many tabs.
ancestor_pids() {
  local _pid=$PPID _ppid _pids=""
  for _ in 1 2 3 4 5; do
    [ -z "$_pid" ] || [ "$_pid" = "1" ] && break
    _pids="${_pids:+$_pids,}$_pid"
    _ppid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
    [ -z "$_ppid" ] || [ "$_ppid" = "1" ] && break
    _pid=$_ppid
  done
  printf '%s' "$_pids"
}

backend_vscode() {
  local title="$1" subtitle="$2" message="$3" group="$4" sender="$5" style="${6:-banner}"
  # Ring the terminal bell so the tab gets a bell icon when not active.
  (printf '\a' > /dev/tty) 2>/dev/null || true
  local pids event_lc
  pids=$(ancestor_pids)
  event_lc=$(printf '%s' "$EVENT" | tr '[:upper:]' '[:lower:]')
  nlog "vscode: event=$event_lc pids=$pids"
  local _label
  _label=$(printf '%s' "$subtitle" | cut -c1-80)
  local open_url="vscode://${VSCODE_EXT_PUBLISHER}.${VSCODE_EXT_NAME}${VSCODE_EXT_URI_PATH}?cwd=$(url_encode_path "${MAIN_REPO_PATH:-$CWD}")&pids=$(url_encode_path "$pids")&event=$event_lc&label=$(url_encode_path "$_label")"
  backend_alerter "$title" "$subtitle" "$message" "$group" "$sender" "$open_url" "$style"
}

SCRIPT_PATH="$0"
if [ -n "${NOTIFY_RUNTIME:-}" ]; then
  RUNTIME="$NOTIFY_RUNTIME"
else
  case "$SCRIPT_PATH" in
    *"/.codex/"*) RUNTIME="codex" ;;
    *"/.claude/"*) RUNTIME="claude" ;;
    *) RUNTIME="$(printf '%s' "$INPUT" | jq -r 'if has("turn_id") then "codex" else "claude" end' 2>/dev/null || echo claude)" ;;
  esac
fi

eval "$(printf '%s' "$INPUT" | jq -r '
  @sh "EVENT=\(.hook_event_name // "")",
  @sh "NOTIF_TYPE=\(.notification_type // "")",
  @sh "STOP_ACTIVE=\(.stop_hook_active // false)",
  @sh "SESSION_ID=\(.session_id // "")",
  @sh "CWD=\(.cwd // "")",
  @sh "TRANSCRIPT=\(.transcript_path // "")",
  @sh "NOTIF_TITLE=\(.title // "")",
  @sh "NOTIF_MSG=\(.message // "")",
  @sh "LAST_ASSISTANT=\(.last_assistant_message // "")"
')"

[ "$NOTIF_TYPE" = "idle_prompt" ] && cleanup_and_exit
[ "$STOP_ACTIVE" = "true" ] && cleanup_and_exit

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

# Current branch in the working directory (worktrees report their own branch).
BRANCH="$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
[ "$BRANCH" = "HEAD" ] && BRANCH=""  # detached HEAD — nothing meaningful to show

case "$EVENT" in
  Stop)
    MESSAGE="${LAST_ASSISTANT:-}"
    [ -z "$MESSAGE" ] && MESSAGE="$(extract_transcript_message)"
    [ -z "$MESSAGE" ] && MESSAGE="Task complete"
    llm_title=$(printf '%s\n' "$MESSAGE" \
      | sed -E 's/^[[:space:]]*[•\-\*]?[[:space:]]*//' \
      | awk 'NF{print; exit}' \
      | cut -c1-60)
    [ -z "$llm_title" ] && llm_title="done"
    if [ -n "${BRANCH:-}" ]; then
      SUBTITLE="${BRANCH} · ${llm_title}"
    else
      SUBTITLE="$llm_title"
    fi
    ;;
  Notification)
    # Claude's payload only carries a generic "needs your attention" string.
    # Pull the last assistant message from the transcript so the banner shows
    # the actual question/context the user has to act on.
    _ctx="$(extract_transcript_message)"
    if [ -n "$_ctx" ]; then
      MESSAGE="$_ctx"
    else
      MESSAGE="${NOTIF_MSG:-Waiting for input}"
    fi
    _label="${NOTIF_TITLE:-Needs input}"
    if [ -n "${BRANCH:-}" ]; then
      SUBTITLE="${BRANCH} · ${_label}"
    else
      SUBTITLE="$_label"
    fi
    ;;
  *) cleanup_and_exit ;;
esac

# Notification events render in alert dialogs which can show a paragraph;
# Stop events render as banners which truncate visually after ~2 lines.
if [ "$EVENT" = "Notification" ]; then
  MESSAGE="$(normalize_message "$MESSAGE" 1000)"
else
  MESSAGE="$(normalize_message "$MESSAGE" 300)"
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

# Fallback click target for non-VSCode backends: open the main repo in
# the editor. backend_vscode ignores this — it builds its own URL.
OPEN_URL=""
if [ -n "${MAIN_REPO_PATH:-}" ]; then
  OPEN_URL="$(notify_editor_scheme)://file$(url_encode_path "$MAIN_REPO_PATH")"
fi

if [ "${NOTIFY_MACOS_DRY_RUN:-0}" = "1" ]; then
  _backend=$(pick_backend)
  _preview_url="$OPEN_URL"
  if [ "$_backend" = "vscode" ]; then
    _preview_url="vscode://${VSCODE_EXT_PUBLISHER}.${VSCODE_EXT_NAME}${VSCODE_EXT_URI_PATH}?cwd=$(url_encode_path "${MAIN_REPO_PATH:-$CWD}")"
  fi
  printf 'macos backend=%s title=%s subtitle=%s message=%s group=%s sender=%s open=%s\n' \
    "$_backend" "$REPO" "$SUBTITLE" "$MESSAGE" "$GROUP" "${SENDER_BUNDLE:-<none>}" "${_preview_url:-<none>}" >&2
  cleanup_and_exit
fi

_chosen_backend=$(pick_backend)
# Notification events block on user input — use persistent alert style so
# they don't auto-dismiss before the user notices.
ALERT_STYLE="banner"
[ "$EVENT" = "Notification" ] && ALERT_STYLE="alert"
nlog "event=$EVENT backend=$_chosen_backend repo=$REPO subtitle=$SUBTITLE style=$ALERT_STYLE"
case "$_chosen_backend" in
  vscode)            backend_vscode            "$REPO" "$SUBTITLE" "$MESSAGE" "$GROUP" "$SENDER_BUNDLE" "$ALERT_STYLE" ;;
  alerter)           backend_alerter           "$REPO" "$SUBTITLE" "$MESSAGE" "$GROUP" "$SENDER_BUNDLE" "$OPEN_URL" "$ALERT_STYLE" ;;
  suppressed)        nlog "suppressed: no banner sent" ;;
esac

cleanup_and_exit
