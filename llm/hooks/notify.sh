#!/bin/bash
# Claude/Codex macOS notification hook.

set -euo pipefail

INPUT=$(cat)

emit_success() {
  case "${RUNTIME:-$0}" in
    *codex*)
    printf '{}\n'
      ;;
  esac
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

extract_display_title() {
  local raw="$1" out
  out=$(printf '%s' "$raw" | jq -er '
    if type == "object" then (.title // empty)
    elif type == "string" then .
    else empty end
  ' 2>/dev/null || true)
  [ -n "$out" ] && { printf '%s' "$out"; return; }

  out=$(printf '%s\n' "$raw" | sed -n -E 's/^[[:space:]]*[Tt]itle:[[:space:]]*//p' | awk 'NF{print; exit}')
  [ -n "$out" ] && { printf '%s' "$out"; return; }

  printf '%s' "$raw"
}

extract_display_message() {
  local raw="$1" out
  out=$(printf '%s' "$raw" | jq -er '
    if type == "object" then (.body // .message // .summary // .title // empty)
    elif type == "string" then .
    else empty end
  ' 2>/dev/null || true)
  [ -n "$out" ] && { printf '%s' "$out"; return; }

  out=$(printf '%s\n' "$raw" | sed -n -E 's/^[[:space:]]*[Bb]ody:[[:space:]]*//p' | awk 'NF{print; exit}')
  [ -n "$out" ] && { printf '%s' "$out"; return; }

  out=$(printf '%s\n' "$raw" | sed -n -E 's/^[[:space:]]*[Tt]itle:[[:space:]]*//p' | awk 'NF{print; exit}')
  [ -n "$out" ] && { printf '%s' "$out"; return; }

  printf '%s' "$raw"
}

notify_editor_scheme() {
  printf '%s' "${NOTIFY_EDITOR_SCHEME:-vscode}"
}

NOTIFY_LOG="${NOTIFY_LOG:-/tmp/fba-notify.log}"
RUNNING_ICON="⏳"
DONE_ICON="🏁"
INPUT_ICON="❓"
INPUT_STATUS="$INPUT_ICON Input needed"

nlog() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "$NOTIFY_LOG" 2>/dev/null || true
}

notify_state_file() {
  local key
  key=$(printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_')
  printf '/tmp/fba-notify-state-%s' "$key"
}

notify_summary_file() {
  local key
  key=$(printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_')
  printf '/tmp/fba-notify-summary-%s' "$key"
}

notify_context_file() {
  local key
  key=$(printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_')
  printf '/tmp/fba-notify-context-%s' "$key"
}

write_notify_state() {
  local file="$1" value="$2"
  [ -n "$file" ] || return 0
  printf '%s' "$value" > "$file" 2>/dev/null || true
}

write_notify_summary() {
  local file="$1" value="$2"
  [ -n "$file" ] || return 0
  [ -n "$value" ] || return 0
  printf '%s' "$value" > "$file" 2>/dev/null || true
}

read_notify_summary() {
  local file="$1"
  [ -n "$file" ] && [ -f "$file" ] || return 0
  head -n 1 "$file" 2>/dev/null | cut -c1-80
}

write_notify_context() {
  local file="$1" value="$2"
  [ -n "$file" ] || return 0
  [ -n "$value" ] || return 0
  printf '%s' "$value" > "$file" 2>/dev/null || true
}

read_notify_context() {
  local file="$1"
  [ -n "$file" ] && [ -f "$file" ] || return 0
  head -n 1 "$file" 2>/dev/null | cut -c1-48
}

prompt_task_summary() {
  local prompt="$1" clean
  clean=$(normalize_message "$prompt" 140)
  clean=$(printf '%s' "$clean" | sed -E '
    :again
    s/^([Oo]k(ay)?|[Gg]reat|[Tt]hen|[Ss]o|[Aa]lso|[Nn]ow)[,[:space:]]+//;
    s/^([Cc]an|[Cc]ould|[Ww]ould) you[[:space:]]+//;
    s/^([Pp]lease|[Ll]et'\''s|[Ww]e need to|[Ww]e want to|[Ii] want to|[Jj]ust)[[:space:]]+//;
    t again
    s/[[:space:]]+/ /g;
    s/^ //; s/ $//;')

  if printf '%s' "$clean" | grep -Eiq 'notif|alerter|hook|focus|icon|show|vscode'; then
    printf 'Improving notification behavior'
  elif printf '%s' "$clean" | grep -Eiq 'summary|task running|running task|working label|start message'; then
    printf 'Summarizing running task'
  elif printf '%s' "$clean" | grep -Eiq 'commit|push|pull request|[^[:alpha:]]pr[^[:alpha:]]'; then
    printf 'Preparing repository changes'
  elif printf '%s' "$clean" | grep -Eiq 'test|verify|smoke|lint|build'; then
    printf 'Verifying current changes'
  elif printf '%s' "$clean" | grep -Eiq 'debug|log|trace|error|fail|timeout'; then
    printf 'Debugging runtime behavior'
  elif printf '%s' "$clean" | grep -Eiq 'readme|doc|architecture|handoff|second brain'; then
    printf 'Documenting implementation details'
  elif [ -n "$clean" ]; then
    printf '%s' "$clean" | awk '
      {
        limit = NF < 7 ? NF : 7
        for (i = 1; i <= limit; i++) {
          if (i > 1) printf " "
          printf "%s", $i
        }
      }'
  else
    printf 'Handling current request'
  fi
}

pr_context_label() {
  local pr="$1" title
  title=$(printf '%s' "$pr" \
    | sed -E '
        s/^#[0-9]+[[:space:]]+//;
        s/[[:space:]]+\[[^]]+\]$//;
        s/^[A-Za-z]+(\([^)]+\))?!?:[[:space:]]*//;
        s/^(add|update|fix|implement|improve)[[:space:]]+//I;
        s/[[:space:]]+/ /g;
        s/^ //; s/ $//;')

  [ -n "$title" ] || return 0
  if printf '%s' "$title" | grep -Eiq 'push-gate|push gate|lease'; then
    printf 'Push-gate leases'
    return
  fi
  if printf '%s' "$title" | grep -Eiq 'notif|alerter|hook|focus|icon|show|vscode|claude|codex'; then
    printf 'Agent notifications'
    return
  fi
  printf '%s' "$title" | awk '{
    limit = NF < 3 ? NF : 3
    for (i = 1; i <= limit; i++) {
      if (i > 1) printf " "
      word = $i
      printf "%s", toupper(substr(word, 1, 1)) substr(word, 2)
    }
  }' | cut -c1-48
}

prompt_task_context() {
  local prompt="$1" clean
  clean=$(normalize_message "$prompt" 180)

  if printf '%s %s' "$REPO" "$clean" | grep -Eiq 'notif|alerter|hook|focus|icon|show|vscode|claude|codex'; then
    printf 'Agent notifications'
  elif printf '%s' "$clean" | grep -Eiq 'commit|push|pull request|[^[:alpha:]]pr[^[:alpha:]]'; then
    if [ -n "${PR_CONTEXT:-}" ]; then
      pr_context_label "$PR_CONTEXT"
    else
      printf 'Git workflow'
    fi
  elif printf '%s' "$clean" | grep -Eiq 'test|verify|smoke|lint|build'; then
    printf 'Verification'
  elif printf '%s' "$clean" | grep -Eiq 'debug|log|trace|error|fail|timeout'; then
    printf 'Debugging'
  elif printf '%s' "$clean" | grep -Eiq 'readme|doc|architecture|handoff|second brain'; then
    printf 'Docs'
  elif [ -n "${BRANCH:-}" ] && ! printf '%s' "$BRANCH" | grep -Eq '^(main|master|develop|dev|mh-netflix)$'; then
    printf '%s' "$BRANCH" | cut -c1-48
  else
    printf '%s' "$REPO" | tr '-' ' ' | awk '{
      for (i = 1; i <= NF; i++) {
        $i = toupper(substr($i, 1, 1)) substr($i, 2)
      }
      print
    }' | cut -c1-48
  fi
}

git_recent_commits() {
  git -C "$CWD" log --format='%s' -5 2>/dev/null | paste -sd '; ' - | cut -c1-300 || true
}

git_pr_context() {
  command -v gh >/dev/null 2>&1 || return 0
  (
    cd "$CWD" 2>/dev/null || exit 0
    gh pr view --json number,title,headRefName,state 2>/dev/null \
      | jq -r 'select(.number != null) | "#\(.number) \(.title) [\(.headRefName)]"' 2>/dev/null \
      | cut -c1-180
  ) || true
}

stop_message_is_unhelpful() {
  local value
  value=$(normalize_message "$1" 80 | tr '[:upper:]' '[:lower:]')
  case "$value" in
    ""|"{}"|"[]"|"done"|"task complete"|"task completed"|"complete"|"completed"|"finished")
      return 0
      ;;
  esac
  return 1
}

stop_message_needs_input() {
  local value
  value=$(normalize_message "$1" 500)
  [ -n "$value" ] || return 1

  # Codex does not currently have a Claude-style Notification hook. Treat a
  # Stop as input-needed only when the final text asks for a concrete action.
  # A bare trailing question mark is too broad: summaries often end with
  # rhetorical or diagnostic questions that do not actually block on a reply.
  printf '%s' "$value" | grep -Eiq \
    '(need|needs|waiting for|requires?) (your )?(input|answer|confirmation|permission|approval|choice|decision)|please (confirm|choose|provide|send|share|clarify)|which (option|approach|one)|what (do you want|would you like|should i)|should i|would you like me to|do you want( me)? to|do you prefer|can you (confirm|provide|send|share|clarify)|are you sure|is that ok|ok to proceed|answer these|respond with|reply with|tell me when|let me know' \
    && return 0
  return 1
}

input_request_kind() {
  local value
  value=$(normalize_message "$1" 500 | tr '[:upper:]' '[:lower:]')
  if printf '%s' "$value" | grep -Eiq 'permission|approval|approve|pg push|push --assert-flow|push-gate|run `?pg`?'; then
    printf 'Permission'
  elif printf '%s' "$value" | grep -Eiq 'choose|choice|which (option|approach|one|direction)|two possible|options?:'; then
    printf 'Choice needed'
  elif printf '%s' "$value" | grep -Eiq 'confirm|confirmation|do you want|should i|proceed|run that now|is that ok'; then
    printf 'Confirm'
  elif printf '%s' "$value" | grep -Eiq 'clarify|clarification|what do you mean|more context|not sure what'; then
    printf 'Clarify'
  elif printf '%s' "$value" | grep -Eiq 'provide|send|share|missing|need .* (info|information|details|file|path|url|name)'; then
    printf 'Missing info'
  elif printf '%s' "$value" | grep -Eiq 'review|check|look over|inspect'; then
    printf 'Review needed'
  else
    printf 'Input needed'
  fi
}

input_subtitle() {
  local kind="$1" context="$2"
  if [ -n "$context" ] && ! display_values_match "$kind" "$context"; then
    printf '%s · %s' "$kind" "$context"
  else
    printf '%s' "$kind"
  fi
}

display_values_match() {
  local left right
  left=$(normalize_message "$1" 120 | tr '[:upper:]' '[:lower:]')
  right=$(normalize_message "$2" 120 | tr '[:upper:]' '[:lower:]')
  [ -n "$left" ] && [ "$left" = "$right" ]
}

branch_is_display_useful() {
  local branch="$1"
  [ -n "$branch" ] || return 1
  ! printf '%s' "$branch" | grep -Eq '^(main|master|develop|dev|mh-netflix)$'
}

dedupe_notification_message() {
  local state="$1" subtitle="$2" message="$3" subtitle_tail
  subtitle_tail=$(printf '%s' "$subtitle" | sed -E 's/^.* · //')
  if display_values_match "$message" "$subtitle" || display_values_match "$message" "$subtitle_tail"; then
    case "$state" in
      running|done|UserPromptSubmit|Stop) printf '%s' "$message" ;;
      input|Notification)                 printf '%s' "$INPUT_STATUS" ;;
      *)                                  printf '%s' "$message" ;;
    esac
    return
  fi
  printf '%s' "$message"
}

