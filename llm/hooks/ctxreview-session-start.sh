#!/usr/bin/env bash
# Detached lifecycle heartbeat: reconcile stale records and enforce safe
# owner-ended/settled-retention cleanup whenever a harness session starts.
set -uo pipefail

# Consume the hook payload so a producer never blocks even though this event
# does not need its fields.
cat >/dev/null

ctxreview_bin="$(command -v ctxreview 2>/dev/null || true)"
[ -n "$ctxreview_bin" ] || ctxreview_bin="$HOME/.local/bin/ctxreview"
[ -x "$ctxreview_bin" ] || exit 0

state_dir="${CTXREVIEW_SESSION_STATE_DIR:-$HOME/.local/state/ctxreview/sessions}"
mkdir -p "$state_dir"
nohup "$ctxreview_bin" --maintain --all \
  >> "$state_dir/session-start.log" 2>&1 </dev/null &
exit 0
