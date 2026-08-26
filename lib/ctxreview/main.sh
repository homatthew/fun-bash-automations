#!/usr/bin/env bash
# ctxreview — one context pack, four independent reviewers, four watchable panes.
#
#   ctxreview run --legs LIST
#     -> ctxpack build -> prompt -> named Herdr session -> reviewer panes
#
# Each leg gets the identical pack and diff and never sees another leg's output,
# so the opinions stay independent. Panes remain conversible through the parent
# session, then the lifecycle manager reclaims exact persisted resources.
#
# Model allocation is not arbitrary. `run-review.sh` serialises Cursor `-p` runs
# behind a lockfile because they race on `~/.cursor/cli-config.json`, so only the
# two models Cursor alone provides go through Cursor here. Sol runs on the Codex
# CLI and Opus on the Claude CLI, natively and concurrently.
#
# See: llm/skills/code-review/SKILL.md, llm/skills/cursor-sub-review/SKILL.md
set -uo pipefail
umask 077

SELF="${CTXREVIEW_SELF:-${0##*/}}"
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  SOURCE_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  case "$SOURCE" in /*) ;; *) SOURCE="$SOURCE_DIR/$SOURCE" ;; esac
done
FBA="$(cd -P "$(dirname "$SOURCE")/../.." && pwd)"
SPAWN="${CTXREVIEW_CURSOR_SPAWN:-$FBA/llm/skills/cursor-sub-review/scripts/spawn-cursor-pane.sh}"

# Resolve with `cursor-agent --list-models` / your codex + claude builds.
CURSOR_KIMI="${CTXREVIEW_KIMI:-kimi-k3-high}"
CURSOR_GROK="${CTXREVIEW_GROK:-cursor-grok-4.6-high}"
CODEX_SOL="${CTXREVIEW_SOL:-gpt-5.6-sol}"
CLAUDE_OPUS="${CTXREVIEW_OPUS:-}"
CLAUDE_OPUS_LABEL="${CLAUDE_OPUS:-managed default (Opus 5 1M)}"

die() { printf '%s: %s\n' "$SELF" "$*" >&2; exit 2; }
say() { printf '%s: %s\n' "$SELF" "$*" >&2; }

. "$FBA/lib/ctxreview/cli.sh"

command_name=""
case "${1:-}" in
  run) command_name=run; shift ;;
  -h|--help|help) usage; exit 0 ;;
  "") usage >&2; exit 2 ;;
  --*) ;;
  *) die "unknown command: $1 (expected run or an inspection/lifecycle option)" ;;
esac

base="" legs="" label="" dir="" dry=0 force=0 again=0
legs_explicit=0
MAX_BYTES="${CTXREVIEW_MAX_BYTES:-400000}"
action="" close_target=""; focus=""; focus_files=""; consolidate_dir=""
adj_dir=""; adj_commit=""; bug_text=""; bug_tool=""; bug_filter="open"; bug_id=""
bug_run="${CTXREVIEW_RUN_ID:-}"; bug_leg="${CTXREVIEW_LEG:-}"
owner_session="${CTXREVIEW_SESSION_ID:-${CODEX_THREAD_ID:-${CLAUDE_SESSION_ID:-}}}"
session_filter=""; respawn_run=""; attach_run=""; attach_leg=""; maintain_args=()
HERDR_SESSION_NAME=""
herdr_session_override=""
WORK_C="$(mktemp -d "${TMPDIR:-/tmp}/ctxreview-c.XXXXXX")"
REAP_DIR="${CTXREVIEW_REAP_DIR:-$HOME/.local/state/ctxreview/reaped}"
SESSION_STATE_DIR="${CTXREVIEW_SESSION_STATE_DIR:-$HOME/.local/state/ctxreview/sessions}"
EVENTS_FILE="${CTXREVIEW_EVENTS_FILE:-$SESSION_STATE_DIR/events.jsonl}"
FOCUS_EVENTS_FILE="${CTXREVIEW_FOCUS_EVENTS_FILE:-$SESSION_STATE_DIR/focus-events.jsonl}"
SETTLED_RETENTION_MINUTES="${CTXREVIEW_SETTLED_RETENTION_MINUTES:-1440}"
OWNER_ENDED_IDLE_MINUTES="${CTXREVIEW_OWNER_ENDED_IDLE_MINUTES:-1440}"
MAINTAIN_LOCK=""
CODEX_NO_MCP_ARGS=()
CODEX_NO_MCP_READY=0

. "$FBA/lib/ctxreview/privacy.sh"
chmod 700 "$WORK_C"
. "$FBA/lib/ctxreview/herdr.sh"

cleanup_work() {
  rm -rf "$WORK_C"
  if [ -n "$MAINTAIN_LOCK" ]; then
    rm -f "$MAINTAIN_LOCK" 2>/dev/null || true
  fi
}
trap cleanup_work EXIT
while [ $# -gt 0 ]; do
  case "$1" in
    --base) base="${2:?}"; shift 2 ;;
    --legs) legs="${2:?}"; legs_explicit=1; shift 2 ;;
    --label) label="${2:?}"; shift 2 ;;
    --dir) dir="${2:?}"; shift 2 ;;
    --dry-run) dry=1; shift ;;
    --force) force=1; shift ;;
    --herdr-session) herdr_session_override="${2:?--herdr-session needs a name}";
                     shift 2 ;;
    --session) owner_session="${2:?--session needs an id}"; shift 2 ;;
    --sessions) action=sessions; shift
                if [ $# -gt 0 ]; then case "$1" in --*) ;; *) session_filter="$1"; shift ;; esac; fi ;;
    --stats) action=stats; shift
             if [ $# -gt 0 ]; then case "$1" in --*) ;; *) session_filter="$1"; shift ;; esac; fi ;;
    --maintain) action=maintain; shift; maintain_args=("$@"); set -- ;;
    --close-session) action=closesession; session_filter="${2:?--close-session needs an id}"; shift 2 ;;
    --session-ended) action=sessionended; session_filter="${2:?--session-ended needs an id}"; shift 2 ;;
    --respawn) action=respawn; respawn_run="${2:?--respawn needs a run id}"; shift 2 ;;
    --attach) action=attach; attach_run="${2:?--attach needs a run id}";
              attach_leg="${3:?--attach needs a leg}"; shift 3 ;;
    --again) again=1; shift ;;
    --focus) focus="${2:?--focus needs a topic}"; shift 2 ;;
    --list) action=list; shift ;;
    --bug) action=bug; bug_text="${2:?--bug needs a description}"; shift 2
           case "${1:-}" in ""|--*) ;; *) bug_tool="$1"; shift ;; esac ;;
    --run) bug_run="${2:?--run needs an id}"; shift 2 ;;
    --leg) bug_leg="${2:?--leg needs a name}"; shift 2 ;;
    --bugs) action=bugs; shift
            case "${1:-}" in ""|--*) ;; *) bug_filter="$1"; shift ;; esac ;;
    --bugs-to-beads) action=bugs2bd; shift ;;
    --bug-fixed) action=bugfixed; bug_id="${2:?--bug-fixed needs an id}"; shift 2 ;;
    --consolidate) action=consolidate; consolidate_dir="${2:?--consolidate needs a run dir}"; shift 2 ;;
    --adjudicate) action=adjudicate; adj_dir="${2:?--adjudicate needs a run dir}"; shift 2
                  [ "${1:-}" = "--commit" ] && { adj_commit=--commit; shift; } ;;
    --close) action=close; close_target="${2:?--close needs RUN|--done|--all}"; shift 2 ;;
    --max-bytes) MAX_BYTES="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

# ------------------------------------------------------- list and close ----
#
# Legs remain running while their parent is active so they stay conversible.
# SessionEnd and the retention fallback reclaim exact persisted resources; this
# live view is still derived from Herdr so it cannot go stale.

. "$FBA/lib/ctxreview/core.sh"
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
need_herdr() { herdr_bin >/dev/null 2>&1 || die "herdr not on PATH"; }
if [ -z "$action" ]; then
  [ "$command_name" = run ] \
    || die "review launch requires: $SELF run --legs kimi,grok,sol,opus"
  [ "$legs_explicit" -eq 1 ] \
    || die "run requires --legs LIST (choose kimi,grok,sol,opus)"
elif [ -n "$command_name" ]; then
  die "run cannot be combined with inspection or lifecycle actions"
fi
case "$action" in
  "") validate_legs "$legs" ;;
esac
case "$action" in
  list)  need_herdr; cmd_list; exit 0 ;;
  close) need_herdr; cmd_close "$close_target"; exit 0 ;;
  consolidate) cmd_consolidate "$consolidate_dir"; exit 0 ;;
  bug) cmd_bug "$bug_text" "$bug_tool"; exit 0 ;;
  bugs) cmd_bugs "$bug_filter"; exit 0 ;;
  bugs2bd) cmd_bugs_to_beads; exit 0 ;;
  bugfixed) cmd_bug_fixed "$bug_id"; exit 0 ;;
  adjudicate) cmd_adjudicate "$adj_dir" $adj_commit; exit 0 ;;
  sessions) cmd_sessions "$session_filter"; exit 0 ;;
  stats) cmd_stats "$session_filter"; exit 0 ;;
  maintain) need_herdr; cmd_maintain "${maintain_args[@]+"${maintain_args[@]}"}"; exit $? ;;
  closesession) need_herdr; cmd_close_session "$session_filter"; exit 0 ;;
  sessionended) need_herdr; cmd_session_ended "$session_filter"; exit 0 ;;
  respawn) need_herdr; cmd_respawn "$respawn_run"; exit $? ;;
  attach) need_herdr; cmd_attach "$attach_run" "$attach_leg"; exit $? ;;
esac

# ------------------------------------------------------------- preflight ----

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a git repository"
command -v ctxpack >/dev/null || die "ctxpack not on PATH"
# Gate on the SERVER being reachable, not on HERDR_ENV.
#
# HERDR_ENV=1 only means "this process is running inside a Herdr-managed pane".
# The CLI itself talks to a socket (~/.config/herdr/herdr.sock), so tab and pane
# operations work from anywhere the socket is reachable — a plain terminal, a
# Codex GUI session, a cron job. Gating on HERDR_ENV refused to run in exactly
# those cases for no reason, and the panes would have appeared in the user's
# session regardless.
if [ "$dry" -eq 0 ]; then
  need_herdr
  herdr_version="$(herdr_global --version 2>/dev/null | awk '{print $2}')"
  case "$herdr_version" in
    0.[89].*|0.[1-9][0-9].*|[1-9].*) ;;
    *) die "ctxreview requires Herdr 0.8+ (found ${herdr_version:-unknown})" ;;
  esac
fi

# A focused round: narrow the question, and carry the full checks for it.
#
# A normal pack lists lens *titles* — enough to remind a reviewer the lens
# exists. A focused round inlines the matching lens files in full, because when
# the whole round is about one thing the reviewer should be reading the actual
# evidence and "how to apply" bullets, not a one-line reminder.
#
# Refuses an unmatched topic rather than silently running an unfocused round.
# That matters here: the corpus has *zero* security/authz coverage, so
# `--focus security` finding nothing is a fact about the corpus, not a clean bill
# of health, and it must not be mistaken for one.
PRIVATE_REVIEW_DIR="${CTXPACK_BIBLE_DIR:-${SECOND_BRAIN_DIR:+$SECOND_BRAIN_DIR/review}}"
LENS_DIR="${PRIVATE_REVIEW_DIR:+$PRIVATE_REVIEW_DIR/lenses}"

focus_lens_files() {  # focus_lens_files <topic> -> matching lens paths
  local topic="$1" hits=""
  [ -d "$LENS_DIR" ] || return 0

  # Tags first: they say what a lens is ABOUT, which is the thing being asked for.
  #
  # Body substring alone is a retrieval proxy and misfired exactly the way proxies
  # do -- `--focus tests` matched 11 of 31 lenses, because "test" appears in
  # almost every piece of evidence regardless of subject. Each lens now carries a
  # hand-assigned `tags:` line; matching a whole tag word is precise, and the
  # substring sweep stays as the fallback for topics nobody has tagged yet.
  hits="$(awk -v t="$topic" '
      FNR==1 { f=FILENAME }
      /^tags:/ { line=tolower($0)
                 n=split(line, w, /[[:space:]]+/)
                 for (i=2; i<=n; i++) if (w[i] == tolower(t)) { print f; break }
                 nextfile }
    ' "$LENS_DIR"/*.md 2>/dev/null | sort -u || true)"
  if [ -n "$hits" ]; then
    printf '%s' "$hits"; return 0
  fi

  # Match the lens id, the title, or the body — a topic is usually all over the
  # evidence even when it is in no filename.
  hits="$(grep -ril -- "$topic" "$LENS_DIR"/*.md 2>/dev/null | sort || true)"

  # Fall back to a stem. "concurrency" appears nowhere in the corpus while
  # "concurrent" and "concurrently" are everywhere, and refusing that is
  # pedantry, not precision. Nine characters of "concurrency" is "concurren",
  # which matches both without matching anything unrelated.
  # Require a long word and keep a long stem. Stripping 2 chars off a 7-letter
  # word turned "quantum" into "quant", which matched "quantitative" in the
  # metrics lenses and ran a bogus focused round instead of refusing. A stem is a
  # concession to morphology (concurrency/concurrent), not a fuzzy search.
  if [ -z "$hits" ] && [ "${#topic}" -ge 9 ]; then
    local stem="${topic:0:$(( ${#topic} - 2 ))}"
    hits="$(grep -ril -- "$stem" "$LENS_DIR"/*.md 2>/dev/null | sort || true)"
    [ -z "$hits" ] || say "focus \"$topic\" matched on stem \"$stem\""
  fi
  printf '%s' "$hits"
}

focus_topics() {  # what --focus can usefully match, for the error path
  [ -d "$LENS_DIR" ] || return 0
  # Tags, not lens ids. A lens id is one string you have to already know; tags are
  # the vocabulary the corpus actually indexes on, and listing them turns a
  # refusal into a menu.
  awk '/^tags:/ { sub(/^tags:[[:space:]]*/,""); n=split($0,w,/[[:space:]]+/)
                  for (i=1;i<=n;i++) if (w[i] != "") print w[i] }' \
    "$LENS_DIR"/*.md 2>/dev/null | sort | uniq -c | sort -rn \
    | awk '{printf "  %-26s (%d lens)\n", $2, $1}'
}

