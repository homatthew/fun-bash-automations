#!/usr/bin/env bash
# Reclaim only ctxreview panes owned by the harness session that is ending.
#
# Codex SessionEnd allows at most three seconds, so this hook records intent and
# starts cleanup detached. ctxreview skips working/blocked legs; the final leg's
# reaper retries after its report and terminal tail are durable.
set -uo pipefail

payload="$(cat)"
session_id="$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)"
case "$session_id" in
  ""|*[!A-Za-z0-9._:-]*) exit 0 ;;
esac

ctxreview_bin="$(command -v ctxreview 2>/dev/null || true)"
[ -n "$ctxreview_bin" ] || ctxreview_bin="$HOME/.local/bin/ctxreview"
[ -x "$ctxreview_bin" ] || exit 0

state_dir="${CTXREVIEW_SESSION_STATE_DIR:-$HOME/.local/state/ctxreview/sessions}"
mkdir -p "$state_dir"
nohup "$ctxreview_bin" --session-ended "$session_id" \
  >> "$state_dir/session-end.log" 2>&1 </dev/null &
exit 0
