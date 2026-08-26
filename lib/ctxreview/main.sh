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

usage() {
  cat <<EOF
$SELF — fan a context pack out to four reviewer panes in a Herdr review workspace

USAGE
  $SELF run --legs LIST [--base REF] [--label TEXT] [--dir DIR]

OPTIONS
  --base REF    Diff base. Default: ctxpack's own (merge-base with default branch).
  --legs LIST   Required comma-separated subset of: kimi,grok,sol,opus
  --label TEXT  Tab label. Default: "review: <branch>"
  --dir DIR     Where pack/prompt/results go. Default: a fresh mktemp -d.
  --dry-run     Build the pack and prompt, print the plan, spawn nothing.
  --force       Ship a prompt over the size cap anyway (default cap 400000 bytes).
  --max-bytes N Change the cap.
  --focus TOPIC Run a FOCUSED round. Matches TOPIC against the lens corpus (id,
                title, body; falls back to a stem) and inlines those lenses in
                FULL — a normal pack only lists titles. The reviewers are told to
                report only that class, to park anything else in a one-line list,
                and to say explicitly when they find nothing.
                An unmatched topic is refused, not run unfocused: "found nothing"
                must not be confusable with "the corpus has no checks for this".
  --again       Retire the previous review workspace for this repo, then run a
                fresh round against the current diff. Refuses while a prior leg
                is still working. New legs are deliberately blind to the last
                round: a leg shown prior findings drifts toward confirming them.
  --herdr-session NAME
                Use NAME for the isolated Herdr session instead of generating
                one. Requires Herdr 0.8+. The name is persisted with the run.
  --session ID  Parent Codex/Claude session that owns this round. Defaults to
                CTXREVIEW_SESSION_ID, CODEX_THREAD_ID, or CLAUDE_SESSION_ID.
                Ownership is persisted with each reviewer runtime session so a
                session-end hook can close only this session's review panes.

  --sessions [ID]
                List persisted review rounds, optionally for one parent session.
  --stats [ID]  Show lifecycle telemetry and current persisted/live state,
                optionally for one parent session.
  --maintain    Run the safe lifecycle manager. It reconciles records whose
                exact resources are already absent, closes owner-ended rounds
                after their legs settle, and closes long-settled rounds after
                the retention window. Owner-ended sessions that remain idle
                beyond their own TTL are hibernated even when Cursor's footer
                is inconclusive. Working, blocked, unknown, moved, or
                label-mismatched resources are never closed.
                  --session ID       one parent session (default: current)
                  --all              every persisted ctxreview round
                  --settled-ttl MIN  fallback retention, default 1440
                  --owner-ended-idle MIN
                                      idle abandonment TTL, default 1440
  --close-session ID
                Capture runtime ids/tails and close settled review workspaces
                owned by ID. Working or blocked legs are left alone.
  --session-ended ID
                Mark the parent session ended and run safe maintenance. The
                SessionEnd hook uses this; the last leg retries cleanup when the
                round settles, and the same pass reconciles fleet stragglers.
  --respawn RUN  Reopen the persisted reviewer conversations for RUN. Named
                Herdr restores the saved layout and native agent sessions.
  --attach RUN LEG
                Resume RUN if needed, then attach this terminal directly to its
                kimi, grok, sol, or opus agent. Detach with ctrl+b q.

  --list        Show review workspaces and their legs with live status. Legs are
                left running while their parent is active so you can keep
                talking to them; lifecycle state shows what still holds a session.
  --close X     Hibernate one persisted RUN, or:
                  --done   every settled review owned by --session (or the
                           current harness session)
                  --all    every safely settled persisted review
                Working, blocked, unknown, or untracked agents are never stopped.
  --consolidate DIR
                Merge the legs' reports into one list, agreement first. Reports
                per-leg parse coverage rather than silently dropping a leg whose
                format it could not read. Groups on file:LINE, never on file
                alone — two findings in a busy file are not a consensus.
  --adjudicate DIR [--commit]
                Close the feedback loop. Without --commit, writes a worksheet of
                the consolidated findings with a blank verdict column. Fill in
                accepted|refuted|deferred plus a reason, then re-run with
                --commit to append to the corpus in the same schema
                \`ctxpack harvest\` writes. A refutation carrying a domain fact is
                what bible rules are made of, and nothing can reconstruct it later.
  --bug TEXT [TOOL]
                File a defect against the TOOLING (default tool: ctxreview).
                Separate channel from --adjudicate: that records verdicts about
                the code under review, this records what is broken in the harness.
                Review legs are told they can file too — a leg that trips over a
                tool defect is the best reporter of it.
                  --run ID           originating review run
                  --leg NAME         originating reviewer leg
                  --session ID       originating parent session
  --bugs [open|fixed|all]   List filed defects (default: open).
  --bug-fixed ID            Mark one fixed.
LEGS
  kimi  Cursor  $CURSOR_KIMI
  grok  Cursor  $CURSOR_GROK
  sol   Codex   $CODEX_SOL
  opus  Claude  $CLAUDE_OPUS_LABEL

All four run as interactive agents in their own pane and stay conversible — ask
one to defend a finding, go deeper, or keep going. Each writes its report to
DIR/<leg>.md, which is the durable copy: a pane retains only about a screenful.

Panes stay open while the parent session is active. Read them, close them early
if desired, or let SessionEnd/retention reclaim them. Each leg writes its report
to DIR/<leg>.md; if one finishes without writing, its terminal tail is captured
to DIR/<leg>.tail.md instead — never over the report, and never as an empty file.

ENVIRONMENT
  CTXREVIEW_KIMI / _GROK / _SOL            override a model id
  CTXREVIEW_OPUS                            override the managed Opus 5 1M default
  CTXREVIEW_CURSOR_SPAWN                     override the Cursor pane helper
  CTXREVIEW_SETTLED_RETENTION_MINUTES       fallback cleanup age (default 1440)
  CTXREVIEW_OWNER_ENDED_IDLE_MINUTES        idle abandonment age (default 1440)
  CTXREVIEW_FAILURE_RATE_TARGET_PERCENT     OKR failure-rate target (default 5)
  CTXREVIEW_NOTIFY=1                        opt into Herdr completion toasts
EOF
}

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

# Route every pane/agent operation through the run's named Herdr 0.8 session.
# `command` bypasses this function so global session management remains possible.
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

named_session_running() {  # named_session_running <name>
  local name="$1"
  herdr_global session list --json 2>/dev/null | jq -e --arg name "$name" \
    '.sessions[]? | select(.name==$name and .running==true)' >/dev/null 2>&1
}

named_session_exists() {  # named_session_exists <name>
  local name="$1"
  herdr_global session list --json 2>/dev/null | jq -e --arg name "$name" \
    '.sessions[]? | select(.name==$name)' >/dev/null 2>&1
}

start_named_session() {  # start_named_session <name>
  local name="$1" bin log attempt status
  HERDR_SESSION_NAME="$name"
  if named_session_running "$name"; then return 0; fi
  bin="$(herdr_bin)" || return 1
  mkdir -p "$SESSION_STATE_DIR/herdr-logs"
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

review_agents() {  # name<TAB>pane<TAB>status<TAB>workspace<TAB>kind
  herdr agent list 2>/dev/null \
    | jq -r '.result.agents[]? | select(.name // "" | startswith("ctxreview-"))
             | "\(.name)\t\(.pane_id)\t\(.agent_status // "?")\t\(.workspace_id // "?")\t\(.agent // "?")"'
}

# Durable ownership and runtime-session metadata.
#
# Herdr panes are disposable; Codex, Claude, and Cursor conversations are not.
# Keep the parent harness session, exact workspace, and each runtime's native
# session id in a small JSON record. Cleanup can then address an explicit set of
# workspaces instead of guessing from a global name prefix, and --respawn can
# reopen the same conversations after their panes have been reclaimed.
session_runs_dir() { printf '%s/runs' "$SESSION_STATE_DIR"; }

valid_session_id() {
  case "${1:-}" in
    ""|*[!A-Za-z0-9._:-]*) return 1 ;;
    *) [ "${#1}" -le 160 ] ;;
  esac
}

valid_leg() {
  case "${1:-}" in kimi|grok|sol|opus) return 0 ;; *) return 1 ;; esac
}

validate_legs() {
  local value="${1:-}" leg seen=","
  [ -n "$value" ] || die "--legs needs at least one of: kimi,grok,sol,opus"
  case "$value" in
    ,*|*,|*,,*) die "invalid --legs value: empty reviewer name" ;;
  esac
  IFS=',' read -r -a parsed_legs <<< "$value"
  [ "${#parsed_legs[@]}" -gt 0 ] || die "--legs needs at least one reviewer"
  for leg in "${parsed_legs[@]}"; do
    valid_leg "$leg" || die "invalid --legs value: ${leg:-<empty>} (choose kimi,grok,sol,opus)"
    case "$seen" in
      *",$leg,"*) die "duplicate --legs value: $leg" ;;
      *) seen="$seen$leg," ;;
    esac
  done
}

session_record_path() { printf '%s/%s.json' "$(session_runs_dir)" "$1"; }

record_run_dir() {  # record_run_dir <record>
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

# Detached leg reapers and maintenance can finish in the same instant. All
# record mutations use one per-run lock and always read the canonical record
# after acquiring it, so a late writer cannot replace another leg's outcome.
acquire_file_lock() {  # acquire_file_lock <path>
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

append_line_locked() {  # append_line_locked <file> <line>
  local file="$1" line="$2" lock="${1}.lock"
  acquire_file_lock "$lock" || return 1
  printf '%s\n' "$line" >> "$file" 2>/dev/null
  local rc=$?
  release_file_lock "$lock"
  return "$rc"
}

# Append-only lifecycle telemetry. Records remain the current-state source of
# truth; this log explains how they got there and makes cleanup effectiveness,
# hook mismatches, and useful retention windows measurable. Each event is one
# compact JSON object so concurrent detached reapers can append independently.
record_event() {  # event run owner outcome reason [leg] [workspace]
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

record_identity() {  # record_identity <record> -> run<TAB>owner
  jq -r '[.run_id // "",.owner_session // ""] | @tsv' "$1" 2>/dev/null
}

persist_session_record() {  # persist_session_record <local-record>
  local record="$1" run_id target tmp
  run_id="$(jq -r '.run_id // empty' "$record" 2>/dev/null)"
  [ -n "$run_id" ] || return 1
  mkdir -p "$(session_runs_dir)"
  target="$(session_record_path "$run_id")"
  tmp="$target.tmp.$$"
  cp "$record" "$tmp" && chmod 600 "$tmp" && mv "$tmp" "$target"
}

# An empty `mcp_servers={}` command-line override does not replace the user's
# configured table; Codex merges it and still starts every existing server. Ask
# Codex for the effective server names and disable each one explicitly. Server
# ids are TOML bare keys in Codex's own configuration contract, so refuse an
# unexpected id rather than accidentally starting it in a review pane.
prepare_codex_no_mcp_args() {
  [ "$CODEX_NO_MCP_READY" -eq 0 ] || return 0
  local codex_bin raw effective id
  codex_bin="$(type -P codex 2>/dev/null || command -v codex 2>/dev/null || true)"
  [ -n "$codex_bin" ] || die "codex not found"
  raw="$("$codex_bin" mcp list --json 2>/dev/null)" \
    || die "could not enumerate Codex MCP servers for review isolation"
  printf '%s' "$raw" | jq -e \
    'type=="array" and all(.[]; (.name | type)=="string")' >/dev/null 2>&1 \
    || die "Codex MCP inventory had an unexpected schema"
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$id" in
      *[!A-Za-z0-9_-]*) die "cannot safely disable Codex MCP server id: $id" ;;
    esac
    CODEX_NO_MCP_ARGS+=( -c "mcp_servers.$id.enabled=false" )
  done < <(printf '%s' "$raw" | jq -r '.[]?.name // empty')
  # Apps/connectors are another MCP-backed tool surface. Review legs only need
  # the repository and shell, so disable their default tool exposure too.
  CODEX_NO_MCP_ARGS+=( -c 'apps._default.enabled=false' )
  effective="$("$codex_bin" "${CODEX_NO_MCP_ARGS[@]}" mcp list --json 2>/dev/null)" \
    || die "could not verify Codex MCP isolation"
  printf '%s' "$effective" | jq -e \
    'type=="array" and all(.[]; .enabled==false)' >/dev/null 2>&1 \
    || die "Codex MCP isolation did not disable every effective server"
  CODEX_NO_MCP_READY=1
}

prepare_cursor_config() {  # prepare_cursor_config <dir> <workspace>
  local config_dir="$1" workspace="${2:-$PWD}" tmp cursor_bin listing line id after
  cursor_bin="$(type -P cursor-agent 2>/dev/null || command -v cursor-agent 2>/dev/null || true)"
  [ -n "$cursor_bin" ] || return 1
  mkdir -p "$config_dir" 2>/dev/null || return 1
  tmp="$(mktemp "$config_dir/mcp.json.tmp.XXXXXX" 2>/dev/null)" || return 1
  if ! printf '{"mcpServers":{}}\n' > "$tmp" || ! mv "$tmp" "$config_dir/mcp.json"; then
    rm -f "$tmp"
    return 1
  fi
  [ "$(cat "$config_dir/mcp.json" 2>/dev/null)" = '{"mcpServers":{}}' ] || return 1

  # CURSOR_CONFIG_DIR redirects CLI approvals, but Cursor still discovers MCP
  # definitions from both <workspace>/.cursor/mcp.json and ~/.cursor/mcp.json.
  # Enumerate that effective inventory and disable every id in the isolated CLI
  # state, then verify the only remaining state is `disabled`.
  listing="$(cd "$workspace" && CURSOR_CONFIG_DIR="$config_dir" "$cursor_bin" mcp list 2>/dev/null)" \
    || return 1
  case "$listing" in
    "No MCP servers configured"*) return 0 ;;
  esac
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      *": disabled") continue ;;
      *:*) id="${line%%:*}" ;;
      *) return 1 ;;
    esac
    [ -n "$id" ] || return 1
    (cd "$workspace" && CURSOR_CONFIG_DIR="$config_dir" \
      "$cursor_bin" mcp disable "$id" >/dev/null 2>&1) || return 1
  done <<< "$listing"
  after="$(cd "$workspace" && CURSOR_CONFIG_DIR="$config_dir" "$cursor_bin" mcp list 2>/dev/null)" \
    || return 1
  case "$after" in
    "No MCP servers configured"*) return 0 ;;
  esac
  while IFS= read -r line; do
    [ -z "$line" ] || case "$line" in *": disabled") ;; *) return 1 ;; esac
  done <<< "$after"
}

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

cmd_sessions() {  # cmd_sessions [owner]
  local owner="${1:-}" files=() f rows="$WORK_C/session-rows.tsv" total=0
  mkdir -p "$(session_runs_dir)"
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
  mkdir -p "$(session_runs_dir)"
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

cmd_list() {
  local agents any=0 record name run running sessions
  sessions="$(herdr_global session list --json 2>/dev/null || printf '{"sessions":[]}')"
  printf '%-28s %-12s %-42s %s\n' SESSION STATE LABEL LEGS
  for record in "$(session_runs_dir)"/*.json; do
    [ -s "$record" ] || continue
    name="$(jq -r '.herdr_session_name // empty' "$record")"
    [ -n "$name" ] || continue
    run="$(jq -r '.run_id // "?"' "$record")"
    running="$(printf '%s' "$sessions" | jq -r --arg name "$name" \
      '[.sessions[]? | select(.name==$name and .running==true)] | length')"
    if [ "$running" -eq 1 ]; then
      HERDR_SESSION_NAME="$name"
      agents="$(review_agents | awk -F'\t' '{printf "%s(%s) ", substr($1,11), $3}')"
      printf '%-28s %-12s %-42s %s\n' "$name" running \
        "$(jq -r '.label // "?"' "$record" | cut -c1-42)" "${agents:-(restoring)}"
    else
      printf '%-28s %-12s %-42s %s\n' "$name" stopped \
        "$(jq -r '.label // "?"' "$record" | cut -c1-42)" \
        "resume: $SELF --respawn $run"
    fi
    any=1
  done

  [ "$any" -eq 1 ] || printf '(no review sessions)\n'
}

cmd_consolidate() {
  local dir="${1:-}"
  [ -n "$dir" ] && [ -d "$dir" ] || die "usage: $SELF --consolidate <run-dir>"

  local rows="$WORK_C/rows.tsv"; : > "$rows"
  local leg f src parsed total=0

  # Did the tree move under the legs? Findings cite file:line, so a changed tree
  # makes every line number a guess and means the legs did not all review the
  # same snapshot.
  if [ -s "$dir/.tree-fingerprint" ]; then
    local now_fp was_fp
    was_fp="$(cat "$dir/.tree-fingerprint")"
    now_fp="$({ git status --porcelain 2>/dev/null; git rev-parse HEAD 2>/dev/null; } \
              | shasum 2>/dev/null | awk '{print $1}')"
    if [ -n "$now_fp" ] && [ "$now_fp" != "$was_fp" ]; then
      printf '> ⚠️ **The working tree changed since this round started.**\n>\n'
      printf '> Every finding below cites a file:line from the original snapshot, so\n'
      printf '> line numbers may no longer match and the legs may not all have seen\n'
      printf '> the same code. Re-run with `--again` rather than trusting these.\n\n'
    fi
  fi

  printf '## Parse coverage\n\n'
  for leg in kimi grok sol opus; do
    f=""; src=""
    [ -s "$dir/$leg.md" ] && { f="$dir/$leg.md"; src="report"; }
    [ -z "$f" ] && [ -s "$dir/$leg.tail.md" ] && { f="$dir/$leg.tail.md"; src="terminal tail (leg wrote no report)"; }
    if [ -z "$f" ]; then
      printf -- '- %-5s **no output** — nothing to consolidate\n' "$leg"; continue
    fi
    # Strip ANSI and box-drawing so a terminal capture still yields findings.
    # Strip decoration as whole characters, and read as bytes.
    #
    # This used to `tr -d` the individual bytes of UTF-8 box-drawing glyphs, which
    # left invalid byte sequences mid-character; awk then died with "towc:
    # multibyte conversion failure" and the leg was reported as unparseable. It
    # also silently mangled every em dash and arrow in a legitimate report.
    #
    # LC_ALL=C makes awk byte-oriented, so no input can trip its decoder.
    parsed="$(sed $'s/\033\\[[0-9;]*[A-Za-z]//g' "$f" \
      | sed 's/▎//g; s/│//g; s/─//g; s/┌//g; s/└//g; s/├//g; s/✽//g; s/✶//g' \
      | LC_ALL=C awk -v leg="$leg" '
          # Block-based, not line-based. A finding title wraps across lines, so
          # reading one line at a time truncated them mid-sentence ("...on every
          # call, and"). And a leg often cites file:line in its Evidence line
          # rather than beside the title, so the location is searched across the
          # whole block -- without it, two legs describing one defect never
          # matched and agreement always read as zero.
          function flush() {
            if (buf == "") return
            title=""; loc=""
            if (match(buf, /\*\*[^*]+\*\*/)) {
              title = substr(buf, RSTART+2, RLENGTH-4)
            }
            # First backticked token that looks like a path, anywhere in the block.
            rest = buf
            while (match(rest, /`[^`]+`/)) {
              cand = substr(rest, RSTART+1, RLENGTH-2)
              # `\/` matters: awk ends a regex literal at a bare slash even
              # inside a character class, which made this a syntax error.
              if (cand ~ /[A-Za-z0-9_\/.-]+\.[A-Za-z]+(:[0-9]+)?$/) { loc = cand; break }
              rest = substr(rest, RSTART+RLENGTH)
            }
            gsub(/[[:space:]]+/, " ", title)
            gsub(/^ | $/, "", title)
            if (length(title) > 8)
              printf "%s\t%s\t%s\t%s\n", leg, (sev?sev:"Unclassified"), loc, title
            buf=""
          }
          /^#+[[:space:]]*(Critical|Important|Observation|Blocking|Nit)/ {
            flush(); sev=$0; gsub(/^#+[[:space:]]*/,"",sev); gsub(/[^A-Za-z].*$/,"",sev); next }
          /^#+[[:space:]]/ { flush(); next }
          {
            line=$0
            gsub(/^[[:space:]|+>-]*/,"",line)
            # Two shapes legs actually emit:
            #   1. **title** — `file:line`     (what the prompt asks for)
            #   **1. title** — `file:line`     (what opus wrote, 23 KB of it)
            #
            # Requiring the first scored a perfectly good report as 0 findings.
            # Ask for a format, accept what arrives.
            #
            # Deliberately NOT accepting "- **bold**": in that same report those
            # are sub-points *inside* a finding, so treating them as findings
            # inflated one defect into five.
            if (line ~ /^([0-9]+\.[[:space:]]*)?\*\*/) { flush(); buf=line }
            else if (buf != "") buf = buf " " line
          }
          END { flush() }' )"
    local n; n="$(printf '%s\n' "$parsed" | grep -c . || true)"
    total=$((total + n))
    printf '%s\n' "$parsed" | grep . >> "$rows" || true
    # Distinguish "the leg died" from "the leg said nothing useful".
    #
    # A Kimi K3 leg was killed mid-review by "Error: High Load" — provider
    # capacity, not a local defect and not a clean bill of health. Reported as
    # "0 findings parsed" it looked identical to a leg that ran fine and found
    # nothing, which is the same conflation L34 is about. A round that lost a leg
    # to capacity has three opinions, not four, and you should know which.
    local died=""
    case "$(tr -d '\0' < "$f" 2>/dev/null)" in
      *"High Load"*|*"high demand"*)        died="provider capacity (High Load)" ;;
      *"rate limit"*|*"Rate limit"*)        died="provider rate limit" ;;
      *"context length"*|*"too long"*)      died="context length exceeded" ;;
      *"Interrupted"*)                      died="interrupted mid-run" ;;
    esac

    if [ -n "$died" ] && [ "${n:-0}" -eq 0 ]; then
      printf -- '- %-5s %s — **leg did not finish: %s**\n' "$leg" "$src" "$died"
      printf -- '  This round has fewer opinions than legs. Not a clean result.\n'
    elif [ "${n:-0}" -eq 0 ]; then
      printf -- '- %-5s %s — **0 findings parsed** (format unrecognised; read it by hand)\n' "$leg" "$src"
    elif [ -n "$died" ]; then
      printf -- '- %-5s %s — %s findings, but %s: may be incomplete\n' "$leg" "$src" "$n" "$died"
    else
      printf -- '- %-5s %s — %s findings\n' "$leg" "$src" "$n"
    fi
  done

  [ "$total" -gt 0 ] || { printf '\nNo findings parsed from any leg. Read the reports directly.\n'; return 0; }

  # Group by location when present, else by the longest title words. Location is
  # the reliable key: two legs describing one defect agree on file:line far more
  # often than on wording.
  printf '\n## Findings, agreement first\n\n'
  awk -F'\t' '
    { key = $3
      if (key == "") { n=split(tolower($4),w," "); key=""
        for (i=1;i<=n && i<=4;i++) if (length(w[i])>5) key = key w[i] }
      # Key on file:LINE, never on file alone. Stripping the line merged
      # sol at fact_store.py:329 with opus at fact_store.py:330 -- two unrelated
      # findings -- into one entry tagged [2 legs]. Two findings in a busy file
      # are not a consensus, and false agreement is the worst defect a
      # consolidator can have, because agreement is the signal acted on without
      # re-deriving. Under-merge on purpose: a missed agreement costs a second
      # look, an invented one costs a wrong fix.
      # (No apostrophes in this awk block: it sits in a single-quoted shell
      # string and one would terminate the program.)
      legs[key] = legs[key] (index(legs[key],$1)?"":($1 " "))
      if (!(key in sev) || rank($2) > rank(sev[key])) sev[key]=$2
      if (!(key in title)) title[key]=$4
      cnt[key] = split(legs[key], tmp, " ") - 1
    }
    function rank(s) { return (s=="Critical"||s=="Blocking") ? 3 : (s=="Important" ? 2 : 1) }
    END {
      for (k in cnt) printf "%d\t%d\t%s\t%s\t%s\n", cnt[k], rank(sev[k]), sev[k], legs[k], title[k] }
  ' "$rows" | sort -rn -k1,1 -k2,2 | awk -F'\t' '
    $1 >= 2 { if (!m++) print "### Raised independently by more than one leg\n"
              printf "- **%s** _(%s)_ — [%d legs: %s]\n", $5, $3, $1, $4 }
    END { if (!m) print "### Raised independently by more than one leg\n\n(none — each finding came from a single leg)\n" }'
  printf '\n'
  awk -F'\t' '
    { key = $3
      if (key == "") { n=split(tolower($4),w," "); key=""
        for (i=1;i<=n && i<=4;i++) if (length(w[i])>5) key = key w[i] }
      # Full file:LINE, matching the agreement pass. Stripping the line here too
      # produced the same false merge in the leads list.
      legs[key] = legs[key] (index(legs[key],$1)?"":($1 " "))
      if (!(key in title)) { title[key]=$4; sv[key]=$2; loc[key]=$3 }
      cnt[key] = split(legs[key], tmp, " ") - 1 }
    END { print "### Single-leg leads — verify against the diff before acting\n"
          for (k in cnt) if (cnt[k] < 2)
            printf "- **%s** _(%s, %s)_%s\n", title[k], sv[k], legs[k], (loc[k]?" — `" loc[k] "`":"") }
  ' "$rows"

  printf '\n> Agreement raises confidence, it does not confer correctness: two legs\n'
  printf '> can share a wrong assumption. Verify before acting, and record what you\n'
  printf '> decided with `%s --adjudicate %s`.\n' "$SELF" "$dir"
}

