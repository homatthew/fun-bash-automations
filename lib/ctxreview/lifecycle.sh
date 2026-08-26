#!/usr/bin/env bash

cmd_close() {
  local target="${1:-}"
  case "$target" in
    --done)
      valid_session_id "$owner_session" \
        || die "--close --done needs --session <parent-session-id> outside a harness session"
      cmd_close_session "$owner_session"
      ;;
    --all)
      local record n=0
      for record in "$(session_runs_dir)"/*.json; do
        [ -s "$record" ] || continue
        [ "$(jq -r '.status // "open"' "$record")" != closed ] || continue
        close_session_record "$record" manual_close_all >/dev/null
        [ "$(jq -r '.status // "open"' "$record")" = closed ] && n=$((n+1))
      done
      say "$n safely hibernated"
      ;;
    *)
      local record
      record="$(session_record_path "$target")"
      [ -s "$record" ] || die "no persisted review run $target"
      close_session_record "$record" manual >/dev/null
      [ "$(jq -r '.status // "open"' "$record")" = closed ] \
        && say "hibernated $target" \
        || die "$target is still working, blocked, unknown, or contains an untracked agent"
      ;;
  esac
}

. "$FBA/lib/ctxreview/maintenance-core.sh"
cmd_maintain() {
  local scope="$owner_session" global=0 ttl="$SETTLED_RETENTION_MINUTES"
  local owner_idle_ttl="$OWNER_ENDED_IDLE_MINUTES" trigger=manual
  while [ $# -gt 0 ]; do
    case "$1" in
      --session) scope="${2:?}"; shift 2 ;;
      --all) global=1; scope=""; shift ;;
      --settled-ttl) ttl="${2:?}"; shift 2 ;;
      --owner-ended-idle) owner_idle_ttl="${2:?}"; shift 2 ;;
      --trigger) trigger="${2:?}"; shift 2 ;;
      *) die "usage: $SELF --maintain [--session ID | --all] [--settled-ttl MIN] [--owner-ended-idle MIN]" ;;
    esac
  done
  case "$ttl" in ""|*[!0-9]*) die "--settled-ttl must be a non-negative integer" ;; esac
  case "$owner_idle_ttl" in
    ""|*[!0-9]*) die "--owner-ended-idle must be a non-negative integer" ;;
  esac
  [ "$global" -eq 1 ] || valid_session_id "$scope" \
    || die "--maintain needs --session <parent-session-id> outside a harness session (or explicit --all)"

  if ! acquire_maintain_lock; then
    printf 'maintenance:\n  status: busy\n  examined: 0\n'
    return 0
  fi

  local live_agents="" live_ws="" live_panes="" record_session=""

  local record run owner reason row state age owner_ended_age leg_count force_idle
  local examined=0 reconciled=0 closed=0 deferred=0 retained=0
  local actions="$WORK_C/maintenance-actions.tsv"; : > "$actions"
  for record in "$(session_runs_dir)"/*.json; do
    [ -s "$record" ] || continue
    [ "$(jq -r '.status // "open"' "$record")" != closed ] || continue
    owner="$(jq -r '.owner_session // ""' "$record")"
    [ "$global" -eq 1 ] || [ "$owner" = "$scope" ] || continue
    run="$(jq -r '.run_id // "unknown"' "$record")"
    record_session="$(jq -r '.herdr_session_name // empty' "$record")"
    [ -n "$record_session" ] || continue
    examined=$((examined+1))
    HERDR_SESSION_NAME="$record_session"
    if [ -n "$record_session" ] && ! named_session_running "$record_session"; then
      close_named_session_record "$record" already_stopped >/dev/null
      reconciled=$((reconciled+1))
      printf '%s\treconciled\tnamed_session_already_stopped\n' "$run" >> "$actions"
      continue
    fi
    if ! live_agents="$(herdr agent list 2>/dev/null)" \
       || ! printf '%s' "$live_agents" | jq -e '.result.agents | type=="array"' >/dev/null 2>&1 \
       || ! live_ws="$(herdr workspace list 2>/dev/null)" \
       || ! printf '%s' "$live_ws" | jq -e '.result.workspaces | type=="array"' >/dev/null 2>&1 \
       || ! live_panes="$(herdr pane list 2>/dev/null)" \
       || ! printf '%s' "$live_panes" | jq -e '.result.panes | type=="array"' >/dev/null 2>&1; then
      write_global_record "$record" \
        '.status="waiting" | .last_cleanup_outcome="deferred" |
         .last_cleanup_detail="inventory_unavailable"' || true
      record_event cleanup_deferred "$run" "$owner" deferred inventory_unavailable
      deferred=$((deferred+1))
      printf '%s\tdeferred\tinventory_unavailable\n' "$run" >> "$actions"
      continue
    fi

    if reconcile_absent_record "$record" "$live_agents" "$live_ws" "$live_panes"; then
      reconciled=$((reconciled+1))
      printf '%s\treconciled\tresources_absent\n' "$run" >> "$actions"
      continue
    fi

    reason=""; force_idle=0
    if [ -n "$(jq -r '.owner_ended_at // empty' "$record")" ]; then
      owner_ended_age="$(record_age_minutes "$record" owner_ended_at created_at)"
      if [ "${owner_ended_age:--1}" -ge "$owner_idle_ttl" ]; then
        reason=owner_ended_idle_expired
        force_idle=1
      else
        reason=owner_ended
      fi
    else
      observe_settled_record "$record" "$live_agents" || true
      age="$(record_age_minutes "$record" settled_at created_at)"
      leg_count="$(jq -r '(.legs // {}) | length' "$record")"
      if [ "${age:--1}" -ge "$ttl" ]; then
        if [ "${leg_count:-0}" -eq 0 ]; then reason=empty_retention
        elif [ -n "$(jq -r '.settled_at // empty' "$record")" ]; then reason=settled_retention
        fi
      fi
    fi

    if [ -z "$reason" ]; then retained=$((retained+1)); continue; fi
    if record_has_untracked_agents "$record" "$live_agents"; then
      write_global_record "$record" \
        '.status="waiting" | .last_cleanup_outcome="deferred" |
         .last_cleanup_detail="untracked_agent_in_owned_workspace"' || true
      record_event cleanup_deferred "$run" "$owner" deferred untracked_agent_in_owned_workspace
      deferred=$((deferred+1))
      printf '%s\tdeferred\tuntracked_agent_in_owned_workspace\n' "$run" >> "$actions"
      continue
    fi
    row="$(close_session_record "$record" "$reason" "$force_idle")"
    state="$(printf '%s' "$row" | awk -F'\t' 'END{print $2}')"
    if [ "$state" = closed ]; then
      closed=$((closed+1)); printf '%s\tclosed\t%s\n' "$run" "$reason" >> "$actions"
    else
      deferred=$((deferred+1)); printf '%s\tdeferred\t%s\n' "$run" "$reason" >> "$actions"
    fi
  done

  record_event maintenance "" "$scope" complete \
    "trigger=$trigger,examined=$examined,reconciled=$reconciled,closed=$closed,deferred=$deferred,retained=$retained"
  release_maintain_lock
  printf 'maintenance:\n'
  printf '  status: complete\n  scope: %s\n  retention_minutes: %s\n' "${scope:-all}" "$ttl"
  printf '  owner_ended_idle_minutes: %s\n' "$owner_idle_ttl"
  printf '  examined: %s\n  reconciled: %s\n  closed: %s\n' "$examined" "$reconciled" "$closed"
  printf '  deferred: %s\n  retained: %s\n' "$deferred" "$retained"
  local n_actions; n_actions="$(grep -c . "$actions" 2>/dev/null || true)"
  n_actions="${n_actions:-0}"
  if [ "${n_actions:-0}" -gt 0 ]; then
    printf 'actions[%s]{run,action,reason}:\n' "$n_actions"
    awk -F'\t' '{printf "  %s,%s,%s\n",$1,$2,$3}' "$actions"
  fi
}

close_session_record() {  # close_session_record <record> [reason] [allow-unverified-idle]
  local record="$1" close_reason="${2:-manual}" allow_unverified_idle="${3:-0}" run
  run="$(jq -r '.run_id // "unknown"' "$record")"
  [ -n "$(jq -r '.herdr_session_name // empty' "$record" 2>/dev/null)" ] \
    || { say "skip $run — predates named sessions"; printf '%s\tunsupported\t0\n' "$run"; return 0; }
  close_named_session_record "$record" "$close_reason" "$allow_unverified_idle"
}

cmd_close_session() {  # cmd_close_session <owner> [reason]
  local owner="${1:-}" close_reason="${2:-manual}" record n=0 rows=""
  valid_session_id "$owner" || die "invalid or missing session id"
  rows="$(mktemp "${TMPDIR:-/tmp}/ctxreview-close.XXXXXX")"
  secure_dir "$(session_runs_dir)"
  : > "$rows"
  for record in "$(session_runs_dir)"/*.json; do
    [ -s "$record" ] || continue
    [ "$(jq -r '.owner_session // ""' "$record")" = "$owner" ] || continue
    [ -n "$(jq -r '.herdr_session_name // empty' "$record")" ] || continue
    [ "$(jq -r '.status // ""' "$record")" = closed ] && continue
    close_session_record "$record" "$close_reason" >> "$rows"
    n=$((n+1))
  done
  if [ "$n" -eq 0 ]; then
    rm -f "$rows"
    printf 'cleanup: 0 open review rounds for %s\n' "$owner"
    return 0
  fi
  printf 'cleanup[%s]{run,status,count}:\n' "$n"
  awk -F'\t' '{printf "  %s,%s,%s\n",$1,$2,$3}' "$rows"
  rm -f "$rows"
}

cmd_session_ended() {  # cmd_session_ended <owner>
  local owner="${1:-}" record found=0 when
  valid_session_id "$owner" || die "invalid or missing session id"
  when="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  secure_dir "$(session_runs_dir)"
  for record in "$(session_runs_dir)"/*.json; do
    [ -s "$record" ] || continue
    [ "$(jq -r '.owner_session // ""' "$record")" = "$owner" ] || continue
    [ -n "$(jq -r '.herdr_session_name // empty' "$record")" ] || continue
    write_global_record "$record" '.owner_ended_at=$when' --arg when "$when" || true
    found=$((found+1))
  done
  if [ "$found" -gt 0 ]; then
    record_event session_end "" "$owner" matched "rounds=$found"
  else
    record_event session_end "" "$owner" unmatched no_owned_rounds
  fi
  printf 'session_end:\n  owner: %s\n  matched_rounds: %s\n' "$owner" "$found"
  # Every real SessionEnd is also a cheap fleet heartbeat. Global maintenance
  # still closes only exact ctxreview-owned resources that are owner-ended or
  # beyond settled retention; active, working, blocked, moved, and mismatched
  # resources remain untouched. This is what eventually heals a missed hook or
  # a record left open after its workspace was closed by hand.
  cmd_maintain --all --trigger session_end
}

resume_named_run() {  # resume_named_run <record>
  local record="$1" run name owner attempt agents expected restored=0
  run="$(jq -r '.run_id // empty' "$record")"
  name="$(jq -r '.herdr_session_name // empty' "$record")"
  owner="$(jq -r '.owner_session // empty' "$record")"
  [ -n "$name" ] || return 2
  start_named_session "$name" || die "could not restore Herdr session $name"

  # Native integrations restore asynchronously after the layout comes back.
  # Wait for every selected persisted agent name, but leave a usable running
  # session behind even if one runtime needs manual attention.
  expected="$(jq -r --arg wanted "$legs" '
    ($wanted|split(",")) as $selected |
    [.legs | to_entries[]? | select(.key as $k | $selected | index($k)) |
      .value.agent_name // empty] | map(select(.!="")) | length' "$record")"
  for attempt in $(seq 1 300); do
    agents="$(herdr agent list 2>/dev/null || true)"
    restored="$(printf '%s' "$agents" | jq -r --arg wanted "$legs" --slurpfile rec "$record" '
      ($wanted|split(",")) as $selected |
      [$rec[0].legs | to_entries[]? | select(.key as $k | $selected | index($k)) |
       .value.agent_name // empty] as $names |
      [.result.agents[]? | select(.name as $n | $names | index($n))] | length' \
      2>/dev/null || printf 0)"
    [ "${restored:-0}" -ge "${expected:-0}" ] && break
    sleep 0.1
  done
  write_global_record "$record" \
    '.status="open" | .herdr_session_state="running" |
     .last_resumed_at=$when | del(.closed_at,.closed_reason) |
     .legs |= with_entries(if .value.agent_name then .value.status="open" else . end)' \
    --arg when "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
  record_event round_resumed "$run" "$owner" restored "named_session=$name"
  printf 'resume:\n'
  printf '  run: %s\n  herdr_session: %s\n  restored_agents: %s\n' \
    "$run" "$name" "${restored:-0}"
  printf '  attach:\n'
  while IFS=$'\t' read -r leg agent; do
    [ -n "$agent" ] || continue
    printf '    %s: %s --attach %s %s\n' "$leg" "$SELF" "$run" "$leg"
  done < <(jq -r '.legs | to_entries[]? | [.key,.value.agent_name] | @tsv' "$record")
}

cmd_attach() {  # cmd_attach <run> <leg>
  local run="${1:-}" leg="${2:-}" record name agent sid agents bin attempt found=""
  [ -n "$run" ] || die "--attach needs a run id"
  valid_leg "$leg" || die "--attach leg must be one of: kimi,grok,sol,opus"
  record="$(session_record_path "$run")"
  [ -s "$record" ] || die "no persisted review run $run"
  name="$(jq -r '.herdr_session_name // empty' "$record")"
  [ -n "$name" ] || die "$run predates named sessions and cannot be attached"
  agent="$(jq -r --arg leg "$leg" '.legs[$leg].agent_name // empty' "$record")"
  sid="$(jq -r --arg leg "$leg" '.legs[$leg].runtime_session_id // empty' "$record")"
  [ -n "$agent" ] || die "$run has no $leg leg"
  start_named_session "$name" || die "could not restore Herdr session $name"
  for attempt in $(seq 1 300); do
    agents="$(herdr agent list 2>/dev/null || true)"
    if printf '%s' "$agents" | jq -e --arg agent "$agent" --arg sid "$sid" '
      .result.agents[]? | select(.name==$agent or ($sid!="" and .agent_session.value==$sid))' \
      >/dev/null 2>&1; then
      agent="$(printf '%s' "$agents" | jq -r --arg agent "$agent" --arg sid "$sid" '
        .result.agents[]? | select(.name==$agent or ($sid!="" and .agent_session.value==$sid)) |
        .name // .pane_id' | sed -n '1p')"
      found=1
      break
    fi
    sleep 0.1
  done
  [ -n "$found" ] || die "$leg did not restore in Herdr session $name"
  bin="$(herdr_bin)" || die "herdr not on PATH"
  trap - EXIT
  cleanup_work
  exec "$bin" --session "$name" agent attach "$agent"
}

cmd_respawn() {  # cmd_respawn <source-run>
  local source_run="${1:-}" source
  [ -n "$source_run" ] || die "--respawn needs a run id"
  source="$(session_record_path "$source_run")"
  [ -s "$source" ] || die "no persisted review run $source_run"
  [ -n "$(jq -r '.herdr_session_name // empty' "$source")" ] \
    || die "$source_run predates named sessions and cannot be restored"
  [ "$legs_explicit" -eq 0 ] \
    || die "--respawn uses the persisted requested legs; do not pass --legs"
  legs="$(jq -r '(.requested_legs // []) | join(",")' "$source")"
  validate_legs "$legs"
  resume_named_run "$source"
}

# Inspection and teardown short-circuit everything below: neither needs a repo,
# a pack, or a diff. Do not hide actions behind `command -v`: a missing runtime
# must be a clear error, not an accidental fall-through into building a review.
