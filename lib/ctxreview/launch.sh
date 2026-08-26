#!/usr/bin/env bash

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
