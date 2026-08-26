#!/usr/bin/env bash

# Spawn a Cursor subagent in a Herdr pane, in the right mode, and prove it.
#
# The failure this exists to prevent: a Cursor pane launched by hand stalls on
# something nobody is watching. Three ways that happens, all reproduced:
#
#   1. Launched without --force. Cursor asks to approve its first shell command.
#      `~/.cursor/cli-config.json` pre-allows only Shell(ls), Shell(git -C) and
#      Shell(echo), so "first command" means the first `git diff` or file read.
#      No prompt is ever answered and the pane sits there indefinitely.
#   2. Prompt typed but never submitted. `herdr agent prompt` puts text in
#      Cursor's input box without sending it. The pane looks healthy and is
#      doing nothing. This one is worse than a visible prompt.
#   3. Started against a pane whose shell has not settled: `herdr agent start`
#      returns agent_pane_busy and the caller moves on believing it spawned.
#
# So this script does not just launch: it verifies mode from Cursor's own footer
# ("Run Everything" is only shown under --force), verifies the prompt actually
# left the input box, and fails loudly rather than leaving a quiet pane behind.

set -uo pipefail

usage() {
  cat <<'EOF'
Usage: spawn-cursor-pane.sh --model MODEL [options]
       spawn-cursor-pane.sh --sweep [--force-sweep]

Options:
  --model MODEL         Cursor model id (resolve with `cursor-agent --list-models`)
  --name NAME           Agent name in Herdr (default: cursor-<model>-<pid>)
  --prompt TEXT         Prompt to submit after the agent is verified ready
  --prompt-file FILE    Read the prompt from a file instead
  --pane ID             Use an existing pane instead of creating a tab
  --cwd DIR             Working directory for a newly created tab (default: $PWD)
  --label TEXT          Tab label when creating one (default: ephemeral marker)
  --config-dir DIR      Isolated Cursor config directory (default:
                        ~/.local/state/cursor-sub-review/config).
  --plan                Read-only: adds --mode ask (use for review legs)
  --start-timeout N     Seconds to wait for the shell / agent (default: 60)
  --no-prompt-check     Skip the "prompt actually submitted" verification
  --no-wait             Return as soon as the prompt is submitted (see below)
  --wait-timeout N      Seconds to wait for the agent to settle (default: 1800)
  --result-file FILE    Where to write the final transcript (default: temp file)
  --keep                Leave the pane open after it settles
  --sweep               Close leaked ephemeral panes this script created earlier
  --force-sweep         With --sweep, also close ones still working

Lifecycle: whoever spawns an ephemeral review session owns it to the end. With a
prompt supplied, the default is therefore drive-to-completion-then-clean-up:
submit, wait for the agent to settle, capture the transcript to a result file,
and close the pane this script created. `--no-wait` or `--keep` opt out, and
then the caller owns the cleanup instead -- `--sweep` exists because that is the
promise most often broken.

Prints `name=… pane=… result=… state=…` on success. Exits non-zero if the pane is
not verifiably in Run Everything mode, so a bad spawn fails instead of hanging.
EOF
}

# Tabs this script creates carry this prefix so a leaked one is findable later.
EPHEMERAL_PREFIX="cursor-ephemeral:"

model=""
name=""
prompt=""
prompt_file=""
pane=""
cwd="$PWD"
label=""
plan_mode=false
start_timeout=60
check_prompt=true
wait_for_finish=true
wait_timeout=1800
result_file=""
keep_pane=false
sweep=false
force_sweep=false
config_dir="${CURSOR_REVIEW_CONFIG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/cursor-sub-review/config}"
herdr_session="${HERDR_SESSION_NAME:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-wait) wait_for_finish=false; shift ;;
    --wait-timeout) wait_timeout="${2:-}"; shift 2 ;;
    --result-file) result_file="${2:-}"; shift 2 ;;
    --keep) keep_pane=true; shift ;;
    --sweep) sweep=true; shift ;;
    --force-sweep) force_sweep=true; shift ;;
    --model) model="${2:-}"; shift 2 ;;
    --name) name="${2:-}"; shift 2 ;;
    --prompt) prompt="${2:-}"; shift 2 ;;
    --prompt-file) prompt_file="${2:-}"; shift 2 ;;
    --pane) pane="${2:-}"; shift 2 ;;
    --cwd) cwd="${2:-}"; shift 2 ;;
    --label) label="${2:-}"; shift 2 ;;
    --config-dir) config_dir="${2:-}"; shift 2 ;;
    --plan) plan_mode=true; shift ;;
    --start-timeout) start_timeout="${2:-}"; shift 2 ;;
    --no-prompt-check) check_prompt=false; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ctxreview 0.8 isolates each review round in a named Herdr session. Preserve
