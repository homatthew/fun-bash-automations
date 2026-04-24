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

# ═══════════════════════════════════════════════════════════════════
# COUPLING: these constants pair with the forked extension at
#   https://github.com/homatthew/vscode-terminal-osc-notifier
# If you change any of them, change the corresponding value in that
# repo too. See llm/hooks/README.md for the full dependency picture.
# ═══════════════════════════════════════════════════════════════════
OSC_EXT_PUBLISHER="homatthew"
OSC_EXT_NAME="vscode-terminal-osc-notifier"
OSC_EXT_URI_PATH="/focus"
OSC_NOTIFY_FORMAT="777;notify;tid=%s;%s;%s"

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
  # Strip markdown so macOS banners render as plain prose. Collapse
  # newlines first: sed's `[^`]*` doesn't cross line boundaries, so
  # multi-line ``` fences slip through unless we join them up front.
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

notify_editor_scheme() {
  printf '%s' "${NOTIFY_EDITOR_SCHEME:-vscode}"
}

# Stable per-agent-session so the extension rebinds to the same key
# across multiple Stop/Notification events from one session. Claude
# provides SESSION_ID; fall back to pid+time when absent.
make_stable_tid() {
  if [ -n "${SESSION_ID:-}" ]; then
    printf 'fba-%s' "$SESSION_ID"
  else
    printf 'fba-%s-%s' "$$" "$(date +%s)"
  fi
}

NOTIFY_LOG="${NOTIFY_LOG:-/tmp/fba-notify.log}"

nlog() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "$NOTIFY_LOG" 2>/dev/null || true
}

