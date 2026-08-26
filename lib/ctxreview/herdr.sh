#!/usr/bin/env bash

# Route every pane/agent operation through the run's named Herdr session.
herdr_bin() { type -P herdr 2>/dev/null || return 1; }

herdr() {
  local bin
  bin="$(herdr_bin)" || return 127
  if [ -n "${HERDR_SESSION_NAME:-}" ]; then
    "$bin" --session "$HERDR_SESSION_NAME" "$@"
  else
    "$bin" "$@"
  fi
}

herdr_global() {
  local bin
  bin="$(herdr_bin)" || return 127
  "$bin" "$@"
}

named_session_running() {
  local name="$1"
  herdr_global session list --json 2>/dev/null | jq -e --arg name "$name" \
    '.sessions[]? | select(.name==$name and .running==true)' >/dev/null 2>&1
}

named_session_exists() {
  local name="$1"
  herdr_global session list --json 2>/dev/null | jq -e --arg name "$name" \
    '.sessions[]? | select(.name==$name)' >/dev/null 2>&1
}

start_named_session() {
  local name="$1" bin log attempt status
  HERDR_SESSION_NAME="$name"
  if named_session_running "$name"; then return 0; fi
  bin="$(herdr_bin)" || return 1
  secure_dir "$SESSION_STATE_DIR/herdr-logs"
  log="$SESSION_STATE_DIR/herdr-logs/$name.log"
  nohup "$bin" --session "$name" server </dev/null >>"$log" 2>&1 &
  disown 2>/dev/null || true
  for attempt in $(seq 1 100); do
    status="$(herdr status server 2>/dev/null || true)"
    case "$status" in *"status: running"*) return 0 ;; esac
    sleep 0.1
  done
  say "named Herdr session $name did not start; see $log"
  return 1
}