# that routing through this helper; otherwise Cursor would be started in the
# user's default session even though the pane id came from the isolated one.
herdr_bin="$(type -P herdr 2>/dev/null || true)"
herdr() {
  [[ -n "$herdr_bin" ]] || return 127
  if [[ -n "$herdr_session" ]]; then
    "$herdr_bin" --session "$herdr_session" "$@"
  else
    "$herdr_bin" "$@"
  fi
}

die() { echo "spawn-cursor-pane: $*" >&2; exit 1; }

prepare_zero_mcp() {  # prepare_zero_mcp <config-dir> <workspace>
  local cfg="$1" workspace="$2" tmp listing line id after
  mkdir -p "$cfg" 2>/dev/null || return 1
  tmp="$(mktemp "$cfg/mcp.json.tmp.XXXXXX" 2>/dev/null)" || return 1
  if ! printf '{"mcpServers":{}}\n' > "$tmp" || ! mv "$tmp" "$cfg/mcp.json"; then
    rm -f "$tmp"
    return 1
  fi
  [[ "$(cat "$cfg/mcp.json" 2>/dev/null)" == '{"mcpServers":{}}' ]] || return 1
  listing="$(cd "$workspace" && CURSOR_CONFIG_DIR="$cfg" "$cursor_cmd" mcp list 2>/dev/null)" \
    || return 1
  case "$listing" in "No MCP servers configured"*) return 0 ;; esac
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    case "$line" in
      *": disabled") continue ;;
      *:*) id="${line%%:*}" ;;
      *) return 1 ;;
    esac
    [[ -n "$id" ]] || return 1
    (cd "$workspace" && CURSOR_CONFIG_DIR="$cfg" \
      "$cursor_cmd" mcp disable "$id" >/dev/null 2>&1) || return 1
  done <<< "$listing"
  after="$(cd "$workspace" && CURSOR_CONFIG_DIR="$cfg" "$cursor_cmd" mcp list 2>/dev/null)" \
    || return 1
  case "$after" in "No MCP servers configured"*) return 0 ;; esac
  while IFS= read -r line; do
    [[ -z "$line" ]] || case "$line" in *": disabled") ;; *) return 1 ;; esac
  done <<< "$after"
}

cursor_footer_settled() {
  local agent="$1" screen attempt
  for attempt in 1 2 3; do
    screen="$(herdr agent read "$agent" --source visible 2>/dev/null)" || return 1
    [[ -n "$screen" && "$screen" == *"Add a follow-up"* ]] || return 1
    [[ "$screen" != *"ctrl+c to stop"* ]] || return 1
    [[ "$attempt" -eq 3 ]] || sleep 1
  done
}

