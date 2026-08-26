#!/usr/bin/env bash

write_global_record() {  # write_global_record <record> <jq-filter> [jq args...]
  local record="$1" filter="$2" run canonical lock tmp run_dir rc=0; shift 2
  run="$(jq -r '.run_id // empty' "$record" 2>/dev/null)"
  [ -n "$run" ] || return 1
  canonical="$(session_record_path "$run")"; lock="$(run_lock_path "$run")"
  acquire_file_lock "$lock" || return 1
  [ -s "$canonical" ] || cp "$record" "$canonical" 2>/dev/null || rc=1
  tmp="$canonical.tmp.${BASHPID:-$$}"
  if [ "$rc" -eq 0 ]; then
    jq "$@" "$filter" "$canonical" > "$tmp" 2>/dev/null \
      && chmod 600 "$tmp" && mv "$tmp" "$canonical" || rc=1
  fi
  rm -f "$tmp" 2>/dev/null || true
  run_dir="$(record_run_dir "$canonical" 2>/dev/null || true)"
  if [ -d "$run_dir" ]; then
    cp "$canonical" "$run_dir/session.json" 2>/dev/null || rc=1
    chmod 600 "$run_dir/session.json" 2>/dev/null || true
  fi
  release_file_lock "$lock"
  return "$rc"
}

cursor_leg_settled() {  # cursor_leg_settled <agent> <report-file>
  local agent="$1" report="$2" screen quiet=0 attempt
  # A report proves a write-up exists, not that a later follow-up has stopped.
  # Always consult the live footer before allowing cleanup.
  : "$report"
  # Herdr reports a composing Cursor as idle. Cursor's own footer is the
  # authoritative signal: require three consecutive quiet frames so a redraw
  # cannot be mistaken for completion.
  for attempt in 1 2 3; do
    screen="$(herdr agent read "$agent" --source visible 2>/dev/null)" || return 1
    [ -n "$screen" ] || return 1
    case "$screen" in *"Add a follow-up"*) ;; *) return 1 ;; esac
    case "$screen" in *"ctrl+c to stop"*) return 1 ;; esac
    quiet=$((quiet+1))
    [ "$quiet" -ge 3 ] && return 0
    sleep 1
  done
  return 1
}

acquire_maintain_lock() {
  secure_dir "$SESSION_STATE_DIR"
  local lock="$SESSION_STATE_DIR/maintain.lock"
  if command -v shlock >/dev/null 2>&1; then
    shlock -f "$lock" -p $$ >/dev/null 2>&1 || return 1
  else
    ( set -o noclobber; printf '%s\n' "$$" > "$lock" ) 2>/dev/null || return 1
  fi
  MAINTAIN_LOCK="$lock"
}

release_maintain_lock() {
  [ -n "$MAINTAIN_LOCK" ] || return 0
  rm -f "$MAINTAIN_LOCK" 2>/dev/null || true
  MAINTAIN_LOCK=""
}