strip_status_prefix() {
  normalize_message "$1" 140 \
    | sed -E 's/^(⏳|🏁|✅|❓)[[:space:]]+//; s/^[Ii]n progress:[[:space:]]+//; s/^[Ff]inished:[[:space:]]+//'
}

dedupe_notification_subtitle() {
  local subtitle="$1" message="$2" branch="$3" subtitle_tail message_text
  subtitle_tail=$(printf '%s' "$subtitle" | sed -E 's/^.* · //')
  message_text="$(strip_status_prefix "$message")"
  if display_values_match "$message_text" "$subtitle_tail"; then
    if branch_is_display_useful "$branch"; then
      printf '%s' "$branch"
    else
      printf ''
    fi
    return
  fi
  printf '%s' "$subtitle"
}

dispatch_alerter() {
  local title="$1" subtitle="$2" message="$3" group="$4" sender="$5" open_url="$6" style="$7" cwd="$8"
  local action_label="${9:-Show}"
  local sound="${10-Pop}"
  local state_file="${11:-}"
  local state_id="${12:-}"
  local sticky_after_click="${13:-0}"
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
    --arg action_label "$action_label" \
    --arg sound "$sound" \
    --arg cwd "$cwd" \
    --arg log "$NOTIFY_LOG" \
    --arg state_file "$state_file" \
    --arg state_id "$state_id" \
    --arg sticky_after_click "$sticky_after_click" \
    '{title:$title, subtitle:$subtitle, message:$message, group:$group, sender:$sender, open_url:$open_url, style:$style, action_label:$action_label, sound:$sound, cwd:$cwd, log:$log, state_file:$state_file, state_id:$state_id, sticky_after_click:$sticky_after_click}' \
    > "$spec"
  label="com.matthewho.fba.notify.${RUNTIME:-agent}.$$.$RANDOM"
  if launchctl submit -l "$label" -o /tmp/fba-notify-dispatch.out -e /tmp/fba-notify-dispatch.err -- /bin/bash "$dispatcher" "$spec" >/dev/null 2>&1; then
    nlog "alerter dispatched: label=$label"
    return 0
  fi
  nlog "launchctl dispatch failed; falling back to nohup"
  nohup /bin/bash "$dispatcher" "$spec" >/dev/null 2>&1 &
}

