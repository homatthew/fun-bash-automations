#!/bin/bash
# Claude/Codex notification hook.
#
# Posts to Slack via chat.postMessage. All
# events sharing the same (repo, branch) context thread under a single parent
# message — only the parent pings @you. Also fires a macOS notification.
# Silently no-ops on missing creds.
#
# Env overrides:
#   NOTIFY_SLACK_DRY_RUN=1   Print payload instead of POSTing
#   NOTIFY_MACOS_DRY_RUN=1   Print mac notif args instead of showing
#   NOTIFY_THREAD_DIR=<dir>  Override thread-anchor directory
#   NOTIFY_SLACK_TOKEN / NOTIFY_SLACK_CHANNEL / NOTIFY_SLACK_USER_ID
#   NOTIFY_SLACK_*_KEYCHAIN_SERVICE and NOTIFY_SLACK_KEYCHAIN_ACCOUNT

set -euo pipefail

INPUT=$(cat)

emit_success() { [ "${RUNTIME:-}" = "codex" ] && printf '{}\n'; return 0; }
cleanup_and_exit() { emit_success; exit 0; }

# Suppress notifications when this session is an internal LLM call made
# by another tool (e.g. pg invoking `codex exec` for the semantic brief
# or intent check). The parent sets NOTIFY_SUPPRESS=1, which propagates
# through the codex child process into its Stop hook environment.
[ "${NOTIFY_SUPPRESS:-0}" = "1" ] && cleanup_and_exit

# ═══════════════════════════════════════════════════════════════════
# COUPLING: these constants pair with the configured OSC notifier extension.
# See llm/hooks/README.md for the full dependency picture.
# ═══════════════════════════════════════════════════════════════════
OSC_EXT_PUBLISHER="${OSC_NOTIFIER_PUBLISHER:-wenbopan}"
OSC_EXT_NAME="${OSC_NOTIFIER_NAME:-vscode-terminal-osc-notifier}"
OSC_EXT_URI_PATH="${OSC_NOTIFIER_URI_PATH:-/focus}"
OSC_NOTIFY_FORMAT="777;notify;tid=%s;%s;%s"

SCRIPT_PATH="$0"
case "$SCRIPT_PATH" in
  *"/.codex/"*) RUNTIME="codex" ;;
  *"/.claude/"*) RUNTIME="claude" ;;
  *)
    RUNTIME="$(printf '%s' "$INPUT" | jq -r 'if has("last_assistant_message") or has("turn_id") then "codex" else "claude" end' 2>/dev/null || echo claude)"
    ;;
esac

eval "$(printf '%s' "$INPUT" | jq -r '
  @sh "EVENT=\(.hook_event_name // "")",
  @sh "TURN_ID=\(.turn_id // "")",
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
case "$EVENT" in Stop|Notification) ;; *) cleanup_and_exit ;; esac

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
BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null || true)