pick_backend() {
  [ "${NOTIFY_SUPPRESS:-0}" = "1" ] && { printf 'suppressed'; return; }
  if [ "${TERM_PROGRAM:-}" = "ghostty" ]; then
    local front
    front=$(osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true' 2>/dev/null || true)
    [ "$front" = "com.mitchellh.ghostty" ] && { printf 'suppressed'; return; }
  fi
  [ "${TERM_PROGRAM:-}" = "vscode" ] && { printf 'vscode'; return; }
  command -v alerter           >/dev/null 2>&1 && { printf 'alerter'; return; }
  command -v terminal-notifier >/dev/null 2>&1 && { printf 'terminal_notifier'; return; }
  printf 'suppressed'
}

backend_alerter() {
  local title="$1" subtitle="$2" message="$3" group="$4" sender="$5" open_url="$6"
  nlog "alerter invoke: title=$title subtitle=$subtitle sender=${sender:-<none>} open=${open_url:-<none>}"
  (
    resp=$(alerter --title "$title" --subtitle "$subtitle" --message "$message" \
      --sound Pop --timeout 60 --ignore-dnd \
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
      if [[ "$open_url" == *"&cwd="* ]] && command -v code >/dev/null 2>&1; then
        _cwd=$(printf '%s' "$open_url" | sed 's/.*&cwd=//' | python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read().strip()))" 2>/dev/null)
        [ -n "$_cwd" ] && ( code "$_cwd" >/dev/null 2>&1; open "$open_url" >/dev/null 2>&1 ) &
      fi
    fi
  ) &
}

backend_terminal_notifier() {
  local title="$1" subtitle="$2" message="$3" group="$4" sender="$5" open_url="$6"
  local args=(-title "$title" -subtitle "$subtitle" -message "$message"
              -sound Pop -group "$group" -timeout 10 -ignoreDnD)
  [ -n "$sender" ]   && args+=(-sender "$sender")
  [ -n "$open_url" ] && args+=(-open "$open_url")
  terminal-notifier "${args[@]}" >/dev/null 2>&1 &
}

# VS Code integrated terminal: emit an OSC 777 carrying a stable tid
# so the forked extension binds our tid to this terminal, THEN fire
# alerter with a URL that hits the extension's URI handler. Extension's
# own UI is silenced via settings (see bin/install-osc-notifier).
write_ancestor_pids() {
  # Walk up the process tree from PPID and write ancestor PIDs to a temp file
  # so the VS Code extension can match terminal.processId against them.
  local _pid=$PPID _ppid _pids=""
  for _ in 1 2 3 4 5; do
    _ppid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')
    [ -z "$_ppid" ] || [ "$_ppid" = "1" ] && break
    _pids="$_pids$_ppid "
    _pid=$_ppid
  done
  printf '%s' "$_pids" > /tmp/fba-ancestor-pids 2>/dev/null || true
  nlog "vscode: ancestor_pids=$_pids"
}

backend_vscode() {
  local title="$1" subtitle="$2" message="$3" group="$4" sender="$5"
  local tid
  tid=$(make_stable_tid)
  write_ancestor_pids
  local osc_title osc_body
  osc_title=$(printf '%s' "$subtitle" | tr ';\a\r\n' '    ')
  osc_body=$(printf '%s'  "$message"  | tr ';\a\r\n' '    ')
  nlog "vscode: tid=$tid osc_title=$osc_title"
  # shellcheck disable=SC2059
  if printf "\e]$OSC_NOTIFY_FORMAT\a\a" "$tid" "$osc_title" "$osc_body" > /dev/tty 2>/dev/null; then
    nlog "vscode: OSC write ok"
  else
    nlog "vscode: OSC write failed (no tty?)"
  fi
  local open_url="vscode://${OSC_EXT_PUBLISHER}.${OSC_EXT_NAME}${OSC_EXT_URI_PATH}?tid=$(url_encode_path "$tid")&cwd=$(url_encode_path "${MAIN_REPO_PATH:-$CWD}")"
  backend_alerter "$title" "$subtitle" "$message" "$group" "$sender" "$open_url"
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

case "$EVENT" in
  Stop)
    MESSAGE="${LAST_ASSISTANT:-}"
    [ -z "$MESSAGE" ] && MESSAGE="$(extract_transcript_message)"
    [ -z "$MESSAGE" ] && MESSAGE="Task complete"
    # Single codex call produces title + plain-text body for the banner.
    # LLM strips markdown more reliably than sed.
    llm_title=""
    llm_body=""
    if command -v codex >/dev/null 2>&1; then
      _tmp=$(mktemp -t notify-brief 2>/dev/null) || _tmp=""
      if [ -n "$_tmp" ]; then
        NOTIFY_SUPPRESS=1 PG_INTERNAL_CODEX=1 codex exec \
          -m gpt-5-nano \
          -c model_reasoning_effort='"low"' \
          --output-last-message "$_tmp" \
          "Given the assistant-turn output below, produce EXACTLY two lines for a macOS notification:

title: <one imperative phrase under 8 words describing the WORK the agent did. NOT metadata like 'Commit abc123', 'PR #N created', 'Done', file paths, or SHA hashes. Prefer verbs: 'fix bug in X', 'add Y', 'refactor Z'>
body: <plain-text summary under 180 chars. STRIP ALL markdown: remove backticks, triple-backtick fences, asterisks (bold/italic), underscores, link brackets, heading hashes, code blocks. Output readable prose only.>

Output ONLY those two lines in that exact format. No preamble, no trailing text.

---
$MESSAGE" </dev/null >/dev/null 2>&1
        llm_title=$(awk -F': *' '/^title:/{sub(/^title: */,""); print; exit}' "$_tmp" 2>/dev/null | cut -c1-60)
        llm_body=$(awk -F': *' '/^body:/{sub(/^body: */,""); print; exit}' "$_tmp" 2>/dev/null | cut -c1-200)
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
    [ -n "$llm_body" ] && MESSAGE="$llm_body"
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
    _tid=$(make_stable_tid)
    _preview_url="vscode://${OSC_EXT_PUBLISHER}.${OSC_EXT_NAME}${OSC_EXT_URI_PATH}?tid=$(url_encode_path "$_tid")"
  fi
  printf 'macos backend=%s title=%s subtitle=%s message=%s group=%s sender=%s open=%s\n' \
    "$_backend" "$REPO" "$SUBTITLE" "$MESSAGE" "$GROUP" "${SENDER_BUNDLE:-<none>}" "${_preview_url:-<none>}" >&2
  cleanup_and_exit
fi

_chosen_backend=$(pick_backend)
nlog "event=$EVENT backend=$_chosen_backend repo=$REPO subtitle=$SUBTITLE"
case "$_chosen_backend" in
  vscode)            backend_vscode            "$REPO" "$SUBTITLE" "$MESSAGE" "$GROUP" "$SENDER_BUNDLE" ;;
  alerter)           backend_alerter           "$REPO" "$SUBTITLE" "$MESSAGE" "$GROUP" "$SENDER_BUNDLE" "$OPEN_URL" ;;
  terminal_notifier) backend_terminal_notifier "$REPO" "$SUBTITLE" "$MESSAGE" "$GROUP" "$SENDER_BUNDLE" "$OPEN_URL" ;;
  suppressed)        nlog "suppressed: no banner sent" ;;
esac

cleanup_and_exit