dispatch_working_summary() {
  local prompt="$1" title="$2" subtitle="$3" group="$4" sender="$5" open_url="$6" cwd="$7" state_file="$8" state_id="$9" summary_file="${10:-}" context_file="${11:-}" repo="${12:-}" branch="${13:-}" pr_context="${14:-}" recent_commits="${15:-}"
  local summarizer spec label
  [ -n "$prompt" ] || return 0
  command -v codex >/dev/null 2>&1 || return 0
  summarizer="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/notify-working-summary.sh"
  if [ ! -x "$summarizer" ]; then
    nlog "working summarizer missing: $summarizer"
    return 0
  fi
  spec=$(mktemp -t fba-notify-working-summary 2>/dev/null) || return 0
  jq -n \
    --arg prompt "$prompt" \
    --arg title "$title" \
    --arg subtitle "$subtitle" \
    --arg group "$group" \
    --arg sender "$sender" \
    --arg open_url "$open_url" \
    --arg cwd "$cwd" \
    --arg log "$NOTIFY_LOG" \
    --arg state_file "$state_file" \
    --arg state_id "$state_id" \
    --arg summary_file "$summary_file" \
    --arg context_file "$context_file" \
    --arg repo "$repo" \
    --arg branch "$branch" \
    --arg pr_context "$pr_context" \
    --arg recent_commits "$recent_commits" \
    '{prompt:$prompt, title:$title, subtitle:$subtitle, group:$group, sender:$sender, open_url:$open_url, cwd:$cwd, log:$log, state_file:$state_file, state_id:$state_id, summary_file:$summary_file, context_file:$context_file, repo:$repo, branch:$branch, pr_context:$pr_context, recent_commits:$recent_commits}' \
    > "$spec"
  label="com.matthewho.fba.notify.summary.${RUNTIME:-agent}.$$.$RANDOM"
  if launchctl submit -l "$label" -o /tmp/fba-notify-summary.out -e /tmp/fba-notify-summary.err -- /bin/bash "$summarizer" "$spec" >/dev/null 2>&1; then
    nlog "working summarizer dispatched: label=$label"
    return 0
  fi
  nlog "launchctl working summarizer failed; falling back to nohup"
  nohup /bin/bash "$summarizer" "$spec" >/dev/null 2>&1 &
}