want() { case ",$legs," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# Presence check only. `herdr agent start --kind codex|claude` resolves and
# launches the binary itself, so the alias-ordering hazard that applies to
# hand-rolled `codex exec` invocations does not arise here.
want sol  && command -v codex  >/dev/null || ! want sol  || die "codex not found"
want opus && command -v claude >/dev/null || ! want opus || die "claude not found"
{ want kimi || want grok; } && [ -x "$SPAWN" ] || true
if { want kimi || want grok; } && [ ! -x "$SPAWN" ]; then
  die "missing $SPAWN"
fi
if want kimi || want grok; then
  prepare_cursor_config "$SESSION_STATE_DIR/cursor-config" "$PWD" \
    || die "could not create the isolated Cursor MCP config"
fi
want sol && prepare_codex_no_mcp_args

if [ -n "$focus" ]; then
  [ -n "$LENS_DIR" ] \
    || die "--focus requires explicit CTXPACK_BIBLE_DIR or SECOND_BRAIN_DIR"
  focus_files="$(focus_lens_files "$focus")"
  if [ -z "$focus_files" ]; then
    printf '%s: no lens matches focus "%s".\n\n' "$SELF" "$focus" >&2
    printf 'A focused round with no checks is an unfocused round wearing a label,\n' >&2
    printf 'and "found nothing" would then mean "the corpus has nothing", not "clean".\n' >&2
    printf 'Available tags (a whole tag matches exactly; substring is the fallback):\n' >&2
    focus_topics >&2
    exit 2
  fi
  n_focus="$(printf '%s\n' "$focus_files" | grep -c .)"
  say "focus \"$focus\" -> $n_focus lens file(s), inlined in full"
  # A topic that matches half the corpus is a theme, not a focus. Said plainly
  # rather than refused: the round still works, it just is not narrow, and the
  # prompt grows by every lens body it inlines.
  if [ "$n_focus" -gt 5 ]; then
    say "note: $n_focus lenses is broad for a focused round — a narrower topic"
    say "      gives the reviewer fewer, sharper checks. \`ctxreview run --focus\` with"
    say "      no match lists every available topic."
  fi
fi

# The run directory lives INSIDE the repo, because that is the only place a
# sandboxed leg can write.
#
# It used to be a mktemp under /var/folders. Every leg was then told to write its
# report to a path outside its own workspace: Codex `workspace-write` permits the
# workspace only, and a Claude leg in plan mode is read-only outright. One leg
# said so verbatim — "the plan file isn't writable in this context" — and simply
# printed its report instead, where only the ~4 KB terminal tail could recover it.
# That is the real reason reports went missing, not the models.
#
# `.ctxreview/` is excluded via `.git/info/exclude`, which is local and untracked,
# so this adds no churn to a tracked .gitignore. Overridable with --dir, and
# --dir outside the repo is exactly the failure above, so it warns.
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$dir" ]; then
  if [ -n "$repo_root" ]; then
    dir="$repo_root/.ctxreview/$(date +%Y%m%d-%H%M%S)-$$"
    excl="$(git rev-parse --git-dir 2>/dev/null)/info/exclude"
    if [ -f "$excl" ] && ! grep -qx '/.ctxreview/' "$excl" 2>/dev/null; then
      printf '/.ctxreview/\n' >> "$excl"
      say "added /.ctxreview/ to .git/info/exclude (local, untracked)"
    fi
  else
    dir="$(mktemp -d "${TMPDIR:-/tmp}/ctxreview.XXXXXX")"
  fi
else
  case "$dir" in
    "$(git rev-parse --show-toplevel 2>/dev/null)"/*) ;;
    *) say "warning: --dir is outside the repo. A sandboxed leg (Codex"
       say "         workspace-write, Claude plan mode) cannot write there, so"
       say "         reports may be lost to the 4 KB terminal tail." ;;
  esac
fi
secure_dir "$dir"
dir="$(cd "$dir" && pwd -P)"
# A caller-selected --dir is a storage location, not a globally unique identity.
# Keep ownership records collision-resistant even when two repositories choose
# the same basename such as `review`.
current_run_id="review-$(date +%Y%m%d-%H%M%S)-$$-${RANDOM:-0}"
branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo HEAD)"
if [ -z "$owner_session" ]; then
  owner_session="manual-$(date +%y%m%d%H%M%S)-$$"
  say "no parent harness session found; generated $owner_session"
fi
valid_session_id "$owner_session" || die "invalid --session id (letters, digits, . _ : -; max 160 chars)"

# Name the workspace after the CHANGE, not the branch.
#
# A branch name is what you typed when you started; a tab label is what you read
# three hours later, and by then `review: HEAD`, `review: main` and
# `review: ODS-4408-islands` all mean nothing. A ticket id is an index into
# something you have to go look up. The commit subject is the one string already
# written to explain the change to a human, so prefer it — falling back through
# progressively worse but still concrete options, never to the branch alone.
derive_label() {
  local repo summary n
  repo="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo '?')")"

  # 1. An open PR title: human-written, already reviewed for clarity.
  summary="$(gh pr view --json title -q .title 2>/dev/null | head -1 || true)"

  # 2. Commit subjects against the base.
  if [ -z "$summary" ] && [ "$resolved_base" != "HEAD" ]; then
    n="$(git rev-list --count "$resolved_base"..HEAD 2>/dev/null || echo 0)"
    if [ "${n:-0}" -eq 1 ]; then
      summary="$(git log -1 --format=%s 2>/dev/null || true)"
    elif [ "${n:-0}" -gt 1 ]; then
      summary="$(git log -1 --format=%s 2>/dev/null || true)"
      [ -z "$summary" ] || summary="$summary (+$((n - 1)))"
    fi
  fi

  # 3. Uncommitted work has no subject; name the area it touches instead.
  if [ -z "$summary" ]; then
    local changed top nfiles
    changed="$(git diff --name-only "$( [ "$resolved_base" = HEAD ] && echo HEAD || echo "$resolved_base...HEAD" )" 2>/dev/null || true)"
    [ -n "$changed" ] || changed="$(git diff --name-only HEAD 2>/dev/null || true)"
    changed="$(printf '%s\n' "$changed"; git ls-files --others --exclude-standard 2>/dev/null)"
    changed="$(printf '%s\n' "$changed" | sort -u | grep -v '^$' || true)"
    nfiles="$(printf '%s\n' "$changed" | grep -c . || true)"
    top="$(printf '%s\n' "$changed" | awk -F/ 'NF>1{print $1"/"$2; next}{print $1}' \
           | sort | uniq -c | sort -rn | awk 'NR==1{$1="";sub(/^ /,"");print}')"
    summary="uncommitted in ${top:-working tree} (${nfiles:-?} files)"
  fi

  summary="$(printf '%s' "$summary" | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')"
  [ "${#summary}" -le 52 ] || summary="${summary:0:49}..."
  printf 'review: %s · %s' "$repo" "$summary"
}

# ------------------------------------------------------ pack and prompt ----

pack="$dir/pack.md"; diff="$dir/diff.patch"; prompt="$dir/prompt.md"

write_review_diff() {  # write_review_diff <base>
  local review_base="$1" f
  if [ "$review_base" = HEAD ]; then
    git diff HEAD 2>/dev/null
  else
    # The first patch is the branch's three-dot delivery scope. The second is
    # the tracked working-tree overlay reviewers/tests currently see.
    git diff "$review_base"...HEAD 2>/dev/null
    git diff HEAD 2>/dev/null
  fi
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    # Text is included in full. Binary content is represented by git's explicit
    # "Binary files differ" marker. The prompt-size cap below handles oversized
    # text by refusing the round, never by silently dropping a file.
    git diff --no-index -- /dev/null "$f" 2>/dev/null || true
  done < <(git ls-files --others --exclude-standard 2>/dev/null)
}

say "building context pack"
if [ -n "$base" ]; then ctxpack build --base "$base" --out "$pack" || die "ctxpack build failed"
else ctxpack build --out "$pack" || die "ctxpack build failed"; fi

resolved_base="$(awk -F'`' '/Diff base/{print $2; exit}' "$pack")"
[ -n "$resolved_base" ] || resolved_base="HEAD"
write_review_diff "$resolved_base" > "$diff"
[ -s "$diff" ] || die "empty diff against $resolved_base — nothing to review"

{
  cat <<'HDR'
You are one of four INDEPENDENT code reviewers. You cannot see the others and
you must not try to; the value of this exercise is that the opinions are
uncorrelated. Look for correctness problems, then try to disprove each
candidate. A clean review is valid; do not invent a finding to fill a section.

Inspect the repository freely to check any claim. Do not commit or push, and do
not "fix" what you find — you are reviewing, and the author decides. Editing the
tree under review also invalidates the other three legs' snapshot.
Keep inspection inside the repository root. Never run `find`, `grep`, or another
recursive search from `/`, HOME, or a broad parent directory; use repo-local
`rg`, file globs, or a narrowly resolved dependency path.

**Write your finished report to the path given in your first message**, then say
so in the pane. Write the file even if you also print the report: the pane only
retains about one screenful, so the file is the durable copy.

After that, stay up and stay conversational. Expect follow-ups — "defend finding
2", "what would the test look like", "keep going". Hold your context.

**If the review tooling itself gets in your way, file it.** You are the best
reporter of a defect in this harness because you just hit it in anger:

Use the attributed `ctxreview --bug` command in your first message. It carries
this run, leg, and parent session so the defect can be traced to its outcome.

Worth filing: the pack was missing something you needed, a section was wrong or
truncated, an instruction contradicted itself, your report path was unwritable,
the diff looked stale. This is a separate channel from your findings — do not put
tooling complaints in the report, and do not let them replace reviewing the code.
One line each, then carry on.

The context pack below is the evidence this diff is being judged against: the
repo's own written conventions, sibling-file precedent, per-file history, domain
notes, previously adjudicated findings, and review lenses. Use it — a finding
that cites a convention with its call sites lands in one round; a finding that
cites your taste is churn.

Rules that come from this corpus and are not negotiable:

1. Never state a convention without the count. "Other services do this" is an
   opinion; "9 of 11 sibling factories call setupAuthInterceptor, at these
   lines" is evidence. The pack's Sibling precedent section computes this, but
   it is a LEAD, not a finding — open two of the cited siblings before writing
   the comment.
2. If you assert a consequence, cite the code that produces it (the consumer, by
   file and line) or narrow the finding to the asymmetry alone. An overstated
   consequence is what gets a correct finding dismissed.
3. Check the pack's code-bible section first. A rule marked `rejected` is a
   finding already turned down with a reason. Re-raising it without addressing
   that reason wastes a round.
4. Prefer a check you can settle with a command over an argument in prose.
5. Say "I could not verify X" rather than guessing. Do not invent line numbers.
6. Check actual scale, callers, rollout, and existing guarantees. Trace the path
   through the downstream consumer before stating the consequence.
7. Keep design preferences and future prerequisites separate from current
   correctness failures. Recommend the smallest invariant the failure needs.

Report findings as:

### Critical / Important / Observation
N. **[title]** — file:line
   Evidence: [what you observed, with the command or excerpt that shows it]
   Fix: [specific action]

Then report:
- **Uncovered failure path:** name one only if it is reachable under the stated
  constraints; otherwise say that none survived review.
- **Weakest test:** identify one only when a concrete implementation break would
  leave it green; otherwise say that none survived review.
- **Unverified:** anything you asserted but could not check.

HDR
  # A focused round states its scope before the pack, so the reviewer reads the
  # pack in service of one question instead of sweeping.
  if [ -n "$focus" ]; then
    printf '\n===== THIS ROUND IS FOCUSED: %s =====\n\n' "$focus"
    cat <<FOC
Report only findings in this class. Other problems you happen to notice go in a
single short "outside this round's scope" list at the end — one line each, no
evidence, no fixes. Do not let them crowd out the focused work.

If you find nothing in this class, say so explicitly and say what you checked.
"No findings" and "I did not look" must not read the same, and a focused round
that returns silence is worthless.

The full checks for this round follow. They are the accumulated evidence for this
class in this codebase, not general advice — cite them.

FOC
    # No `local` here: this block runs at top level inside a command group, not
    # in a function, and bash rejects `local` there.
    for lf in $focus_files; do
      printf '\n----- lens: %s -----\n\n' "$(basename "$lf")"; cat "$lf"
    done
    printf '\n===== END FOCUS =====\n'
  fi

  printf '\n===== CONTEXT PACK =====\n\n'; cat "$pack"
  printf '\n===== DIFF (base %s) =====\n\n' "$resolved_base"; cat "$diff"
} > "$prompt"

# Fingerprint the tree the legs are about to review.
#
# Legs are no longer sandboxed read-only — that is what lets them write their own
# report — which also means any of them CAN edit the tree under review. One Cursor
# pane reported "2 files edited" during a round; no mtime changed in the window so
# nothing was proven, but the capability is real and the consequence is severe: if
# the tree moves, every leg's findings refer to a diff that no longer exists, and
# the other legs were reviewing a different snapshot than the one you now hold.
#
# Cheaper and more reliable than trying to prevent it per-runtime: record what the
# tree looked like, and have --consolidate refuse to present findings silently if
# it changed.
{ git status --porcelain 2>/dev/null; git rev-parse HEAD 2>/dev/null; } \
  | shasum 2>/dev/null | awk '{print $1}' > "$dir/.tree-fingerprint" || true

bytes="$(wc -c < "$prompt" | tr -d ' ')"
say "pack $(wc -l < "$pack" | tr -d ' ') lines, diff $(wc -l < "$diff" | tr -d ' ') lines, prompt $bytes bytes"

# Derived here, not earlier: it needs the resolved base and the changed files.
[ -n "$label" ] || label="$(derive_label)"

# Keep review labels visually distinct inside the isolated session. Ownership
# and cleanup come from the persisted Herdr session name, never label scanning.
case "$label" in
  "review: "*) ;;
  *) label="review: $label" ;;
esac
say "label: $label"

# Refuse to ship a prompt nobody will actually read in full. Four legs each
# silently truncating a 1.6 MB prompt looks exactly like four completed reviews.
# The corpus rule is: never truncate quietly -- so fail with the options instead.
if [ "$bytes" -gt "$MAX_BYTES" ] && [ "$force" -eq 0 ]; then
  cat >&2 <<EOF
$SELF: prompt is $bytes bytes (cap $MAX_BYTES).

A diff this size does not get reviewed, it gets skimmed or truncated -- and a
truncated leg is indistinguishable from a thorough one in its output. Options:

  narrow the base      $SELF --base <later-ref>
  review a subrange    git diff <base>...HEAD -- <dir>   then review that branch
  split the branch     one reviewable claim per PR (see llm/AGENTS.md scope rules)
  override             $SELF --force        (say so when you report the findings)
EOF
  exit 2
fi

if [ "$dry" -eq 1 ]; then
  printf '\nPlan (dry run)\n  dir    %s\n  base   %s\n  legs   %s\n  label  %s\n' \
    "$dir" "$resolved_base" "$legs" "$label"
  exit 0
fi

# --------------------------------------------------------------- panes -----

# Every round gets its own named Herdr 0.8 session and socket. Layout changes
# are therefore incapable of touching the user's default session or focus.
# Session stop hibernates the entire round; restart restores the layout and the
# native agent conversations.
#
# Every create/split still uses `--no-focus` inside the isolated session so a
# later TUI attach opens predictably.
# --again: retire the previous round for this repo, then run a fresh one.
#
# The legs are deliberately NOT told what the last round found. A leg shown prior
# findings drifts toward confirming them, and the corpus rule is that the author
# of a finding is the wrong judge of its fix -- which applies to a sibling model
# reading the same list. If you want a targeted re-check, that is what --focus is
# for.
#
# Closing first matters for a reason beyond tidiness: two generations of findings
# left side by side read as two legs agreeing, which is exactly the false-quorum
# signal --consolidate exists to prevent.
if [ "$again" -eq 1 ]; then
  # Retire only rounds owned by this parent session for this repository. Global
  # cwd/prefix matching can close another agent's review and cannot detect an
  # idle-but-composing Cursor leg.
  repo_name="$(basename "$repo_root")"
  prior_found=0; prior_waiting=0
  for prior_record in "$(session_runs_dir)"/*.json; do
    [ -s "$prior_record" ] || continue
    [ "$(jq -r '.owner_session // empty' "$prior_record")" = "$owner_session" ] || continue
    [ "$(jq -r '.repo_root // empty' "$prior_record")" = "$repo_root" ] || continue
    [ "$(jq -r '.status // empty' "$prior_record")" != closed ] || continue
    prior_found=$((prior_found+1))
    close_session_record "$prior_record"
    if [ "$(jq -r '.status // empty' "$prior_record")" != closed ]; then
      prior_waiting=$((prior_waiting+1))
    fi
  done
  if [ "$prior_found" -eq 0 ]; then
    say "--again: no previous owned review workspace for $repo_name; running a first round"
  elif [ "$prior_waiting" -gt 0 ]; then
    die "--again: $prior_waiting previous owned round(s) are still working, blocked, composing, or unverifiable"
  fi
fi

HERDR_SESSION_NAME="${herdr_session_override:-ctxreview-$(date +%y%m%d-%H%M%S)-$$}"
case "$HERDR_SESSION_NAME" in
  ""|[!a-z]*|*[!a-z0-9_-]*)
    die "invalid --herdr-session name (use lowercase letters, digits, _ or -)" ;;
esac
[ "${#HERDR_SESSION_NAME}" -le 63 ] \
  || die "--herdr-session name must be at most 63 characters"
named_session_exists "$HERDR_SESSION_NAME" \
  && die "Herdr session $HERDR_SESSION_NAME already exists; use --respawn on its persisted run"
start_named_session "$HERDR_SESSION_NAME" \
  || die "could not start isolated Herdr session $HERDR_SESSION_NAME"
say "isolated Herdr session: $HERDR_SESSION_NAME"

ws=""; p1=""
say "creating isolated review workspace"
wjson="$(herdr workspace create --cwd "$PWD" --label "$label" --no-focus 2>&1)"
ws="$(printf '%s' "$wjson" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)"
p1="$(printf '%s' "$wjson" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)"
[ -n "$ws" ] && [ -n "$p1" ] || die "could not create the isolated review workspace: $wjson"
# (herdr speaks JSON and its ids contain a colon, `w1:p55`, so these are parsed
# with jq — a regex returned `w1` and every pane op then addressed the wrong
# target.)
# Herdr agent names are global, not workspace-scoped. Include this run's first
# pane id so two review workspaces can run the same leg concurrently.
agent_suffix="$(printf '%s' "$p1" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
[ -n "$agent_suffix" ] || agent_suffix="$$"

split() {  # split <pane> <right|down> -> new pane id
  local out; out="$(herdr pane split "$1" --direction "$2" --no-focus 2>&1)" || { say "split failed: $out"; return 1; }
  printf '%s' "$out" | jq -r '.result.pane.pane_id // empty' 2>/dev/null
}

panes=("$p1")
n=0; for l in kimi grok sol opus; do want "$l" && n=$((n+1)); done
[ "$n" -ge 2 ] && { p2="$(split "$p1" right)" && panes+=("$p2"); }
[ "$n" -ge 3 ] && { p3="$(split "$p1" down)"  && panes+=("$p3"); }
[ "$n" -ge 4 ] && { p4="$(split "${panes[1]}" down)" && panes+=("$p4"); }
say "panes: ${panes[*]}"
init_session_record || die "could not persist review session ownership"

# Sets PANE, does not echo it. `pane="$(next_pane)"` runs the function in a
# SUBSHELL, so the counter increment is discarded and every leg is handed the
# first pane -- which then fails as "agent did not start" because the previous
# leg already owns it. Observed, not hypothetical.
i=0
PANE=""
failed_legs=""
next_pane() { PANE="${panes[$i]:-}"; i=$((i+1)); }
mark_failed() {  # leg reason
  local tag="$1" reason="${2:-launch_failed}"
  failed_legs="$failed_legs $tag"
  finalize_leg "$tag" failure "$reason" "" \
    || say "$tag failure could not be persisted"
  signal_terminal "$tag"
}

launch_cursor() {  # launch_cursor <model> <tag>
  local model="$1" tag="$2" pane agent
  next_pane; pane="$PANE"
  [ -n "$pane" ] || { say "no pane left for $tag"; mark_failed "$tag" no_pane; return 1; }
  agent="ctxreview-$tag-$agent_suffix"
  herdr pane rename "$pane" "$tag" >/dev/null 2>&1 || true
  # A POINTER, not the prompt. Pushing tens of kilobytes through an agent input
  # box is the spawner's documented failure mode #2 -- text lands but is never
  # submitted, and the pane looks healthy while doing nothing. It warned exactly
  # that on the first live run. Reading a file is a tool call Cursor does well.
  write_pointer "$tag" "$model" oneline
  local ptr="$dir/$tag.prompt.md"
  # No --plan: these legs write their own report file, so they need more than
  # `--mode ask`. --keep + --no-wait leave the pane conversible and return here.
  if HERDR_SESSION_NAME="$HERDR_SESSION_NAME" "$SPAWN" \
              --model "$model" --name "$agent" --pane "$pane" \
              --prompt-file "$ptr" --keep --no-wait \
              --cwd "$repo_root" \
              --config-dir "$SESSION_STATE_DIR/cursor-config" \
              >>"$dir/$tag.spawn.log" 2>&1; then
    record_leg_session "$tag" "$agent" cursor "$model" "$pane" "$model" \
      || say "$tag native session id will be refreshed at settlement or cleanup"
    # The spawner does not return success until Cursor's footer proves the prompt
    # left the composer, even with --no-wait.
    say "$tag -> pane $pane as $agent"
    # Recorded per successful launch so the settle-notifier knows how many legs
    # to wait for. A leg that failed to spawn must not be waited on, or the round
    # never announces.
    printf '%s\n' "$tag" >> "$dir/.launched"
    # Capture the transcript ourselves.
    #
    # `--no-wait` returns as soon as the prompt is submitted, which also skips
    # the spawner's wait-then-capture path -- so `--result-file` never gets
    # written and closing the pane loses the review outright. That happened:
    # two Cursor legs produced nothing while the piped legs produced 287 KB and
    # 9.8 KB. A detached reaper per leg keeps the pane watchable AND makes the
    # "a closed pane is not a lost review" promise true.
    # Two measured caveats.
    #
    # `herdr agent read` emits RAW terminal text, not JSON -- piping it through
    # jq silently produces an empty file.
    #
    # And it is a terminal SNAPSHOT, not a session log: visible, recent and
    # recent-unwrapped all returned ~4.1 KB on a long-running agent. So this
    # recovers the tail -- normally the findings summary, which is the part you
    # want -- but NOT a full transcript. A leg that writes a long report loses
    # its middle. That is the price of an interactive-only runtime; legs with a
    # headless mode are piped instead precisely to avoid it.
    # Writes to <tag>.tail.md, never <tag>.md, and only when the leg produced no
    # report of its own.
    #
    # It used to write <tag>.md directly -- the same path the leg writes -- so a
    # 4 KB terminal tail would clobber a real report. Opus wrote 17 KB in one run;
    # that was one race away from being replaced by a quarter of itself. A
    # fallback that can destroy the primary is not a fallback.
    #
    # No empty files either: a 0-byte report reads as "the leg produced nothing"
    # when it means "we captured nothing".
    # Wait for the leg to START before waiting for it to FINISH.
    #
    # A freshly spawned agent sits at `idle` until its prompt submits, so
    # `wait --until idle` matched instantly: the reaper captured a 567-byte
    # startup banner as the "report", announced the leg settled, and exited —
    # while the leg had not yet run. Every tiny .tail.md came from this, and once
    # the reaper had exited nothing captured the real output at all.
    #
    # Missing the `working` window is not fatal: a fast leg may pass through it
    # between polls, so a timeout here falls through to the settle wait rather
    # than giving up.
    watch_leg "$tag" "$agent"
  else
    say "$tag FAILED to spawn (see $dir/$tag.spawn.log)"
    # The spawner can fail after Cursor itself started (for example, mode or
    # prompt verification failed) and its best-effort pane close can also fail.
    # Persist any surviving exact agent before terminalizing the leg so scoped
    # cleanup owns the straggler instead of losing it to a name-prefix sweep.
    update_session_record \
      '.legs[$leg] += {agent_name:$agent,kind:"cursor",model:$model,
        model_arg:$model,pane_id:$pane,status:"open"}' \
      --arg leg "$tag" --arg agent "$agent" --arg model "$model" --arg pane "$pane" \
      || say "$tag failed spawn ownership could not be persisted"
    if herdr agent get "$agent" >/dev/null 2>&1; then
      record_leg_session "$tag" "$agent" cursor "$model" "$pane" "$model" \
        || say "$tag failed after start; native session id will be refreshed during cleanup"
    fi
    mark_failed "$tag" spawn_failed
  fi
}

# Interactive agent in a pane, via the Herdr agent API.
#
# Chosen over `codex exec` / `claude -p` deliberately: a piped leg is one shot
# and cannot be asked to continue, defend a finding, or go deeper — which is the
# most useful thing you can do with a reviewer. The transcript problem that
# argued for piping (`herdr agent read` only recovers ~4 KB of terminal) is
# solved instead by telling the leg to WRITE its report to a file, which it can
# do because these legs are not sandboxed read-only.
launch_agent() {  # launch_agent <tag> <kind> [agent args...]
  local tag="$1" kind="$2"; shift 2
  local pane agent
  next_pane; pane="$PANE"
  [ -n "$pane" ] || { say "no pane left for $tag"; mark_failed "$tag" no_pane; return 1; }
  agent="ctxreview-$tag-$agent_suffix"
  herdr pane rename "$pane" "$tag" >/dev/null 2>&1 || true

  local start_output attempt=1 max_attempts="${CTXREVIEW_PANE_START_ATTEMPTS:-10}"
  while :; do
    if start_output="$(herdr agent start "$agent" --kind "$kind" --pane "$pane" \
         --timeout "${CTXREVIEW_START_TIMEOUT_MS:-90000}" -- "$@" 2>&1)"; then
      break
    fi
    printf '%s\n' "$start_output" >>"$dir/$tag.spawn.log"
    # A newly created tab can return several seconds before its login shell
    # reaches a prompt. Poll only this transient state; every other start error
    # is actionable and exits the loop immediately.
    if ! printf '%s' "$start_output" | grep -q 'agent_pane_busy' \
       || [ "$attempt" -ge "$max_attempts" ]; then
      break
    fi
    attempt=$((attempt+1))
    sleep "${CTXREVIEW_PANE_READY_DELAY_SECONDS:-1}"
  done
  printf '%s\n' "$start_output" >>"$dir/$tag.spawn.log"
  if ! printf '%s' "$start_output" | grep -q '"type":"agent_started"'; then
    say "$tag FAILED to start (see $dir/$tag.spawn.log)"
    mark_failed "$tag" start_failed
    return 1
  fi

  # Ownership begins at agent_started, before any later readiness, model, or
  # prompt check can fail. A half-started process must remain attributable and
  # reclaimable even when the launch itself becomes a terminal failure.
  record_leg_session "$tag" "$agent" "$kind" \
    "$( [ "$tag" = sol ] && printf '%s' "$CODEX_SOL" || printf '%s' "$CLAUDE_OPUS_LABEL" )" "$pane" \
    "$( [ "$tag" = sol ] && printf '%s' "$CODEX_SOL" || printf '%s' "$CLAUDE_OPUS" )" \
    || say "$tag native session id will be refreshed at settlement or cleanup"

  # On a fresh login shell Herdr can recognize the typed Claude launch command
  # before the shell has executed it. Do not paste the review into zsh: prove
  # that Claude's own UI is visible first. One Enter is safe if the process is
  # merely slow (it becomes an empty UI submission) and necessary if the launch
  # line is still waiting at the prompt.
  # Ask Herdr whether the agent is up; do not scrape the pane for a banner.
  #
  # This probe used to wait for the literal string "Claude Code", which this
  # build never prints -- a live pane shows `Opus 5 (1M context) 1M │ main*` and
  # a permissions footer, no banner. So the match always timed out, then burned
  # another 120s, then reported a healthy agent as "did not reach the Claude UI".
  # `agent start` had already returned agent=claude, agent_status=idle,
  # interactive_ready=true for that same pane.
  #
  # Herdr's own detection is structural and version-independent; a banner string
  # is neither.
  if [ "$kind" = claude ]; then
    local ready="" ready_attempts="${CTXREVIEW_INTERACTIVE_READY_ATTEMPTS:-30}"
    for _ in $(seq 1 "$ready_attempts"); do
      ready="$(herdr agent get "$agent" 2>/dev/null \
               | jq -r '.result.agent | select(.interactive_ready==true) | .agent' 2>/dev/null || true)"
      [ -n "$ready" ] && break
      sleep "${CTXREVIEW_INTERACTIVE_READY_DELAY_SECONDS:-1}"
    done
    if [ -z "$ready" ]; then
      say "$tag did not become interactive-ready (see $dir/$tag.spawn.log)"
      mark_failed "$tag" interactive_not_ready
      return 1
    fi
  fi
  # Capture, then match. `herdr pane read | grep -q` makes grep close the pipe on
  # its first hit, herdr takes SIGPIPE, and `set -o pipefail` reports the
  # pipeline as failed -- so a pane correctly showing "Opus 5 (1M context) 1M"
  # was read as the wrong model. Fourth occurrence of this exact trap in these
  # tools: `| head` twice in ctxpack, `| grep -q` on `herdr status server`, and
  # here. Never pipe herdr output into an early-exiting reader.
  #
  # Also give the UI a moment: interactive_ready precedes the model line render.
  if [ "$kind" = claude ] && [ -z "$CLAUDE_OPUS" ]; then
    local seen="" panetext
    for _ in $(seq 1 20); do
      panetext="$(herdr pane read "$pane" --source recent-unwrapped --lines 120 2>/dev/null || true)"
      case "$panetext" in *[Oo]pus" "5*1M*) seen=1; break ;; esac
      sleep 1
    done
    if [ -z "$seen" ]; then
      say "$tag did not start with the managed Opus 5 1M default (see the pane)"
      mark_failed "$tag" model_mismatch
      return 1
    fi
  fi

  # --wait proves the prompt left the input box. Without it a pane can look
  # healthy while holding unsubmitted text -- the failure mode that produced two
  # empty Cursor reviews on the first live run.
  local prompt_output submitted=0
  local prompt_wait_args=(--wait --until working \
    --timeout "${CTXREVIEW_PROMPT_START_TIMEOUT_MS:-10000}")
  if prompt_output="$(herdr agent prompt "$agent" \
       "$(cat "$dir/$tag.prompt.md")" "${prompt_wait_args[@]}" 2>&1)"; then
    printf '%s\n' "$prompt_output" >>"$dir/$tag.spawn.log"
    say "$tag -> pane $pane as $agent (conversible)"
    printf '%s\n' "$tag" >> "$dir/.launched"
    submitted=1
  elif printf '%s' "$prompt_output" | grep -q 'agent_prompt_stalled' \
       && sleep "${CTXREVIEW_PROMPT_RECOVERY_DELAY_SECONDS:-1}" \
       && herdr agent send-keys "$agent" enter \
            >>"$dir/$tag.spawn.log" 2>&1 \
       && herdr agent wait "$agent" --until working \
            --timeout "${CTXREVIEW_PROMPT_START_TIMEOUT_MS:-10000}" \
            >>"$dir/$tag.spawn.log" 2>&1; then
    printf '%s\n' "$prompt_output" >>"$dir/$tag.spawn.log"
    say "$tag -> pane $pane as $agent (submitted with explicit Enter; conversible)"
    printf '%s\n' "$tag" >> "$dir/.launched"
    submitted=1
  else
    printf '%s\n' "$prompt_output" >>"$dir/$tag.spawn.log"
    say "$tag started in $pane but the prompt may not have submitted — check the pane"
    mark_failed "$tag" prompt_submission_failed
  fi
  [ "$submitted" -eq 0 ] || watch_leg "$tag" "$agent"
}

# One notification when the whole round settles, not four as legs trickle in.
#
# Completion is durable in the session record and visible through kun-status.
# Herdr UI notifications are opt-in because even a transient toast can intercept
# keyboard focus while the user is typing in another pane.
signal_terminal() {  # signal_terminal [tag]
  local tag="$1"
  local record="$(session_record_path "$current_run_id")"
  if [ -n "$tag" ] && mkdir "$dir/.terminal-$tag" 2>/dev/null; then
    printf '%s\n' "$tag" >> "$dir/.settled" 2>/dev/null || true
  fi
  [ -f "$dir/.launch-complete" ] && [ -s "$record" ] || return 0

  local want got round_outcome
  want="$(jq -r '(.requested_legs // []) | length' "$record")"
  got="$(jq -r '[.legs[]? | select(.outcome=="success" or .outcome=="degraded" or .outcome=="failure")] | length' "$record")"
  round_outcome="$(jq -r '.outcome // "pending"' "$record")"
  [ "${got:-0}" -eq "${want:-0}" ] || return 0
  case "$round_outcome" in success|degraded|failure) ;; *) return 0 ;; esac

  # `mkdir` is atomic, so exactly one reaper announces even when the last two
  # legs settle in the same second.
  mkdir "$dir/.notified" 2>/dev/null || return 0

  # Native ids can appear after `agent start` has already succeeded. Refresh the
  # whole round once, after every launched leg has settled, before announcing or
  # honoring a pending parent-session cleanup.
  refresh_leg_sessions

  local reports
  reports="$(jq -r '[.legs[]? | select(.outcome=="success")] | length' "$record")"
  # In-app notifications can intercept keyboard focus. Keep them opt-in; the
  # durable record and kun-status remain the default completion surfaces.
  if [ "${CTXREVIEW_NOTIFY:-0}" = 1 ]; then
    herdr notification show "review settled: ${label:-review}" \
      --body "$want legs terminal, $reports primary reports. Consolidate: ctxreview --consolidate $dir" \
      >/dev/null 2>&1 || true
  fi
  say "all $want legs terminal — outcome $round_outcome"

  # Settlement is a lifecycle heartbeat: retry owner-ended cleanup, reconcile
  # resources closed by hand, and enforce the conservative retention fallback.
  # The maintainer uses exact persisted ownership and never touches a working,
  # blocked, unknown, moved, or label-mismatched resource.
  cmd_maintain --all --trigger round_settled \
    >>"$dir/session-cleanup.log" 2>&1 || true
}

watch_leg() {  # watch_leg <tag> <agent>
  local tag="$1" agent="$2"
  ( if [ "$tag" = kimi ] || [ "$tag" = grok ]; then
      cursor_waited=0
      cursor_limit="${CTXREVIEW_CURSOR_TIMEOUT_SECONDS:-3600}"
      while [ "$cursor_waited" -lt "$cursor_limit" ]; do
        cursor_leg_settled "$agent" "$dir/$tag.md" && break
        sleep 1
        cursor_waited=$((cursor_waited+1))
      done
      if [ "$cursor_waited" -ge "$cursor_limit" ]; then
        say "$tag did not reach a verified Cursor footer or durable report"
        finalize_leg "$tag" failure cursor_timeout "" || true
        signal_terminal "$tag"
        exit 0
      fi
    else
      local wait_args=(--timeout "${CTXREVIEW_LEG_TIMEOUT_MS:-3600000}")
      if ! herdr agent wait "$agent" "${wait_args[@]}" >/dev/null 2>&1; then
        say "$tag did not reach a settled lifecycle state"
        finalize_leg "$tag" failure lifecycle_timeout "" || true
        signal_terminal "$tag"
        exit 0
      fi
      actual_status="$(herdr agent get "$agent" 2>/dev/null \
        | jq -r '.result.agent.agent_status // "unknown"' 2>/dev/null || true)"
      case "$actual_status" in
        blocked)
          say "$tag is blocked"
          finalize_leg "$tag" failure blocked "" || true
          signal_terminal "$tag"
          exit 0 ;;
        idle|done) ;;
        *)
          say "$tag is ${actual_status:-unknown}, not settled"
          finalize_leg "$tag" failure "lifecycle_${actual_status:-unknown}" "" || true
          signal_terminal "$tag"
          exit 0 ;;
      esac
    fi
    if [ ! -s "$dir/$tag.md" ]; then
      tail_out="$(herdr agent read "$agent" --source recent-unwrapped --lines 4000 2>/dev/null || true)"
      [ -n "$tail_out" ] \
        || tail_out="$(herdr agent read "$agent" --source recent 2>/dev/null || true)"
      [ -n "$tail_out" ] && printf '%s\n' "$tail_out" > "$dir/$tag.tail.md"
    fi
    if [ -s "$dir/$tag.md" ]; then
      finalize_leg "$tag" success primary_report "$dir/$tag.md" || true
    elif [ -s "$dir/$tag.tail.md" ]; then
      finalize_leg "$tag" degraded tail_only "$dir/$tag.tail.md" || true
    else
      finalize_leg "$tag" failure missing_artifact "" || true
    fi
    signal_terminal "$tag"
  # Detached output must not inherit the caller's descriptors or ctxreview will
  # appear to block until every reviewer finishes.
  ) >>"$dir/$tag.reaper.log" 2>&1 &
  disown 2>/dev/null || true
}

# The leg is asked to write this itself; the reaper is only a fallback.
write_pointer() {  # write_pointer <tag> <model-label> [oneline]
  local tag="$1" model="$2" oneline="${3:-}"
  local prompt_bytes prompt_lines
  prompt_bytes="$(wc -c < "$prompt" | tr -d ' ')"
  prompt_lines="$(wc -l < "$prompt" | tr -d ' ')"

  # Cursor gets ONE line. Everything else gets the readable multi-line form.
  #
  # A multi-line pointer lands in Cursor's composer and never submits: Enter
  # inserts a newline instead of sending. Verified from a real run -- the pane
  # showed "Run Everything" mode with the prompt still sitting behind the "→"
  # composer marker, so the leg was fully able to write and had simply never been
  # asked. That, not the sandbox, is why Cursor legs produced tails and no
  # reports.
  if [ -n "$oneline" ]; then
    printf 'Read %s in full (%s bytes, %s lines) and follow it exactly; your file reader may cap one read at 100000 characters, so continue in sequential chunks until EOF and verify you reached line %s — you are the "%s" leg (%s); write your finished report to %s, then stay up for follow-up questions; if the tooling fails, file it with: ctxreview --bug "<what broke, concretely>" ctxreview --run %s --leg %s --session %s (replace ctxreview with the concrete failing tool when needed).\n' \
      "$prompt" "$prompt_bytes" "$prompt_lines" "$prompt_lines" "$tag" "$model" \
      "$dir/$tag.md" "$current_run_id" "$tag" "$owner_session" > "$dir/$tag.prompt.md"
    return 0
  fi

  { printf 'Read %s in full (%s bytes, %s lines) and follow it exactly.\n' \
      "$prompt" "$prompt_bytes" "$prompt_lines"
    printf 'If one file read truncates (some cap at 100000 characters), continue in sequential chunks through line %s.\n' \
      "$prompt_lines"
    printf 'It has your review\n'
    printf 'instructions, the context pack, and the diff. Do not skim it.\n\n'
    printf 'You are the "%s" leg (%s). Write your finished report to:\n  %s\n\n' \
      "$tag" "$model" "$dir/$tag.md"
    # State that the path is writable and inside the workspace. A sandboxed leg
    # that assumes otherwise skips the write and prints instead, which loses
    # everything past the terminal tail.
    printf 'That path is inside this repository and writable — it is not blocked by\n'
    printf 'a read-only or workspace-scoped sandbox. Write the file. If the write\n'
    printf 'genuinely fails, say so explicitly and print the report in full.\n\n'
    printf 'Then stay up for follow-up questions.\n'
    printf '\nIf the tooling fails, file the defect with this attributed command:\n'
    printf '  ctxreview --bug "<what broke, concretely>" ctxreview --run %s --leg %s --session %s\n' \
      "$current_run_id" "$tag" "$owner_session"
    printf 'Replace the second ctxreview with ctxpack, herdr, corpus, or another concrete tool when appropriate.\n'
  } > "$dir/$tag.prompt.md"
}

# All four legs are interactive and stay conversible. Cursor goes through
# spawn-cursor-pane.sh because that script proves "Run Everything" mode from
# Cursor's own footer and fails loudly, so a config race surfaces as a failed
# spawn rather than a pane that quietly does nothing. Staggered for the same
# reason: only Cursor contends on ~/.cursor/cli-config.json.
want kimi && launch_cursor "$CURSOR_KIMI" kimi
want grok && { sleep 4; launch_cursor "$CURSOR_GROK" grok; }

# Codex and Claude have their own Herdr agent kinds, so they get the same
# lifecycle as the Cursor legs: `herdr agent list/wait/read`, and a pane you can
# type into. Both were verified to start and detect (agent=codex/claude,
# status=idle, interactive_ready=true).
want sol  && { write_pointer sol  "codex $CODEX_SOL";    launch_agent sol  codex \
  "${CODEX_NO_MCP_ARGS[@]}" -m "$CODEX_SOL"; }
if want opus; then
  write_pointer opus "claude $CLAUDE_OPUS_LABEL"
  if [ -n "$CLAUDE_OPUS" ]; then
    launch_agent opus claude --model "$CLAUDE_OPUS" \
      --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
      --permission-mode plan --dangerously-skip-permissions
  else
    launch_agent opus claude --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
      --permission-mode plan --dangerously-skip-permissions
  fi
fi
touch "$dir/.launch-complete"
signal_terminal ""

cat <<EOF

── ctxreview up ──────────────────────────────────────────────
$( [ -n "$ws" ] && printf 'workspace %s (dedicated)\n' "$ws" || printf 'tab in current workspace\n' )
$( [ -n "$HERDR_SESSION_NAME" ] && printf 'herdr    %s (isolated named session)\n' "$HERDR_SESSION_NAME" )
label    $label
dir      $dir
base     $resolved_base
legs     $legs
session  $owner_session

  pack     $pack
  prompt   $prompt
  results  $dir/<leg>.md        (written by the leg)
           $dir/<leg>.tail.md   (only if a leg wrote nothing)

Attach directly to a leg:        $SELF --attach $current_run_id sol
Detach from direct attach:       ctrl+b q
List what is still running:      $SELF --list
Tail a finished leg instead:     less $dir/<leg>.md
Hibernate all legs safely:       $SELF --close-session $owner_session
Restore conversations later:     $SELF --respawn $current_run_id
Later, when the id has scrolled away:  $SELF --list
Close this session's settled reviews:  $SELF --close --done
Inspect automatic lifecycle telemetry: $SELF --stats $owner_session



Consolidating: a finding two legs raise independently is high confidence. A
finding only one raises is a lead — verify it against the diff yourself before
acting. Treat all four as dissent, not authority.
EOF

if [ -n "$failed_legs" ]; then
  say "failed legs:${failed_legs}"
  exit 1
fi
