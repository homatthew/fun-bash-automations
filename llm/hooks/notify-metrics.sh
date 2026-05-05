#!/bin/bash
# Shared timing helpers for notification click/focus paths.

notify_now_ms() {
  python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
}

notify_metric_log_file() {
  printf '%s' "${NOTIFY_METRICS_LOG:-/tmp/fba-notify-metrics.jsonl}"
}

notify_vscode_bundle_id() {
  printf '%s' "${NOTIFY_VSCODE_BUNDLE_ID:-com.microsoft.VSCode}"
}

notify_vscode_recovery_mode() {
  case "${NOTIFY_VSCODE_RECOVERY:-folder-first}" in
    0|false|FALSE|no|NO|off|OFF) printf 'off' ;;
    async|ASYNC|background|BACKGROUND) printf 'async' ;;
    uri-first|URI-FIRST|uri_first|URI_FIRST) printf 'uri-first' ;;
    sync|SYNC|blocking|BLOCKING|folder-first|FOLDER-FIRST|folder_first|FOLDER_FIRST) printf 'folder-first' ;;
    *) printf 'folder-first' ;;
  esac
}

notify_vscode_focus_request_dir() {
  printf '%s' "${NOTIFY_VSCODE_FOCUS_REQUEST_DIR:-/tmp/fba-vscode-focus-requests}"
}

notify_write_vscode_focus_request() {
  local source="$1" action="$2" activation="$3" group="$4" state_id="$5" open_url="$6" cwd="$7" clicked_ms="$8"
  local dir id tmp out
  dir="$(notify_vscode_focus_request_dir)"
  mkdir -p "$dir" 2>/dev/null || return 0
  id="$(date '+%s' 2>/dev/null || printf 0)-$$-$RANDOM"
  tmp="$dir/$id.json.tmp"
  out="$dir/$id.json"
  jq -n \
    --arg source "$source" \
    --arg action "$action" \
    --arg activation "$activation" \
    --arg group "$group" \
    --arg state_id "$state_id" \
    --arg open_url "$open_url" \
    --arg cwd "$cwd" \
    --argjson clicked_ms "${clicked_ms:-0}" \
    '{
      source: $source,
      action: $action,
      activation: $activation,
      group: $group,
      state_id: $state_id,
      open_url: $open_url,
      cwd: $cwd,
      clicked_ms: $clicked_ms,
      created_at: (now | todateiso8601)
    }' > "$tmp" 2>/dev/null && mv "$tmp" "$out" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
}

notify_activate_vscode() {
  local bundle_id="$1"
  osascript -e "tell application id \"$bundle_id\" to activate" >/dev/null 2>&1 || true
}

notify_async_activate_vscode() {
  local bundle_id="$1"
  notify_activate_vscode "$bundle_id" >/dev/null 2>&1 &
}