dispatch_final_summary() {
  local source_text="$1" task_summary="$2" title="$3" subtitle="$4" group="$5" sender="$6" open_url="$7" cwd="$8" state_file="$9" state_id="${10}" summary_file="${11:-}" context_file="${12:-}" repo="${13:-}" branch="${14:-}" pr_context="${15:-}" recent_commits="${16:-}"
  local summarizer spec label
  command -v codex >/dev/null 2>&1 || return 0
  summarizer="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/notify-final-summary.sh"
  if [ ! -x "$summarizer" ]; then
    nlog "final summarizer missing: $summarizer"
    return 0
  fi
  spec=$(mktemp -t fba-notify-final-summary 2>/dev/null) || return 0
  jq -n \
    --arg source_text "$source_text" \
    --arg task_summary "$task_summary" \
    --arg title "$title" \
    --arg subtitle "$subtitle" \
    --arg group "$group" \
    --arg sender "$sender" \
    --arg open_url "$open_url" \
    --arg cwd "$cwd" \
    --arg log "$NOTIFY_LOG" \
    --arg state_file "$state_file" \
    --arg state_id "$state_id" \
    --arg summary_file "$summary_file" \
    --arg context_file "$context_file" \
    --arg repo "$repo" \
    --arg branch "$branch" \
    --arg pr_context "$pr_context" \
    --arg recent_commits "$recent_commits" \
    '{source_text:$source_text, task_summary:$task_summary, title:$title, subtitle:$subtitle, group:$group, sender:$sender, open_url:$open_url, cwd:$cwd, log:$log, state_file:$state_file, state_id:$state_id, summary_file:$summary_file, context_file:$context_file, repo:$repo, branch:$branch, pr_context:$pr_context, recent_commits:$recent_commits}' \
    > "$spec"
  label="com.matthewho.fba.notify.final.${RUNTIME:-agent}.$$.$RANDOM"
  if launchctl submit -l "$label" -o /tmp/fba-notify-final.out -e /tmp/fba-notify-final.err -- /bin/bash "$summarizer" "$spec" >/dev/null 2>&1; then
    nlog "final summarizer dispatched: label=$label"
    return 0
  fi
  nlog "launchctl final summarizer failed; falling back to nohup"
  nohup /bin/bash "$summarizer" "$spec" >/dev/null 2>&1 &
}

