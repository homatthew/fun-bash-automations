#!/bin/bash
# Detached input-needed notification classifier for notify.sh.

set -euo pipefail

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/Applications/Visual Studio Code.app/Contents/Resources/app/bin:${PATH:-}"

SPEC="${1:-}"
[ -n "$SPEC" ] && [ -f "$SPEC" ] || exit 0

cleanup() {
  rm -f "$SPEC"
}
trap cleanup EXIT

eval "$(jq -r '
  @sh "SOURCE_TEXT=\(.source_text // "")",
  @sh "TASK_SUMMARY=\(.task_summary // "")",
  @sh "TITLE=\(.title // "")",
  @sh "SUBTITLE=\(.subtitle // "")",
  @sh "GROUP=\(.group // "")",
  @sh "SENDER=\(.sender // "")",
  @sh "OPEN_URL=\(.open_url // "")",
  @sh "CWD=\(.cwd // "")",
  @sh "LOG=\(.log // "/tmp/fba-notify.log")",
  @sh "STATE_FILE=\(.state_file // "")",
  @sh "STATE_ID=\(.state_id // "")",
  @sh "SUMMARY_FILE=\(.summary_file // "")",
  @sh "CONTEXT_FILE=\(.context_file // "")",
  @sh "REPO=\(.repo // "")",
  @sh "BRANCH=\(.branch // "")",
  @sh "PR_CONTEXT=\(.pr_context // "")",
  @sh "RECENT_COMMITS=\(.recent_commits // "")"
' "$SPEC")"

nlog() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >> "$LOG" 2>/dev/null || true
}

home_dir() {
  [ -n "${HOME:-}" ] && { printf '%s' "$HOME"; return; }
  dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2; exit}'
}

state_is_current() {
  [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ] || return 1
  [ "$(cat "$STATE_FILE" 2>/dev/null || true)" = "$STATE_ID" ]
}