notify_metric_json() {
  local event="$1" source="$2" action="$3" activation="$4" group="$5" state_id="$6" open_url="$7" started_ms="$8" clicked_ms="$9" open_started_ms="${10}" open_done_ms="${11}" folder_open_started_ms="${12:-0}" folder_open_done_ms="${13:-0}" activate_started_ms="${14:-0}" activate_done_ms="${15:-0}" sleep_started_ms="${16:-0}" sleep_done_ms="${17:-0}" second_open_started_ms="${18:-0}" second_open_done_ms="${19:-0}" recovery_enabled="${20:-0}" recovery_mode="${21:-off}"
  local log_file
  log_file="$(notify_metric_log_file)"
  jq -cn \
    --arg ts "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
    --arg event "$event" \
    --arg source "$source" \
    --arg action "$action" \
    --arg activation "$activation" \
    --arg group "$group" \
    --arg state_id "$state_id" \
    --arg open_url "$open_url" \
    --argjson started_ms "${started_ms:-0}" \
    --argjson clicked_ms "${clicked_ms:-0}" \
    --argjson open_started_ms "${open_started_ms:-0}" \
    --argjson open_done_ms "${open_done_ms:-0}" \
    --argjson folder_open_started_ms "${folder_open_started_ms:-0}" \
    --argjson folder_open_done_ms "${folder_open_done_ms:-0}" \
    --argjson activate_started_ms "${activate_started_ms:-0}" \
    --argjson activate_done_ms "${activate_done_ms:-0}" \
    --argjson sleep_started_ms "${sleep_started_ms:-0}" \
    --argjson sleep_done_ms "${sleep_done_ms:-0}" \
    --argjson second_open_started_ms "${second_open_started_ms:-0}" \
    --argjson second_open_done_ms "${second_open_done_ms:-0}" \
    --arg recovery_enabled "$recovery_enabled" \
    --arg recovery_mode "$recovery_mode" \
    '
    def diff($a; $b): if $a > 0 and $b > 0 then ($b - $a) else null end;
    def maybe_ms($v): if $v > 0 then $v else null end;
    {
      ts: $ts,
      event: $event,
      source: $source,
      action: $action,
      activation: $activation,
      group: $group,
      state_id: $state_id,
      open_url_scheme: ($open_url | split(":")[0]),
      started_ms: $started_ms,
      clicked_ms: $clicked_ms,
      open_started_ms: $open_started_ms,
      open_done_ms: $open_done_ms,
      folder_open_started_ms: maybe_ms($folder_open_started_ms),
      folder_open_done_ms: maybe_ms($folder_open_done_ms),
      activate_started_ms: maybe_ms($activate_started_ms),
      activate_done_ms: maybe_ms($activate_done_ms),
      sleep_started_ms: maybe_ms($sleep_started_ms),
      sleep_done_ms: maybe_ms($sleep_done_ms),
      second_open_started_ms: maybe_ms($second_open_started_ms),
      second_open_done_ms: maybe_ms($second_open_done_ms),
      vscode_recovery_enabled: ($recovery_enabled == "1"),
      vscode_recovery_mode: $recovery_mode,
      notification_to_click_ms: diff($started_ms; $clicked_ms),
      click_to_open_start_ms: diff($clicked_ms; $open_started_ms),
      click_to_open_done_ms: diff($clicked_ms; $open_done_ms),
      click_to_folder_open_start_ms: diff($clicked_ms; $folder_open_started_ms),
      click_to_folder_open_done_ms: diff($clicked_ms; $folder_open_done_ms),
      folder_open_duration_ms: diff($folder_open_started_ms; $folder_open_done_ms),
      click_to_activate_start_ms: diff($clicked_ms; $activate_started_ms),
      click_to_activate_done_ms: diff($clicked_ms; $activate_done_ms),
      app_activate_duration_ms: diff($activate_started_ms; $activate_done_ms),
      sleep_duration_ms: diff($sleep_started_ms; $sleep_done_ms),
      click_to_second_open_start_ms: diff($clicked_ms; $second_open_started_ms),
      click_to_second_open_done_ms: diff($clicked_ms; $second_open_done_ms)
    }' >> "$log_file" 2>/dev/null || true
}

notify_run_vscode_recovery() {
  local source="$1" action="$2" activation="$3" group="$4" state_id="$5" open_url="$6" started_ms="$7" clicked_ms="$8" cwd="$9" mode="${10}"
  local folder_open_started_ms folder_open_done_ms activate_started_ms activate_done_ms sleep_started_ms sleep_done_ms second_open_started_ms second_open_done_ms bundle_id

  notify_write_vscode_focus_request "$source" "$action" "$activation" "$group" "$state_id" "$open_url" "$cwd" "$clicked_ms"
  bundle_id="$(notify_vscode_bundle_id)"
  folder_open_started_ms="$(notify_now_ms 2>/dev/null || printf 0)"
  open -b "$bundle_id" "$cwd" >/dev/null 2>&1 || true
  folder_open_done_ms="$(notify_now_ms 2>/dev/null || printf 0)"
  activate_started_ms="$(notify_now_ms 2>/dev/null || printf 0)"
  notify_async_activate_vscode "$bundle_id"
  activate_done_ms="$(notify_now_ms 2>/dev/null || printf 0)"
  sleep_started_ms="$(notify_now_ms 2>/dev/null || printf 0)"
  sleep 0.4
  sleep_done_ms="$(notify_now_ms 2>/dev/null || printf 0)"
  second_open_started_ms="$(notify_now_ms 2>/dev/null || printf 0)"
  open "$open_url" >/dev/null 2>&1 || true
  second_open_done_ms="$(notify_now_ms 2>/dev/null || printf 0)"

  notify_metric_json "notification_vscode_recovery" "$source" "$action" "$activation" "$group" "$state_id" "$open_url" "$started_ms" "$clicked_ms" 0 0 "$folder_open_started_ms" "$folder_open_done_ms" "$activate_started_ms" "$activate_done_ms" "$sleep_started_ms" "$sleep_done_ms" "$second_open_started_ms" "$second_open_done_ms" 1 "$mode"
}