dispatch_input_summary() {
  local source_text="$1" task_summary="$2" title="$3" subtitle="$4" group="$5" sender="$6" open_url="$7" cwd="$8" state_file="$9" state_id="${10}" summary_file="${11:-}" context_file="${12:-}" repo="${13:-}" branch="${14:-}" pr_context="${15:-}" recent_commits="${16:-}"
  local summarizer spec label
  [ -n "$source_text" ] || return 0
  command -v codex >/dev/null 2>&1 || return 0
  summarizer="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/notify-input-summary.sh"
  if [ ! -x "$summarizer" ]; then
    nlog "input summarizer missing: $summarizer"
    return 0
  fi
  spec=$(mktemp -t fba-notify-input-summary 2>/dev/null) || return 0
  jq -n \
    --arg source_text "$source_text" \
    --arg task_summary "$task_summary" \
    --arg title "$title" \
    --arg subtitle "$subtitle" \
    --arg group "$group" \
    --arg sender "$sender" \
    --arg open_url "$open_url" \
    --arg cwd "$cwd" \
    --arg log "$NOTIFY_LOG" \
    --arg state_file "$state_file" \
    --arg state_id "$state_id" \
    --arg summary_file "$summary_file" \
    --arg context_file "$context_file" \
    --arg repo "$repo" \
    --arg branch "$branch" \
    --arg pr_context "$pr_context" \
    --arg recent_commits "$recent_commits" \
    '{source_text:$source_text, task_summary:$task_summary, title:$title, subtitle:$subtitle, group:$group, sender:$sender, open_url:$open_url, cwd:$cwd, log:$log, state_file:$state_file, state_id:$state_id, summary_file:$summary_file, context_file:$context_file, repo:$repo, branch:$branch, pr_context:$pr_context, recent_commits:$recent_commits}' \
    > "$spec"
  label="com.matthewho.fba.notify.input.${RUNTIME:-agent}.$$.$RANDOM"
  if launchctl submit -l "$label" -o /tmp/fba-notify-input.out -e /tmp/fba-notify-input.err -- /bin/bash "$summarizer" "$spec" >/dev/null 2>&1; then
    nlog "input summarizer dispatched: label=$label"
    return 0
  fi
  nlog "launchctl input summarizer failed; falling back to nohup"
  nohup /bin/bash "$summarizer" "$spec" >/dev/null 2>&1 &
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
  local action_label="${8:-Show}"
  local sound="${9-Pop}"
  local state_file="${10:-}"
  local state_id="${11:-}"
  local sticky_after_click="${12:-0}"
  # Alert style is persistent. alerter only renders a sticky alert when
  # --actions is supplied; --timeout 0 means no auto-close.
  local extra_args=()
  if [ "$style" = "alert" ]; then
    extra_args+=(--actions "$action_label" --timeout 0)
  else
    extra_args+=(--timeout 60)
  fi
  [ -n "$sound" ] && extra_args+=(--sound "$sound")
  nlog "alerter invoke: title=$title subtitle=$subtitle style=$style action=$action_label sound=${sound:-<none>} msg_len=${#message} sender=${sender:-<none>} open=${open_url:-<none>}"
  if dispatch_alerter "$title" "$subtitle" "$message" "$group" "$sender" "$open_url" "$style" "${MAIN_REPO_PATH:-$CWD}" "$action_label" "$sound" "$state_file" "$state_id" "$sticky_after_click"; then
    return
  fi
  (
    resp=$(alerter --title "$title" --subtitle "$subtitle" --message "$message" \
      --ignore-dnd \
      "${extra_args[@]}" \
      ${group:+--group "$group"} \
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
  local action_label="${7:-Show}"
  local sound="${8-Pop}"
  local state_file="${9:-}"
  local state_id="${10:-}"
  local sticky_after_click="${11:-0}"
  # Ring the terminal bell for audible notifications so the tab gets a bell
  # icon when not active. Quiet working notifications only update macOS state.
  [ -n "$sound" ] && (printf '\a' > /dev/tty) 2>/dev/null || true
  local pids event_lc
  pids=$(ancestor_pids)
  event_lc="${DISPLAY_STATE:-$(printf '%s' "$EVENT" | tr '[:upper:]' '[:lower:]')}"
  nlog "vscode: event=$event_lc pids=$pids"
  local _label
  _label=$(printf '%s' "$subtitle" | cut -c1-80)
  local open_url="vscode://${VSCODE_EXT_PUBLISHER}.${VSCODE_EXT_NAME}${VSCODE_EXT_URI_PATH}?cwd=$(url_encode_path "${MAIN_REPO_PATH:-$CWD}")&pids=$(url_encode_path "$pids")&event=$event_lc&label=$(url_encode_path "$_label")"
  backend_alerter "$title" "$subtitle" "$message" "$group" "$sender" "$open_url" "$style" "$action_label" "$sound" "$state_file" "$state_id" "$sticky_after_click"
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
  @sh "TURN_ID=\(.turn_id // "")",
  @sh "NOTIF_TYPE=\(.notification_type // "")",
  @sh "STOP_ACTIVE=\(.stop_hook_active // false)",
  @sh "SESSION_ID=\(.session_id // "")",
  @sh "CWD=\(.cwd // "")",
  @sh "TRANSCRIPT=\(.transcript_path // "")",
  @sh "NOTIF_TITLE=\(.title // "")",
  @sh "NOTIF_MSG=\(.message // "")",
  @sh "LAST_ASSISTANT=\(.last_assistant_message // "")",
  @sh "PROMPT=\(.prompt // "")"
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
PR_CONTEXT="$(git_pr_context)"
RECENT_COMMITS="$(git_recent_commits)"

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

RUN_ID="${TURN_ID:-$SESSION_ID}"
[ -z "$RUN_ID" ] && RUN_ID="${RUNTIME:-agent}-$REPO-$$"
STATE_FILE="$(notify_state_file "$GROUP")"
SUMMARY_FILE="$(notify_summary_file "$GROUP")"
CONTEXT_FILE="$(notify_context_file "$GROUP")"
TASK_SUMMARY="$(read_notify_summary "$SUMMARY_FILE")"
TASK_CONTEXT="$(read_notify_context "$CONTEXT_FILE")"
DISPLAY_TITLE="$REPO"
FINAL_SUMMARY_SOURCE=""
DISPLAY_STATE=""
INPUT_KIND=""
INPUT_SUMMARY_SOURCE=""

case "$EVENT" in
  UserPromptSubmit)
    DISPLAY_STATE="running"
    DISPLAY_TITLE="$RUNNING_ICON $REPO"
    TASK_SUMMARY="$(prompt_task_summary "$PROMPT")"
    TASK_CONTEXT="$(prompt_task_context "$PROMPT")"
    write_notify_summary "$SUMMARY_FILE" "$TASK_SUMMARY"
    write_notify_context "$CONTEXT_FILE" "$TASK_CONTEXT"
    MESSAGE="$TASK_SUMMARY"
    if [ -n "$TASK_CONTEXT" ]; then
      SUBTITLE="$TASK_CONTEXT"
    elif [ -n "${BRANCH:-}" ]; then
      SUBTITLE="$BRANCH"
    else
      SUBTITLE="Active task"
    fi
    ;;
  Stop)
    RAW_MESSAGE="${LAST_ASSISTANT:-}"
    fallback_title=""
    [ -z "$RAW_MESSAGE" ] && RAW_MESSAGE="$(extract_transcript_message)"
    FINAL_SUMMARY_SOURCE="$RAW_MESSAGE"
    if [ "$RUNTIME" = "codex" ] && stop_message_needs_input "$RAW_MESSAGE"; then
      DISPLAY_STATE="input"
      DISPLAY_TITLE="$INPUT_ICON $REPO"
      MESSAGE="$(extract_display_message "$RAW_MESSAGE")"
      INPUT_KIND="$(input_request_kind "$RAW_MESSAGE")"
      _input_context="${TASK_CONTEXT:-$(prompt_task_context "$RAW_MESSAGE")}"
      SUBTITLE="$(input_subtitle "$INPUT_KIND" "$_input_context")"
    else
      DISPLAY_STATE="done"
      DISPLAY_TITLE="$DONE_ICON $REPO"
      if stop_message_is_unhelpful "$RAW_MESSAGE"; then
        if [ -n "$TASK_SUMMARY" ]; then
          RAW_MESSAGE="$TASK_SUMMARY"
          fallback_title="$TASK_SUMMARY"
        else
          RAW_MESSAGE="Current request completed"
          fallback_title="Current request completed"
        fi
      fi
      MESSAGE="$(extract_display_message "$RAW_MESSAGE")"
      title_source="$(extract_display_title "$RAW_MESSAGE")"
      [ -n "$fallback_title" ] && title_source="$fallback_title"
      if stop_message_is_unhelpful "$title_source"; then
        if [ -n "$TASK_SUMMARY" ]; then
          title_source="$TASK_SUMMARY"
        else
          title_source="Current request completed"
        fi
      fi
      llm_title=$(printf '%s\n' "$title_source" \
        | sed -E 's/^[[:space:]]*[•\-\*]?[[:space:]]*//' \
        | awk 'NF{print; exit}' \
        | cut -c1-60)
      [ -z "$llm_title" ] && llm_title="Current request completed"
      if [ -n "$TASK_CONTEXT" ]; then
        SUBTITLE="$TASK_CONTEXT"
      elif [ -n "${BRANCH:-}" ]; then
        SUBTITLE="$BRANCH"
      else
        SUBTITLE="Finished"
      fi
    fi
    ;;
  Notification)
    DISPLAY_STATE="input"
    DISPLAY_TITLE="$INPUT_ICON $REPO"
    # Claude's payload only carries a generic "needs your attention" string.
    # Pull the last assistant message from the transcript so the banner shows
    # the actual question/context the user has to act on.
    _ctx="$(extract_transcript_message)"
    if [ -n "$_ctx" ]; then
      MESSAGE="$_ctx"
    else
      MESSAGE="${NOTIF_MSG:-Waiting for input}"
    fi
    INPUT_KIND="$(input_request_kind "$MESSAGE")"
    _input_context="${TASK_CONTEXT:-${NOTIF_TITLE:-Needs input}}"
    SUBTITLE="$(input_subtitle "$INPUT_KIND" "$_input_context")"
    ;;
  *) cleanup_and_exit ;;