extract_transcript_last() {
  [ -z "${TRANSCRIPT:-}" ] || [ ! -f "${TRANSCRIPT:-}" ] && return 0
  jq -rs '
    [ .[]? | select(.type == "assistant") | .message.content[]?
      | select(.type == "text" and (.text // "") != "") | .text ]
    | last // ""
  ' "$TRANSCRIPT" 2>/dev/null
}

# Markdown → Slack mrkdwn, then truncate. Keep newlines (Slack renders them).
format_body() {
  local text="$1" limit="${2:-400}"
  printf '%s' "$text" \
    | sed -E '
        s/^#{1,6}[[:space:]]+//;
        s/\*\*([^*]+)\*\*/*\1*/g;
        s/__([^_]+)__/*\1*/g;
        s/\[([^]]+)\]\(([^)]+)\)/<\2|\1>/g;
        s/^[[:space:]]*[-*+][[:space:]]+/• /;
      ' \
    | awk -v lim="$limit" '
        { out = out $0 "\n"; if (length(out) > lim) { out = substr(out,1,lim) "…"; exit } }
        END { sub(/\n$/, "", out); print out }
      '
}

# Claude usually concludes a turn with a summary paragraph — use the last
# non-empty paragraph; fall back to the whole message.
extract_summary() {
  local text="$1" limit="${2:-600}"
  [ -z "$text" ] && return 0
  local last
  last=$(printf '%s' "$text" | awk -v RS='' 'NF { last = $0 } END { print last }')
  [ -z "$last" ] && last="$text"
  format_body "$last" "$limit"
}

git_change_summary() {
  [ -z "${CWD:-}" ] && return 0
  git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  local status stat recent out=""
  status=$(git -C "$CWD" status --porcelain 2>/dev/null | head -8)
  stat=$(git -C "$CWD" diff HEAD --shortstat 2>/dev/null | sed 's/^ *//')
  recent=$(git -C "$CWD" log --since='45 minutes ago' --pretty='%h %s' 2>/dev/null | head -3)

  local chunk
  if [ -n "$recent" ]; then
    printf -v chunk '*Recent commits:*\n```\n%s\n```\n' "$recent"
    out+="$chunk"
  fi
  if [ -n "$status" ]; then
    printf -v chunk '*Working tree:*\n```\n%s\n```\n' "$status"
    out+="$chunk"
  fi
  [ -n "$stat" ] && out="${out}_${stat}_"
  printf '%s' "$out"
}

frontmost_bundle_id() {
  osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true' 2>/dev/null
}

# Editor URL scheme. Defaults to vscode. Override with
# NOTIFY_EDITOR_SCHEME=cursor (or any other editor that implements a
# similar file URL handler).
notify_editor_scheme() {
  printf '%s' "${NOTIFY_EDITOR_SCHEME:-vscode}"
}

# URL-encode path segment: keep / : - _ . ~ and alnum, percent-encode the rest.
# Needed because terminal-notifier -open goes through NSURL which is strict.
# Strip markdown markers so notification banners don't show literal
# backticks, asterisks, and link syntax. macOS notifications are plain
# text; we keep the Slack-flavored version separately for the Slack side.
strip_markdown_for_banner() {
  printf '%s' "$1" \
    | sed -E '
        s/```[^`]*```//g;
        s/`([^`]+)`/\1/g;
        s/\*\*([^*]+)\*\*/\1/g;
        s/__([^_]+)__/\1/g;
        s/\[([^]]+)\]\([^)]+\)/\1/g;
        s/^#{1,6}[[:space:]]+//;
        s/^[[:space:]]*[-*+•][[:space:]]+/• /;
      ' \
    | tr -s '\n' ' ' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

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

notify_key() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

notification_session_key() {
  [ -n "${NOTIFY_SESSION_KEY:-}" ] && { printf '%s' "$NOTIFY_SESSION_KEY"; return; }
  [ -n "${SESSION_ID:-}" ] && { printf 'session:%s' "$SESSION_ID"; return; }
  [ -n "${TURN_ID:-}" ] && { printf 'turn:%s' "$TURN_ID"; return; }
  printf '%s:%s' "${TERM_PROGRAM:-terminal}" "$PPID"
}

# Stable per-agent-session so the extension rebinds to the same key
# across multiple Stop/Notification events from one session.
make_stable_tid() {
  if [ -n "${SESSION_ID:-}" ]; then
    printf 'fba-%s' "$SESSION_ID"
  else
    printf 'fba-%s-%s' "$$" "$(date +%s)"
  fi
}

pick_backend() {
  [ "${NOTIFY_SUPPRESS:-0}" = "1" ] && { printf 'suppressed'; return; }
  if [ "${TERM_PROGRAM:-}" = "ghostty" ]; then
    [ "$(frontmost_bundle_id || true)" = "com.mitchellh.ghostty" ] && { printf 'suppressed'; return; }
  fi
  [ "${TERM_PROGRAM:-}" = "vscode" ] && { printf 'vscode'; return; }
  command -v alerter           >/dev/null 2>&1 && { printf 'alerter'; return; }
  command -v terminal-notifier >/dev/null 2>&1 && { printf 'terminal_notifier'; return; }
  printf 'suppressed'
}

backend_alerter() {
  local title="$1" subtitle="$2" message="$3" group="$4" sender="$5" open_url="$6"
  (
    resp=$(alerter --title "$title" --subtitle "$subtitle" --message "$message" \
      --sound Pop --timeout 60 --ignore-dnd \
      ${group:+--group "$group"} \
      ${sender:+--sender "$sender"} --json 2>/dev/null)
    act=$(printf '%s' "$resp" | jq -r '.activationType // ""' 2>/dev/null)
    if [ "$act" = "contentsClicked" ] && [ -n "$open_url" ]; then
      open "$open_url" >/dev/null 2>&1 || true
    fi
  ) >/dev/null 2>&1 &
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
backend_vscode() {
  local title="$1" subtitle="$2" message="$3" group="$4" sender="$5"
  local tid
  tid=$(make_stable_tid)
  local osc_title osc_body
  osc_title=$(printf '%s' "$subtitle" | tr ';\a\r\n' '    ')
  osc_body=$(printf '%s'  "$message"  | tr ';\a\r\n' '    ')
  # shellcheck disable=SC2059
  printf "\e]$OSC_NOTIFY_FORMAT\a" "$tid" "$osc_title" "$osc_body" > /dev/tty 2>/dev/null || true
  local open_url="vscode://${OSC_EXT_PUBLISHER}.${OSC_EXT_NAME}${OSC_EXT_URI_PATH}?tid=$(url_encode_path "$tid")"
  backend_alerter "$title" "$subtitle" "$message" "$group" "$sender" "$open_url"
}

send_macos_notification() {
  local title="$1" subtitle="$2" message="$3" group="$4" sender="$5"
  [ "$(uname -s)" = "Darwin" ] || return 0

  local one_line
  one_line=$(strip_markdown_for_banner "$message" | cut -c1-200)
  local open_url=""
  [ -n "${MAIN_REPO_PATH:-}" ] && \
    open_url="$(notify_editor_scheme)://file$(url_encode_path "$MAIN_REPO_PATH")"

  local backend preview_url
  backend=$(pick_backend)
  preview_url="$open_url"
  if [ "$backend" = "vscode" ]; then
    local _tid
    _tid=$(make_stable_tid)
    preview_url="vscode://${OSC_EXT_PUBLISHER}.${OSC_EXT_NAME}${OSC_EXT_URI_PATH}?tid=$(url_encode_path "$_tid")"
  fi

  if [ "${NOTIFY_MACOS_DRY_RUN:-0}" = "1" ]; then
    printf 'macos backend=%s title=%s subtitle=%s message=%s group=%s open=%s\n' \
      "$backend" "$title" "$subtitle" "$one_line" "$group" "${preview_url:-<none>}" >&2
    return 0
  fi

  case "$backend" in
    vscode)            backend_vscode            "$title" "$subtitle" "$one_line" "$group" "$sender" ;;
    alerter)           backend_alerter           "$title" "$subtitle" "$one_line" "$group" "$sender" "$open_url" ;;
    terminal_notifier) backend_terminal_notifier "$title" "$subtitle" "$one_line" "$group" "$sender" "$open_url" ;;
    suppressed)        : ;;
  esac
}

