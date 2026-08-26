#!/usr/bin/env bash

session_runs_dir() { printf '%s/runs' "$SESSION_STATE_DIR"; }
session_record_path() { printf '%s/%s.json' "$(session_runs_dir)" "$1"; }

record_run_dir() {
  local record="$1" run_dir repo_root
  run_dir="$(jq -r '.run_dir // empty' "$record" 2>/dev/null)"
  [ -n "$run_dir" ] || return 1
  case "$run_dir" in
    /*) printf '%s\n' "$run_dir" ;;
    *)
      repo_root="$(jq -r '.repo_root // empty' "$record" 2>/dev/null)"
      [ -n "$repo_root" ] || return 1
      printf '%s/%s\n' "${repo_root%/}" "$run_dir"
      ;;
  esac
}

acquire_file_lock() {
  local lock="$1" attempt pid="${BASHPID:-$$}"
  mkdir -p "$(dirname "$lock")"
  for attempt in $(seq 1 100); do
    if command -v shlock >/dev/null 2>&1; then
      shlock -f "$lock" -p "$pid" >/dev/null 2>&1 && return 0
    else
      ( set -o noclobber; printf '%s\n' "$pid" > "$lock" ) 2>/dev/null && return 0
    fi
    sleep 0.05
  done
  return 1
}

release_file_lock() { rm -f "$1" 2>/dev/null || true; }
run_lock_path() { printf '%s/locks/%s.lock' "$SESSION_STATE_DIR" "$1"; }

append_line_locked() {
  local file="$1" line="$2" lock="${1}.lock"
  acquire_file_lock "$lock" || return 1
  printf '%s\n' "$line" >> "$file" 2>/dev/null
  local rc=$?
  release_file_lock "$lock"
  return "$rc"
}

record_event() {
  local event="$1" run="${2:-}" owner="${3:-}" outcome="${4:-}" reason="${5:-}"
  local leg="${6:-}" workspace="${7:-}" line event_id=""
  mkdir -p "$(dirname "$EVENTS_FILE")"
  case "$event" in
    leg_terminal) event_id="$run:$leg:terminal" ;;
    round_terminal) event_id="$run:round:terminal" ;;
  esac
  line="$(jq -nc \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg event "$event" \
    --arg run "$run" --arg owner "$owner" --arg outcome "$outcome" \
    --arg reason "$reason" --arg leg "$leg" --arg workspace "$workspace" \
    --arg event_id "$event_id" \
    '{schema:1,at:$at,event:$event,run_id:$run,owner_session:$owner,
      outcome:$outcome,reason:$reason,leg:$leg,workspace_id:$workspace,
      event_id:$event_id} |
     with_entries(select(.value != ""))' 2>/dev/null)" || return 0
  append_line_locked "$EVENTS_FILE" "$line" || return 0
  chmod 600 "$EVENTS_FILE" 2>/dev/null || true
}

record_identity() {
  jq -r '[.run_id // "",.owner_session // ""] | @tsv' "$1" 2>/dev/null
}

persist_session_record() {
  local record="$1" run_id target tmp
  run_id="$(jq -r '.run_id // empty' "$record" 2>/dev/null)"
  [ -n "$run_id" ] || return 1
  mkdir -p "$(session_runs_dir)"
  target="$(session_record_path "$run_id")"
  tmp="$target.tmp.$$"
  cp "$record" "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$target"
}