esac

# Notification events render in alert dialogs which can show a paragraph.
# Running and Stop notifications stay shorter so they scan well as status.
if [ "$DISPLAY_STATE" = "input" ]; then
  MESSAGE="$(normalize_message "$MESSAGE" 1000)"
  INPUT_SUMMARY_SOURCE="$MESSAGE"
elif [ "$EVENT" = "UserPromptSubmit" ]; then
  MESSAGE="$(normalize_message "$MESSAGE" 200)"
else
  MESSAGE="$(normalize_message "$MESSAGE" 300)"
fi
MESSAGE="$(dedupe_notification_message "$DISPLAY_STATE" "$SUBTITLE" "$MESSAGE")"
SUBTITLE="$(dedupe_notification_subtitle "$SUBTITLE" "$MESSAGE" "${BRANCH:-}")"

case "$DISPLAY_STATE" in
  running) CURRENT_STATE_ID="$RUN_ID" ;;
  input)   CURRENT_STATE_ID="input:$RUN_ID" ;;
  done)    CURRENT_STATE_ID="final:$RUN_ID" ;;
  *)       CURRENT_STATE_ID="$RUN_ID" ;;
esac
write_notify_state "$STATE_FILE" "$CURRENT_STATE_ID"

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
  _dry_action="Show"
  _dry_sound="Pop"
  [ "$DISPLAY_STATE" = "input" ] && _dry_action="Respond"
  [ "$DISPLAY_STATE" = "running" ] && _dry_sound=""
  printf 'macos backend=%s state=%s title=%s subtitle=%s message=%s group=%s sender=%s style=alert action=%s sound=%s open=%s\n' \
    "$_backend" "$DISPLAY_STATE" "$DISPLAY_TITLE" "$SUBTITLE" "$MESSAGE" "$GROUP" "${SENDER_BUNDLE:-<none>}" "$_dry_action" "${_dry_sound:-<none>}" "${_preview_url:-<none>}" >&2
  cleanup_and_exit