notify_click_open_url() {
  local source="$1" action="$2" activation="$3" group="$4" state_id="$5" open_url="$6" started_ms="$7" clicked_ms="$8" cwd="${9:-}"
  local open_started_ms open_done_ms folder_open_started_ms=0 folder_open_done_ms=0 activate_started_ms=0 activate_done_ms=0 sleep_started_ms=0 sleep_done_ms=0 second_open_started_ms=0 second_open_done_ms=0 recovery_enabled=0 recovery_mode bundle_id

  recovery_mode="$(notify_vscode_recovery_mode)"
  if [ "$recovery_mode" != "off" ] && [ -n "$cwd" ] && [[ "$open_url" == vscode:* ]]; then
    recovery_enabled=1
    case "$recovery_mode" in
      folder-first)
        notify_write_vscode_focus_request "$source" "$action" "$activation" "$group" "$state_id" "$open_url" "$cwd" "$clicked_ms"
        bundle_id="$(notify_vscode_bundle_id)"
        folder_open_started_ms="$(notify_now_ms 2>/dev/null || printf 0)"
        open_started_ms="$folder_open_started_ms"
        open -b "$bundle_id" "$cwd" >/dev/null 2>&1 || true
        folder_open_done_ms="$(notify_now_ms 2>/dev/null || printf 0)"
        open_done_ms="$folder_open_done_ms"
        activate_started_ms="$(notify_now_ms 2>/dev/null || printf 0)"
        notify_async_activate_vscode "$bundle_id"
        activate_done_ms="$(notify_now_ms 2>/dev/null || printf 0)"
        sleep_started_ms="$(notify_now_ms 2>/dev/null || printf 0)"
        sleep "${NOTIFY_VSCODE_FOCUS_SETTLE_SECONDS:-0.1}"
        sleep_done_ms="$(notify_now_ms 2>/dev/null || printf 0)"
        second_open_started_ms="$(notify_now_ms 2>/dev/null || printf 0)"
        open "$open_url" >/dev/null 2>&1 || true
        second_open_done_ms="$(notify_now_ms 2>/dev/null || printf 0)"
        ;;
      uri-first)
        open_started_ms="$(notify_now_ms 2>/dev/null || printf 0)"
        open "$open_url" >/dev/null 2>&1 || true
        open_done_ms="$(notify_now_ms 2>/dev/null || printf 0)"
        notify_write_vscode_focus_request "$source" "$action" "$activation" "$group" "$state_id" "$open_url" "$cwd" "$clicked_ms"
        bundle_id="$(notify_vscode_bundle_id)"
        folder_open_started_ms="$(notify_now_ms 2>/dev/null || printf 0)"
        open -b "$bundle_id" "$cwd" >/dev/null 2>&1 || true
        folder_open_done_ms="$(notify_now_ms 2>/dev/null || printf 0)"
        activate_started_ms="$(notify_now_ms 2>/dev/null || printf 0)"
        notify_async_activate_vscode "$bundle_id"
        activate_done_ms="$(notify_now_ms 2>/dev/null || printf 0)"
        sleep_started_ms="$(notify_now_ms 2>/dev/null || printf 0)"
        sleep "${NOTIFY_VSCODE_FOCUS_SETTLE_SECONDS:-0.4}"
        sleep_done_ms="$(notify_now_ms 2>/dev/null || printf 0)"
        second_open_started_ms="$(notify_now_ms 2>/dev/null || printf 0)"
        open "$open_url" >/dev/null 2>&1 || true
        second_open_done_ms="$(notify_now_ms 2>/dev/null || printf 0)"
        ;;
      async)
        open_started_ms="$(notify_now_ms 2>/dev/null || printf 0)"
        open "$open_url" >/dev/null 2>&1 || true
        open_done_ms="$(notify_now_ms 2>/dev/null || printf 0)"
        notify_run_vscode_recovery "$source" "$action" "$activation" "$group" "$state_id" "$open_url" "$started_ms" "$clicked_ms" "$cwd" "$recovery_mode" >/dev/null 2>&1 &
        ;;
    esac
  else
    recovery_mode="off"
    open_started_ms="$(notify_now_ms 2>/dev/null || printf 0)"
    open "$open_url" >/dev/null 2>&1 || true
    open_done_ms="$(notify_now_ms 2>/dev/null || printf 0)"
  fi

  notify_metric_json "notification_click_open" "$source" "$action" "$activation" "$group" "$state_id" "$open_url" "$started_ms" "$clicked_ms" "$open_started_ms" "$open_done_ms" "$folder_open_started_ms" "$folder_open_done_ms" "$activate_started_ms" "$activate_done_ms" "$sleep_started_ms" "$sleep_done_ms" "$second_open_started_ms" "$second_open_done_ms" "$recovery_enabled" "$recovery_mode"
}
