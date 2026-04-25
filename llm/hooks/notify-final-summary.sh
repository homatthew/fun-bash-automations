#!/bin/bash
# Detached task-finished notification summarizer for notify.sh.

set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/Applications/Visual Studio Code.app/Contents/Resources/app/bin:${PATH:-}"

SPEC="${1:-}"
[ -n "$SPEC" ] && [ -f "$SPEC" ] || exit 0

cleanup() {
  rm -f "$SPEC"
}
trap cleanup EXIT

eval "$(jq -r '
  @sh "SOURCE_TEXT=\(.source_text // "")",
  @sh "TASK_SUMMARY=\(.task_summary // "")",
  @sh "TITLE=\(.title // "")",
  @sh "SUBTITLE=\(.subtitle // "")",
  @sh "GROUP=\(.group // "")",
  @sh "SENDER=\(.sender // "")",
  @sh "OPEN_URL=\(.open_url // "")",
  @sh "CWD=\(.cwd // "")",
  @sh "LOG=\(.log // "/tmp/fba-notify.log")",
  @sh "STATE_FILE=\(.state_file // "")",
  @sh "STATE_ID=\(.state_id // "")",
  @sh "SUMMARY_FILE=\(.summary_file // "")"
' "$SPEC")"

nlog() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true
}

home_dir() {
  [ -n "${HOME:-}" ] && { printf '%s' "$HOME"; return; }
  dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2; exit}'
}

state_is_current() {
  [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ] || return 1
  [ "$(cat "$STATE_FILE" 2>/dev/null || true)" = "$STATE_ID" ]
}

extract_summary() {
  local file="$1" out
  out=$(jq -er '
    if type == "object" then (.summary // .title // .message // .body // empty)
    elif type == "string" then .
    else empty end
  ' "$file" 2>/dev/null || true)
  [ -n "$out" ] || out=$(awk 'NF{print; exit}' "$file" 2>/dev/null || true)

  printf '%s' "$out" \
    | sed -E '
        s/^[[:space:]]*[-"*`]+[[:space:]]*//;
        s/^[[:space:]]*[Tt]itle:[[:space:]]*//;
        s/^[[:space:]]*[Ss]ummary:[[:space:]]*//;
        s/[[:space:]]*[."`]+$//;
        s/[[:space:]]+/ /g;
        s/^ //; s/ $//;' \
    | cut -c1-90
}

run_codex_summary() {
  NOTIFY_SUPPRESS=1 PG_INTERNAL_CODEX=1 codex exec \
    -m gpt-5-nano \
    -C "$CWD" \
    -c features.codex_hooks=false \
    -c model_reasoning_effort='"low"' \
    --output-last-message "$tmp" \
    "Summarize the completed agent task below for a macOS notification.

Output one concise completion summary, 3-9 words.
Use a past-tense verb or concise result phrase.
Examples:
- Updated notification status layout
- Verified hook click focus
- Documented notification architecture

Do not include emoji, quotes, JSON, markdown, file paths, branch names, or punctuation at the end.
Do not output generic words like done, finished, completed, or task complete by themselves.

Original task summary:
$TASK_SUMMARY

Final assistant/result text:
$SOURCE_TEXT" </dev/null >/dev/null 2>"$err"
}

run_with_timeout() {
  local seconds="$1" rc_file pid rc
  rc_file=$(mktemp -t fba-notify-final-summary-rc 2>/dev/null) || return 1
  rm -f "$rc_file"
  (
    set +e
    run_codex_summary
    printf '%s' "$?" > "$rc_file"
  ) &
  pid=$!

  for _ in $(seq 1 "$((seconds * 10))"); do
    [ -f "$rc_file" ] && break
    sleep 0.1
  done

  if [ ! -f "$rc_file" ]; then
    kill "$pid" >/dev/null 2>&1 || true
    sleep 0.2
    kill -9 "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
    rm -f "$rc_file"
    return 124
  fi

  wait "$pid" >/dev/null 2>&1 || true
  rc=$(cat "$rc_file" 2>/dev/null || printf 1)
  rm -f "$rc_file"
  return "$rc"
}

[ -n "$SOURCE_TEXT" ] || [ -n "$TASK_SUMMARY" ] || exit 0
state_is_current || exit 0
command -v codex >/dev/null 2>&1 || exit 0

HOME="$(home_dir)"
[ -n "$HOME" ] || HOME="/Users/$(id -un)"
export HOME
export CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
if [ -z "${OPENAI_API_KEY:-}" ] && [ -f "$CODEX_HOME/auth.json" ]; then
  OPENAI_API_KEY="$(jq -r '.OPENAI_API_KEY // empty' "$CODEX_HOME/auth.json" 2>/dev/null || true)"
  export OPENAI_API_KEY
fi

tmp=$(mktemp -t fba-notify-final-summary 2>/dev/null) || exit 0
err=$(mktemp -t fba-notify-final-summary-err 2>/dev/null) || err=/dev/null
trap 'rm -f "$SPEC" "$tmp" "$err"' EXIT

nlog "final summary start: source_len=${#SOURCE_TEXT} task_len=${#TASK_SUMMARY} cwd=$CWD codex=$(command -v codex) home=${HOME:-<none>}"
rc=0
run_with_timeout 12 || rc=$?
summary="$(extract_summary "$tmp")"
out_len=$(wc -c < "$tmp" 2>/dev/null | tr -d ' ' || printf 0)
err_tail=$(tr '\n' ' ' < "$err" 2>/dev/null | cut -c1-240)
nlog "final summary codex rc=$rc out_len=$out_len err=${err_tail:-<none>}"

if [ -z "$summary" ]; then
  nlog "final summary unavailable"
  exit 0
fi

if [ "$rc" -ne 0 ]; then
  nlog "final summary using output despite rc=$rc: $summary"
fi

state_is_current || {
  nlog "final summary skipped stale update: $summary"
  exit 0
}

if [ -n "$SUMMARY_FILE" ]; then
  printf '%s' "$summary" > "$SUMMARY_FILE" 2>/dev/null || true
fi

nlog "final summary update: $summary"
resp=$(alerter --title "$TITLE" --subtitle "$SUBTITLE" --message "$summary" \
  --ignore-dnd --actions Show --timeout 0 --sound Pop \
  ${GROUP:+--group "$GROUP"} \
  ${SENDER:+--sender "$SENDER"} --json 2>&1 || true)
act=$(printf '%s' "$resp" | jq -r '.activationType // ""' 2>/dev/null || true)
nlog "final summary alerter act=$act"
if [[ "$act" = "contentsClicked" || "$act" = "actionClicked" ]] && [ -n "$OPEN_URL" ]; then
  open "$OPEN_URL" >/dev/null 2>&1 || true
  if [ -n "$CWD" ] && command -v code >/dev/null 2>&1; then
    code "$CWD" >/dev/null 2>&1 || true
    sleep 0.4
    open "$OPEN_URL" >/dev/null 2>&1 || true
  fi
fi