fi

_chosen_backend=$(pick_backend)
_async_open_url="$OPEN_URL"
if [ "$_chosen_backend" = "vscode" ]; then
  _async_pids=$(ancestor_pids)
  _async_event="$DISPLAY_STATE"
  _async_label=$(printf '%s' "$SUBTITLE" | cut -c1-80)
  _async_open_url="vscode://${VSCODE_EXT_PUBLISHER}.${VSCODE_EXT_NAME}${VSCODE_EXT_URI_PATH}?cwd=$(url_encode_path "${MAIN_REPO_PATH:-$CWD}")&pids=$(url_encode_path "$_async_pids")&event=$_async_event&label=$(url_encode_path "$_async_label")"
fi
# Keep agent notifications persistent. The dispatcher is detached from the
# hook timeout, and the group id replaces older notifications for the same
# runtime/repo.
ALERT_STYLE="alert"
ACTION_LABEL="Show"
SOUND="Pop"
[ "$DISPLAY_STATE" = "running" ] && SOUND=""
[ "$DISPLAY_STATE" = "input" ] && ACTION_LABEL="Respond"
STICKY_AFTER_CLICK="0"
[ "$DISPLAY_STATE" = "running" ] && STICKY_AFTER_CLICK="1"
[ "$DISPLAY_STATE" = "input" ] && STICKY_AFTER_CLICK="1"
nlog "event=$EVENT state=$DISPLAY_STATE backend=$_chosen_backend repo=$REPO subtitle=$SUBTITLE style=$ALERT_STYLE action=$ACTION_LABEL sound=${SOUND:-<none>}"
case "$_chosen_backend" in
  vscode)            backend_vscode            "$DISPLAY_TITLE" "$SUBTITLE" "$MESSAGE" "$GROUP" "$SENDER_BUNDLE" "$ALERT_STYLE" "$ACTION_LABEL" "$SOUND" "$STATE_FILE" "$CURRENT_STATE_ID" "$STICKY_AFTER_CLICK" ;;
  alerter)           backend_alerter           "$DISPLAY_TITLE" "$SUBTITLE" "$MESSAGE" "$GROUP" "$SENDER_BUNDLE" "$OPEN_URL" "$ALERT_STYLE" "$ACTION_LABEL" "$SOUND" "$STATE_FILE" "$CURRENT_STATE_ID" "$STICKY_AFTER_CLICK" ;;
  suppressed)        nlog "suppressed: no banner sent" ;;