# Build message parts
case "$EVENT" in
  Stop)
    ICON=":white_check_mark:"
    COLOR="#2eb886"
    RAW="${LAST_ASSISTANT:-}"
    [ -z "$RAW" ] && RAW="$(extract_transcript_last || true)"
    [ -z "$RAW" ] && RAW="Task complete"
    SUMMARY="$(extract_summary "$RAW" 800)"
    # Single codex call produces BOTH a short title and a plain-text
    # body for the banner. LLM strips markdown properly (code fences,
    # backticks, asterisks, nested bullets) in ways sed can't match.
    # Output shape:
    #   title: <imperative phrase under 8 words>
    #   body:  <plain-text summary, <=180 chars, no markdown>
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
$SUMMARY" </dev/null >/dev/null 2>&1
        llm_title=$(awk -F': *' '/^title:/{sub(/^title: */,""); print; exit}' "$_tmp" 2>/dev/null | cut -c1-60)
        llm_body=$(awk -F': *' '/^body:/{sub(/^body: */,""); print; exit}' "$_tmp" 2>/dev/null | cut -c1-200)
        rm -f "$_tmp"
      fi
    fi
    if [ -z "$llm_title" ]; then
      llm_title=$(printf '%s\n' "$SUMMARY" \
        | sed -E 's/^[[:space:]]*[•\-\*]?[[:space:]]*//' \
        | awk 'NF{print; exit}' \
        | cut -c1-60)
      [ -z "$llm_title" ] && llm_title="done"
    fi
    # Use LLM-cleaned body when available; it strips markdown more
    # reliably than our sed pass.
    if [ -n "$llm_body" ]; then
      SUMMARY="$llm_body"
    fi
    if [ -n "${BRANCH:-}" ]; then
      SUBTITLE="${BRANCH} · ${llm_title}"
    else
      SUBTITLE="$llm_title"
    fi
    ;;
  Notification)
    ICON=":warning:"
    COLOR="#daa038"
    RAW="${NOTIF_MSG:-Awaiting input}"
    # Prefer the actual message for header; fall back to title, then generic
    if [ -n "${NOTIF_TITLE:-}" ] && [ "$NOTIF_TITLE" != "Claude Code" ]; then
      SUBTITLE="$NOTIF_TITLE"
    else
      SUBTITLE="Awaiting input"
    fi
    SUMMARY="$(format_body "$RAW" 400)"
    ;;
