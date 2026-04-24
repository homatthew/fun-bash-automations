#!/bin/bash
# Claude/Codex notification hook.
#
# Posts to Slack via chat.postMessage (bot token from macOS Keychain). All
# events sharing the same (repo, branch) context thread under a single parent
# message — only the parent pings @you. Also fires a macOS notification.
# Silently no-ops on missing creds.
#
# Keychain items (account = $USER):
#   claude-slack-bot-token   xoxb-... (required for Slack)
#   claude-slack-channel     C... channel ID (required for Slack)
#   claude-slack-user-id     U... pinged on the parent message (optional)
#
# Env overrides:
#   NOTIFY_SLACK_DRY_RUN=1   Print payload instead of POSTing
#   NOTIFY_MACOS_DRY_RUN=1   Print mac notif args instead of showing
#   NOTIFY_THREAD_DIR=<dir>  Override thread-anchor directory

set -euo pipefail

INPUT=$(cat)

emit_success() { [ "${RUNTIME:-}" = "codex" ] && printf '{}\n'; return 0; }
cleanup_and_exit() { emit_success; exit 0; }

# Suppress notifications when this session is an internal LLM call made
# by another tool (e.g. pg invoking `codex exec` for the semantic brief
# or intent check). The parent sets NOTIFY_SUPPRESS=1, which propagates
# through the codex child process into its Stop hook environment.
[ "${NOTIFY_SUPPRESS:-0}" = "1" ] && cleanup_and_exit

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

# URL-encode path segment: keep / : - _ . ~ and alnum, percent-encode the rest.
# Needed because terminal-notifier -open goes through NSURL which is strict.
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

send_macos_notification() {
  local title="$1" subtitle="$2" message="$3" group="$4" sender="$5"
  [ "$(uname -s)" = "Darwin" ] || return 0
  if [ "${TERM_PROGRAM:-}" = "ghostty" ]; then
    [ "$(frontmost_bundle_id || true)" = "com.mitchellh.ghostty" ] && return 0
  fi
  # Clicking the notification opens VS Code at the canonical repo path
  # (main repo, not worktree). Falls back to -activate for the current
  # terminal if no repo path is resolvable.
  local open_url="" activate=""
  if [ -n "${MAIN_REPO_PATH:-}" ]; then
    open_url="vscode://file$(url_encode_path "$MAIN_REPO_PATH")"
  else
    case "${TERM_PROGRAM:-}" in
      ghostty) activate="com.mitchellh.ghostty" ;;
      vscode)  activate="com.microsoft.VSCode" ;;
    esac
  fi
  local one_line
  one_line=$(printf '%s' "$message" | tr '\n' ' ' | cut -c1-200)
  if [ "${NOTIFY_MACOS_DRY_RUN:-0}" = "1" ]; then
    printf 'macos title=%s subtitle=%s message=%s group=%s open=%s activate=%s\n' \
      "$title" "$subtitle" "$one_line" "$group" "${open_url:-<none>}" "${activate:-<none>}" >&2
    return 0
  fi
  command -v terminal-notifier >/dev/null 2>&1 || return 0
  local args=(-title "$title" -subtitle "$subtitle" -message "$one_line" -sound Pop -group "$group" -sender "$sender" -timeout 10 -ignoreDnD)
  if [ -n "$open_url" ]; then
    args+=(-open "$open_url")
  elif [ -n "$activate" ]; then
    args+=(-activate "$activate")
  fi
  terminal-notifier "${args[@]}" >/dev/null 2>&1 &
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
    # Subtitle: "<branch> · <one-line activity title>". Branch up front
    # disambiguates when you have multiple branches/worktrees active.
    # Title is LLM-generated via codex when available (~2s), falls back
    # to first-line-of-summary heuristic.
    llm_title=""
    if command -v codex >/dev/null 2>&1; then
      _tmp=$(mktemp -t notify-title 2>/dev/null) || _tmp=""
      if [ -n "$_tmp" ]; then
        # NOTIFY_SUPPRESS=1 prevents the child codex's own Stop hook
        # from firing back into this script (infinite recursion).
        NOTIFY_SUPPRESS=1 PG_INTERNAL_CODEX=1 codex exec \
          -m gpt-5-nano \
          -c model_reasoning_effort='"low"' \
          --output-last-message "$_tmp" \
          "Summarize this assistant-turn output into ONE imperative phrase under 8 words. No period, no trailing punctuation. Output only the phrase:

$SUMMARY" </dev/null >/dev/null 2>&1
        llm_title=$(awk 'NF{print; exit}' "$_tmp" 2>/dev/null | cut -c1-60)
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
  FOOTER="$FOOTER · <vscode://file$MAIN_REPO_PATH|VS Code>"
fi

if [ "$RUNTIME" = "codex" ]; then
  MACOS_SENDER="com.googlecode.iterm2"
  MACOS_GROUP="codex-$REPO"
else
  MACOS_SENDER="com.anthropic.claudefordesktop"
  MACOS_GROUP="claude-$REPO"
fi

send_macos_notification "$REPO" "$SUBTITLE" "$SUMMARY" "$MACOS_GROUP" "$MACOS_SENDER"

TOKEN=""; CHAN=""; SLACK_USER=""
if command -v security >/dev/null 2>&1; then
  TOKEN=$(security find-generic-password -a "${USER:-$(id -un)}" -s claude-slack-bot-token -w 2>/dev/null || true)
  CHAN=$(security find-generic-password -a "${USER:-$(id -un)}" -s claude-slack-channel -w 2>/dev/null || true)
  SLACK_USER=$(security find-generic-password -a "${USER:-$(id -un)}" -s claude-slack-user-id -w 2>/dev/null || true)
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