esac

if [ "$DISPLAY_STATE" = "running" ] && [ "$_chosen_backend" != "suppressed" ]; then
  dispatch_working_summary "$PROMPT" "$DISPLAY_TITLE" "$SUBTITLE" "$GROUP" "$SENDER_BUNDLE" "$_async_open_url" "${MAIN_REPO_PATH:-$CWD}" "$STATE_FILE" "$CURRENT_STATE_ID" "$SUMMARY_FILE" "$CONTEXT_FILE" "$REPO" "${BRANCH:-}" "$PR_CONTEXT" "$RECENT_COMMITS"
elif [ "$DISPLAY_STATE" = "done" ] && [ "$_chosen_backend" != "suppressed" ]; then
  dispatch_final_summary "$FINAL_SUMMARY_SOURCE" "$TASK_SUMMARY" "$DISPLAY_TITLE" "$SUBTITLE" "$GROUP" "$SENDER_BUNDLE" "$_async_open_url" "${MAIN_REPO_PATH:-$CWD}" "$STATE_FILE" "$CURRENT_STATE_ID" "$SUMMARY_FILE" "$CONTEXT_FILE" "$REPO" "${BRANCH:-}" "$PR_CONTEXT" "$RECENT_COMMITS"
elif [ "$DISPLAY_STATE" = "input" ] && [ "$_chosen_backend" != "suppressed" ]; then
  dispatch_input_summary "${INPUT_SUMMARY_SOURCE:-$MESSAGE}" "$TASK_SUMMARY" "$DISPLAY_TITLE" "$SUBTITLE" "$GROUP" "$SENDER_BUNDLE" "$_async_open_url" "${MAIN_REPO_PATH:-$CWD}" "$STATE_FILE" "$CURRENT_STATE_ID" "$SUMMARY_FILE" "$CONTEXT_FILE" "$REPO" "${BRANCH:-}" "$PR_CONTEXT" "$RECENT_COMMITS"
fi

cleanup_and_exit
