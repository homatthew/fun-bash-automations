#!/usr/bin/env bash

cmd_sessions() {  # cmd_sessions [owner]
  local owner="${1:-}" files=() f rows="$WORK_C/session-rows.tsv" total=0
  secure_dir "$(session_runs_dir)"
  : > "$rows"
  for f in "$(session_runs_dir)"/*.json; do
    [ -s "$f" ] || continue
    [ -z "$owner" ] || [ "$(jq -r '.owner_session // ""' "$f")" = "$owner" ] || continue
    jq -r '[.run_id,.owner_session,.status,(.herdr_session_name // "default"),
            ((.workspace_ids // [])|join("+")),((.legs // {})|length),.repo_root] | @tsv' "$f" >> "$rows"
    total=$((total+1))
  done
  if [ "$total" -eq 0 ]; then
    printf 'sessions: 0 persisted review rounds%s\n' "$( [ -n "$owner" ] && printf ' for %s' "$owner" )"
    return 0
  fi
  printf 'sessions[%s]{run,owner,status,herdr_session,workspaces,legs,repo}:\n' "$total"
  awk -F'\t' '{printf "  %s,%s,%s,%s,%s,%s,%s\n",$1,$2,$3,$4,$5,$6,$7}' "$rows"
}
cmd_stats() {  # cmd_stats [owner]
  local owner="${1:-}" records="$WORK_C/stats-records.jsonl"
  local events="$WORK_C/stats-events.jsonl" focuses="$WORK_C/stats-focus.jsonl"
  local inventory=named_sessions live_ids='[]' f
  local target="${CTXREVIEW_FAILURE_RATE_TARGET_PERCENT:-5}"
  [ -z "$owner" ] || valid_session_id "$owner" || die "invalid session id"
  jq -en --arg value "$target" '($value|tonumber) as $n | $n>=0 and $n<=100' \
    >/dev/null 2>&1 || die "CTXREVIEW_FAILURE_RATE_TARGET_PERCENT must be between 0 and 100"
  : > "$records"; : > "$events"; : > "$focuses"
  secure_dir "$(session_runs_dir)"
  for f in "$(session_runs_dir)"/*.json; do
    [ -s "$f" ] || continue
    [ -z "$owner" ] || [ "$(jq -r '.owner_session // ""' "$f")" = "$owner" ] || continue
    jq -c '.' "$f" >> "$records" 2>/dev/null || true
  done
  if [ -s "$EVENTS_FILE" ]; then
    if [ -z "$owner" ]; then
      jq -c '.' "$EVENTS_FILE" > "$events" 2>/dev/null || true
    else
      jq -c --arg owner "$owner" 'select((.owner_session // "") == $owner)' \
        "$EVENTS_FILE" > "$events" 2>/dev/null || true
    fi
  fi
  if [ -s "$FOCUS_EVENTS_FILE" ]; then
    if [ -z "$owner" ]; then
      jq -c '.' "$FOCUS_EVENTS_FILE" > "$focuses" 2>/dev/null || true
    else
      jq -c --arg owner "$owner" 'select((.owner_session // "") == $owner)' \
        "$FOCUS_EVENTS_FILE" > "$focuses" 2>/dev/null || true
    fi
  fi

  local session_inventory
  session_inventory="$(herdr_global session list --json 2>/dev/null || printf '{"sessions":[]}')"
  live_ids="$(printf '%s' "$session_inventory" | jq -c \
    '[.sessions[]? | select(.running==true) | .name]' 2>/dev/null || printf '[]')"

  local named_stats
  named_stats="$(jq -n --slurpfile records "$records" \
    --argjson sessions "$(printf '%s' "$session_inventory" | jq -c '.sessions // []' 2>/dev/null || printf '[]')" '
    [$records[] | select((.herdr_session_name // "")!="")] as $named |
    {tracked:($named|length),
     running:([$named[] | select(.herdr_session_name as $name |
       any($sessions[]?; .name==$name and .running==true))]|length),
     stopped:([$named[] | select(.herdr_session_name as $name |
       (any($sessions[]?; .name==$name and .running==true)|not))]|length)}')"

  local record_stats event_stats focus_stats observed_runs
  observed_runs="$(jq -s -c '[.[] | select(.event=="round_settled" and
    .outcome=="observed") | .run_id] | unique' "$events")"
  record_stats="$(jq -s --argjson live "$live_ids" --argjson observed "$observed_runs" \
    --argjson target "$target" '
    def epoch: fromdateiso8601;
    def percentile($xs; $p):
      ($xs | sort) as $s |
      if ($s|length)==0 then null
      else $s[((($s|length)-1) * $p | floor)] end;
    . as $records |
    (map(select(.settled_at and .created_at and
      (.run_id as $run | $observed | index($run) | not)) |
      ((.settled_at|epoch) - (.created_at|epoch)))) as $settle |
    (map(select(.closed_at and (.owner_ended_at // .settled_at)) |
      ((.closed_at|epoch) - ((.owner_ended_at // .settled_at)|epoch)))) as $cleanup |
    (map(select((.schema // 1)>=3 and
      ((.requested_legs // null)|type)=="array" and
      ((.requested_legs // [])|length)>0))) as $eligible |
    ([$eligible[] as $round | $round.requested_legs[] as $leg |
      {outcome:($round.legs[$leg].outcome // "pending")}]) as $leg_outcomes |
    ($leg_outcomes | map(select(.outcome=="success")) | length) as $success |
    ($leg_outcomes | map(select(.outcome=="degraded")) | length) as $degraded |
    ($leg_outcomes | map(select(.outcome=="failure")) | length) as $failure |
    ($success+$degraded+$failure) as $terminal |
    ($leg_outcomes|length) as $requested |
    (if $terminal==0 then null
     else (($failure*10000/$terminal)|round/100) end) as $failure_rate |
    ($eligible | map(select((.herdr_session_name // "")!=""))) as $named_eligible |
    ([$named_eligible[] as $round | $round.requested_legs[] as $leg |
      {outcome:($round.legs[$leg].outcome // "pending")}]) as $named_outcomes |
    ($named_outcomes | map(select(.outcome=="success")) | length) as $named_success |
    ($named_outcomes | map(select(.outcome=="degraded")) | length) as $named_degraded |
    ($named_outcomes | map(select(.outcome=="failure")) | length) as $named_failure |
    ($named_success+$named_degraded+$named_failure) as $named_terminal |
    ($named_outcomes|length) as $named_requested |
    (if $named_terminal==0 then null
     else (($named_failure*10000/$named_terminal)|round/100) end) as $named_failure_rate |
    {
      total:length,
      active:(map(select((.status // "open")=="open"))|length),
      settled:(map(select(.status=="settled"))|length),
      waiting:(map(select(.status=="waiting"))|length),
      closed:(map(select(.status=="closed"))|length),
      owner_ended_waiting:(map(select(.status!="closed" and .owner_ended_at))|length),
      respawned:(map(select(.resumed_from))|length),
      settled_observed:(map(select(.run_id as $run | $observed | index($run)))|length),
      live:(map(select(.status!="closed" and
        (.herdr_session_name as $name | $live | index($name))))|length),
      stale:(map(select(.status!="closed" and (.herdr_session_name // "")!="" and
        (.herdr_session_name as $name | $live | index($name) | not)))|length),
      settle_samples:($settle|length), settle_p50:percentile($settle;0.50),
      settle_p95:percentile($settle;0.95),
      cleanup_samples:($cleanup|length), cleanup_p50:percentile($cleanup;0.50),
      cleanup_p95:percentile($cleanup;0.95),
      okr:{
        target_failure_rate_percent:$target,
        status:(if $terminal==0 then "insufficient_data"
                elif ($failure_rate <= $target) then "met" else "missed" end),
        sample_size:$terminal,
        numerator_failures:$failure,
        denominator_terminal:$terminal,
        failure_rate_percent:$failure_rate,
        successful:$success,
        degraded:$degraded,
        pending:($requested-$terminal),
        requested:$requested,
        classification_coverage_percent:(if $requested==0 then null
          else (($terminal*10000/$requested)|round/100) end),
        eligible_rounds:($eligible|length),
        default_four_leg_rounds:($eligible | map(select(
          ((.requested_legs|sort)==["grok","kimi","opus","sol"]))) | length),
        subset_rounds:($eligible | map(select(
          ((.requested_legs|sort)!=["grok","kimi","opus","sol"]))) | length),
        pre_named_unclassified_rounds:($records | map(select(
          ((.schema // 1)<3) or ((.requested_legs // null)|type)!="array")) | length)
      },
      named_okr:{
        target_failure_rate_percent:$target,
        status:(if $named_terminal==0 then "insufficient_data"
                elif ($named_failure_rate <= $target) then "met" else "missed" end),
        sample_size:$named_terminal,
        numerator_failures:$named_failure,
        denominator_terminal:$named_terminal,
        failure_rate_percent:$named_failure_rate,
        successful:$named_success,
        degraded:$named_degraded,
        pending:($named_requested-$named_terminal),
        requested:$named_requested,
        eligible_rounds:($named_eligible|length)
      }
    }' "$records")"
  event_stats="$(jq -s '
    def percentile($xs; $p):
      ($xs | sort) as $s |
      if ($s|length)==0 then null
      else $s[((($s|length)-1) * $p | floor)] end;
    . as $events |
    (map(select(.run_id and .leg)) | group_by([.run_id,.leg]) | map(
      ([.[] | select(.event=="leg_started") | .at] | min) as $started |
      ([.[] | select(.event=="leg_terminal" or .event=="leg_settled") | .at] | min) as $settled |
      select($started and $settled) |
      (($settled|fromdateiso8601) - ($started|fromdateiso8601)))) as $leg_duration |
    {total:length,
     attempts:(map(select(.event=="cleanup_attempt"))|length),
     closed:(map(select(.event=="round_closed"))|length),
     reconciled:(map(select(.event=="round_reconciled"))|length),
     deferred:(map(select(.event=="cleanup_deferred"))|length),
     retention:(map(select(.event=="round_closed" and
       (.reason=="named_session_stop:settled_retention" or
        .reason=="named_session_stop:empty_retention")))|length),
     aged_idle:(map(select(.event=="round_closed" and
       .reason=="named_session_stop:owner_ended_idle_expired"))|length),
     unmatched_session_end:(map(select(.event=="session_end" and .outcome=="unmatched"))|length),
     leg_samples:($leg_duration|length), leg_p50:percentile($leg_duration;0.50),
     leg_p95:percentile($leg_duration;0.95),
     last:(map(.at // "") | max // "none")}' "$events")"
  focus_stats="$(jq -s '{
    close_operations:length,
    focus_drifts:(map(select(.focus_drift == true))|length),
    restored:(map(select(.restore_outcome == "restored"))|length),
    restore_failed:(map(select(.restore_outcome == "failed"))|length),
    last_drift_at:(map(select(.focus_drift == true) | .at // "") | max // "none")
  }' "$focuses")"

  printf 'telemetry:\n'
  printf '  scope: %s\n' "${owner:-all}"
  printf '  inventory: %s\n' "$inventory"
  printf '  retention_minutes: %s\n' "$SETTLED_RETENTION_MINUTES"
  printf '  owner_ended_idle_minutes: %s\n' "$OWNER_ENDED_IDLE_MINUTES"
  printf '  named_sessions:\n'
  printf '    tracked: %s\n' "$(jq -r '.tracked' <<< "$named_stats")"
  printf '    running: %s\n' "$(jq -r '.running' <<< "$named_stats")"
  printf '    stopped: %s\n' "$(jq -r '.stopped' <<< "$named_stats")"
  printf '  events_file: %s\n' "$(jq -Rnr --arg v "$EVENTS_FILE" '$v|@json')"
  printf '  events: %s\n' "$(jq -r '.total' <<< "$event_stats")"
  printf '  last_event_at: %s\n' "$(jq -r '.last' <<< "$event_stats")"
  printf '  rounds:\n'
  printf '    total: %s\n' "$(jq -r '.total' <<< "$record_stats")"
  printf '    active: %s\n' "$(jq -r '.active' <<< "$record_stats")"
  printf '    settled: %s\n' "$(jq -r '.settled' <<< "$record_stats")"
  printf '    waiting: %s\n' "$(jq -r '.waiting' <<< "$record_stats")"
  printf '    closed: %s\n' "$(jq -r '.closed' <<< "$record_stats")"
  printf '    live: %s\n' "$(jq -r '.live' <<< "$record_stats")"
  printf '    stale: %s\n' "$(jq -r '.stale' <<< "$record_stats")"
  printf '    owner_ended_waiting: %s\n' "$(jq -r '.owner_ended_waiting' <<< "$record_stats")"
  printf '    respawned: %s\n' "$(jq -r '.respawned' <<< "$record_stats")"
  printf '    settled_observed: %s\n' "$(jq -r '.settled_observed' <<< "$record_stats")"
  printf '  okr:\n'
  printf '    objective: keep_ctxreview_terminal_failure_rate_at_or_below_target\n'
  printf '    target_failure_rate_percent: %s\n' "$(jq -r '.okr.target_failure_rate_percent' <<< "$record_stats")"
  printf '    status: %s\n' "$(jq -r '.okr.status' <<< "$record_stats")"
  printf '    sample_size: %s\n' "$(jq -r '.okr.sample_size' <<< "$record_stats")"
  printf '    numerator_failures: %s\n' "$(jq -r '.okr.numerator_failures' <<< "$record_stats")"
  printf '    denominator_terminal: %s\n' "$(jq -r '.okr.denominator_terminal' <<< "$record_stats")"
  printf '    failure_rate_percent: %s\n' "$(jq -r '.okr.failure_rate_percent // "none"' <<< "$record_stats")"
  printf '    successful: %s\n' "$(jq -r '.okr.successful' <<< "$record_stats")"
  printf '    degraded: %s\n' "$(jq -r '.okr.degraded' <<< "$record_stats")"
  printf '    pending: %s\n' "$(jq -r '.okr.pending' <<< "$record_stats")"
  printf '    requested: %s\n' "$(jq -r '.okr.requested' <<< "$record_stats")"
  printf '    classification_coverage_percent: %s\n' "$(jq -r '.okr.classification_coverage_percent // "none"' <<< "$record_stats")"
  printf '    eligible_rounds: %s\n' "$(jq -r '.okr.eligible_rounds' <<< "$record_stats")"
  printf '    default_four_leg_rounds: %s\n' "$(jq -r '.okr.default_four_leg_rounds' <<< "$record_stats")"
  printf '    subset_rounds: %s\n' "$(jq -r '.okr.subset_rounds' <<< "$record_stats")"
  printf '    pre_named_unclassified_rounds: %s\n' "$(jq -r '.okr.pre_named_unclassified_rounds' <<< "$record_stats")"
  printf '  named_session_okr:\n'
  printf '    status: %s\n' "$(jq -r '.named_okr.status' <<< "$record_stats")"
  printf '    sample_size: %s\n' "$(jq -r '.named_okr.sample_size' <<< "$record_stats")"
  printf '    numerator_failures: %s\n' "$(jq -r '.named_okr.numerator_failures' <<< "$record_stats")"
  printf '    denominator_terminal: %s\n' "$(jq -r '.named_okr.denominator_terminal' <<< "$record_stats")"
  printf '    failure_rate_percent: %s\n' "$(jq -r '.named_okr.failure_rate_percent // "none"' <<< "$record_stats")"
  printf '    successful: %s\n' "$(jq -r '.named_okr.successful' <<< "$record_stats")"
  printf '    degraded: %s\n' "$(jq -r '.named_okr.degraded' <<< "$record_stats")"
  printf '    pending: %s\n' "$(jq -r '.named_okr.pending' <<< "$record_stats")"
  printf '    requested: %s\n' "$(jq -r '.named_okr.requested' <<< "$record_stats")"
  printf '    eligible_rounds: %s\n' "$(jq -r '.named_okr.eligible_rounds' <<< "$record_stats")"
  printf '  cleanup:\n'
  printf '    attempts: %s\n' "$(jq -r '.attempts' <<< "$event_stats")"
  printf '    closed: %s\n' "$(jq -r '.closed' <<< "$event_stats")"
  printf '    reconciled: %s\n' "$(jq -r '.reconciled' <<< "$event_stats")"
  printf '    deferred: %s\n' "$(jq -r '.deferred' <<< "$event_stats")"
  printf '    retention_closed: %s\n' "$(jq -r '.retention' <<< "$event_stats")"
  printf '    aged_owner_ended_idle_closed: %s\n' "$(jq -r '.aged_idle' <<< "$event_stats")"
  printf '    unmatched_session_end: %s\n' "$(jq -r '.unmatched_session_end' <<< "$event_stats")"
  printf '  focus_isolation:\n'
  printf '    strategy: named_herdr_session_socket\n'
  printf '    default_session_mutations: 0\n'
  printf '    historical_focus_events_file: %s\n' "$(jq -Rnr --arg v "$FOCUS_EVENTS_FILE" '$v|@json')"
  printf '    historical_close_operations: %s\n' "$(jq -r '.close_operations' <<< "$focus_stats")"
  printf '    historical_focus_drifts: %s\n' "$(jq -r '.focus_drifts' <<< "$focus_stats")"
  printf '    historical_restore_failed: %s\n' "$(jq -r '.restore_failed' <<< "$focus_stats")"
  printf '  duration_seconds:\n'
  printf '    leg_samples: %s\n' "$(jq -r '.leg_samples' <<< "$event_stats")"
  printf '    leg_p50: %s\n' "$(jq -r '.leg_p50 // "none"' <<< "$event_stats")"
  printf '    leg_p95: %s\n' "$(jq -r '.leg_p95 // "none"' <<< "$event_stats")"
  printf '    settle_samples: %s\n' "$(jq -r '.settle_samples' <<< "$record_stats")"
  printf '    settle_p50: %s\n' "$(jq -r '.settle_p50 // "none"' <<< "$record_stats")"
  printf '    settle_p95: %s\n' "$(jq -r '.settle_p95 // "none"' <<< "$record_stats")"
  printf '    cleanup_samples: %s\n' "$(jq -r '.cleanup_samples' <<< "$record_stats")"
  printf '    cleanup_p50: %s\n' "$(jq -r '.cleanup_p50 // "none"' <<< "$record_stats")"
  printf '    cleanup_p95: %s\n' "$(jq -r '.cleanup_p95 // "none"' <<< "$record_stats")"
}