reconcile_absent_record() {  # record live-agents live-workspaces live-panes
  local record="$1" live_agents="$2" live_ws="$3" live_panes="$4"
  local names panes workspaces has_live=0 run owner when
  names="$(jq -c '[.legs[]?.agent_name // empty]' "$record")"
  panes="$(jq -c '[.legs[]?.pane_id // empty]' "$record")"
  workspaces="$(jq -c '[.workspace_ids[]?]' "$record")"
  printf '%s' "$live_agents" | jq -e --argjson names "$names" \
    'any(.result.agents[]?; .name as $n | $names | index($n))' >/dev/null 2>&1 && has_live=1
  printf '%s' "$live_panes" | jq -e --argjson panes "$panes" \
    'any(.result.panes[]?; .pane_id as $p | $panes | index($p))' >/dev/null 2>&1 && has_live=1
  printf '%s' "$live_ws" | jq -e --argjson workspaces "$workspaces" \
    'any(.result.workspaces[]?; .workspace_id as $w | $workspaces | index($w))' >/dev/null 2>&1 && has_live=1
  [ "$has_live" -eq 0 ] || return 1

  # Once every persisted runtime is absent, no pending leg can produce another
  # artifact. Classify schema-3 legs from what survived on disk before closing
  # the ownership record; never turn absence into an implicit success.
  if [ "$(jq -r '.schema // 1' "$record")" -ge 3 ]; then
    local leg run_dir artifact
    run_dir="$(record_run_dir "$record" 2>/dev/null || true)"
    while IFS= read -r leg; do
      [ -n "$leg" ] || continue
      if [ -n "$run_dir" ] && [ -s "$run_dir/$leg.md" ]; then
        artifact="$run_dir/$leg.md"
        terminalize_record_leg "$record" "$leg" success primary_report "$artifact" || return 1
      elif [ -n "$run_dir" ] && [ -s "$run_dir/$leg.tail.md" ]; then
        artifact="$run_dir/$leg.tail.md"
        terminalize_record_leg "$record" "$leg" degraded tail_only "$artifact" || return 1
      else
        terminalize_record_leg "$record" "$leg" failure resources_absent "" || return 1
      fi
    done < <(jq -r '(.requested_legs // [])[] as $leg |
      select((.legs[$leg].outcome // "pending") == "pending") | $leg' "$record")
  fi

  IFS=$'\t' read -r run owner < <(record_identity "$record")
  when="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_global_record "$record" \
    '.schema=(if (.schema // 1)<3 then 2 else .schema end) |
     .status="closed" | .closed_at=$when | .reconciled_at=$when |
     .closed_reason="resources_absent" | .last_cleanup_outcome="reconciled" |
     .legs |= with_entries(.value.status="closed")' --arg when "$when" || return 1
  record_event round_reconciled "$run" "$owner" reconciled resources_absent
  return 0
}

observe_settled_record() {  # record live-agents
  local record="$1" live_agents="$2" count leg agent kind info status run owner when run_dir
  [ -z "$(jq -r '.settled_at // empty' "$record")" ] || return 0
  count="$(jq -r '(.legs // {}) | length' "$record")"
  [ "${count:-0}" -gt 0 ] || return 1
  while IFS=$'\t' read -r leg agent kind; do
    [ -n "$agent" ] || return 1
    info="$(printf '%s' "$live_agents" | jq -c --arg name "$agent" \
      '.result.agents[]? | select(.name==$name)' | sed -n '1p')"
    [ -n "$info" ] || return 1
    status="$(printf '%s' "$info" | jq -r '.agent_status // "unknown"')"
    case "$status" in idle|done) ;; *) return 1 ;; esac
    if [ "$kind" = cursor ] && ! cursor_leg_settled "$agent" ""; then return 1; fi
  done < <(jq -r '.legs | to_entries[]? |
    [.key,.value.agent_name,(.value.kind // "unknown")] | @tsv' "$record")

  if [ "$(jq -r '.schema // 1' "$record")" -ge 3 ]; then
    run_dir="$(record_run_dir "$record" 2>/dev/null || true)"
    while IFS= read -r leg; do
      [ -n "$leg" ] || continue
      if [ -n "$run_dir" ] && [ -s "$run_dir/$leg.md" ]; then
        terminalize_record_leg "$record" "$leg" success primary_report "$run_dir/$leg.md" || return 1
      elif [ -n "$run_dir" ] && [ -s "$run_dir/$leg.tail.md" ]; then
        terminalize_record_leg "$record" "$leg" degraded tail_only "$run_dir/$leg.tail.md" || return 1
      else
        terminalize_record_leg "$record" "$leg" failure missing_artifact "" || return 1
      fi
    done < <(jq -r '(.requested_legs // [])[] as $leg |
      select((.legs[$leg].outcome // "pending") == "pending") | $leg' "$record")
    return 0
  fi

  IFS=$'\t' read -r run owner < <(record_identity "$record")
  when="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_global_record "$record" \
    '.settled_at=$when | .status="settled" |
     .settled_at_source="maintenance_observation" |
     .legs |= with_entries(.value.status="settled")' --arg when "$when" || return 1
  record_event round_settled "$run" "$owner" observed maintenance
  return 0
}

record_has_untracked_agents() {  # record live-agents
  local record="$1" live_agents="$2" names workspaces
  [ "$(jq -r '(.workspace_ids // []) | length' "$record")" -gt 0 ] || return 1
  names="$(jq -c '[.legs[]?.agent_name // empty]' "$record")"
  workspaces="$(jq -c '[.workspace_ids[]?]' "$record")"
  printf '%s' "$live_agents" | jq -e --argjson names "$names" --argjson workspaces "$workspaces" '
    any(.result.agents[]?;
      (.workspace_id as $w | $workspaces | index($w)) and
      (.name as $n | $names | index($n) | not))' >/dev/null 2>&1
}

record_age_minutes() {  # record timestamp-field fallback-field
  local record="$1" field="$2" fallback="$3"
  jq -r --arg field "$field" --arg fallback "$fallback" '
    (.[$field] // .[$fallback] // empty) as $at |
    if $at=="" then -1 else (((now - ($at|fromdateiso8601)) / 60) | floor) end' \
    "$record" 2>/dev/null || printf '%s\n' -1
}

close_named_session_record() {  # close_named_session_record <record> [reason] [allow-unverified-idle]
  local record="$1" close_reason="${2:-manual}" allow_unverified_idle="${3:-0}"
  local run owner name run_dir
  local HERDR_SESSION_NAME live_agents info leg agent kind status busy=0 untracked=0
  local capture_dir artifact stopped_at
  run="$(jq -r '.run_id // empty' "$record")"
  owner="$(jq -r '.owner_session // empty' "$record")"
  name="$(jq -r '.herdr_session_name // empty' "$record")"
  run_dir="$(record_run_dir "$record" 2>/dev/null || true)"
  HERDR_SESSION_NAME="$name"
  record_event cleanup_attempt "$run" "$owner" started "$close_reason"

  if ! named_session_running "$name"; then
    stopped_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    write_global_record "$record" \
      '.status="closed" | .closed_at=($when) |
       .closed_reason=($reason) | .herdr_session_state="stopped" |
       .resumable=true | .last_cleanup_outcome="already_stopped"' \
      --arg when "$stopped_at" --arg reason "$close_reason" || true
    record_event round_reconciled "$run" "$owner" reconciled named_session_already_stopped
    printf '%s\tclosed\t0\n' "$run"
    return 0
  fi

  if ! live_agents="$(herdr agent list 2>/dev/null)" \
     || ! printf '%s' "$live_agents" | jq -e '.result.agents | type=="array"' >/dev/null 2>&1; then
    write_global_record "$record" \
      '.status="waiting" | .last_cleanup_outcome="deferred" |
       .last_cleanup_detail="agent_inventory_unavailable"' || true
    record_event cleanup_deferred "$run" "$owner" deferred agent_inventory_unavailable
    printf '%s\twaiting\t1\n' "$run"
    return 0
  fi

  # A named session is owned as a unit, but do not stop it if somebody added an
  # untracked agent after launch. That is the only case where session-level
  # reclamation could affect work outside this review record.
  if printf '%s' "$live_agents" | jq -e --slurpfile rec "$record" '
    [$rec[0].legs[]?.agent_name // empty] as $expected |
    any(.result.agents[]?; .name as $name | $expected | index($name) | not)' \
    >/dev/null 2>&1; then
    untracked=1
    busy=$((busy+1))
    say "keep $run — named session $name contains an untracked agent"
  fi

  capture_dir="$REAP_DIR/$run"
  secure_dir "$capture_dir"
  # The original checkout may have been temporary and removed before cleanup.
  # Keep the tail in lifecycle storage instead of recreating an abandoned tree
  # or accidentally interpreting an empty run_dir as a path under `/`.
  [ -n "$run_dir" ] && [ -d "$run_dir" ] || run_dir="$capture_dir"
  while IFS=$'\t' read -r leg agent kind; do
    [ -n "$leg" ] || continue
    info="$(printf '%s' "$live_agents" | jq -c --arg name "$agent" \
      '.result.agents[]? | select(.name==$name)' | sed -n '1p')"
    if [ -z "$info" ]; then
      case "$(jq -r --arg leg "$leg" '.legs[$leg].outcome // "pending"' "$record")" in
        success|degraded|failure) continue ;;
        *)
          if [ "$allow_unverified_idle" -eq 1 ]; then
            terminalize_record_leg "$record" "$leg" failure agent_absent_at_idle_expiry "" || true
            say "hibernate $run — $leg is absent after the owner-ended idle TTL"
            continue
          fi
          busy=$((busy+1)); say "keep $run — $leg has not reached a terminal outcome"; continue
          ;;
      esac
    fi
    status="$(printf '%s' "$info" | jq -r '.agent_status // "unknown"')"
    case "$status" in
      idle|done) ;;
      *) busy=$((busy+1)); say "keep $run — $agent is $status"; continue ;;
    esac
    if [ "$kind" = cursor ] && ! cursor_leg_settled "$agent" "$run_dir/$leg.md"; then
      if [ "$allow_unverified_idle" -eq 1 ]; then
        say "hibernate $run — $agent is idle past the owner-ended TTL"
      else
        busy=$((busy+1)); say "keep $run — $agent is still composing"; continue
      fi
    fi
    herdr agent read "$agent" --source recent-unwrapped --lines 4000 \
      > "$capture_dir/$leg.tail.md" 2>/dev/null || true
    if [ ! -s "$run_dir/$leg.md" ] && [ -s "$capture_dir/$leg.tail.md" ]; then
      cp "$capture_dir/$leg.tail.md" "$run_dir/$leg.tail.md" 2>/dev/null || true
    fi
  done < <(jq -r '.legs | to_entries[]? |
    [.key,.value.agent_name,(.value.kind // "unknown")] | @tsv' "$record")

  if [ "$busy" -gt 0 ]; then
    write_global_record "$record" \
      '.status="waiting" | .last_cleanup_outcome="deferred" |
       .last_cleanup_detail=(if $untracked then "untracked_agent_in_named_session"
                             else "resources_busy_or_unverified" end)' \
      --argjson untracked "$( [ "$untracked" -eq 1 ] && echo true || echo false )" || true
    record_event cleanup_deferred "$run" "$owner" deferred resources_busy_or_unverified
    printf '%s\twaiting\t%s\n' "$run" "$busy"
    return 0
  fi

  # Seal any still-pending outcome from the durable report or the expanded 0.8
  # terminal-history capture before hibernating the processes.
  while IFS= read -r leg; do
    [ -n "$leg" ] || continue
    artifact=""
    if [ -s "$run_dir/$leg.md" ]; then
      terminalize_record_leg "$record" "$leg" success primary_report "$run_dir/$leg.md" || true
    elif [ -s "$run_dir/$leg.tail.md" ]; then
      terminalize_record_leg "$record" "$leg" degraded tail_only "$run_dir/$leg.tail.md" || true
    else
      terminalize_record_leg "$record" "$leg" failure missing_artifact "" || true
    fi
  done < <(jq -r '(.requested_legs // [])[] as $leg |
    select((.legs[$leg].outcome // "pending")=="pending") | $leg' "$record")

  if ! herdr_global session stop "$name" --json >/dev/null 2>&1; then
    write_global_record "$record" \
      '.status="waiting" | .last_cleanup_outcome="deferred" |
       .last_cleanup_detail="session_stop_failed"' || true
    record_event cleanup_deferred "$run" "$owner" deferred session_stop_failed
    printf '%s\twaiting\t1\n' "$run"
    return 0
  fi
  stopped_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  write_global_record "$record" \
    '.status="closed" | .closed_at=$when | .closed_reason=$reason |
     .herdr_session_state="stopped" | .resumable=true |
     .last_cleanup_outcome="closed" | .last_cleanup_detail="" |
     .legs |= with_entries(.value.status="closed")' \
    --arg when "$stopped_at" --arg reason "$close_reason" || true
  record_event round_closed "$run" "$owner" closed "named_session_stop:$close_reason"
  printf '%s\tclosed\t1\n' "$run"
}
