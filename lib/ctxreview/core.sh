#!/usr/bin/env bash

review_agents() {  # name<TAB>pane<TAB>status<TAB>workspace<TAB>kind
  herdr agent list 2>/dev/null \
    | jq -r '.result.agents[]? | select(.name // "" | startswith("ctxreview-"))
             | "\(.name)\t\(.pane_id)\t\(.agent_status // "?")\t\(.workspace_id // "?")\t\(.agent // "?")"'
}

. "$FBA/lib/ctxreview/legs.sh"
. "$FBA/lib/ctxreview/records-events.sh"

. "$FBA/lib/ctxreview/runtime-adapters.sh"

init_session_record() {  # needs dir/ws/label/repo_root/owner_session/current_run_id
  local run_id record
  run_id="$current_run_id"
  record="$dir/session.json"
  jq -n \
    --arg run "$run_id" --arg owner "$owner_session" --arg repo "$repo_root" \
    --arg rundir "$dir" --arg workspace "$ws" --arg label "$label" \
    --arg herdr_session "$HERDR_SESSION_NAME" \
    --arg created "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg requested "$legs" \
    '($requested | split(",")) as $wanted |
     {schema:3, run_id:$run, owner_session:$owner, repo_root:$repo,
      run_dir:$rundir, label:$label, created_at:$created,
      herdr_session_name:$herdr_session,
      herdr_session_state:(if $herdr_session=="" then "default" else "running" end),
      workspace_ids:(if $workspace=="" then [] else [$workspace] end),
      requested_legs:$wanted, status:"open",
      legs:(reduce $wanted[] as $leg ({};
        .[$leg]={status:"pending",outcome:"pending"}))}' > "$record" || return 1
  chmod 600 "$record" 2>/dev/null || true
  persist_session_record "$record" || return 1
  record_event round_created "$run_id" "$owner_session" created "" "" "$ws"
}

update_session_record() {  # update_session_record <jq-filter> [jq args...]
  local filter="$1" local_record="$dir/session.json" run canonical tmp lock rc=0; shift
  [ -s "$local_record" ] || return 1
  run="$(jq -r '.run_id // empty' "$local_record" 2>/dev/null)"
  [ -n "$run" ] || return 1
  canonical="$(session_record_path "$run")"; lock="$(run_lock_path "$run")"
  acquire_file_lock "$lock" || return 1
  [ -s "$canonical" ] || cp "$local_record" "$canonical" 2>/dev/null || rc=1
  tmp="$canonical.tmp.${BASHPID:-$$}"
  if [ "$rc" -eq 0 ]; then
    jq "$@" "$filter" "$canonical" > "$tmp" 2>/dev/null \
      && chmod 600 "$tmp" && mv "$tmp" "$canonical" || rc=1
  fi
  rm -f "$tmp" 2>/dev/null || true
  if [ "$rc" -eq 0 ] && [ "$canonical" != "$local_record" ]; then
    cp "$canonical" "$local_record" 2>/dev/null || rc=1
    chmod 600 "$local_record" 2>/dev/null || true
  fi
  release_file_lock "$lock"
  return "$rc"
}

terminalize_record_leg() {  # record leg success|degraded|failure reason [artifact]
  local source="$1" leg="$2" outcome="$3" reason="$4" artifact="${5:-}"
  local run owner workspace run_dir canonical lock tmp now prior round_before round_after rc=0
  valid_leg "$leg" || return 1
  case "$outcome" in success|degraded|failure) ;; *) return 1 ;; esac
  [ -s "$source" ] || return 1
  run="$(jq -r '.run_id // empty' "$source" 2>/dev/null)"
  [ -n "$run" ] || return 1
  canonical="$(session_record_path "$run")"; lock="$(run_lock_path "$run")"
  acquire_file_lock "$lock" || return 1
  [ -s "$canonical" ] || cp "$source" "$canonical" 2>/dev/null || rc=1
  if [ "$rc" -eq 0 ]; then
    prior="$(jq -r --arg leg "$leg" '.legs[$leg].outcome // "pending"' "$canonical")"
    case "$prior" in
      success|degraded|failure)
        release_file_lock "$lock"
        return 0
        ;;
    esac
    round_before="$(jq -r '.outcome // "pending"' "$canonical")"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    tmp="$canonical.tmp.${BASHPID:-$$}"
    jq --arg leg "$leg" --arg outcome "$outcome" --arg reason "$reason" \
       --arg artifact "$artifact" --arg now "$now" '
      .schema=3 |
      .legs[$leg].status="settled" |
      .legs[$leg].outcome=$outcome |
      .legs[$leg].reason=$reason |
      .legs[$leg].finished_at=$now |
      if $artifact=="" then del(.legs[$leg].artifact)
      else .legs[$leg].artifact=$artifact end |
      (.requested_legs // (.legs|keys)) as $wanted |
      ([$wanted[] as $name | .legs[$name].outcome]) as $outcomes |
      if ($outcomes | all(. == "success" or . == "degraded" or . == "failure")) then
        .status="settled" |
        .settled_at=(.settled_at // $now) |
        .settled_at_source=(.settled_at_source // "terminal_outcomes") |
        .outcome=(if ($outcomes | index("failure")) then "failure"
                  elif ($outcomes | index("degraded")) then "degraded"
                  else "success" end)
      else . end
    ' "$canonical" > "$tmp" 2>/dev/null \
      && chmod 600 "$tmp" && mv "$tmp" "$canonical" || rc=1
  fi
  rm -f "${tmp:-}" 2>/dev/null || true
  if [ "$rc" -eq 0 ]; then
    run_dir="$(record_run_dir "$canonical" 2>/dev/null || true)"
    if [ -d "$run_dir" ]; then
      cp "$canonical" "$run_dir/session.json" 2>/dev/null || rc=1
      chmod 600 "$run_dir/session.json" 2>/dev/null || true
    fi
    owner="$(jq -r '.owner_session // empty' "$canonical")"
    workspace="$(jq -r '.workspace_ids[0] // empty' "$canonical")"
    round_after="$(jq -r '.outcome // "pending"' "$canonical")"
  fi
  release_file_lock "$lock"
  [ "$rc" -eq 0 ] || return 1
  record_event leg_terminal "$run" "$owner" "$outcome" "$reason" "$leg" "$workspace"
  case "$round_before" in success|degraded|failure) ;;
    *) case "$round_after" in
         success|degraded|failure)
           record_event round_terminal "$run" "$owner" "$round_after" all_legs "" "$workspace" ;;
       esac ;;
  esac
}

