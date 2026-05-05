#!/bin/bash
# Detached macOS notification sender for notify.sh.

set -euo pipefail

PATH="${NOTIFY_PATH_PREFIX:+$NOTIFY_PATH_PREFIX:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/Applications/Visual Studio Code.app/Contents/Resources/app/bin:${PATH:-}"

SPEC="${1:-}"
[ -n "$SPEC" ] && [ -f "$SPEC" ] || exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [ -f "$SCRIPT_DIR/notify-metrics.sh" ]; then
  # shellcheck source=notify-metrics.sh
  . "$SCRIPT_DIR/notify-metrics.sh"
fi

cleanup() {
  rm -f "$SPEC"
}
trap cleanup EXIT

eval "$(jq -r '
  @sh "TITLE=\(.title // "")",
  @sh "SUBTITLE=\(.subtitle // "")",
  @sh "MESSAGE=\(.message // "")",
  @sh "GROUP=\(.group // "")",
  @sh "SENDER=\(.sender // "")",
  @sh "OPEN_URL=\(.open_url // "")",
  @sh "STYLE=\(.style // "banner")",
  @sh "ACTION_LABEL=\(.action_label // "Show")",
  @sh "SOUND=\(.sound // "Pop")",
  @sh "CWD=\(.cwd // "")",
  @sh "LOG=\(.log // "/tmp/fba-notify.log")",
  @sh "STATE_FILE=\(.state_file // "")",
  @sh "STATE_ID=\(.state_id // "")",
  @sh "STICKY_AFTER_CLICK=\(.sticky_after_click // "0")"
' "$SPEC")"

nlog() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true
}

extra_args=()
if [ "$STYLE" = "alert" ]; then
  extra_args+=(--actions "$ACTION_LABEL" --timeout 0)
else
  extra_args+=(--timeout 60)
fi
[ -n "$SOUND" ] && extra_args+=(--sound "$SOUND")

state_is_current() {
  [ "$STICKY_AFTER_CLICK" = "1" ] || return 1
  [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ] || return 1
  [ "$(cat "$STATE_FILE" 2>/dev/null || true)" = "$STATE_ID" ]
}

while :; do
  notify_started_ms="$(notify_now_ms 2>/dev/null || printf 0)"
  resp=$(alerter --title "$TITLE" --subtitle "$SUBTITLE" --message "$MESSAGE" \
    --ignore-dnd \
    "${extra_args[@]}" \
    ${GROUP:+--group "$GROUP"} \
    ${SENDER:+--sender "$SENDER"} --json 2>&1 || true)

  nlog "alerter response: $resp"
  act=$(printf '%s' "$resp" | jq -r '.activationType // ""' 2>/dev/null || true)
  nlog "alerter act=$act"

  if [[ "$act" = "contentsClicked" || "$act" = "actionClicked" ]] && [ -n "$OPEN_URL" ]; then
    notify_clicked_ms="$(notify_now_ms 2>/dev/null || printf 0)"
    nlog "alerter opening: $OPEN_URL"
    if command -v notify_click_open_url >/dev/null 2>&1; then
      notify_click_open_url "dispatch" "$ACTION_LABEL" "$act" "$GROUP" "$STATE_ID" "$OPEN_URL" "$notify_started_ms" "$notify_clicked_ms" "$CWD"
    else
      open "$OPEN_URL" >/dev/null 2>&1 || true
    fi
    if state_is_current; then
      nlog "alerter sticky re-post: state=$STATE_ID"
      sleep 0.6
      continue
    fi
  fi
  break
done