esac

ahead_behind_marker() {
  [ -z "${CWD:-}" ] && return 0
  git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  local base counts behind ahead
  if   git -C "$CWD" rev-parse --abbrev-ref '@{upstream}' >/dev/null 2>&1; then
    base='@{upstream}'
  elif git -C "$CWD" rev-parse --verify origin/main   >/dev/null 2>&1; then
    base='origin/main'
  elif git -C "$CWD" rev-parse --verify origin/master >/dev/null 2>&1; then
    base='origin/master'
  else
    return 0
  fi

  counts=$(git -C "$CWD" rev-list --left-right --count "$base...HEAD" 2>/dev/null) || return 0
  behind=${counts%%$'\t'*}
  ahead=${counts##*$'\t'}

  local out=""
  [ "$ahead"  -gt 0 ] 2>/dev/null && out="${out}↑${ahead}"
  [ "$behind" -gt 0 ] 2>/dev/null && out="${out}↓${behind}"
  [ -n "$out" ] && printf '`%s`' "$out"
  return 0
}

HEADER="$ICON  *$REPO*"
[ -n "$BRANCH" ] && HEADER="$HEADER  \`$BRANCH\`"
AB="$(ahead_behind_marker)"
[ -n "$AB" ] && HEADER="$HEADER  $AB"
HEADER="$HEADER  —  $SUBTITLE"

CHANGES="$(git_change_summary)"

# Derive a web URL for the current branch (GitHub or Bitbucket/Stash style)
branch_web_url() {
  [ -z "${CWD:-}" ] || [ -z "${BRANCH:-}" ] && return 0
  local url host path
  url=$(git -C "$CWD" config --get remote.origin.url 2>/dev/null || true)
  [ -z "$url" ] && return 0
  case "$url" in
    git@*:*) host="${url#git@}"; host="${host%%:*}"; path="${url#*:}" ;;
    https://*) host="${url#https://}"; host="${host%%/*}"; path="${url#https://*/}" ;;
    ssh://git@*) url="${url#ssh://git@}"; host="${url%%/*}"; path="${url#*/}" ;;
    *) return 0 ;;
  esac
  path="${path%.git}"
  case "$host" in
    *github*) printf 'https://%s/%s/tree/%s' "$host" "$path" "$BRANCH" ;;
    *stash*|*bitbucket*) printf 'https://%s/projects/%s/browse?at=refs/heads/%s' \
      "$host" "$(printf '%s' "$path" | sed 's|/|/repos/|')" "$BRANCH" ;;
  esac
}

BRANCH_URL="$(branch_web_url)"
CWD_DISPLAY="$(printf '%s' "$CWD" | sed "s|^$HOME|~|")"
FOOTER="\`$CWD_DISPLAY\`"
[ -n "${SESSION_ID:-}" ] && FOOTER="$FOOTER · session \`${SESSION_ID:0:8}\`"
[ -n "$BRANCH_URL" ] && FOOTER="$FOOTER · <$BRANCH_URL|branch>"
# VS Code link always points to main repo (not worktree) so it opens the
# canonical tree regardless of where Claude is actually running.
if [ -n "$MAIN_REPO_PATH" ]; then
  FOOTER="$FOOTER · <$(notify_editor_scheme)://file$MAIN_REPO_PATH|VS Code>"
fi

if [ "$RUNTIME" = "codex" ]; then
  MACOS_SENDER="com.googlecode.iterm2"
  MACOS_GROUP="codex-$REPO"
else
  MACOS_SENDER="com.anthropic.claudefordesktop"
  MACOS_GROUP="claude-$REPO"
fi
SESSION_GROUP_KEY="$(notify_key "$(notification_session_key)" | cut -c1-80)"
MACOS_GROUP="$MACOS_GROUP-$SESSION_GROUP_KEY"