finalize_leg() {  # leg outcome reason [artifact]
  terminalize_record_leg "$(session_record_path "$current_run_id")" "$@"
}

record_leg_session() {  # record_leg_session <leg> <agent> <kind> <model> <pane> [model-arg]
  local leg="$1" agent="$2" kind="$3" model="$4" pane="$5" model_arg="${6:-}"
  local live sid="" source attempt
  # Agent detection and native-session discovery are separate Herdr updates.
  # Starting successfully does not guarantee the session id is visible in the
  # very next list response, so give persistence a short bounded settle window.
  for attempt in $(seq 1 20); do
    live="$(herdr agent list 2>/dev/null || true)"
    sid="$(printf '%s' "$live" | jq -r --arg n "$agent" \
      '.result.agents[]? | select(.name==$n) | .agent_session.value // empty' 2>/dev/null | sed -n '1p')"
    [ -n "$sid" ] && break
    sleep 0.1
  done
  source="$(printf '%s' "$live" | jq -r --arg n "$agent" \
    '.result.agents[]? | select(.name==$n) | .agent_session.source // empty' 2>/dev/null | sed -n '1p')"
  # Persist exact ownership even when Herdr has not surfaced the native session
  # id yet. Settlement and scoped cleanup refresh it before the pane disappears.
  update_session_record \
    '.legs[$leg] += {agent_name:$agent,kind:$kind,model:$model,model_arg:$model_arg,pane_id:$pane,
                  runtime_session_id:$sid,runtime_session_source:$source,
                  status:"open",started_at:$started}' \
    --arg leg "$leg" --arg agent "$agent" --arg kind "$kind" --arg model "$model" \
    --arg model_arg "$model_arg" --arg pane "$pane" --arg sid "$sid" --arg source "$source" \
    --arg started "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  local event_run event_owner event_ws
  IFS=$'\t' read -r event_run event_owner < <(record_identity "$dir/session.json")
  event_ws="$(jq -r '.workspace_ids[0] // empty' "$dir/session.json")"
  record_event leg_started "$event_run" "$event_owner" started "" "$leg" "$event_ws"
  [ -n "$sid" ]
}

refresh_leg_sessions() {  # refresh every leg in the current run record
  local record="$dir/session.json" live updates="$dir/.refresh-legs.$$.jsonl"
  [ -s "$record" ] || return 0
  live="$(herdr agent list 2>/dev/null || true)"
  : > "$updates"
  local leg agent info sid source pane
  while IFS=$'\t' read -r leg agent; do
    [ -n "$leg" ] && [ -n "$agent" ] || continue
    info="$(printf '%s' "$live" | jq -c --arg n "$agent" \
      '.result.agents[]? | select(.name==$n)' 2>/dev/null | sed -n '1p')"
    [ -n "$info" ] || continue
    sid="$(printf '%s' "$info" | jq -r '.agent_session.value // empty')"
    [ -n "$sid" ] || continue
    source="$(printf '%s' "$info" | jq -r '.agent_session.source // empty')"
    pane="$(printf '%s' "$info" | jq -r '.pane_id // empty')"
    jq -nc --arg leg "$leg" --arg sid "$sid" --arg source "$source" \
      --arg pane "$pane" '{leg:$leg,sid:$sid,source:$source,pane:$pane}' >> "$updates"
  done < <(jq -r '.legs | to_entries[]? | [.key,.value.agent_name] | @tsv' "$record")
  [ -s "$updates" ] || { rm -f "$updates"; return 0; }
  local payload; payload="$(jq -s '.' "$updates")"
  rm -f "$updates"
  update_session_record \
    'reduce $updates[] as $u (.;
       .legs[$u.leg].runtime_session_id=$u.sid |
       .legs[$u.leg].runtime_session_source=$u.source |
       .legs[$u.leg].last_live_pane=$u.pane)' \
    --argjson updates "$payload" || true
}

. "$FBA/lib/ctxreview/telemetry.sh"
. "$FBA/lib/ctxreview/reports.sh"