# --- sweep: collect ephemeral sessions a previous caller failed to clean up ---
if $sweep; then
  [[ -n "$herdr_bin" ]] || die "herdr is not on PATH"
  command -v jq >/dev/null 2>&1 || die "jq is required"
  leaked="$(herdr tab list | jq -r --arg p "$EPHEMERAL_PREFIX" \
    '.result.tabs[] | select(.label | startswith($p)) | .tab_id')"
  if [[ -z "$leaked" ]]; then
    echo "no leaked ephemeral Cursor sessions"
    exit 0
  fi
  agents_json="$(herdr agent list 2>/dev/null)" \
    && jq -e '.result.agents | type=="array"' >/dev/null 2>&1 <<<"$agents_json" \
    || die "could not verify Herdr agent inventory"
  panes_json="$(herdr pane list 2>/dev/null)" \
    && jq -e '.result.panes | type=="array"' >/dev/null 2>&1 <<<"$panes_json" \
    || die "could not verify Herdr pane inventory"
  status=0
  while IFS= read -r tab_id; do
    [[ -n "$tab_id" ]] || continue
    busy=0
    while IFS= read -r pane_id; do
      [[ -n "$pane_id" ]] || continue
      agent_info="$(jq -c --arg p "$pane_id" \
        '.result.agents[]? | select(.pane_id==$p)' <<<"$agents_json" | sed -n '1p')"
      [[ -n "$agent_info" ]] || continue
      agent_name="$(jq -r '.name // empty' <<<"$agent_info")"
      agent_status="$(jq -r '.agent_status // "unknown"' <<<"$agent_info")"
      agent_kind="$(jq -r '.agent // "unknown"' <<<"$agent_info")"
      case "$agent_status" in idle|done) ;; *) busy=1; continue ;; esac
      if [[ "$agent_kind" == cursor ]] && ! cursor_footer_settled "$agent_name"; then
        busy=1
      fi
    done < <(jq -r --arg t "$tab_id" '.result.panes[]? |
      select(.tab_id==$t) | .pane_id' <<<"$panes_json")
    if [[ "$busy" != "0" ]] && ! $force_sweep; then
      echo "still active or unverifiable, left alone: $tab_id (use --force-sweep to close anyway)"
      status=1
      continue
    fi
    while IFS= read -r pane_id; do
      [[ -n "$pane_id" ]] || continue
      herdr pane close "$pane_id" >/dev/null 2>&1 || true
    done < <(jq -r --arg t "$tab_id" '.result.panes[]? |
      select(.tab_id==$t) | .pane_id' <<<"$panes_json")
    echo "closed leaked ephemeral session: $tab_id"
  done <<<"$leaked"
  exit "$status"
fi

[[ -n "$model" ]] || { usage >&2; die "--model is required"; }
[[ "$wait_timeout" =~ ^[1-9][0-9]*$ ]] || die "--wait-timeout must be a positive integer"
[[ "$start_timeout" =~ ^[1-9][0-9]*$ ]] || die "--start-timeout must be a positive integer"
[[ -n "$herdr_bin" ]] || die "herdr is not on PATH"
command -v jq >/dev/null 2>&1 || die "jq is required"
cursor_cmd="$(command -v cursor-agent || true)"
[[ -n "$cursor_cmd" ]] || die "cursor-agent is not on PATH"
[[ "${HERDR_ENV:-}" == "1" || -n "$(herdr status 2>/dev/null)" ]] || die "no reachable herdr server"

if [[ -n "$prompt_file" ]]; then
  [[ -r "$prompt_file" ]] || die "prompt file is not readable: $prompt_file"
  prompt="$(cat "$prompt_file")"
fi

# Do not silently downgrade a model the caller asked for.
herdr_models="$("$cursor_cmd" --list-models 2>/dev/null | awk '{print $1}')"
if [[ -n "$herdr_models" ]] && ! grep -Fxq "$model" <<<"$herdr_models"; then
  die "unknown Cursor model: $model (see cursor-agent --list-models)"
fi

[[ -n "$name" ]] || name="cursor-${model}-$$"
# Marked, not just named: --sweep finds these later if the owner walks away.
[[ -n "$label" ]] || label="${EPHEMERAL_PREFIX}${name}"

created_tab=""
owns_agent=false
if [[ -z "$pane" ]]; then
  tabs_before="$(herdr tab list | jq -r '.result.tabs[].tab_id' | sort)"
  herdr tab create --label "$label" --cwd "$cwd" --no-focus >/dev/null 2>&1 ||
    die "could not create a tab"
  for _ in $(seq 1 "$start_timeout"); do
    created_tab="$(comm -13 <(printf '%s\n' "$tabs_before") \
      <(herdr tab list | jq -r '.result.tabs[].tab_id' | sort))"
    [[ -n "$created_tab" ]] && break
    sleep 1
  done
  [[ -n "$created_tab" ]] || die "tab did not appear"
  pane="$(herdr pane list | jq -r --arg t "$created_tab" \
    '.result.panes[] | select(.tab_id==$t) | .pane_id' | head -1)"
  [[ -n "$pane" ]] || die "created tab $created_tab has no pane"
fi

cleanup_failed_spawn() {
  # A half-spawned pane is the thing we are trying to stop shipping. If this
  # script created the tab and the spawn did not verify, take it back down.
  if [[ -n "$pane" ]] && { [[ -n "$created_tab" ]] || $owns_agent; }; then
    herdr pane close "$pane" >/dev/null 2>&1 || true
  fi
}

# Cursor keeps chat data outside CURSOR_CONFIG_DIR, but discovers MCP definitions
# from the workspace and ~/.cursor directly. Disable the effective inventory in
# isolated CLI state before exporting that state into the pane.
if ! prepare_zero_mcp "$config_dir" "$cwd"; then
  cleanup_failed_spawn
  die "could not verify zero effective Cursor MCP servers"
fi
config_cmd=""
printf -v config_cmd 'export CURSOR_CONFIG_DIR=%q' "$config_dir"
config_ready=false
for _ in $(seq 1 "$start_timeout"); do
  if herdr pane run "$pane" "$config_cmd" >/dev/null 2>&1; then
    config_ready=true
    break
  fi
  sleep 1
done
$config_ready || {
  cleanup_failed_spawn
  die "could not isolate Cursor config in pane $pane"
}

# `herdr agent start` requires the pane to be at a settled interactive prompt;
# a fresh tab running a slow zsh profile is not, and returns agent_pane_busy.
# Retry rather than treating the first failure as fatal.
started=""
for _ in $(seq 1 "$start_timeout"); do
  if $plan_mode; then
    started="$(herdr agent start "$name" --kind cursor --pane "$pane" -- \
      --mode ask --force --trust --model "$model" 2>&1)"
  else
    started="$(herdr agent start "$name" --kind cursor --pane "$pane" -- \
      --force --trust --model "$model" 2>&1)"
  fi
  grep -q '"type":"agent_started"' <<<"$started" && break
  started=""
  sleep 1
done
if [[ -z "$started" ]]; then
  cleanup_failed_spawn
  die "agent did not start in pane $pane within ${start_timeout}s"
fi
owns_agent=true

# Mode verification, not mode assumption. Cursor prints "Run Everything" in its
# footer only when --force is active; anything else means this pane will stop at
# its first approval with nobody there to answer.
mode_ok=false
screen=""
for _ in $(seq 1 "$start_timeout"); do
  # Capture before matching. With pipefail, `herdr pane read | grep -q` can
  # report failure when grep closes the pipe after its first match and Herdr
  # receives SIGPIPE, turning a healthy Cursor pane into a failed spawn.
  screen="$(herdr pane read "$pane" --source visible --lines 40 2>/dev/null || true)"
  if [[ "$screen" == *"Run Everything"* ]]; then
    mode_ok=true
    break
  fi
  sleep 1
done
if ! $mode_ok; then
  cleanup_failed_spawn
  die "pane $pane did not reach Run Everything mode; refusing to leave a pane that will stall"
fi

if [[ -n "$prompt" ]]; then
  if ! herdr agent prompt "$name" "$prompt" >/dev/null 2>&1; then
    cleanup_failed_spawn
    die "could not submit the prompt to $name"
  fi
  # `agent prompt` fills Cursor's input box; it does not always send it. An
  # unsent prompt looks exactly like a healthy idle pane, so press Enter and
  # then confirm the box actually drained.
  herdr agent send-keys "$name" enter >/dev/null 2>&1 || true
  if $check_prompt; then
    submitted=false
    for _ in $(seq 1 "$start_timeout"); do
      screen="$(herdr pane read "$pane" --source visible --lines 40 2>/dev/null)"
      if grep -qE "Running|task|ctrl\+c to stop" <<<"$screen"; then
        submitted=true
        break
      fi
      sleep 1
    done
    if ! $submitted; then
      cleanup_failed_spawn
      die "prompt did not leave the Cursor composer in $pane"
    fi
  fi
fi

# --- drive to completion, capture, clean up ------------------------------------
# Spawning is the easy half. An ephemeral review session that nobody drives to a
# result and nobody closes is the same waste as one stuck on a prompt, minus the
# visible symptom, so ownership runs to the end by default.
state="spawned"
if [[ -n "$prompt" ]] && $wait_for_finish; then
  # Not `herdr agent wait`: herdr reports a composing Cursor as "idle" and a
  # finished one as "blocked", so waiting on agent_status returns immediately and
  # captures a mid-flight transcript. Measured, not assumed.
  #
  # Cursor's own footer is honest. While a turn is in flight it shows
  # "ctrl+c to stop" next to the input box; when the turn ends only
  # "Add a follow-up" remains. Require several consecutive quiet reads so a
  # redraw between frames cannot read as completion.
  settled_reads=0
  state="timeout"
  for _ in $(seq 1 "$wait_timeout"); do
    screen="$(herdr pane read "$pane" --source visible --lines 40 2>/dev/null)"
    if grep -q "Add a follow-up" <<<"$screen" && ! grep -q "ctrl+c to stop" <<<"$screen"; then
      settled_reads=$((settled_reads + 1))
      if [[ "$settled_reads" -ge 3 ]]; then
        state="settled"
        break
      fi
    else
      settled_reads=0
    fi
    sleep 1
  done
  [[ "$state" == "settled" ]] ||
    echo "spawn-cursor-pane: WARNING: $name did not settle within ${wait_timeout}s" >&2

  [[ -n "$result_file" ]] || result_file="$(mktemp -t "cursor-${name}").md"
  # Capture before closing: the pane is the only place this transcript exists.
  if ! herdr pane read "$pane" --source recent --lines 4000 2>/dev/null \
      | tr -d '\r' > "$result_file" || [[ ! -s "$result_file" ]]; then
    state="capture-failed"
    echo "spawn-cursor-pane: transcript capture failed; $pane was left open" >&2
  fi

  if ! $keep_pane && [[ "$state" == "settled" ]]; then
    herdr pane close "$pane" >/dev/null 2>&1 || true
    state="settled-and-closed"
  fi
fi

printf 'name=%s pane=%s result=%s state=%s\n' \
  "$name" "$pane" "${result_file:--}" "$state"

# A pane left behind is the caller's problem to finish; say so rather than
# exiting 0 and letting it be forgotten.
if [[ "$state" == "timeout" || "$state" == "capture-failed" ]]; then
  echo "spawn-cursor-pane: $pane is still open and unfinished; drive it or run --sweep" >&2
  exit 3
fi