extract_json_field() {
  local field="$1" file="$2" out
  out=$(jq -er --arg field "$field" '
    if type == "object" then (.[$field] // empty)
    else empty end
  ' "$file" 2>/dev/null || true)

  printf '%s' "$out" \
    | sed -E '
        s/^[[:space:]]*[-"*`]+[[:space:]]*//;
        s/[[:space:]]*[."`]+$//;
        s/[[:space:]]+/ /g;
        s/^ //; s/ $//;'
}

state_is_input() {
  local value
  value=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [ "$value" = "input" ] || [ "$value" = "needs_input" ] || [ "$value" = "needs-input" ]
}

kind_is_useful() {
  case "$1" in
    Permission|Choice\ needed|Confirm|Clarify|Missing\ info|Review\ needed|Input\ needed)
      return 0
      ;;
  esac
  return 1
}

context_is_useful() {
  local value="$1" value_lc repo_lc branch_lc
  value_lc=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | tr '-' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
  repo_lc=$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]' | tr '-' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
  branch_lc=$(printf '%s' "$BRANCH" | tr '[:upper:]' '[:lower:]' | tr '-' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')

  [ -n "$value_lc" ] || return 1
  [ "$value_lc" = "$repo_lc" ] && return 1
  [ -n "$branch_lc" ] && [ "$value_lc" = "$branch_lc" ] && return 1
  case "$value_lc" in
    main|master|dev|develop|mh\ netflix|fun\ bash\ automations)
      return 1
      ;;
  esac
  return 0
}

display_subtitle() {
  local kind="$1" context="$2"
  if [ -n "$context" ]; then
    printf '%s · %s' "$kind" "$context"
  else
    printf '%s' "$kind"
  fi
}

run_codex_summary() {
  NOTIFY_SUPPRESS=1 PG_INTERNAL_CODEX=1 codex exec \
    -m gpt-5-nano \
    -C "$CWD" \
    -c features.codex_hooks=false \
    -c model_reasoning_effort='"low"' \
    --output-last-message "$tmp" \
    "Classify an agent notification that may need user input.

Output strict JSON with exactly these string fields:
{\"state\":\"input\",\"kind\":\"...\",\"context\":\"...\",\"summary\":\"...\"}

state: \"input\" only if the assistant is asking the user to answer, choose, confirm, approve, provide missing info, review, or run something. Otherwise use \"done\".
kind: one of Permission, Choice needed, Confirm, Clarify, Missing info, Review needed, Input needed.
context: 1-3 words for the workspace/topic, suitable for the notification subtitle. Prefer the feature/domain over repo/branch names.
summary: 3-9 words describing what the user needs to do.

Examples:
{\"state\":\"input\",\"kind\":\"Permission\",\"context\":\"Git workflow\",\"summary\":\"Approve push-gate lease\"}
{\"state\":\"input\",\"kind\":\"Choice needed\",\"context\":\"Agent notifications\",\"summary\":\"Choose input notification behavior\"}
{\"state\":\"input\",\"kind\":\"Confirm\",\"context\":\"Runtime deploy\",\"summary\":\"Confirm hook deployment\"}
{\"state\":\"done\",\"kind\":\"Input needed\",\"context\":\"\",\"summary\":\"\"}

Do not include emoji, markdown, file paths, branch names, or punctuation in the field values.
Except for the required JSON syntax, do not include commentary.

Repo: $REPO
Branch: $BRANCH
CWD: $CWD
Current subtitle: $SUBTITLE
Open PR: $PR_CONTEXT
Recent commits: $RECENT_COMMITS
Prior task summary:
$TASK_SUMMARY

Assistant text:
$SOURCE_TEXT" </dev/null >/dev/null 2>"$err"
}

run_with_timeout() {
  local seconds="$1" rc_file pid rc
  rc_file=$(mktemp -t fba-notify-input-summary-rc 2>/dev/null) || return 1
  rm -f "$rc_file"
  (
    set +e
    run_codex_summary
    printf '%s' "$?" > "$rc_file"
  ) &
  pid=$!

  for _ in $(seq 1 "$((seconds * 10))"); do
    [ -f "$rc_file" ] && break
    sleep 0.1
  done

  if [ ! -f "$rc_file" ]; then
    kill "$pid" >/dev/null 2>&1 || true
    sleep 0.2
    kill -9 "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
    rm -f "$rc_file"
    return 124
  fi

  wait "$pid" >/dev/null 2>&1 || true
  rc=$(cat "$rc_file" 2>/dev/null || printf 1)
  rm -f "$rc_file"
  return "$rc"
}

[ -n "$SOURCE_TEXT" ] || exit 0
state_is_current || exit 0
command -v codex >/dev/null 2>&1 || exit 0

HOME="$(home_dir)"
[ -n "$HOME" ] || HOME="/Users/$(id -un)"
export HOME
export CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
if [ -z "${OPENAI_API_KEY:-}" ] && [ -f "$CODEX_HOME/auth.json" ]; then
  OPENAI_API_KEY="$(jq -r '.OPENAI_API_KEY // empty' "$CODEX_HOME/auth.json" 2>/dev/null || true)"
  export OPENAI_API_KEY
fi

tmp=$(mktemp -t fba-notify-input-summary 2>/dev/null) || exit 0
err=$(mktemp -t fba-notify-input-summary-err 2>/dev/null) || err=/dev/null
trap 'rm -f "$SPEC" "$tmp" "$err"' EXIT

nlog "input summary start: source_len=${#SOURCE_TEXT} task_len=${#TASK_SUMMARY} cwd=$CWD codex=$(command -v codex) home=${HOME:-<none>}"
rc=0
run_with_timeout 20 || rc=$?
state="$(extract_json_field state "$tmp")"
kind="$(extract_json_field kind "$tmp" | cut -c1-24)"
context="$(extract_json_field context "$tmp" | cut -c1-48)"
summary="$(extract_json_field summary "$tmp" | cut -c1-90)"
out_len=$(wc -c < "$tmp" 2>/dev/null | tr -d ' ' || printf 0)
err_tail=$(tr '\n' ' ' < "$err" 2>/dev/null | cut -c1-240)
nlog "input summary codex rc=$rc state=${state:-<none>} kind=${kind:-<none>} out_len=$out_len err=${err_tail:-<none>}"

state_is_input "$state" || exit 0
kind_is_useful "$kind" || kind="Input needed"
context_is_useful "$context" || context=""
[ -n "$summary" ] || summary="$SOURCE_TEXT"

state_is_current || {
  nlog "input summary skipped stale update: $summary"
  exit 0
}

if [ -n "$SUMMARY_FILE" ]; then
  printf '%s' "$summary" > "$SUMMARY_FILE" 2>/dev/null || true
fi
if [ -n "$CONTEXT_FILE" ] && [ -n "$context" ]; then
  printf '%s' "$context" > "$CONTEXT_FILE" 2>/dev/null || true
fi

display_subtitle="$(display_subtitle "$kind" "$context")"
nlog "input summary update: subtitle=${display_subtitle:-<none>} summary=$summary"
while :; do
  state_is_current || break
  resp=$(alerter --title "$TITLE" --subtitle "$display_subtitle" --message "$summary" \
    --ignore-dnd --actions Respond --timeout 0 --sound Pop \
    ${GROUP:+--group "$GROUP"} \
    ${SENDER:+--sender "$SENDER"} --json 2>&1 || true)
  act=$(printf '%s' "$resp" | jq -r '.activationType // ""' 2>/dev/null || true)
  nlog "input summary alerter act=$act"
  if [[ "$act" = "contentsClicked" || "$act" = "actionClicked" ]] && [ -n "$OPEN_URL" ]; then
    open "$OPEN_URL" >/dev/null 2>&1 || true
    if [ -n "$CWD" ] && command -v code >/dev/null 2>&1; then
      code "$CWD" >/dev/null 2>&1 || true
      sleep 0.4
      open "$OPEN_URL" >/dev/null 2>&1 || true
    fi
    if state_is_current; then
      nlog "input summary sticky re-post: state=$STATE_ID"
      sleep 0.6
      continue
    fi
  fi
  break
done