send_macos_notification "$REPO" "$SUBTITLE" "$SUMMARY" "$MACOS_GROUP" "$MACOS_SENDER"

TOKEN="${NOTIFY_SLACK_TOKEN:-}"
CHAN="${NOTIFY_SLACK_CHANNEL:-}"
SLACK_USER="${NOTIFY_SLACK_USER_ID:-}"
KEYCHAIN_ACCOUNT="${NOTIFY_SLACK_KEYCHAIN_ACCOUNT:-${USER:-$(id -un)}}"
if command -v security >/dev/null 2>&1; then
  if [ -z "$TOKEN" ] && [ -n "${NOTIFY_SLACK_TOKEN_KEYCHAIN_SERVICE:-}" ]; then
    TOKEN=$(security find-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$NOTIFY_SLACK_TOKEN_KEYCHAIN_SERVICE" -w 2>/dev/null || true)
  fi
  if [ -z "$CHAN" ] && [ -n "${NOTIFY_SLACK_CHANNEL_KEYCHAIN_SERVICE:-}" ]; then
    CHAN=$(security find-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$NOTIFY_SLACK_CHANNEL_KEYCHAIN_SERVICE" -w 2>/dev/null || true)
  fi
  if [ -z "$SLACK_USER" ] && [ -n "${NOTIFY_SLACK_USER_KEYCHAIN_SERVICE:-}" ]; then
    SLACK_USER=$(security find-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$NOTIFY_SLACK_USER_KEYCHAIN_SERVICE" -w 2>/dev/null || true)
  fi
fi
[ -z "$TOKEN" ] && cleanup_and_exit
[ -z "$CHAN" ] && cleanup_and_exit

# Thread anchor keyed on (repo, branch) — resumed sessions, compactions, and
# concurrent sessions on the same branch all post under one thread.
THREAD_DIR="${NOTIFY_THREAD_DIR:-/tmp/claude-slack-threads}"
mkdir -p "$THREAD_DIR" 2>/dev/null || true

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
THREAD_TS=""
[ -r "$THREAD_FILE" ] && THREAD_TS="$(cat "$THREAD_FILE" 2>/dev/null || true)"

# Mention only on the parent post so replies don't re-ping.
if [ -z "$THREAD_TS" ] && [ -n "$SLACK_USER" ]; then
  SUMMARY="<@$SLACK_USER> $SUMMARY"
fi

PAYLOAD=$(jq -n \
  --arg channel "$CHAN" \
  --arg header "$HEADER" \
  --arg summary "$SUMMARY" \
  --arg changes "$CHANGES" \
  --arg footer "$FOOTER" \
  --arg thread_ts "$THREAD_TS" \
  '
  def blocks:
    [
      { type: "section", text: { type: "mrkdwn", text: $header } },
      { type: "section", text: { type: "mrkdwn", text: $summary } }
    ]
    + (if $changes != "" then [
        { type: "divider" },
        { type: "section", text: { type: "mrkdwn", text: $changes } }
      ] else [] end)
    + [
        { type: "context", elements: [ { type: "mrkdwn", text: $footer } ] }
      ];
  {
    channel: $channel,
    text: $header,
    blocks: blocks,
    unfurl_links: false,
    unfurl_media: false
  } + (if $thread_ts != "" then { thread_ts: $thread_ts } else {} end)')

if [ "${NOTIFY_SLACK_DRY_RUN:-0}" = "1" ]; then
  if [ "$RUNTIME" = "codex" ]; then
    printf '%s\n' "$PAYLOAD" >&2
  else
    printf '%s\n' "$PAYLOAD"
  fi
  cleanup_and_exit
fi

RESP=$(curl -sS https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json; charset=utf-8' \
  --data "$PAYLOAD" 2>/dev/null || true)

OK=$(printf '%s' "$RESP" | jq -r '.ok // false' 2>/dev/null)
TS=$(printf '%s' "$RESP" | jq -r '.ts // empty' 2>/dev/null)

# Stash parent ts so subsequent events thread under it
if [ "$OK" = "true" ] && [ -z "$THREAD_TS" ] && [ -n "$TS" ]; then
  printf '%s' "$TS" > "$THREAD_FILE" 2>/dev/null || true
fi

cleanup_and_exit