# Close the feedback loop: local findings -> adjudicated verdicts -> the corpus.
#
# `ctxpack harvest` teaches the bible from remote PR threads. Until this existed,
# a local four-model review taught it nothing: every round paid full price and
# left no deposit, which is the difference between a system that compounds and
# four tools that happen to be in the same directory.
#
# Two phases, no prompting. `--adjudicate` writes a worksheet of the consolidated
# findings with a blank verdict per line; you fill it in; `--adjudicate --commit`
# appends the filled rows to adjudications.jsonl in the schema `harvest` writes.
# Emit-then-commit rather than an interactive questionnaire, because a reviewer
# fills this in while reading the diff, not in one sitting at a prompt.
ADJ_FILE="${CTXPACK_BIBLE_DIR:-${SECOND_BRAIN_DIR:-$HOME/repos/dump/second-brain}/review}/adjudications.jsonl"

cmd_adjudicate() {
  local dir="${1:-}" commit=0
  shift || true
  [ "${1:-}" = "--commit" ] && commit=1
  [ -n "$dir" ] && [ -d "$dir" ] || die "usage: $SELF --adjudicate <run-dir> [--commit]"
  local sheet="$dir/adjudication.tsv"

  if [ "$commit" -eq 0 ]; then
    if [ -s "$sheet" ]; then
      say "worksheet already exists: $sheet"
      say "fill the verdict column, then: $SELF --adjudicate $dir --commit"
      return 0
    fi
    local repo branch
    repo="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo unknown)")"
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    {
      printf '# ctxreview adjudication worksheet — %s @ %s\n' "$repo" "$branch"
      printf '#\n# Set VERDICT to one of: accepted | refuted | deferred\n'
      printf '# Add REASON. A refutation with a domain fact is the most valuable\n'
      printf '# artefact here — it is what the bible rules are made of, and it is the\n'
      printf '# one thing no amount of re-reviewing can reconstruct later.\n'
      printf '# Leave VERDICT blank to skip a finding. Then:\n'
      printf '#   %s --adjudicate %s --commit\n#\n' "$SELF" "$dir"
      printf '# VERDICT\tLEG\tSEVERITY\tLOCATION\tFINDING\tREASON\n'
      cmd_consolidate "$dir" 2>/dev/null \
        | awk '/^- \*\*/ {
            # Cut at the LAST "** _(" rather than splitting on "**".
            #
            # Field-splitting on ** truncated any title containing a literal **
            # (a backticked `**`, an emphasis inside the sentence), which shifted
            # every later column and produced rows whose VERDICT was a leg name.
            # The commit path rejected those loudly, but a worksheet you cannot
            # trust is worse than a missing one.
            line=$0
            sub(/^- \*\*/, "", line)
            marker=index(line, "** _(")
            if (marker == 0) next
            title = substr(line, 1, marker - 1)
            rest  = substr(line, marker)
            sev=""; legs=""; loc=""
            if (match(rest, /_\([^)]*\)_/)) { m=substr(rest,RSTART+2,RLENGTH-4); split(m,a,", "); sev=a[1]; legs=a[2] }
            if (match(rest, /`[^`]+`/)) loc=substr(rest,RSTART+1,RLENGTH-2)
            gsub(/[[:space:]]+$/,"",legs)
            gsub(/\t/," ",title)
            printf "\t%s\t%s\t%s\t%s\t\n", legs, sev, loc, title }'
    } > "$sheet"
    local n; n="$(grep -cv '^#' "$sheet" || true)"
    say "worksheet: $sheet ($n findings)"
    say "fill the VERDICT column, then: $SELF --adjudicate $dir --commit"
    return 0
  fi

  [ -s "$sheet" ] || die "no worksheet at $sheet — run $SELF --adjudicate $dir first"
  local repo branch who n=0
  repo="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo unknown)")"
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
  who="${CTXREVIEW_ADJUDICATOR:-$(git config user.name 2>/dev/null || true)}"
  who="${who:-${USER:-local-author}}"
  mkdir -p "$(dirname "$ADJ_FILE")"
  while IFS=$'\t' read -r verdict legs sev loc finding reason; do
    case "$verdict" in ''|'#'*|VERDICT) continue ;; esac
    case "$verdict" in
      accepted|refuted|deferred) ;;
      *) say "skip: unknown verdict \"$verdict\" for: ${finding:0:50}"; continue ;;
    esac
    # Same schema harvest writes, plus `source` so local rounds are
    # distinguishable. Weighting: an adjudicated local finding carries a REASON,
    # which the corpus already ranks above a merely-stated remote one -- so it is
    # equal evidence once adjudicated, and none before.
    jq -nc --arg repo "local/$repo" --arg branch "$branch" --arg by "ctxreview-$legs" \
           --arg path "$loc" --arg finding "$finding" --arg sev "$sev" \
           --arg verdict "$verdict" --arg reason "$reason" --arg who "$who" \
      '{repo:$repo, pr:0, branch:$branch, path:$path, by:$by, severity:$sev,
        finding:$finding, replies:[{who:$who, body:$reason}],
        adjudication:"replied", verdict:$verdict, source:"ctxreview"}' \
      >> "$ADJ_FILE"
    n=$((n+1))
  done < "$sheet"
  sort -u "$ADJ_FILE" -o "$ADJ_FILE"
  say "appended $n adjudications — corpus now $(wc -l < "$ADJ_FILE" | tr -d ' ') threads"
  [ "$n" -gt 0 ] && say "refutations with a domain fact are bible-rule material: see $ADJ_FILE"
}

# A defect log for the TOOLING, distinct from the corpus.
#
# `--adjudicate` records verdicts about the code under review. This records
# defects in ctxpack/ctxreview/kun-status themselves — the loop where the system
# improves itself. Roughly fifteen such bugs surfaced while building this and were
# recorded only as prose in PLAN.md, which is unqueryable and drifts.
#
# Any agent can file one: a review leg that trips over a tool defect is the best
# possible reporter, because it hit the thing in anger. So filing is one command
# with no ceremony and no repo state — `bd` exists but this repo has no `.beads`,
# and requiring an init would mean a leg in a fresh checkout cannot report.
#
# Lives in user state, not the repo: a bug filed mid-review must not add diff churn
# to the very change being reviewed.
BUGS_FILE="${CTXREVIEW_BUGS_FILE:-$HOME/.local/state/ctxreview/bugs.jsonl}"

cmd_bug() {
  local text="${1:-}" tool="${2:-ctxreview}"
  [ -n "$text" ] || die "usage: $SELF --bug \"<what broke>\" [tool]"
  [ -z "$bug_run" ] || valid_session_id "$bug_run" || die "invalid --run id"
  [ -z "$bug_leg" ] || valid_leg "$bug_leg" || die "invalid --leg name"
  [ -z "$owner_session" ] || valid_session_id "$owner_session" || die "invalid --session id"
  mkdir -p "$(dirname "$BUGS_FILE")"
  local id repo line
  # Second-granularity ids collided immediately: three bugs filed in the same
  # second shared an id, which would make --bug-fixed close an arbitrary one of
  # them. $RANDOM disambiguates without needing a lock or a counter file.
  id="b$(date +%y%m%d%H%M%S)-$RANDOM"
  repo="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo '-')")"
  line="$(jq -nc --arg id "$id" --arg tool "$tool" --arg text "$text" \
         --arg repo "$repo" --arg when "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         --arg run "$bug_run" --arg leg "$bug_leg" --arg owner "$owner_session" \
    '{id:$id, tool:$tool, status:"open", filed:$when, repo:$repo, text:$text,
      run_id:$run,leg:$leg,owner_session:$owner} |
     with_entries(select(.value != ""))')" || die "could not encode bug"
  append_line_locked "$BUGS_FILE" "$line" || die "could not append $BUGS_FILE"
  chmod 600 "$BUGS_FILE" 2>/dev/null || true
  record_event tool_bug_filed "$bug_run" "$owner_session" filed "$id" "$bug_leg"
  printf 'bug:\n'
  printf '  id: %s\n  tool: %s\n  status: open\n' "$id" "$tool"
}

# Blocks, not a truncated table.
#
# The first version printed a fixed-width table that cut every defect at 84
# characters with no way to reach the rest — and the 19-character ids overflowed
# their column, so the fields did not even line up. A backlog you cannot read is
# not a backlog. `fold` wraps to the terminal instead of discarding text.
cmd_bugs() {
  local want="${1:-open}"
  [ -s "$BUGS_FILE" ] || { say "no bugs filed yet ($BUGS_FILE)"; return 0; }
  local cols="${COLUMNS:-100}"; [ "$cols" -ge 40 ] 2>/dev/null || cols=100

  jq -r --arg w "$want" 'select($w == "all" or .status == $w)
      | "\(.id)\t\(.status)\t\(.tool)\t\(.filed[0:10])\t\(.text)"' "$BUGS_FILE" 2>/dev/null \
    | while IFS=$'\t' read -r id st tool filed text; do
        printf '\n%s  [%s] %s  %s\n' "$id" "$st" "$tool" "$filed"
        printf '%s\n' "$text" | fold -s -w $((cols - 4)) | sed 's/^/    /'
      done

  local o c
  o="$(jq -r 'select(.status=="open")|1' "$BUGS_FILE" 2>/dev/null | grep -c . || true)"
  c="$(jq -r 'select(.status=="fixed")|1' "$BUGS_FILE" 2>/dev/null | grep -c . || true)"
  printf '\n── %s open, %s fixed ──\n' "${o:-0}" "${c:-0}"
  printf '  %s --bugs all          include fixed\n' "$SELF"
  printf '  %s --bug-fixed <id>    close one\n' "$SELF"
  printf '  %s --bugs-to-beads     promote open ones into bd (needs .beads here)\n' "$SELF"
}

# Promote open defects into beads, for the ones you actually intend to work.
#
# Filing stays in JSONL on purpose: a review leg in a fresh checkout has no
# `.beads`, and requiring an init would mean it cannot report at all. But JSONL is
# a capture buffer, not a tracker — it has no dependencies, priorities, or ready
# queue. So capture is frictionless and promotion is explicit, which also keeps
# junk out of bd.
#
# Idempotent: a promoted bug records its bead id and is skipped next time.
cmd_bugs_to_beads() {
  command -v bd >/dev/null || die "bd not installed"
  [ -s "$BUGS_FILE" ] || { say "no bugs filed"; return 0; }
  [ -d .beads ] || die "no .beads in $(pwd) — run \`bd init\` here first, or promote from a repo that has one"

  local promoted=0 id text tool bead tmp="$WORK_C/promote.jsonl"
  : > "$tmp"
  while IFS=$'\t' read -r id tool text; do
    [ -n "$id" ] || continue
    bead="$(bd create --title "[$tool] ${text:0:70}" --type bug --priority 2 2>&1 \
            | grep -oE '[a-z-]+-[0-9]+' | head -1 || true)"
    if [ -n "$bead" ]; then
      say "promoted $id -> $bead"
      printf '%s\t%s\n' "$id" "$bead" >> "$tmp"
      promoted=$((promoted + 1))
    else
      say "could not promote $id"
    fi
  done < <(jq -r 'select(.status=="open" and (.bead // "") == "")
                 | "\(.id)\t\(.tool)\t\(.text)"' "$BUGS_FILE" 2>/dev/null)

  if [ "$promoted" -gt 0 ]; then
    local out="$WORK_C/bugs-with-beads.jsonl" bug_lock="${BUGS_FILE}.lock" rc=0
    acquire_file_lock "$bug_lock" || die "could not lock $BUGS_FILE"
    jq -c --slurpfile ignore /dev/null '.' "$BUGS_FILE" > "$out" || rc=1
    while IFS=$'\t' read -r id bead; do
      [ "$rc" -eq 0 ] || break
      jq -c --arg id "$id" --arg bead "$bead" \
        'if .id == $id then .bead = $bead else . end' "$out" > "$out.n" \
        && mv "$out.n" "$out" || rc=1
    done < "$tmp"
    [ "$rc" -ne 0 ] || mv "$out" "$BUGS_FILE" || rc=1
    release_file_lock "$bug_lock"
    [ "$rc" -eq 0 ] || die "could not update $BUGS_FILE"
  fi
  say "promoted $promoted; bd ready shows what to work next"
}

cmd_bug_fixed() {
  local id="${1:-}"
  [ -n "$id" ] || die "usage: $SELF --bug-fixed <id>"
  [ -s "$BUGS_FILE" ] || die "no bugs filed"
  # Rewrite in place via a temp file; never edit the log with sed, which would
  # corrupt any text containing a delimiter.
  local tmp="$WORK_C/bugs.jsonl" bug_lock="${BUGS_FILE}.lock"
  acquire_file_lock "$bug_lock" || die "could not lock $BUGS_FILE"
  if ! jq -c --arg id "$id" --arg when "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      'if .id == $id then .status = "fixed" | .fixed = $when else . end' \
      "$BUGS_FILE" > "$tmp" 2>/dev/null; then
    release_file_lock "$bug_lock"
    die "could not rewrite $BUGS_FILE"
  fi
  if ! diff -q "$BUGS_FILE" "$tmp" >/dev/null 2>&1; then
    if mv "$tmp" "$BUGS_FILE"; then
      release_file_lock "$bug_lock"
      say "closed $id"
    else
      release_file_lock "$bug_lock"
      die "could not replace $BUGS_FILE"
    fi
  else
    release_file_lock "$bug_lock"
    die "no bug with id $id"
  fi
}

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
  mkdir -p "$SESSION_STATE_DIR"
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
  mkdir -p "$capture_dir"
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
  mkdir -p "$(session_runs_dir)"
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
  mkdir -p "$(session_runs_dir)"
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
LENS_DIR="${CTXPACK_BIBLE_DIR:-${SECOND_BRAIN_DIR:-$HOME/repos/dump/second-brain}/review}/lenses"

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
mkdir -p "$dir"
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
